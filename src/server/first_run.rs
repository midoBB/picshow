use std::{env, fs, path::Path, sync::Arc};

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
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::Mutex;
use tracing::{error, info};

use crate::{
    config::AppConfig,
    logging,
    server::{middlewares, serve_static_file},
};

#[derive(Deserialize)]
struct BrowseRequest {
    path: String,
    #[serde(rename = "showHidden")]
    show_hidden: bool,
}

#[derive(Serialize, Deserialize, Eq)]
struct DirectoryItem {
    name: String,
    path: String,
    is_dir: bool,
}

impl Ord for DirectoryItem {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.name.cmp(&other.name)
    }
}

// Required for Ord implementation
impl PartialOrd for DirectoryItem {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

// Required for Ord implementation
impl std::cmp::PartialEq for DirectoryItem {
    fn eq(&self, other: &Self) -> bool {
        self.name == other.name
    }
}

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
    let api_routes = axum::Router::new()
        .route("/config", post(save_config))
        .route("/browse", post(browse_directory));
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
fn get_start_dir() -> String {
    match env::var("HOME") {
        Ok(path) => path,
        Err(_) => "/".to_string(),
    }
}
async fn browse_directory(Json(payload): Json<BrowseRequest>) -> impl IntoResponse {
    let path = if payload.path.is_empty() {
        get_start_dir()
    } else {
        payload.path
    };
    let dir_path = Path::new(&path);
    if !dir_path.exists() || !dir_path.is_dir() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error": "Invalid directory path"})),
        )
            .into_response();
    }

    match fs::read_dir(dir_path) {
        Ok(entries) => {
            let mut items: Vec<DirectoryItem> = Vec::new();
            for entry in entries.filter_map(Result::ok) {
                let file_type = entry.file_type().unwrap();
                let is_dir = file_type.is_dir();
                let is_hidden = entry.file_name().to_string_lossy().starts_with('.');
                let hidden_wanted = payload.show_hidden;
                let is_hidden = is_hidden && !hidden_wanted;

                // Only include directories
                if is_dir && !is_hidden {
                    let name = entry.file_name().to_string_lossy().to_string();
                    let entry_path = entry.path().to_string_lossy().to_string();
                    items.push(DirectoryItem {
                        name,
                        path: entry_path,
                        is_dir,
                    });
                }
            }
            items.sort();

            // Add parent directory option for navigation (except at root)
            if path != "/" {
                if let Some(parent) = Path::new(&path).parent() {
                    let parent_path = parent.to_string_lossy().to_string();
                    items.insert(
                        0,
                        DirectoryItem {
                            name: "..".to_string(),
                            path: parent_path,
                            is_dir: true,
                        },
                    );
                }
            }

            (StatusCode::OK, Json(json!({"items": items}))).into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error": format!("Failed to read directory: {}", e)})),
        )
            .into_response(),
    }
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
