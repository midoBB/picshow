//! Multi-index hashing (Norouzi et al.) for Hamming range queries.
//!
//! Each code is split into 16-bit chunks, one lookup table per chunk. If two
//! codes are within distance r, by pigeonhole at least one of their m chunks is
//! within ⌊r/m⌋, so probing every chunk value in that radius finds all matches.

const CHUNK_BITS: usize = 16;
const CHUNK_VALUES: usize = 1 << CHUNK_BITS;
const CHUNKS_PER_WORD: usize = 64 / CHUNK_BITS;

/// One chunk's table in CSR form: codes with chunk value v are
/// `items[offsets[v]..offsets[v + 1]]`.
struct ChunkTable {
    offsets: Vec<u32>,
    items: Vec<u32>,
}

pub struct MultiIndexHamming<const W: usize> {
    codes: Vec<[u64; W]>,
    owners: Vec<usize>,
    tables: Vec<ChunkTable>,
    /// Per-code "last seen in query n" stamps for deduplication.
    seen: Vec<u32>,
    query_epoch: u32,
}

fn chunk<const W: usize>(code: &[u64; W], c: usize) -> usize {
    let word = code[c / CHUNKS_PER_WORD];
    ((word >> ((c % CHUNKS_PER_WORD) * CHUNK_BITS)) & (CHUNK_VALUES as u64 - 1)) as usize
}

/// All 16-bit masks with popcount ≤ radius.
fn probe_masks(radius: u32) -> Vec<u16> {
    (0..CHUNK_VALUES as u32)
        .filter(|m| m.count_ones() <= radius)
        .map(|m| m as u16)
        .collect()
}

impl<const W: usize> MultiIndexHamming<W> {
    const CHUNKS: usize = W * CHUNKS_PER_WORD;

    /// Build from (code, owner) pairs. An owner may contribute several codes.
    pub fn build(entries: Vec<([u64; W], usize)>) -> Self {
        let (codes, owners): (Vec<_>, Vec<_>) = entries.into_iter().unzip();
        let tables = (0..Self::CHUNKS)
            .map(|c| {
                let mut offsets = vec![0u32; CHUNK_VALUES + 1];
                for code in &codes {
                    offsets[chunk(code, c) + 1] += 1;
                }
                for v in 0..CHUNK_VALUES {
                    offsets[v + 1] += offsets[v];
                }
                let mut cursor = offsets.clone();
                let mut items = vec![0u32; codes.len()];
                for (i, code) in codes.iter().enumerate() {
                    let slot = &mut cursor[chunk(code, c)];
                    items[*slot as usize] = i as u32;
                    *slot += 1;
                }
                ChunkTable { offsets, items }
            })
            .collect();
        let seen = vec![0; codes.len()];
        Self {
            codes,
            owners,
            tables,
            seen,
            query_epoch: 0,
        }
    }

    /// Call `visit(owner)` for every code within Hamming distance `radius` of
    /// `query`. An owner is visited once per matching code.
    pub fn range_query(&mut self, query: &[u64; W], radius: u32, mut visit: impl FnMut(usize)) {
        if self.codes.is_empty() {
            return;
        }
        self.query_epoch = self.query_epoch.wrapping_add(1);
        if self.query_epoch == 0 {
            self.seen.fill(0);
            self.query_epoch = 1;
        }
        let masks = probe_masks(radius / Self::CHUNKS as u32);
        for (c, table) in self.tables.iter().enumerate() {
            let q = chunk(query, c);
            for &mask in &masks {
                let v = q ^ mask as usize;
                let range = table.offsets[v] as usize..table.offsets[v + 1] as usize;
                for &item in &table.items[range] {
                    let item = item as usize;
                    if self.seen[item] == self.query_epoch {
                        continue;
                    }
                    self.seen[item] = self.query_epoch;
                    if super::features::hamming(&self.codes[item], query) <= radius {
                        visit(self.owners[item]);
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::features::hamming;
    use super::*;

    fn xorshift(s: &mut u64) -> u64 {
        *s ^= *s << 13;
        *s ^= *s >> 7;
        *s ^= *s << 17;
        *s
    }

    /// Random codes clustered around a few centres, so small radii have hits.
    fn codes<const W: usize>(n: usize, seed: u64) -> Vec<[u64; W]> {
        let mut s = seed;
        let centres: Vec<[u64; W]> = (0..8)
            .map(|_| std::array::from_fn(|_| xorshift(&mut s)))
            .collect();
        (0..n)
            .map(|i| {
                let mut code = centres[i % centres.len()];
                for _ in 0..(xorshift(&mut s) % (W as u64 * 24)) {
                    let bit = xorshift(&mut s) as usize % (W * 64);
                    code[bit / 64] ^= 1 << (bit % 64);
                }
                code
            })
            .collect()
    }

    fn matches_brute_force<const W: usize>(radii: &[u32]) {
        let codes = codes::<W>(600, 0x9E37_79B9_7F4A_7C15);
        let mut index =
            MultiIndexHamming::build(codes.iter().copied().zip(0..codes.len()).collect());
        for &r in radii {
            for q in codes.iter().step_by(37) {
                let mut got = Vec::new();
                index.range_query(q, r, |o| got.push(o));
                got.sort_unstable();
                let want: Vec<usize> = (0..codes.len())
                    .filter(|&i| hamming(&codes[i], q) <= r)
                    .collect();
                assert_eq!(got, want, "W={W} r={r}");
            }
        }
    }

    #[test]
    fn range_query_64_matches_brute_force() {
        matches_brute_force::<1>(&[0, 10, 40, 60]);
    }

    #[test]
    fn range_query_256_matches_brute_force() {
        matches_brute_force::<4>(&[0, 10, 40, 60]);
    }

    #[test]
    fn owners_with_several_codes() {
        let mut index = MultiIndexHamming::<1>::build(vec![([0], 7), ([!0], 7), ([0xF], 3)]);
        let mut got = Vec::new();
        index.range_query(&[!0], 2, |o| got.push(o));
        assert_eq!(got, vec![7]);
    }
}
