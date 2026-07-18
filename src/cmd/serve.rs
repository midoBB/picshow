use anyhow::Result;
use std::{sync::Arc, time::Duration};
use tokio::{
    sync::Semaphore,
    time::{self, Interval},
};

use tracing::{debug, error, info};

use crate::{
    cache::AppCache,
    clustering::ClusterBuilder,
    config::{AppConfig, ConfigManager},
    data::repository::MediaRepository,
    files::{command_handler::CommandHandler, processor::Processor},
    ipc::CommandChannels,
    server::api,
    settings::SettingsManager,
};

pub async fn handle_serve(config: &AppConfig, cli_port: Option<u16>) -> Result<()> {
    let config = Arc::new(config.clone().with_port(cli_port));
    if !port_is_available(config.port) {
        return Err(anyhow::anyhow!(
            "Port {} is already in use, Maybe another instance is running?",
            config.port
        ));
    }
    info!("PicShow {} is starting", env!("APP_VERSION"));
    let channels = CommandChannels::default();
    let (shutdown_tx, _) = tokio::sync::broadcast::channel::<()>(1);
    let processor_shutdown = shutdown_tx.subscribe();
    let command_shutdown = shutdown_tx.subscribe();
    let api_shutdown = shutdown_tx.subscribe();

    // Initialize ConfigManager
    let config_manager = ConfigManager::new((*config).clone()).await?;

    let cache = AppCache::new(config.cache_size_mb as u64);
    let repository = Arc::new(MediaRepository::new(cache.clone(), config.clone()).await?);
    if let Ok(stats) = repository.get_stats().await {
        info!(
            "Loaded {} files ({} images, {} videos, {} favorites)",
            stats.count, stats.images, stats.videos, stats.favorites
        );
    }
    let status_tx = channels.status_tx.clone();
    let mut command_handler = CommandHandler::new(
        config.clone(),
        repository.clone(),
        channels.command_rx,
        channels.status_tx,
    );
    let processor = Processor::new(config.clone(), repository.clone());

    let settings_manager = SettingsManager::new(config_manager.clone()).await;
    let auto_refresh_enabled = config.auto_refresh_enabled;
    let auto_refresh_duration = config.auto_refresh_duration; // Duration is in hours
    let processor_tick = if auto_refresh_enabled {
        // Convert hours to seconds
        Some(time::interval(Duration::from_secs(
            auto_refresh_duration as u64 * 3600,
        )))
    } else {
        None
    };
    let processor_semaphore = Semaphore::new(1);
    // Get a config change receiver for the processor
    let mut config_change_rx = config_manager.subscribe();

    let command_tx = channels.command_tx.clone();
    let status_rx = channels.status_rx;
    let api_command_tx = command_tx.clone();
    let processorer_handle = tokio::spawn(async move {
        let mut shutdown_rx = processor_shutdown;
        let command_rx = command_tx.subscribe();
        process_files(
            processor,
            processor_tick,
            processor_semaphore,
            &mut shutdown_rx,
            &mut config_change_rx,
            auto_refresh_enabled,
            status_tx,
            command_rx,
        )
        .await
    });
    let api_handle = tokio::spawn(api::run_server(
        config.clone(),
        repository.clone(),
        api_shutdown,
        api_command_tx,
        status_rx,
        settings_manager,
    ));
    let command_handle = tokio::spawn(async move {
        let mut shutdown_rx = command_shutdown;
        command_handler.run_command_handler(&mut shutdown_rx).await;
    });
    let mut sigterm = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = sigterm.recv() => {}
    }
    debug!("Shutting down...");
    shutdown_tx.send(())?;
    let _ = tokio::join!(processorer_handle, api_handle, command_handle);
    repository.cleanup().await?;
    Ok(())
}

async fn process_files(
    processor: Processor,
    mut tick: Option<Interval>,
    semaphore: Semaphore,
    shutdown_rx: &mut tokio::sync::broadcast::Receiver<()>,
    config_change_rx: &mut tokio::sync::broadcast::Receiver<crate::config::ConfigChange>,
    mut auto_refresh_enabled: bool,
    status_tx: tokio::sync::broadcast::Sender<crate::ipc::ProcessorStatus>,
    mut command_rx: tokio::sync::broadcast::Receiver<crate::ipc::ProcessorCommand>,
) -> Result<()> {
    loop {
        tokio::select! {
            _ = shutdown_rx.recv() => {
                debug!("Shutting down processor");
                break Ok(());
            }
            command = command_rx.recv() => {
                if let Ok(crate::ipc::ProcessorCommand::TriggerScan) = command {
                    let _permit = semaphore.acquire().await;
                    if _permit.is_err() {
                        continue;
                    }
                    // Send processing started status
                    let _ = status_tx.send(crate::ipc::ProcessorStatus::ProcessingStarted);
                    info!("Processing started");
                    let (media_files_count, _) = processor.process(shutdown_rx).await?;
                    info!("Processing complete: {} files found", media_files_count);
                    // Rebuild clusters after scan
                    rebuild_clusters(&processor).await;
                    // Recreate stats from actual data after scan
                    if let Err(e) = processor.repository.recreate_stats().await {
                        error!("Failed to recreate stats: {:?}", e);
                    }
                    // Send processing finished status
                    let _ = status_tx.send(crate::ipc::ProcessorStatus::ProcessingFinished);
                    info!("Processing finished");
                }
            }
            config_result = config_change_rx.recv() => {
                if let std::result::Result::Ok(config_change) = config_result {
                    // Update auto_refresh_enabled state
                    auto_refresh_enabled = config_change.config.auto_refresh_enabled;

                    // Update the refresh interval if auto_refresh is enabled
                    if auto_refresh_enabled {
                        // Convert hours to seconds safely to avoid overflow
                        let duration_hours = config_change.config.auto_refresh_duration as u64;
                        let duration_seconds = duration_hours.saturating_mul(3600);
                        let new_duration = Duration::from_secs(duration_seconds);
                        tick = Some(time::interval(new_duration));
                        info!("Auto-refresh enabled with interval {} hours ({} seconds)", duration_hours, duration_seconds);
                    } else {
                        tick = None;
                        info!("Auto-refresh disabled");
                    }
                } else {
                    debug!("Config change receiver error: channel closed");
                }
            }
            _ = async {
                match &mut tick {
                    Some(t) => t.tick().await,
                    None => std::future::pending().await,
                }
            }, if auto_refresh_enabled => {
                let _permit = semaphore.acquire().await;
                if _permit.is_err() {
                    continue;
                }
                // Send processing started status
                let _ = status_tx.send(crate::ipc::ProcessorStatus::ProcessingStarted);
                info!("Processing started");
                let (media_files_count, exit_option) = processor.process(shutdown_rx).await?;
                info!("Processing complete: {} files found", media_files_count);
                // Rebuild clusters after scan
                rebuild_clusters(&processor).await;
                // Recreate stats from actual data after scan
                if let Err(e) = processor.repository.recreate_stats().await {
                    error!("Failed to recreate stats: {:?}", e);
                }
                // Send processing finished status
                let _ = status_tx.send(crate::ipc::ProcessorStatus::ProcessingFinished);
                info!("Processing finished");
                if exit_option.is_some() {
                    break Ok(());
                }
            }
        }
    }
}
fn port_is_available(port: u16) -> bool {
    match std::net::TcpListener::bind(format!("0.0.0.0:{}", port)) {
        Ok(listener) => {
            drop(listener);
            true
        }
        Err(_) => false,
    }
}

async fn rebuild_clusters(processor: &Processor) {
    let builder = ClusterBuilder::new(processor.repository.clone(), &processor.config);
    match builder.build_clusters(false, true).await {
        Ok(stats) => {
            info!(
                "Cluster rebuild complete: {} clusters, {} images clustered",
                stats.clusters_created, stats.images_clustered
            );
        }
        Err(e) => {
            error!("Failed to rebuild clusters: {:?}", e);
        }
    }
}
