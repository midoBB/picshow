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
                PRAGMA synchronous = NORMAL;
                PRAGMA busy_timeout = 30000;
            "#,
        )?;
        Ok(Self {
            write_connection: Arc::new(Mutex::new(write_connection)),
        })
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
}
