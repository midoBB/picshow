use std::{path::PathBuf, sync::Arc};

use crate::{
    config::{AppConfig, PartialAppSettings},
    data::{repository::MediaRepository, FilledMediaFile, Media},
    files::processor::DeleteMode,
    ipc::{ProcessorCommand, ProcessorStatus},
    logging,
    server::{middlewares, serve_static_file, MediaFileDTOVec, PaginationDTO},
    settings::SettingsManager,
};
use anyhow::Result;
use axum::{
    body::Body,
    extract::{Path, Query, Request, State},
    http::{header, HeaderMap, StatusCode},
    middleware,
    response::{sse::Event, IntoResponse, Sse},
    routing::{delete, get, patch, post},
    Json,
};

use chrono::DateTime;
use local_ip_address::list_afinet_netifas;
use serde_json::json;
use tokio::{fs::File, sync::broadcast};
use tokio_util::io::ReaderStream;
use tracing::{debug, error, info};
use uuid::Uuid;

use rust_embed::RustEmbed;

use super::{DeleteFilesRequest, FileQuery, FilledFileQuery, StatsDTO};

#[derive(RustEmbed)]
#[folder = "app_frontend/dist/"]
pub struct FrontendAssets;

struct AppState {
    config: Arc<AppConfig>,
    repo: Arc<MediaRepository>,
    command_tx: broadcast::Sender<ProcessorCommand>,
    status_rx: broadcast::Receiver<ProcessorStatus>,
    settings: SettingsManager,
    is_processing: Arc<tokio::sync::Mutex<bool>>,
}

pub async fn run_server(
    config: Arc<AppConfig>,
    repo: Arc<MediaRepository>,
    mut shutdown_rx: tokio::sync::broadcast::Receiver<()>,
    command_tx: broadcast::Sender<ProcessorCommand>,
    status_rx: broadcast::Receiver<ProcessorStatus>,
    settings: SettingsManager,
) -> Result<()> {
    let state = Arc::new(AppState {
        config,
        repo,
        command_tx,
        status_rx,
        settings,
        is_processing: Arc::new(tokio::sync::Mutex::new(false)),
    });
    let api_routes = axum::Router::new()
        .route("/", delete(delete_files))
        .route("/", get(get_files))
        .route("/stats", get(get_stats))
        .route("/settings", get(get_settings))
        .route("/settings", patch(update_settings))
        .route("/:id/favorite", get(get_favorite_status))
        .route("/:id/favorite", patch(toggle_favorite))
        .route("/image/:id", get(get_image))
        .route("/video/:id", get(stream_video))
        .route("/thumbnail/:id", get(get_thumbnail))
        .route("/processor-status", get(processor_status_stream))
        .route("/internal/trigger-scan", post(trigger_scan))
        .route("/internal/lock/:secret", get(lock))
        .route("/internal/unlock/:secret", get(unlock))
        .route("/clusters", get(get_clusters_handler))
        .route("/clusters/:id", get(get_cluster_detail_handler))
        .route("/clusters/:id/resolve", post(resolve_cluster_handler))
        .route("/internal/rebuild-clusters", post(rebuild_clusters_handler));
    let app = axum::Router::new()
        .nest("/api", api_routes)
        .fallback(|path: Request| async move { serve_static_file::<FrontendAssets>(path.uri()) })
        .layer(middlewares())
        .layer(middleware::from_fn(logging::log_request_response))
        .with_state(state.clone());

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", state.config.port)).await?;
    info!("Server is running on:");
    info!("  ➜  Local:   http://localhost:{}/", state.config.port);
    for (_, ip) in list_afinet_netifas()?
        .into_iter()
        .filter(|(_, ip)| ip.is_ipv4())
    {
        info!("  ➜  Network: http://{}:{}/", ip, state.config.port);
    }
    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            shutdown_rx.recv().await.ok();
            debug!("Shutting down API server");
        })
        .await?;
    Ok(())
}

async fn get_stats(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let stats = state.repo.get_stats().await;
    match stats {
        Ok(stats) => {
            let is_processing = *state.is_processing.lock().await;
            axum::Json(StatsDTO::from((stats, is_processing))).into_response()
        }
        Err(e) => {
            tracing::error!("Failed to get stats: {:?}", e);
            axum::http::StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn get_image(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> impl IntoResponse {
    get_media_file(state, id, headers).await
}
async fn stream_video(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> impl IntoResponse {
    get_media_file(state, id, headers).await
}

async fn get_thumbnail(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let file_id = match Uuid::parse_str(&id) {
        Ok(id) => id,
        Err(e) => {
            tracing::error!("Failed to parse file id: {:?}", e);
            return (
                axum::http::StatusCode::BAD_REQUEST,
                axum::response::Json(json!({"error": "Invalid file id"})),
            )
                .into_response();
        }
    };
    let media_file = match state.repo.get_file_by_id(file_id, true).await {
        Ok(file) => match FilledMediaFile::try_from(file) {
            Ok(filled) => filled,
            Err(e) => {
                tracing::error!("Failed to convert media file: {:?}", e);
                return (
                    axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                    axum::response::Json(json!({"error": "Failed to convert media file"})),
                )
                    .into_response();
            }
        },
        Err(e) => {
            tracing::error!("Failed to get file: {:?}", e);
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                axum::response::Json(json!({"error": "Failed to get file"})),
            )
                .into_response();
        }
    };

    // Check If-Modified-Since header
    if headers
        .get(header::IF_MODIFIED_SINCE)
        .and_then(|h| h.to_str().ok())
        .and_then(|s| DateTime::parse_from_rfc2822(s).ok())
        .is_some_and(|if_modified_since| media_file.last_modified <= if_modified_since)
    {
        debug!("Returning 304 Not Modified");
        return StatusCode::NOT_MODIFIED.into_response();
    }

    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "image/jpeg".to_string()),
            (header::LAST_MODIFIED, media_file.last_modified.to_rfc2822()),
            (header::CACHE_CONTROL, "public, max-age=12".to_string()),
        ],
        match media_file.media {
            Media::Image(image) => image.thumbnail.data,
            Media::Video(video) => video.thumbnail.data,
        },
    )
        .into_response()
}

async fn get_media_file(state: Arc<AppState>, id: String, headers: HeaderMap) -> impl IntoResponse {
    let file_id = match Uuid::parse_str(&id) {
        Ok(id) => id,
        Err(e) => {
            tracing::error!("Failed to parse file id: {:?}", e);
            return (
                axum::http::StatusCode::BAD_REQUEST,
                axum::response::Json(json!({"error": "Invalid file id"})),
            )
                .into_response();
        }
    };

    let media_file = match state.repo.get_file_by_id(file_id, true).await {
        Ok(file) => match FilledMediaFile::try_from(file) {
            Ok(filled) => filled,
            Err(e) => {
                tracing::error!("Failed to convert media file: {:?}", e);
                return (
                    axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                    axum::response::Json(json!({"error": "Failed to convert media file"})),
                )
                    .into_response();
            }
        },
        Err(e) => {
            tracing::error!("Failed to get file: {:?}", e);
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                axum::response::Json(json!({"error": "Failed to get file"})),
            )
                .into_response();
        }
    };

    // Check If-Modified-Since header
    if headers
        .get(header::IF_MODIFIED_SINCE)
        .and_then(|h| h.to_str().ok())
        .and_then(|s| DateTime::parse_from_rfc2822(s).ok())
        .is_some_and(|if_modified_since| media_file.last_modified <= if_modified_since)
    {
        debug!("Returning 304 Not Modified");
        return StatusCode::NOT_MODIFIED.into_response();
    }

    let path = PathBuf::from(state.config.folder_path.clone()).join(&media_file.filename);

    let file = match File::open(&path).await {
        Ok(file) => file,
        Err(e) => {
            tracing::error!("Failed to open file: {:?}", e);
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                axum::response::Json(json!({"error": "Failed to open file"})),
            )
                .into_response();
        }
    };

    let stream = ReaderStream::new(file);
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, media_file.mime_type),
            (header::LAST_MODIFIED, media_file.last_modified.to_rfc2822()),
            (header::CONTENT_LENGTH, media_file.size.to_string()),
            (header::CACHE_CONTROL, "public, max-age=259200".to_string()),
        ],
        Body::from_stream(stream),
    )
        .into_response()
}

async fn get_favorite_status(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let file_id = match Uuid::parse_str(&id) {
        Ok(id) => id,
        Err(e) => {
            tracing::error!("Failed to parse file id: {:?}", e);
            return (
                axum::http::StatusCode::BAD_REQUEST,
                axum::response::Json(json!({"error": "Invalid file id"})),
            )
                .into_response();
        }
    };
    let is_favorite = match state.repo.get_favorite_status(file_id).await {
        Ok(favorite) => favorite,
        Err(e) => {
            tracing::error!("Failed to get favorite status: {:?}", e);
            return (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                axum::response::Json(json!({"error": "Failed to get favorite status"})),
            )
                .into_response();
        }
    };
    axum::Json(json!(is_favorite)).into_response()
}

async fn toggle_favorite(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let file_id = match Uuid::parse_str(&id) {
        Ok(id) => id,
        Err(e) => {
            tracing::error!("Failed to parse file id: {:?}", e);
            return (
                axum::http::StatusCode::BAD_REQUEST,
                axum::response::Json(json!({"error": "Invalid file id"})),
            )
                .into_response();
        }
    };
    match state.repo.toggle_favorite_status(file_id).await {
        Ok(_) => (axum::http::StatusCode::NO_CONTENT).into_response(),
        Err(e) => {
            tracing::error!("Failed to toggle favorite status: {:?}", e);
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                axum::response::Json(json!({"error": "Failed to toggle favorite status"})),
            )
                .into_response()
        }
    }
}

async fn delete_files(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<DeleteFilesRequest>,
) -> impl IntoResponse {
    let ids = payload
        .ids
        .split(',')
        .map(Uuid::parse_str)
        .filter_map(|x| x.ok())
        .collect::<Vec<_>>();
    if ids.is_empty() {
        error!("Error parsing Ids in delete files");
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error": "Invalid IDs"})),
        )
            .into_response();
    }

    let settings = state.settings.get().await;
    let mode = match settings.delete_mode {
        crate::settings::DeleteMode::MoveToTrash => DeleteMode::MoveToTrash,
        crate::settings::DeleteMode::DeletePermanently => DeleteMode::DeletePermanently,
    };

    let command = ProcessorCommand::DeleteFiles {
        ids: ids.clone(),
        mode,
    };
    match state.command_tx.send(command.clone()) {
        Ok(_) => {
            info!("Sent {:?} command to processor", command)
        }
        Err(e) => {
            tracing::error!("Failed to send command to processor: {:?}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": "Failed to send command to processor"})),
            )
                .into_response();
        }
    };
    match state.repo.batch_delete_files(ids).await {
        Ok(_) => (StatusCode::OK).into_response(),
        Err(e) => {
            tracing::error!("Failed to delete files: {:?}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": "Failed to delete files"})),
            )
                .into_response()
        }
    }
}

async fn get_files(
    State(state): State<Arc<AppState>>,
    query: Option<Query<FileQuery>>,
) -> impl IntoResponse {
    let query = FilledFileQuery::from(query.unwrap_or_default().0);
    match state.repo.get_files(query).await {
        Ok((pagination, files)) => (
            StatusCode::OK,
            axum::response::Json(json!({ "files":  MediaFileDTOVec::from(files), "pagination": PaginationDTO::from(pagination) })),
        )
            .into_response(),
        Err(e) => {
            tracing::error!("Failed to get files: {:?}", e);
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                axum::response::Json(json!({"error": "Failed to get files"})),
            )
                .into_response()
        }
    }
}

async fn lock(State(state): State<Arc<AppState>>, Path(secret): Path<String>) -> impl IntoResponse {
    if secret != state.config.lock_secret {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": "Invalid secret"})),
        )
            .into_response();
    }
    match state.repo.lock_writes().await {
        Ok(_) => (StatusCode::NO_CONTENT).into_response(),
        Err(e) => {
            tracing::error!("Failed to lock writes: {:?}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": "Failed to lock writes"})),
            )
                .into_response()
        }
    }
}

async fn unlock(
    State(state): State<Arc<AppState>>,
    Path(secret): Path<String>,
) -> impl IntoResponse {
    if secret != state.config.lock_secret {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error": "Invalid secret"})),
        )
            .into_response();
    }
    match state.repo.unlock_writes().await {
        Ok(_) => (StatusCode::NO_CONTENT).into_response(),
        Err(e) => {
            tracing::error!("Failed to unlock writes: {:?}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": "Failed to unlock writes"})),
            )
                .into_response()
        }
    }
}

async fn get_settings(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let settings = state.settings.get().await;
    Json(settings).into_response()
}

async fn update_settings(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<PartialAppSettings>,
) -> impl IntoResponse {
    // The settings manager handles logging errors internally
    state.settings.update_partial(payload).await;
    let settings = state.settings.get().await;
    Json(settings).into_response()
}

async fn trigger_scan(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    // Send a scan command to the processor
    let scan_command = crate::ipc::ProcessorCommand::TriggerScan;

    match state.command_tx.send(scan_command) {
        Ok(_) => (
            StatusCode::ACCEPTED,
            Json(json!({"message": "Scan triggered"})),
        )
            .into_response(),
        Err(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error": "Failed to trigger scan"})),
        )
            .into_response(),
    }
}

async fn processor_status_stream(
    State(state): State<Arc<AppState>>,
) -> Sse<impl futures::Stream<Item = Result<Event, axum::Error>>> {
    let mut status_rx = state.status_rx.resubscribe();
    let is_processing = state.is_processing.clone();

    let stream = async_stream::stream! {
        while let Ok(status) = status_rx.recv().await {
            let event = match status {
                ProcessorStatus::ProcessingStarted => {
                    *is_processing.lock().await = true;
                    Event::default().event("processing_started").data("started")
                }
                ProcessorStatus::ProcessingFinished => {
                    *is_processing.lock().await = false;
                    Event::default().event("processing_finished").data("finished")
                }
                _ => continue,
            };

            yield Ok(event);
        }
    };

    Sse::new(stream).keep_alive(
        axum::response::sse::KeepAlive::new()
            .interval(std::time::Duration::from_secs(15))
            .text("keepalive"),
    )
}

// ===== Clustering Endpoints =====

async fn get_clusters_handler(
    State(state): State<Arc<AppState>>,
    Query(query): Query<super::ClusterQuery>,
) -> impl IntoResponse {
    let page = query.page.unwrap_or(1);
    let page_size = query.page_size.unwrap_or(20);

    match state.repo.get_clusters_paginated(page, page_size).await {
        Ok((pagination, clusters)) => {
            let response = super::ClustersResponse {
                clusters,
                pagination: PaginationDTO::from(pagination),
            };
            axum::Json(response).into_response()
        }
        Err(e) => {
            error!("Failed to get clusters: {:?}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                axum::Json(json!({"error": "Failed to get clusters"})),
            )
                .into_response()
        }
    }
}

async fn get_cluster_detail_handler(
    State(state): State<Arc<AppState>>,
    Path(cluster_id): Path<i64>,
) -> impl IntoResponse {
    match state.repo.get_cluster_images(cluster_id).await {
        Ok(images) => {
            let response = super::ClusterDetailResponse { cluster_id, images };
            axum::Json(response).into_response()
        }
        Err(e) => {
            error!("Failed to get cluster detail: {:?}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                axum::Json(json!({"error": "Failed to get cluster detail"})),
            )
                .into_response()
        }
    }
}

async fn resolve_cluster_handler(
    State(state): State<Arc<AppState>>,
    Path(cluster_id): Path<i64>,
    Json(payload): Json<super::ResolveClusterRequest>,
) -> impl IntoResponse {
    // Parse best shot ID
    let best_shot_id = match Uuid::parse_str(&payload.best_shot_id) {
        Ok(id) => id,
        Err(e) => {
            error!("Failed to parse best_shot_id: {:?}", e);
            return (
                StatusCode::BAD_REQUEST,
                axum::Json(json!({"error": "Invalid best_shot_id"})),
            )
                .into_response();
        }
    };

    // Mark the best shot
    if let Err(e) = state.repo.mark_best_shot(cluster_id, best_shot_id).await {
        error!("Failed to mark best shot: {:?}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            axum::Json(json!({"error": "Failed to mark best shot"})),
        )
            .into_response();
    }

    // Get media file IDs to delete
    let media_file_ids = match state.repo.resolve_cluster(cluster_id).await {
        Ok(ids) => ids,
        Err(e) => {
            error!("Failed to resolve cluster: {:?}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                axum::Json(json!({"error": "Failed to resolve cluster"})),
            )
                .into_response();
        }
    };

    if payload.delete_others && !media_file_ids.is_empty() {
        // Get delete mode from settings
        let settings = state.settings.get().await;
        let delete_mode = match settings.delete_mode {
            crate::config::DeleteMode::MoveToTrash => {
                crate::files::processor::DeleteMode::MoveToTrash
            }
            crate::config::DeleteMode::DeletePermanently => {
                crate::files::processor::DeleteMode::DeletePermanently
            }
        };

        // Send delete command to processor
        let ids_clone = media_file_ids.clone();
        if let Err(e) = state.command_tx.send(ProcessorCommand::DeleteFiles {
            ids: ids_clone,
            mode: delete_mode,
        }) {
            error!("Failed to send delete command: {:?}", e);
        }

        // Delete from database
        let deleted_count = media_file_ids.len();
        if let Err(e) = state.repo.batch_delete_files(media_file_ids).await {
            error!("Failed to delete files from database: {:?}", e);
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                axum::Json(json!({"error": "Failed to delete files"})),
            )
                .into_response();
        }

        (
            StatusCode::OK,
            axum::Json(json!({"success": true, "deleted_count": deleted_count})),
        )
            .into_response()
    } else {
        (
            StatusCode::OK,
            axum::Json(json!({"success": true, "deleted_count": 0})),
        )
            .into_response()
    }
}

async fn rebuild_clusters_handler(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    use crate::clustering::ClusterBuilder;

    let builder = ClusterBuilder::new(state.repo.clone());

    match builder.build_clusters().await {
        Ok(stats) => {
            info!(
                "Cluster rebuild complete: {} clusters, {} images clustered",
                stats.clusters_created, stats.images_clustered
            );
            axum::Json(json!({
                "success": true,
                "clusters_created": stats.clusters_created,
                "images_clustered": stats.images_clustered,
                "total_images": stats.total_images
            }))
            .into_response()
        }
        Err(e) => {
            error!("Failed to rebuild clusters: {:?}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                axum::Json(json!({"error": "Failed to rebuild clusters"})),
            )
                .into_response()
        }
    }
}
