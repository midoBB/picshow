package files

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"image"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"io"
	"log"
	"math"
	"os"
	"path/filepath"
	"picshow/internal/config"
	"picshow/internal/db"
	"strings"

	"github.com/disintegration/imaging"
	"github.com/gabriel-vasile/mimetype"
	"github.com/tidwall/gjson"
	ffmpeg "github.com/u2takey/ffmpeg-go"
	"gorm.io/gorm"
)

type handler struct {
	config *config.Config
	db     *gorm.DB
}

func newHandler(config *config.Config, db *gorm.DB) *handler {
	return &handler{config: config, db: db}
}

func getFullMimeType(filePath string) string {
	mtype, _ := mimetype.DetectFile(filePath) // since this was already had been given a mimetype we know this operation will not fail
	return mtype.String()
}

func getFileMimeType(filePath string) (db.MimeType, error) {
	mtype, err := mimetype.DetectFile(filePath)
	if err != nil {
		return db.MimeTypeError, fmt.Errorf("error detecting mime type: %w", err)
	}
	if strings.Contains(mtype.String(), "image") {
		return db.MimeTypeImage, nil
	} else if strings.Contains(mtype.String(), "video") {
		return db.MimeTypeVideo, nil
	}
	return db.MimeTypeOther, nil
}

// generateFileKey creates a unique key for a file based on its size, creation time, and partial content hash
func (h *handler) generateFileKey(filePath string) (string, error) {
	file, err := os.Open(filePath)
	if err != nil {
		return "", fmt.Errorf("error opening file: %w", err)
	}
	defer file.Close()

	fileInfo, err := file.Stat()
	if err != nil {
		return "", fmt.Errorf("error getting file info: %w", err)
	}

	fileSize := fileInfo.Size()

	// Read the first 'hashSize' bytes for hashing
	buffer := make([]byte, h.config.HashSize)
	n, err := file.Read(buffer)
	if err != nil && err != io.EOF {
		return "", fmt.Errorf("error reading file: %w", err)
	}

	hasher := md5.New()
	hasher.Write(buffer[:n])
	contentHash := hex.EncodeToString(hasher.Sum(nil))

	// Combine the elements into a key
	key := fmt.Sprintf("%d_%s", fileSize, contentHash)

	return key, nil
}

func readFrameAsJPEG(inFileName string, timestamp float64) io.Reader {
	buf := bytes.NewBuffer(nil)
	err := ffmpeg.Input(inFileName).
		Filter("select", ffmpeg.Args{fmt.Sprintf("gte(n,%d)", uint64(timestamp))}).
		Output("pipe:", ffmpeg.KwArgs{"vframes": 1, "format": "image2", "vcodec": "mjpeg"}).
		WithOutput(buf, os.Stdout).
		Run()
	if err != nil {
		panic(err)
	}
	return buf
}

func (h *handler) handleNewVideo(filePath string, file db.File) error {
	res, err := ffmpeg.Probe(filePath)
	if err != nil {
		return err
	}
	duration := gjson.Get(res, "format.duration").Float()
	width := gjson.Get(res, "streams.#(codec_type=video).width").Uint()
	height := gjson.Get(res, "streams.#(codec_type=video).height").Uint()
	screenshotAt := math.Floor(duration * 0.33)
	reader := readFrameAsJPEG(filePath, screenshotAt)
	img, err := imaging.Decode(reader)
	if err != nil {
		return err
	}

	// Create a thumbnail while maintaining aspect ratio
	var thumbnail image.Image
	if width > height {
		thumbnail = imaging.Resize(img, h.config.MaxThumbnailSize, 0, imaging.Lanczos)
	} else {
		thumbnail = imaging.Resize(img, 0, h.config.MaxThumbnailSize, imaging.Lanczos)
	}

	// Encode thumbnail to JPEG
	var thumbnailBuffer bytes.Buffer
	if err := jpeg.Encode(&thumbnailBuffer, thumbnail, &jpeg.Options{Quality: 85}); err != nil {
		return err
	}

	// Get thumbnail dimensions
	thumbBounds := thumbnail.Bounds()
	thumbWidth := thumbBounds.Max.X - thumbBounds.Min.X
	thumbHeight := thumbBounds.Max.Y - thumbBounds.Min.Y

	// Create Video record
	image := db.Video{
		FullMimeType:    getFullMimeType(filePath),
		Width:           width,
		Height:          height,
		FileID:          file.ID,
		ThumbnailWidth:  uint64(thumbWidth),
		ThumbnailHeight: uint64(thumbHeight),
		Length:          uint64(duration),
		ThumbnailData:   thumbnailBuffer.Bytes(),
	}

	// Save Image record to database
	if err := h.db.Create(&image).Error; err != nil {
		return err
	}

	log.Printf("Successfully processed and saved image: %s", filepath.Base(filePath))
	return nil
}

func (h *handler) handleNewImage(filePath string, file db.File) error {
	// Open the image file
	imgFile, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer imgFile.Close()

	// Decode the image
	img, _, err := image.Decode(imgFile)
	if err != nil {
		return err
	}

	// Get image dimensions
	bounds := img.Bounds()
	width := bounds.Max.X - bounds.Min.X
	height := bounds.Max.Y - bounds.Min.Y

	// Create a thumbnail while maintaining aspect ratio
	var thumbnail image.Image
	if width > height {
		thumbnail = imaging.Resize(img, h.config.MaxThumbnailSize, 0, imaging.Lanczos)
	} else {
		thumbnail = imaging.Resize(img, 0, h.config.MaxThumbnailSize, imaging.Lanczos)
	}

	// Encode thumbnail to JPEG
	var thumbnailBuffer bytes.Buffer
	if err := jpeg.Encode(&thumbnailBuffer, thumbnail, &jpeg.Options{Quality: 85}); err != nil {
		return err
	}

	// Get thumbnail dimensions
	thumbBounds := thumbnail.Bounds()
	thumbWidth := thumbBounds.Max.X - thumbBounds.Min.X
	thumbHeight := thumbBounds.Max.Y - thumbBounds.Min.Y

	// Create Image record
	image := db.Image{
		FullMimeType:    getFullMimeType(filePath),
		Width:           uint64(width),
		Height:          uint64(height),
		FileID:          file.ID,
		ThumbnailWidth:  uint64(thumbWidth),
		ThumbnailHeight: uint64(thumbHeight),
		ThumbnailData:   thumbnailBuffer.Bytes(),
	}

	// Save Image record to database
	if err := h.db.Create(&image).Error; err != nil {
		return err
	}

	log.Printf("Successfully processed and saved image: %s", filepath.Base(filePath))
	return nil
}
