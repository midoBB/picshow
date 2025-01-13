use std::sync::Arc;

use anyhow::Result;
use axum::{
    extract::{Request, State},
    http::StatusCode,
    middleware,
    response::IntoResponse,
    routing::post,
    Json,
};
use local_ip_address::list_afinet_netifas;
use rust_embed::RustEmbed;
use serde_json::json;
use tokio::sync::Mutex;
use tracing::{error, info};

use crate::{
    config::AppConfig,
    logging,
    server::{middlewares, serve_static_file},
};

#[derive(RustEmbed)]
#[folder = "first_run_frontend/dist/"]
pub struct FirstRunFrontendAssets;
struct AppState {
    shutdown_tx: Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
}
pub async fn run_server(cfg: AppConfig) -> Result<AppConfig> {
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel();
    let state = Arc::new(AppState {
        shutdown_tx: Mutex::new(Some(shutdown_tx)),
    });
    let api_routes = axum::Router::new().route("/config", post(save_config));
    let app = axum::Router::new()
        .nest("/api", api_routes)
        .with_state(state)
        .fallback(
            |path: Request| async move { serve_static_file::<FirstRunFrontendAssets>(path.uri()) },
        )
        .layer(middlewares())
        .layer(middleware::from_fn(logging::log_request_response));

    info!("Starting server on port {}", cfg.clone().port);
    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", cfg.port)).await?;
    info!("Server is running on:");
    info!("  ➜  Local:   http://localhost:{}/", cfg.port);
    for (_, ip) in list_afinet_netifas()?
        .into_iter()
        .filter(|(_, ip)| ip.is_ipv4())
    {
        info!("  ➜  Network: http://{}:{}/", ip, cfg.port);
    }
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            shutdown_rx.await.ok();
        })
        .await?;
    AppConfig::try_load().map_err(|e| {
        error!("Error loading configuration: {}", e);
        anyhow::anyhow!("Error loading configuration")
    })
}

async fn save_config(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<AppConfig>,
) -> impl IntoResponse {
    let config = payload;

    match config.save() {
        Ok(_) => info!("Configuration saved"),
        Err(e) => {
            error!("Error saving configuration: {}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": "Failed to save config"})),
            )
                .into_response();
        }
    }
    if let Some(tx) = state.shutdown_tx.lock().await.take() {
        let _ = tx.send(());
    }
    StatusCode::OK.into_response()
}
