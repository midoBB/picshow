use anyhow::Result;
use rusqlite::{config::DbConfig, Connection, OpenFlags};
use std::{path::PathBuf, sync::Arc};
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
        write_connection.execute_batch(
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
        let backup_manager = Self {
            write_connection: Arc::new(Mutex::new(write_connection)),
        };

        // Check database integrity before using it for backup operations
        backup_manager.check_integrity().await?;

        Ok(backup_manager)
    }

    /// Check database integrity for backup operations
    async fn check_integrity(&self) -> Result<()> {
        use tracing::{error, info, warn};

        info!("Checking database integrity for backup operations...");

        let conn = self.write_connection.lock().await;

        // Use rusqlite's PRAGMA interface for integrity check
        let mut stmt = conn.prepare("PRAGMA quick_check")?;
        let result: String = stmt.query_row([], |row| row.get(0))?;

        if result == "ok" {
            info!("Database integrity check passed for backup operations");
            return Ok(());
        }

        warn!("Database quick check failed: {}", result);

        // Perform full integrity check
        let mut stmt = conn.prepare("PRAGMA integrity_check")?;
        let result: String = stmt.query_row([], |row| row.get(0))?;

        if result == "ok" {
            info!("Database full integrity check passed");
            return Ok(());
        }

        error!("Database corruption detected in backup manager: {}", result);
        Err(anyhow::anyhow!("Database corruption detected: {}", result))
    }

    pub async fn backup(&self, destination: String) -> Result<()> {
        let conn = self.write_connection.lock().await;
        let progress_fn = |p: rusqlite::backup::Progress| {
            let completed_pages = p.pagecount - p.remaining;
            let percentage = if p.pagecount > 0 {
                (completed_pages as f64 / p.pagecount as f64) * 100.0
            } else {
                0.0
            };
            info!("Backup progress: {:.2}%", percentage);
        };
        conn.backup(
            rusqlite::DatabaseName::Main,
            &destination,
            Some(progress_fn),
        )?;
        Ok(())
    }

    pub async fn restore(&self, source: PathBuf) -> Result<()> {
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
        Ok(())
    }

    /// Perform database maintenance operations optimized for SD cards
    pub async fn perform_maintenance(&self) -> Result<()> {
        use tracing::{debug, info};

        info!("Starting database maintenance in backup manager...");

        let conn = self.write_connection.lock().await;

        // Checkpoint WAL to reduce file size
        debug!("Checkpointing WAL...");
        conn.pragma_update(None, "wal_checkpoint", "TRUNCATE")?;

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
