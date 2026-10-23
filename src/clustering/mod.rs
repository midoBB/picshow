pub mod features;
mod graph;
mod hdbscan;
mod hnsw;
mod mih;

use anyhow::Result;
use std::sync::Arc;
use tracing::{debug, info, warn};
use uuid::Uuid;

use crate::config::{AppConfig, ClusterAlgorithm};
use crate::data::repository::MediaRepository;
use crate::data::PerceptualFeatures;
use features::{stored_distance, ImageFeatures, MatchParams};
use graph::{build_candidate_graph, MatchGraph, UnionFind};

pub struct ClusterBuilder {
    repository: Arc<MediaRepository>,
    settings: ClusterSettings,
}

#[derive(Debug)]
pub struct ClusterStats {
    pub total_images: usize,
    pub images_with_hash: usize,
    pub clusters_created: usize,
    pub images_clustered: usize,
}

const CLUSTERING_PARAMS_KEY: &str = "clustering_params";

/// Bumped when the stored features or the match rule change, so the next
/// build replaces every cluster.
const FEATURES_VERSION: u32 = 2;

#[derive(Clone, Copy, Debug)]
struct ClusterSettings {
    algorithm: ClusterAlgorithm,
    matching: MatchParams,
    dbscan_min_points: usize,
    hnsw_k: usize,
    hdbscan_min_cluster_size: usize,
    hdbscan_min_samples: usize,
}

impl ClusterSettings {
    fn from_config(config: &AppConfig) -> Self {
        Self {
            algorithm: config.cluster_algorithm,
            matching: MatchParams {
                threshold64: config.cluster_threshold,
                threshold256: config.cluster_threshold_256,
                color_threshold: config.cluster_color_threshold as f32,
                color_tight: config.cluster_color_tight as f32,
                rescue_factor: config.cluster_rescue_factor as f32,
            },
            dbscan_min_points: config.cluster_dbscan_min_pts,
            hnsw_k: config.cluster_hnsw_k,
            hdbscan_min_cluster_size: config.cluster_hdbscan_min_cluster_size,
            hdbscan_min_samples: config.cluster_hdbscan_min_samples,
        }
    }

    fn serialize(&self) -> String {
        let m = &self.matching;
        format!(
            "{:?},{},{},{},{},{},{},{},{},{},v{}",
            self.algorithm,
            m.threshold64,
            m.threshold256,
            m.color_threshold,
            m.color_tight,
            m.rescue_factor,
            self.hnsw_k,
            self.dbscan_min_points,
            self.hdbscan_min_cluster_size,
            self.hdbscan_min_samples,
            FEATURES_VERSION
        )
    }
}

#[derive(Clone, PartialEq)]
enum VisitStatus {
    Unvisited,
    Noise,
    Clustered(usize),
}

/// Group image indices; each returned cluster has ≥ 2 members, representative first.
fn compute_clusters(images: &[ImageFeatures], settings: &ClusterSettings) -> Vec<Vec<usize>> {
    let graph = build_candidate_graph(images, &settings.matching, settings.hnsw_k);
    let edges: usize = (0..graph.len())
        .map(|i| graph.neighbors(i).len())
        .sum::<usize>()
        / 2;
    debug!(
        "Match graph: {} images, {} matching pairs",
        graph.len(),
        edges
    );

    let clusters = match settings.algorithm {
        ClusterAlgorithm::Single => cluster_single(&graph),
        ClusterAlgorithm::Complete => cluster_complete(&graph),
        ClusterAlgorithm::Dbscan => cluster_dbscan(&graph, settings.dbscan_min_points),
        ClusterAlgorithm::Hdbscan => hdbscan::cluster(
            &graph,
            settings.hdbscan_min_samples,
            settings.hdbscan_min_cluster_size,
        )
        .into_iter()
        .map(|c| c.members)
        .collect(),
    };
    clusters.into_iter().filter(|c| c.len() > 1).collect()
}

// ------------------------------------------------------------------
// Algorithm: Single-linkage (connected components of the match graph)
// ------------------------------------------------------------------

fn cluster_single(graph: &MatchGraph) -> Vec<Vec<usize>> {
    let n = graph.len();
    let mut uf = UnionFind::new(n);
    for i in 0..n {
        for &(j, _) in graph.neighbors(i) {
            uf.union(i, j);
        }
    }

    let mut cluster_of_root = vec![usize::MAX; n];
    let mut clusters: Vec<Vec<usize>> = Vec::new();
    for i in 0..n {
        let root = uf.find(i);
        if cluster_of_root[root] == usize::MAX {
            cluster_of_root[root] = clusters.len();
            clusters.push(Vec::new());
        }
        clusters[cluster_of_root[root]].push(i);
    }
    clusters
}

// ------------------------------------------------------------------
// Algorithm: Complete-linkage (greedy, in image order)
// ------------------------------------------------------------------

fn cluster_complete(graph: &MatchGraph) -> Vec<Vec<usize>> {
    let n = graph.len();
    let mut clusters: Vec<Vec<usize>> = Vec::new();
    let mut cluster_of = vec![usize::MAX; n];

    for i in 0..n {
        // Only clusters holding a neighbour of i can have every member match it.
        let mut candidates: Vec<usize> = graph
            .neighbors(i)
            .iter()
            .map(|&(j, _)| cluster_of[j])
            .filter(|&c| c != usize::MAX)
            .collect();
        candidates.sort_unstable();
        candidates.dedup();

        let mut best: Option<(usize, f32)> = None;
        for c in candidates {
            let mut max_dist = 0f32;
            let all_within = clusters[c].iter().all(|&m| match graph.weight(i, m) {
                Some(w) => {
                    max_dist = max_dist.max(w);
                    true
                }
                None => false,
            });
            if all_within && best.is_none_or(|(_, b)| max_dist < b) {
                best = Some((c, max_dist));
            }
        }

        let c = match best {
            Some((c, _)) => c,
            None => {
                clusters.push(Vec::new());
                clusters.len() - 1
            }
        };
        clusters[c].push(i);
        cluster_of[i] = c;
    }

    clusters
}

// ------------------------------------------------------------------
// Algorithm: DBSCAN (ε-neighbourhood = matching pairs)
// ------------------------------------------------------------------

fn cluster_dbscan(graph: &MatchGraph, min_pts: usize) -> Vec<Vec<usize>> {
    let n = graph.len();
    let neighbours: Vec<Vec<usize>> = (0..n)
        .map(|i| graph.neighbors(i).iter().map(|&(j, _)| j).collect())
        .collect();

    // Track visit status: Unvisited, Noise, or Clustered(cluster_index)
    let mut assigned: Vec<VisitStatus> = vec![VisitStatus::Unvisited; n];
    let mut raw_clusters: Vec<Vec<usize>> = Vec::new();

    for i in 0..n {
        if assigned[i] != VisitStatus::Unvisited {
            continue;
        }

        if neighbours[i].len() + 1 < min_pts {
            assigned[i] = VisitStatus::Noise;
            continue;
        }

        let cluster_id = raw_clusters.len();
        raw_clusters.push(vec![i]);
        assigned[i] = VisitStatus::Clustered(cluster_id);

        // BFS expansion
        let mut seeds = neighbours[i].clone();
        let mut in_seeds = vec![false; n];
        for &nbr in &neighbours[i] {
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

            if neighbours[q].len() + 1 >= min_pts {
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
}

impl ClusterBuilder {
    pub fn new(repository: Arc<MediaRepository>, config: &AppConfig) -> Self {
        Self {
            repository,
            settings: ClusterSettings::from_config(config),
        }
    }

    // --- Public entry point ---

    pub async fn build_clusters(
        &self,
        force_rebuild: bool,
        save_state: bool,
    ) -> Result<ClusterStats> {
        let current_params = self.settings.serialize();

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
            "Starting cluster build ({:?}, force: {})",
            self.settings, should_force
        );

        debug!("Cleaning up orphaned data");
        let (orphaned_members, orphaned_images) = self.repository.cleanup_orphaned_data().await?;
        if orphaned_members > 0 || orphaned_images > 0 {
            info!(
                "Cleaned up {} orphaned cluster members and {} orphaned images",
                orphaned_members, orphaned_images
            );
        }

        debug!("Fetching all perceptual features");
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

        let settings = self.settings;
        let (all_images, new_clusters) = tokio::task::spawn_blocking(move || {
            let clusters = compute_clusters(&all_images, &settings);
            (all_images, clusters)
        })
        .await?;

        let members_with_distances = |cluster: &[usize]| -> Vec<(Uuid, u32)> {
            let representative = &all_images[cluster[0]];
            cluster
                .iter()
                .filter_map(|&m| {
                    let distance = stored_distance(&all_images[m], representative)?;
                    Some((all_images[m].id, distance))
                })
                .collect()
        };

        if should_force {
            debug!("Force rebuild: atomically replacing all clusters");
            let clusters_to_write: Vec<(Uuid, Vec<(Uuid, u32)>)> = new_clusters
                .iter()
                .map(|cluster| (all_images[cluster[0]].id, members_with_distances(cluster)))
                .filter(|(_, members)| members.len() > 1)
                .collect();

            let (created, clustered) = self
                .repository
                .clear_and_create_clusters(&clusters_to_write)
                .await?;
            let stats = ClusterStats {
                total_images,
                images_with_hash: total_images,
                clusters_created: created,
                images_clustered: clustered,
            };
            info!(
                "Clustering complete: {} clusters / {} images / {} total (algo: {:?})",
                stats.clusters_created,
                stats.images_clustered,
                stats.total_images,
                self.settings.algorithm
            );
            return Ok(stats);
        }

        debug!("Incremental rebuild: fetching existing clusters");
        let existing = self.repository.get_all_clusters_with_members().await?;

        let mut final_clusters_created = 0;
        let mut images_clustered = 0;
        let mut skipped = 0;

        for cluster in new_clusters {
            let representative_id = all_images[cluster[0]].id;
            let member_ids: Vec<Uuid> = cluster.iter().map(|&m| all_images[m].id).collect();

            let is_unchanged = existing.iter().any(|ec| {
                if ec.representative_id != representative_id {
                    return false;
                }
                if ec.members.len() != member_ids.len() {
                    return false;
                }
                let existing_ids: Vec<Uuid> = ec.members.iter().map(|(id, _)| *id).collect();
                member_ids.iter().all(|id| existing_ids.contains(id))
            });

            if is_unchanged {
                debug!("Skipping unchanged cluster (rep: {})", representative_id);
                skipped += 1;
                images_clustered += cluster.len();
                continue;
            }

            let members_with_distances = members_with_distances(&cluster);
            if members_with_distances.len() < 2 {
                continue;
            }

            let old_cluster_ids: Vec<i64> = existing
                .iter()
                .filter(|ec| {
                    let existing_ids: Vec<Uuid> = ec.members.iter().map(|(id, _)| *id).collect();
                    member_ids.iter().any(|id| existing_ids.contains(id))
                })
                .map(|ec| ec.cluster_id)
                .collect();

            let db_cluster_id = if let Some(_old_id) = old_cluster_ids.first() {
                self.repository
                    .replace_clusters(&old_cluster_ids, representative_id, &members_with_distances)
                    .await?
            } else {
                self.repository
                    .create_cluster_with_members(representative_id, &members_with_distances)
                    .await?
            };

            final_clusters_created += 1;
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
            "Clustering complete (incremental): {} created, {} unchanged, {} images clustered / {} total (algo: {:?})",
            final_clusters_created, skipped, images_clustered, total_images, self.settings.algorithm
        );

        Ok(stats)
    }

    // ------------------------------------------------------------------
    // Incremental clustering
    // ------------------------------------------------------------------

    /// Attach a newly hashed image to the best-matching existing cluster.
    /// Every algorithm compares against representatives only, as single
    /// linkage would; density-based ones can't place a single point meaningfully.
    pub async fn add_to_clusters_multi(
        &self,
        image_id: Uuid,
        features: &PerceptualFeatures,
    ) -> Result<()> {
        if matches!(
            self.settings.algorithm,
            ClusterAlgorithm::Dbscan | ClusterAlgorithm::Hdbscan
        ) {
            warn!(
                "Incremental clustering with {:?} is not meaningful; \
                 falling back to single-linkage",
                self.settings.algorithm
            );
        }

        debug!("Incremental clustering for image {}", image_id);

        let representatives = self.repository.get_cluster_representatives().await?;
        if representatives.is_empty() {
            debug!("No existing clusters, skipping incremental clustering");
            return Ok(());
        }

        let image = ImageFeatures::from_perceptual(image_id, features);
        let best_match = representatives
            .iter()
            .filter_map(|(cluster_id, rep)| {
                let weight = self.settings.matching.match_weight(&image, rep)?;
                Some((*cluster_id, weight, rep))
            })
            .min_by(|a, b| a.1.total_cmp(&b.1));

        if let Some((cluster_id, _, rep)) = best_match {
            let distance = stored_distance(&image, rep).unwrap_or(0);
            self.repository
                .add_to_cluster(cluster_id, image_id, distance)
                .await?;
            debug!(
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

    fn graph(n: usize, edges: &[(usize, usize)]) -> MatchGraph {
        MatchGraph::from_edges(n, edges.iter().map(|&(i, j)| (i, j, 0.5)))
    }

    #[test]
    fn single_links_chains() {
        let g = graph(5, &[(0, 1), (1, 2), (3, 4)]);
        assert_eq!(cluster_single(&g), vec![vec![0, 1, 2], vec![3, 4]]);
    }

    #[test]
    fn complete_requires_all_members() {
        // 2 matches 1 but not 0, so it can't join {0, 1}.
        let g = graph(3, &[(0, 1), (1, 2)]);
        assert_eq!(cluster_complete(&g), vec![vec![0, 1], vec![2]]);
    }

    #[test]
    fn dbscan_marks_sparse_points_as_noise() {
        let g = graph(5, &[(0, 1), (0, 2), (1, 2), (3, 4)]);
        let mut clusters = cluster_dbscan(&g, 3);
        clusters.iter_mut().for_each(|c| c.sort_unstable());
        assert_eq!(clusters, vec![vec![0, 1, 2]]);
    }
}
