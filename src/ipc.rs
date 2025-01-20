use anyhow::anyhow;
use anyhow::Result;
use serde::Deserialize;
use serde::Serialize;
use tokio::fs::File;
use tokio::signal::unix::{signal, SignalKind};
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::files::processor::DeleteMode;

pub const BACKUP_LOCK_PATH: &str = "/tmp/picshow.backup.lock";

pub struct OperationLock {
    _file: File,
}

impl OperationLock {
    pub async fn new() -> Result<Self> {
        if (File::open(BACKUP_LOCK_PATH).await).is_ok() {
            return Err(anyhow!("Another operation is already running"));
        }

        let file = File::create(BACKUP_LOCK_PATH).await?;

        let lock = Self { _file: file };

        // Set up signal handling
        let lock_path_clone = BACKUP_LOCK_PATH.to_string();
        tokio::spawn(async move {
            let mut sigint = signal(SignalKind::interrupt()).unwrap();
            let mut sigterm = signal(SignalKind::terminate()).unwrap();

            tokio::select! {
                _ = sigint.recv() => {},
                _ = sigterm.recv() => {},
            }

            let _ = tokio::fs::remove_file(lock_path_clone).await;
            std::process::exit(0);
        });

        Ok(lock)
    }
}

impl Drop for OperationLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(BACKUP_LOCK_PATH);
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ProcessorCommand {
    DeleteFiles { ids: Vec<Uuid>, mode: DeleteMode },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ProcessorStatus {
    TaskDone { command: ProcessorCommand },
    ProcessingError { error: String },
}
pub struct CommandChannels {
    pub command_tx: broadcast::Sender<ProcessorCommand>,
    pub command_rx: broadcast::Receiver<ProcessorCommand>,
    pub status_tx: broadcast::Sender<ProcessorStatus>,
    pub status_rx: broadcast::Receiver<ProcessorStatus>,
}

impl CommandChannels {
    pub fn new() -> Self {
        let (command_tx, command_rx) = broadcast::channel(100);
        let (status_tx, status_rx) = broadcast::channel(100);

        Self {
            command_tx,
            command_rx,
            status_tx,
            status_rx,
        }
    }
}

impl Default for CommandChannels {
    fn default() -> Self {
        Self::new()
    }
}
