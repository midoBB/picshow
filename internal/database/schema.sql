CREATE TABLE files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    hash TEXT UNIQUE NOT NULL,
    filename TEXT NOT NULL,
    size INTEGER NOT NULL,
    mime_type TEXT NOT NULL,
    last_modified INTEGER NOT NULL
);

CREATE INDEX idx_files_hash ON files (hash);
CREATE INDEX idx_files_last_modified ON files (last_modified);

CREATE TABLE images
(
    id INTEGER
    PRIMARY KEY AUTOINCREMENT,
    full_mime_type TEXT NOT NULL,
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,
    file_id INTEGER NOT NULL,
    thumbnail_width INTEGER NOT NULL,
    thumbnail_height INTEGER NOT NULL,
    thumbnail_data BLOB NOT NULL,
    FOREIGN KEY (file_id) REFERENCES files (id) ON DELETE CASCADE
);

CREATE TABLE videos
(
    id INTEGER
    PRIMARY KEY AUTOINCREMENT,
    full_mime_type TEXT NOT NULL,
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,
    length INTEGER NOT NULL,
    file_id INTEGER NOT NULL,
    thumbnail_width INTEGER NOT NULL,
    thumbnail_height INTEGER NOT NULL,
    thumbnail_data BLOB NOT NULL,
    FOREIGN KEY (file_id) REFERENCES files (id) ON DELETE CASCADE
);

CREATE INDEX idx_images_file_id ON images (file_id);
CREATE INDEX idx_videos_file_id ON videos (file_id);
