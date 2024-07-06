package db

import (
	"fmt"
	"math"

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
	Files      []File     `json:"files"`
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

func GetFiles(db *gorm.DB, page, pageSize int, order OrderBy, direction OrderDirection, seed *uint64) (*FilesWithPagination, error) {
	var files []File
	var totalRecords int64

	// Count total records
	if err := db.Model(&File{}).Count(&totalRecords).Error; err != nil {
		return nil, err
	}

	// Calculate pagination
	totalPages := int(math.Ceil(float64(totalRecords) / float64(pageSize)))
	offset := (page - 1) * pageSize

	// Fetch files with pagination
	if err := db.Preload("Image").Preload("Video").Scopes(OrderFiles(order, direction, seed)).
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

	pagination := Pagination{
		TotalRecords: totalRecords,
		CurrentPage:  page,
		TotalPages:   totalPages,
		NextPage:     nextPage,
		PrevPage:     prevPage,
	}

	return &FilesWithPagination{
		Files:      files,
		Pagination: pagination,
	}, nil
}

func GetStats(db *gorm.DB) (*ServerStats, error) {
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
	return &ServerStats{
		Count:      totalCount,
		VideoCount: totalVideoCount,
		ImageCount: totalImageCount,
	}, nil
}
