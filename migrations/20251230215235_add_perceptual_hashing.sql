-- Add perceptual_hash column to images table
ALTER TABLE images ADD COLUMN perceptual_hash INTEGER;

-- Create index for efficient similarity searches
CREATE INDEX idx_images_perceptual_hash ON images(perceptual_hash)
  WHERE perceptual_hash IS NOT NULL;

-- Cluster metadata table
CREATE TABLE IF NOT EXISTS image_clusters (
    cluster_id INTEGER PRIMARY KEY AUTOINCREMENT,
    representative_image_id BLOB NOT NULL,
    created_at TEXT NOT NULL,
    is_resolved INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (representative_image_id) REFERENCES images(id) ON DELETE CASCADE
) STRICT;

-- Cluster membership junction table
CREATE TABLE IF NOT EXISTS cluster_members (
    cluster_id INTEGER NOT NULL,
    image_id BLOB NOT NULL,
    hamming_distance INTEGER NOT NULL,
    is_best_shot INTEGER NOT NULL DEFAULT 0,
    added_at TEXT NOT NULL,
    PRIMARY KEY (cluster_id, image_id),
    FOREIGN KEY (cluster_id) REFERENCES image_clusters(cluster_id) ON DELETE CASCADE,
    FOREIGN KEY (image_id) REFERENCES images(id) ON DELETE CASCADE
) STRICT;

CREATE INDEX idx_cluster_members_image_id ON cluster_members(image_id);
CREATE INDEX idx_cluster_members_best ON cluster_members(cluster_id, is_best_shot);
