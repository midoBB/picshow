//! Perceptual hashing used for similar-image detection.
//!
//! Each image gets six 64-bit DCT hashes (pHash), stored in the existing `images` columns:
//!
//! | column                   | region of the (EXIF-oriented) image                          |
//! |--------------------------|--------------------------------------------------------------|
//! | `perceptual_hash`        | whole image                                                  |
//! | `perceptual_hash_center` | largest centered square                                      |
//! | `perceptual_hash_tl`     | largest square anchored at the start (left / top)            |
//! | `perceptual_hash_tr`     | largest square anchored at the end (right / bottom)          |
//! | `perceptual_hash_bl`     | centered 85% zoom (same aspect ratio)                        |
//! | `perceptual_hash_br`     | centered 70% zoom (same aspect ratio)                        |
//!
//! The crop hashes let a cropped copy (whose whole-image hash equals one of the original's
//! crop hashes) be matched against the original.
//!
//! A region with almost no low-frequency structure (black frames, blank walls, clear sky)
//! produces a hash made of noise, which would collide with every other flat region. Such
//! regions are stored as [`UNRELIABLE_HASH`] and are ignored when comparing.

use anyhow::{anyhow, Result};
use fast_image_resize::{self as fir, FilterType, ResizeAlg, ResizeOptions};
use image::{DynamicImage, ImageDecoder, ImageReader};

/// Bump whenever the hash computation changes so stored hashes get recomputed.
pub const HASH_VERSION: u32 = 2;

/// Stored for regions too flat to hash meaningfully. A real hash is never 0: bits are set
/// for coefficients above the median, so roughly half of them are always set.
pub const UNRELIABLE_HASH: i64 = 0;

pub type PerceptualHashes = [Option<i64>; 6];

const DCT_SIZE: usize = 32;
/// The image is first box-averaged down so its short side is this long; every region is
/// then resampled from that small copy instead of the full-resolution decode.
const WORKING_SHORT_SIDE: u32 = 128;
/// Hashes use the lowest-frequency coefficients in zig-zag order (DC excluded). With
/// u + v <= 10 there are 65 of them, of which the first 64 are used.
const MAX_FREQ: usize = 10;
/// RMS (in 8-bit gray levels) of the hashed coefficients below which a region is flat.
const FLAT_RMS: f32 = 2.5;

pub fn compute_from_path(path: &str) -> Result<PerceptualHashes> {
    let mut decoder = ImageReader::open(path)?
        .with_guessed_format()?
        .into_decoder()?;
    let orientation = decoder.orientation()?;
    let mut img = DynamicImage::from_decoder(decoder)?;
    img.apply_orientation(orientation);
    compute(&img)
}

pub fn compute(img: &DynamicImage) -> Result<PerceptualHashes> {
    let luma = img.to_luma8();
    let (src_w, src_h) = luma.dimensions();
    if src_w == 0 || src_h == 0 {
        return Err(anyhow!("Image has no pixels"));
    }
    let src = fir::images::Image::from_vec_u8(src_w, src_h, luma.into_raw(), fir::PixelType::U8)?;

    let mut resizer = fir::Resizer::new();
    let scale = (WORKING_SHORT_SIDE as f64 / src_w.min(src_h) as f64).min(1.0);
    let work_w = ((src_w as f64 * scale).round() as u32).max(1);
    let work_h = ((src_h as f64 * scale).round() as u32).max(1);
    let mut work = fir::images::Image::new(work_w, work_h, fir::PixelType::U8);
    // Box filtering averages every source pixel into the working copy (no aliasing).
    resizer.resize(
        &src,
        &mut work,
        &ResizeOptions::new().resize_alg(ResizeAlg::Convolution(FilterType::Box)),
    )?;

    let (w, h) = (work_w as f64, work_h as f64);
    let side = w.min(h);
    let zoom = |f: f64| ((w * (1.0 - f)) / 2.0, (h * (1.0 - f)) / 2.0, w * f, h * f);
    let regions = [
        (0.0, 0.0, w, h),
        ((w - side) / 2.0, (h - side) / 2.0, side, side),
        (0.0, 0.0, side, side),
        (w - side, h - side, side, side),
        zoom(0.85),
        zoom(0.70),
    ];

    let mut hashes = [None; 6];
    for (slot, (left, top, width, height)) in hashes.iter_mut().zip(regions) {
        let mut dst = fir::images::Image::new(DCT_SIZE as u32, DCT_SIZE as u32, fir::PixelType::U8);
        resizer.resize(
            &work,
            &mut dst,
            &ResizeOptions::new()
                .resize_alg(ResizeAlg::Convolution(FilterType::Bilinear))
                .crop(left, top, width, height),
        )?;
        *slot = Some(hash_pixels(dst.buffer()));
    }
    Ok(hashes)
}

/// pHash of a `DCT_SIZE` x `DCT_SIZE` 8-bit grayscale block.
fn hash_pixels(pixels: &[u8]) -> i64 {
    debug_assert_eq!(pixels.len(), DCT_SIZE * DCT_SIZE);
    let n = DCT_SIZE as f32;
    let cos = |k: usize, x: usize| ((std::f32::consts::PI / n) * (x as f32 + 0.5) * k as f32).cos();

    // Separable 2D DCT-II, computing only the low frequencies that are used.
    let mut rows = [[0f32; MAX_FREQ + 1]; DCT_SIZE];
    for (y, row) in rows.iter_mut().enumerate() {
        for (v, out) in row.iter_mut().enumerate() {
            *out = (0..DCT_SIZE)
                .map(|x| pixels[y * DCT_SIZE + x] as f32 * cos(v, x))
                .sum();
        }
    }
    // Orthonormal scaling (2 / N) for non-DC terms, so FLAT_RMS is in gray levels.
    let mut coeffs = Vec::with_capacity(64);
    for diag in 1..=MAX_FREQ {
        for u in 0..=diag {
            let v = diag - u;
            let c: f32 = (0..DCT_SIZE).map(|y| rows[y][v] * cos(u, y)).sum();
            coeffs.push(c * 2.0 / n);
        }
    }
    coeffs.truncate(64);

    let rms = (coeffs.iter().map(|c| c * c).sum::<f32>() / 64.0).sqrt();
    if rms < FLAT_RMS {
        return UNRELIABLE_HASH;
    }

    let mut sorted = coeffs.clone();
    sorted.sort_by(f32::total_cmp);
    let median = (sorted[31] + sorted[32]) / 2.0;
    let bits = coeffs.iter().enumerate().fold(
        0u64,
        |acc, (i, &c)| if c > median { acc | (1 << i) } else { acc },
    );
    bits as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{GrayImage, Luma};

    fn scene(w: u32, h: u32, seed: u32) -> DynamicImage {
        // Smooth, photo-like content: a few overlapping blobs plus a gradient.
        let s = seed as f32;
        DynamicImage::ImageLuma8(GrayImage::from_fn(w, h, |x, y| {
            let (fx, fy) = (x as f32 / w as f32, y as f32 / h as f32);
            let mut v = 60.0 + 80.0 * fy;
            for k in 0..4 {
                let k = k as f32;
                let cx = ((s * 1.7 + k * 2.3).sin() + 1.0) / 2.0;
                let cy = ((s * 0.9 + k * 1.1).cos() + 1.0) / 2.0;
                let d = ((fx - cx).powi(2) + (fy - cy).powi(2)).sqrt();
                v += 70.0 * (-d * d * 18.0).exp() * if k as u32 % 2 == 0 { 1.0 } else { -1.0 };
            }
            Luma([v.clamp(0.0, 255.0) as u8])
        }))
    }

    fn dist(a: i64, b: i64) -> u32 {
        (a ^ b).count_ones()
    }

    #[test]
    fn resized_copy_matches_and_different_scene_does_not() {
        let a = compute(&scene(1200, 800, 1)).unwrap();
        let resized = compute(&scene(1200, 800, 1).resize_exact(
            300,
            200,
            image::imageops::FilterType::Triangle,
        ))
        .unwrap();
        let other = compute(&scene(1200, 800, 7)).unwrap();
        assert!(dist(a[0].unwrap(), resized[0].unwrap()) <= 8);
        assert!(dist(a[0].unwrap(), other[0].unwrap()) > 16);
    }

    #[test]
    fn center_square_crop_matches_center_hash() {
        let img = scene(1200, 800, 3);
        let original = compute(&img).unwrap();
        let cropped = compute(&img.crop_imm(200, 0, 800, 800)).unwrap();
        assert!(dist(original[1].unwrap(), cropped[0].unwrap()) <= 4);
    }

    #[test]
    fn flat_regions_are_marked_unreliable() {
        let flat = DynamicImage::ImageLuma8(GrayImage::from_fn(640, 480, |x, y| {
            Luma([120 + ((x * 7 + y * 13) % 3) as u8])
        }));
        let hashes = compute(&flat).unwrap();
        assert!(hashes.iter().all(|h| *h == Some(UNRELIABLE_HASH)));
    }

    #[test]
    fn real_hashes_have_about_half_the_bits_set() {
        let h = compute(&scene(800, 600, 5)).unwrap()[0].unwrap();
        assert!((20..=44).contains(&h.count_ones()));
    }
}
