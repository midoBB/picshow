use anyhow::Result;
use base64::{prelude::BASE64_STANDARD, Engine as _};
use sqlx::{
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
    Row,
};
use std::borrow::Borrow;
use std::str::FromStr as _;
use std::time::Duration;
use std::{path::Path, sync::Arc};
use tokio::fs;
use tokio::sync::{RwLock, Semaphore};
use tracing::{debug, info, trace};
use uuid::Uuid;

use super::*;
use crate::cache::{self, AppCache};
use crate::config::AppConfig;
use crate::server::{FileQueryType, FilledFileQuery};

// Database configuration constants
const DEFAULT_CACHE_SIZE: &str = "-64000";
const DEFAULT_PAGE_SIZE: &str = "4096";
const DEFAULT_WAL_CHECKPOINT: &str = "1000";
const DEFAULT_BUSY_TIMEOUT_SECS: u64 = 10;

#[derive(Clone, Debug)]
pub struct MediaRepository {
    read_pool: sqlx::SqlitePool,
    write_pool: Arc<sqlx::SqlitePool>,
    write_semaphore: Arc<RwLock<Semaphore>>,
    lock_semaphore: Arc<Semaphore>,
    cache: AppCache,
    db_path: String,
}

impl MediaRepository {
    pub async fn new(cache: AppCache, config: Arc<AppConfig>) -> Result<Self> {
        let db_path = format!("{}picshow.db", &config.db_path);
        ensure_dir(db_path.as_str()).await?;
        let url_db_path = &format!("sqlite://{}", db_path);
        let read_options = SqliteConnectOptions::from_str(&format!("{}?mode=ro", url_db_path))?
            .pragma("journal_mode", "WAL")
            .pragma("synchronous", "FULL")
            .pragma("foreign_keys", "ON")
            .pragma("cache_size", DEFAULT_CACHE_SIZE)
            .pragma("temp_store", "MEMORY")
            .pragma("page_size", DEFAULT_PAGE_SIZE)
            .pragma("secure_delete", "OFF")
            .pragma("wal_autocheckpoint", DEFAULT_WAL_CHECKPOINT)
            .busy_timeout(Duration::from_secs(DEFAULT_BUSY_TIMEOUT_SECS));
        let write_options = SqliteConnectOptions::from_str(url_db_path)?
            .pragma("journal_mode", "WAL")
            .pragma("synchronous", "FULL")
            .pragma("foreign_keys", "ON")
            .pragma("cache_size", DEFAULT_CACHE_SIZE)
            .pragma("temp_store", "MEMORY")
            .pragma("page_size", DEFAULT_PAGE_SIZE)
            .pragma("secure_delete", "OFF")
            .pragma("wal_autocheckpoint", DEFAULT_WAL_CHECKPOINT)
            .pragma("auto_vacuum", "INCREMENTAL")
            .busy_timeout(Duration::from_secs(DEFAULT_BUSY_TIMEOUT_SECS));
        let read_pool = SqlitePoolOptions::new()
            .max_connections(10)
            .min_connections(2)
            .acquire_timeout(Duration::from_secs(30))
            .idle_timeout(Some(Duration::from_secs(600)))
            .test_before_acquire(true)
            .connect_with(read_options)
            .await?;

        let write_pool = SqlitePoolOptions::new()
            .max_connections(1)
            .min_connections(1)
            .acquire_timeout(Duration::from_secs(30))
            .idle_timeout(Some(Duration::from_secs(600)))
            .test_before_acquire(true)
            .connect_with(write_options)
            .await?;

        let repo = Self {
            read_pool,
            write_pool: Arc::new(write_pool),
            write_semaphore: Arc::new(RwLock::new(Semaphore::new(1))),
            lock_semaphore: Arc::new(Semaphore::new(1)),
            cache,
            db_path,
        };

        repo.init_schema().await?;
        repo.check_and_repair_corruption().await?;
        Ok(repo)
    }

    fn get_read_conn(&self) -> &sqlx::SqlitePool {
        &self.read_pool
    }

    async fn get_write_conn(&self) -> Result<Arc<sqlx::SqlitePool>> {
        let _ = self
            .write_semaphore
            .read()
            .await
            .acquire()
            .await
            .map_err(|e| anyhow::anyhow!("Failed to acquire write semaphore: {}", e))?;
        Ok(Arc::clone(&self.write_pool))
    }

    async fn init_schema(&self) -> Result<()> {
        sqlx::migrate!("./migrations")
            .run(self.get_write_conn().await?.borrow())
            .await?;
        Ok(())
    }

    pub async fn check_and_repair_corruption(&self) -> Result<()> {
        use tracing::{error, info, warn};

        info!("Checking database integrity...");

        let quick_check = sqlx::query_scalar::<_, String>("PRAGMA quick_check")
            .fetch_one(self.get_read_conn())
            .await;

        match quick_check {
            Ok(result) if result == "ok" => {
                info!("Database quick check passed");
                return Ok(());
            }
            Ok(result) => {
                warn!("Database quick check failed: {}", result);
            }
            Err(e) => {
                error!("Failed to perform quick check: {}", e);
            }
        }

        info!("Performing full integrity check...");
        let integrity_check = sqlx::query_scalar::<_, String>("PRAGMA integrity_check")
            .fetch_one(self.get_read_conn())
            .await;

        match integrity_check {
            Ok(result) if result == "ok" => {
                info!("Database integrity check passed");
                return Ok(());
            }
            Ok(result) => {
                error!("Database corruption detected: {}", result);
            }
            Err(e) => {
                error!("Failed to perform integrity check: {}", e);
                return Err(e.into());
            }
        }

        warn!("Attempting database repair...");

        if let Err(e) = sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
            .execute(self.get_write_conn().await?.borrow())
            .await
        {
            error!("Failed to checkpoint WAL during repair: {}", e);
        }

        if let Err(e) = sqlx::query("PRAGMA incremental_vacuum")
            .execute(self.get_write_conn().await?.borrow())
            .await
        {
            error!("Failed to vacuum database during repair: {}", e);
        }

        let recheck = sqlx::query_scalar::<_, String>("PRAGMA integrity_check")
            .fetch_one(self.get_read_conn())
            .await;

        match recheck {
            Ok(result) if result == "ok" => {
                info!("Database repair successful");
                Ok(())
            }
            Ok(result) => {
                error!("Database repair failed, corruption persists: {}", result);
                Err(anyhow::anyhow!(
                    "Database corruption could not be repaired: {}",
                    result
                ))
            }
            Err(e) => {
                error!("Failed to recheck integrity after repair: {}", e);
                Err(e.into())
            }
        }
    }

    pub async fn perform_maintenance(&self) -> Result<()> {
        use tracing::{debug, info};

        info!("Starting database maintenance...");

        debug!("Checkpointing WAL...");
        sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
            .execute(self.get_write_conn().await?.borrow())
            .await?;

        debug!("Performing incremental vacuum...");
        sqlx::query("PRAGMA incremental_vacuum")
            .execute(self.get_write_conn().await?.borrow())
            .await?;

        debug!("Analyzing database statistics...");
        sqlx::query("PRAGMA analyze")
            .execute(self.get_write_conn().await?.borrow())
            .await?;

        info!("Database maintenance completed");
        Ok(())
    }

    pub(crate) async fn cleanup(&self) -> Result<()> {
        debug!("Starting DB cleanup");
        {
            let semaphore = self.write_semaphore.read().await;
            let _write_lock = semaphore.acquire().await?;
            trace!("Acquired write lock for cleanup");
        }

        trace!("Closing read connection pool...");
        self.read_pool.close().await;
        loop {
            if Arc::strong_count(&self.write_pool) == 1 {
                self.write_pool.close().await;
                let wal_path = format!("{}-wal", self.db_path);
                let shm_path = format!("{}-shm", self.db_path);

                // Attempt to remove WAL and SHM files
                for path in [&wal_path, &shm_path] {
                    if tokio::fs::remove_file(path).await.is_ok() {
                        trace!("Removed WAL / SHM file {}", path);
                    }
                }
                break;
            } else {
                trace!("Write pool still has other references, skipping write pool cleanup");
                continue;
            }
        }

        debug!("Database cleanup completed");
        Ok(())
    }

    pub async fn get_app_state(&self, key: &str) -> Result<Option<String>> {
        let row = sqlx::query!("SELECT value FROM app_state WHERE key = ?", key)
            .fetch_optional(self.get_read_conn())
            .await?;
        Ok(row.map(|r| r.value))
    }

    pub async fn set_app_state(&self, key: &str, value: &str) -> Result<()> {
        sqlx::query!(
            "INSERT OR REPLACE INTO app_state (key, value) VALUES (?, ?)",
            key,
            value
        )
        .execute(self.get_write_conn().await?.borrow())
        .await?;
        Ok(())
    }

    pub async fn remove_app_state(&self, key: &str) -> Result<()> {
        sqlx::query!("DELETE FROM app_state WHERE key = ?", key)
            .execute(self.get_write_conn().await?.borrow())
            .await?;
        Ok(())
    }

    pub async fn lock_writes(&self) -> Result<()> {
        trace!("Locking writes");
        // Force acquire the lock semaphore first
        let _lock = self
            .lock_semaphore
            .acquire()
            .await
            .map_err(|e| anyhow::anyhow!("Failed to acquire lock semaphore: {}", e))?;

        // Wait a small duration for current operations to complete
        tokio::time::sleep(Duration::from_millis(100)).await;

        // Force reset the write semaphore
        self.write_semaphore.write().await.close();
        let mut conn = self.write_pool.acquire().await?;
        sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
            .execute(&mut *conn)
            .await?;
        drop(conn);
        Ok(())
    }

    pub async fn unlock_writes(&self) -> Result<()> {
        debug!("Unlocking writes");
        let mut conn = self.write_pool.acquire().await?;
        sqlx::query("PRAGMA wal_checkpoint(PASSIVE)")
            .execute(&mut *conn)
            .await?;
        drop(conn);
        *self.write_semaphore.write().await = Semaphore::new(1);
        self.lock_semaphore.add_permits(1);
        Ok(())
    }
    async fn fetch_media(
        &self,
        media_file: UnfilledMediaFile,
        img_vid_id: uuid::Uuid,
        _thumb_id: uuid::Uuid,
    ) -> Result<FilledMediaFile> {
        // Single optimized query with JOIN to get both media and thumbnail data
        let query_str = match &media_file.media_type {
            MediaType::Image => {
                "SELECT i.id, i.width, i.height,
                        i.perceptual_hash, i.perceptual_hash_center, i.perceptual_hash_tl, i.perceptual_hash_tr, i.perceptual_hash_bl, i.perceptual_hash_br,
                        0 as duration_ms,
                        t.id as thumb_id, t.width as thumb_width, t.height as thumb_height, t.data as thumb_data
                 FROM images i JOIN thumbnails t ON i.thumbnail_id = t.id
                 WHERE i.id = ?"
            }
            MediaType::Video => {
                "SELECT v.id, v.width, v.height,
                        NULL as perceptual_hash, NULL as perceptual_hash_center, NULL as perceptual_hash_tl, NULL as perceptual_hash_tr, NULL as perceptual_hash_bl, NULL as perceptual_hash_br,
                        v.duration_ms,
                        t.id as thumb_id, t.width as thumb_width, t.height as thumb_height, t.data as thumb_data
                 FROM videos v JOIN thumbnails t ON v.thumbnail_id = t.id
                 WHERE v.id = ?"
            }
        };

        let row = sqlx::query(query_str)
            .bind(img_vid_id)
            .fetch_one(self.get_read_conn())
            .await?;

        let thumbnail = Thumbnail {
            id: row.get("thumb_id"),
            width: row.get("thumb_width"),
            height: row.get("thumb_height"),
            data: row.get("thumb_data"),
        };

        let mime_type = match media_file.mime_type.clone() {
            Some(mime) => mime,
            None => return Err(anyhow::anyhow!("Missing mime_type for media file")),
        };

        match &media_file.media_type {
            MediaType::Image => {
                let image = Image {
                    id: row.get("id"),
                    width: row.get("width"),
                    height: row.get("height"),
                    perceptual_hash: row.try_get("perceptual_hash").ok(),
                    perceptual_hash_center: row.try_get("perceptual_hash_center").ok(),
                    perceptual_hash_tl: row.try_get("perceptual_hash_tl").ok(),
                    perceptual_hash_tr: row.try_get("perceptual_hash_tr").ok(),
                    perceptual_hash_bl: row.try_get("perceptual_hash_bl").ok(),
                    perceptual_hash_br: row.try_get("perceptual_hash_br").ok(),
                    thumbnail,
                };
                Ok(media_file.with_image(image, mime_type.clone()))
            }
            MediaType::Video => {
                let video = Video {
                    id: row.get("id"),
                    width: row.get("width"),
                    height: row.get("height"),
                    duration_ms: row.get::<i64, _>("duration_ms") as u64,
                    thumbnail,
                };
                Ok(media_file.with_video(video, mime_type.clone()))
            }
        }
    }

    async fn get_file(&self, find_by: FindBy, with_media: bool) -> Result<MediaFile> {
        let main_query = "SELECT id, hash, created_at, filename, size, media_type, last_modified, is_favorite, mime_type FROM media_files WHERE";
        let query = match find_by {
            FindBy::Id(_) => format!("{} id = ?", main_query),
            FindBy::Hash(_) => format!("{} hash = ?", main_query),
            FindBy::Filename(_) => format!("{} filename = ?", main_query),
        };

        let query_builder = match find_by {
            FindBy::Id(id) => sqlx::query_as::<_, UnfilledMediaFile>(&query).bind(id),
            FindBy::Hash(hash) => sqlx::query_as::<_, UnfilledMediaFile>(&query).bind(hash),
            FindBy::Filename(filename) => {
                sqlx::query_as::<_, UnfilledMediaFile>(&query).bind(filename)
            }
        };
        let media_file: UnfilledMediaFile = query_builder.fetch_one(self.get_read_conn()).await?;
        if !with_media {
            Ok(MediaFile::Unfilled(media_file))
        } else {
            let media_file_id = media_file.id;
            let media_file_type = media_file.media_type.clone();

            let (img_vid_id, thumb_id) = self
                .get_img_vid_thumb_ids(media_file_id, media_file_type)
                .await?;

            let media_file = self.fetch_media(media_file, img_vid_id, thumb_id).await?;
            Ok(MediaFile::Filled(media_file))
        }
    }

    async fn get_img_vid_thumb_ids(
        &self,
        media_file_id: Uuid,
        media_type: MediaType,
    ) -> Result<(Uuid, Uuid)> {
        let cache_key = cache::get_img_vid_thumb_cache_key(media_file_id, &media_type);
        if let Some(ids) = self.cache.get::<(Uuid, Uuid)>(cache_key.clone()).await {
            return Ok(ids);
        }
        let query = match media_type {
        MediaType::Image => "SELECT id, thumbnail_id FROM images LEFT JOIN media_images ON images.id = media_images.image_id WHERE media_images.media_id = ?",
        MediaType::Video => "SELECT id, thumbnail_id FROM videos LEFT JOIN media_videos ON videos.id = media_videos.video_id WHERE media_videos.media_id = ?",
    };

        let (img_vid_id, thumb_id) = sqlx::query_as::<_, (Uuid, Uuid)>(query)
            .bind(media_file_id)
            .fetch_one(self.get_read_conn())
            .await?;
        self.cache.set(cache_key, &(img_vid_id, thumb_id)).await;
        Ok((img_vid_id, thumb_id))
    }
    pub async fn resolve_image_id(&self, media_file_id: Uuid) -> Result<Uuid> {
        let image_id: Uuid =
            sqlx::query_scalar("SELECT image_id FROM media_images WHERE media_id = ?")
                .bind(media_file_id)
                .fetch_one(self.get_read_conn())
                .await?;
        Ok(image_id)
    }

    pub async fn get_file_by_id(&self, id: uuid::Uuid, with_media: bool) -> Result<MediaFile> {
        self.get_file(FindBy::Id(id), with_media).await
    }

    pub async fn get_file_by_hash(&self, hash: String, with_media: bool) -> Result<MediaFile> {
        self.get_file(FindBy::Hash(hash.clone()), with_media).await
    }
    pub async fn get_file_by_filename(
        &self,
        filename: &str,
        with_media: bool,
    ) -> Result<MediaFile> {
        self.get_file(FindBy::Filename(filename.to_string()), with_media)
            .await
    }

    pub async fn get_stats(&self) -> Result<Stats> {
        if let Some(stats) = self
            .cache
            .get::<Stats>(cache::STATS_CACHE_KEY.to_string())
            .await
        {
            return Ok(stats);
        }
        let stats = sqlx::query_as::<_, Stats>(
            "SELECT count, images, videos, favorites FROM stats LIMIT 1",
        )
        .fetch_one(self.get_read_conn())
        .await?;
        self.cache
            .set(cache::STATS_CACHE_KEY.to_string(), &stats)
            .await;
        Ok(stats)
    }
    pub async fn exists_by_name(&self, filename: &str) -> Result<bool> {
        // Optimized EXISTS query using COUNT with LIMIT for early termination
        Ok(sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM media_files WHERE filename = ? LIMIT 1",
        )
        .bind(filename)
        .fetch_one(self.get_read_conn())
        .await?
            > 0)
    }

    pub async fn exists_by_hash(&self, hash: String) -> Result<bool> {
        // Optimized EXISTS query using COUNT with LIMIT for early termination
        Ok(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM media_files WHERE hash = ? LIMIT 1")
                .bind(hash)
                .fetch_one(self.get_read_conn())
                .await?
                > 0,
        )
    }

    pub async fn get_favorite_status(&self, file_id: Uuid) -> Result<bool> {
        let cache_key = cache::get_favorite_status_cache_key(&file_id);

        if let Some(status) = self.cache.get::<bool>(cache_key.clone()).await {
            debug!(
                "Cache hit for favorite status for file {} with status {}",
                file_id, status
            );
            return Ok(status);
        }

        // Optimized query with explicit type casting
        let is_fav: bool = sqlx::query_scalar("SELECT is_favorite FROM media_files WHERE id = ?")
            .bind(file_id)
            .fetch_one(self.get_read_conn())
            .await?;
        self.cache.set(cache_key, &is_fav).await;
        Ok(is_fav)
    }
    pub async fn batch_delete_files(&self, file_ids: Vec<Uuid>) -> Result<()> {
        if file_ids.is_empty() {
            return Ok(());
        }

        let mut tx = self.get_write_conn().await?.begin().await?;
        let placeholders = ["?"].repeat(file_ids.len()).join(",");

        // Optimized single query to get stats and delete in one operation using CTE
        let combined_query = format!(
            r#"WITH deleted_files AS (
                SELECT id, media_type, is_favorite, filename
                FROM media_files
                WHERE id IN ({})
            ),
            stats_calc AS (
                SELECT
                    COUNT(*) as total_count,
                    SUM(CASE WHEN media_type = 'Image' THEN 1 ELSE 0 END) as img_count,
                    SUM(CASE WHEN media_type = 'Video' THEN 1 ELSE 0 END) as vid_count,
                    SUM(CASE WHEN is_favorite = 1 THEN 1 ELSE 0 END) as fav_count
                FROM deleted_files
            )
            SELECT total_count, img_count, vid_count, fav_count FROM stats_calc"#,
            placeholders
        );

        let stats_row = file_ids
            .iter()
            .fold(sqlx::query(&combined_query), |builder, id| builder.bind(id))
            .fetch_one(&mut *tx)
            .await?;

        let count: i64 = stats_row.get("total_count");
        let img_count: i64 = stats_row.get("img_count");
        let vid_count: i64 = stats_row.get("vid_count");
        let fav_count: i64 = stats_row.get("fav_count");

        // Delete the files
        let delete_query = format!("DELETE FROM media_files WHERE id IN ({})", placeholders);
        file_ids
            .iter()
            .fold(sqlx::query(&delete_query), |builder, id| builder.bind(id))
            .execute(&mut *tx)
            .await?;

        // Update stats in single query
        sqlx::query!(
            "UPDATE stats SET count = count - ?, images = images - ?, videos = videos - ?, favorites = favorites - ? WHERE id = 1",
            count,
            img_count,
            vid_count,
            fav_count,
        )
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;

        // Cache invalidation
        self.cache.invalidate_stats_cache();
        self.cache.invalidate_files_cache();
        for file_id in &file_ids {
            self.cache.invalidate_file_cache(file_id);
            self.cache.invalidate_favorite_status_cache(file_id);
        }
        Ok(())
    }

    /// Atomically insert or update a file, handling duplicates gracefully
    /// Returns Ok(MediaFile) if successful, Err if file should be treated as duplicate
    pub async fn upsert_file(&self, media_file: FilledMediaFile) -> Result<MediaFile> {
        let mut tx = self.get_write_conn().await?.begin().await?;

        // Check if file with same hash exists
        let existing_by_hash: Option<UnfilledMediaFile> = sqlx::query_as::<_, UnfilledMediaFile>(
            "SELECT id, hash, created_at, filename, size, media_type, last_modified, is_favorite, mime_type FROM media_files WHERE hash = ?"
        )
        .bind(&media_file.hash)
        .fetch_optional(&mut *tx)
        .await?;

        // Check if file with same filename exists
        let existing_by_filename: Option<UnfilledMediaFile> = sqlx::query_as::<_, UnfilledMediaFile>(
            "SELECT id, hash, created_at, filename, size, media_type, last_modified, is_favorite, mime_type FROM media_files WHERE filename = ?"
        )
        .bind(&media_file.filename)
        .fetch_optional(&mut *tx)
        .await?;

        match (existing_by_hash, existing_by_filename) {
            (Some(mut existing_by_hash), _) => {
                // File with same hash exists - check if it's the same filename
                if existing_by_hash.filename == media_file.filename {
                    // Same file, check if it needs updating
                    if existing_by_hash.last_modified != media_file.last_modified {
                        // Update the existing file
                        self.update_file_in_transaction(
                            &mut tx,
                            existing_by_hash.id,
                            &media_file.filename,
                            media_file.last_modified,
                            media_file.size,
                        )
                        .await?;
                        existing_by_hash.last_modified = media_file.last_modified;
                        existing_by_hash.size = media_file.size;
                    }
                    tx.commit().await?;
                    return Ok(MediaFile::Unfilled(existing_by_hash));
                } else {
                    // Different filename but same hash - this is a duplicate
                    debug!(
                        "Duplicate detected: hash '{}' found in files '{}' and '{}'",
                        media_file.hash, existing_by_hash.filename, media_file.filename
                    );
                    tx.rollback().await?;
                    return Err(anyhow::anyhow!(
                        "Duplicate file detected: hash exists with different filename"
                    ));
                }
            }
            (None, Some(existing_by_filename)) => {
                // Same filename but different hash - file was modified
                debug!("File {} was modified, updating record", media_file.filename);
                self.delete_file_in_transaction(&mut tx, existing_by_filename.id)
                    .await?;
                // Continue to insert the new file
            }
            (None, None) => {
                // New file - continue with insertion
            }
        }

        // Insert the new file
        let result = match &media_file.media_type {
            MediaType::Image => {
                self.insert_image_in_transaction(&mut tx, media_file.clone())
                    .await
            }
            MediaType::Video => {
                self.insert_video_in_transaction(&mut tx, media_file.clone())
                    .await
            }
        };

        if result.is_err() {
            tx.rollback().await?;
            return result.map(|_| MediaFile::Filled(media_file));
        }

        tx.commit().await?;

        // Update cache
        self.cache.invalidate_stats_cache();
        self.cache.invalidate_files_cache();
        self.cache
            .invalidate_img_vid_thumb_cache(&media_file.id, &media_file.media_type);
        self.cache.invalidate_favorite_status_cache(&media_file.id);

        Ok(MediaFile::Filled(media_file))
    }

    pub async fn insert_file(&self, media_file: FilledMediaFile) -> Result<()> {
        let clone = media_file.clone();
        let result = match &media_file.media_type {
            MediaType::Image => self.insert_image(media_file).await,
            MediaType::Video => self.insert_video(media_file).await,
        };
        if result.is_ok() {
            self.cache.invalidate_stats_cache();
            self.cache.invalidate_files_cache();
            self.cache
                .invalidate_img_vid_thumb_cache(&clone.id, &clone.media_type);
            self.cache.invalidate_favorite_status_cache(&clone.id);
        }
        result
    }
    async fn insert_image_in_transaction(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
        media_file: FilledMediaFile,
    ) -> Result<()> {
        debug!("Saving image to database {}", media_file.filename);
        let image = media_file.media.as_image().expect("Should be an image");

        // Insert thumbnail first
        let thumb_id = image.thumbnail.id;
        let thumb_width = image.thumbnail.width;
        let thumb_height = image.thumbnail.height;
        let thumb_data = &image.thumbnail.data;
        sqlx::query!(
            r#"INSERT INTO thumbnails (id, width, height, data) VALUES (?, ?, ?, ?)"#,
            thumb_id,
            thumb_width,
            thumb_height,
            thumb_data,
        )
        .execute(&mut **tx)
        .await?;

        sqlx::query!(
            r#"INSERT INTO images (
                    id, width, height, thumbnail_id,
                    perceptual_hash, perceptual_hash_center, perceptual_hash_tl, perceptual_hash_tr, perceptual_hash_bl, perceptual_hash_br
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"#,
            image.id,
            image.width,
            image.height,
            image.thumbnail.id,
            image.perceptual_hash,
            image.perceptual_hash_center,
            image.perceptual_hash_tl,
            image.perceptual_hash_tr,
            image.perceptual_hash_bl,
            image.perceptual_hash_br,
        )
            .execute(&mut **tx)
            .await?;

        let hash = &media_file.hash;
        let filename = &media_file.filename;
        let media_type = &media_file.media_type;
        let mime_type = &media_file.mime_type;
        sqlx::query!(r#"INSERT INTO media_files (id, hash, created_at, filename, media_type, last_modified, size, mime_type)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)"#,
            media_file.id,
            hash,
            media_file.created_at,
            filename,
            media_type,
            media_file.last_modified,
            media_file.size,
            mime_type,
        )
        .execute(&mut **tx)
        .await?;

        sqlx::query!(
            "INSERT INTO media_images (media_id, image_id) VALUES (?, ?)",
            media_file.id,
            image.id
        )
        .execute(&mut **tx)
        .await?;

        sqlx::query!("UPDATE stats SET count = count + 1, images = images + 1 WHERE id = 1")
            .execute(&mut **tx)
            .await?;

        Ok(())
    }

    async fn insert_image(&self, media_file: FilledMediaFile) -> Result<()> {
        debug!("Saving image to database {}", media_file.filename);
        let image = media_file.media.as_image().expect("Should be an image");
        let thumbnail = image.thumbnail.clone();

        let mut tx = self.get_write_conn().await?.begin().await?;

        sqlx::query!(
            r#"INSERT INTO thumbnails (id, width, height, data) VALUES (?, ?, ?, ?)"#,
            thumbnail.id,
            thumbnail.width,
            thumbnail.height,
            thumbnail.data,
        )
        .execute(&mut *tx)
        .await?;

        sqlx::query!(
            r#"INSERT INTO images (
                    id, width, height, thumbnail_id,
                    perceptual_hash, perceptual_hash_center, perceptual_hash_tl, perceptual_hash_tr, perceptual_hash_bl, perceptual_hash_br
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"#,
            image.id,
            image.width,
            image.height,
            thumbnail.id,
            image.perceptual_hash,
            image.perceptual_hash_center,
            image.perceptual_hash_tl,
            image.perceptual_hash_tr,
            image.perceptual_hash_bl,
            image.perceptual_hash_br,
        )
            .execute(&mut *tx)
            .await?;

        let hash = &media_file.hash;
        let filename = &media_file.filename;
        let media_type = &media_file.media_type;
        let mime_type = &media_file.mime_type;
        sqlx::query!(r#"INSERT INTO media_files (id, hash, created_at, filename, media_type, last_modified, size, mime_type)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)"#,
            media_file.id,
            hash,
            media_file.created_at,
            filename,
            media_type,
            media_file.last_modified,
            media_file.size,
            mime_type,
        )
        .execute(&mut *tx)
        .await?;

        sqlx::query!(
            "INSERT INTO media_images (media_id, image_id) VALUES (?, ?)",
            media_file.id,
            image.id
        )
        .execute(&mut *tx)
        .await?;

        sqlx::query!("UPDATE stats SET count = count + 1, images = images + 1 WHERE id = 1")
            .execute(&mut *tx)
            .await?;

        tx.commit().await?;
        Ok(())
    }

    async fn insert_video_in_transaction(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
        media_file: FilledMediaFile,
    ) -> Result<()> {
        debug!("Saving video to database {}", media_file.filename);
        let video = media_file.media.as_video().expect("Should be a video");

        // Insert thumbnail first
        let thumb_id = video.thumbnail.id;
        let thumb_width = video.thumbnail.width;
        let thumb_height = video.thumbnail.height;
        let thumb_data = &video.thumbnail.data;
        sqlx::query!(
            r#"INSERT INTO thumbnails (id, width, height, data) VALUES (?, ?, ?, ?)"#,
            thumb_id,
            thumb_width,
            thumb_height,
            thumb_data,
        )
        .execute(&mut **tx)
        .await?;

        let duration = video.duration_ms as i64;
        sqlx::query!(
            r#"INSERT INTO videos (id, width, height, duration_ms, thumbnail_id)
                   VALUES (?, ?, ?, ?, ?)"#,
            video.id,
            video.width,
            video.height,
            duration,
            video.thumbnail.id,
        )
        .execute(&mut **tx)
        .await?;

        let hash = &media_file.hash;
        let filename = &media_file.filename;
        let media_type = &media_file.media_type;
        let mime_type = &media_file.mime_type;
        sqlx::query!(r#"INSERT INTO media_files (id, hash, created_at, filename, media_type, last_modified, size, mime_type)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)"#,
            media_file.id,
            hash,
            media_file.created_at,
            filename,
            media_type,
            media_file.last_modified,
            media_file.size,
            mime_type,
        )
        .execute(&mut **tx)
        .await?;

        sqlx::query!(
            "INSERT INTO media_videos (media_id, video_id) VALUES (?, ?)",
            media_file.id,
            video.id
        )
        .execute(&mut **tx)
        .await?;

        sqlx::query!("UPDATE stats SET count = count + 1, videos = videos + 1 WHERE id = 1")
            .execute(&mut **tx)
            .await?;

        Ok(())
    }

    async fn insert_video(&self, media_file: FilledMediaFile) -> Result<()> {
        debug!("Saving video to database {}", media_file.filename);
        let video = media_file.media.as_video().expect("Should be a video");
        let thumbnail = video.thumbnail.clone();

        let mut tx = self.get_write_conn().await?.begin().await?;

        sqlx::query!(
            r#"INSERT INTO thumbnails (id, width, height, data) VALUES (?, ?, ?, ?)"#,
            thumbnail.id,
            thumbnail.width,
            thumbnail.height,
            thumbnail.data,
        )
        .execute(&mut *tx)
        .await?;

        let duration = video.duration_ms as i64;
        sqlx::query!(
            r#"INSERT INTO videos (id, width, height, duration_ms, thumbnail_id)
                   VALUES (?, ?, ?, ?, ?)"#,
            video.id,
            video.width,
            video.height,
            duration,
            thumbnail.id,
        )
        .execute(&mut *tx)
        .await?;

        let hash = &media_file.hash;
        let filename = &media_file.filename;
        let media_type = &media_file.media_type;
        let mime_type = &media_file.mime_type;
        sqlx::query!(r#"INSERT INTO media_files (id, hash, created_at, filename, media_type, last_modified, size, mime_type)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)"#,
            media_file.id,
            hash,
            media_file.created_at,
            filename,
            media_type,
            media_file.last_modified,
            media_file.size,
            mime_type,
        )
        .execute(&mut *tx)
        .await?;

        sqlx::query!(
            "INSERT INTO media_videos (media_id, video_id) VALUES (?, ?)",
            media_file.id,
            video.id
        )
        .execute(&mut *tx)
        .await?;

        sqlx::query!("UPDATE stats SET count = count + 1, videos = videos + 1 WHERE id = 1")
            .execute(&mut *tx)
            .await?;

        tx.commit().await?;
        Ok(())
    }
    async fn update_file_in_transaction(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
        file_id: Uuid,
        new_file_name: &str,
        last_modified: DateTime<Utc>,
        size: i64,
    ) -> Result<()> {
        sqlx::query!(
            "UPDATE media_files SET filename = ?, last_modified = ?, size = ? WHERE id = ?",
            new_file_name,
            last_modified,
            size,
            file_id,
        )
        .execute(&mut **tx)
        .await?;
        Ok(())
    }

    async fn delete_file_in_transaction(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
        file_id: Uuid,
    ) -> Result<()> {
        // Get file info for stats update
        let file_info: Option<(MediaType, bool)> = sqlx::query_as::<_, (MediaType, bool)>(
            "SELECT media_type, is_favorite FROM media_files WHERE id = ?",
        )
        .bind(file_id)
        .fetch_optional(&mut **tx)
        .await?;

        if let Some((media_type, is_favorite)) = file_info {
            // Delete the file (cascades to related tables)
            sqlx::query!("DELETE FROM media_files WHERE id = ?", file_id)
                .execute(&mut **tx)
                .await?;

            // Update stats
            let (img_change, vid_change, fav_change) = match media_type {
                MediaType::Image => (-1, 0, if is_favorite { -1 } else { 0 }),
                MediaType::Video => (0, -1, if is_favorite { -1 } else { 0 }),
            };

            sqlx::query!(
                "UPDATE stats SET count = count + ?, images = images + ?, videos = videos + ?, favorites = favorites + ? WHERE id = 1",
                -1,
                img_change,
                vid_change,
                fav_change,
            )
            .execute(&mut **tx)
            .await?;
        }

        Ok(())
    }

    pub async fn update_file_name_and_modified_date(
        &self,
        file_id: Uuid,
        new_file_name: &str,
        last_modified: DateTime<Utc>,
    ) -> Result<()> {
        let mut tx = self.get_write_conn().await?.begin().await?;
        sqlx::query!(
            "UPDATE media_files SET filename = ?, last_modified = ? WHERE id = ?",
            new_file_name,
            last_modified,
            file_id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        self.cache.invalidate_file_cache(&file_id);
        self.cache.invalidate_files_cache();
        Ok(())
    }

    pub async fn remove_non_existing_files_by_hashes(&self, hashes: Vec<String>) -> Result<()> {
        if hashes.is_empty() {
            return Ok(());
        }

        let placeholders = ["?"].repeat(hashes.len()).join(",");
        let query = format!(
            "SELECT media_type, is_favorite FROM media_files WHERE id IN ({})",
            placeholders
        );
        let data = hashes
            .iter()
            .fold(
                sqlx::query_as::<_, (MediaType, bool)>(&query),
                |builder, hash| builder.bind(hash),
            )
            .fetch_all(self.get_read_conn())
            .await?;

        let count = data.len() as i64;
        let img_count = data.iter().filter(|(t, _)| *t == MediaType::Image).count() as i64;
        let vid_count = data.iter().filter(|(t, _)| *t == MediaType::Video).count() as i64;
        let fav_count = data.iter().filter(|(_, f)| *f).count() as i64;

        let mut tx = self.get_write_conn().await?.begin().await?;
        let query = format!(
            "DELETE FROM media_files WHERE hash NOT IN ({})",
            placeholders
        );
        hashes
            .iter()
            .fold(sqlx::query(&query), |builder, hash| builder.bind(hash))
            .execute(&mut *tx)
            .await?;

        // Optimized single stats update query
        sqlx::query!(
            "UPDATE stats SET count = count - ?, images = images - ?, videos = videos - ?, favorites = favorites - ? WHERE id = 1",
            count,
            img_count,
            vid_count,
            fav_count,
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        self.cache.invalidate_stats_cache();
        self.cache.invalidate_files_cache();
        Ok(())
    }

    pub async fn toggle_favorite_status(&self, file_id: Uuid) -> Result<()> {
        let mut tx = self.get_write_conn().await?.begin().await?;
        let is_favorite: bool =
            sqlx::query_scalar("SELECT is_favorite FROM media_files WHERE id = ?")
                .bind(file_id)
                .fetch_one(&mut *tx)
                .await?;
        let new_fav = !is_favorite;
        sqlx::query!(
            "UPDATE media_files SET is_favorite = ? WHERE id = ?",
            new_fav,
            file_id
        )
        .execute(&mut *tx)
        .await?;
        // Optimized stats update - note: count stays the same, only favorites change
        let fav_change = if new_fav { 1 } else { -1 };
        sqlx::query!(
            "UPDATE stats SET favorites = favorites + ? WHERE id = 1",
            fav_change
        )
        .execute(&mut *tx)
        .await?;
        self.cache.invalidate_stats_cache();
        self.cache.invalidate_file_cache(&file_id);
        debug!(
            "Toggling favorite status for file {} with status {}",
            file_id, !is_favorite
        );
        self.cache.invalidate_favorite_status_cache(&file_id);
        self.cache.invalidate_files_cache();
        tx.commit().await?;
        Ok(())
    }

    pub async fn has_missing_perceptual_hashes(&self, media_file_id: Uuid) -> Result<bool> {
        let has_missing: bool = sqlx::query_scalar(
            r#"SELECT EXISTS(
                SELECT 1 FROM media_images mi
                JOIN images i ON i.id = mi.image_id
                WHERE mi.media_id = ?
                AND (
                    i.perceptual_hash IS NULL
                    OR i.perceptual_hash_center IS NULL
                    OR i.perceptual_hash_tl IS NULL
                    OR i.perceptual_hash_tr IS NULL
                    OR i.perceptual_hash_bl IS NULL
                    OR i.perceptual_hash_br IS NULL
                )
            )"#,
        )
        .bind(media_file_id)
        .fetch_one(self.get_read_conn())
        .await?;
        Ok(has_missing)
    }

    pub async fn update_image_perceptual_hashes(
        &self,
        media_file_id: Uuid,
        perceptual_hash: Option<i64>,
        perceptual_hash_center: Option<i64>,
        perceptual_hash_tl: Option<i64>,
        perceptual_hash_tr: Option<i64>,
        perceptual_hash_bl: Option<i64>,
        perceptual_hash_br: Option<i64>,
    ) -> Result<()> {
        let mut tx = self.get_write_conn().await?.begin().await?;
        sqlx::query!(
            r#"UPDATE images SET
                    perceptual_hash = ?,
                    perceptual_hash_center = ?,
                    perceptual_hash_tl = ?,
                    perceptual_hash_tr = ?,
                    perceptual_hash_bl = ?,
                    perceptual_hash_br = ?
                WHERE id = (
                    SELECT image_id FROM media_images WHERE media_id = ?
                )"#,
            perceptual_hash,
            perceptual_hash_center,
            perceptual_hash_tl,
            perceptual_hash_tr,
            perceptual_hash_bl,
            perceptual_hash_br,
            media_file_id,
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn get_files(
        &self,
        query: FilledFileQuery,
    ) -> Result<(Pagination, Vec<FilledMediaFile>)> {
        let cache_key = cache::get_files_cache_key(&query);

        // Check cache for all queries, including random ordered ones
        if let Some(result) = self
            .cache
            .get::<(Pagination, Vec<FilledMediaFile>)>(cache_key.clone())
            .await
        {
            return Ok(result);
        }
        let stats = self.get_stats().await?;
        let total_records = match query.file_type {
            FileQueryType::Image => stats.images,
            FileQueryType::Video => stats.videos,
            FileQueryType::Favorite => stats.favorites,
            _ => stats.count,
        };
        let total_pages = (total_records as f64 / query.page_size as f64).ceil() as u32;
        let offset = (query.page - 1) * query.page_size;
        let pagination = Pagination {
            count: total_records,
            current_page: query.page,
            total_pages,
            next_page: if query.page < total_pages {
                Some(query.page + 1)
            } else {
                None
            },
            prev_page: if query.page > 1 {
                Some(query.page - 1)
            } else {
                None
            },
        };

        // Optimize random ordering with proper seeded randomness
        let order_by = match query.order.as_str() {
            "random" => {
                if let Some(seed) = query.seed {
                    // Use deterministic hash-based ordering with seed
                    // This combines the rowid with the seed for deterministic randomness
                    format!(
                        "(((mf.rowid + {}) * 1103515245 + 12345) % 2147483647)",
                        seed
                    )
                } else {
                    "RANDOM()".to_string()
                }
            }
            _ => format!("mf.created_at {}", query.direction),
        };

        let only_favs = if query.file_type == FileQueryType::Favorite {
            "AND mf.is_favorite = 1"
        } else {
            ""
        };
        let mime_cond = match query.file_type {
            FileQueryType::Image => "AND mf.media_type = 'Image'",
            FileQueryType::Video => "AND mf.media_type = 'Video'",
            _ => "",
        };

        // Single optimized query with JOINs - eliminates N+1 problem
        let query_str = format!(
            r#"SELECT
                mf.id, mf.hash, mf.created_at, mf.filename, mf.size, mf.media_type,
                mf.last_modified, mf.is_favorite, mf.mime_type,
                COALESCE(i.id, v.id) as media_id,
                 COALESCE(i.width, v.width) as width,
                 COALESCE(i.height, v.height) as height,
                 i.perceptual_hash,
                 i.perceptual_hash_center,
                 i.perceptual_hash_tl,
                 i.perceptual_hash_tr,
                 i.perceptual_hash_bl,
                 i.perceptual_hash_br,
                 COALESCE(v.duration_ms, 0) as duration_ms,
                 t.id as thumbnail_id, t.width as thumb_width, t.height as thumb_height, t.data as thumb_data
             FROM media_files mf
            LEFT JOIN media_images mi ON mf.id = mi.media_id
            LEFT JOIN images i ON mi.image_id = i.id
            LEFT JOIN media_videos mv ON mf.id = mv.media_id
            LEFT JOIN videos v ON mv.video_id = v.id
            LEFT JOIN thumbnails t ON (i.thumbnail_id = t.id OR v.thumbnail_id = t.id)
            WHERE 1=1 {} {}
            ORDER BY {}
            LIMIT {} OFFSET {}"#,
            only_favs, mime_cond, order_by, query.page_size, offset
        );

        let rows = sqlx::query(&query_str)
            .fetch_all(self.get_read_conn())
            .await?;

        let filled_files: Vec<FilledMediaFile> = rows
            .into_iter()
            .map(|row| {
                let media_file = UnfilledMediaFile {
                    id: row.get("id"),
                    hash: row.get("hash"),
                    created_at: row.get("created_at"),
                    filename: row.get("filename"),
                    size: row.get("size"),
                    media_type: row.get("media_type"),
                    last_modified: row.get("last_modified"),
                    is_favorite: row.get("is_favorite"),
                    mime_type: row.get("mime_type"),
                    media: None,
                };

                let thumbnail = Thumbnail {
                    id: row.get("thumbnail_id"),
                    width: row.get("thumb_width"),
                    height: row.get("thumb_height"),
                    data: row.get("thumb_data"),
                };

                let mime_type = match media_file.mime_type.clone() {
                    Some(mime) => mime,
                    None => return Err(anyhow::anyhow!("Missing mime_type for media file")),
                };
                match media_file.media_type {
                    MediaType::Image => {
                        let image = Image {
                            id: row.get("media_id"),
                            width: row.get("width"),
                            height: row.get("height"),
                            perceptual_hash: row.try_get("perceptual_hash").ok(),
                            perceptual_hash_center: row.try_get("perceptual_hash_center").ok(),
                            perceptual_hash_tl: row.try_get("perceptual_hash_tl").ok(),
                            perceptual_hash_tr: row.try_get("perceptual_hash_tr").ok(),
                            perceptual_hash_bl: row.try_get("perceptual_hash_bl").ok(),
                            perceptual_hash_br: row.try_get("perceptual_hash_br").ok(),
                            thumbnail,
                        };
                        Ok(media_file.with_image(image, mime_type.clone()))
                    }
                    MediaType::Video => {
                        let video = Video {
                            id: row.get("media_id"),
                            width: row.get("width"),
                            height: row.get("height"),
                            duration_ms: row.get::<i64, _>("duration_ms") as u64,
                            thumbnail,
                        };
                        Ok(media_file.with_video(video, mime_type))
                    }
                }
            })
            .collect::<Result<Vec<_>, _>>()?;

        let result = (pagination, filled_files);
        self.cache.set(cache_key, &result).await;
        Ok(result)
    }

    // ===== Clustering Methods =====

    pub async fn get_all_perceptual_hashes(&self) -> Result<Vec<(uuid::Uuid, Vec<i64>)>> {
        let rows = sqlx::query!(
            r#"SELECT
                    i.id,
                    i.perceptual_hash,
                    i.perceptual_hash_center,
                    i.perceptual_hash_tl,
                    i.perceptual_hash_tr,
                    i.perceptual_hash_bl,
                    i.perceptual_hash_br
               FROM images i
               JOIN media_images mi ON i.id = mi.image_id
               JOIN media_files mf ON mi.media_id = mf.id
               WHERE (
                    i.perceptual_hash IS NOT NULL OR
                    i.perceptual_hash_center IS NOT NULL OR
                    i.perceptual_hash_tl IS NOT NULL OR
                    i.perceptual_hash_tr IS NOT NULL OR
                    i.perceptual_hash_bl IS NOT NULL OR
                    i.perceptual_hash_br IS NOT NULL
               )"#
        )
        .fetch_all(self.get_read_conn())
        .await?;

        Ok(rows
            .into_iter()
            .filter_map(|row| {
                let id = uuid::Uuid::from_slice(&row.id).ok()?;
                let mut hashes = Vec::with_capacity(6);
                if let Some(v) = row.perceptual_hash {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_center {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_tl {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_tr {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_bl {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_br {
                    hashes.push(v);
                }
                if hashes.is_empty() {
                    None
                } else {
                    Some((id, hashes))
                }
            })
            .collect())
    }

    pub async fn create_cluster(&self, representative_id: uuid::Uuid) -> Result<i64> {
        let created_at = chrono::Utc::now().to_rfc3339();
        let write_conn = self.get_write_conn().await?;
        let result = sqlx::query!(
            "INSERT INTO image_clusters (representative_image_id, created_at, is_resolved) VALUES (?, ?, 0)",
            representative_id,
            created_at
        )
        .execute(write_conn.as_ref())
        .await?;

        Ok(result.last_insert_rowid())
    }

    pub async fn add_to_cluster(
        &self,
        cluster_id: i64,
        image_id: uuid::Uuid,
        distance: u32,
    ) -> Result<()> {
        let added_at = chrono::Utc::now().to_rfc3339();
        let distance_i32 = distance as i32;
        let write_conn = self.get_write_conn().await?;

        sqlx::query!(
            "INSERT INTO cluster_members (cluster_id, image_id, hamming_distance, is_best_shot, added_at)
             VALUES (?, ?, ?, 0, ?)",
            cluster_id,
            image_id,
            distance_i32,
            added_at
        )
        .execute(write_conn.as_ref())
        .await?;

        Ok(())
    }

    /// Batch insert cluster members for efficient bulk operations
    pub async fn add_batch_to_cluster(
        &self,
        cluster_id: i64,
        members: &[(uuid::Uuid, u32)], // (image_id, hamming_distance)
    ) -> Result<()> {
        if members.is_empty() {
            return Ok(());
        }

        let added_at = chrono::Utc::now().to_rfc3339();
        let write_conn = self.get_write_conn().await?;

        // Build batch insert query
        // SQLite supports multi-row INSERT
        let mut query = String::from(
            "INSERT INTO cluster_members (cluster_id, image_id, hamming_distance, is_best_shot, added_at) VALUES "
        );

        let placeholders: Vec<String> = (0..members.len())
            .map(|_| "(?, ?, ?, 0, ?)".to_string())
            .collect();
        query.push_str(&placeholders.join(", "));

        let mut query_builder = sqlx::query(&query);

        // Bind parameters
        for (image_id, distance) in members {
            query_builder = query_builder
                .bind(cluster_id)
                .bind(*image_id)
                .bind(*distance as i32)
                .bind(&added_at);
        }

        query_builder.execute(write_conn.as_ref()).await?;

        Ok(())
    }

    pub async fn get_cluster_member_count(&self, cluster_id: i64) -> Result<i64> {
        let result = sqlx::query!(
            "SELECT COUNT(*) as count FROM cluster_members WHERE cluster_id = ?",
            cluster_id
        )
        .fetch_one(self.get_read_conn())
        .await?;

        Ok(result.count as i64)
    }

    pub async fn delete_cluster(&self, cluster_id: i64) -> Result<()> {
        let write_conn = self.get_write_conn().await?;
        sqlx::query!(
            "DELETE FROM image_clusters WHERE cluster_id = ?",
            cluster_id
        )
        .execute(write_conn.as_ref())
        .await?;

        Ok(())
    }

    pub async fn replace_clusters(
        &self,
        old_cluster_ids: &[i64],
        representative_id: Uuid,
        members: &[(Uuid, u32)],
    ) -> Result<i64> {
        let write_conn = self.get_write_conn().await?;
        let mut tx = write_conn.begin().await?;

        for &old_cluster_id in old_cluster_ids {
            sqlx::query!(
                "DELETE FROM cluster_members WHERE cluster_id = ?",
                old_cluster_id
            )
            .execute(&mut *tx)
            .await?;

            sqlx::query!(
                "DELETE FROM image_clusters WHERE cluster_id = ?",
                old_cluster_id
            )
            .execute(&mut *tx)
            .await?;
        }

        let added_at = chrono::Utc::now().to_rfc3339();

        let at = &added_at;
        let cluster_id: i64 = sqlx::query!(
            "INSERT INTO image_clusters (representative_image_id, created_at, is_resolved) VALUES (?, ?, 0)",
            representative_id,
            at,
        )
        .execute(&mut *tx)
        .await?
        .last_insert_rowid();

        if !members.is_empty() {
            let mut query = String::from(
                "INSERT INTO cluster_members (cluster_id, image_id, hamming_distance, is_best_shot, added_at) VALUES "
            );
            let placeholders: Vec<String> = (0..members.len())
                .map(|_| "(?, ?, ?, 0, ?)".to_string())
                .collect();
            query.push_str(&placeholders.join(", "));

            let mut query_builder = sqlx::query(&query);
            for (image_id, distance) in members {
                query_builder = query_builder
                    .bind(cluster_id)
                    .bind(*image_id)
                    .bind(*distance as i32)
                    .bind(&added_at);
            }
            query_builder.execute(&mut *tx).await?;
        }

        tx.commit().await?;
        Ok(cluster_id)
    }

    pub async fn get_all_clusters_with_members(&self) -> Result<Vec<super::ExistingCluster>> {
        let rows = sqlx::query!(
            r#"SELECT
                   ic.cluster_id,
                   ic.representative_image_id,
                   cm.image_id,
                   cm.hamming_distance
               FROM image_clusters ic
               JOIN cluster_members cm ON cm.cluster_id = ic.cluster_id
               ORDER BY ic.cluster_id"#,
        )
        .fetch_all(self.get_read_conn())
        .await?;

        let mut result: Vec<super::ExistingCluster> = Vec::new();
        let mut current_cluster_id: Option<i64> = None;

        for row in rows {
            let cluster_id = row.cluster_id;

            if current_cluster_id != Some(cluster_id) {
                let representative_id = Uuid::from_slice(&row.representative_image_id)
                    .map_err(|e| anyhow::anyhow!("Invalid UUID: {}", e))?;

                result.push(super::ExistingCluster {
                    cluster_id,
                    representative_id,
                    members: Vec::new(),
                });
                current_cluster_id = Some(cluster_id);
            }

            if let Ok(id) = Uuid::from_slice(&row.image_id) {
                if let Some(last) = result.last_mut() {
                    last.members.push((id, row.hamming_distance as u32));
                }
            }
        }

        Ok(result)
    }

    pub async fn clear_clusters(&self) -> Result<()> {
        let write_conn = self.get_write_conn().await?;

        sqlx::query!("DELETE FROM cluster_members")
            .execute(write_conn.as_ref())
            .await?;

        sqlx::query!("DELETE FROM image_clusters")
            .execute(write_conn.as_ref())
            .await?;

        Ok(())
    }

    pub async fn cleanup_orphaned_data(&self) -> Result<(i64, i64)> {
        let write_conn = self.get_write_conn().await?;

        // Delete orphaned cluster_members (images that no longer exist in media_files)
        let cluster_members_deleted = sqlx::query!(
            r#"DELETE FROM cluster_members
               WHERE image_id NOT IN (
                   SELECT i.id FROM images i
                   JOIN media_images mi ON i.id = mi.image_id
                   JOIN media_files mf ON mi.media_id = mf.id
               )"#
        )
        .execute(write_conn.as_ref())
        .await?
        .rows_affected() as i64;

        // Delete orphaned images (no corresponding media_files entry)
        let images_deleted = sqlx::query!(
            r#"DELETE FROM images
               WHERE id NOT IN (
                   SELECT i.id FROM images i
                   JOIN media_images mi ON i.id = mi.image_id
                   JOIN media_files mf ON mi.media_id = mf.id
               )"#
        )
        .execute(write_conn.as_ref())
        .await?
        .rows_affected() as i64;

        info!(
            "Cleaned up {} orphaned cluster members and {} orphaned images",
            cluster_members_deleted, images_deleted
        );

        Ok((cluster_members_deleted, images_deleted))
    }

    pub async fn get_cluster_representatives(&self) -> Result<Vec<(i64, Vec<i64>)>> {
        let rows = sqlx::query!(
            r#"SELECT
                    c.cluster_id,
                    i.perceptual_hash,
                    i.perceptual_hash_center,
                    i.perceptual_hash_tl,
                    i.perceptual_hash_tr,
                    i.perceptual_hash_bl,
                    i.perceptual_hash_br
               FROM image_clusters c
               JOIN images i ON c.representative_image_id = i.id
               WHERE (
                    i.perceptual_hash IS NOT NULL OR
                    i.perceptual_hash_center IS NOT NULL OR
                    i.perceptual_hash_tl IS NOT NULL OR
                    i.perceptual_hash_tr IS NOT NULL OR
                    i.perceptual_hash_bl IS NOT NULL OR
                    i.perceptual_hash_br IS NOT NULL
               )"#
        )
        .fetch_all(self.get_read_conn())
        .await?;

        Ok(rows
            .into_iter()
            .filter_map(|row| {
                let mut hashes = Vec::with_capacity(6);
                if let Some(v) = row.perceptual_hash {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_center {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_tl {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_tr {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_bl {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_br {
                    hashes.push(v);
                }
                if hashes.is_empty() {
                    None
                } else {
                    Some((row.cluster_id, hashes))
                }
            })
            .collect())
    }

    pub async fn get_cluster_members_with_hashes(
        &self,
        cluster_id: i64,
    ) -> Result<Vec<(uuid::Uuid, Vec<i64>)>> {
        let rows = sqlx::query!(
            r#"SELECT
                    i.id,
                    i.perceptual_hash,
                    i.perceptual_hash_center,
                    i.perceptual_hash_tl,
                    i.perceptual_hash_tr,
                    i.perceptual_hash_bl,
                    i.perceptual_hash_br
               FROM cluster_members cm
               JOIN images i ON cm.image_id = i.id
               JOIN media_images mi ON i.id = mi.image_id
               JOIN media_files mf ON mi.media_id = mf.id
               WHERE cm.cluster_id = ? AND (
                    i.perceptual_hash IS NOT NULL OR
                    i.perceptual_hash_center IS NOT NULL OR
                    i.perceptual_hash_tl IS NOT NULL OR
                    i.perceptual_hash_tr IS NOT NULL OR
                    i.perceptual_hash_bl IS NOT NULL OR
                    i.perceptual_hash_br IS NOT NULL
               )"#,
            cluster_id
        )
        .fetch_all(self.get_read_conn())
        .await?;

        Ok(rows
            .into_iter()
            .filter_map(|row| {
                let id = uuid::Uuid::from_slice(&row.id).ok()?;
                let mut hashes = Vec::with_capacity(6);
                if let Some(v) = row.perceptual_hash {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_center {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_tl {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_tr {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_bl {
                    hashes.push(v);
                }
                if let Some(v) = row.perceptual_hash_br {
                    hashes.push(v);
                }
                if hashes.is_empty() {
                    None
                } else {
                    Some((id, hashes))
                }
            })
            .collect())
    }

    pub async fn get_clusters_paginated(
        &self,
        page: u32,
        page_size: u32,
    ) -> Result<(Pagination, Vec<crate::server::ClusterDTO>)> {
        use crate::server::ClusterDTO;

        // Get total count — match the main query's JOIN so empty clusters don't cause drift
        let count_row = sqlx::query!(
            r#"SELECT COUNT(DISTINCT c.cluster_id) as count
               FROM image_clusters c
               JOIN cluster_members cm ON c.cluster_id = cm.cluster_id
               WHERE c.is_resolved = 0"#,
        )
        .fetch_one(self.get_read_conn())
        .await?;
        let total_count: i64 = count_row.count;
        let total_pages = (total_count as f64 / page_size as f64).ceil() as u32;
        let offset = (page - 1) * page_size;

        let pagination = Pagination {
            count: total_count as u32,
            current_page: page,
            total_pages,
            prev_page: if page > 1 { Some(page - 1) } else { None },
            next_page: if page < total_pages {
                Some(page + 1)
            } else {
                None
            },
        };

        // Fetch clusters with preview thumbnails (first 4 images)
        let rows = sqlx::query!(
            r#"SELECT
                c.cluster_id AS "cluster_id!",
                c.representative_image_id AS "representative_image_id!",
                c.created_at AS "created_at!",
                c.is_resolved AS "is_resolved!",
                COUNT(DISTINCT cm.image_id) as image_count
            FROM image_clusters c
            JOIN cluster_members cm ON c.cluster_id = cm.cluster_id
            WHERE c.is_resolved = 0
            GROUP BY c.cluster_id
            ORDER BY
                MAX(cm.hamming_distance) ASC,     -- 1. Tightest clusters first (graded by their worst match)
                COUNT(DISTINCT cm.image_id) DESC, -- 2. Then by largest space savings
                c.created_at DESC                 -- 3. Then newest
            LIMIT ? OFFSET ?"#,
            page_size,
            offset
        )
        .fetch_all(self.get_read_conn())
        .await?;
        let cluster_ids: Vec<i64> = rows.iter().map(|r| r.cluster_id).collect();
        let mut thumb_map: std::collections::HashMap<i64, Vec<String>> =
            std::collections::HashMap::new();

        if !cluster_ids.is_empty() {
            // Emit IN clause placeholders manually
            let placeholders: Vec<String> =
                std::iter::repeat_n("?".to_string(), cluster_ids.len()).collect();
            let in_clause = placeholders.join(",");
            let query_str = format!(
                r#"SELECT cluster_id, data FROM (
                       SELECT cm.cluster_id, t.data,
                           ROW_NUMBER() OVER (PARTITION BY cm.cluster_id ORDER BY cm.hamming_distance) as rn
                       FROM cluster_members cm
                       JOIN images i ON cm.image_id = i.id
                       JOIN thumbnails t ON i.thumbnail_id = t.id
                       WHERE cm.cluster_id IN ({})
                   ) WHERE rn <= 4"#,
                in_clause
            );

            let mut q = sqlx::query(&query_str);
            for id in &cluster_ids {
                q = q.bind(id);
            }
            let thumb_rows = q.fetch_all(self.get_read_conn()).await?;

            for trow in thumb_rows {
                let cid: i64 = trow.get("cluster_id");
                let data: Vec<u8> = trow.get("data");
                let entry = thumb_map.entry(cid).or_default();
                entry.push(format!(
                    "data:image/jpeg;base64,{}",
                    BASE64_STANDARD.encode(&data)
                ));
            }
        }

        let mut clusters = Vec::new();
        for row in rows {
            let preview_thumbnails = thumb_map.remove(&row.cluster_id).unwrap_or_default();

            if let Ok(rep_id) = uuid::Uuid::from_slice(&row.representative_image_id) {
                clusters.push(ClusterDTO {
                    cluster_id: row.cluster_id,
                    image_count: row.image_count as i32,
                    representative_image_id: rep_id.to_string(),
                    preview_thumbnails,
                    is_resolved: row.is_resolved != 0,
                    created_at: row
                        .created_at
                        .parse()
                        .unwrap_or_else(|_| chrono::Utc::now()),
                });
            }
        }

        Ok((pagination, clusters))
    }

    pub async fn get_cluster_images(
        &self,
        cluster_id: i64,
    ) -> Result<Vec<crate::server::ClusterImageDTO>> {
        use crate::server::ClusterImageDTO;

        let rows = sqlx::query!(
            r#"SELECT
                i.id,
                mf.filename,
                cm.hamming_distance,
                cm.is_best_shot,
                i.width,
                i.height,
                t.data as thumbnail_data
            FROM cluster_members cm
            JOIN images i ON cm.image_id = i.id
            JOIN media_images mi ON i.id = mi.image_id
            JOIN media_files mf ON mi.media_id = mf.id
            JOIN thumbnails t ON i.thumbnail_id = t.id
            WHERE cm.cluster_id = ?
            ORDER BY cm.is_best_shot DESC, cm.hamming_distance ASC"#,
            cluster_id
        )
        .fetch_all(self.get_read_conn())
        .await?;

        Ok(rows
            .into_iter()
            .filter_map(|row| {
                uuid::Uuid::from_slice(&row.id)
                    .ok()
                    .map(|id| ClusterImageDTO {
                        id: id.to_string(),
                        filename: row.filename,
                        hamming_distance: row.hamming_distance as i32,
                        is_best_shot: row.is_best_shot != 0,
                        thumbnail: format!(
                            "data:image/jpeg;base64,{}",
                            BASE64_STANDARD.encode(row.thumbnail_data)
                        ),
                        width: row.width as i32,
                        height: row.height as i32,
                    })
            })
            .collect())
    }

    pub async fn mark_best_shots(&self, cluster_id: i64, image_ids: &[uuid::Uuid]) -> Result<()> {
        let mut tx = self.get_write_conn().await?.begin().await?;

        // Reset all best_shot flags for this cluster
        sqlx::query!(
            "UPDATE cluster_members SET is_best_shot = 0 WHERE cluster_id = ?",
            cluster_id
        )
        .execute(&mut *tx)
        .await?;

        // Set the new best shots
        let mut updated = 0u64;
        for image_id in image_ids {
            let result = sqlx::query!(
                "UPDATE cluster_members SET is_best_shot = 1 WHERE cluster_id = ? AND image_id = ?",
                cluster_id,
                image_id
            )
            .execute(&mut *tx)
            .await?;
            updated += result.rows_affected();
        }

        if updated == 0 {
            tx.rollback().await?;
            return Err(anyhow::anyhow!(
                "No cluster members matched the provided best shot IDs (cluster {})",
                cluster_id
            ));
        }

        tx.commit().await?;

        Ok(())
    }

    pub async fn resolve_cluster(&self, cluster_id: i64) -> Result<Vec<uuid::Uuid>> {
        let write_conn = self.get_write_conn().await?;
        let mut tx = write_conn.begin().await?;

        // Get all media_file IDs for images in this cluster that are NOT the best shot
        let rows = sqlx::query!(
            r#"SELECT mf.id
               FROM cluster_members cm
               JOIN images i ON cm.image_id = i.id
               JOIN media_images mi ON i.id = mi.image_id
               JOIN media_files mf ON mi.media_id = mf.id
               WHERE cm.cluster_id = ? AND cm.is_best_shot = 0"#,
            cluster_id
        )
        .fetch_all(&mut *tx)
        .await?;

        let media_file_ids: Vec<uuid::Uuid> = rows
            .into_iter()
            .filter_map(|row| uuid::Uuid::from_slice(&row.id).ok())
            .collect();

        // Mark cluster as resolved
        sqlx::query!(
            "UPDATE image_clusters SET is_resolved = 1 WHERE cluster_id = ?",
            cluster_id
        )
        .execute(&mut *tx)
        .await?;

        tx.commit().await?;

        Ok(media_file_ids)
    }
}

pub async fn ensure_dir(db_path: &str) -> Result<()> {
    let path = Path::new(db_path)
        .parent()
        .ok_or(anyhow::anyhow!("Invalid path"))?;
    if !path.exists() {
        fs::create_dir_all(path).await?;
    }
    if !Path::new(db_path).exists() {
        fs::File::create(db_path).await?;
        // NOTE: Here we ensure that the DB is already initialized
        let conn = rusqlite::Connection::open_with_flags(
            db_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE
                | rusqlite::OpenFlags::SQLITE_OPEN_CREATE
                | rusqlite::OpenFlags::SQLITE_OPEN_URI,
        )?;
        conn.execute_batch(&format!(
            r#"
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = FULL;
                PRAGMA busy_timeout = 30000;
                PRAGMA cache_size = {};
                PRAGMA temp_store = MEMORY;
                PRAGMA page_size = {};
                PRAGMA secure_delete = OFF;
                PRAGMA wal_autocheckpoint = {};
                PRAGMA auto_vacuum = INCREMENTAL;
                "#,
            DEFAULT_CACHE_SIZE, DEFAULT_PAGE_SIZE, DEFAULT_WAL_CHECKPOINT
        ))?;
    }
    Ok(())
}
