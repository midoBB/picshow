use std::collections::{HashMap, HashSet};

use super::features::{ImageFeatures, MatchParams, HIST_BINS};
use super::hnsw::Hnsw;
use super::mih::MultiIndexHamming;

/// Symmetric adjacency list of matching pairs; each row is sorted by neighbour
/// and weighted by ρ (see `MatchParams::match_weight`).
pub struct MatchGraph {
    pub adjacency: Vec<Vec<(usize, f32)>>,
}

impl MatchGraph {
    pub fn len(&self) -> usize {
        self.adjacency.len()
    }

    pub fn neighbors(&self, i: usize) -> &[(usize, f32)] {
        &self.adjacency[i]
    }

    pub fn weight(&self, i: usize, j: usize) -> Option<f32> {
        let row = &self.adjacency[i];
        row.binary_search_by_key(&j, |&(n, _)| n)
            .ok()
            .map(|pos| row[pos].1)
    }

    pub fn from_edges(n: usize, edges: impl IntoIterator<Item = (usize, usize, f32)>) -> Self {
        let mut adjacency = vec![Vec::new(); n];
        for (i, j, w) in edges {
            adjacency[i].push((j, w));
            adjacency[j].push((i, w));
        }
        for row in &mut adjacency {
            row.sort_unstable_by_key(|&(n, _)| n);
        }
        Self { adjacency }
    }
}

pub struct UnionFind {
    parent: Vec<usize>,
}

impl UnionFind {
    pub fn new(n: usize) -> Self {
        Self {
            parent: (0..n).collect(),
        }
    }

    pub fn find(&mut self, mut x: usize) -> usize {
        while self.parent[x] != x {
            self.parent[x] = self.parent[self.parent[x]];
            x = self.parent[x];
        }
        x
    }

    pub fn union(&mut self, a: usize, b: usize) -> Option<usize> {
        let (ra, rb) = (self.find(a), self.find(b));
        if ra == rb {
            return None;
        }
        self.parent[rb] = ra;
        Some(ra)
    }
}

/// Find every matching pair without comparing all pairs.
///
/// Strict matches (ρ < 1) need a hash within threshold, which MIH finds
/// exactly. Rescue matches need near-identical colour, so they are drawn from
/// each image's `hnsw_k` colour-nearest neighbours.
pub fn build_candidate_graph(
    images: &[ImageFeatures],
    params: &MatchParams,
    hnsw_k: usize,
) -> MatchGraph {
    let n = images.len();

    let mut mih64 = MultiIndexHamming::<1>::build(
        images
            .iter()
            .enumerate()
            .flat_map(|(i, img)| img.hashes64.iter().map(move |&h| ([h], i)))
            .collect(),
    );
    let mut mih256 = MultiIndexHamming::<4>::build(
        images
            .iter()
            .enumerate()
            .filter_map(|(i, img)| img.hash256.map(|h| (h, i)))
            .collect(),
    );

    // Identical embeddings share one node: HNSW's neighbour-diversity rule
    // ties on duplicates and would prune every link out of a duplicate group.
    let mut hnsw = Hnsw::new(HIST_BINS);
    let mut hnsw_owners: Vec<Vec<usize>> = Vec::new();
    if hnsw_k > 0 {
        let mut node_of: HashMap<Vec<u32>, usize> = HashMap::new();
        for (i, img) in images.iter().enumerate() {
            if let Some(hist) = &img.hist {
                let key = hist.embedding().iter().map(|x| x.to_bits()).collect();
                let node = *node_of.entry(key).or_insert_with(|| {
                    hnsw.insert(hist.embedding());
                    hnsw_owners.push(Vec::new());
                    hnsw_owners.len() - 1
                });
                hnsw_owners[node].push(i);
            }
        }
    }

    // Thresholds are exclusive, so the inclusive search radius is one less.
    let radius64 = params.threshold64.checked_sub(1);
    let radius256 = params.threshold256.checked_sub(1);

    let mut pairs: HashSet<(usize, usize)> = HashSet::new();
    let mut add = |i: usize, j: usize| {
        if i != j {
            pairs.insert((i.min(j), i.max(j)));
        }
    };

    for (i, img) in images.iter().enumerate() {
        if let Some(r) = radius64 {
            for &h in &img.hashes64 {
                mih64.range_query(&[h], r, |j| add(i, j));
            }
        }
        if let (Some(r), Some(h)) = (radius256, &img.hash256) {
            mih256.range_query(h, r, |j| add(i, j));
        }
        if let (true, Some(hist)) = (hnsw_k > 0, &img.hist) {
            for (node, _) in hnsw.search(hist.embedding(), hnsw_k + 1) {
                for &j in &hnsw_owners[node as usize] {
                    add(i, j);
                }
            }
        }
    }

    MatchGraph::from_edges(
        n,
        pairs.into_iter().filter_map(|(i, j)| {
            params
                .match_weight(&images[i], &images[j])
                .map(|w| (i, j, w))
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::super::features::Histogram;
    use super::*;
    use uuid::Uuid;

    const PARAMS: MatchParams = MatchParams {
        threshold64: 10,
        threshold256: 40,
        color_threshold: 0.35,
        color_tight: 0.12,
        rescue_factor: 1.5,
    };

    fn image(h64: u64, h256: [u64; 4], hist_bin: usize) -> ImageFeatures {
        let mut w = vec![0.01; HIST_BINS];
        w[hist_bin] = 1.0;
        ImageFeatures {
            id: Uuid::nil(),
            hashes64: vec![h64],
            hash256: Some(h256),
            hist: Histogram::from_weights(&w),
        }
    }

    #[test]
    fn matches_brute_force() {
        let mut s = 0xDEAD_BEEF_u64;
        let mut next = || {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s
        };
        let base: Vec<(u64, [u64; 4])> = (0..20)
            .map(|_| (next(), [next(), next(), next(), next()]))
            .collect();
        let images: Vec<ImageFeatures> = (0..300)
            .map(|i| {
                let (mut h64, mut h256) = base[i % base.len()];
                for _ in 0..(next() % 14) {
                    h64 ^= 1 << (next() % 64);
                }
                for _ in 0..(next() % 60) {
                    let bit = next() % 256;
                    h256[(bit / 64) as usize] ^= 1 << (bit % 64);
                }
                image(h64, h256, (next() % 3) as usize)
            })
            .collect();

        // k ≥ n makes HNSW exhaustive, so the graph must equal brute force.
        let graph = build_candidate_graph(&images, &PARAMS, images.len());
        for i in 0..images.len() {
            for j in 0..images.len() {
                let want = if i == j {
                    None
                } else {
                    PARAMS.match_weight(&images[i], &images[j])
                };
                assert_eq!(graph.weight(i, j), want, "pair ({i}, {j})");
            }
        }
    }
}
