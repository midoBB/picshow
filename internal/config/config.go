package config

import "github.com/spf13/viper"

type Config struct {
	FolderPath       string
	BatchSize        int // TODO: return to using batching when processiing at startup
	HashSize         int
	MaxThumbnailSize int
	Port             int
	RefreshInterval  int
	CacheSizeMB      int
}

func LoadConfig() (*Config, error) {
	v := viper.New()
	v.SetConfigName("config")
	v.SetConfigType("toml")
	v.AddConfigPath("$XDG_CONFIG_HOME/picshow")
	v.AddConfigPath("$HOME/.config/picshow")
	v.AddConfigPath(".")
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
