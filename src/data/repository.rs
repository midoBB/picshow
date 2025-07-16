use anyhow::Result;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::Row;
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
            .pragma("cache_size", "-64000")
            .pragma("temp_store", "MEMORY")
            .pragma("page_size", "4096")
            .pragma("secure_delete", "OFF")
            .pragma("wal_autocheckpoint", "1000")
            .busy_timeout(Duration::from_secs(10));
        let write_options = SqliteConnectOptions::from_str(url_db_path)?
            .pragma("journal_mode", "WAL")
            .pragma("synchronous", "FULL")
            .pragma("foreign_keys", "ON")
            .pragma("cache_size", "-64000")
            .pragma("temp_store", "MEMORY")
            .pragma("page_size", "4096")
            .pragma("secure_delete", "OFF")
            .pragma("wal_autocheckpoint", "1000")
            .pragma("auto_vacuum", "INCREMENTAL")
            .busy_timeout(Duration::from_secs(10));
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

    async fn get_write_conn(&self) -> Arc<sqlx::SqlitePool> {
        let _ = self.write_semaphore.read().await.acquire().await.unwrap();
        Arc::clone(&self.write_pool)
    }

    async fn init_schema(&self) -> Result<()> {
        sqlx::migrate!("./migrations")
            .run(self.get_write_conn().await.borrow())
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
            .execute(self.get_write_conn().await.borrow())
            .await
        {
            error!("Failed to checkpoint WAL during repair: {}", e);
        }

        if let Err(e) = sqlx::query("PRAGMA incremental_vacuum")
            .execute(self.get_write_conn().await.borrow())
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
            .execute(self.get_write_conn().await.borrow())
            .await?;

        debug!("Performing incremental vacuum...");
        sqlx::query("PRAGMA incremental_vacuum")
            .execute(self.get_write_conn().await.borrow())
            .await?;

        debug!("Analyzing database statistics...");
        sqlx::query("PRAGMA analyze")
            .execute(self.get_write_conn().await.borrow())
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
    pub async fn lock_writes(&self) -> Result<()> {
        trace!("Locking writes");
        // Force acquire the lock semaphore first
        let _lock = self.lock_semaphore.acquire().await.unwrap();

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
        info!("Unlocking writes");
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
        let media_type = media_file.media_type.clone();
        
        // Single optimized query with JOIN to get both media and thumbnail data
        let query_str = match media_type {
            MediaType::Image => {
                "SELECT i.id, i.width, i.height, 0 as duration_ms, t.id as thumb_id, t.width as thumb_width, t.height as thumb_height, t.data as thumb_data 
                 FROM images i JOIN thumbnails t ON i.thumbnail_id = t.id 
                 WHERE i.id = ?"
            }
            MediaType::Video => {
                "SELECT v.id, v.width, v.height, v.duration_ms, t.id as thumb_id, t.width as thumb_width, t.height as thumb_height, t.data as thumb_data 
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
        
        match media_type {
            MediaType::Image => {
                let image = Image {
                    id: row.get("id"),
                    width: row.get("width"),
                    height: row.get("height"),
                    thumbnail,
                };
                Ok(media_file.clone().with_image(
                    image,
                    media_file.mime_type.unwrap(),
                ))
            }
            MediaType::Video => {
                let video = Video {
                    id: row.get("id"),
                    width: row.get("width"),
                    height: row.get("height"),
                    duration_ms: row.get::<i64, _>("duration_ms") as u64,
                    thumbnail,
                };
                Ok(media_file.clone().with_video(
                    video,
                    media_file.mime_type.unwrap(),
                ))
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
        .await? > 0)
    }

    pub async fn exists_by_hash(&self, hash: String) -> Result<bool> {
        // Optimized EXISTS query using COUNT with LIMIT for early termination
        Ok(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM media_files WHERE hash = ? LIMIT 1",
            )
            .bind(hash)
            .fetch_one(self.get_read_conn())
            .await? > 0,
        )
    }

    pub async fn get_favorite_status(&self, file_id: Uuid) -> Result<bool> {
        let cache_key = cache::get_favorite_status_cache_key(&file_id);

        if let Some(status) = self.cache.get::<bool>(cache_key.clone()).await {
            info!(
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
        
        let mut tx = self.get_write_conn().await.begin().await?;
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
        sqlx::query(
            "UPDATE stats SET count = count - ?, images = images - ?, videos = videos - ?, favorites = favorites - ? WHERE id = 1"
        )
        .bind(count)
        .bind(img_count)
        .bind(vid_count)
        .bind(fav_count)
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
    async fn insert_image(&self, media_file: FilledMediaFile) -> Result<()> {
        debug!("Saving image to database {}", media_file.filename);
        let image = media_file.media.as_image().expect("Should be an image");
        let thumbnail = image.thumbnail.clone();

        let mut tx = self.get_write_conn().await.begin().await?;

        sqlx::query(r#"INSERT INTO thumbnails (id, width, height, data) VALUES (?, ?, ?, ?)"#)
            .bind(thumbnail.id)
            .bind(thumbnail.width)
            .bind(thumbnail.height)
            .bind(thumbnail.data)
            .execute(&mut *tx)
            .await?;

        sqlx::query(r#"INSERT INTO images (id, width, height, thumbnail_id) VALUES (?, ?, ?, ?)"#)
            .bind(image.id)
            .bind(image.width)
            .bind(image.height)
            .bind(thumbnail.id)
            .execute(&mut *tx)
            .await?;

        sqlx::query(r#"INSERT INTO media_files (id, hash, created_at, filename, media_type, last_modified, size, mime_type)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)"#)
        .bind(media_file.id)
        .bind(&media_file.hash)
        .bind(media_file.created_at)
        .bind(&media_file.filename)
        .bind(&media_file.media_type)
        .bind(media_file.last_modified)
        .bind(media_file.size)
        .bind(&media_file.mime_type)
        .execute(&mut *tx)
        .await?;

        sqlx::query("INSERT INTO media_images (media_id, image_id) VALUES (?, ?)")
            .bind(media_file.id)
            .bind(image.id)
            .execute(&mut *tx)
            .await?;

        sqlx::query("UPDATE stats SET count = count + 1, images = images + 1 WHERE id = 1")
            .execute(&mut *tx)
            .await?;

        tx.commit().await?;
        Ok(())
    }

    async fn insert_video(&self, media_file: FilledMediaFile) -> Result<()> {
        debug!("Saving video to database {}", media_file.filename);
        let video = media_file.media.as_video().expect("Should be a video");
        let thumbnail = video.thumbnail.clone();

        let mut tx = self.get_write_conn().await.begin().await?;

        sqlx::query(r#"INSERT INTO thumbnails (id, width, height, data) VALUES (?, ?, ?, ?)"#)
            .bind(thumbnail.id)
            .bind(thumbnail.width)
            .bind(thumbnail.height)
            .bind(thumbnail.data)
            .execute(&mut *tx)
            .await?;

        sqlx::query(
            r#"INSERT INTO videos (id, width, height, duration_ms, thumbnail_id)
                   VALUES (?, ?, ?, ?, ?)"#,
        )
        .bind(video.id)
        .bind(video.width)
        .bind(video.height)
        .bind(video.duration_ms as i64)
        .bind(thumbnail.id)
        .execute(&mut *tx)
        .await?;

        sqlx::query(r#"INSERT INTO media_files (id, hash, created_at, filename, media_type, last_modified, size, mime_type)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)"#)
        .bind(media_file.id)
        .bind(&media_file.hash)
        .bind(media_file.created_at)
        .bind(&media_file.filename)
        .bind(&media_file.media_type)
        .bind(media_file.last_modified)
        .bind(media_file.size)
        .bind(&media_file.mime_type)
        .execute(&mut *tx)
        .await?;

        sqlx::query("INSERT INTO media_videos (media_id, video_id) VALUES (?, ?)")
            .bind(media_file.id)
            .bind(video.id)
            .execute(&mut *tx)
            .await?;

        sqlx::query("UPDATE stats SET count = count + 1, videos = videos + 1 WHERE id = 1")
            .execute(&mut *tx)
            .await?;

        tx.commit().await?;
        Ok(())
    }
    pub async fn update_file_name_and_modified_date(
        &self,
        file_id: Uuid,
        new_file_name: &str,
        last_modified: DateTime<Utc>,
    ) -> Result<()> {
        let mut tx = self.get_write_conn().await.begin().await?;
        sqlx::query("UPDATE media_files SET filename = ?, last_modified = ? WHERE id = ?")
            .bind(new_file_name)
            .bind(last_modified)
            .bind(file_id)
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

        let count = data.len();
        let img_count = data.iter().filter(|(t, _)| *t == MediaType::Image).count();
        let vid_count = data.iter().filter(|(t, _)| *t == MediaType::Video).count();
        let fav_count = data.iter().filter(|(_, f)| *f).count();

        let mut tx = self.get_write_conn().await.begin().await?;
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
        sqlx::query(
            "UPDATE stats SET count = count - ?, images = images - ?, videos = videos - ?, favorites = favorites - ? WHERE id = 1"
        )
        .bind(count as i64)
        .bind(img_count as i64)
        .bind(vid_count as i64)
        .bind(fav_count as i64)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        self.cache.invalidate_stats_cache();
        self.cache.invalidate_files_cache();
        Ok(())
    }

    pub async fn toggle_favorite_status(&self, file_id: Uuid) -> Result<()> {
        let mut tx = self.get_write_conn().await.begin().await?;
        let is_favorite: bool =
            sqlx::query_scalar("SELECT is_favorite FROM media_files WHERE id = ?")
                .bind(file_id)
                .fetch_one(&mut *tx)
                .await?;
        sqlx::query("UPDATE media_files SET is_favorite = ? WHERE id = ?")
            .bind(!is_favorite)
            .bind(file_id)
            .execute(&mut *tx)
            .await?;
        // Optimized stats update - note: count stays the same, only favorites change
        let fav_change = if !is_favorite { 1 } else { -1 };
        sqlx::query("UPDATE stats SET favorites = favorites + ? WHERE id = 1")
            .bind(fav_change)
            .execute(&mut *tx)
            .await?;
        self.cache.invalidate_stats_cache();
        self.cache.invalidate_file_cache(&file_id);
        info!(
            "Toggling favorite status for file {} with status {}",
            file_id, !is_favorite
        );
        self.cache.invalidate_favorite_status_cache(&file_id);
        self.cache.invalidate_files_cache();
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
                    format!("(((mf.rowid + {}) * 1103515245 + 12345) % 2147483647)", seed)
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
            
        let filled_files: Vec<FilledMediaFile> = rows.into_iter().map(|row| {
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
            
            let mime_type = media_file.mime_type.clone().unwrap();
            match media_file.media_type {
                MediaType::Image => {
                    let image = Image {
                        id: row.get("media_id"),
                        width: row.get("width"),
                        height: row.get("height"),
                        thumbnail,
                    };
                    media_file.with_image(image, mime_type)
                }
                MediaType::Video => {
                    let video = Video {
                        id: row.get("media_id"),
                        width: row.get("width"),
                        height: row.get("height"),
                        duration_ms: row.get::<i64, _>("duration_ms") as u64,
                        thumbnail,
                    };
                    media_file.with_video(video, mime_type)
                }
            }
        }).collect();
        
        let result = (pagination, filled_files);
        self.cache.set(cache_key, &result).await;
        Ok(result)
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
        conn.execute_batch(
            r#"
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = FULL;
                PRAGMA busy_timeout = 30000;
                PRAGMA cache_size = -64000;
                PRAGMA temp_store = MEMORY;
                PRAGMA page_size = 4096;
                PRAGMA secure_delete = OFF;
                PRAGMA wal_autocheckpoint = 1000;
                PRAGMA auto_vacuum = INCREMENTAL;
            "#,
        )?;
    }
    Ok(())
}
