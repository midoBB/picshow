package cache

import (
	"encoding/json"
	"fmt"
	"picshow/internal/config"
	"strings"
	"time"

	log "github.com/sirupsen/logrus"

	"picshow/internal/utils"

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
	FilesCacheKey       CacheKey = "list"
	PaginationCacheKey  CacheKey = "pagination"
	StatsCacheKey       CacheKey = "stats"
	FileCacheKey        CacheKey = "single"
	FileContentCacheKey CacheKey = "content"
	RandomCacheKey      CacheKey = "random_order"
)

// GenerateFilesCacheKey generates a unique key for files query
func GenerateFilesCacheKey(
	page, pageSize int,
	order utils.OrderBy,
	direction utils.OrderDirection,
	seed *uint64,
	mimetype *string,
) (string, string) {
	seedStr := "0"
	if seed != nil {
		seedStr = fmt.Sprintf("%d", *seed)
	}
	mimetypeStr := ""
	if mimetype != nil {
		mimetypeStr = *mimetype
	}
	return fmt.Sprintf("%s:%s:%s:%s:%s:%d:%d", FilesCacheKey, order, direction, seedStr, mimetypeStr, page, pageSize), fmt.Sprintf("%s:%s:%s:%s:%s:%d:%d", PaginationCacheKey, order, direction, seedStr, mimetypeStr, page, pageSize)
}

// GenerateFileCacheKey generates a unique key for a single file
func GenerateFileCacheKey(id uint64) string {
	return fmt.Sprintf("%s:%d", FileCacheKey, id)
}

// GenerateFileContentCacheKey generates a unique key for a single file
func GenerateFileContentCacheKey(id uint64) string {
	return fmt.Sprintf("%s:%d", FileContentCacheKey, id)
}

// SetCache sets a value in the cache
func (c *Cache) SetCache(key string, value interface{}) error {
	data, err := json.Marshal(value)
	if err != nil {
		log.WithFields(log.Fields{"key": key, "value": value}).Debug("Failed to marshal value")
		return err
	}
	c.cache.Set(key, data)
	log.WithFields(log.Fields{"key": key, "size": len(data)}).Debug("Setting cache")
	return nil
}

// GetCache retrieves a value from the cache
func (c *Cache) GetCache(key string, value interface{}) (bool, error) {
	log.WithFields(log.Fields{"key": key}).Debug("Checking cache")
	data, found := c.cache.Get(key)
	if !found {
		log.WithFields(log.Fields{"key": key}).Debug("Cache miss")
		return false, nil
	}
	log.WithFields(log.Fields{"key": key, "size": len(data)}).Debug("Cache hit")
	return true, json.Unmarshal(data, value)
}

func (c *Cache) Delete(key string) {
	c.cache.DeleteByFunc(func(cacheKey string, value []byte) bool {
		log.WithFields(log.Fields{"key": cacheKey}).Debug("Deleting from cache")
		return strings.Contains(cacheKey, key)
	})
}
