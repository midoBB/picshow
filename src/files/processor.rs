use crate::{
    config::AppConfig,
    data::{repository::MediaRepository, MediaFile, MediaType, UnfilledMediaFile},
    files::handler::get_mime_guess,
};
use anyhow::Result;
use chrono::{DateTime, Utc};
use dashmap::DashSet;
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
};
use tokio::{
    fs::{self, File},
    sync::{Mutex, Semaphore},
    time::Instant,
};
use tracing::{debug, error, info};

use super::handler::Handler;
use walkdir::{DirEntry, WalkDir};

#[derive(Clone)]
pub struct Processor {
    config: Arc<AppConfig>,
    handler: Handler,
    repository: Arc<MediaRepository>,
    duplicate_path: Arc<PathBuf>,
}

impl Processor {
    pub fn new(config: Arc<AppConfig>, repository: Arc<MediaRepository>) -> Self {
        Self {
            config: config.clone(),
            handler: Handler::new(config.clone()),
            repository,
            duplicate_path: Arc::new(
                PathBuf::from(config.clone().folder_path.as_str()).join("duplicates"),
            ),
        }
    }

    pub async fn process(
        &self,
        shutdown_rx: &mut tokio::sync::broadcast::Receiver<()>,
    ) -> Result<(u32, Option<()>)> {
        info!("Starting processing files");
        info!("Folder path: {}", self.config.folder_path);
        info!(
            "Duplicate path: {}",
            self.duplicate_path.as_path().display()
        );
        ensure_path(self.duplicate_path.clone()).await?;
        let processed_hashes: Arc<DashSet<String>> = Arc::new(DashSet::new());
        let final_processed_hashes = processed_hashes.clone();
        let folder = PathBuf::from(self.config.clone().folder_path.as_str());
        let concurrency_max = self.config.concurrency as usize;
        let semaphore = Arc::new(Semaphore::new(concurrency_max));

        let entries = WalkDir::new(folder.clone())
            .max_depth(1)
            .into_iter()
            .filter_entry(|e| !is_hidden(e))
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_file());
        let progress_counter = Arc::new(AtomicUsize::new(0));
        let last_update = Arc::new(Mutex::new(Instant::now()));

        let mut media_stream = futures::stream::iter(entries)
            .map(|entry| {
                let semaphore_clone = semaphore.clone();
                let hashset = processed_hashes.clone();
                let progress_counter = progress_counter.clone();
                let last_update = last_update.clone();
                async move {
                    let entry_arc = Arc::new(entry);
                    let _permit = semaphore_clone.acquire().await?;
                    let res = self.process_file(entry_arc.clone(), hashset).await;
                    if let Err(ref error) = res {
                        let filename = entry_arc
                            .clone()
                            .file_name()
                            .to_os_string()
                            .into_string()
                            .map_err(|_| anyhow::anyhow!("Couldn't get filename"))?;
                        error!("Error processing file {}: {}", filename, error);
                    } else {
                        let new_count = progress_counter.fetch_add(1, Ordering::SeqCst) + 1;
                        let mut last_update_time = last_update.lock().await;
                        let now = Instant::now();
                        if now.duration_since(*last_update_time).as_secs() >= 60 {
                            info!("Progress update: {} files processed", new_count);
                            progress_counter.store(0, Ordering::SeqCst);
                            *last_update_time = now;
                        }
                    }
                    res
                }
            })
            .buffer_unordered(concurrency_max);
        let mut media_files = 0u32;
        let exit_option: Option<()>;
        loop {
            tokio::select! {
                next = media_stream.next() => {
                    if let Some(result) = next {
                        if result.is_ok() {
                            media_files += 1;
                        }
                    } else {
                        exit_option = None;
                        break;
                    }
                },
                Ok(()) = shutdown_rx.recv() => {
                    debug!("Received shutdown signal, stopping file processing");
                    exit_option = Some(());
                    break;
                }
            }
        }
        self.handle_non_exsiting_files(final_processed_hashes)
            .await?;
        info!("Finished processing files");
        Ok((media_files, exit_option))
    }
    async fn process_file(
        &self,
        entry: Arc<DirEntry>,
        processed_hashes: Arc<DashSet<String>>,
    ) -> Result<MediaFile> {
        let dir_entry = &entry.clone();
        let filename = dir_entry
            .file_name()
            .to_os_string()
            .into_string()
            .map_err(|_| anyhow::anyhow!("Couldn't get filename"))?;
        let file_path = dir_entry
            .path()
            .to_str()
            .ok_or(anyhow::anyhow!("Invalid path"))?;
        let file = File::open(file_path).await?;
        let metadata = file.metadata().await?;
        let created_at = chrono::Utc::now();
        let last_modified: DateTime<Utc> = metadata.modified()?.into();
        let size = metadata.len() as i64;
        let key = self.handler.generate_key(file_path).await?;
        let filename_exists = self.repository.exists_by_name(filename.as_str()).await?;
        if filename_exists {
            let existing_file = self
                .repository
                .get_file_by_filename(filename.as_str(), false)
                .await?;
            let existing_file: UnfilledMediaFile = existing_file.into();
            if existing_file.hash == key {
                debug!(
                    "File {} has not been modified since last processing, skipping",
                    filename
                );
                return Ok(MediaFile::Unfilled(existing_file));
            }
        }
        if processed_hashes.contains(&key) {
            let original_file: UnfilledMediaFile = self
                .repository
                .get_file_by_hash(key.clone(), false)
                .await?
                .into();
            self.handle_duplicate_file(filename.as_str(), original_file.filename.as_str())
                .await?;
            return Err(anyhow::anyhow!("Found duplicate file: {}", filename));
        }
        let hash_exists = self.repository.exists_by_hash(key.clone()).await?;
        if hash_exists {
            let existing_file = self.repository.get_file_by_hash(key.clone(), false).await?;
            let mut existing_file: UnfilledMediaFile = existing_file.into();
            debug!("Updating existing file record for {}", filename);
            existing_file.filename = filename.clone();
            existing_file.last_modified = last_modified;
            if let Err(err) = self
                .repository
                .update_file_name_and_modified_date(existing_file.id, &filename, last_modified)
                .await
            {
                return Err(anyhow::anyhow!("error updating file {}: {}", filename, err));
            }
            return Ok(MediaFile::Unfilled(existing_file));
        }
        debug!("Processing new file {}", filename);
        let mime = get_mime_guess(file_path).await?;
        let file = UnfilledMediaFile {
            id: uuid::Uuid::now_v7(),
            hash: key.clone(),
            created_at,
            filename: filename.clone(),
            size,
            media_type: mime.clone(),
            last_modified,
            media: None,
            mime_type: None,
            is_favorite: false,
        };
        let file = match mime {
            MediaType::Image => self.handler.clone().handle_new_image(file, file_path).await,
            MediaType::Video => self.handler.clone().handle_new_video(file, file_path).await,
        }?;
        self.repository.insert_file(file.clone()).await?;
        processed_hashes.insert(key);
        Ok(MediaFile::Filled(file))
    }

    async fn handle_duplicate_file(&self, filename: &str, original_filename: &str) -> Result<()> {
        info!("Duplicate file found: {}", filename);
        let duplicate_path = self.duplicate_path.join(filename);
        info!(
            "Moving file to duplicate path: {}, original file: {}",
            duplicate_path.as_path().display(),
            original_filename
        );
        fs::rename(
            PathBuf::from(self.config.clone().folder_path.as_str()).join(filename),
            duplicate_path.as_path(),
        )
        .await?;
        Ok(())
    }

    async fn handle_non_exsiting_files(
        &self,
        processed_hashes: Arc<DashSet<String>>,
    ) -> Result<()> {
        let hashes = processed_hashes
            .iter()
            .map(|v| v.to_string())
            .collect::<Vec<String>>();
        self.repository
            .remove_non_existing_files_by_hashes(hashes)
            .await
    }
}

pub(crate) async fn ensure_path(duplicate_path: Arc<PathBuf>) -> Result<()> {
    fs::create_dir_all(duplicate_path.as_path()).await?;
    Ok(())
}
fn is_hidden(entry: &DirEntry) -> bool {
    entry
        .file_name()
        .to_str()
        .map(|s| s.starts_with("."))
        .unwrap_or(false)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum DeleteMode {
    MoveToTrash,
    DeletePermanently,
}
