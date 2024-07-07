package files

import (
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"picshow/internal/config"
	"picshow/internal/db"
	"sync"

	"gorm.io/gorm"
)

type Processor struct {
	db      *gorm.DB
	config  *config.Config
	handler *handler
}

func NewProcessor(config *config.Config, db *gorm.DB) *Processor {
	return &Processor{
		db:      db,
		config:  config,
		handler: newHandler(config, db),
	}
}

func (p *Processor) Process() error {
	files, err := os.ReadDir(p.config.FolderPath)
	if err != nil {
		return fmt.Errorf("error reading directory: %w", err)
	}

	var existingHashes []string
	if err := p.db.Model(&db.File{}).Pluck("Hash", &existingHashes).Error; err != nil {
		return fmt.Errorf("error getting existing hashes: %w", err)
	}

	existingHashesMap := make(map[string]struct{})
	for _, hash := range existingHashes {
		existingHashesMap[hash] = struct{}{}
	}

	var wg sync.WaitGroup
	semaphore := make(chan struct{}, 10) // Limit concurrent goroutines

	var mu sync.Mutex
	insertBuffer := make([]db.File, 0, p.config.BatchSize)
	updateBuffer := make([]db.File, 0, p.config.BatchSize)
	deleteBuffer := make([]string, 0, p.config.BatchSize)
	imageBuffer := make([]db.Image, 0, p.config.BatchSize)
	videoBuffer := make([]db.Video, 0, p.config.BatchSize)
	applyBuffers := func() {
		if len(insertBuffer) > 0 {
			if err := p.db.CreateInBatches(insertBuffer, p.config.BatchSize).Error; err != nil {
				log.Printf("Error inserting files in batch: %v", err)
			}
			for _, file := range insertBuffer {
				filePath := filepath.Join(p.config.FolderPath, file.Filename)
				if db.MimeType(file.MimeType) == db.MimeTypeImage {
					if image, err := p.handler.handleNewImage(filePath, file); err != nil {
						log.Printf("Error processing image %s: %v", filePath, err)
					} else {
						imageBuffer = append(imageBuffer, *image)
					}
				} else if db.MimeType(file.MimeType) == db.MimeTypeVideo {
					if video, err := p.handler.handleNewVideo(filePath, file); err != nil {
						log.Printf("Error processing video %s: %v", filePath, err)
					} else {
						videoBuffer = append(videoBuffer, *video)
					}
				}
			}
			insertBuffer = insertBuffer[:0]
		}
		if len(imageBuffer) > 0 {
			if err := p.db.CreateInBatches(imageBuffer, p.config.BatchSize).Error; err != nil {
				log.Printf("Error inserting images in batch: %v", err)
			}
			imageBuffer = imageBuffer[:0]
		}
		if len(videoBuffer) > 0 {
			if err := p.db.CreateInBatches(videoBuffer, p.config.BatchSize).Error; err != nil {
				log.Printf("Error inserting videos in batch: %v", err)
			}
			videoBuffer = videoBuffer[:0]
		}
		if len(updateBuffer) > 0 {
			for _, file := range updateBuffer {
				if err := p.db.Model(&db.File{}).Where("hash = ?", file.Hash).Update("filename", file.Filename).Error; err != nil {
					log.Printf("Error updating file %s: %v", file.Filename, err)
				}
			}
			updateBuffer = updateBuffer[:0]
		}
		if len(deleteBuffer) > 0 {
			if err := p.db.Where("file_id IN (select id from files where hash IN ? )", deleteBuffer).Delete(&db.Image{}).Error; err != nil {
				log.Printf("Error deleting files in batch: %v", err)
			}
			if err := p.db.Where("file_id IN (select id from files where hash IN ? )", deleteBuffer).Delete(&db.Video{}).Error; err != nil {
				log.Printf("Error deleting files in batch: %v", err)
			}
			if err := p.db.Where("hash IN ?", deleteBuffer).Delete(&db.File{}).Error; err != nil {
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

			filePath := filepath.Join(p.config.FolderPath, f.Name())
			hash, err := p.handler.generateFileKey(filePath)
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
				var existingFile db.File
				if err := p.db.Where("hash = ?", hash).First(&existingFile).Error; err != nil {
					log.Printf("Error fetching existing file for hash %s: %v", hash, err)
					return
				}
				if existingFile.Filename != f.Name() {
					updateBuffer = append(updateBuffer, db.File{Hash: hash, Filename: f.Name()})
					if len(updateBuffer) >= p.config.BatchSize {
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
				insertBuffer = append(insertBuffer, db.File{Hash: hash, Filename: f.Name(), Size: fileInfo.Size(), MimeType: mtype.String()})
				if len(insertBuffer) >= p.config.BatchSize {
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
		if len(deleteBuffer) >= p.config.BatchSize {
			applyBuffers()
		}
	}
	applyBuffers() // Process any remaining deletions
	mu.Unlock()

	return nil
}
