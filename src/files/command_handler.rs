use anyhow::Result;
use std::{path::PathBuf, sync::Arc};
use tokio::fs;

use tokio::sync::broadcast;
use tracing::{debug, info};
use uuid::Uuid;

use crate::{
    config::AppConfig,
    data::{repository::MediaRepository, UnfilledMediaFile},
    ipc::{ProcessorCommand, ProcessorStatus},
};

use super::processor::{ensure_path, DeleteMode};

pub struct CommandHandler {
    config: Arc<AppConfig>,
    repository: Arc<MediaRepository>,
    trash_path: Arc<PathBuf>,
    command_rx: broadcast::Receiver<ProcessorCommand>,
    status_tx: broadcast::Sender<ProcessorStatus>,
}

impl CommandHandler {
    pub fn new(
        config: Arc<AppConfig>,
        repository: Arc<MediaRepository>,
        command_rx: broadcast::Receiver<ProcessorCommand>,
        status_tx: broadcast::Sender<ProcessorStatus>,
    ) -> Self {
        Self {
            config: config.clone(),
            repository,
            trash_path: Arc::new(PathBuf::from(config.clone().folder_path.as_str()).join("trash")),
            command_rx,
            status_tx,
        }
    }

    async fn delete_file(&mut self, fileids: Vec<Uuid>, mode: DeleteMode) -> Result<()> {
        info!(
            "Deleting {} file(s) with mode {:?}",
            fileids.len(),
            mode
        );
        ensure_path(self.trash_path.clone()).await?;
        for id in fileids {
            debug!("Getting file with id {}", id);
            let file = self.repository.get_file_by_id(id, false).await?;
            let file = UnfilledMediaFile::from(file);
            debug!("File {:?} found", file.filename);
            let file_path = PathBuf::from(self.config.clone().folder_path.as_str())
                .join(file.filename.as_str());
            let filename = file.filename.as_str();
            match mode {
                DeleteMode::MoveToTrash => {
                    let trash_path = self.trash_path.join(filename);
                    fs::rename(file_path.as_path(), trash_path.as_path()).await?;
                    info!("Moved {} to trash", filename);
                }
                DeleteMode::DeletePermanently => {
                    fs::remove_file(file_path.as_path()).await?;
                    info!("Deleted {}", filename);
                }
            };
        }
        Ok(())
    }
    pub async fn run_command_handler(
        &mut self,
        shutdown_rx: &mut tokio::sync::broadcast::Receiver<()>,
    ) {
        loop {
            tokio::select! {
                _ = shutdown_rx.recv() => {
                    debug!("Received shutdown signal, stopping command handling");
                    break;
                }
                command = self.command_rx.recv() => {
                    match command {
                        Ok(command) => {
                            debug!("Received command: {:?}", command);
                            match &command {
                                ProcessorCommand::DeleteFiles { ids, mode } => {
                                    match self.delete_file(ids.clone(), mode.clone()).await {
                                        Err(e) => {
                                            debug!("Error for DeleteFiles command: {}", e);
                                            let _ = self.status_tx.send(ProcessorStatus::ProcessingError { error: e.to_string() });
                                        },
                                       _ => {
                                            let _ = self.status_tx.send(ProcessorStatus::TaskDone { command });
                                            debug!("DeleteFiles command completed");
                                        }
                                    }
                                }
                                ProcessorCommand::TriggerScan => {
                                    debug!("TriggerScan command received");
                                }
                            }
                        },
                        Err(_) => {
                            debug!("Command channel closed, stopping file processing");
                            break;
                        }
                    }
                },
            }
        }
    }
}