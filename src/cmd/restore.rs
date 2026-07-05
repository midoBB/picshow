use std::path::PathBuf;

use crate::{
    cmd::{make_lock_request, InternalOP},
    config::AppConfig,
    data::backup_manager::BackupManager,
    ipc::OperationLock,
};
use anyhow::Result;
use tracing::{error, info};

pub async fn handle_restore(config: AppConfig, source: PathBuf) -> Result<()> {
    let _lock = OperationLock::new()
        .await
        .map_err(|_| anyhow::anyhow!("Another instance of backup/restore is already running"))?;

    make_lock_request(&config, InternalOP::Lock).await?;
    info!("Starting restore from {:?} ", source);

    let repo = BackupManager::new(format!("{}picshow.db", config.clone().db_path.as_str())).await;
    if let Err(e) = repo {
        make_lock_request(&config, InternalOP::Unlock).await?;
        return Err(e);
    }
    let restore_result = repo?.restore(source).await;
    let unlock_result = make_lock_request(&config, InternalOP::Unlock).await;
    match (restore_result, unlock_result) {
        (Ok(_), Ok(_)) => info!("Restore completed"),
        (Err(e), _) => {
            error!("Restore failed: {}", e);
            return Err(e);
        }
        (Ok(_), Err(e)) => return Err(e),
    }

    Ok(())
}
