package files

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"picshow/internal/config"
	"picshow/internal/db"
	"picshow/internal/utils"
	"strings"

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

	for _, file := range files {
		if file.IsDir() {
			continue
		}

		filePath := filepath.Join(p.config.FolderPath, file.Name())
		hash, err := p.handler.generateFileKey(filePath)
		if err != nil {
			log.Printf("Error generating hash for %s: %v", file.Name(), err)
			continue
		}

		fileInfo, err := file.Info()
		if err != nil {
			log.Printf("Error getting file info for %s: %v", file.Name(), err)
			continue
		}

		if _, exists := existingHashesMap[hash]; exists {
			// File exists, update filename if necessary
			var existingFile db.File
			if err := p.db.Where("hash = ?", hash).First(&existingFile).Error; err != nil {
				log.Printf("Error fetching existing file for hash %s: %v", hash, err)
				continue
			}
			if existingFile.Filename != file.Name() {
				if err := p.db.Model(&db.File{}).Where("hash = ?", hash).Update("filename", file.Name()).Error; err != nil {
					log.Printf("Error updating file %s: %v", file.Name(), err)
				}
			}
			delete(existingHashesMap, hash)
		} else {
			mtype, err := getFileMimeType(filePath)
			if err != nil {
				log.Printf("Error detecting mime type for %s: %v", file.Name(), err)
				continue
			}

			// New file, insert it
			newFile := db.File{Hash: hash, Filename: file.Name(), Size: fileInfo.Size(), MimeType: mtype.String()}
			if err := p.db.Create(&newFile).Error; err != nil {
				if strings.Contains(err.Error(), "UNIQUE constraint failed: files.hash") {
					log.Printf("Duplicate hash detected for %s: %v", file.Name(), err)
					log.Printf("Duplicate hash detected for %s", file.Name())

					// Create duplicates directory if it doesn't exist
					duplicatesDir := filepath.Join(filepath.Dir(p.config.FolderPath), "duplicates")
					if err := os.MkdirAll(duplicatesDir, 0755); err != nil {
						log.Printf("Error creating duplicates directory: %v", err)
						continue
					}

					// Get the original file
					var originalFile db.File
					if err := p.db.Where("hash = ?", hash).First(&originalFile).Error; err != nil {
						log.Printf("Error fetching original file for hash %s: %v", hash, err)
						continue
					}

					// Copy the original file to the duplicates directory
					originalPath := filepath.Join(p.config.FolderPath, originalFile.Filename)
					originalDuplicatePath := filepath.Join(duplicatesDir, originalFile.Filename)
					if err := utils.CopyFile(originalPath, originalDuplicatePath); err != nil {
						log.Printf("Error copying original file %s: %v", originalFile.Filename, err)
					}

					// Move the duplicate file to the duplicates directory
					duplicatePath := filepath.Join(duplicatesDir, file.Name())
					if err := os.Rename(filePath, duplicatePath); err != nil {
						log.Printf("Error moving duplicate file %s: %v", file.Name(), err)
					}
					continue
				}
				log.Printf("Error inserting file %s: %v", file.Name(), err)
				continue
			}

			// Process new file based on its type
			if mtype == db.MimeTypeImage {
				image, err := p.handler.handleNewImage(filePath, newFile)
				if err != nil {
					log.Printf("Error processing image %s: %v", filePath, err)
				} else {
					if err := p.db.Create(image).Error; err != nil {
						log.Printf("Error inserting image %s: %v", filePath, err)
					}
				}
			} else if mtype == db.MimeTypeVideo {
				video, err := p.handler.handleNewVideo(filePath, newFile)
				if err != nil {
					log.Printf("Error processing video %s: %v", filePath, err)
				} else {
					if err := p.db.Create(video).Error; err != nil {
						log.Printf("Error inserting video %s: %v", filePath, err)
					}
				}
			}
		}
	}

	// Remove files from DB that no longer exist in the folder
	for hash := range existingHashesMap {
		if err := p.db.Where("file_id IN (SELECT id FROM files WHERE hash = ?)", hash).Delete(&db.Image{}).Error; err != nil {
			log.Printf("Error deleting image for hash %s: %v", hash, err)
		}
		if err := p.db.Where("file_id IN (SELECT id FROM files WHERE hash = ?)", hash).Delete(&db.Video{}).Error; err != nil {
			log.Printf("Error deleting video for hash %s: %v", hash, err)
		}
		if err := p.db.Where("hash = ?", hash).Delete(&db.File{}).Error; err != nil {
			log.Printf("Error deleting file for hash %s: %v", hash, err)
		}
	}

	return nil
}
