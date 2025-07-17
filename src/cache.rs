use moka::future::Cache;
use serde::{de::DeserializeOwned, Serialize};
use uuid::Uuid;

use crate::{data::MediaType, server::FilledFileQuery};

#[derive(Clone, Debug)]
pub struct AppCache {
    pub cache: Cache<String, Vec<u8>>,
}

impl AppCache {
    pub fn new(cache_size_mb: u64) -> Self {
        let cache_size = cache_size_mb * 1024 * 1024;
        let cache = Cache::builder()
            .support_invalidation_closures()
            .weigher(|_key, value: &Vec<u8>| -> u32 { value.len() as u32 })
            .max_capacity(cache_size)
            .build();
        Self { cache }
    }
    pub async fn get<T>(&self, key: String) -> Option<T>
    where
        T: DeserializeOwned,
    {
        let raw = self.cache.get(key.as_str()).await;
        match raw {
            Some(raw) => {
                let res = bincode::deserialize::<T>(&raw);
                res.ok()
            }
            None => None,
        }
    }

    pub async fn set<T>(&self, key: String, value: &T)
    where
        T: Serialize,
    {
        let data = bincode::serialize(value);
        if let Ok(data) = data {
            self.cache.insert(key, data).await
        }
    }

    pub fn delete(&self, key: &str) {
        let key = String::from(key);
        let _ = self
            .cache
            .invalidate_entries_if(move |k, _| k.contains(&key));
    }
    pub fn invalidate_stats_cache(&self) {
        self.delete(STATS_CACHE_KEY);
    }

    pub fn invalidate_file_cache(&self, file_id: &uuid::Uuid) {
        self.delete(&get_file_cache_key(file_id));
    }

    pub fn invalidate_files_cache(&self) {
        self.delete(FILES_CACHE_PREFIX);
    }

    pub fn invalidate_img_vid_thumb_cache(&self, media_file_id: &Uuid, media_type: &MediaType) {
        self.delete(&get_img_vid_thumb_cache_key(*media_file_id, media_type));
    }

    pub fn invalidate_favorite_status_cache(&self, file_id: &Uuid) {
        self.delete(&get_favorite_status_cache_key(file_id));
    }
}

pub(crate) const STATS_CACHE_KEY: &str = "stats";
const FILE_CACHE_PREFIX: &str = "file:";
const FILES_CACHE_PREFIX: &str = "files:";
const IMG_VID_THUMB_CACHE_PREFIX: &str = "img_vid_thumb:";
const FAVORITE_STATUS_CACHE_PREFIX: &str = "favorite_status:";

// New helper methods for cache keys
pub fn get_img_vid_thumb_cache_key(media_file_id: Uuid, media_type: &MediaType) -> String {
    format!(
        "{}{:?}:{}",
        IMG_VID_THUMB_CACHE_PREFIX, media_type, media_file_id
    )
}

pub fn get_favorite_status_cache_key(file_id: &Uuid) -> String {
    format!("{}{}", FAVORITE_STATUS_CACHE_PREFIX, file_id)
}
// Helper methods for cache keys
pub fn get_file_cache_key(id: &uuid::Uuid) -> String {
    format!("{}{}", FILE_CACHE_PREFIX, id)
}

pub fn get_files_cache_key(query: &FilledFileQuery) -> String {
    format!(
        "{}{}:{}:{}:{}:{}:{}",
        FILES_CACHE_PREFIX,
        query.file_type,
        query.page,
        query.page_size,
        query.order,
        query.direction,
        if query.order == "random" {
            query.seed.unwrap_or(0).to_string()
        } else {
            String::new()
        }
    )
}
