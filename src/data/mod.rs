pub mod backup_manager;
pub mod repository;

use std::fmt::Display;

use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::{
    prelude::{FromRow, Type},
    Database, Sqlite,
};

#[derive(Clone, Serialize, Deserialize, FromRow)]
pub struct UnfilledMediaFile {
    pub id: uuid::Uuid,
    pub hash: String,
    pub created_at: DateTime<Utc>,
    pub filename: String,
    pub size: i64,
    pub media_type: MediaType,
    pub last_modified: DateTime<Utc>,
    #[sqlx(skip)]
    pub media: Option<Media>,
    pub mime_type: Option<String>,
    pub is_favorite: bool,
}
impl From<FilledMediaFile> for UnfilledMediaFile {
    fn from(filled: FilledMediaFile) -> Self {
        Self {
            id: filled.id,
            hash: filled.hash,
            created_at: filled.created_at,
            filename: filled.filename,
            size: filled.size,
            media_type: filled.media_type,
            last_modified: filled.last_modified,
            media: Some(filled.media),
            mime_type: Some(filled.mime_type),
            is_favorite: filled.is_favorite,
        }
    }
}
impl From<MediaFile> for UnfilledMediaFile {
    fn from(media_file: MediaFile) -> Self {
        match media_file {
            MediaFile::Unfilled(unfilled) => unfilled,
            MediaFile::Filled(filled) => Self {
                id: filled.id,
                hash: filled.hash,
                created_at: filled.created_at,
                filename: filled.filename,
                size: filled.size,
                media_type: filled.media_type,
                last_modified: filled.last_modified,
                media: Some(filled.media),
                mime_type: Some(filled.mime_type),
                is_favorite: filled.is_favorite,
            },
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct FilledMediaFile {
    pub id: uuid::Uuid,
    pub hash: String,
    pub created_at: DateTime<Utc>,
    pub filename: String,
    pub size: i64,
    pub media_type: MediaType,
    pub last_modified: DateTime<Utc>,
    pub media: Media,
    pub mime_type: String,
    pub is_favorite: bool,
}

#[derive(Serialize, Deserialize)]
pub enum MediaFile {
    Unfilled(UnfilledMediaFile),
    Filled(FilledMediaFile),
}

impl MediaFile {
    pub fn get_id(&self) -> uuid::Uuid {
        match self {
            MediaFile::Unfilled(unfilled) => unfilled.id,
            MediaFile::Filled(filled) => filled.id,
        }
    }
}

impl TryFrom<UnfilledMediaFile> for FilledMediaFile {
    type Error = anyhow::Error;
    fn try_from(value: UnfilledMediaFile) -> Result<Self> {
        match (value.media, value.mime_type) {
            (Some(media), Some(mime_type)) => Ok(Self {
                id: value.id,
                hash: value.hash,
                created_at: value.created_at,
                filename: value.filename,
                size: value.size,
                media_type: value.media_type,
                last_modified: value.last_modified,
                media,
                mime_type,
                is_favorite: value.is_favorite,
            }),
            _ => Err(anyhow::anyhow!("Media is not filled")),
        }
    }
}

impl TryFrom<Result<UnfilledMediaFile, anyhow::Error>> for FilledMediaFile {
    type Error = anyhow::Error;
    fn try_from(value: Result<UnfilledMediaFile, anyhow::Error>) -> Result<Self> {
        match value {
            Ok(media_file) => Self::try_from(media_file),
            Err(e) => Err(e),
        }
    }
}

impl TryFrom<MediaFile> for FilledMediaFile {
    type Error = anyhow::Error;
    fn try_from(value: MediaFile) -> Result<Self> {
        match value {
            MediaFile::Filled(filled) => Ok(filled),
            _ => Err(anyhow::anyhow!("Media is not filled")),
        }
    }
}

impl UnfilledMediaFile {
    pub fn with_image(mut self, image: Image, mime_type: String) -> FilledMediaFile {
        self.media = Some(Media::Image(image));
        self.mime_type = Some(mime_type);
        self.try_into().unwrap()
    }

    pub fn with_video(mut self, video: Video, mime_type: String) -> FilledMediaFile {
        self.media = Some(Media::Video(video));
        self.mime_type = Some(mime_type);
        self.try_into().unwrap()
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub enum MediaType {
    Image,
    Video,
}
impl Type<Sqlite> for MediaType {
    fn type_info() -> <Sqlite as Database>::TypeInfo {
        <String as Type<Sqlite>>::type_info()
    }
}

impl<'r> sqlx::Decode<'r, Sqlite> for MediaType {
    fn decode(value: sqlx::sqlite::SqliteValueRef<'r>) -> Result<Self, sqlx::error::BoxDynError> {
        let value = <String as sqlx::Decode<Sqlite>>::decode(value)?;
        MediaType::try_from(value).map_err(Into::into)
    }
}

impl sqlx::Encode<'_, Sqlite> for MediaType {
    fn encode_by_ref(
        &self,
        args: &mut Vec<sqlx::sqlite::SqliteArgumentValue<'_>>,
    ) -> std::result::Result<
        sqlx::encode::IsNull,
        std::boxed::Box<(dyn std::error::Error + std::marker::Send + std::marker::Sync + 'static)>,
    > {
        args.push(sqlx::sqlite::SqliteArgumentValue::Text(
            self.to_string().into(),
        ));
        Ok(sqlx::encode::IsNull::No)
    }
}

impl std::fmt::Display for MediaType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MediaType::Image => write!(f, "Image"),
            MediaType::Video => write!(f, "Video"),
        }
    }
}

impl TryFrom<String> for MediaType {
    type Error = anyhow::Error;
    fn try_from(value: String) -> Result<Self> {
        match value.as_str() {
            "Image" | "image" => Ok(MediaType::Image),
            "Video" | "video" => Ok(MediaType::Video),
            _ => Err(anyhow::anyhow!("Invalid media type")),
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
pub enum Media {
    Image(Image),
    Video(Video),
}

impl Media {
    pub fn as_image(&self) -> Option<Image> {
        match self {
            Media::Image(image) => Some(image.clone()),
            _ => None,
        }
    }
    pub fn as_video(&self) -> Option<Video> {
        match self {
            Media::Video(video) => Some(video.clone()),
            _ => None,
        }
    }
}

#[derive(Clone, Serialize, Deserialize, FromRow, Default)]
pub struct Image {
    pub id: uuid::Uuid,
    pub width: u32,
    pub height: u32,
    #[sqlx(skip)]
    pub thumbnail: Thumbnail,
}

impl Image {
    pub fn new(id: uuid::Uuid, width: u32, height: u32, thumbnail: Thumbnail) -> Self {
        Self {
            id,
            width,
            height,
            thumbnail,
        }
    }
}

#[derive(Clone, Serialize, Deserialize, FromRow, Default)]
pub struct Video {
    pub id: uuid::Uuid,
    pub width: u32,
    pub height: u32,
    pub duration_ms: u64,
    #[sqlx(skip)]
    pub thumbnail: Thumbnail,
}

#[derive(Clone, Serialize, Deserialize, FromRow, Default)]
pub struct Thumbnail {
    pub id: uuid::Uuid,
    pub width: u32,
    pub height: u32,
    pub data: Vec<u8>,
}

impl Thumbnail {
    pub fn new(id: uuid::Uuid, width: u32, height: u32, data: Vec<u8>) -> Self {
        Self {
            id,
            width,
            height,
            data,
        }
    }
}

impl Video {
    pub fn new(
        id: uuid::Uuid,
        width: u32,
        height: u32,
        duration_ms: u64,
        thumbnail: Thumbnail,
    ) -> Self {
        Self {
            id,
            width,
            height,
            duration_ms,
            thumbnail,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, FromRow)]
pub struct Stats {
    pub count: u32,
    pub images: u32,
    pub videos: u32,
    pub favorites: u32,
}

#[derive(Serialize, Deserialize)]
pub struct Pagination {
    pub count: u32,
    pub current_page: u32,
    pub total_pages: u32,
    pub prev_page: Option<u32>,
    pub next_page: Option<u32>,
}

#[derive(Clone)]
pub enum FindBy {
    Id(uuid::Uuid),
    Hash(String),
    Filename(String),
}

impl Display for FindBy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FindBy::Id(id) => write!(f, "id:{}", id),
            FindBy::Hash(hash) => write!(f, "hash:{}", hash),
            FindBy::Filename(filename) => write!(f, "filename:{}", filename),
        }
    }
}
