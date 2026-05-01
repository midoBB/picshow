use anyhow::{anyhow, Result};
use fast_image_resize::{self as fir, ResizeAlg, ResizeOptions};
use image::DynamicImage;
use image_hasher::{HashAlg, HasherConfig};
use regex::Regex;
use std::ffi::OsStr;
use std::path::Path;
use std::process::Stdio;
use std::sync::Arc;
use tokio::fs::File;
use tokio::io::{AsyncReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::Semaphore;
use tracing::{debug, warn};
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
    phash_semp: Arc<Semaphore>,
}

impl Handler {
    pub fn new(config: Arc<AppConfig>) -> Self {
        let available_concurrency = std::thread::available_parallelism()
            .map(|x| x.get())
            .unwrap_or(1)
            / 2;

        let phash_concurrency = (config.concurrency as usize)
            .min(available_concurrency)
            .max(1);
        Self {
            config,
            identify_regex: Regex::new(r"^(?P<width>\d+)x(?P<height>\d+)$")
                .expect("Identify regex should be valid"),
            identify_semp: Arc::new(Semaphore::new(1)),
            convert_semp: Arc::new(Semaphore::new(1)),
            ffmpeg_semp: Arc::new(Semaphore::new(1)),
            ffpobe_semp: Arc::new(Semaphore::new(1)),
            phash_semp: Arc::new(Semaphore::new(phash_concurrency)),
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
    pub async fn compute_perceptual_hashes(
        &self,
        file_path: &str,
    ) -> Result<(
        Option<i64>,
        Option<i64>,
        Option<i64>,
        Option<i64>,
        Option<i64>,
        Option<i64>,
    )> {
        let _permit = self.phash_semp.acquire().await?;

        match tokio::task::spawn_blocking({
            let file_path = file_path.to_string();
            move || -> Result<(
                Option<i64>,
                Option<i64>,
                Option<i64>,
                Option<i64>,
                Option<i64>,
                Option<i64>,
            )> {
                // Keep the work per image tiny: we resize directly to the algorithm's input size.
                // For `HashAlg::Gradient` with `hash_size(8,8)`, the hasher internally uses
                // (width + 1) x height.
                const HASH_W: u32 = 8;
                const HASH_H: u32 = 8;
                const DST_W: u32 = HASH_W + 1;
                const DST_H: u32 = HASH_H;

                let img = image::open(&file_path)?;
                let rgba = img.to_rgba8();
                let (src_w, src_h) = (rgba.width(), rgba.height());
                let src_image = fir::images::Image::from_vec_u8(
                    src_w,
                    src_h,
                    rgba.into_raw(),
                    fir::PixelType::U8x4,
                )?;
                let mut resizer = fir::Resizer::new();

                let hasher = HasherConfig::new()
                    .hash_alg(HashAlg::Gradient)
                    .hash_size(HASH_W, HASH_H)
                    .to_hasher();

                let to_i64 = |hash: image_hasher::ImageHash| -> Result<i64> {
                    let hash_bytes = hash.as_bytes();
                    if hash_bytes.len() < 8 {
                        return Err(anyhow!("Hash too short"));
                    }
                    let hash_u64 = u64::from_be_bytes(hash_bytes[0..8].try_into()?);
                    Ok(hash_u64 as i64)
                };

                let hash_letterboxed = |resizer: &mut fir::Resizer| -> Result<i64> {
                    let scale = (DST_W as f32 / src_w as f32).min(DST_H as f32 / src_h as f32);
                    let new_w = ((src_w as f32) * scale).round().max(1.0) as u32;
                    let new_h = ((src_h as f32) * scale).round().max(1.0) as u32;

                    let mut resized_buf = vec![0u8; (new_w * new_h * 4) as usize];
                    let mut resized_image = fir::images::Image::from_slice_u8(
                        new_w,
                        new_h,
                        resized_buf.as_mut_slice(),
                        fir::PixelType::U8x4,
                    )?;

                    let opts = ResizeOptions::new()
                        .use_alpha(false)
                        .resize_alg(ResizeAlg::Interpolation(fir::FilterType::Bilinear));
                    resizer.resize(&src_image, &mut resized_image, &opts)?;

                    let mut canvas = vec![128u8; (DST_W * DST_H * 4) as usize];
                    for px in canvas.chunks_exact_mut(4) {
                        px[3] = 255;
                    }

                    let off_x = ((DST_W - new_w) / 2) as usize;
                    let off_y = ((DST_H - new_h) / 2) as usize;
                    let dst_stride = (DST_W * 4) as usize;
                    let src_stride = (new_w * 4) as usize;
                    for y in 0..(new_h as usize) {
                        let dst_start = (off_y + y) * dst_stride + off_x * 4;
                        let src_start = y * src_stride;
                        canvas[dst_start..dst_start + src_stride]
                            .copy_from_slice(&resized_buf[src_start..src_start + src_stride]);
                    }

                    let dyn_img = DynamicImage::ImageRgba8(
                        image::RgbaImage::from_raw(DST_W, DST_H, canvas).unwrap(),
                    );
                    to_i64(hasher.hash_image(&dyn_img))
                };

                let hash_resized =
                    |resizer: &mut fir::Resizer, centering: (f64, f64)| -> Result<i64> {
                    let mut dst_buf = vec![0u8; (DST_W * DST_H * 4) as usize];
                    let mut dst_image = fir::images::Image::from_slice_u8(
                        DST_W,
                        DST_H,
                        dst_buf.as_mut_slice(),
                        fir::PixelType::U8x4,
                    )?;

                    let opts = ResizeOptions::new()
                        .use_alpha(false)
                        .resize_alg(ResizeAlg::Interpolation(fir::FilterType::Bilinear))
                        .fit_into_destination(Some(centering));
                    resizer.resize(&src_image, &mut dst_image, &opts)?;

                    // Hash the tiny resized image. The hasher's internal resize is effectively free.
                    let dyn_img = DynamicImage::ImageRgba8(
                        image::RgbaImage::from_raw(DST_W, DST_H, dst_buf).unwrap(),
                    );
                    to_i64(hasher.hash_image(&dyn_img))
                };

                let full = hash_letterboxed(&mut resizer).ok();
                let center = hash_resized(&mut resizer, (0.5, 0.5)).ok();
                let tl = hash_resized(&mut resizer, (0.0, 0.0)).ok();
                let tr = hash_resized(&mut resizer, (1.0, 0.0)).ok();
                let bl = hash_resized(&mut resizer, (0.0, 1.0)).ok();
                let br = hash_resized(&mut resizer, (1.0, 1.0)).ok();

                Ok((full, center, tl, tr, bl, br))
            }
        })
        .await
        {
            Ok(Ok(hashes)) => Ok(hashes),
            Ok(Err(e)) => {
                warn!(
                    "Failed to compute perceptual hashes for {}: {}",
                    file_path, e
                );
                Ok((None, None, None, None, None, None))
            }
            Err(e) => {
                warn!("Perceptual hash task panicked for {}: {}", file_path, e);
                Ok((None, None, None, None, None, None))
            }
        }
    }

    pub async fn compute_perceptual_hash(&self, file_path: &str) -> Result<Option<i64>> {
        let (full, ..) = self.compute_perceptual_hashes(file_path).await?;
        Ok(full)
    }

    pub async fn handle_new_image(
        &self,
        file: UnfilledMediaFile,
        path: &str,
    ) -> Result<FilledMediaFile> {
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
        if ext == "gif" {
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

        // Compute perceptual hashes (full + crop variants)
        let (
            perceptual_hash,
            perceptual_hash_center,
            perceptual_hash_tl,
            perceptual_hash_tr,
            perceptual_hash_bl,
            perceptual_hash_br,
        ) = self.compute_perceptual_hashes(path).await?;
        debug!("Perceptual hash (full): {}", perceptual_hash.unwrap_or(-1));

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
            Image::new(
                Uuid::new_v4(),
                width,
                height,
                perceptual_hash,
                perceptual_hash_center,
                perceptual_hash_tl,
                perceptual_hash_tr,
                perceptual_hash_bl,
                perceptual_hash_br,
                thumbnail,
            ),
            full_mime,
        );
        drop(convert_perm);
        Ok(with_image)
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
        .unwrap_or_else(|| "other/other".to_string())
        .split_once("/")
        .map(|(name, _)| name)
        .unwrap_or("other")
        .to_string();
    MediaType::try_from(mime_name)
}

pub async fn get_mime(file_path: &str) -> Result<String> {
    let from = Path::new(&file_path);
    let mime = tree_magic_mini::from_filepath(from).ok_or(anyhow!("Could not get mime type"))?;
    Ok(mime.to_string())
}
