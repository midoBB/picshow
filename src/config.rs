use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::{fmt::Debug, path::PathBuf, sync::Arc};
use tokio::sync::{broadcast, RwLock};

pub const DEFAULT_PORT: u16 = 8281;
pub fn get_default_port() -> u16 {
    DEFAULT_PORT
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
#[derive(Default)]
pub enum DuplicateHandling {
    #[default]
    MoveToFolder,
    Delete,
    Skip,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
#[derive(Default)]
pub enum DeleteMode {
    #[default]
    MoveToTrash,
    DeletePermanently,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppConfig {
    pub folder_path: String,
    pub db_path: String,
    pub backup_folder_path: String,
    pub hash_size: u32,
    pub concurrency: u32,
    pub max_thumbnail_size: u32,
    #[serde(rename = "cacheSizeMB")]
    pub cache_size_mb: u32,
    #[serde(default = "get_default_port")]
    pub port: u16,
    pub log_level: crate::logging::LogLevel,
    pub lock_secret: String,
    // Settings fields
    #[serde(default)]
    pub duplicate_handling: DuplicateHandling,
    #[serde(default)]
    pub delete_mode: DeleteMode,
    #[serde(default = "default_auto_refresh_enabled")]
    pub auto_refresh_enabled: bool,
    #[serde(default = "default_auto_refresh_duration")]
    pub auto_refresh_duration: u16,
}

fn default_auto_refresh_enabled() -> bool {
    true
}

fn default_auto_refresh_duration() -> u16 {
    1 // Default: 1 hour
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            folder_path: String::new(),
            db_path: String::new(),
            concurrency: 4,
            hash_size: 8,
            max_thumbnail_size: 300,
            port: DEFAULT_PORT,
            cache_size_mb: 100,
            log_level: crate::logging::LogLevel::Info,
            backup_folder_path: String::new(),
            lock_secret: String::new(),
            duplicate_handling: DuplicateHandling::default(),
            delete_mode: DeleteMode::default(),
            auto_refresh_enabled: default_auto_refresh_enabled(),
            auto_refresh_duration: default_auto_refresh_duration(),
        }
    }
}

impl AppConfig {
    pub fn config_exists() -> bool {
        let config_dir = dirs::config_dir().unwrap_or_else(|| PathBuf::from("."));
        let config_path = config_dir.join("picshow").join("config.json");
        config_path.exists()
    }
    pub fn try_load() -> Result<Self> {
        let config_dir = dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("picshow");
        let config_path = config_dir.join("config.json");
        if !config_path.exists() {
            return Err(anyhow::anyhow!("Configuration file does not exist"));
        }
        let config_str = std::fs::read_to_string(config_path)
            .map_err(|e| anyhow::anyhow!("Error reading configuration file: {}", e))?;
        serde_json::from_str(&config_str)
            .map_err(|e| anyhow::anyhow!("Error parsing configuration file: {}", e))
    }

    pub fn save(&self) -> Result<()> {
        let config_dir = dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("picshow");

        std::fs::create_dir_all(&config_dir).map_err(|e| anyhow::anyhow!(e.to_string()))?;

        let config_path = config_dir.join("config.json");
        let config_str =
            serde_json::ser::to_string(self).map_err(|e| anyhow::anyhow!(e.to_string()))?;
        std::fs::write(config_path, config_str).map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(())
    }

    pub fn with_port(mut self, port: Option<u16>) -> Self {
        self.port = port.unwrap_or(self.port);
        self
    }

    pub fn get_settings(&self) -> AppSettings {
        AppSettings {
            duplicate_handling: self.duplicate_handling.clone(),
            delete_mode: self.delete_mode.clone(),
            auto_refresh_enabled: self.auto_refresh_enabled,
            auto_refresh_duration: self.auto_refresh_duration,
        }
    }

    pub fn update_settings(&mut self, update: PartialAppSettings) {
        if let Some(duplicate_handling) = update.duplicate_handling {
            self.duplicate_handling = duplicate_handling;
        }
        if let Some(delete_mode) = update.delete_mode {
            self.delete_mode = delete_mode;
        }
        if let Some(auto_refresh_enabled) = update.auto_refresh_enabled {
            self.auto_refresh_enabled = auto_refresh_enabled;
        }
        if let Some(auto_refresh_duration) = update.auto_refresh_duration {
            // Validate: 1 hour minimum, 168 hours (7 days) maximum
            self.auto_refresh_duration = auto_refresh_duration.clamp(1, 168);
        }
    }
}

// Type alias for backward compatibility with frontend
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    pub duplicate_handling: DuplicateHandling,
    pub delete_mode: DeleteMode,
    pub auto_refresh_enabled: bool,
    pub auto_refresh_duration: u16,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PartialAppSettings {
    pub duplicate_handling: Option<DuplicateHandling>,
    pub delete_mode: Option<DeleteMode>,
    pub auto_refresh_enabled: Option<bool>,
    pub auto_refresh_duration: Option<u16>,
}

// Broadcast channel message for config changes
#[derive(Debug, Clone)]
pub struct ConfigChange {
    pub config: AppConfig,
}

#[derive(Clone)]
pub struct ConfigManager {
    config: Arc<RwLock<AppConfig>>,
    change_tx: broadcast::Sender<ConfigChange>,
}

impl ConfigManager {
    pub async fn new(config: AppConfig) -> Result<Self> {
        let (change_tx, _) = broadcast::channel(100);
        let config = Arc::new(RwLock::new(config));

        Ok(Self { config, change_tx })
    }

    pub async fn get(&self) -> AppConfig {
        self.config.read().await.clone()
    }

    pub async fn get_settings(&self) -> AppSettings {
        self.config.read().await.get_settings()
    }

    pub async fn update_settings(&self, update: PartialAppSettings) -> Result<AppConfig> {
        let mut config = self.config.write().await;
        config.update_settings(update);

        // Save to disk
        config.save()?;

        // Broadcast change
        let config_clone = config.clone();
        if let Err(e) = self.change_tx.send(ConfigChange {
            config: config_clone.clone(),
        }) {
            tracing::warn!("Failed to broadcast config change: {}", e);
        }

        Ok(config_clone)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<ConfigChange> {
        self.change_tx.subscribe()
    }
}
