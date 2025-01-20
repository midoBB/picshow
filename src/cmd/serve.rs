use anyhow::{Ok, Result};
use std::{sync::Arc, time::Duration};
use tokio::{
    sync::Semaphore,
    time::{self, Interval},
};

use tracing::{debug, info};

use crate::{
    cache::AppCache, config::AppConfig, data::repository::MediaRepository,
    files::{command_handler::CommandHandler, processor::Processor}, ipc::CommandChannels, server::api,
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
    let cache = AppCache::new(config.cache_size_mb as u64);
    let repository = Arc::new(MediaRepository::new(cache.clone(), config.clone()).await?);
    let mut command_handler = CommandHandler::new(config.clone(), repository.clone(), channels.command_rx, channels.status_tx);
    let processor = Processor::new(
        config.clone(),
        repository.clone(),
    );

    let processor_tick = time::interval(Duration::from_secs(
        config.refresh_interval as u64 * 60 * 60,
    ));
    let processor_semaphore = Semaphore::new(1);
    let processorer_handle = tokio::spawn(async move {
        let mut shutdown_rx = processor_shutdown;
        process_files(
            processor,
            processor_tick,
            processor_semaphore,
            &mut shutdown_rx,
        )
        .await
    });
    let api_handle = tokio::spawn(api::run_server(
        config.clone(),
        repository.clone(),
        api_shutdown,
        channels.command_tx,
        channels.status_rx,
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
) -> Result<()> {
    loop {
        tick.tick().await;
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
fn port_is_available(port: u16) -> bool {
    let listener = std::net::TcpListener::bind(format!("0.0.0.0:{}", port));
    if listener.is_err() {
        return false;
    }
    let listener = listener.unwrap();
    drop(listener);
    true
}
