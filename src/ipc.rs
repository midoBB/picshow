use anyhow::anyhow;
use anyhow::Result;
use tokio::fs::File;
use tokio::signal::unix::{signal, SignalKind};

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
