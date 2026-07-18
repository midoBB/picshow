pub mod backup_manager;
pub mod repository;

use std::{
    fmt::Display,
    fs::OpenOptions,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use sqlx::{
    prelude::{FromRow, Type},
    sqlite::SqliteConnectOptions,
    Database, Sqlite, SqlitePool,
};
use uuid::Uuid;

const CACHE_SIZE: &str = "-64000";
const PAGE_SIZE: &str = "4096";
const BUSY_TIMEOUT_MS: &str = "30000";

// Rollback-journal mode (journal_mode=DELETE) rather than WAL: this workload is
// read-mostly with very low write volume, so we favor SQLite's oldest and most
// battle-tested single-file crash-recovery path over WAL's throughput benefits.
// A writer only needs the exclusive lock briefly at commit; busy_timeout absorbs
// the resulting contention on the read pool.
fn apply_sqlx_pragmas(mut options: SqliteConnectOptions, writable: bool) -> SqliteConnectOptions {
    options = options
        .pragma("journal_mode", "DELETE")
        .pragma("synchronous", "FULL")
        .pragma("foreign_keys", "ON")
        .pragma("busy_timeout", BUSY_TIMEOUT_MS)
        .pragma("cache_size", CACHE_SIZE)
        .pragma("temp_store", "MEMORY")
        .pragma("page_size", PAGE_SIZE)
        .pragma("secure_delete", "OFF")
        .pragma("cell_size_check", "ON")
        .pragma("mmap_size", "0");

    if writable {
        options = options.pragma("auto_vacuum", "INCREMENTAL");
    }

    options
}

fn apply_rusqlite_pragmas(conn: &rusqlite::Connection, writable: bool) -> Result<()> {
    let auto_vacuum = if writable {
        "PRAGMA auto_vacuum = INCREMENTAL;"
    } else {
        ""
    };
    conn.execute_batch(&format!(
        r#"
            PRAGMA journal_mode = DELETE;
            PRAGMA synchronous = FULL;
            PRAGMA foreign_keys = ON;
            PRAGMA busy_timeout = {BUSY_TIMEOUT_MS};
            PRAGMA cache_size = {CACHE_SIZE};
            PRAGMA temp_store = MEMORY;
            PRAGMA page_size = {PAGE_SIZE};
            PRAGMA secure_delete = OFF;
            PRAGMA cell_size_check = ON;
            PRAGMA mmap_size = 0;
            {auto_vacuum}
        "#
    ))?;
    verify_rusqlite_journal_mode(conn)?;
    Ok(())
}

async fn verify_sqlx_journal_mode(pool: &SqlitePool) -> Result<()> {
    let journal_mode: String = sqlx::query_scalar("PRAGMA journal_mode")
        .fetch_one(pool)
        .await
        .context("failed to read SQLite journal_mode")?;
    if !journal_mode.eq_ignore_ascii_case("delete") {
        anyhow::bail!("SQLite journal_mode is {}, expected DELETE", journal_mode);
    }
    Ok(())
}

fn verify_rusqlite_journal_mode(conn: &rusqlite::Connection) -> Result<()> {
    let journal_mode: String = conn.query_row("PRAGMA journal_mode", [], |row| row.get(0))?;
    if !journal_mode.eq_ignore_ascii_case("delete") {
        anyhow::bail!("SQLite journal_mode is {}, expected DELETE", journal_mode);
    }
    Ok(())
}

async fn check_sqlx_integrity(pool: &SqlitePool) -> Result<()> {
    let quick_check = sqlx::query_scalar::<_, String>("PRAGMA quick_check")
        .fetch_one(pool)
        .await
        .context("failed to run SQLite quick_check")?;

    if quick_check == "ok" {
        check_sqlx_foreign_keys(pool).await?;
        return Ok(());
    }

    let integrity_check = sqlx::query_scalar::<_, String>("PRAGMA integrity_check")
        .fetch_one(pool)
        .await
        .context("failed to run SQLite integrity_check")?;

    if integrity_check != "ok" {
        anyhow::bail!(
            "SQLite integrity check failed: quick_check={}, integrity_check={}",
            quick_check,
            integrity_check
        );
    }

    check_sqlx_foreign_keys(pool).await
}

fn check_rusqlite_integrity(conn: &rusqlite::Connection) -> Result<()> {
    let quick_check: String = conn.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
    if quick_check != "ok" {
        let integrity_check: String =
            conn.query_row("PRAGMA integrity_check", [], |row| row.get(0))?;
        if integrity_check != "ok" {
            anyhow::bail!(
                "SQLite integrity check failed: quick_check={}, integrity_check={}",
                quick_check,
                integrity_check
            );
        }
    }

    let has_fk_errors: Option<i64> = conn
        .prepare("SELECT 1 FROM pragma_foreign_key_check LIMIT 1")?
        .query_row([], |row| row.get(0))
        .optional()?;
    if has_fk_errors.is_some() {
        anyhow::bail!("SQLite foreign_key_check failed");
    }

    Ok(())
}

async fn check_sqlx_foreign_keys(pool: &SqlitePool) -> Result<()> {
    let has_fk_errors: Option<i64> =
        sqlx::query_scalar("SELECT 1 FROM pragma_foreign_key_check LIMIT 1")
            .fetch_optional(pool)
            .await
            .context("failed to run SQLite foreign_key_check")?;
    if has_fk_errors.is_some() {
        anyhow::bail!("SQLite foreign_key_check failed");
    }
    Ok(())
}

fn make_standalone_database_file(path: &Path) -> Result<()> {
    let conn = rusqlite::Connection::open(path)?;
    conn.execute_batch("PRAGMA journal_mode = DELETE;")?;
    check_rusqlite_integrity(&conn)?;
    Ok(())
}

fn sync_file_and_parent(path: &Path) -> Result<()> {
    OpenOptions::new()
        .read(true)
        .open(path)
        .with_context(|| format!("failed to open {} for sync", path.display()))?
        .sync_all()
        .with_context(|| format!("failed to sync {}", path.display()))?;

    if let Some(parent) = path.parent() {
        sync_directory(parent)?;
    }

    Ok(())
}

fn sync_directory(path: &Path) -> Result<()> {
    OpenOptions::new()
        .read(true)
        .open(path)
        .with_context(|| format!("failed to open directory {} for sync", path.display()))?
        .sync_all()
        .with_context(|| format!("failed to sync directory {}", path.display()))?;
    Ok(())
}

fn temp_backup_path(destination: &Path) -> PathBuf {
    let parent = destination.parent().unwrap_or_else(|| Path::new("."));
    let name = destination
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("picshow.bak");
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    parent.join(format!(".{}.tmp-{}-{}", name, std::process::id(), nanos))
}

fn remove_sqlite_sidecars(path: &Path) -> Result<()> {
    // Under journal_mode=DELETE the only transient sidecar is `-journal`, and it's
    // removed automatically at the end of any successfully committed transaction.
    // This just cleans up after an interrupted backup step, defensively.
    let sidecar = PathBuf::from(format!("{}-journal", path.display()));
    match std::fs::remove_file(&sidecar) {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rusqlite_pragmas_enable_rollback_journal_and_integrity_checks_pass() -> Result<()> {
        let tempdir = tempfile::tempdir()?;
        let db_path = tempdir.path().join("picshow.db");
        let conn = rusqlite::Connection::open(&db_path)?;

        apply_rusqlite_pragmas(&conn, true)?;
        conn.execute_batch(
            r#"
                CREATE TABLE media_files (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
                INSERT INTO media_files (name) VALUES ('image.jpg');
            "#,
        )?;
        drop(conn);

        let conn = rusqlite::Connection::open(&db_path)?;
        let journal_mode: String = conn.query_row("PRAGMA journal_mode", [], |row| row.get(0))?;
        assert_eq!(journal_mode.to_ascii_lowercase(), "delete");
        check_rusqlite_integrity(&conn)?;

        let count: i64 =
            conn.query_row("SELECT COUNT(*) FROM media_files", [], |row| row.get(0))?;
        assert_eq!(count, 1);

        Ok(())
    }

    #[test]
    fn verify_rusqlite_journal_mode_rejects_wal() -> Result<()> {
        let tempdir = tempfile::tempdir()?;
        let db_path = tempdir.path().join("picshow.db");
        let conn = rusqlite::Connection::open(&db_path)?;
        conn.execute_batch("PRAGMA journal_mode = WAL;")?;

        let err = verify_rusqlite_journal_mode(&conn).expect_err("WAL mode should be rejected");
        assert!(err.to_string().contains("expected DELETE"));

        Ok(())
    }

    #[test]
    fn foreign_key_check_failure_is_reported() -> Result<()> {
        let conn = rusqlite::Connection::open_in_memory()?;
        conn.execute_batch(
            r#"
                PRAGMA foreign_keys = OFF;
                CREATE TABLE parent (id INTEGER PRIMARY KEY);
                CREATE TABLE child (
                    id INTEGER PRIMARY KEY,
                    parent_id INTEGER NOT NULL REFERENCES parent(id)
                );
                INSERT INTO child (id, parent_id) VALUES (1, 99);
            "#,
        )?;

        let err = check_rusqlite_integrity(&conn).expect_err("foreign key check should fail");
        assert!(err.to_string().contains("foreign_key_check"));

        Ok(())
    }

    #[test]
    fn temp_backup_path_uses_destination_directory() -> Result<()> {
        let destination = Path::new("/tmp/picshow-test.bak");
        let temp = temp_backup_path(destination);

        assert_eq!(temp.parent(), destination.parent());
        assert!(temp
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with(".picshow-test.bak.tmp-")));

        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct ExistingCluster {
    pub cluster_id: i64,
    pub representative_id: Uuid,
    pub members: Vec<(Uuid, u32)>,
}

#[derive(Clone, Serialize, Deserialize, FromRow)]
pub struct UnfilledMediaFile {
    pub id: uuid::Uuid,
    pub hash: String,
    pub created_at: DateTime<Utc>,
    pub filename: String,
    pub size: i64,
    pub media_type: MediaType,
    pub last_modified: DateTime<Utc>,
    #[sqlx(skip)]
    pub media: Option<Media>,
    pub mime_type: Option<String>,
    pub is_favorite: bool,
}
impl From<FilledMediaFile> for UnfilledMediaFile {
    fn from(filled: FilledMediaFile) -> Self {
        Self {
            id: filled.id,
            hash: filled.hash,
            created_at: filled.created_at,
            filename: filled.filename,
            size: filled.size,
            media_type: filled.media_type,
            last_modified: filled.last_modified,
            media: Some(filled.media),
            mime_type: Some(filled.mime_type),
            is_favorite: filled.is_favorite,
        }
    }
}
impl From<MediaFile> for UnfilledMediaFile {
    fn from(media_file: MediaFile) -> Self {
        match media_file {
            MediaFile::Unfilled(unfilled) => unfilled,
            MediaFile::Filled(filled) => Self {
                id: filled.id,
                hash: filled.hash,
                created_at: filled.created_at,
                filename: filled.filename,
                size: filled.size,
                media_type: filled.media_type,
                last_modified: filled.last_modified,
                media: Some(filled.media),
                mime_type: Some(filled.mime_type),
                is_favorite: filled.is_favorite,
            },
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct FilledMediaFile {
    pub id: uuid::Uuid,
    pub hash: String,
    pub created_at: DateTime<Utc>,
    pub filename: String,
    pub size: i64,
    pub media_type: MediaType,
    pub last_modified: DateTime<Utc>,
    pub media: Media,
    pub mime_type: String,
    pub is_favorite: bool,
}

#[derive(Serialize, Deserialize)]
pub enum MediaFile {
    Unfilled(UnfilledMediaFile),
    Filled(FilledMediaFile),
}

impl MediaFile {
    pub fn get_id(&self) -> uuid::Uuid {
        match self {
            MediaFile::Unfilled(unfilled) => unfilled.id,
            MediaFile::Filled(filled) => filled.id,
        }
    }
}

impl TryFrom<UnfilledMediaFile> for FilledMediaFile {
    type Error = anyhow::Error;
    fn try_from(value: UnfilledMediaFile) -> Result<Self> {
        match (value.media, value.mime_type) {
            (Some(media), Some(mime_type)) => Ok(Self {
                id: value.id,
                hash: value.hash,
                created_at: value.created_at,
                filename: value.filename,
                size: value.size,
                media_type: value.media_type,
                last_modified: value.last_modified,
                media,
                mime_type,
                is_favorite: value.is_favorite,
            }),
            _ => Err(anyhow::anyhow!("Media is not filled")),
        }
    }
}

impl TryFrom<Result<UnfilledMediaFile, anyhow::Error>> for FilledMediaFile {
    type Error = anyhow::Error;
    fn try_from(value: Result<UnfilledMediaFile, anyhow::Error>) -> Result<Self> {
        match value {
            Ok(media_file) => Self::try_from(media_file),
            Err(e) => Err(e),
        }
    }
}

impl TryFrom<MediaFile> for FilledMediaFile {
    type Error = anyhow::Error;
    fn try_from(value: MediaFile) -> Result<Self> {
        match value {
            MediaFile::Filled(filled) => Ok(filled),
            _ => Err(anyhow::anyhow!("Media is not filled")),
        }
    }
}

impl UnfilledMediaFile {
    pub fn with_image(mut self, image: Image, mime_type: String) -> FilledMediaFile {
        self.media = Some(Media::Image(image));
        self.mime_type = Some(mime_type);
        self.try_into().unwrap()
    }

    pub fn with_video(mut self, video: Video, mime_type: String) -> FilledMediaFile {
        self.media = Some(Media::Video(video));
        self.mime_type = Some(mime_type);
        self.try_into().unwrap()
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub enum MediaType {
    Image,
    Video,
}
impl Type<Sqlite> for MediaType {
    fn type_info() -> <Sqlite as Database>::TypeInfo {
        <String as Type<Sqlite>>::type_info()
    }
}

impl<'r> sqlx::Decode<'r, Sqlite> for MediaType {
    fn decode(value: sqlx::sqlite::SqliteValueRef<'r>) -> Result<Self, sqlx::error::BoxDynError> {
        let value = <String as sqlx::Decode<Sqlite>>::decode(value)?;
        MediaType::try_from(value).map_err(Into::into)
    }
}

impl sqlx::Encode<'_, Sqlite> for MediaType {
    fn encode_by_ref(
        &self,
        args: &mut Vec<sqlx::sqlite::SqliteArgumentValue<'_>>,
    ) -> std::result::Result<
        sqlx::encode::IsNull,
        std::boxed::Box<dyn std::error::Error + std::marker::Send + std::marker::Sync + 'static>,
    > {
        args.push(sqlx::sqlite::SqliteArgumentValue::Text(
            self.to_string().into(),
        ));
        Ok(sqlx::encode::IsNull::No)
    }
}

impl std::fmt::Display for MediaType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MediaType::Image => write!(f, "Image"),
            MediaType::Video => write!(f, "Video"),
        }
    }
}

impl TryFrom<String> for MediaType {
    type Error = anyhow::Error;
    fn try_from(value: String) -> Result<Self> {
        match value.as_str() {
            "Image" | "image" => Ok(MediaType::Image),
            "Video" | "video" => Ok(MediaType::Video),
            _ => Err(anyhow::anyhow!("Invalid media type")),
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
pub enum Media {
    Image(Image),
    Video(Video),
}

impl Media {
    pub fn as_image(&self) -> Option<Image> {
        match self {
            Media::Image(image) => Some(image.clone()),
            _ => None,
        }
    }
    pub fn as_video(&self) -> Option<Video> {
        match self {
            Media::Video(video) => Some(video.clone()),
            _ => None,
        }
    }
}

#[derive(Clone, Serialize, Deserialize, FromRow, Default)]
pub struct Image {
    pub id: uuid::Uuid,
    pub width: u32,
    pub height: u32,
    /// Perceptual hashes used for similarity clustering.
    ///
    /// `perceptual_hash` is the legacy/full hash; the *_* variants are crop hashes.
    pub perceptual_hash: Option<i64>,
    pub perceptual_hash_center: Option<i64>,
    pub perceptual_hash_tl: Option<i64>,
    pub perceptual_hash_tr: Option<i64>,
    pub perceptual_hash_bl: Option<i64>,
    pub perceptual_hash_br: Option<i64>,
    #[sqlx(skip)]
    pub thumbnail: Thumbnail,
}

impl Image {
    pub fn new(
        id: uuid::Uuid,
        width: u32,
        height: u32,
        perceptual_hash: Option<i64>,
        perceptual_hash_center: Option<i64>,
        perceptual_hash_tl: Option<i64>,
        perceptual_hash_tr: Option<i64>,
        perceptual_hash_bl: Option<i64>,
        perceptual_hash_br: Option<i64>,
        thumbnail: Thumbnail,
    ) -> Self {
        Self {
            id,
            width,
            height,
            perceptual_hash,
            perceptual_hash_center,
            perceptual_hash_tl,
            perceptual_hash_tr,
            perceptual_hash_bl,
            perceptual_hash_br,
            thumbnail,
        }
    }

    pub fn perceptual_hashes(&self) -> [Option<i64>; 6] {
        [
            self.perceptual_hash,
            self.perceptual_hash_center,
            self.perceptual_hash_tl,
            self.perceptual_hash_tr,
            self.perceptual_hash_bl,
            self.perceptual_hash_br,
        ]
    }
}

#[derive(Clone, Serialize, Deserialize, FromRow, Default)]
pub struct Video {
    pub id: uuid::Uuid,
    pub width: u32,
    pub height: u32,
    pub duration_ms: u64,
    #[sqlx(skip)]
    pub thumbnail: Thumbnail,
}

#[derive(Clone, Serialize, Deserialize, FromRow, Default)]
pub struct Thumbnail {
    pub id: uuid::Uuid,
    pub width: u32,
    pub height: u32,
    pub data: Vec<u8>,
}

impl Thumbnail {
    pub fn new(id: uuid::Uuid, width: u32, height: u32, data: Vec<u8>) -> Self {
        Self {
            id,
            width,
            height,
            data,
        }
    }
}

impl Video {
    pub fn new(
        id: uuid::Uuid,
        width: u32,
        height: u32,
        duration_ms: u64,
        thumbnail: Thumbnail,
    ) -> Self {
        Self {
            id,
            width,
            height,
            duration_ms,
            thumbnail,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, FromRow)]
pub struct Stats {
    pub count: u32,
    pub images: u32,
    pub videos: u32,
    pub favorites: u32,
}

#[derive(Serialize, Deserialize)]
pub struct Pagination {
    pub count: u32,
    pub current_page: u32,
    pub total_pages: u32,
    pub prev_page: Option<u32>,
    pub next_page: Option<u32>,
}

#[derive(Clone)]
pub enum FindBy {
    Id(uuid::Uuid),
    Hash(String),
    Filename(String),
}

impl Display for FindBy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FindBy::Id(id) => write!(f, "id:{}", id),
            FindBy::Hash(hash) => write!(f, "hash:{}", hash),
            FindBy::Filename(filename) => write!(f, "filename:{}", filename),
        }
    }
}
