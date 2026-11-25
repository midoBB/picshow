use std::path::PathBuf;

use crate::{
    cmd::{make_lock_request, InternalOP},
    config::AppConfig,
    data::backup_manager::{backup_filename, finalize_snapshot, BackupManager},
    ipc::OperationLock,
};
use anyhow::Result;
use tracing::{debug, info};

pub async fn handle_backup(config: AppConfig, destination: Option<PathBuf>) -> Result<()> {
    let _lock = OperationLock::new()
        .await
        .map_err(|_| anyhow::anyhow!("Another instance of backup/restore is already running"))?;
    let default_path = backup_filename(&config.backup_folder_path);
    let dest_path = destination.unwrap_or(default_path.into());
    let dest_path = dest_path
        .as_os_str()
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("Invalid destination path: contains non-UTF-8 characters"))?
        .to_string();
    if let Some(parent) = std::path::Path::new(&dest_path).parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    info!("Backing up the database to file: {}", dest_path.clone());
    let db_path = format!("{}picshow.db", config.db_path.clone());
    // Integrity-check the source before pausing the server's writes, and
    // verify the copy after resuming them; only the page copy needs the lock.
    let repo = BackupManager::new(db_path).await?;
    make_lock_request(&config, InternalOP::Lock).await?;
    let snapshot = repo.snapshot(&dest_path).await;
    let unlock_result = make_lock_request(&config, InternalOP::Unlock).await;
    let backup_result =
        snapshot.and_then(|temp| finalize_snapshot(&temp, std::path::Path::new(&dest_path)));
    match (backup_result, unlock_result) {
        (Ok(_), Ok(_)) => info!("Backup completed"),
        (Err(e), _) => return Err(e),
        (Ok(_), Err(e)) => return Err(e),
    }
    debug!("Shutdown complete");
    Ok(())
}
