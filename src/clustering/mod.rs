use anyhow::Result;
use std::sync::Arc;
use tracing::{debug, info, warn};
use uuid::Uuid;

use crate::config::{AppConfig, ClusterAlgorithm};
use crate::data::repository::MediaRepository;

// ---------------------------------------------------------------------------
// ClusterBuilder
// ---------------------------------------------------------------------------

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

    // --- Distance helpers ---

    /// Minimum Hamming distance across all hash pairs between two images.
    fn min_distance(hashset_a: &[u64], hashset_b: &[u64]) -> Option<u32> {
        if hashset_a.is_empty() || hashset_b.is_empty() {
            return None;
        }

        let mut best: Option<u32> = None;
        for a in hashset_a {
            for b in hashset_b {
                let d = (a ^ b).count_ones();
                match best {
                    Some(cur) if d >= cur => {}
                    _ => {
                        best = Some(d);
                        if d == 0 {
                            return Some(0);
                        }
                    }
                }
            }
        }
        best
    }

    // --- Public entry point ---

    pub async fn build_clusters(&self) -> Result<ClusterStats> {
        info!(
            "Starting cluster build (algo: {:?}, threshold: {}, min_pts: {}, k: {})",
            self.algorithm, self.hamming_threshold, self.dbscan_min_points, self.kmeans_k
        );

        // Step 0: Clean up orphaned data
        debug!("Cleaning up orphaned data");
        let (orphaned_members, orphaned_images) = self.repository.cleanup_orphaned_data().await?;
        if orphaned_members > 0 || orphaned_images > 0 {
            info!(
                "Cleaned up {} orphaned cluster members and {} orphaned images",
                orphaned_members, orphaned_images
            );
        }

        // Step 1: Clear existing clusters
        debug!("Clearing existing clusters");
        self.repository.clear_clusters().await?;

        // Step 2: Fetch ALL hashes
        debug!("Fetching all perceptual hashes");
        let all_images = self.repository.get_all_perceptual_hashes().await?;
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

        // Convert to u64
        let images_u64: Vec<(Uuid, Vec<u64>)> = all_images
            .into_iter()
            .map(|(id, hashes)| (id, hashes.into_iter().map(|h| h as u64).collect()))
            .collect();

        // Step 3: Cluster using selected algorithm
        let clusters: Vec<Vec<(Uuid, Vec<u64>)>> = match self.algorithm {
            ClusterAlgorithm::Single => self.cluster_single(&images_u64),
            ClusterAlgorithm::Complete => self.cluster_complete(&images_u64),
            ClusterAlgorithm::Dbscan => self.cluster_dbscan(&images_u64),
            ClusterAlgorithm::Kmeans => self.cluster_kmeans(&images_u64),
        };

        // Step 4: Write to database (skip singletons)
        debug!("Writing {} in-memory clusters to database", clusters.len());
        let mut final_clusters_created = 0;
        let mut images_clustered = 0;

        for cluster in clusters {
            if cluster.len() <= 1 {
                continue;
            }

            let representative_id = cluster[0].0;
            let representative_hashes = &cluster[0].1;

            let db_cluster_id = self.repository.create_cluster(representative_id).await?;
            final_clusters_created += 1;

            let members_with_distances: Vec<(Uuid, u32)> = cluster
                .iter()
                .filter_map(|(id, hashes)| {
                    let distance = Self::min_distance(hashes, representative_hashes)?;
                    Some((*id, distance))
                })
                .collect();

            self.repository
                .add_batch_to_cluster(db_cluster_id, &members_with_distances)
                .await?;

            images_clustered += cluster.len();

            debug!(
                "Created cluster {} with {} members",
                db_cluster_id,
                cluster.len()
            );
        }

        let stats = ClusterStats {
            total_images,
            images_with_hash: total_images,
            clusters_created: final_clusters_created,
            images_clustered,
        };

        info!(
            "Clustering complete: {} clusters / {} images / {} total (algo: {:?})",
            stats.clusters_created, stats.images_clustered, stats.total_images, self.algorithm
        );

        Ok(stats)
    }

    // ------------------------------------------------------------------
    // Algorithm: Single-linkage
    // ------------------------------------------------------------------

    fn cluster_single(&self, images: &[(Uuid, Vec<u64>)]) -> Vec<Vec<(Uuid, Vec<u64>)>> {
        let mut clusters: Vec<Vec<(Uuid, Vec<u64>)>> = Vec::new();

        for (image_id, hashes) in images {
            let mut best_cluster_idx: Option<usize> = None;
            let mut best_distance = u32::MAX;

            for (cluster_idx, cluster) in clusters.iter().enumerate() {
                for (_, member_hashes) in cluster {
                    let Some(distance) = Self::min_distance(hashes, member_hashes) else {
                        continue;
                    };
                    if distance < self.hamming_threshold && distance < best_distance {
                        best_distance = distance;
                        best_cluster_idx = Some(cluster_idx);
                        if distance == 0 {
                            break;
                        }
                    }
                }
            }

            match best_cluster_idx {
                Some(idx) => clusters[idx].push((*image_id, hashes.clone())),
                None => clusters.push(vec![(*image_id, hashes.clone())]),
            }
        }

        clusters
    }

    // ------------------------------------------------------------------
    // Algorithm: Complete-linkage
    // ------------------------------------------------------------------

    fn cluster_complete(&self, images: &[(Uuid, Vec<u64>)]) -> Vec<Vec<(Uuid, Vec<u64>)>> {
        let mut clusters: Vec<Vec<(Uuid, Vec<u64>)>> = Vec::new();

        for (image_id, hashes) in images {
            let mut best_cluster_idx: Option<usize> = None;
            let mut best_max_dist = u32::MAX;

            for (cluster_idx, cluster) in clusters.iter().enumerate() {
                let mut max_dist = 0u32;
                let mut all_within = true;

                for (_, member_hashes) in cluster {
                    let Some(distance) = Self::min_distance(hashes, member_hashes) else {
                        all_within = false;
                        break;
                    };
                    if distance >= self.hamming_threshold {
                        all_within = false;
                        break;
                    }
                    if distance > max_dist {
                        max_dist = distance;
                    }
                }

                if all_within && max_dist < best_max_dist {
                    best_max_dist = max_dist;
                    best_cluster_idx = Some(cluster_idx);
                }
            }

            match best_cluster_idx {
                Some(idx) => clusters[idx].push((*image_id, hashes.clone())),
                None => clusters.push(vec![(*image_id, hashes.clone())]),
            }
        }

        clusters
    }

    // ------------------------------------------------------------------
    // Algorithm: DBSCAN
    // ------------------------------------------------------------------

    fn cluster_dbscan(&self, images: &[(Uuid, Vec<u64>)]) -> Vec<Vec<(Uuid, Vec<u64>)>> {
        let n = images.len();
        let eps = self.hamming_threshold;
        let min_pts = self.dbscan_min_points;

        if n == 0 {
            return Vec::new();
        }

        // Precompute symmetric neighbour list.
        let mut neighbours: Vec<Vec<usize>> = vec![Vec::new(); n];
        for i in 0..n {
            for j in (i + 1)..n {
                if let Some(d) = Self::min_distance(&images[i].1, &images[j].1) {
                    if d < eps {
                        neighbours[i].push(j);
                        neighbours[j].push(i);
                    }
                }
            }
        }

        // None  = unprocessed noise / not yet assigned
        let mut assigned: Vec<Option<usize>> = vec![None; n];
        let mut raw_clusters: Vec<Vec<usize>> = Vec::new();

        for i in 0..n {
            if assigned[i].is_some() {
                continue;
            }

            if neighbours[i].len() < min_pts {
                // Mark as noise so we don't revisit it.
                assigned[i] = None;
                continue;
            }

            let cluster_id = raw_clusters.len();
            raw_clusters.push(vec![i]);
            assigned[i] = Some(cluster_id);

            // BFS expansion
            let mut seeds = neighbours[i].clone();
            let mut in_seeds = vec![false; n];
            for &nbr in &neighbours[i] {
                in_seeds[nbr] = true;
            }

            while let Some(q) = seeds.pop() {
                if assigned[q].is_some() {
                    continue;
                }
                assigned[q] = Some(cluster_id);
                raw_clusters[cluster_id].push(q);

                if neighbours[q].len() >= min_pts {
                    for &nbr in &neighbours[q] {
                        if !in_seeds[nbr] {
                            in_seeds[nbr] = true;
                            seeds.push(nbr);
                        }
                    }
                }
            }
        }

        raw_clusters
            .into_iter()
            .map(|indices| {
                indices
                    .into_iter()
                    .map(|idx| (images[idx].0, images[idx].1.clone()))
                    .collect()
            })
            .collect()
    }

    // ------------------------------------------------------------------
    // Algorithm: K-means / K-modes (for binary perceptual hashes)
    //
    // Uses only the *first* (full-image) hash for centroid computation
    // and assignment.  Centroid update = bitwise majority vote (k-modes).
    // ------------------------------------------------------------------

    fn cluster_kmeans(&self, images: &[(Uuid, Vec<u64>)]) -> Vec<Vec<(Uuid, Vec<u64>)>> {
        let n = images.len();
        if n == 0 {
            return Vec::new();
        }

        let k = self.kmeans_k.min(n);
        if k <= 1 {
            return vec![images.to_vec()];
        }

        const MAX_ITERS: usize = 50;

        // Each image’s first hash (full hash).  Images with no hash use
        // u64::MAX as sentinel – virtually impossible to collide.
        let hashes: Vec<u64> = images
            .iter()
            .map(|(_, hs)| *hs.first().unwrap_or(&u64::MAX))
            .collect();

        // --- Initialisation (k-means++) ---
        let mut centroids: Vec<u64> = Vec::with_capacity(k);
        {
            // Simple xorshift seeded from wall-clock nanos.
            let mut s = {
                use std::time::{SystemTime, UNIX_EPOCH};
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.subsec_nanos() as u64)
                    .unwrap_or(42)
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

        // Build clusters from final labels
        let mut clusters: Vec<Vec<(Uuid, Vec<u64>)>> = vec![Vec::new(); k];
        for (i, &label) in labels.iter().enumerate() {
            clusters[label].push((images[i].0, images[i].1.clone()));
        }
        clusters.retain(|c| !c.is_empty());

        clusters
    }

    // ------------------------------------------------------------------
    // Incremental clustering
    // ------------------------------------------------------------------

    pub async fn add_to_clusters_multi(&self, image_id: Uuid, hashes: &[i64]) -> Result<()> {
        let effective_algo = match self.algorithm {
            ClusterAlgorithm::Single | ClusterAlgorithm::Complete => self.algorithm,
            ClusterAlgorithm::Dbscan | ClusterAlgorithm::Kmeans => {
                warn!(
                    "Incremental clustering with {:?} is not meaningful; \
                     falling back to single-linkage",
                    self.algorithm
                );
                ClusterAlgorithm::Single
            }
        };

        debug!(
            "Incremental clustering for image {} using {:?}",
            image_id, effective_algo
        );

        let representatives = self.repository.get_cluster_representatives().await?;
        if representatives.is_empty() {
            debug!("No existing clusters, skipping incremental clustering");
            return Ok(());
        }

        let hashes_u64: Vec<u64> = hashes.iter().copied().map(|h| h as u64).collect();
        let mut best_match: Option<(i64, u32)> = None;

        for (cluster_id, rep_hashes) in representatives {
            let rep_u64: Vec<u64> = rep_hashes.into_iter().map(|h| h as u64).collect();
            let Some(distance) = Self::min_distance(&hashes_u64, &rep_u64) else {
                continue;
            };

            if distance < self.hamming_threshold {
                if let Some((_, best_dist)) = best_match {
                    if distance < best_dist {
                        best_match = Some((cluster_id, distance));
                    }
                } else {
                    best_match = Some((cluster_id, distance));
                }
            }
        }

        if let Some((cluster_id, distance)) = best_match {
            self.repository
                .add_to_cluster(cluster_id, image_id, distance)
                .await?;
            info!(
                "Added image {} to cluster {} (distance: {})",
                image_id, cluster_id, distance
            );
        } else {
            debug!("No matching cluster found for image {}", image_id);
        }

        Ok(())
    }

    pub async fn add_to_clusters(&self, image_id: Uuid, phash: i64) -> Result<()> {
        self.add_to_clusters_multi(image_id, &[phash]).await
    }
}
