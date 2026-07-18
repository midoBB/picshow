use anyhow::Result;
use rusqlite::{config::DbConfig, Connection, OpenFlags};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::UNIX_EPOCH,
};
use tokio::sync::Mutex;

use tracing::{info, warn};

pub struct BackupManager {
    write_connection: Arc<Mutex<Connection>>,
}

impl BackupManager {
    pub async fn new(db_path: String) -> Result<Self> {
        super::repository::ensure_dir(&db_path).await?;
        let db_path = format!("file:{}", db_path);

        let write_connection = Connection::open_with_flags(
            db_path.as_str(),
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_URI,
        )?;
        write_connection.set_db_config(DbConfig::SQLITE_DBCONFIG_ENABLE_TRIGGER, true)?;
        write_connection.set_db_config(DbConfig::SQLITE_DBCONFIG_ENABLE_FKEY, true)?;
        super::apply_rusqlite_pragmas(&write_connection, true)?;
        let backup_manager = Self {
            write_connection: Arc::new(Mutex::new(write_connection)),
        };

        // Check database integrity before using it for backup operations
        backup_manager.check_integrity().await?;

        Ok(backup_manager)
    }

    /// Check database integrity for backup operations
    async fn check_integrity(&self) -> Result<()> {
        info!("Checking database integrity for backup operations...");
        let conn = self.write_connection.lock().await;
        super::check_rusqlite_integrity(&conn)?;
        info!("Database integrity check passed for backup operations");
        Ok(())
    }

    pub async fn backup(&self, destination: String) -> Result<()> {
        let destination = PathBuf::from(destination);
        let temp_destination = super::temp_backup_path(&destination);
        let conn = self.write_connection.lock().await;
        super::check_rusqlite_integrity(&conn)?;
        let progress_fn = |p: rusqlite::backup::Progress| {
            let completed_pages = p.pagecount - p.remaining;
            let percentage = if p.pagecount > 0 {
                (completed_pages as f64 / p.pagecount as f64) * 100.0
            } else {
                0.0
            };
            info!("Backup progress: {:.2}%", percentage);
        };

        let backup_result = conn.backup(
            rusqlite::DatabaseName::Main,
            &temp_destination,
            Some(progress_fn),
        );
        if let Err(e) = backup_result {
            let _ = fs::remove_file(&temp_destination);
            let _ = super::remove_sqlite_sidecars(&temp_destination);
            return Err(e.into());
        }

        super::make_standalone_database_file(&temp_destination)?;
        super::remove_sqlite_sidecars(&temp_destination)?;
        verify_database_file(&temp_destination)?;
        super::sync_file_and_parent(&temp_destination)?;
        fs::rename(&temp_destination, &destination)?;
        super::remove_sqlite_sidecars(&destination)?;
        super::sync_file_and_parent(&destination)?;
        Ok(())
    }

    pub async fn restore(&self, source: PathBuf) -> Result<()> {
        verify_database_file(&source)?;
        let mut conn = self.write_connection.lock().await;
        let progress_fn = |p: rusqlite::backup::Progress| {
            let completed_pages = p.pagecount - p.remaining;
            let percentage = if p.pagecount > 0 {
                (completed_pages as f64 / p.pagecount as f64) * 100.0
            } else {
                0.0
            };
            info!("Restore progress: {:.2}%", percentage);
        };
        conn.restore(rusqlite::DatabaseName::Main, &source, Some(progress_fn))?;
        super::apply_rusqlite_pragmas(&conn, true)?;
        super::check_rusqlite_integrity(&conn)?;
        Ok(())
    }

    /// Perform database maintenance operations optimized for SD cards
    pub async fn perform_maintenance(&self) -> Result<()> {
        use tracing::{debug, info};

        info!("Starting database maintenance in backup manager...");

        let conn = self.write_connection.lock().await;

        // Incremental vacuum to reclaim space gradually
        debug!("Performing incremental vacuum...");
        conn.pragma_update(None, "incremental_vacuum", "")?;

        // Analyze tables for query optimization
        debug!("Analyzing database statistics...");
        conn.execute("PRAGMA analyze", [])?;

        info!("Database maintenance completed in backup manager");
        Ok(())
    }
}

pub(crate) fn verify_database_file(path: &Path) -> Result<()> {
    let uri = format!("file:{}?mode=ro", path.display());
    let conn = Connection::open_with_flags(
        uri.as_str(),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )?;
    super::apply_rusqlite_pragmas(&conn, false)?;
    super::check_rusqlite_integrity(&conn)
}

/// Build a dated backup destination path in `folder`, matching the naming
/// convention (`picshow.<timestamp>.bak`) that `list_backups` parses back out.
pub(crate) fn backup_filename(folder: &str) -> String {
    let datetime = chrono::Local::now().format("%Y-%m-%d_%H-%M-%S").to_string();
    format!("{}picshow.{}.bak", folder, datetime)
}

fn backup_timestamp(filename: &str) -> Option<chrono::NaiveDateTime> {
    let stem = filename.strip_prefix("picshow.")?.strip_suffix(".bak")?;
    chrono::NaiveDateTime::parse_from_str(stem, "%Y-%m-%d_%H-%M-%S").ok()
}

/// List `picshow.*.bak` files in `folder`, newest first. Falls back to file
/// mtime for names that don't parse as our timestamp convention.
pub(crate) fn list_backups(folder: &str) -> Result<Vec<PathBuf>> {
    let dir = Path::new(folder);
    if !dir.exists() {
        return Ok(Vec::new());
    }

    let mut entries: Vec<(PathBuf, i64)> = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let name = match path.file_name().and_then(|n| n.to_str()) {
            Some(n) => n,
            None => continue,
        };
        if !name.starts_with("picshow.") || !name.ends_with(".bak") {
            continue;
        }

        let sort_key = backup_timestamp(name)
            .map(|dt| dt.and_utc().timestamp())
            .or_else(|| {
                entry
                    .metadata()
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                    .map(|d| d.as_secs() as i64)
            })
            .unwrap_or(0);
        entries.push((path, sort_key));
    }

    entries.sort_by_key(|(_, ts)| std::cmp::Reverse(*ts));
    Ok(entries.into_iter().map(|(path, _)| path).collect())
}

/// Delete every backup beyond the newest `keep` in `folder`.
pub(crate) async fn rotate_backups(folder: &str, keep: usize) -> Result<()> {
    let backups = list_backups(folder)?;
    for path in backups.into_iter().skip(keep) {
        if let Err(e) = tokio::fs::remove_file(&path).await {
            warn!("Failed to remove old backup {}: {}", path.display(), e);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn backup_writes_verified_destination_without_leaving_temp_file() -> Result<()> {
        let tempdir = tempfile::tempdir()?;
        let db_path = tempdir.path().join("picshow.db");
        let backup_path = tempdir.path().join("picshow.bak");

        {
            let conn = Connection::open(&db_path)?;
            crate::data::apply_rusqlite_pragmas(&conn, true)?;
            conn.execute_batch(
                r#"
                    CREATE TABLE media_files (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
                    INSERT INTO media_files (name) VALUES ('image.jpg');
                "#,
            )?;
        }

        let manager = BackupManager::new(db_path.to_string_lossy().to_string()).await?;
        manager
            .backup(backup_path.to_string_lossy().to_string())
            .await?;

        verify_database_file(&backup_path)?;
        let backup = Connection::open(&backup_path)?;
        let count: i64 =
            backup.query_row("SELECT COUNT(*) FROM media_files", [], |row| row.get(0))?;
        assert_eq!(count, 1);

        let temp_files = fs::read_dir(tempdir.path())?
            .filter_map(|entry| entry.ok())
            .filter(|entry| entry.file_name().to_string_lossy().contains(".tmp-"))
            .count();
        assert_eq!(temp_files, 0);

        Ok(())
    }

    #[tokio::test]
    async fn restore_rejects_corrupt_source() -> Result<()> {
        let tempdir = tempfile::tempdir()?;
        let db_path = tempdir.path().join("picshow.db");
        let corrupt_backup = tempdir.path().join("corrupt.bak");
        fs::write(&corrupt_backup, b"not a sqlite database")?;

        let manager = BackupManager::new(db_path.to_string_lossy().to_string()).await?;
        let err = manager
            .restore(corrupt_backup)
            .await
            .expect_err("corrupt restore source should fail");
        assert!(!err.to_string().is_empty());

        Ok(())
    }

    #[test]
    fn backup_filename_produces_a_parseable_dated_name() {
        let tempdir = tempfile::tempdir().unwrap();
        let folder = format!("{}/", tempdir.path().display());

        let path = backup_filename(&folder);
        assert!(path.starts_with(&folder));

        let filename = Path::new(&path).file_name().unwrap().to_str().unwrap();
        assert!(backup_timestamp(filename).is_some());
    }

    #[test]
    fn list_backups_sorts_newest_first_by_embedded_timestamp() -> Result<()> {
        let tempdir = tempfile::tempdir()?;
        let folder = format!("{}/", tempdir.path().display());

        for ts in [
            "2026-01-01_00-00-00",
            "2026-06-01_00-00-00",
            "2026-03-01_00-00-00",
        ] {
            fs::write(tempdir.path().join(format!("picshow.{}.bak", ts)), b"x")?;
        }
        // A non-matching file should be ignored.
        fs::write(tempdir.path().join("notes.txt"), b"x")?;

        let backups = list_backups(&folder)?;
        let names: Vec<String> = backups
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().to_string())
            .collect();
        assert_eq!(
            names,
            vec![
                "picshow.2026-06-01_00-00-00.bak",
                "picshow.2026-03-01_00-00-00.bak",
                "picshow.2026-01-01_00-00-00.bak",
            ]
        );
        Ok(())
    }

    #[tokio::test]
    async fn rotate_backups_keeps_only_the_newest() -> Result<()> {
        let tempdir = tempfile::tempdir()?;
        let folder = format!("{}/", tempdir.path().display());

        for ts in [
            "2026-01-01_00-00-00",
            "2026-02-01_00-00-00",
            "2026-03-01_00-00-00",
        ] {
            fs::write(tempdir.path().join(format!("picshow.{}.bak", ts)), b"x")?;
        }

        rotate_backups(&folder, 2).await?;

        let remaining = list_backups(&folder)?;
        let names: Vec<String> = remaining
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().to_string())
            .collect();
        assert_eq!(
            names,
            vec![
                "picshow.2026-03-01_00-00-00.bak",
                "picshow.2026-02-01_00-00-00.bak",
            ]
        );
        Ok(())
    }
}
