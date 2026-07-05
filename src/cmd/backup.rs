use std::path::PathBuf;

use crate::{
    cmd::{make_lock_request, InternalOP},
    config::AppConfig,
    data::backup_manager::BackupManager,
    ipc::OperationLock,
};
use anyhow::Result;
use chrono::Local;
use tracing::{debug, info};

pub async fn handle_backup(config: AppConfig, destination: Option<PathBuf>) -> Result<()> {
    let _lock = OperationLock::new()
        .await
        .map_err(|_| anyhow::anyhow!("Another instance of backup/restore is already running"))?;
    make_lock_request(&config, InternalOP::Lock).await?;
    let datetime = Local::now().format("%Y-%m-%d_%H-%M-%S").to_string();
    let default_path = format!("{}picshow.{}.bak", config.backup_folder_path, datetime).to_string();
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
    let repo = BackupManager::new(db_path).await;
    if let Err(e) = repo {
        make_lock_request(&config, InternalOP::Unlock).await?;
        return Err(e);
    }
    let backup_result = repo?.backup(dest_path).await;
    let unlock_result = make_lock_request(&config, InternalOP::Unlock).await;
    match (backup_result, unlock_result) {
        (Ok(_), Ok(_)) => info!("Backup completed"),
        (Err(e), _) => return Err(e),
        (Ok(_), Err(e)) => return Err(e),
    }
    debug!("Shutdown complete");
    Ok(())
}
