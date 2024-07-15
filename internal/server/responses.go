package server

import (
	"picshow/internal/utils"
	"time"

	pb "picshow/internal/kv"
)

type File struct {
	ID           uint64
	Hash         string
	CreatedAt    time.Time
	Filename     string
	Size         int64
	MimeType     string
	LastModified int64
	Image        *Image `json:",omitempty"`
	Video        *Video `json:",omitempty"`
}

type Image struct {
	ID              uint
	FullMimeType    string
	Width           uint64
	Height          uint64
	ThumbnailWidth  uint64
	ThumbnailHeight uint64
	ThumbnailBase64 string
}

type Video struct {
	ID              uint64
	FullMimeType    string
	Width           uint64
	Height          uint64
	Length          uint64
	FileID          uint64
	ThumbnailWidth  uint64
	ThumbnailHeight uint64
	ThumbnailBase64 string
}

func MapProtoFileToServerFile(protoFile *pb.File) *File {
	serverFile := &File{
		ID:           protoFile.Id,
		Hash:         protoFile.Hash,
		CreatedAt:    protoFile.CreatedAt.AsTime(),
		Filename:     protoFile.Filename,
		Size:         protoFile.Size,
		MimeType:     protoFile.MimeType,
		LastModified: protoFile.LastModified,
	}

	switch media := protoFile.Media.(type) {
	case *pb.File_Image:
		serverFile.Image = &Image{
			FullMimeType:    media.Image.FullMimeType,
			Width:           media.Image.Width,
			Height:          media.Image.Height,
			ThumbnailWidth:  media.Image.ThumbnailWidth,
			ThumbnailHeight: media.Image.ThumbnailHeight,
			ThumbnailBase64: utils.ThumbBytesToBase64(media.Image.ThumbnailData),
		}
	case *pb.File_Video:
		serverFile.Video = &Video{
			FullMimeType:    media.Video.FullMimeType,
			Width:           media.Video.Width,
			Height:          media.Video.Height,
			Length:          media.Video.Length,
			ThumbnailWidth:  media.Video.ThumbnailWidth,
			ThumbnailHeight: media.Video.ThumbnailHeight,
			ThumbnailBase64: utils.ThumbBytesToBase64(media.Video.ThumbnailData),
		}
	}

	return serverFile
}

type Pagination struct {
	TotalRecords uint64  `json:"total_records"`
	CurrentPage  uint64  `json:"current_page"`
	TotalPages   uint64  `json:"total_pages"`
	NextPage     *uint64 `json:"next_page"`
	PrevPage     *uint64 `json:"prev_page"`
}

type FilesWithPagination struct {
	Files      []*File     `json:"files"`
	Pagination *Pagination `json:"pagination"`
}

func MapProtoPaginationToServerPagination(protoPagination *pb.Pagination) *Pagination {
	serverPagination := &Pagination{
		TotalRecords: protoPagination.TotalRecords,
		CurrentPage:  protoPagination.CurrentPage,
		TotalPages:   protoPagination.TotalPages,
	}
	if protoPagination.NextPage != nil {
		serverPagination.NextPage = protoPagination.NextPage
	}
	if protoPagination.PrevPage != nil {
		serverPagination.PrevPage = protoPagination.PrevPage
	}
	return serverPagination
}
