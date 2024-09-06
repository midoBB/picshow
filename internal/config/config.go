package config

import (
	"fmt"
	"os"

	"github.com/spf13/viper"
)

type Config struct {
	FolderPath       string
	DBPath           string
	BatchSize        int
	Concurrency      int
	HashSize         int
	MaxThumbnailSize int
	PORT             int
	RefreshInterval  int
	CacheSizeMB      int
	LogLevel         string
}

const DefaultPort = 8281

func GetPort() int {
	v := viper.New()
	v.SetDefault("PORT", DefaultPort)
	v.SetDefault("LogLevel", "debug")
	v.AutomaticEnv()
	return v.GetInt("PORT")
}

func LoadConfig() (*Config, error) {
	v := viper.New()
	v.SetDefault("PORT", GetPort())
	v.SetDefault("LogLevel", "debug")
	v.SetConfigName("config")
	v.SetConfigType("toml")
	var configPath string
	if os.Getenv("$XDG_CONFIG_HOME") != "" {
		configPath = "$XDG_CONFIG_HOME/picshow"
	} else {
		configPath = "$HOME/.config/picshow"
	}
	v.AddConfigPath(configPath)
	v.AutomaticEnv()
	if err := v.ReadInConfig(); err != nil {
		return nil, err
	}
	var config Config
	if err := v.Unmarshal(&config); err != nil {
		return nil, err
	}
	return &config, nil
}

func (c *Config) Save() error {
	v := viper.New()
	v.SetDefault("PORT", GetPort())
	v.SetConfigName("config")
	v.SetConfigType("toml")
	var configPath string
	if os.Getenv("$XDG_CONFIG_HOME") != "" {
		configPath = "$XDG_CONFIG_HOME/picshow"
	} else {
		configPath = "$HOME/.config/picshow"
	}
	err := os.MkdirAll(os.ExpandEnv(configPath), 0755)
	if err != nil {
		return fmt.Errorf("failed to create config directory: %w", err)
	}
	v.AddConfigPath(configPath)
	v.AutomaticEnv()
	v.Set("RefreshInterval", c.RefreshInterval)
	v.Set("CacheSizeMB", c.CacheSizeMB)
	v.Set("HashSize", c.HashSize)
	v.Set("MaxThumbnailSize", c.MaxThumbnailSize)
	v.Set("FolderPath", c.FolderPath)
	v.Set("DBPath", c.DBPath)
	v.Set("BatchSize", c.BatchSize)
	v.Set("Concurrency", c.Concurrency)
	v.Set("LogLevel", c.LogLevel)
	return v.SafeWriteConfig()
}
