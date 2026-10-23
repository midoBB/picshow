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
use crate::data::{
    FilledMediaFile, Image, MediaType, PerceptualFeatures, Thumbnail, UnfilledMediaFile, Video,
};

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
    pub async fn compute_perceptual_hashes(&self, file_path: &str) -> Result<PerceptualFeatures> {
        let _permit = self.phash_semp.acquire().await?;

        match tokio::task::spawn_blocking({
            let file_path = file_path.to_string();
            move || -> Result<PerceptualFeatures> {
                // Keep the work per image tiny: we resize directly to the algorithm's input size.
                // For `HashAlg::Gradient` with `hash_size(w, h)`, the hasher internally uses
                // (w + 1) x h.
                const HASH_W: u32 = 8;
                const HASH_H: u32 = 8;
                const DST_W: u32 = HASH_W + 1;
                const DST_H: u32 = HASH_H;
                const HASH256_W: u32 = 16;
                const HASH256_H: u32 = 16;
                const HIST_SIDE: u32 = 64;

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
                let hasher256 = HasherConfig::new()
                    .hash_alg(HashAlg::Gradient)
                    .hash_size(HASH256_W, HASH256_H)
                    .to_hasher();

                let to_i64 = |hash: image_hasher::ImageHash| -> Result<i64> {
                    let hash_bytes = hash.as_bytes();
                    if hash_bytes.len() < 8 {
                        return Err(anyhow!("Hash too short"));
                    }
                    let hash_u64 = u64::from_be_bytes(hash_bytes[0..8].try_into()?);
                    Ok(hash_u64 as i64)
                };

                let to_bytes32 = |hash: image_hasher::ImageHash| -> Result<[u8; 32]> {
                    hash.as_bytes()
                        .try_into()
                        .map_err(|_| anyhow!("256-bit hash has wrong length"))
                };

                let letterboxed = |resizer: &mut fir::Resizer,
                                   dst_w: u32,
                                   dst_h: u32|
                 -> Result<DynamicImage> {
                    let scale = (dst_w as f32 / src_w as f32).min(dst_h as f32 / src_h as f32);
                    let new_w = ((src_w as f32) * scale).round().clamp(1.0, dst_w as f32) as u32;
                    let new_h = ((src_h as f32) * scale).round().clamp(1.0, dst_h as f32) as u32;

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

                    let mut canvas = vec![128u8; (dst_w * dst_h * 4) as usize];
                    for px in canvas.chunks_exact_mut(4) {
                        px[3] = 255;
                    }

                    let off_x = ((dst_w - new_w) / 2) as usize;
                    let off_y = ((dst_h - new_h) / 2) as usize;
                    let dst_stride = (dst_w * 4) as usize;
                    let src_stride = (new_w * 4) as usize;
                    for y in 0..(new_h as usize) {
                        let dst_start = (off_y + y) * dst_stride + off_x * 4;
                        let src_start = y * src_stride;
                        canvas[dst_start..dst_start + src_stride]
                            .copy_from_slice(&resized_buf[src_start..src_start + src_stride]);
                    }

                    Ok(DynamicImage::ImageRgba8(
                        image::RgbaImage::from_raw(dst_w, dst_h, canvas).unwrap(),
                    ))
                };

                let resized = |resizer: &mut fir::Resizer,
                               dst_w: u32,
                               dst_h: u32,
                               centering: Option<(f64, f64)>|
                 -> Result<Vec<u8>> {
                    let mut dst_buf = vec![0u8; (dst_w * dst_h * 4) as usize];
                    let mut dst_image = fir::images::Image::from_slice_u8(
                        dst_w,
                        dst_h,
                        dst_buf.as_mut_slice(),
                        fir::PixelType::U8x4,
                    )?;

                    let opts = ResizeOptions::new()
                        .use_alpha(false)
                        .resize_alg(ResizeAlg::Interpolation(fir::FilterType::Bilinear))
                        .fit_into_destination(centering);
                    resizer.resize(&src_image, &mut dst_image, &opts)?;
                    Ok(dst_buf)
                };

                let hash_cropped =
                    |resizer: &mut fir::Resizer, centering: (f64, f64)| -> Result<i64> {
                        let dst_buf = resized(resizer, DST_W, DST_H, Some(centering))?;
                        // Hash the tiny resized image. The hasher's internal resize is effectively free.
                        let dyn_img = DynamicImage::ImageRgba8(
                            image::RgbaImage::from_raw(DST_W, DST_H, dst_buf).unwrap(),
                        );
                        to_i64(hasher.hash_image(&dyn_img))
                    };

                let full = letterboxed(&mut resizer, DST_W, DST_H)
                    .and_then(|img| to_i64(hasher.hash_image(&img)))
                    .ok();
                let center = hash_cropped(&mut resizer, (0.5, 0.5)).ok();
                let tl = hash_cropped(&mut resizer, (0.0, 0.0)).ok();
                let tr = hash_cropped(&mut resizer, (1.0, 0.0)).ok();
                let bl = hash_cropped(&mut resizer, (0.0, 1.0)).ok();
                let br = hash_cropped(&mut resizer, (1.0, 1.0)).ok();

                let hash256 = letterboxed(&mut resizer, HASH256_W + 1, HASH256_H)
                    .and_then(|img| to_bytes32(hasher256.hash_image(&img)))
                    .ok();

                // Stretch (no crop, no letterbox) so every source pixel contributes and
                // the grey padding doesn't skew the colour distribution.
                let histogram = resized(&mut resizer, HIST_SIDE, HIST_SIDE, None)
                    .map(|buf| crate::clustering::features::build_histogram(&buf))
                    .ok();

                Ok(PerceptualFeatures {
                    hashes64: [full, center, tl, tr, bl, br],
                    hash256,
                    histogram,
                })
            }
        })
        .await
        {
            Ok(Ok(features)) => Ok(features),
            Ok(Err(e)) => {
                warn!(
                    "Failed to compute perceptual hashes for {}: {}",
                    file_path, e
                );
                Ok(PerceptualFeatures::default())
            }
            Err(e) => {
                warn!("Perceptual hash task panicked for {}: {}", file_path, e);
                Ok(PerceptualFeatures::default())
            }
        }
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

        // Compute perceptual features (64-bit full + crops, 256-bit full, colour histogram)
        let features = self.compute_perceptual_hashes(path).await?;
        debug!(
            "Perceptual hash (full): {}",
            features.hashes64[0].unwrap_or(-1)
        );

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
            Image::new(Uuid::new_v4(), width, height, &features, thumbnail),
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clustering::features::{ImageFeatures, MatchParams};

    /// Warm hues across x, brightness down y; `hue_shift` recolours without
    /// changing the brightness structure the gradient hash sees.
    fn gradient(w: u32, h: u32, hue_shift: f32) -> image::RgbImage {
        image::RgbImage::from_fn(w, h, |x, y| {
            let hue = (x as f32 / w as f32 * 0.25 + hue_shift).fract() * 6.0;
            let (s, v) = (0.8, 0.3 + 0.7 * y as f32 / h as f32);
            let c = v * s;
            let x2 = c * (1.0 - (hue % 2.0 - 1.0).abs());
            let (r, g, b) = match hue as u32 {
                0 => (c, x2, 0.0),
                1 => (x2, c, 0.0),
                2 => (0.0, c, x2),
                3 => (0.0, x2, c),
                4 => (x2, 0.0, c),
                _ => (c, 0.0, x2),
            };
            let m = v - c;
            let to_u8 = |ch: f32| ((ch + m) * 255.0).round() as u8;
            image::Rgb([to_u8(r), to_u8(g), to_u8(b)])
        })
    }

    #[tokio::test]
    async fn features_match_resized_copy_and_veto_recoloured_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = |name: &str| dir.path().join(name).to_string_lossy().to_string();
        gradient(640, 480, 0.0).save(path("a.png")).unwrap();
        image::imageops::resize(
            &gradient(640, 480, 0.0),
            320,
            240,
            image::imageops::FilterType::Triangle,
        )
        .save(path("small.png"))
        .unwrap();
        gradient(640, 480, 0.5)
            .save(path("recoloured.png"))
            .unwrap();

        let handler = Handler::new(Arc::new(AppConfig::default()));
        let mut features = Vec::new();
        for name in ["a.png", "small.png", "recoloured.png"] {
            let f = handler
                .compute_perceptual_hashes(&path(name))
                .await
                .unwrap();
            assert!(f.hashes64.iter().all(Option::is_some), "{name}");
            assert!(f.hash256.is_some(), "{name}");
            let total: u32 = f
                .histogram
                .as_ref()
                .unwrap()
                .iter()
                .map(|&b| b as u32)
                .sum();
            assert!(
                total.abs_diff(u16::MAX as u32) < 128,
                "{name}: histogram sums to {total}"
            );
            features.push(ImageFeatures::from_perceptual(Uuid::nil(), &f));
        }

        let params = MatchParams {
            threshold64: 10,
            threshold256: 40,
            color_threshold: 0.35,
            color_tight: 0.12,
            rescue_factor: 1.5,
        };
        assert!(params.match_weight(&features[0], &features[1]).is_some());
        assert!(params.match_weight(&features[0], &features[2]).is_none());
    }
}
