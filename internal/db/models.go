package db

import "time"

type File struct {
	ID       uint64 `gorm:"primaryKey"`
	Hash     string `gorm:"uniqueIndex"`
	Filename string
	Size     int64
	MimeType string
}

type Image struct {
	ID              uint `gorm:"primaryKey"`
	CreatedAt       time.Time
	FullMimeType    string
	Width           uint64
	Height          uint64
	FileID          uint64
	File            File
	ThumbnailWidth  uint64
	ThumbnailHeight uint64
	ThumbnailData   []byte
}

type Video struct {
	ID              uint64 `gorm:"primaryKey"`
	CreatedAt       time.Time
	FullMimeType    string
	Width           uint64
	Height          uint64
	Length          uint64
	FileID          uint64
	File            File
	ThumbnailWidth  uint64
	ThumbnailHeight uint64
	ThumbnailData   []byte
}
type MimeType string

const (
	MimeTypeImage MimeType = "image"
	MimeTypeVideo MimeType = "video"
	MimeTypeOther MimeType = "other"
	MimeTypeError MimeType = "error"
)

var AllMimeTypes = []MimeType{MimeTypeImage, MimeTypeVideo, MimeTypeOther, MimeTypeError}

func (mt MimeType) IsValid() bool {
	switch mt {
	case MimeTypeImage, MimeTypeVideo, MimeTypeOther, MimeTypeError:
		return true
	}
	return false
}

func (mt MimeType) String() string {
	return string(mt)
}
