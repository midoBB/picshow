package database

import "time"

type File struct {
	ID           uint64 `gorm:"primaryKey"`
	Hash         string `gorm:"uniqueIndex"`
	CreatedAt    time.Time
	Filename     string
	Size         int64
	MimeType     string
	LastModified int64
	Image        *Image `gorm:"foreignKey:FileID" json:",omitempty"`
	Video        *Video `gorm:"foreignKey:FileID" json:",omitempty"`
}

func (f *File) SetLastModified(t time.Time) {
	f.LastModified = t.Unix()
}

func (f *File) GetLastModified() time.Time {
	return time.Unix(f.LastModified, 0)
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
	ThumbnailData   []byte `json:"-"`
	ThumbnailBase64 string `gorm:"-"`
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
	ThumbnailData   []byte `json:"-"`
	ThumbnailBase64 string `gorm:"-"`
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
