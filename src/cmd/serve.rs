use anyhow::{Ok, Result};
use std::{sync::Arc, time::Duration};
use tokio::{
    sync::Semaphore,
    time::{self, Interval},
};

use tracing::{debug, info};

use crate::{
    cache::AppCache, config::AppConfig, data::repository::MediaRepository,
    files::processor::Processor, server::api,
};

pub async fn handle_serve(config: &AppConfig, cli_port: Option<u16>) -> Result<()> {
    let config = Arc::new(config.clone().with_port(cli_port));
    if !port_is_available(config.port) {
        return Err(anyhow::anyhow!(
            "Port {} is already in use, Maybe another instance is running?",
            config.port
        ));
    }
    let (shutdown_tx, shutdown_rx) = tokio::sync::broadcast::channel::<()>(1);
    let cache = AppCache::new(config.cache_size_mb as u64);
    let db_path = format!("{}picshow.db", &config.db_path);
    let repository = Arc::new(MediaRepository::new(db_path.as_str(), cache.clone()).await?);
    let processor = Arc::new(Processor::new(config.clone(), repository.clone()));
    let processor_tick = time::interval(Duration::from_secs(
        config.refresh_interval as u64 * 60 * 60,
    ));
    let processor_semaphore = Arc::new(Semaphore::new(1));
    let processor_shutdown = shutdown_tx.subscribe();
    let processorer_handle = tokio::spawn(process_files(
        processor.clone(),
        processor_tick,
        processor_semaphore.clone(),
        processor_shutdown,
    ));
    let api_handle = tokio::spawn(api::run_server(
        config.clone(),
        repository.clone(),
        shutdown_rx,
    ));
    tokio::signal::ctrl_c().await?;
    debug!("Shutting down...");
    shutdown_tx.send(())?;
    let _ = tokio::join!(processorer_handle, api_handle);
    repository.cleanup().await?;
    Ok(())
}

async fn process_files(
    processor: Arc<Processor>,
    mut tick: Interval,
    semaphore: Arc<Semaphore>,
    mut shutdown_rx: tokio::sync::broadcast::Receiver<()>,
) -> Result<()> {
    loop {
        tokio::select! {
            _ = tick.tick() => {
                let _permit = semaphore.acquire().await;
                if _permit.is_err() {
                    continue;
                }
                let process_res = <Processor as Clone>::clone(&processor).process().await?;
                info!("Files processed: {}", process_res);
            }
            _ = shutdown_rx.recv() => {
                debug!("Processor received shutdown signal");
                break Ok(());
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
