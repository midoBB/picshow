use anyhow::{anyhow, Result};
use regex::Regex;
use std::ffi::OsStr;
use std::path::Path;
use std::process::Stdio;
use std::sync::Arc;
use tokio::fs::File;
use tokio::io::{AsyncReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::Semaphore;
use tracing::debug;
use uuid::Uuid;
use xxhash_rust::const_xxh3::xxh3_64;

use crate::config::AppConfig;
use crate::data::{FilledMediaFile, Image, MediaType, Thumbnail, UnfilledMediaFile, Video};

#[derive(Debug, Clone)]
pub struct Handler {
    config: Arc<AppConfig>,
    identify_regex: Regex,
    identify_semp: Arc<Semaphore>,
    convert_semp: Arc<Semaphore>,
    ffmpeg_semp: Arc<Semaphore>,
    ffpobe_semp: Arc<Semaphore>,
}

impl Handler {
    pub fn new(config: Arc<AppConfig>) -> Self {
        Self {
            config,
            identify_regex: Regex::new(r"^(?P<width>\d+)x(?P<height>\d+)$")
                .expect("Identify regex should be valid"),
            identify_semp: Arc::new(Semaphore::new(1)),
            convert_semp: Arc::new(Semaphore::new(1)),
            ffmpeg_semp: Arc::new(Semaphore::new(1)),
            ffpobe_semp: Arc::new(Semaphore::new(1)),
        }
    }
    pub async fn generate_key(&self, file_path: &str) -> Result<String> {
        let file = File::open(file_path).await?;
        let metadata = file.metadata().await?;
        let mut reader = BufReader::new(file);
        let mut buf: Vec<u8> = vec![];
        if metadata.len() < u64::from(self.config.hash_size * 1024) {
            reader.read_to_end(&mut buf).await?;
        } else {
            buf.resize(usize::try_from(self.config.hash_size * 1024)?, 0);
            reader.read_exact(&mut buf).await?;
        }
        let hash = xxh3_64(buf.as_slice()).to_string();
        Ok(hash)
    }
    pub async fn handle_new_image(
        &self,
        file: UnfilledMediaFile,
        path: &str,
    ) -> Result<(FilledMediaFile, u64)> {
        debug!("Processing new image {}", file.filename);
        let full_mime = get_mime(path).await?;
        let mut filename = file.filename.clone();
        let ext = Path::new(path)
            .extension()
            .and_then(OsStr::to_str)
            .ok_or_else(|| anyhow!("Could not get file extension"))?;
        let parent_dir = Path::new(path)
            .parent()
            .ok_or_else(|| anyhow!("Could not get parent directory"))?;
        if ext == ".gif" {
            filename = filename.clone() + "[0]"; // Identify the first frame of the GIF
        }
        let identify_perm = self.identify_semp.acquire().await?;
        let mut identify_cmd = Command::new("identify");
        identify_cmd
            .arg("-format")
            .arg("%wx%h")
            .arg(parent_dir.join(filename));
        let identify_output = identify_cmd.output().await?;
        if !identify_output.status.success() {
            return Err(anyhow!(
                "identify command failed with status: {}",
                identify_output.status
            ));
        }
        let output = String::from_utf8(identify_output.stdout)?;
        let caps = self
            .identify_regex
            .captures(&output)
            .ok_or_else(|| anyhow!("identify command output is not in the expected format"))?;
        let width = caps
            .name("width")
            .ok_or(anyhow!(
                "identify command output is not in the expected format"
            ))?
            .as_str()
            .parse::<u32>()?;
        let height = caps
            .name("height")
            .ok_or(anyhow!(
                "identify command output is not in the expected format"
            ))?
            .as_str()
            .parse::<u32>()?;
        let (thumb_width, thumb_height) = self.calculate_thumb_size(width, height);
        let temp = tempfile::NamedTempFile::new()?;
        let temp_path = temp
            .path()
            .to_str()
            .ok_or(anyhow!("could not create temporary files"))?;
        drop(identify_perm);
        let convert_perm = self.convert_semp.acquire().await?;
        let mut convert_cmd = Command::new("convert");
        convert_cmd.args([
            path,
            "-thumbnail",
            format!("{}x{}", thumb_width, thumb_height).as_str(),
            "-depth",
            "8",
            "-quality",
            "85",
            "-filter",
            "Triangle",
            temp_path,
        ]);
        let convert_output = convert_cmd.output().await?;
        if !convert_output.status.success() {
            return Err(anyhow!(
                "convert command failed with status: {}",
                convert_output.status
            ));
        }
        let temp_file = File::open(temp_path).await?;
        let mut reader = BufReader::new(temp_file);
        let mut buf: Vec<u8> = vec![];
        reader.read_to_end(&mut buf).await?;
        let thumbnail = Thumbnail::new(uuid::Uuid::new_v4(), thumb_width, thumb_height, buf);
        let with_image = file.with_image(
            Image::new(Uuid::new_v4(), width, height, thumbnail),
            full_mime,
        );
        drop(convert_perm);
        let phash = self.calculate_phash(path.to_string()).await?;

        Ok((with_image, phash))
    }
    pub async fn handle_new_video(
        &self,
        file: UnfilledMediaFile,
        path: &str,
    ) -> Result<FilledMediaFile> {
        use serde::{Deserialize, Serialize};

        #[derive(Serialize, Deserialize)]
        pub struct ProbeResult {
            streams: Vec<Stream>,
            format: Format,
        }

        #[derive(Serialize, Deserialize)]
        pub struct Format {
            duration: String,
        }

        #[derive(Serialize, Deserialize)]
        pub struct Stream {
            #[serde(rename = "codec_type")]
            codec_type: String,
            width: Option<u32>,
            height: Option<u32>,
        }
        debug!("Processing new video {}", file.filename);
        let full_mime = get_mime(path).await?;
        let probe_perm = self.ffpobe_semp.acquire().await?;
        let mut probe_cmd = Command::new("ffprobe");
        probe_cmd.stdout(Stdio::piped());
        probe_cmd.args([
            "-v",
            "quiet",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            path,
        ]);
        let probe_output = probe_cmd.output().await?;
        if !probe_output.status.success() {
            return Err(anyhow!(
                "probe command failed with status: {}",
                probe_output.status
            ));
        }
        let out = String::from_utf8(probe_output.stdout)?;

        let probe_res: ProbeResult = serde_json::from_str(&out).map_err(|e| {
            anyhow!(
                "ffprobe command output is not in the expected format: {}, file {}",
                e,
                file.filename
            )
        })?;
        let (width, height) = probe_res
            .streams
            .iter()
            .find(|stream| stream.codec_type == "video")
            .map(|stream| {
                (
                    stream.width.ok_or(anyhow!("")),
                    stream.height.ok_or(anyhow!("")),
                )
            })
            .ok_or(anyhow!(
                "ffprobe command output is not in the expected format"
            ))?;
        let width = width?;
        let height = height?;
        let duration = probe_res.format.duration.parse::<f64>()?;
        debug!("Generating thumbnail for video {}", file.filename);
        let screenshot_at = duration * 0.33;
        let (thumb_width, thumb_height) = self.calculate_thumb_size(width, height);
        drop(probe_perm);
        let temp = tempfile::NamedTempFile::new()?;
        let temp_path = temp
            .path()
            .to_str()
            .ok_or(anyhow!("could not create temporary files"))?;
        let ffmpeg_perm = self.ffmpeg_semp.acquire().await?;
        let mut ffmpeg_cmd = Command::new("ffmpeg");
        ffmpeg_cmd.args([
            "-ss",
            format!("{:.2}", screenshot_at).as_str(),
            "-t",
            "0.1",
            "-i",
            path,
            "-an",
            "-vframes",
            "1",
            "-vf",
            format!("scale={}:{}:flags=fast_bilinear", thumb_width, thumb_height).as_str(),
            "-f",
            "mjpeg",
            "-q:v",
            "5",
            "-y",
            temp_path,
        ]);
        let ffmpeg_output = ffmpeg_cmd.output().await?;
        if !ffmpeg_output.status.success() {
            return Err(anyhow!(
                "ffmpeg command failed with status: {}",
                ffmpeg_output.status
            ));
        }
        let temp_file = File::open(temp_path).await?;
        let mut reader = BufReader::new(temp_file);
        let mut buf: Vec<u8> = vec![];
        reader.read_to_end(&mut buf).await?;
        let thumbnail = Thumbnail::new(uuid::Uuid::new_v4(), thumb_width, thumb_height, buf);
        let with_video = file.with_video(
            Video::new(
                Uuid::new_v4(),
                width,
                height,
                duration.round() as u64,
                thumbnail,
            ),
            full_mime,
        );
        drop(ffmpeg_perm);
        Ok(with_video)
    }

    pub async fn calculate_phash(&self, path: String) -> Result<u64> {
        use fast_image_resize as fr;
        use image::{DynamicImage, ImageBuffer};
        use rustdct::DctPlanner;

        fn load_image(path: String) -> Result<DynamicImage> {
            image::open(Path::new(&path)).map_err(|e| anyhow!(e.to_string()))
        }
        fn resize_image(
            img: &DynamicImage,
            size: u32,
        ) -> Result<ImageBuffer<image::Rgb<u8>, Vec<u8>>> {
            println!("Resizing image");
            let width = size;
            let height = size;

            // Create resizer
            let src_image = fast_image_resize::images::Image::from_vec_u8(
                img.width(),
                img.height(),
                img.to_rgb8().into_raw(),
                fr::PixelType::U8x3,
            )
            .map_err(|e| anyhow!(e.to_string()))?;

            // Create destination buffer
            let mut dst_image =
                fast_image_resize::images::Image::new(width, height, fr::PixelType::U8x3);

            // Create resize algorithm
            let mut resizer = fast_image_resize::Resizer::new();

            let mut options = fast_image_resize::ResizeOptions::new();
            options.algorithm =
                fast_image_resize::ResizeAlg::Convolution(fast_image_resize::FilterType::Bilinear);
            let options = Some(options);
            // Perform resize
            resizer
                .resize(&src_image, &mut dst_image, &options)
                .map_err(|e| anyhow!(e.to_string()))?;

            // Convert back to image buffer
            ImageBuffer::from_raw(width, height, dst_image.into_vec())
                .ok_or_else(|| anyhow!("Failed to create image buffer".to_string()))
        }

        #[inline(always)]
        fn to_grayscale_f64(img: &ImageBuffer<image::Rgb<u8>, Vec<u8>>) -> Vec<f64> {
            println!("Converting to grayscale");
            img.pixels()
                .map(|p| {
                    let [r, g, b] = p.0;
                    // Using same coefficients as original: 0.299, 0.587, 0.114
                    0.299 * f64::from(r) + 0.587 * f64::from(g) + 0.114 * f64::from(b)
                })
                .collect()
        }
        fn apply_dct(pixels: &[f64]) -> Vec<f64> {
            println!("Applying DCT");
            let mut planner = DctPlanner::new();
            let dct = planner.plan_dct2(4096);
            let mut output = pixels.to_vec();
            dct.process_dct2(&mut output);
            output
        }

        fn compute_median(values: &[f64]) -> f64 {
            println!("Computing median");
            let mut sorted = values.to_vec();
            sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());

            let mid = values.len() / 2;
            if values.len() % 2 == 0 {
                (sorted[mid - 1] + sorted[mid]) / 2.0
            } else {
                sorted[mid]
            }
        }
        println!("Starting perception hash");
        const SIZE: u32 = 64;
        tokio::task::spawn_blocking(move || {
            println!("Loading image");
            let img = load_image(path).unwrap();
            println!("Loaded image");
            // Resize to 64x64
            let resized = resize_image(&img, SIZE)?;

            // Convert to grayscale and get pixels as f64
            let pixels = to_grayscale_f64(&resized);

            // Apply DCT
            let dct_result = apply_dct(&pixels);

            // Calculate median of DCT coefficients
            let median = compute_median(&dct_result);

            // Generate hash based on whether values are above median
            let mut hash = 0u64;
            for (i, &value) in dct_result.iter().take(64).enumerate() {
                if value > median {
                    hash |= 1u64 << i;
                }
            }
            Ok::<u64, anyhow::Error>(hash)
        })
        .await?
    }

    fn calculate_thumb_size(&self, width: u32, height: u32) -> (u32, u32) {
        if width > height {
            (
                self.config.max_thumbnail_size,
                calculate_thumbnail_dimension(height, width, self.config.max_thumbnail_size),
            )
        } else {
            (
                calculate_thumbnail_dimension(width, height, self.config.max_thumbnail_size),
                self.config.max_thumbnail_size,
            )
        }
    }
}

fn calculate_thumbnail_dimension(original: u32, other: u32, max_size: u32) -> u32 {
    ((original as f64 * max_size as f64 / other as f64).round() as u32).min(max_size)
}
pub async fn get_mime_guess(file_path: &str) -> Result<MediaType> {
    let from = Path::new(&file_path);
    let mime = mime_guess::from_path(from);
    let mime_name = mime
        .iter()
        .map(|x| x.to_string())
        .find(|x| x.contains("video") || x.contains("image"))
        .unwrap_or("other/other".to_string())
        .split_once("/")
        .unwrap()
        .0
        .to_string();
    MediaType::try_from(mime_name)
}

pub async fn get_mime(file_path: &str) -> Result<String> {
    let from = Path::new(&file_path);
    let mime = tree_magic_mini::from_filepath(from).ok_or(anyhow!("Could not get mime type"))?;
    Ok(mime.to_string())
}
