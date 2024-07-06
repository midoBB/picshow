package config

import "github.com/spf13/viper"

type Config struct {
	FolderPath       string
	BatchSize        int
	HashSize         int
	MaxThumbnailSize int
	DbPath           string
}

func LoadConfig() (*Config, error) {
	v := viper.New()
	v.SetConfigName("config")
	v.SetConfigType("toml")
	v.AddConfigPath(".")
	v.AddConfigPath("$XDG_CONFIG_HOME/picshow")
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
