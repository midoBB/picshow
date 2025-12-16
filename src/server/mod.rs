use base64::{prelude::BASE64_STANDARD, Engine as _};
use chrono::{DateTime, Utc};
use rust_embed::RustEmbed;
use serde::Serialize;
use std::{fmt::Display, time::Duration};
use tracing::{debug, error};

use axum::{
    http::{self, header, HeaderName, StatusCode, Uri},
    response::IntoResponse,
};
use tower::{layer::util::Stack, ServiceBuilder};
use tower_http::{
    compression::CompressionLayer,
    cors::{self, CorsLayer},
    request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer},
    timeout::TimeoutLayer,
};

use crate::data::{FilledMediaFile, Media, MediaType, Pagination, Stats};

pub mod api;
pub mod first_run;

type Middlewares = ServiceBuilder<
    Stack<
        CompressionLayer,
        Stack<
            PropagateRequestIdLayer,
            Stack<
                SetRequestIdLayer<MakeRequestUuid>,
                Stack<TimeoutLayer, Stack<CorsLayer, tower::layer::util::Identity>>,
            >,
        >,
    >,
>;
pub fn middlewares() -> Middlewares {
    ServiceBuilder::new()
        .layer(
            CorsLayer::new()
                .allow_methods([http::Method::GET, http::Method::POST, http::Method::OPTIONS])
                .allow_origin(cors::Any),
        )
        .layer({
            TimeoutLayer::with_status_code(StatusCode::REQUEST_TIMEOUT, Duration::from_secs(30))
        })
        .layer(SetRequestIdLayer::new(
            HeaderName::from_static("x-request-id"),
            MakeRequestUuid,
        ))
        .layer(PropagateRequestIdLayer::new(HeaderName::from_static(
            "x-request-id",
        )))
        .layer(CompressionLayer::new())
}

fn serve_static_file<T>(uri: &Uri) -> impl IntoResponse
where
    T: RustEmbed,
{
    let uri_path = uri.path().to_string();
    let path = match uri_path
        .strip_prefix('/')
        .ok_or_else(|| anyhow::anyhow!("Invalid path"))
        .inspect_err(|e| error!("Invalid path: {}", e))
    {
        Ok(path) => path,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                [(header::CONTENT_TYPE, "text/plain")],
                "400 Bad Request",
            )
                .into_response()
        }
    };
    debug!("Serving static file: {}", path);
    let asset = match path {
        "index.html" | "" => T::get("index.html"),
        _ => T::get(path),
    };
    match asset {
        Some(asset) => {
            let actual_path = if path.is_empty() { "index.html" } else { path };
            let mime = mime_guess::from_path(actual_path).first_or_octet_stream();
            (
                StatusCode::OK,
                [(header::CONTENT_TYPE, mime.as_ref())],
                asset.data,
            )
                .into_response()
        }
        None => (
            StatusCode::NOT_FOUND,
            [(header::CONTENT_TYPE, "text/plain")],
            "404 Not Found",
        )
            .into_response(),
    }
}

#[derive(Serialize)]
pub struct PaginationDTO {
    pub total_records: u32,
    pub current_page: u32,
    pub total_pages: u32,
    pub prev_page: Option<u32>,
    pub next_page: Option<u32>,
}

impl From<Pagination> for PaginationDTO {
    fn from(pagination: Pagination) -> Self {
        Self {
            total_records: pagination.count,
            current_page: pagination.current_page,
            total_pages: pagination.total_pages,
            prev_page: pagination.prev_page,
            next_page: pagination.next_page,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
pub enum MediaTypeDTO {
    Image,
    Video,
}

impl From<MediaType> for MediaTypeDTO {
    fn from(media_type: MediaType) -> Self {
        match media_type {
            MediaType::Image => MediaTypeDTO::Image,
            MediaType::Video => MediaTypeDTO::Video,
        }
    }
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "PascalCase")]
pub struct MediaDTO {
    pub width: u32,
    pub height: u32,
    pub thumbnail_width: u32,
    pub thumbnail_height: u32,
    #[serde(skip)]
    pub thumbnail_base64: String,
    pub length: Option<u32>,
}

fn get_b64_thumbnail(data: Vec<u8>) -> String {
    format!("data:image/jpeg;base64,{}", BASE64_STANDARD.encode(data))
}

impl From<Media> for MediaDTO {
    fn from(media: Media) -> Self {
        match media {
            Media::Image(image) => MediaDTO {
                width: image.width,
                height: image.height,
                thumbnail_width: image.thumbnail.width,
                thumbnail_height: image.thumbnail.height,
                thumbnail_base64: get_b64_thumbnail(image.thumbnail.data),
                length: None,
            },
            Media::Video(video) => MediaDTO {
                width: video.width,
                height: video.height,
                thumbnail_width: video.thumbnail.width,
                thumbnail_height: video.thumbnail.height,
                thumbnail_base64: get_b64_thumbnail(video.thumbnail.data),
                length: Some(video.duration_ms as u32),
            },
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct MediaFileDTO {
    pub id: String,
    pub hash: String,
    pub created_at: DateTime<Utc>,
    pub filename: String,
    pub size: i64,
    pub media_type: MediaTypeDTO,
    pub mime_type: String,
    pub is_favorite: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<MediaDTO>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub video: Option<MediaDTO>,
}

impl From<FilledMediaFile> for MediaFileDTO {
    fn from(media_file: FilledMediaFile) -> Self {
        let media = match media_file.media {
            Media::Image(image) => Some(MediaDTO::from(Media::Image(image))),
            Media::Video(video) => Some(MediaDTO::from(Media::Video(video))),
        };
        Self {
            id: media_file.id.to_string(),
            hash: media_file.hash,
            created_at: media_file.created_at,
            filename: media_file.filename,
            size: media_file.size,
            media_type: MediaTypeDTO::from(media_file.media_type.clone()),
            mime_type: media_file.mime_type,
            is_favorite: media_file.is_favorite,
            image: media
                .clone()
                .filter(|_| media_file.media_type == MediaType::Image),
            video: media
                .clone()
                .filter(|_| media_file.media_type == MediaType::Video),
        }
    }
}
#[derive(Serialize)]
pub struct MediaFileDTOVec(Vec<MediaFileDTO>);

impl From<Vec<FilledMediaFile>> for MediaFileDTOVec {
    fn from(media_files_vec: Vec<FilledMediaFile>) -> Self {
        let res = media_files_vec
            .into_iter()
            .map(MediaFileDTO::from)
            .collect::<Vec<MediaFileDTO>>();
        MediaFileDTOVec(res)
    }
}

#[derive(Serialize)]
pub struct StatsDTO {
    count: u32,
    video_count: u32,
    image_count: u32,
    favorite_count: u32,
}

impl From<Stats> for StatsDTO {
    fn from(stats: Stats) -> Self {
        Self {
            count: stats.count,
            video_count: stats.videos,
            image_count: stats.images,
            favorite_count: stats.favorites,
        }
    }
}

#[derive(serde::Deserialize)]
pub struct FileQuery {
    pub page: Option<u32>,
    pub page_size: Option<u32>,
    pub order: Option<String>,
    pub direction: Option<String>,
    pub seed: Option<u64>,
    #[serde(rename(deserialize = "type"))]
    pub file_type: Option<String>,
}
impl Default for FileQuery {
    fn default() -> Self {
        Self {
            page: Some(1),
            page_size: Some(10),
            order: Some("created_at".to_string()),
            direction: Some("desc".to_string()),
            seed: None,
            file_type: Some("all".to_string()),
        }
    }
}

#[derive(PartialEq, Eq)]
pub enum FileQueryType {
    Video,
    Image,
    Favorite,
    All,
}

impl From<String> for FileQueryType {
    fn from(value: String) -> Self {
        match value.as_str() {
            "image" => FileQueryType::Image,
            "video" => FileQueryType::Video,
            "favorite" => FileQueryType::Favorite,
            _ => FileQueryType::All,
        }
    }
}

impl Display for FileQueryType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FileQueryType::Video => write!(f, "image"),
            FileQueryType::Image => write!(f, "video"),
            FileQueryType::Favorite => write!(f, "favorite"),
            FileQueryType::All => write!(f, "all"),
        }
    }
}

pub struct FilledFileQuery {
    pub page: u32,
    pub page_size: u32,
    pub order: String,
    pub direction: String,
    pub seed: Option<u64>,
    pub file_type: FileQueryType,
}

impl From<FileQuery> for FilledFileQuery {
    fn from(query: FileQuery) -> Self {
        Self {
            page: query.page.unwrap_or(1),
            page_size: query.page_size.unwrap_or(10),
            order: query.order.unwrap_or("created_at".to_string()),
            direction: query.direction.unwrap_or("desc".to_string()),
            seed: query.seed,
            file_type: FileQueryType::from(query.file_type.unwrap_or(String::from("all"))),
        }
    }
}

#[derive(serde::Deserialize)]
struct DeleteFilesRequest {
    ids: String,
}
