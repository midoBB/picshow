package db

import "time"

type File struct {
	ID        uint64 `gorm:"primaryKey"`
	Hash      string `gorm:"uniqueIndex"`
	CreatedAt time.Time
	Filename  string
	Size      int64
	MimeType  string
	Image     *Image `gorm:"foreignKey:FileID" json:",omitempty"`
	Video     *Video `gorm:"foreignKey:FileID" json:",omitempty"`
}

type Image struct {
	ID              uint `gorm:"primaryKey"`
	FullMimeType    string
	Width           uint64
	Height          uint64
	FileID          uint64
	File            File `json:"-"`
	ThumbnailWidth  uint64
	ThumbnailHeight uint64
	ThumbnailData   []byte
}

type Video struct {
	ID              uint64 `gorm:"primaryKey"`
	FullMimeType    string
	Width           uint64
	Height          uint64
	Length          uint64
	FileID          uint64
	File            File `json:"-"`
	ThumbnailWidth  uint64
	ThumbnailHeight uint64
	ThumbnailData   []byte
}

type ServerStats struct {
	Count      int64 `json:"count"`
	VideoCount int64 `json:"video_count"`
	ImageCount int64 `json:"image_count"`
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
