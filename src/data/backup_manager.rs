use anyhow::Result;
use rusqlite::{config::DbConfig, Connection, OpenFlags};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::sync::Mutex;

use tracing::info;

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
        super::checkpoint_truncate_rusqlite(&conn)?;
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
        super::checkpoint_truncate_rusqlite(&conn)?;
        super::check_rusqlite_integrity(&conn)?;
        Ok(())
    }

    /// Perform database maintenance operations optimized for SD cards
    pub async fn perform_maintenance(&self) -> Result<()> {
        use tracing::{debug, info};

        info!("Starting database maintenance in backup manager...");

        let conn = self.write_connection.lock().await;

        // Checkpoint WAL to reduce file size
        debug!("Checkpointing WAL...");
        super::checkpoint_truncate_rusqlite(&conn)?;

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

fn verify_database_file(path: &Path) -> Result<()> {
    let uri = format!("file:{}?mode=ro", path.display());
    let conn = Connection::open_with_flags(
        uri.as_str(),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )?;
    super::apply_rusqlite_pragmas(&conn, false)?;
    super::check_rusqlite_integrity(&conn)
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
            crate::data::checkpoint_truncate_rusqlite(&conn)?;
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
}
