use anyhow::Result;
use std::sync::Arc;
use tracing::{debug, info};
use uuid::Uuid;

use crate::data::repository::MediaRepository;

pub struct ClusterBuilder {
    repository: Arc<MediaRepository>,
    hamming_threshold: u32,
}

#[derive(Debug)]
pub struct ClusterStats {
    pub total_images: usize,
    pub images_with_hash: usize,
    pub clusters_created: usize,
    pub images_clustered: usize,
}

impl ClusterBuilder {
    pub fn new(repository: Arc<MediaRepository>) -> Self {
        Self {
            repository,
            hamming_threshold: 12, // Very similar only
        }
    }

    /// Calculate Hamming distance between two hashes
    fn hamming_distance(hash1: i64, hash2: i64) -> u32 {
        // Convert to u64 for XOR operation
        let h1 = hash1 as u64;
        let h2 = hash2 as u64;
        (h1 ^ h2).count_ones()
    }

    /// Build clusters from all images with perceptual hashes
    /// Uses an optimized in-memory algorithm to avoid N+1 database queries
    pub async fn build_clusters(&self) -> Result<ClusterStats> {
        info!("Starting fast in-memory cluster build");

        // Step 0: Clean up orphaned data
        debug!("Cleaning up orphaned data");
        let (orphaned_members, orphaned_images) = self.repository.cleanup_orphaned_data().await?;
        if orphaned_members > 0 || orphaned_images > 0 {
            info!(
                "Cleaned up {} orphaned cluster members and {} orphaned images",
                orphaned_members, orphaned_images
            );
        }

        // Step 1: Clear existing clusters (single DB operation)
        debug!("Clearing existing clusters");
        self.repository.clear_clusters().await?;

        // Step 2: Fetch ALL hashes at once (single DB query)
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

        // Step 3: In-Memory Clustering (pure CPU operations, no DB calls)
        // Each cluster stores its members with their hashes for distance calculations
        struct InMemoryCluster {
            members: Vec<(Uuid, u64)>, // (image_id, hash)
        }

        let mut clusters: Vec<InMemoryCluster> = Vec::new();

        for (image_id, hash_i64) in all_images {
            let hash_u64 = hash_i64 as u64;
            let mut best_cluster_idx: Option<usize> = None;
            let mut min_distance = u32::MAX;

            // Compare against ALL existing clusters in RAM (no DB calls!)
            // True single-linkage: check distance to ALL members of each cluster
            for (cluster_idx, cluster) in clusters.iter().enumerate() {
                for (_, member_hash) in &cluster.members {
                    let distance = (hash_u64 ^ member_hash).count_ones();

                    if distance < self.hamming_threshold {
                        if distance < min_distance {
                            min_distance = distance;
                            best_cluster_idx = Some(cluster_idx);
                        }
                        // Optimization: if distance is 0 (identical), stop searching
                        if distance == 0 {
                            break;
                        }
                    }
                }
            }

            // Add to existing cluster or create new one (all in RAM)
            match best_cluster_idx {
                Some(idx) => {
                    clusters[idx].members.push((image_id, hash_u64));
                }
                None => {
                    // Create new cluster
                    clusters.push(InMemoryCluster {
                        members: vec![(image_id, hash_u64)],
                    });
                }
            }
        }

        // Step 4: Bulk write to database (efficient batch operations)
        debug!("Writing {} in-memory clusters to database", clusters.len());
        let mut final_clusters_created = 0;
        let mut images_clustered = 0;

        for cluster in clusters {
            // Skip singleton clusters (only 1 member)
            if cluster.members.len() <= 1 {
                continue;
            }

            // Use first member as representative
            let representative_id = cluster.members[0].0;
            let representative_hash = cluster.members[0].1;

            // Create cluster in DB
            let db_cluster_id = self.repository.create_cluster(representative_id).await?;
            final_clusters_created += 1;

            // Prepare batch of members with their distances from representative
            let members_with_distances: Vec<(Uuid, u32)> = cluster
                .members
                .iter()
                .map(|(id, hash)| {
                    let distance = (hash ^ representative_hash).count_ones();
                    (*id, distance)
                })
                .collect();

            // Batch insert all members at once
            self.repository
                .add_batch_to_cluster(db_cluster_id, &members_with_distances)
                .await?;

            images_clustered += cluster.members.len();

            debug!(
                "Created cluster {} with {} members",
                db_cluster_id,
                cluster.members.len()
            );
        }

        let stats = ClusterStats {
            total_images,
            images_with_hash: total_images,
            clusters_created: final_clusters_created,
            images_clustered,
        };

        info!(
            "Clustering complete: {} clusters created, {} images clustered out of {} total (using in-memory algorithm)",
            stats.clusters_created, stats.images_clustered, stats.total_images
        );

        Ok(stats)
    }

    /// Add a newly processed image to existing clusters (incremental clustering)
    pub async fn add_to_clusters(&self, image_id: Uuid, phash: i64) -> Result<()> {
        debug!("Attempting to add image {} to existing clusters", image_id);

        // Fetch cluster representatives
        let representatives = self.repository.get_cluster_representatives().await?;

        if representatives.is_empty() {
            debug!("No existing clusters, skipping incremental clustering");
            return Ok(());
        }

        let mut best_match: Option<(i64, u32)> = None; // (cluster_id, distance)

        for (cluster_id, rep_hash) in representatives {
            let distance = Self::hamming_distance(phash, rep_hash);

            if distance < self.hamming_threshold {
                if let Some((_, best_distance)) = best_match {
                    if distance < best_distance {
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hamming_distance() {
        // Same hashes
        assert_eq!(ClusterBuilder::hamming_distance(0, 0), 0);

        // Different by 1 bit
        assert_eq!(ClusterBuilder::hamming_distance(0b1010, 0b1110), 1);

        // Different by 2 bits
        assert_eq!(ClusterBuilder::hamming_distance(0b1010, 0b1100), 2);

        // Completely different
        assert_eq!(ClusterBuilder::hamming_distance(0b0000, 0b1111), 4);

        // Real-world example with i64
        let hash1: i64 = 123456789;
        let hash2: i64 = 123456790;
        assert!(ClusterBuilder::hamming_distance(hash1, hash2) > 0);
    }
}
