package config

import (
	"fmt"
	"os"

	"github.com/spf13/viper"
)

type Config struct {
	FolderPath       string
	BatchSize        *int // TODO: return to using batching when processiing at startup
	HashSize         int
	MaxThumbnailSize int
	PORT             int
	RefreshInterval  int
	CacheSizeMB      int
}

const DefaultPort = 8281

func GetPort() int {
	v := viper.New()
	v.SetDefault("PORT", DefaultPort)
	v.AutomaticEnv()
	return v.GetInt("PORT")
}

func LoadConfig() (*Config, error) {
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
	return v.SafeWriteConfig()
}
