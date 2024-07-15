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
	var totalPages int
	err = r.db.Transaction(func(tx *gorm.DB) error {
		// Count total records
		if err := tx.Model(&File{}).Scopes(ByType(mimetype)).Count(&totalRecords).Error; err != nil {
			return err
		}

		// Calculate pagination
		totalPages = int(math.Ceil(float64(totalRecords) / float64(pageSize)))
		offset := (page - 1) * pageSize

		// Fetch files with pagination
		query := tx.Preload("Image").Preload("Video").Scopes(ByType(mimetype), OrderFiles(order, direction, seed))
		if err := query.Offset(offset).Limit(pageSize).Find(&files).Error; err != nil {
			return err
		}

		return nil
	})
	if err != nil {
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

	var stats ServerStats
	err = r.db.Transaction(func(tx *gorm.DB) error {
		// Use a single query to get all stats
		err := tx.Raw(`
			SELECT
				(SELECT COUNT(*) FROM files) as count,
				(SELECT COUNT(*) FROM videos) as video_count,
				(SELECT COUNT(*) FROM images) as image_count
		`).Scan(&stats).Error
		return err
	})
	if err != nil {
		return nil, err
	}

	if err := r.cache.SetCache(string(cache.StatsCacheKey), &stats); err != nil {
		return nil, fmt.Errorf("failed to set cache: %w", err)
	}

	return &stats, nil
}

func (r *Repository) DeleteFiles(ids []uint64) error {
	return r.db.Transaction(func(tx *gorm.DB) error {
		// Delete related records in a single query each
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
	return r.db.Transaction(func(tx *gorm.DB) error {
		// Check if the file exists
		var file File
		if err := tx.First(&file, id).Error; err != nil {
			if err == gorm.ErrRecordNotFound {
				return fmt.Errorf("file with id %d not found", id)
			}
			return err
		}

		// Delete related records and the file in a single query each
		if err := tx.Where("file_id = ?", id).Delete(&Image{}).Error; err != nil {
			return err
		}

		if err := tx.Where("file_id = ?", id).Delete(&Video{}).Error; err != nil {
			return err
		}

		if err := tx.Delete(&file).Error; err != nil {
			return err
		}

		r.clearCacheByFileID(id)
		r.clearCache()

		return nil
	})
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
