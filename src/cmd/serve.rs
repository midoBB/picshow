use anyhow::Result;
use std::{sync::Arc, time::Duration};
use tokio::{
    sync::Semaphore,
    time::{self, Interval},
};

use tracing::{debug, info};

use crate::{
    cache::AppCache,
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
    let channels = CommandChannels::default();
    let (shutdown_tx, _) = tokio::sync::broadcast::channel::<()>(1);
    let processor_shutdown = shutdown_tx.subscribe();
    let command_shutdown = shutdown_tx.subscribe();
    let api_shutdown = shutdown_tx.subscribe();

    // Initialize ConfigManager
    let config_manager = ConfigManager::new((*config).clone()).await?;

    let cache = AppCache::new(config.cache_size_mb as u64);
    let repository = Arc::new(MediaRepository::new(cache.clone(), config.clone()).await?);
    let mut command_handler = CommandHandler::new(
        config.clone(),
        repository.clone(),
        channels.command_rx,
        channels.status_tx,
    );
    let processor = Processor::new(config.clone(), repository.clone());

    let settings_manager = SettingsManager::new(config_manager.clone()).await;
    let processor_tick = time::interval(Duration::from_secs(
        config.auto_refresh_duration as u64 * 60 * 60,
    ));
    let processor_semaphore = Semaphore::new(1);
    // Get a config change receiver for the processor
    let mut config_change_rx = config_manager.subscribe();

    let processorer_handle = tokio::spawn(async move {
        let mut shutdown_rx = processor_shutdown;
        process_files(
            processor,
            processor_tick,
            processor_semaphore,
            &mut shutdown_rx,
            &mut config_change_rx,
        )
        .await
    });
    let api_handle = tokio::spawn(api::run_server(
        config.clone(),
        repository.clone(),
        api_shutdown,
        channels.command_tx,
        channels.status_rx,
        settings_manager,
    ));
    let command_handle = tokio::spawn(async move {
        let mut shutdown_rx = command_shutdown;
        command_handler.run_command_handler(&mut shutdown_rx).await;
    });
    tokio::signal::ctrl_c().await?;
    debug!("Shutting down...");
    shutdown_tx.send(())?;
    let _ = tokio::join!(processorer_handle, api_handle, command_handle);
    repository.cleanup().await?;
    Ok(())
}

async fn process_files(
    processor: Processor,
    mut tick: Interval,
    semaphore: Semaphore,
    shutdown_rx: &mut tokio::sync::broadcast::Receiver<()>,
    config_change_rx: &mut tokio::sync::broadcast::Receiver<crate::config::ConfigChange>,
) -> Result<()> {
    loop {
        tokio::select! {
            _ = shutdown_rx.recv() => {
                debug!("Shutting down processor");
                break Ok(());
            }
            config_result = config_change_rx.recv() => {
                if let std::result::Result::Ok(config_change) = config_result {
                        // Update the refresh interval if auto_refresh is enabled
                        if config_change.config.auto_refresh_enabled {
                            // Convert hours to seconds safely to avoid overflow
                            let duration_hours = config_change.config.auto_refresh_duration as u64;
                            let duration_seconds = duration_hours.saturating_mul(3600);
                            let new_duration = Duration::from_secs(duration_seconds);
                            tick = time::interval(new_duration);
                            info!("Updated refresh interval to {} seconds", duration_seconds);
                        }
                    } else {
                        debug!("Config change receiver error: channel closed");
                    }
            }
            _ = tick.tick() => {
                let _permit = semaphore.acquire().await;
                if _permit.is_err() {
                    continue;
                }
                let (media_files_count, exit_option) = processor.process(shutdown_rx).await?;
                info!("Found {} files", media_files_count);
                if exit_option.is_some() {
                    break Ok(());
                }
            }
        }
    }
}
fn port_is_available(port: u16) -> bool {
    let listener = std::net::TcpListener::bind(format!("0.0.0.0:{}", port));
    if listener.is_err() {
        return false;
    }
    let listener = listener.unwrap();
    drop(listener);
    true
}
