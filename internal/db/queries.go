package db

import (
	"fmt"
	"math"
	"picshow/internal/utils"

	"gorm.io/gorm"
)

type Pagination struct {
	TotalRecords int64 `json:"total_records"`
	CurrentPage  int   `json:"current_page"`
	TotalPages   int   `json:"total_pages"`
	NextPage     *int  `json:"next_page"`
	PrevPage     *int  `json:"prev_page"`
}

type FilesWithPagination struct {
	Files      []*File    `json:"files"`
	Pagination Pagination `json:"pagination"`
}

type OrderBy string

const (
	CreatedAt OrderBy = "created_at"
	Random    OrderBy = "random"
)

type OrderDirection string

const (
	Asc  OrderDirection = "asc"
	Desc OrderDirection = "desc"
)

func OrderFiles(by OrderBy, direction OrderDirection, seed *uint64) func(db *gorm.DB) *gorm.DB {
	return func(db *gorm.DB) *gorm.DB {
		switch by {
		case CreatedAt:
			if direction == Desc {
				return db.Order("created_at desc")
			}
			return db.Order("created_at asc")
		case Random:
			return db.Order(fmt.Sprintf("SIN(id + %d)", *seed))
		default:
			return db
		}
	}
}

func ByType(mimetype *string) func(db *gorm.DB) *gorm.DB {
	return func(db *gorm.DB) *gorm.DB {
		if mimetype == nil {
			return db
		}
		return db.Where("mime_type = ?", mimetype)
	}
}

func GetFiles(cache *Cache, db *gorm.DB, page, pageSize int, order OrderBy, direction OrderDirection, seed *uint64, mimetype *string) (*FilesWithPagination, error) {
	cacheKey := GenerateFilesCacheKey(page, pageSize, order, direction, seed, mimetype)
	var cachedFiles FilesWithPagination
	found, err := cache.GetCache(cacheKey, &cachedFiles)
	if err != nil {
		return nil, fmt.Errorf("cache error: %w", err)
	}
	if found {
		return &cachedFiles, nil
	}
	var files []*File
	var totalRecords int64

	// Count total records
	if err := db.Model(&File{}).Scopes(ByType(mimetype)).Count(&totalRecords).Error; err != nil {
		return nil, err
	}

	// Calculate pagination
	totalPages := int(math.Ceil(float64(totalRecords) / float64(pageSize)))
	offset := (page - 1) * pageSize

	// Fetch files with pagination
	if err := db.Preload("Image").Preload("Video").Scopes(ByType(mimetype), OrderFiles(order, direction, seed)).
		Offset(offset).Limit(pageSize).Find(&files).Error; err != nil {
		return nil, err
	}

	// Prepare pagination info
	var nextPage, prevPage *int
	if page < totalPages {
		next := page + 1
		nextPage = &next
	}
	if page > 1 {
		prev := page - 1
		prevPage = &prev
	}

	for _, file := range files {
		if file.Image != nil {
			file.Image.ThumbnailBase64 = utils.ThumbBytesToBase64(file.Image.ThumbnailData)
		} else if file.Video != nil {
			file.Video.ThumbnailBase64 = utils.ThumbBytesToBase64(file.Video.ThumbnailData)
		}
	}

	pagination := Pagination{
		TotalRecords: totalRecords,
		CurrentPage:  page,
		TotalPages:   totalPages,
		NextPage:     nextPage,
		PrevPage:     prevPage,
	}

	result := &FilesWithPagination{
		Files:      files,
		Pagination: pagination,
	}
	if err := cache.SetCache(cacheKey, result); err != nil {
		return nil, fmt.Errorf("failed to set cache: %w", err)
	}
	return result, nil
}

func GetStats(cache *Cache, db *gorm.DB) (*ServerStats, error) {
	var cachedStats ServerStats
	found, err := cache.GetCache(string(StatsCacheKey), &cachedStats)
	if err != nil {
		return nil, fmt.Errorf("cache error: %w", err)
	}
	if found {
		return &cachedStats, nil
	}
	var totalCount int64
	var totalVideoCount int64
	var totalImageCount int64
	if err := db.Model(&File{}).Count(&totalCount).Error; err != nil {
		return nil, err
	}
	if err := db.Model(&Video{}).Count(&totalVideoCount).Error; err != nil {
		return nil, err
	}
	if err := db.Model(&Image{}).Count(&totalImageCount).Error; err != nil {
		return nil, err
	}
	stats := &ServerStats{
		Count:      totalCount,
		VideoCount: totalVideoCount,
		ImageCount: totalImageCount,
	}

	if err := cache.SetCache(string(StatsCacheKey), stats); err != nil {
		return nil, fmt.Errorf("failed to set cache: %w", err)
	}

	return stats, nil
}

func GetFile(cache *Cache, db *gorm.DB, id uint64) (*File, error) {
	cacheKey := GenerateFileCacheKey(id)

	var cachedFile File
	found, err := cache.GetCache(cacheKey, &cachedFile)
	if err != nil {
		return nil, fmt.Errorf("cache error: %w", err)
	}
	if found {
		return &cachedFile, nil
	}
	var file File
	if err := db.Preload("Video").First(&file, id).Error; err != nil {
		return nil, err
	}
	if err := cache.SetCache(cacheKey, &file); err != nil {
		return nil, fmt.Errorf("failed to set cache: %w", err)
	}
	return &file, nil
}

func DeleteFile(cache *Cache, db *gorm.DB, id uint64) error {
	// First, delete records from images and videos tables where file_id matches the given id
	err := db.Where("file_id = ?", id).Delete(&Image{}).Error
	if err != nil {
		return err
	}

	err = db.Where("file_id = ?", id).Delete(&Video{}).Error
	if err != nil {
		return err
	}

	// Finally, delete the record from the files table where id matches
	err = db.Delete(&File{}, id).Error
	if err != nil {
		return err
	}
	cacheKey := GenerateFileCacheKey(id)
	cache.cache.Delete(cacheKey)
	cache.cache.Delete(string(StatsCacheKey))
	// Invalidate files cache (simplistic approach, could be more granular)
	cache.cache.Delete(string(FilesCacheKey))
	return nil
}
