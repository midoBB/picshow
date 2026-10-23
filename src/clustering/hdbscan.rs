//! HDBSCAN (Campello et al.) over a sparse match graph.
//!
//! Absent edges are treated as infinite distance, so each connected component
//! of the graph is its own hierarchy. Unlike the reference implementation, a
//! component's root may itself be selected; otherwise a lone pair of
//! duplicates could never form a cluster.

use super::graph::{MatchGraph, UnionFind};

/// Floor on distances when converting to λ = 1/d, so exact duplicates
/// (ρ = 0) don't swamp every stability comparison.
const MIN_DISTANCE: f64 = 0.01;

pub struct HdbscanCluster {
    /// Member indices; the first is the exemplar (the member that persists to the highest λ).
    pub members: Vec<usize>,
}

/// Single-linkage dendrogram: nodes 0..n are points, n.. are merges.
struct Dendrogram {
    n: usize,
    children: Vec<(usize, usize)>,
    distance: Vec<f64>,
    size: Vec<usize>,
}

impl Dendrogram {
    fn node_size(&self, node: usize) -> usize {
        if node < self.n {
            1
        } else {
            self.size[node - self.n]
        }
    }

    fn points_under(&self, node: usize, out: &mut Vec<usize>) {
        let mut stack = vec![node];
        while let Some(x) = stack.pop() {
            if x < self.n {
                out.push(x);
            } else {
                let (l, r) = self.children[x - self.n];
                stack.push(l);
                stack.push(r);
            }
        }
    }
}

struct CondensedCluster {
    parent: Option<usize>,
    birth: f64,
    stability: f64,
    children: Vec<usize>,
}

fn lambda(distance: f64) -> f64 {
    1.0 / distance.max(MIN_DISTANCE)
}

pub fn cluster(
    graph: &MatchGraph,
    min_samples: usize,
    min_cluster_size: usize,
) -> Vec<HdbscanCluster> {
    let n = graph.len();
    let min_cluster_size = min_cluster_size.max(2);

    // Core distance: distance to the (min_samples − 1)-th neighbour, the point
    // itself counting as the first sample.
    let k = min_samples.max(1) - 1;
    let core: Vec<f64> = (0..n)
        .map(|i| {
            if k == 0 {
                return 0.0;
            }
            let mut weights: Vec<f64> = graph.neighbors(i).iter().map(|&(_, w)| w as f64).collect();
            if weights.len() < k {
                return f64::INFINITY;
            }
            weights.select_nth_unstable_by(k - 1, f64::total_cmp);
            weights[k - 1]
        })
        .collect();

    // Minimum spanning forest under mutual reachability (Kruskal).
    let mut edges: Vec<(f64, usize, usize)> = (0..n)
        .flat_map(|i| {
            let core = &core;
            graph
                .neighbors(i)
                .iter()
                .filter(move |&&(j, _)| j > i)
                .map(move |&(j, w)| ((w as f64).max(core[i]).max(core[j]), i, j))
        })
        .filter(|e| e.0.is_finite())
        .collect();
    edges.sort_by(|a, b| a.0.total_cmp(&b.0));

    // Building the dendrogram directly from the sorted edges is Kruskal's
    // algorithm: each successful union is an MST edge and a merge node.
    let mut uf = UnionFind::new(n);
    let mut top = (0..n).collect::<Vec<_>>(); // union-find root -> dendrogram node
    let mut tree = Dendrogram {
        n,
        children: Vec::new(),
        distance: Vec::new(),
        size: Vec::new(),
    };
    for (d, i, j) in edges {
        let (ri, rj) = (uf.find(i), uf.find(j));
        let Some(root) = uf.union(ri, rj) else {
            continue;
        };
        let (a, b) = (top[ri], top[rj]);
        let node = n + tree.children.len();
        tree.size.push(tree.node_size(a) + tree.node_size(b));
        tree.children.push((a, b));
        tree.distance.push(d);
        top[root] = node;
    }

    // Condense each component's hierarchy, recording where each point falls out.
    let mut clusters: Vec<CondensedCluster> = Vec::new();
    let mut fallout: Vec<Option<(usize, f64)>> = vec![None; n];
    let mut scratch = Vec::new();
    let roots: Vec<usize> = (0..n)
        .filter(|&i| uf.find(i) == i)
        .map(|r| top[r])
        .collect();
    for root in roots {
        if tree.node_size(root) < min_cluster_size {
            continue;
        }
        clusters.push(CondensedCluster {
            parent: None,
            birth: 0.0,
            stability: 0.0,
            children: Vec::new(),
        });
        let mut stack = vec![(root, clusters.len() - 1)];
        while let Some((node, c)) = stack.pop() {
            let (l, r) = tree.children[node - n];
            let lam = lambda(tree.distance[node - n]);
            let gain = lam - clusters[c].birth;
            let (sl, sr) = (tree.node_size(l), tree.node_size(r));
            match (sl >= min_cluster_size, sr >= min_cluster_size) {
                (true, true) => {
                    clusters[c].stability += gain * (sl + sr) as f64;
                    for child in [l, r] {
                        clusters.push(CondensedCluster {
                            parent: Some(c),
                            birth: lam,
                            stability: 0.0,
                            children: Vec::new(),
                        });
                        let id = clusters.len() - 1;
                        clusters[c].children.push(id);
                        stack.push((child, id));
                    }
                }
                (big_l, big_r) => {
                    let mut leaving = Vec::new();
                    if big_l {
                        stack.push((l, c));
                    } else {
                        leaving.push(l);
                    }
                    if big_r {
                        stack.push((r, c));
                    } else {
                        leaving.push(r);
                    }
                    for side in leaving {
                        scratch.clear();
                        tree.points_under(side, &mut scratch);
                        clusters[c].stability += gain * scratch.len() as f64;
                        for &p in &scratch {
                            fallout[p] = Some((c, lam));
                        }
                    }
                }
            }
        }
    }

    // Excess-of-mass selection, children before parents (children have higher ids).
    let mut selected = vec![false; clusters.len()];
    let mut value = vec![0.0; clusters.len()];
    for c in (0..clusters.len()).rev() {
        let children_value: f64 = clusters[c].children.iter().map(|&ch| value[ch]).sum();
        if clusters[c].children.is_empty() || clusters[c].stability >= children_value {
            selected[c] = true;
            value[c] = clusters[c].stability;
        } else {
            value[c] = children_value;
        }
    }
    // A selected ancestor overrides its descendants. Parents have lower ids.
    let mut chosen: Vec<Option<usize>> = vec![None; clusters.len()];
    for c in 0..clusters.len() {
        chosen[c] = match clusters[c].parent.and_then(|p| chosen[p]) {
            Some(ancestor) => Some(ancestor),
            None if selected[c] => Some(c),
            None => None,
        };
    }

    let mut out: Vec<Option<(Vec<usize>, usize, f64)>> = vec![None; clusters.len()];
    for (p, f) in fallout.iter().enumerate() {
        let Some((c, lam)) = *f else { continue };
        let Some(sel) = chosen[c] else { continue };
        let entry = out[sel].get_or_insert_with(|| (Vec::new(), p, lam));
        entry.0.push(p);
        if lam > entry.2 {
            entry.1 = p;
            entry.2 = lam;
        }
    }
    out.into_iter()
        .flatten()
        .map(|(mut members, exemplar, _)| {
            members.sort_unstable();
            let pos = members.iter().position(|&m| m == exemplar).unwrap();
            members[..=pos].rotate_right(1);
            HdbscanCluster { members }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sorted_clusters(graph: &MatchGraph, min_samples: usize, mcs: usize) -> Vec<Vec<usize>> {
        let mut out: Vec<Vec<usize>> = cluster(graph, min_samples, mcs)
            .into_iter()
            .map(|c| {
                let mut m = c.members;
                m.sort_unstable();
                m
            })
            .collect();
        out.sort();
        out
    }

    fn clique(members: &[usize], w: f32) -> Vec<(usize, usize, f32)> {
        let mut edges = Vec::new();
        for (a, &i) in members.iter().enumerate() {
            for &j in &members[a + 1..] {
                edges.push((i, j, w));
            }
        }
        edges
    }

    #[test]
    fn three_groups_with_noise() {
        // Groups 0-4, 5-9, 10-14 are tight; weak bridges join them into one
        // component; 15-17 hang off loosely and 18-19 are isolated.
        let mut edges = Vec::new();
        edges.extend(clique(&[0, 1, 2, 3, 4], 0.1));
        edges.extend(clique(&[5, 6, 7, 8, 9], 0.15));
        edges.extend(clique(&[10, 11, 12, 13, 14], 0.12));
        edges.extend([
            (4, 5, 0.9),
            (9, 10, 0.95),
            (15, 0, 1.2),
            (16, 7, 1.3),
            (17, 12, 1.25),
        ]);
        let graph = MatchGraph::from_edges(20, edges);
        assert_eq!(
            sorted_clusters(&graph, 3, 3),
            vec![
                vec![0, 1, 2, 3, 4],
                vec![5, 6, 7, 8, 9],
                vec![10, 11, 12, 13, 14],
            ]
        );
    }

    #[test]
    fn isolated_duplicate_pair() {
        let graph = MatchGraph::from_edges(4, [(1, 2, 0.0)]);
        assert_eq!(sorted_clusters(&graph, 2, 2), vec![vec![1, 2]]);
    }

    #[test]
    fn exemplar_is_most_persistent() {
        // Point 3 attaches loosely to a tight triangle; the exemplar must be in the triangle.
        let mut edges = clique(&[0, 1, 2], 0.1);
        edges.push((2, 3, 0.5));
        let graph = MatchGraph::from_edges(4, edges);
        let clusters = cluster(&graph, 2, 2);
        assert_eq!(clusters.len(), 1);
        assert!(clusters[0].members[0] < 3);
    }
}
