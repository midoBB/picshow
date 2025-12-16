// Re-export types from config for backward compatibility
pub use crate::config::{
    AppSettings, ConfigManager, DeleteMode, DuplicateHandling, PartialAppSettings,
};

// Wrapper for backward compatibility with existing code
#[derive(Clone)]
pub struct SettingsManager {
    config_manager: ConfigManager,
}

impl SettingsManager {
    pub async fn new(config_manager: ConfigManager) -> Self {
        Self { config_manager }
    }

    pub async fn get(&self) -> AppSettings {
        self.config_manager.get_settings().await
    }

    pub async fn update(&self, settings: AppSettings) {
        let update = PartialAppSettings {
            duplicate_handling: Some(settings.duplicate_handling),
            delete_mode: Some(settings.delete_mode),
            auto_refresh_enabled: Some(settings.auto_refresh_enabled),
            auto_refresh_duration: Some(settings.auto_refresh_duration),
        };

        if let Err(e) = self.config_manager.update_settings(update).await {
            tracing::error!("Failed to update settings: {}", e);
        }
    }

    pub async fn update_partial(&self, update: PartialAppSettings) {
        if let Err(e) = self.config_manager.update_settings(update).await {
            tracing::error!("Failed to update settings: {}", e);
        }
    }

    pub fn subscribe(&self) -> tokio::sync::broadcast::Receiver<crate::config::ConfigChange> {
        self.config_manager.subscribe()
    }
}
