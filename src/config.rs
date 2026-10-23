use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::{fmt::Debug, path::PathBuf, sync::Arc};
use tokio::sync::{broadcast, RwLock};

pub const DEFAULT_PORT: u16 = 8281;

/// Bump when an upgrade must change values in existing config files, and add
/// the step to `AppConfig::migrate`. Each step runs once per install, so values
/// the user sets afterwards are never overwritten.
pub const CONFIG_VERSION: u32 = 1;
pub fn get_default_port() -> u16 {
    DEFAULT_PORT
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
#[derive(Default)]
pub enum ClusterAlgorithm {
    Single,
    Complete,
    Dbscan,
    // K-means was removed; configs that still name it get HDBSCAN.
    #[serde(alias = "kmeans")]
    #[default]
    Hdbscan,
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
    /// Missing in files written before versioning, which therefore start at 0.
    #[serde(default)]
    pub config_version: u32,
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
    // Cluster config (not exposed in frontend settings — edit config.json directly)
    #[serde(default = "default_cluster_algorithm")]
    pub cluster_algorithm: ClusterAlgorithm,
    #[serde(default = "default_cluster_threshold")]
    pub cluster_threshold: u32,
    #[serde(default = "default_cluster_dbscan_min_pts")]
    pub cluster_dbscan_min_pts: usize,
    #[serde(default = "default_cluster_threshold_256")]
    pub cluster_threshold_256: u32,
    #[serde(default = "default_cluster_color_threshold")]
    pub cluster_color_threshold: f64,
    #[serde(default = "default_cluster_color_tight")]
    pub cluster_color_tight: f64,
    #[serde(default = "default_cluster_rescue_factor")]
    pub cluster_rescue_factor: f64,
    #[serde(default = "default_cluster_hnsw_k")]
    pub cluster_hnsw_k: usize,
    #[serde(default = "default_cluster_hdbscan_min_cluster_size")]
    pub cluster_hdbscan_min_cluster_size: usize,
    #[serde(default = "default_cluster_hdbscan_min_samples")]
    pub cluster_hdbscan_min_samples: usize,
    // Scheduled backup config (not exposed in frontend settings — edit config.json directly)
    #[serde(default = "default_backup_scheduled_enabled")]
    pub backup_scheduled_enabled: bool,
    #[serde(default = "default_backup_interval_hours")]
    pub backup_interval_hours: u16,
    #[serde(default = "default_backup_retention_count")]
    pub backup_retention_count: usize,
}

fn default_auto_refresh_enabled() -> bool {
    true
}

fn default_auto_refresh_duration() -> u16 {
    1 // Default: 1 hour
}

fn default_cluster_algorithm() -> ClusterAlgorithm {
    ClusterAlgorithm::Hdbscan
}

fn default_cluster_threshold() -> u32 {
    10
}

fn default_cluster_dbscan_min_pts() -> usize {
    3
}

fn default_cluster_threshold_256() -> u32 {
    48
}

fn default_cluster_color_threshold() -> f64 {
    0.35
}

fn default_cluster_color_tight() -> f64 {
    0.12
}

fn default_cluster_rescue_factor() -> f64 {
    1.5
}

fn default_cluster_hnsw_k() -> usize {
    10
}

fn default_cluster_hdbscan_min_cluster_size() -> usize {
    2
}

fn default_cluster_hdbscan_min_samples() -> usize {
    2
}

fn default_backup_scheduled_enabled() -> bool {
    true
}

fn default_backup_interval_hours() -> u16 {
    24
}

fn default_backup_retention_count() -> usize {
    7
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            config_version: CONFIG_VERSION,
            folder_path: String::new(),
            db_path: Self::get_default_db_path(),
            concurrency: 4,
            hash_size: 8,
            max_thumbnail_size: 300,
            port: DEFAULT_PORT,
            cache_size_mb: 100,
            log_level: crate::logging::LogLevel::Info,
            backup_folder_path: Self::get_default_backup_path(),
            lock_secret: String::new(),
            duplicate_handling: DuplicateHandling::default(),
            delete_mode: DeleteMode::default(),
            auto_refresh_enabled: default_auto_refresh_enabled(),
            auto_refresh_duration: default_auto_refresh_duration(),
            cluster_algorithm: default_cluster_algorithm(),
            cluster_threshold: default_cluster_threshold(),
            cluster_dbscan_min_pts: default_cluster_dbscan_min_pts(),
            cluster_threshold_256: default_cluster_threshold_256(),
            cluster_color_threshold: default_cluster_color_threshold(),
            cluster_color_tight: default_cluster_color_tight(),
            cluster_rescue_factor: default_cluster_rescue_factor(),
            cluster_hnsw_k: default_cluster_hnsw_k(),
            cluster_hdbscan_min_cluster_size: default_cluster_hdbscan_min_cluster_size(),
            cluster_hdbscan_min_samples: default_cluster_hdbscan_min_samples(),
            backup_scheduled_enabled: default_backup_scheduled_enabled(),
            backup_interval_hours: default_backup_interval_hours(),
            backup_retention_count: default_backup_retention_count(),
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
        let config_str = std::fs::read_to_string(&config_path)
            .map_err(|e| anyhow::anyhow!("Error reading configuration file: {}", e))?;

        let needs_rewrite = {
            let raw: serde_json::Value = serde_json::from_str(&config_str)?;
            raw.get("clusterAlgorithm").is_none()
                || raw.get("clusterThreshold").is_none()
                || raw.get("clusterDbscanMinPts").is_none()
                || raw.get("clusterKmeansK").is_some()
                || raw.get("clusterThreshold256").is_none()
                || raw.get("clusterColorThreshold").is_none()
                || raw.get("clusterColorTight").is_none()
                || raw.get("clusterRescueFactor").is_none()
                || raw.get("clusterHnswK").is_none()
                || raw.get("clusterHdbscanMinClusterSize").is_none()
                || raw.get("clusterHdbscanMinSamples").is_none()
                || raw.get("backupScheduledEnabled").is_none()
                || raw.get("backupIntervalHours").is_none()
                || raw.get("backupRetentionCount").is_none()
        };

        let mut config: Self = serde_json::from_str(&config_str)
            .map_err(|e| anyhow::anyhow!("Error parsing configuration file: {}", e))?;

        let from_version = config.config_version;
        if config.migrate() {
            let backup_path = config_dir.join(format!("config.json.v{}.bak", from_version));
            std::fs::write(&backup_path, &config_str)
                .map_err(|e| anyhow::anyhow!("Error backing up configuration file: {}", e))?;
            tracing::info!(
                "Migrated config from version {} to {} (previous file saved to {})",
                from_version,
                config.config_version,
                backup_path.display()
            );
        }

        if needs_rewrite || config.config_version != from_version {
            tracing::info!("Adding cluster config defaults to existing config file");
            config.save()?;
        }

        Ok(config)
    }

    /// Apply each pending upgrade step in order. Returns whether anything ran.
    fn migrate(&mut self) -> bool {
        let from_version = self.config_version;
        if from_version < 1 {
            // v1: K-means removed; HDBSCAN with the 256-bit hash becomes the default.
            self.cluster_algorithm = ClusterAlgorithm::Hdbscan;
            self.cluster_threshold_256 = 48;
        }
        self.config_version = self.config_version.max(CONFIG_VERSION);
        self.config_version != from_version
    }

    fn get_default_db_path() -> String {
        dirs::data_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("picshow")
            .join("picshow.db")
            .to_string_lossy()
            .to_string()
    }

    fn get_default_backup_path() -> String {
        dirs::data_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("picshow")
            .join("picshow.bak")
            .to_string_lossy()
            .to_string()
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A config file as written before versioning existed.
    fn unversioned(algorithm: &str) -> serde_json::Value {
        let mut raw = serde_json::to_value(AppConfig::default()).unwrap();
        let obj = raw.as_object_mut().unwrap();
        obj.remove("configVersion");
        obj.insert("clusterAlgorithm".into(), algorithm.into());
        obj.insert("clusterThreshold256".into(), 40.into());
        raw
    }

    #[test]
    fn legacy_kmeans_config_loads_as_hdbscan() {
        let mut raw = unversioned("kmeans");
        raw["clusterKmeansK"] = 10.into();
        let config: AppConfig = serde_json::from_value(raw).unwrap();
        assert_eq!(config.cluster_algorithm, ClusterAlgorithm::Hdbscan);
    }

    #[test]
    fn upgrade_switches_existing_installs_once() {
        let mut config: AppConfig = serde_json::from_value(unversioned("complete")).unwrap();
        assert_eq!(config.config_version, 0);
        assert!(config.migrate());
        assert_eq!(config.cluster_algorithm, ClusterAlgorithm::Hdbscan);
        assert_eq!(config.cluster_threshold_256, 48);
        assert_eq!(config.config_version, CONFIG_VERSION);

        // A later user choice survives the next start.
        config.cluster_algorithm = ClusterAlgorithm::Single;
        config.cluster_threshold_256 = 36;
        let mut reloaded: AppConfig =
            serde_json::from_value(serde_json::to_value(&config).unwrap()).unwrap();
        assert!(!reloaded.migrate());
        assert_eq!(reloaded.cluster_algorithm, ClusterAlgorithm::Single);
        assert_eq!(reloaded.cluster_threshold_256, 36);
    }

    #[test]
    fn new_installs_start_current() {
        let mut config = AppConfig::default();
        assert_eq!(config.config_version, CONFIG_VERSION);
        assert_eq!(config.cluster_algorithm, ClusterAlgorithm::Hdbscan);
        assert_eq!(config.cluster_threshold_256, 48);
        assert!(!config.migrate());
    }
}
