use uuid::Uuid;

use crate::data::PerceptualFeatures;

// HSV histogram layout: index = (h * HIST_S + s) * HIST_V + v.
pub const HIST_H: usize = 8;
pub const HIST_S: usize = 4;
pub const HIST_V: usize = 4;
pub const HIST_BINS: usize = HIST_H * HIST_S * HIST_V;

/// Below this saturation hue is noise, so greys all land in hue bin 0.
const GREY_SATURATION: f32 = 0.1;

/// Bin an RGBA8 buffer into an HSV histogram whose bins sum to ~65535.
pub fn build_histogram(rgba: &[u8]) -> Vec<u16> {
    let mut counts = [0u32; HIST_BINS];
    let mut total = 0u32;
    for px in rgba.as_chunks::<4>().0 {
        counts[hsv_bin(px[0], px[1], px[2])] += 1;
        total += 1;
    }
    if total == 0 {
        return vec![0; HIST_BINS];
    }
    counts
        .iter()
        .map(|&c| ((c as u64 * u16::MAX as u64 + total as u64 / 2) / total as u64) as u16)
        .collect()
}

fn hsv_bin(r: u8, g: u8, b: u8) -> usize {
    let (r, g, b) = (r as f32 / 255.0, g as f32 / 255.0, b as f32 / 255.0);
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let delta = max - min;
    let v = max;
    let s = if max > 0.0 { delta / max } else { 0.0 };

    let quantize = |x: f32, bins: usize| ((x * bins as f32) as usize).min(bins - 1);
    let v_bin = quantize(v, HIST_V);
    if s < GREY_SATURATION {
        return v_bin;
    }

    // Hue in [0, 1).
    let h = if max == r {
        ((g - b) / delta).rem_euclid(6.0)
    } else if max == g {
        (b - r) / delta + 2.0
    } else {
        (r - g) / delta + 4.0
    } / 6.0;

    (quantize(h, HIST_H) * HIST_S + quantize(s, HIST_S)) * HIST_V + v_bin
}

/// Histogram stored as sqrt of the normalised bins, so the Bhattacharyya
/// coefficient is a dot product and L2 in this space is √2 · Hellinger.
#[derive(Clone, Debug)]
pub struct Histogram {
    sqrt_bins: Vec<f32>,
}

impl Histogram {
    pub fn from_blob(blob: &[u8]) -> Option<Self> {
        if blob.len() != HIST_BINS * 2 {
            return None;
        }
        let bins: Vec<f32> = blob
            .as_chunks::<2>()
            .0
            .iter()
            .map(|&c| u16::from_le_bytes(c) as f32)
            .collect();
        Self::from_weights(&bins)
    }

    pub fn from_weights(bins: &[f32]) -> Option<Self> {
        let total: f32 = bins.iter().sum();
        if total <= 0.0 {
            return None;
        }
        Some(Self {
            sqrt_bins: bins.iter().map(|b| (b / total).sqrt()).collect(),
        })
    }

    /// Hellinger distance in [0, 1].
    pub fn distance(&self, other: &Histogram) -> f32 {
        let bc: f32 = self
            .sqrt_bins
            .iter()
            .zip(&other.sqrt_bins)
            .map(|(a, b)| a * b)
            .sum();
        (1.0 - bc).max(0.0).sqrt()
    }

    pub fn embedding(&self) -> &[f32] {
        &self.sqrt_bins
    }
}

#[derive(Clone, Debug)]
pub struct ImageFeatures {
    pub id: Uuid,
    pub hashes64: Vec<u64>,
    pub hash256: Option<[u64; 4]>,
    pub hist: Option<Histogram>,
}

impl ImageFeatures {
    pub fn from_parts(
        id: Uuid,
        hashes64: [Option<i64>; 6],
        hash256: Option<&[u8]>,
        histogram: Option<&[u8]>,
    ) -> Self {
        Self {
            id,
            hashes64: hashes64.into_iter().flatten().map(|h| h as u64).collect(),
            hash256: hash256.and_then(parse_hash256),
            hist: histogram.and_then(Histogram::from_blob),
        }
    }

    pub fn from_perceptual(id: Uuid, features: &PerceptualFeatures) -> Self {
        Self::from_parts(
            id,
            features.hashes64,
            features.hash256.as_ref().map(|h| h.as_slice()),
            features.histogram_blob().as_deref(),
        )
    }

    pub fn has_hash(&self) -> bool {
        !self.hashes64.is_empty() || self.hash256.is_some()
    }
}

fn parse_hash256(bytes: &[u8]) -> Option<[u64; 4]> {
    if bytes.len() != 32 {
        return None;
    }
    let mut words = [0u64; 4];
    for (word, &chunk) in words.iter_mut().zip(bytes.as_chunks::<8>().0) {
        *word = u64::from_be_bytes(chunk);
    }
    Some(words)
}

pub fn hamming<const W: usize>(a: &[u64; W], b: &[u64; W]) -> u32 {
    a.iter().zip(b).map(|(x, y)| (x ^ y).count_ones()).sum()
}

/// Minimum Hamming distance across all 64-bit hash pairs between two images.
pub fn min_distance(hashset_a: &[u64], hashset_b: &[u64]) -> Option<u32> {
    let mut best: Option<u32> = None;
    for a in hashset_a {
        for b in hashset_b {
            let d = (a ^ b).count_ones();
            if d == 0 {
                return Some(0);
            }
            if best.is_none_or(|cur| d < cur) {
                best = Some(d);
            }
        }
    }
    best
}

#[derive(Clone, Copy, Debug)]
pub struct MatchParams {
    /// 64-bit hashes match when distance < threshold64.
    pub threshold64: u32,
    /// 256-bit hash matches when distance < threshold256.
    pub threshold256: u32,
    /// Histogram veto: pairs further apart than this never match.
    pub color_threshold: f32,
    /// Pairs at most this far apart in colour may use the rescue threshold.
    pub color_tight: f32,
    /// Hash threshold multiplier for colour-tight pairs.
    pub rescue_factor: f32,
}

impl MatchParams {
    /// Edge weight ρ for a matching pair, `None` if they don't match.
    ///
    /// ρ is the hash distance as a fraction of its threshold, taking the better
    /// of the 64-bit (crop-aware) and 256-bit paths, so ρ < 1 is a strict match.
    pub fn match_weight(&self, a: &ImageFeatures, b: &ImageFeatures) -> Option<f32> {
        let ratio = |d: u32, t: u32| {
            if t == 0 {
                f32::INFINITY
            } else {
                d as f32 / t as f32
            }
        };
        let rho64 = min_distance(&a.hashes64, &b.hashes64).map(|d| ratio(d, self.threshold64));
        let rho256 = match (&a.hash256, &b.hash256) {
            (Some(x), Some(y)) => Some(ratio(hamming(x, y), self.threshold256)),
            _ => None,
        };
        let rho = match (rho64, rho256) {
            (Some(x), Some(y)) => x.min(y),
            (Some(x), None) | (None, Some(x)) => x,
            (None, None) => return None,
        };

        let color = match (&a.hist, &b.hist) {
            (Some(x), Some(y)) => Some(x.distance(y)),
            _ => None,
        };
        if color.is_some_and(|c| c > self.color_threshold) {
            return None;
        }

        if rho < 1.0 {
            return Some(rho);
        }
        if color.is_some_and(|c| c <= self.color_tight) && rho < self.rescue_factor {
            return Some(rho);
        }
        None
    }
}

/// Distance stored in `cluster_members.hamming_distance`, kept on the 64-bit scale.
pub fn stored_distance(a: &ImageFeatures, b: &ImageFeatures) -> Option<u32> {
    let d64 = min_distance(&a.hashes64, &b.hashes64);
    let d256 = match (&a.hash256, &b.hash256) {
        (Some(x), Some(y)) => Some((hamming(x, y) + 2) / 4),
        _ => None,
    };
    match (d64, d256) {
        (Some(x), Some(y)) => Some(x.min(y)),
        (x, y) => x.or(y),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hist(bins: &[(usize, f32)]) -> Histogram {
        let mut w = vec![0.0; HIST_BINS];
        for &(i, v) in bins {
            w[i] = v;
        }
        Histogram::from_weights(&w).unwrap()
    }

    fn image(h64: u64, h256: [u64; 4], hist: Histogram) -> ImageFeatures {
        ImageFeatures {
            id: Uuid::nil(),
            hashes64: vec![h64],
            hash256: Some(h256),
            hist: Some(hist),
        }
    }

    const PARAMS: MatchParams = MatchParams {
        threshold64: 10,
        threshold256: 40,
        color_threshold: 0.35,
        color_tight: 0.12,
        rescue_factor: 1.5,
    };

    #[test]
    fn hellinger_bounds() {
        let a = hist(&[(0, 1.0), (5, 3.0)]);
        let b = hist(&[(7, 1.0)]);
        assert!(a.distance(&a) < 1e-3);
        assert!((a.distance(&b) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn blob_roundtrip() {
        let rgba: Vec<u8> = [[255, 0, 0, 255], [0, 0, 255, 255], [128, 128, 128, 255]]
            .iter()
            .flatten()
            .copied()
            .collect();
        let bins = build_histogram(&rgba);
        assert_eq!(bins.len(), HIST_BINS);
        assert_eq!(bins.iter().filter(|&&b| b > 0).count(), 3);
        let blob: Vec<u8> = bins.iter().flat_map(|b| b.to_le_bytes()).collect();
        let h = Histogram::from_blob(&blob).unwrap();
        assert!(h.distance(&h) < 1e-3);
    }

    #[test]
    fn greys_share_hue_bin() {
        assert_eq!(hsv_bin(200, 200, 200), hsv_bin(200, 205, 195));
        assert_ne!(hsv_bin(255, 0, 0), hsv_bin(0, 0, 255));
    }

    #[test]
    fn match_rule_branches() {
        let base_hist = hist(&[(0, 1.0), (1, 1.0)]);
        let near_hist = hist(&[(0, 1.0), (1, 1.1)]);
        let mid_hist = hist(&[(0, 1.0), (1, 1.0), (2, 0.35)]);
        let far_hist = hist(&[(9, 1.0)]);
        let a = image(0, [0; 4], base_hist);

        // Strict: 64-bit distance 5 < 10.
        let strict = image(0b11111, [!0; 4], mid_hist.clone());
        assert_eq!(PARAMS.match_weight(&a, &strict), Some(0.5));

        // Veto: identical hashes, different colours.
        let vetoed = image(0, [0; 4], far_hist);
        assert_eq!(PARAMS.match_weight(&a, &vetoed), None);

        // Rescue: 256-bit distance 50 (ρ = 1.25), colours nearly identical.
        let rescue_hash = [(1 << 50) - 1, 0, 0, 0];
        let rescued = image(!0, rescue_hash, near_hist);
        assert_eq!(PARAMS.match_weight(&a, &rescued), Some(1.25));

        // Same hashes, colour only moderately close: no rescue.
        let not_rescued = image(!0, rescue_hash, mid_hist);
        assert!(PARAMS.match_weight(&a, &not_rescued).is_none());
    }

    #[test]
    fn stored_distance_uses_64_bit_scale() {
        let h = hist(&[(0, 1.0)]);
        let a = image(0, [0; 4], h.clone());
        let b = image(!0, [0xFF, 0, 0, 0], h);
        assert_eq!(stored_distance(&a, &b), Some(2));
    }
}
