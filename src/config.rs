use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::{fmt::Debug, path::PathBuf};

pub const DEFAULT_PORT: u16 = 8281;
pub fn get_default_port() -> u16 {
    DEFAULT_PORT
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
    pub refresh_interval: u16,
    #[serde(rename = "cacheSizeMB")]
    pub cache_size_mb: u32,
    #[serde(default = "get_default_port")]
    pub port: u16,
    pub log_level: crate::logging::LogLevel,
    pub lock_secret: String,
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
            refresh_interval: 3600,
            cache_size_mb: 100,
            log_level: crate::logging::LogLevel::Info,
            backup_folder_path: String::new(),
            lock_secret: String::new(),
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
}
