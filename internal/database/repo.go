package database

import (
	"fmt"
	"math"
	"picshow/internal/cache"
	"picshow/internal/utils"

	"gorm.io/gorm"
)

type Repository struct {
	db    *gorm.DB
	cache *cache.Cache
}

func NewRepository(db *gorm.DB, cache *cache.Cache) *Repository {
	return &Repository{
		db:    db,
		cache: cache,
	}
}

func OrderFiles(
	by utils.OrderBy,
	direction utils.OrderDirection,
	seed *uint64,
) func(db *gorm.DB) *gorm.DB {
	return func(db *gorm.DB) *gorm.DB {
		switch by {
		case utils.CreatedAt:
			if direction == utils.Desc {
				return db.Order("created_at desc")
			}
			return db.Order("created_at asc")
		case utils.Random:
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

func (r *Repository) GetFiles(
	page, pageSize int,
	order utils.OrderBy,
	direction utils.OrderDirection,
	seed *uint64,
	mimetype *string,
) (*FilesWithPagination, error) {
	cacheKey := cache.GenerateFilesCacheKey(page, pageSize, order, direction, seed, mimetype)
	var cachedFiles FilesWithPagination
	found, err := r.cache.GetCache(cacheKey, &cachedFiles)
	if err != nil {
		return nil, fmt.Errorf("cache error: %w", err)
	}
	if found {
		return &cachedFiles, nil
	}
	var files []*File
	var totalRecords int64

	// Count total records
	if err := r.db.Model(&File{}).Scopes(ByType(mimetype)).Count(&totalRecords).Error; err != nil {
		return nil, err
	}

	// Calculate pagination
	totalPages := int(math.Ceil(float64(totalRecords) / float64(pageSize)))
	offset := (page - 1) * pageSize

	// Fetch files with pagination
	if err := r.db.Preload("Image").Preload("Video").Scopes(ByType(mimetype), OrderFiles(order, direction, seed)).
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
	if err := r.cache.SetCache(cacheKey, result); err != nil {
		return nil, fmt.Errorf("failed to set cache: %w", err)
	}
	return result, nil
}

func (r *Repository) GetStats() (*ServerStats, error) {
	var cachedStats ServerStats
	found, err := r.cache.GetCache(string(cache.StatsCacheKey), &cachedStats)
	if err != nil {
		return nil, fmt.Errorf("cache error: %w", err)
	}
	if found {
		return &cachedStats, nil
	}
	var totalCount int64
	var totalVideoCount int64
	var totalImageCount int64
	if err := r.db.Model(&File{}).Count(&totalCount).Error; err != nil {
		return nil, err
	}
	if err := r.db.Model(&Video{}).Count(&totalVideoCount).Error; err != nil {
		return nil, err
	}
	if err := r.db.Model(&Image{}).Count(&totalImageCount).Error; err != nil {
		return nil, err
	}
	stats := &ServerStats{
		Count:      totalCount,
		VideoCount: totalVideoCount,
		ImageCount: totalImageCount,
	}

	if err := r.cache.SetCache(string(cache.StatsCacheKey), stats); err != nil {
		return nil, fmt.Errorf("failed to set cache: %w", err)
	}

	return stats, nil
}

func (r *Repository) DeleteFiles(ids []uint64) error {
	return r.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("file_id IN ?", ids).Delete(&Image{}).Error; err != nil {
			return err
		}
		if err := tx.Where("file_id IN ?", ids).Delete(&Video{}).Error; err != nil {
			return err
		}
		if err := tx.Where("id IN ?", ids).Delete(&File{}).Error; err != nil {
			return err
		}
		for _, id := range ids {
			r.clearCacheByFileID(id)
		}
		r.clearCache()
		return nil
	})
}

func (r *Repository) GetFilesByIds(ids []uint64) ([]*File, error) {
	var files []*File
	if err := r.db.Find(&files, ids).Error; err != nil {
		return nil, err
	}
	return files, nil
}

func (r *Repository) GetFile(id uint64) (*File, error) {
	cacheKey := cache.GenerateFileCacheKey(id)

	var cachedFile File
	found, err := r.cache.GetCache(cacheKey, &cachedFile)
	if err != nil {
		return nil, fmt.Errorf("cache error: %w", err)
	}
	if found {
		return &cachedFile, nil
	}
	var file File
	if err := r.db.Preload("Video").First(&file, id).Error; err != nil {
		return nil, err
	}
	if err := r.cache.SetCache(cacheKey, &file); err != nil {
		return nil, fmt.Errorf("failed to set cache: %w", err)
	}
	return &file, nil
}

func (r *Repository) clearCacheByFileID(id uint64) {
	cacheKey := cache.GenerateFileCacheKey(id)
	contentCacheKey := cache.GenerateFileContentCacheKey(id)
	r.cache.Delete(cacheKey)
	r.cache.Delete(contentCacheKey)
}

func (r *Repository) clearCache() {
	r.cache.Delete(string(cache.StatsCacheKey))
	r.cache.Delete(string(cache.FilesCacheKey))
}

func (r *Repository) DeleteFile(id uint64) error {
	// First, delete records from images and videos tables where file_id matches the given id
	err := r.db.Where("file_id = ?", id).Delete(&Image{}).Error
	if err != nil {
		return err
	}

	err = r.db.Where("file_id = ?", id).Delete(&Video{}).Error
	if err != nil {
		return err
	}

	// Finally, delete the record from the files table where id matches
	err = r.db.Delete(&File{}, id).Error
	if err != nil {
		return err
	}
	r.clearCacheByFileID(id)
	r.clearCache()
	return nil
}

func (r *Repository) FindAllFiles() ([]File, error) {
	var files []File
	if err := r.db.Find(&files).Error; err != nil {
		return nil, fmt.Errorf("error fetching existing files: %w", err)
	}
	return files, nil
}

func (r *Repository) UpdateFile(file *File) error {
	r.clearCacheByFileID(file.ID)
	return r.db.Model(file).Where("hash = ?", file.Hash).Updates(file).Error
}

func (r *Repository) CreateFile(file *File) error {
	r.cache.Delete(string(cache.StatsCacheKey))
	r.cache.Delete(string(cache.FilesCacheKey))
	return r.db.Create(file).Error
}

func (r *Repository) CreateImage(image *Image) error {
	return r.db.Create(image).Error
}

func (r *Repository) CreateVideo(video *Video) error {
	return r.db.Create(video).Error
}

func (r *Repository) FindFileByHash(hash string) (*File, error) {
	var file File
	if err := r.db.Where("hash = ?", hash).First(&file).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			return nil, nil
		}
		return nil, err
	}
	return &file, nil
}
