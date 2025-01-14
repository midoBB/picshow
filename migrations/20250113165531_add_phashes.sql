CREATE TABLE IF NOT EXISTS phashes (
    hash_id BLOB NOT NULL,
    media_id BLOB NOT NULL,
    phash BLOB NOT NULL,
    PRIMARY KEY (hash_id, media_id),
    FOREIGN KEY (media_id) REFERENCES media_files (id) ON DELETE CASCADE
) STRICT;

CREATE INDEX IF NOT EXISTS idx_phashes_media_id ON phashes (media_id);
