package main

import (
	"bytes"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"io"
	"io/fs"
	"log"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/disintegration/imaging"
	"github.com/gabriel-vasile/mimetype"
	"github.com/illarion/gonotify"
	"github.com/tidwall/gjson"
	ffmpeg "github.com/u2takey/ffmpeg-go"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

const (
	dbName             = "files.db"
	folderPath         = "/home/mh/Pictures"
	deletedFilesFolder = "/home/mh/Documents"
	batchSize          = 100
	hashSize           = 8192
	maxThumbnailSize   = 320
)

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

func (mt MimeType) String() string {
	return string(mt)
}

func thumbBytesToBase64(thumbBytes []byte) string {
	return "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(thumbBytes)
}

func getFileMimeType(filePath string) (MimeType, error) {
	mtype, err := mimetype.DetectFile(filePath)
	if err != nil {
		return MimeTypeError, fmt.Errorf("error detecting mime type: %w", err)
	}
	if strings.Contains(mtype.String(), "image") {
		return MimeTypeImage, nil
	} else if strings.Contains(mtype.String(), "video") {
		return MimeTypeVideo, nil
	}
	return MimeTypeOther, nil
}

// generateFileKey creates a unique key for a file based on its size, creation time, and partial content hash
func generateFileKey(filePath string) (string, error) {
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
	buffer := make([]byte, hashSize)
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

func main() {
	newLogger := logger.New(
		log.New(os.Stdout, "\r\n", log.LstdFlags), // io writer
		logger.Config{
			SlowThreshold:             time.Second, // Slow SQL threshold
			LogLevel:                  logger.Info, // Log level
			IgnoreRecordNotFoundError: false,       // Don't ignore ErrRecordNotFound error
			Colorful:                  true,        // Enable color
		},
	)

	db, err := gorm.Open(sqlite.Open(dbName), &gorm.Config{
		Logger: newLogger,
	})
	if err != nil {
		log.Fatal(err)
	}

	err = db.AutoMigrate(&File{}, &Image{}, &Video{})
	if err != nil {
		log.Fatal(err)
	}

	err = processFiles(db)
	if err != nil {
		log.Fatal(err)
	}

	fmt.Println("Initial file processing completed successfully.")

	err = watchDirectory(db)
	if err != nil {
		log.Fatal(err)
	}
}

func ExampleReadFrameAsJpeg(inFileName string, timestamp float64) io.Reader {
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

func handleNewVideo(db *gorm.DB, filePath string, file File) error {
	res, err := ffmpeg.Probe(filePath)
	if err != nil {
		return err
	}
	duration := gjson.Get(res, "format.duration").Float()
	width := gjson.Get(res, "streams.#(codec_type=video).width").Uint()
	height := gjson.Get(res, "streams.#(codec_type=video).height").Uint()
	screenshotAt := math.Floor(duration * 0.33)
	reader := ExampleReadFrameAsJpeg(filePath, screenshotAt)
	img, err := imaging.Decode(reader)
	if err != nil {
		return err
	}
	log.Printf("Video info: %+v", duration)
	log.Printf("Video info: %+v", width)
	log.Printf("Video info: %+v", height)

	var thumbnailBuffer bytes.Buffer
	if err := jpeg.Encode(&thumbnailBuffer, img, &jpeg.Options{Quality: 85}); err != nil {
		return err
	}

	// Get thumbnail dimensions
	thumbBounds := img.Bounds()
	thumbWidth := thumbBounds.Max.X - thumbBounds.Min.X
	thumbHeight := thumbBounds.Max.Y - thumbBounds.Min.Y
	// Create Video record
	image := Video{
		FullMimeType:    file.MimeType,
		Width:           width,
		Height:          height,
		FileID:          file.ID,
		ThumbnailWidth:  uint64(thumbWidth),
		ThumbnailHeight: uint64(thumbHeight),
		Length:          uint64(duration),
		ThumbnailData:   thumbnailBuffer.Bytes(),
	}

	// Save Image record to database
	if err := db.Create(&image).Error; err != nil {
		return err
	}

	log.Printf("Successfully processed and saved image: %s", filepath.Base(filePath))
	return nil
}

func handleNewImage(db *gorm.DB, filePath string, file File) error {
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
		thumbnail = imaging.Resize(img, maxThumbnailSize, 0, imaging.Lanczos)
	} else {
		thumbnail = imaging.Resize(img, 0, maxThumbnailSize, imaging.Lanczos)
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
	image := Image{
		FullMimeType:    file.MimeType,
		Width:           uint64(width),
		Height:          uint64(height),
		FileID:          file.ID,
		ThumbnailWidth:  uint64(thumbWidth),
		ThumbnailHeight: uint64(thumbHeight),
		ThumbnailData:   thumbnailBuffer.Bytes(),
	}

	// Save Image record to database
	if err := db.Create(&image).Error; err != nil {
		return err
	}

	log.Printf("Successfully processed and saved image: %s", filepath.Base(filePath))
	return nil
}

func processFiles(db *gorm.DB) error {
	files, err := os.ReadDir(folderPath)
	if err != nil {
		return fmt.Errorf("error reading directory: %w", err)
	}

	var existingHashes []string
	if err := db.Model(&File{}).Pluck("Hash", &existingHashes).Error; err != nil {
		return fmt.Errorf("error getting existing hashes: %w", err)
	}

	existingHashesMap := make(map[string]struct{})
	for _, hash := range existingHashes {
		existingHashesMap[hash] = struct{}{}
	}

	var wg sync.WaitGroup
	semaphore := make(chan struct{}, 10) // Limit concurrent goroutines

	var mu sync.Mutex
	insertBuffer := make([]File, 0, batchSize)
	updateBuffer := make([]File, 0, batchSize)
	deleteBuffer := make([]string, 0, batchSize)

	applyBuffers := func() {
		if len(insertBuffer) > 0 {
			if err := db.CreateInBatches(insertBuffer, batchSize).Error; err != nil {
				log.Printf("Error inserting files in batch: %v", err)
			}
			for _, file := range insertBuffer {
				if MimeType(file.MimeType) == MimeTypeImage {
					filePath := filepath.Join(folderPath, file.Filename)
					if err := handleNewImage(db, filePath, file); err != nil {
						log.Printf("Error processing image %s: %v", filePath, err)
					}
				} else if MimeType(file.MimeType) == MimeTypeVideo {
					filePath := filepath.Join(folderPath, file.Filename)
					if err := handleNewVideo(db, filePath, file); err != nil {
						log.Printf("Error processing video %s: %v", filePath, err)
					}
				}
			}
			insertBuffer = insertBuffer[:0]
		}
		if len(updateBuffer) > 0 {
			for _, file := range updateBuffer {
				if err := db.Model(&File{}).Where("hash = ?", file.Hash).Update("filename", file.Filename).Error; err != nil {
					log.Printf("Error updating file %s: %v", file.Filename, err)
				}
			}
			updateBuffer = updateBuffer[:0]
		}
		if len(deleteBuffer) > 0 {
			if err := db.Where("hash IN ?", deleteBuffer).Delete(&File{}).Error; err != nil {
				log.Printf("Error deleting files in batch: %v", err)
			}
			deleteBuffer = deleteBuffer[:0]
		}
	}

	for _, file := range files {
		if file.IsDir() {
			continue
		}

		wg.Add(1)
		go func(f fs.DirEntry) {
			defer wg.Done()
			semaphore <- struct{}{}
			defer func() { <-semaphore }()

			filePath := filepath.Join(folderPath, f.Name())
			hash, err := generateFileKey(filePath)
			if err != nil {
				log.Printf("Error generating hash for %s: %v", f.Name(), err)
				return
			}

			fileInfo, err := f.Info()
			if err != nil {
				log.Printf("Error getting file info for %s: %v", f.Name(), err)
				return
			}

			mu.Lock()
			defer mu.Unlock()

			if _, exists := existingHashesMap[hash]; exists {
				// File exists, update filename if necessary
				var existingFile File
				if err := db.Where("hash = ?", hash).First(&existingFile).Error; err != nil {
					log.Printf("Error fetching existing file for hash %s: %v", hash, err)
					return
				}
				if existingFile.Filename != f.Name() {
					updateBuffer = append(updateBuffer, File{Hash: hash, Filename: f.Name()})
					if len(updateBuffer) >= batchSize {
						applyBuffers()
					}
				}
				delete(existingHashesMap, hash)
			} else {
				mtype, err := getFileMimeType(filePath)
				if err != nil {
					log.Printf("Error detecting mime type for %s: %v", f.Name(), err)
					return
				}
				// New file, insert it
				insertBuffer = append(insertBuffer, File{Hash: hash, Filename: f.Name(), Size: fileInfo.Size(), MimeType: mtype.String()})
				if len(insertBuffer) >= batchSize {
					applyBuffers()
				}
			}
		}(file)
	}

	wg.Wait()

	// Process remaining files in buffers
	mu.Lock()
	applyBuffers()

	// Remove files from DB that no longer exist in the folder
	for hash := range existingHashesMap {
		deleteBuffer = append(deleteBuffer, hash)
		if len(deleteBuffer) >= batchSize {
			applyBuffers()
		}
	}
	applyBuffers() // Process any remaining deletions
	mu.Unlock()

	return nil
}

func watchDirectory(db *gorm.DB) error {
	// on startup we skip the count of events equivalent to the number of items in db
	var count int64
	err := db.Model(&File{}).Count(&count).Error
	if err != nil {
		return fmt.Errorf("error getting count of files: %w", err)
	}
	watcher, err := gonotify.NewDirWatcher(gonotify.IN_CREATE|gonotify.IN_DELETE|gonotify.IN_MOVED_FROM|gonotify.IN_MOVED_TO, folderPath)
	if err != nil {
		return fmt.Errorf("error creating watcher: %w", err)
	}
	defer watcher.Close()
	var skipped int64 = 0
	for {
		select {
		case event := <-watcher.C:
			time.Sleep(time.Millisecond * 200) // let the file system catch up
			switch {
			case event.Mask&gonotify.IN_CREATE == gonotify.IN_CREATE:
				if skipped < count {
					skipped++
					continue
				}
				handleCreate(db, event.Name)
			case event.Mask&gonotify.IN_MOVED_TO == gonotify.IN_MOVED_TO:
				handleMovedTo(db, event.Name)
			case event.Mask&gonotify.IN_DELETE == gonotify.IN_DELETE:
				fallthrough
			case event.Mask&gonotify.IN_MOVED_FROM == gonotify.IN_MOVED_FROM:
				handleRemove(db, event.Name)
			}
		}
	}
}

func handleCreate(db *gorm.DB, filePath string) {
	hash, err := generateFileKey(filePath)
	if err != nil {
		log.Printf("Error generating hash for new file %s: %v", filePath, err)
		return
	}

	fileInfo, err := os.Stat(filePath)
	if err != nil {
		log.Printf("Error getting file info for new file %s: %v", filePath, err)
		return
	}

	mtype, err := getFileMimeType(filePath)
	if err != nil {
		log.Printf("Error detecting mime type for %s: %v", filePath, err)
		return
	}
	newFile := File{
		Hash:     hash,
		Filename: filepath.Base(filePath),
		Size:     fileInfo.Size(),
		MimeType: mtype.String(),
	}

	result := db.Create(&newFile)
	if result.Error != nil {
		if strings.Contains(result.Error.Error(), "UNIQUE constraint failed: files.hash") {
			newPath := filepath.Join(deletedFilesFolder, filepath.Base(filePath))
			err = os.Rename(filePath, newPath)
			if err != nil {
				log.Printf("Error moving duplicate file to deleted files folder: %v", err)
				return
			} else {
				log.Printf("Successfully deleted duplicate file: %s", filePath)
			}
		} else {
			log.Printf("Error inserting new file %s: %v", filePath, result.Error)
		}
	} else {
		log.Printf("Successfully inserted new file: %+v", newFile)
	}
	if mtype == MimeTypeImage {
		if err := handleNewImage(db, filePath, newFile); err != nil {
			log.Printf("Error processing image %s: %v", filePath, err)
		}
	} else if mtype == MimeTypeVideo {
		if err := handleNewVideo(db, filePath, newFile); err != nil {
			log.Printf("Error processing video %s: %v", filePath, err)
		}
	}
}

func handleMovedTo(db *gorm.DB, filePath string) {
	hash, err := generateFileKey(filePath)
	if err != nil {
		log.Printf("Error generating hash for moved file %s: %v", filePath, err)
		return
	}

	var existingFile File
	if err := db.Where("hash = ?", hash).First(&existingFile).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			// If the file doesn't exist in the database, treat it as a new file
			handleCreate(db, filePath)
		} else {
			log.Printf("Error checking for existing file %s: %v", filePath, err)
		}
		return
	}

	// Update the filename if it has changed
	newFilename := filepath.Base(filePath)
	if existingFile.Filename != newFilename {
		if err := db.Model(&existingFile).Update("filename", newFilename).Error; err != nil {
			log.Printf("Error updating moved file %s: %v", filePath, err)
		}
	}
}

func handleRemove(db *gorm.DB, filePath string) {
	filename := filepath.Base(filePath)
	if err := db.Where("filename = ?", filename).Delete(&File{}).Error; err != nil {
		log.Printf("Error deleting removed file %s: %v", filePath, err)
	}
}
