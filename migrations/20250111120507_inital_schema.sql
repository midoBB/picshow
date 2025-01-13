-- Main table for storing media files
CREATE TABLE IF NOT EXISTS media_files (
    id BLOB PRIMARY KEY,
    hash TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    filename TEXT NOT NULL UNIQUE,
    media_type TEXT NOT NULL CHECK (media_type IN ('Image', 'Video')),
    last_modified TEXT NOT NULL,
    is_favorite INTEGER NOT NULL DEFAULT 0,
    size INTEGER NOT NULL,
    mime_type TEXT NOT NULL
) STRICT;

-- Index on the hash column to speed up queries filtering by hash
CREATE INDEX IF NOT EXISTS idx_media_files_hash ON media_files (hash);

-- Index on the filename column to speed up queries filtering by filename
CREATE INDEX IF NOT EXISTS idx_media_files_filename ON media_files (filename);

CREATE TABLE IF NOT EXISTS media_images (
    media_id BLOB PRIMARY KEY,
    image_id BLOB NOT NULL,
    FOREIGN KEY (media_id) REFERENCES media_files (id) ON DELETE CASCADE,
    FOREIGN KEY (image_id) REFERENCES images (id) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS media_videos (
    media_id BLOB PRIMARY KEY,
    video_id BLOB NOT NULL,
    FOREIGN KEY (media_id) REFERENCES media_files (id) ON DELETE CASCADE,
    FOREIGN KEY (video_id) REFERENCES videos (id) ON DELETE CASCADE
) STRICT;

CREATE INDEX IF NOT EXISTS idx_media_images_image_id ON media_images (image_id);
CREATE INDEX IF NOT EXISTS idx_media_videos_video_id ON media_videos (video_id);

-- Table to store details specific to image media
CREATE TABLE IF NOT EXISTS images (
    id BLOB PRIMARY KEY,
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,
    thumbnail_id BLOB,
    FOREIGN KEY (thumbnail_id) REFERENCES thumbnails (id) ON DELETE CASCADE
) STRICT;
-- Table to store details specific to video media
CREATE TABLE IF NOT EXISTS videos (
    id BLOB PRIMARY KEY,
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    thumbnail_id BLOB,
    FOREIGN KEY (thumbnail_id) REFERENCES thumbnails (id) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS thumbnails (
    id BLOB PRIMARY KEY,
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,
    data BLOB NOT NULL
) STRICT;

-- Table for media statistics (this is a singleton table)
CREATE TABLE IF NOT EXISTS stats (
    id INTEGER PRIMARY KEY DEFAULT 1,
    count INTEGER NOT NULL DEFAULT 0,
    images INTEGER NOT NULL DEFAULT 0,
    videos INTEGER NOT NULL DEFAULT 0,
    favorites INTEGER NOT NULL DEFAULT 0
) STRICT;

-- INSERT the singleton row into the stats table
INSERT OR IGNORE INTO stats (id, count, images, videos, favorites) VALUES (
    1, 0, 0, 0, 0
);

-- Set the user_version to 1 to indicate that the database is initialised
PRAGMA user_version = 1;
