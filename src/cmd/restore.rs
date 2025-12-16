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
    match repo?.restore(source).await {
        Ok(_) => {
            make_lock_request(&config, InternalOP::Unlock).await?;
            info!("Restore completed");
        }
        Err(e) => {
            make_lock_request(&config, InternalOP::Unlock).await?;
            error!("Restore failed: {}", e);
        }
    }

    Ok(())
}
