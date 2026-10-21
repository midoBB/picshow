use anyhow::Result;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tracing::{debug, info, warn};
use uuid::Uuid;

use crate::config::{AppConfig, ClusterAlgorithm};
use crate::data::repository::MediaRepository;
use crate::files::phash::{HASH_VERSION, UNRELIABLE_HASH};

pub struct ClusterBuilder {
    repository: Arc<MediaRepository>,
    algorithm: ClusterAlgorithm,
    hamming_threshold: u32,
    dbscan_min_points: usize,
    kmeans_k: usize,
}

#[derive(Debug)]
pub struct ClusterStats {
    pub total_images: usize,
    pub images_with_hash: usize,
    pub clusters_created: usize,
    pub images_clustered: usize,
}

const CLUSTERING_PARAMS_KEY: &str = "clustering_params";

/// Extra distance charged when two images only match through a crop hash. A crop match is
/// weaker evidence than a whole-image match, so it has to be closer to count.
const CROP_PENALTY: u32 = 2;

/// Reported for members that share no comparable hash with their cluster's representative.
const NO_DISTANCE: u32 = 64;

/// Hash slots in storage order: whole image first, then the crop variants (see `files::phash`).
/// A slot is 0 when the hash is missing or unreliable.
type Slots = [u64; 6];

#[derive(Clone, PartialEq)]
enum VisitStatus {
    Unvisited,
    Noise,
    Clustered(usize),
}

fn serialize_clustering_params(
    algo: ClusterAlgorithm,
    threshold: u32,
    min_pts: usize,
    k: usize,
) -> String {
    format!(
        "{:?},{},{},{},v{}",
        algo, threshold, min_pts, k, HASH_VERSION
    )
}

// --- Distance helpers ---

/// Distance between two images: whole image vs whole image, or (with a penalty) the whole
/// of one image vs a crop of the other, which is what a cropped copy looks like. Crop vs
/// crop pairs are not compared: different regions of different photos (two skies, two
/// walls) match far too easily.
#[inline(always)]
fn pair_distance(a: &Slots, b: &Slots) -> Option<u32> {
    let mut best: Option<u32> = None;
    let mut consider = |x: u64, y: u64, penalty: u32| {
        if x != 0 && y != 0 {
            let d = (x ^ y).count_ones() + penalty;
            if best.is_none_or(|cur| d < cur) {
                best = Some(d);
            }
        }
    };
    consider(a[0], b[0], 0);
    for slot in 1..a.len() {
        consider(a[0], b[slot], CROP_PENALTY);
        consider(a[slot], b[0], CROP_PENALTY);
    }
    best
}

#[inline(always)]
fn row_neighbours_impl(hashes: &[Slots], i: usize, threshold: u32, out: &mut Vec<(u32, u32, u32)>) {
    let a = &hashes[i];
    for (j, b) in hashes.iter().enumerate().skip(i + 1) {
        if let Some(d) = pair_distance(a, b) {
            if d < threshold {
                out.push((i as u32, j as u32, d));
            }
        }
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "popcnt")]
unsafe fn row_neighbours_popcnt(
    hashes: &[Slots],
    i: usize,
    threshold: u32,
    out: &mut Vec<(u32, u32, u32)>,
) {
    row_neighbours_impl(hashes, i, threshold, out)
}

/// Release builds target baseline x86-64, where `count_ones` is a slow bit-twiddling
/// fallback; use the POPCNT instruction when the CPU has it.
fn row_neighbours(hashes: &[Slots], i: usize, threshold: u32, out: &mut Vec<(u32, u32, u32)>) {
    #[cfg(target_arch = "x86_64")]
    if std::is_x86_feature_detected!("popcnt") {
        // SAFETY: the CPU supports POPCNT, checked just above.
        return unsafe { row_neighbours_popcnt(hashes, i, threshold, out) };
    }
    row_neighbours_impl(hashes, i, threshold, out)
}

/// Every pair of images closer than `threshold`, as an adjacency list sorted by neighbour.
/// This is the only quadratic step; it is spread over all cores.
fn neighbour_graph(hashes: &[Slots], threshold: u32) -> Vec<Vec<(u32, u32)>> {
    let n = hashes.len();
    let threads = std::thread::available_parallelism()
        .map(|x| x.get())
        .unwrap_or(1);
    let next_row = AtomicUsize::new(0);
    const ROWS_PER_TASK: usize = 64;

    let edges: Vec<(u32, u32, u32)> = std::thread::scope(|s| {
        let workers: Vec<_> = (0..threads)
            .map(|_| {
                s.spawn(|| {
                    let mut out = Vec::new();
                    loop {
                        let start = next_row.fetch_add(ROWS_PER_TASK, Ordering::Relaxed);
                        if start >= n {
                            break out;
                        }
                        for i in start..(start + ROWS_PER_TASK).min(n) {
                            row_neighbours(hashes, i, threshold, &mut out);
                        }
                    }
                })
            })
            .collect();
        workers
            .into_iter()
            .flat_map(|w| w.join().expect("neighbour worker panicked"))
            .collect()
    });

    let mut graph: Vec<Vec<(u32, u32)>> = vec![Vec::new(); n];
    for (i, j, d) in edges {
        graph[i as usize].push((j, d));
        graph[j as usize].push((i, d));
    }
    for adj in &mut graph {
        adj.sort_unstable();
    }
    graph
}

fn edge(graph: &[Vec<(u32, u32)>], a: usize, b: usize) -> Option<u32> {
    let adj = &graph[a];
    adj.binary_search_by_key(&(b as u32), |&(j, _)| j)
        .ok()
        .map(|idx| adj[idx].1)
}

fn find(parent: &mut [usize], mut x: usize) -> usize {
    while parent[x] != x {
        parent[x] = parent[parent[x]];
        x = parent[x];
    }
    x
}

impl ClusterBuilder {
    pub fn new(repository: Arc<MediaRepository>, config: &AppConfig) -> Self {
        Self {
            repository,
            algorithm: config.cluster_algorithm,
            hamming_threshold: config.cluster_threshold,
            dbscan_min_points: config.cluster_dbscan_min_pts,
            kmeans_k: config.cluster_kmeans_k,
        }
    }

    // --- Public entry point ---

    pub async fn build_clusters(
        &self,
        force_rebuild: bool,
        save_state: bool,
    ) -> Result<ClusterStats> {
        let current_params = serialize_clustering_params(
            self.algorithm,
            self.hamming_threshold,
            self.dbscan_min_points,
            self.kmeans_k,
        );

        let params_changed = if !force_rebuild {
            if let Ok(Some(prev_params)) =
                self.repository.get_app_state(CLUSTERING_PARAMS_KEY).await
            {
                if prev_params != current_params {
                    info!(
                        "Clustering params changed: {} -> {}",
                        prev_params, current_params
                    );
                    true
                } else {
                    false
                }
            } else {
                true
            }
        } else {
            false
        };

        let should_force = force_rebuild || params_changed;

        if should_force && save_state {
            if let Err(e) = self
                .repository
                .set_app_state(CLUSTERING_PARAMS_KEY, &current_params)
                .await
            {
                warn!("Failed to save clustering params: {}", e);
            }
        }

        info!(
            "Starting cluster build (algo: {:?}, threshold: {}, min_pts: {}, k: {}, force: {})",
            self.algorithm,
            self.hamming_threshold,
            self.dbscan_min_points,
            self.kmeans_k,
            should_force
        );

        debug!("Cleaning up orphaned data");
        let (orphaned_members, orphaned_images) = self.repository.cleanup_orphaned_data().await?;
        if orphaned_members > 0 || orphaned_images > 0 {
            info!(
                "Cleaned up {} orphaned cluster members and {} orphaned images",
                orphaned_members, orphaned_images
            );
        }

        debug!("Fetching all perceptual hashes");
        let mut all_images = self.repository.get_all_perceptual_hashes().await?;
        let total_images = all_images.len();
        info!("Found {} images with perceptual hashes", total_images);

        if all_images.is_empty() {
            return Ok(ClusterStats {
                total_images: 0,
                images_with_hash: 0,
                clusters_created: 0,
                images_clustered: 0,
            });
        }

        // A stable order keeps the result (and so the incremental diff below) deterministic.
        all_images.sort_unstable_by_key(|(id, _)| *id);
        let ids: Vec<Uuid> = all_images.iter().map(|(id, _)| *id).collect();
        let hashes: Vec<Slots> = all_images
            .iter()
            .map(|(_, hs)| {
                let mut slots = [0u64; 6];
                for (slot, h) in slots.iter_mut().zip(hs) {
                    *slot = match *h {
                        UNRELIABLE_HASH => 0,
                        h => h as u64,
                    };
                }
                slots
            })
            .collect();
        drop(all_images);

        let params = ClusterParams {
            algorithm: self.algorithm,
            threshold: self.hamming_threshold,
            dbscan_min_points: self.dbscan_min_points,
            kmeans_k: self.kmeans_k,
        };
        let started = std::time::Instant::now();
        // CPU-bound; keep it off the async runtime's worker threads.
        let new_clusters: Vec<(Uuid, Vec<(Uuid, u32)>)> = tokio::task::spawn_blocking(move || {
            compute_clusters(&hashes, &params)
                .into_iter()
                .map(|members| {
                    let rep = ids[members[0].0];
                    let members = members.into_iter().map(|(i, d)| (ids[i], d)).collect();
                    (rep, members)
                })
                .collect()
        })
        .await?;
        debug!(
            "Computed {} clusters in {:?}",
            new_clusters.len(),
            started.elapsed()
        );

        if should_force {
            debug!("Force rebuild: atomically replacing all clusters");
            let (created, clustered) = self
                .repository
                .clear_and_create_clusters(&new_clusters)
                .await?;
            let stats = ClusterStats {
                total_images,
                images_with_hash: total_images,
                clusters_created: created,
                images_clustered: clustered,
            };
            info!(
                "Clustering complete: {} clusters / {} images / {} total (algo: {:?})",
                stats.clusters_created, stats.images_clustered, stats.total_images, self.algorithm
            );
            return Ok(stats);
        }

        debug!("Incremental rebuild: fetching existing clusters");
        let existing = self.repository.get_all_clusters_with_members().await?;
        let mut existing_by_member: HashMap<Uuid, usize> = HashMap::new();
        let existing_sets: Vec<HashSet<Uuid>> = existing
            .iter()
            .enumerate()
            .map(|(idx, ec)| {
                ec.members
                    .iter()
                    .map(|(id, _)| {
                        existing_by_member.insert(*id, idx);
                        *id
                    })
                    .collect()
            })
            .collect();

        let mut final_clusters_created = 0;
        let mut images_clustered = 0;
        let mut skipped = 0;

        for (representative_id, members_with_distances) in new_clusters {
            let member_ids: Vec<Uuid> = members_with_distances.iter().map(|(id, _)| *id).collect();

            let mut old_indices: Vec<usize> = member_ids
                .iter()
                .filter_map(|id| existing_by_member.get(id).copied())
                .collect();
            old_indices.sort_unstable();
            old_indices.dedup();

            let is_unchanged = old_indices.iter().any(|&idx| {
                existing[idx].representative_id == representative_id
                    && existing_sets[idx].len() == member_ids.len()
                    && member_ids.iter().all(|id| existing_sets[idx].contains(id))
            });

            if is_unchanged {
                debug!("Skipping unchanged cluster (rep: {})", representative_id);
                skipped += 1;
                images_clustered += member_ids.len();
                continue;
            }

            let old_cluster_ids: Vec<i64> = old_indices
                .iter()
                .map(|&idx| existing[idx].cluster_id)
                .collect();

            let db_cluster_id = if !old_cluster_ids.is_empty() {
                self.repository
                    .replace_clusters(&old_cluster_ids, representative_id, &members_with_distances)
                    .await?
            } else {
                self.repository
                    .create_cluster_with_members(representative_id, &members_with_distances)
                    .await?
            };

            final_clusters_created += 1;
            images_clustered += member_ids.len();

            debug!(
                "Created cluster {} with {} members",
                db_cluster_id,
                member_ids.len()
            );
        }

        let stats = ClusterStats {
            total_images,
            images_with_hash: total_images,
            clusters_created: final_clusters_created,
            images_clustered,
        };

        info!(
            "Clustering complete (incremental): {} created, {} unchanged, {} images clustered / {} total (algo: {:?})",
            final_clusters_created, skipped, images_clustered, total_images, self.algorithm
        );

        Ok(stats)
    }
}

#[derive(Clone, Copy)]
struct ClusterParams {
    algorithm: ClusterAlgorithm,
    threshold: u32,
    dbscan_min_points: usize,
    kmeans_k: usize,
}

/// Clusters of two or more images, as `(index, distance to representative)` with the
/// representative first and the rest closest-first.
fn compute_clusters(hashes: &[Slots], params: &ClusterParams) -> Vec<Vec<(usize, u32)>> {
    let groups = if params.algorithm == ClusterAlgorithm::Kmeans {
        cluster_kmeans(hashes, params.kmeans_k)
    } else {
        let graph = neighbour_graph(hashes, params.threshold);
        match params.algorithm {
            ClusterAlgorithm::Single => cluster_single(&graph),
            ClusterAlgorithm::Complete => cluster_complete(&graph),
            ClusterAlgorithm::Dbscan => cluster_dbscan(&graph, params.dbscan_min_points),
            ClusterAlgorithm::Kmeans => unreachable!(),
        }
    };

    groups
        .into_iter()
        .filter(|g| g.len() > 1)
        .map(|group| order_by_medoid(hashes, group))
        .collect()
}

/// Picks the member closest to all others as representative (rather than whichever image
/// happened to come first) and sorts the rest by their distance to it.
fn order_by_medoid(hashes: &[Slots], group: Vec<usize>) -> Vec<(usize, u32)> {
    let dist = |a: usize, b: usize| pair_distance(&hashes[a], &hashes[b]).unwrap_or(NO_DISTANCE);
    let rep = *group
        .iter()
        .min_by_key(|&&a| (group.iter().map(|&b| dist(a, b) as u64).sum::<u64>(), a))
        .expect("cluster is not empty");
    let mut members: Vec<(usize, u32)> = group
        .iter()
        .map(|&i| (i, if i == rep { 0 } else { dist(i, rep) }))
        .collect();
    members.sort_unstable_by_key(|&(i, d)| (i != rep, d, i));
    members
}

// ------------------------------------------------------------------
// Algorithm: Single-linkage (connected components of the neighbour graph)
// ------------------------------------------------------------------

fn cluster_single(graph: &[Vec<(u32, u32)>]) -> Vec<Vec<usize>> {
    let n = graph.len();
    let mut parent: Vec<usize> = (0..n).collect();
    for (i, adj) in graph.iter().enumerate() {
        for &(j, _) in adj {
            let (a, b) = (find(&mut parent, i), find(&mut parent, j as usize));
            if a != b {
                parent[a.max(b)] = a.min(b);
            }
        }
    }
    let mut groups: HashMap<usize, Vec<usize>> = HashMap::new();
    for i in 0..n {
        let root = find(&mut parent, i);
        groups.entry(root).or_default().push(i);
    }
    groups.into_values().collect()
}

// ------------------------------------------------------------------
// Algorithm: Complete-linkage (agglomerative, closest pairs merged first)
//
// Two groups merge only if every image in one is within the threshold of every image in
// the other, so chains of "each looks like the next" never pull unrelated shots together.
// ------------------------------------------------------------------

fn cluster_complete(graph: &[Vec<(u32, u32)>]) -> Vec<Vec<usize>> {
    let n = graph.len();
    let mut edges: Vec<(u32, usize, usize)> = graph
        .iter()
        .enumerate()
        .flat_map(|(i, adj)| {
            adj.iter()
                .filter(move |&&(j, _)| (j as usize) > i)
                .map(move |&(j, d)| (d, i, j as usize))
        })
        .collect();
    edges.sort_unstable();

    let mut parent: Vec<usize> = (0..n).collect();
    let mut members: Vec<Vec<usize>> = (0..n).map(|i| vec![i]).collect();
    for (_, i, j) in edges {
        let (a, b) = (find(&mut parent, i), find(&mut parent, j));
        if a == b {
            continue;
        }
        let fully_linked = members[a]
            .iter()
            .all(|&x| members[b].iter().all(|&y| edge(graph, x, y).is_some()));
        if !fully_linked {
            continue;
        }
        let (keep, gone) = if members[a].len() >= members[b].len() {
            (a, b)
        } else {
            (b, a)
        };
        let moved = std::mem::take(&mut members[gone]);
        members[keep].extend(moved);
        parent[gone] = keep;
    }
    members.into_iter().filter(|m| !m.is_empty()).collect()
}

// ------------------------------------------------------------------
// Algorithm: DBSCAN
// ------------------------------------------------------------------

fn cluster_dbscan(graph: &[Vec<(u32, u32)>], min_pts: usize) -> Vec<Vec<usize>> {
    let n = graph.len();
    let mut assigned: Vec<VisitStatus> = vec![VisitStatus::Unvisited; n];
    let mut raw_clusters: Vec<Vec<usize>> = Vec::new();

    for i in 0..n {
        if assigned[i] != VisitStatus::Unvisited {
            continue;
        }

        if graph[i].len() + 1 < min_pts {
            assigned[i] = VisitStatus::Noise;
            continue;
        }

        let cluster_id = raw_clusters.len();
        raw_clusters.push(vec![i]);
        assigned[i] = VisitStatus::Clustered(cluster_id);

        // BFS expansion
        let mut seeds: Vec<usize> = graph[i].iter().map(|&(j, _)| j as usize).collect();
        let mut in_seeds = vec![false; n];
        for &nbr in &seeds {
            in_seeds[nbr] = true;
        }

        while let Some(q) = seeds.pop() {
            if assigned[q] != VisitStatus::Unvisited {
                if assigned[q] == VisitStatus::Noise {
                    assigned[q] = VisitStatus::Clustered(cluster_id);
                    raw_clusters[cluster_id].push(q);
                }
                continue;
            }
            assigned[q] = VisitStatus::Clustered(cluster_id);
            raw_clusters[cluster_id].push(q);

            if graph[q].len() + 1 >= min_pts {
                for &(nbr, _) in &graph[q] {
                    let nbr = nbr as usize;
                    if !in_seeds[nbr] {
                        in_seeds[nbr] = true;
                        seeds.push(nbr);
                    }
                }
            }
        }
    }

    raw_clusters
}

// ------------------------------------------------------------------
// Algorithm: K-means / K-modes (for binary perceptual hashes)
//
// Uses only the whole-image hash for centroid computation and assignment; images without a
// reliable one are left out. Centroid update = bitwise majority vote (k-modes).
// ------------------------------------------------------------------

fn cluster_kmeans(all_hashes: &[Slots], k: usize) -> Vec<Vec<usize>> {
    let indices: Vec<usize> = (0..all_hashes.len())
        .filter(|&i| all_hashes[i][0] != 0)
        .collect();
    let hashes: Vec<u64> = indices.iter().map(|&i| all_hashes[i][0]).collect();
    let n = hashes.len();
    if n == 0 {
        return Vec::new();
    }

    let k = k.min(n);
    if k <= 1 {
        return vec![indices];
    }

    const MAX_ITERS: usize = 50;

    // --- Initialisation (k-means++) ---
    let mut centroids: Vec<u64> = Vec::with_capacity(k);
    {
        // Simple xorshift seeded from wall-clock nanos.
        let mut s = {
            use std::time::{SystemTime, UNIX_EPOCH};
            let raw = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.subsec_nanos() as u64)
                .unwrap_or(42);
            if raw == 0 {
                42
            } else {
                raw
            }
        };
        let mut xorshift = move || {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s
        };

        // First centroid: random image
        centroids.push(hashes[(xorshift() as usize) % n]);

        for _ in 1..k {
            let mut dists = vec![0f64; n];
            let mut total = 0.0f64;
            for i in 0..n {
                let mut min_d = u32::MAX;
                for c in &centroids {
                    let d = (hashes[i] ^ c).count_ones();
                    if d < min_d {
                        min_d = d;
                    }
                }
                let dsq = (min_d as f64) * (min_d as f64) + 1.0;
                dists[i] = dsq;
                total += dsq;
            }

            let threshold = (xorshift() as f64 / u64::MAX as f64) * total;
            let mut cum = 0.0f64;
            let mut chosen = 0usize;
            for (i, &d) in dists.iter().enumerate() {
                cum += d;
                if cum >= threshold {
                    chosen = i;
                    break;
                }
            }
            centroids.push(hashes[chosen]);
        }
    }

    let mut labels = vec![0usize; n];

    // --- Lloyd iteration ---
    for iter in 0..MAX_ITERS {
        // Assign
        for i in 0..n {
            let mut best_c = 0;
            let mut best_d = u32::MAX;
            for (c, centroid) in centroids.iter().enumerate() {
                let d = (hashes[i] ^ centroid).count_ones();
                if d < best_d {
                    best_d = d;
                    best_c = c;
                    if d == 0 {
                        break;
                    }
                }
            }
            labels[i] = best_c;
        }

        // Update centroids (bitwise majority)
        let prev = centroids.clone();
        for c in 0..k {
            let mut counts = vec![0u32; 64];
            let mut total = 0usize;
            for i in 0..n {
                if labels[i] == c {
                    total += 1;
                    for (bit, count) in counts.iter_mut().enumerate() {
                        *count += ((hashes[i] >> bit) & 1) as u32;
                    }
                }
            }

            if total == 0 {
                continue; // keep previous centroid for empty clusters
            }

            let mut new_hash = 0u64;
            for (bit, &ones) in counts.iter().enumerate() {
                let zeros = total as u32 - ones;
                if ones > zeros || (ones == zeros && (prev[c] >> bit) & 1 == 1) {
                    new_hash |= 1 << bit;
                }
            }
            centroids[c] = new_hash;
        }

        if centroids == prev {
            debug!("K-means converged after {} iterations", iter + 1);
            break;
        }
    }

    let mut clusters: Vec<Vec<usize>> = vec![Vec::new(); k];
    for (i, &label) in labels.iter().enumerate() {
        clusters[label].push(indices[i]);
    }
    clusters.retain(|c| !c.is_empty());
    clusters
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(algorithm: ClusterAlgorithm) -> ClusterParams {
        ClusterParams {
            algorithm,
            threshold: 10,
            dbscan_min_points: 2,
            kmeans_k: 2,
        }
    }

    fn full(h: u64) -> Slots {
        [h, 0, 0, 0, 0, 0]
    }

    fn sorted(clusters: Vec<Vec<(usize, u32)>>) -> Vec<Vec<usize>> {
        let mut out: Vec<Vec<usize>> = clusters
            .into_iter()
            .map(|c| {
                let mut ids: Vec<usize> = c.into_iter().map(|(i, _)| i).collect();
                ids.sort();
                ids
            })
            .collect();
        out.sort();
        out
    }

    const A: u64 = 0x0123_4567_89ab_cdef;
    const B: u64 = 0xfedc_ba98_7654_3210;

    #[test]
    fn crop_to_crop_pairs_are_not_compared() {
        let shared_sky = 0x5555_5555_aaaa_aaaa;
        let x = [A, shared_sky, 0, 0, 0, 0];
        let y = [B, shared_sky, 0, 0, 0, 0];
        let via_crop = (A ^ shared_sky)
            .count_ones()
            .min((B ^ shared_sky).count_ones());
        assert_eq!(pair_distance(&x, &y), Some(via_crop + CROP_PENALTY));
        assert!(via_crop > 10);
    }

    #[test]
    fn whole_image_matching_a_crop_counts_with_penalty() {
        let original = [A, B, 0, 0, 0, 0];
        let cropped = full(B ^ 1);
        assert_eq!(pair_distance(&original, &cropped), Some(1 + CROP_PENALTY));
    }

    #[test]
    fn missing_or_unreliable_hashes_never_match() {
        assert_eq!(pair_distance(&[0; 6], &[0; 6]), None);
        assert_eq!(
            pair_distance(&full(A), &[0, A, 0, 0, 0, 0]),
            Some(CROP_PENALTY)
        );
    }

    #[test]
    fn complete_linkage_does_not_chain() {
        // 0 ~ 1 ~ 2 in steps of 6 bits, but 0 and 2 are 12 bits apart.
        let hashes = [full(A), full(A ^ 0x3f), full(A ^ 0xfff), full(B)];
        assert_eq!(
            sorted(compute_clusters(
                &hashes,
                &params(ClusterAlgorithm::Complete)
            )),
            vec![vec![0, 1]]
        );
        assert_eq!(
            sorted(compute_clusters(&hashes, &params(ClusterAlgorithm::Single))),
            vec![vec![0, 1, 2]]
        );
    }

    #[test]
    fn complete_linkage_is_order_independent() {
        let a = [full(A), full(A ^ 0x3f), full(A ^ 0xfff), full(A ^ 0xfc0)];
        let b = [a[2], a[3], a[1], a[0]];
        let map_b = [2, 3, 1, 0];
        let ca = sorted(compute_clusters(&a, &params(ClusterAlgorithm::Complete)));
        let cb: Vec<Vec<usize>> = sorted(
            compute_clusters(&b, &params(ClusterAlgorithm::Complete))
                .into_iter()
                .map(|c| c.into_iter().map(|(i, d)| (map_b[i], d)).collect())
                .collect(),
        );
        assert_eq!(ca, cb);
    }

    #[test]
    fn representative_is_the_medoid() {
        // 1 sits between 0 and 2.
        let hashes = [full(A ^ 0x7), full(A), full(A ^ 0x700)];
        let clusters = compute_clusters(&hashes, &params(ClusterAlgorithm::Single));
        assert_eq!(clusters, vec![vec![(1, 0), (0, 3), (2, 3)]]);
    }

    #[test]
    fn dbscan_and_kmeans_use_reliable_hashes_only() {
        let hashes = [full(A), full(A ^ 1), [0; 6], [0; 6]];
        assert_eq!(
            sorted(compute_clusters(&hashes, &params(ClusterAlgorithm::Dbscan))),
            vec![vec![0, 1]]
        );
        let clusters = sorted(compute_clusters(&hashes, &params(ClusterAlgorithm::Kmeans)));
        assert!(clusters.iter().flatten().all(|&i| i < 2));
    }

    #[test]
    fn neighbour_graph_matches_brute_force() {
        let mut s = 0x9e37_79b9_7f4a_7c15u64;
        let mut next = || {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            s
        };
        let base: Vec<u64> = (0..20).map(|_| next()).collect();
        let hashes: Vec<Slots> = (0..500)
            .map(|i| {
                let flip = 1u64 << (next() % 64) | 1u64 << (next() % 64);
                [base[i % 20] ^ flip, next(), 0, base[(i + 3) % 20], 0, 0]
            })
            .collect();
        let graph = neighbour_graph(&hashes, 10);
        for i in 0..hashes.len() {
            for j in 0..hashes.len() {
                let expected = pair_distance(&hashes[i], &hashes[j]).filter(|&d| i != j && d < 10);
                assert_eq!(edge(&graph, i, j), expected, "pair {i},{j}");
            }
        }
    }
}
