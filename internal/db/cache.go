package db

import (
	"encoding/json"
	"fmt"
	"picshow/internal/config"
	"time"

	"github.com/maypok86/otter"
)

type Cache struct {
	cache otter.Cache[string, []byte]
}

func NewCache(config *config.Config) (*Cache, error) {
	var err error
	cache, err := otter.MustBuilder[string, []byte](config.CacheSizeMB * 1024 * 1024).
		WithTTL(15 * time.Minute).
		Build()
	if err != nil {
		return nil, err
	}
	return &Cache{cache}, nil
}

// CacheKey is a type for cache keys
type CacheKey string

const (
	FilesCacheKey CacheKey = "files"
	StatsCacheKey CacheKey = "stats"
	FileCacheKey  CacheKey = "file"
)

// GenerateFilesCacheKey generates a unique key for files query
func GenerateFilesCacheKey(page, pageSize int, order OrderBy, direction OrderDirection, seed *uint64, mimetype *string) string {
	seedStr := "0"
	if seed != nil {
		seedStr = fmt.Sprintf("%d", *seed)
	}
	mimetypeStr := ""
	if mimetype != nil {
		mimetypeStr = *mimetype
	}
	return fmt.Sprintf("%s:%s:%s:%s:%s:%d:%d", FilesCacheKey, order, direction, seedStr, mimetypeStr, page, pageSize)
}

// GenerateFileCacheKey generates a unique key for a single file
func GenerateFileCacheKey(id uint64) string {
	return fmt.Sprintf("%s:%d", FileCacheKey, id)
}

// SetCache sets a value in the cache
func (c *Cache) SetCache(key string, value interface{}) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	c.cache.Set(key, data)
	return nil
}

// GetCache retrieves a value from the cache
func (c *Cache) GetCache(key string, value interface{}) (bool, error) {
	data, found := c.cache.Get(key)
	if !found {
		return false, nil
	}
	return true, json.Unmarshal(data, value)
}
