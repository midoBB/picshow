use crate::{
    config::{AppConfig, DuplicateHandling},
    data::{repository::MediaRepository, MediaFile, MediaType, UnfilledMediaFile},
    files::handler::get_mime_guess,
};
use anyhow::Result;
use chrono::{DateTime, Utc};
use futures::StreamExt;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
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
use tracing::{debug, error, info, warn};

use super::handler::Handler;
use walkdir::{DirEntry, WalkDir};

#[derive(Clone)]
pub struct Processor {
    pub(crate) config: Arc<AppConfig>,
    handler: Handler,
    pub(crate) repository: Arc<MediaRepository>,
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

        // Track processed hashes for cleanup phase
        let processed_hashes: Arc<Mutex<HashSet<String>>> = Arc::new(Mutex::new(HashSet::new()));
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
                let processed_hashes_clone = processed_hashes.clone();
                let progress_counter = progress_counter.clone();
                let last_update = last_update.clone();
                async move {
                    let entry_arc = Arc::new(entry);
                    let _permit = semaphore_clone.acquire().await?;
                    let res = self
                        .process_file(entry_arc.clone(), processed_hashes_clone)
                        .await;
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
        processed_hashes: Arc<Mutex<HashSet<String>>>,
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

        // Check if file exists and hasn't been modified
        if let Ok(existing_file) = self
            .repository
            .get_file_by_filename(filename.as_str(), false)
            .await
        {
            let existing_file: UnfilledMediaFile = existing_file.into();
            if existing_file.hash == key && existing_file.last_modified == last_modified {
                debug!(
                    "File {} has not been modified since last processing, skipping",
                    filename
                );
                // Add to processed hashes for cleanup
                processed_hashes.lock().await.insert(key);

                // Backfill perceptual hashes for existing images that don't have them
                if existing_file.media_type == MediaType::Image {
                    let image_id = existing_file.id;
                    if !self.repository.has_missing_perceptual_hashes(image_id).await.unwrap_or(true) {
                        debug!("Image {} already has perceptual hashes, skipping", filename);
                        return Ok(MediaFile::Unfilled(existing_file));
                    }
                    if let Ok(hashes) = self
                        .handler
                        .compute_perceptual_hashes(file_path)
                        .await
                    {
                        if hashes.0.is_some()
                            || hashes.1.is_some()
                            || hashes.2.is_some()
                            || hashes.3.is_some()
                            || hashes.4.is_some()
                            || hashes.5.is_some()
                        {
                            if let Err(e) = self
                                .repository
                                .update_image_perceptual_hashes(
                                    image_id,
                                    hashes.0,
                                    hashes.1,
                                    hashes.2,
                                    hashes.3,
                                    hashes.4,
                                    hashes.5,
                                )
                                .await
                            {
                                warn!("Failed to backfill perceptual hashes for {}: {}", filename, e);
                            } else {
                                debug!("Backfilled perceptual hashes for existing image {}", filename);
                            }
                        }
                    }
                }

                return Ok(MediaFile::Unfilled(existing_file));
            }
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

        // Use the new upsert method to handle duplicates atomically
        match self.repository.upsert_file(file.clone()).await {
            Ok(media_file) => {
                // Add to processed hashes for cleanup
                processed_hashes.lock().await.insert(key);
                Ok(media_file)
            }
            Err(e) if e.to_string().contains("Duplicate file detected") => {
                // Handle duplicate based on configuration
                match self.config.duplicate_handling {
                    DuplicateHandling::MoveToFolder => {
                        // Try to get the original file for moving
                        if let Ok(original_file) =
                            self.repository.get_file_by_hash(key.clone(), false).await
                        {
                            let original_file: UnfilledMediaFile = original_file.into();
                            self.handle_duplicate_file(
                                filename.as_str(),
                                original_file.filename.as_str(),
                            )
                            .await?;
                        }
                    }
                    DuplicateHandling::Delete => {
                        let file_path =
                            PathBuf::from(self.config.folder_path.as_str()).join(&filename);
                        if let Err(delete_err) = fs::remove_file(file_path).await {
                            error!(
                                "Failed to delete duplicate file {}: {}",
                                filename, delete_err
                            );
                        }
                    }
                    DuplicateHandling::Skip => {
                        debug!("Skipping duplicate file: {}", filename);
                    }
                }
                Err(anyhow::anyhow!("Found duplicate file: {}", filename))
            }
            Err(e) => Err(e),
        }
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
        processed_hashes: Arc<Mutex<HashSet<String>>>,
    ) -> Result<()> {
        let hashes = processed_hashes
            .lock()
            .await
            .iter()
            .cloned()
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
