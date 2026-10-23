//! Hierarchical navigable small world graph (Malkov & Yashunin) for
//! approximate k-NN under squared L2.

use std::cmp::{Ordering, Reverse};
use std::collections::{BinaryHeap, HashSet};

#[derive(Clone, Copy, PartialEq)]
struct Scored {
    dist: f32,
    node: u32,
}

impl Eq for Scored {}

impl PartialOrd for Scored {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Scored {
    fn cmp(&self, other: &Self) -> Ordering {
        self.dist
            .total_cmp(&other.dist)
            .then(self.node.cmp(&other.node))
    }
}

pub struct Hnsw {
    dim: usize,
    m: usize,
    ef_construction: usize,
    ef_search: usize,
    level_mult: f64,
    vectors: Vec<f32>,
    /// links[node][layer] = neighbours of node on that layer.
    links: Vec<Vec<Vec<u32>>>,
    entry: Option<u32>,
    rng: u64,
}

fn sq_l2(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| (x - y) * (x - y)).sum()
}

impl Hnsw {
    pub fn new(dim: usize) -> Self {
        let m = 16;
        Self {
            dim,
            m,
            ef_construction: 100,
            ef_search: 64,
            level_mult: 1.0 / (m as f64).ln(),
            vectors: Vec::new(),
            links: Vec::new(),
            entry: None,
            // Fixed seed: identical inputs build identical graphs.
            rng: 0x2545_F491_4F6C_DD1D,
        }
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.links.len()
    }

    fn vector(&self, node: u32) -> &[f32] {
        let start = node as usize * self.dim;
        &self.vectors[start..start + self.dim]
    }

    fn random_level(&mut self) -> usize {
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        let uniform = ((self.rng >> 11) as f64 + 1.0) / (1u64 << 53) as f64;
        (-uniform.ln() * self.level_mult) as usize
    }

    fn max_links(&self, layer: usize) -> usize {
        if layer == 0 {
            self.m * 2
        } else {
            self.m
        }
    }

    fn top_layer(&self) -> usize {
        self.entry.map_or(0, |e| self.links[e as usize].len() - 1)
    }

    /// Best-first search of one layer; returns up to `ef` nearest, closest first.
    fn search_layer(
        &self,
        query: &[f32],
        entries: &[Scored],
        ef: usize,
        layer: usize,
    ) -> Vec<Scored> {
        let mut visited: HashSet<u32> = entries.iter().map(|s| s.node).collect();
        let mut candidates: BinaryHeap<Reverse<Scored>> =
            entries.iter().copied().map(Reverse).collect();
        let mut results: BinaryHeap<Scored> = entries.iter().copied().collect();

        while let Some(Reverse(current)) = candidates.pop() {
            if results.len() >= ef && current.dist > results.peek().unwrap().dist {
                break;
            }
            for &nbr in &self.links[current.node as usize][layer] {
                if !visited.insert(nbr) {
                    continue;
                }
                let dist = sq_l2(query, self.vector(nbr));
                if results.len() < ef || dist < results.peek().unwrap().dist {
                    let scored = Scored { dist, node: nbr };
                    candidates.push(Reverse(scored));
                    results.push(scored);
                    if results.len() > ef {
                        results.pop();
                    }
                }
            }
        }
        results.into_sorted_vec()
    }

    /// Keep candidates that are closer to the base than to any already kept
    /// neighbour, which preserves links across clusters; then top up by distance.
    fn select_neighbors(&self, candidates: &[Scored], limit: usize) -> Vec<u32> {
        let mut kept: Vec<Scored> = Vec::with_capacity(limit);
        let mut skipped = Vec::new();
        for &c in candidates {
            if kept.len() >= limit {
                break;
            }
            let diverse = kept
                .iter()
                .all(|k| sq_l2(self.vector(c.node), self.vector(k.node)) > c.dist);
            if diverse {
                kept.push(c);
            } else {
                skipped.push(c);
            }
        }
        for c in skipped {
            if kept.len() >= limit {
                break;
            }
            kept.push(c);
        }
        kept.into_iter().map(|s| s.node).collect()
    }

    fn greedy_descend(&self, query: &[f32], from_layer: usize, to_layer: usize) -> Option<Scored> {
        let entry = self.entry?;
        let mut best = Scored {
            dist: sq_l2(query, self.vector(entry)),
            node: entry,
        };
        for layer in (to_layer..=from_layer).rev() {
            best = self.search_layer(query, &[best], 1, layer)[0];
        }
        Some(best)
    }

    pub fn insert(&mut self, vector: &[f32]) -> u32 {
        assert_eq!(vector.len(), self.dim);
        let node = self.links.len() as u32;
        let level = self.random_level();
        self.vectors.extend_from_slice(vector);
        self.links.push(vec![Vec::new(); level + 1]);

        let Some(entry) = self.entry else {
            self.entry = Some(node);
            return node;
        };
        let top = self.top_layer();
        let mut entries = vec![if level < top {
            self.greedy_descend(vector, top, level + 1).unwrap()
        } else {
            Scored {
                dist: sq_l2(vector, self.vector(entry)),
                node: entry,
            }
        }];

        for layer in (0..=level.min(top)).rev() {
            let found = self.search_layer(vector, &entries, self.ef_construction, layer);
            let neighbors = self.select_neighbors(&found, self.m);
            let limit = self.max_links(layer);
            for &nbr in &neighbors {
                let nbr_links = &mut self.links[nbr as usize][layer];
                nbr_links.push(node);
                if nbr_links.len() > limit {
                    let base = self.vector(nbr);
                    let mut scored: Vec<Scored> = self.links[nbr as usize][layer]
                        .iter()
                        .map(|&n| Scored {
                            dist: sq_l2(base, self.vector(n)),
                            node: n,
                        })
                        .collect();
                    scored.sort_unstable();
                    let pruned = self.select_neighbors(&scored, limit);
                    self.links[nbr as usize][layer] = pruned;
                }
            }
            self.links[node as usize][layer] = neighbors;
            entries = found;
        }

        if level > top {
            self.entry = Some(node);
        }
        node
    }

    /// Approximate k nearest neighbours as (node, squared L2), closest first.
    pub fn search(&self, query: &[f32], k: usize) -> Vec<(u32, f32)> {
        let Some(entry) = self.greedy_descend(query, self.top_layer(), 1) else {
            return Vec::new();
        };
        let mut found = self.search_layer(query, &[entry], self.ef_search.max(k), 0);
        found.truncate(k);
        found.into_iter().map(|s| (s.node, s.dist)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recall_against_brute_force() {
        const N: usize = 2000;
        const DIM: usize = 128;
        const K: usize = 10;
        let mut s = 0x1234_5678_9ABC_DEF1u64;
        let mut next = || {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            (s >> 40) as f32 / (1u64 << 24) as f32
        };
        let data: Vec<Vec<f32>> = (0..N).map(|_| (0..DIM).map(|_| next()).collect()).collect();

        let mut index = Hnsw::new(DIM);
        for v in &data {
            index.insert(v);
        }
        assert_eq!(index.len(), N);

        let mut hits = 0;
        let queries = (0..N).step_by(20);
        let n_queries = queries.len();
        for q in queries {
            let mut exact: Vec<(usize, f32)> =
                (0..N).map(|i| (i, sq_l2(&data[q], &data[i]))).collect();
            exact.sort_by(|a, b| a.1.total_cmp(&b.1));
            let truth: HashSet<u32> = exact[..K].iter().map(|&(i, _)| i as u32).collect();
            hits += index
                .search(&data[q], K)
                .iter()
                .filter(|(n, _)| truth.contains(n))
                .count();
        }
        let recall = hits as f64 / (n_queries * K) as f64;
        assert!(recall >= 0.95, "recall@{K} = {recall}");
    }

    #[test]
    fn tight_groups_stay_connected() {
        // Groups much larger than M with near-identical members, like burst shots.
        let mut s = 0x0BAD_5EED_u64;
        let mut jitter = || {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            (s >> 40) as f32 / (1u64 << 24) as f32 * 1e-4
        };
        let mut index = Hnsw::new(4);
        for g in 0..3 {
            for _ in 0..100 {
                let mut v = [0.0f32; 4];
                v[g] = 1.0;
                for x in &mut v {
                    *x += jitter();
                }
                index.insert(&v);
            }
        }
        for q in [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
        ] {
            let found = index.search(&q, 300);
            let groups: HashSet<u32> = found.iter().map(|&(n, _)| n / 100).collect();
            assert_eq!(groups.len(), 3, "query {q:?} reached groups {groups:?}");
        }
    }

    #[test]
    fn empty_and_single() {
        let mut index = Hnsw::new(2);
        assert!(index.search(&[0.0, 0.0], 3).is_empty());
        index.insert(&[1.0, 1.0]);
        assert_eq!(index.search(&[0.0, 0.0], 3), vec![(0, 2.0)]);
    }
}
