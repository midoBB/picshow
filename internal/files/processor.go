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
		handler: newHandler(config),
	}
}

func (p *Processor) Process() error {
	files, err := os.ReadDir(p.config.FolderPath)
	if err != nil {
		return fmt.Errorf("error reading directory: %w", err)
	}
	var existingFiles []db.File
	if err := p.db.Find(&existingFiles).Error; err != nil {
		return fmt.Errorf("error fetching existing files: %w", err)
	}

	existingFilesMap := make(map[string]db.File)
	existingFilesHashesMap := make(map[string]db.File)
	for _, file := range existingFiles {
		existingFilesMap[file.Filename] = file
		existingFilesHashesMap[file.Hash] = file
	}
	for _, file := range files {
		if file.IsDir() {
			continue
		}

		filePath := filepath.Join(p.config.FolderPath, file.Name())
		fileInfo, err := file.Info()
		if err != nil {
			log.Printf("Error getting file info for %s: %v", file.Name(), err)
			continue
		}

		lastModified := fileInfo.ModTime().Unix()

		existingFile, existsByName := existingFilesMap[file.Name()]
		if existsByName && existingFile.LastModified >= lastModified {
			// this should be done by a flag after we compare the number of files with the number in db
			// countImage := int64(0)
			// p.db.Model(&db.Image{}).
			// 	Where("file_id = ? ", existingFile.ID).
			// 	Count(&countImage)
			// countVideo := int64(0)
			// p.db.Model(&db.Video{}).
			// 	Where("file_id = ? ", existingFile.ID).
			// 	Count(&countVideo)
			// if countImage == 0 && countVideo == 0 {
			// 	p.processNewFile(filePath, existingFile, db.MimeType(existingFile.MimeType))
			// }
			delete(existingFilesMap, file.Name())
			continue
		}

		// File is new or has been modified, process it
		hash, err := p.handler.generateFileKey(filePath)
		if err != nil {
			log.Printf("Error generating hash for %s: %v", file.Name(), err)
			continue
		}
		oldFileInfo, existsByHash := existingFilesHashesMap[hash]
		mtype, err := getFileMimeType(filePath)
		if err != nil {
			log.Printf("Error detecting mime type for %s: %v", file.Name(), err)
			continue
		}

		if existsByHash {
			if err := p.db.Model(&db.File{}).Where("hash = ?", hash).Updates(map[string]interface{}{"filename": file.Name(), "last_modified": lastModified}).Error; err != nil {
				log.Printf("Error updating file %s: %v", file.Name(), err)
				continue
			}
			delete(existingFilesMap, oldFileInfo.Filename)
		} else {
			newFile := db.File{
				Hash:         hash,
				Filename:     file.Name(),
				Size:         fileInfo.Size(),
				MimeType:     mtype.String(),
				LastModified: lastModified,
			}
			if err := p.db.Create(&newFile).Error; err != nil {
				if strings.Contains(err.Error(), "UNIQUE constraint failed: files.hash") {
					p.handleDuplicateFile(filePath, file.Name(), hash)
					continue
				}
				log.Printf("Error inserting file %s: %v", file.Name(), err)
				continue
			}

			p.processNewFile(filePath, newFile, mtype)
		}
		delete(existingFilesMap, file.Name())
	}

	// Remove files from DB that no longer exist in the folder
	p.removeNonExistentFiles(existingFilesMap)

	return nil
}

func (p *Processor) handleDuplicateFile(filePath, fileName, hash string) {
	log.Printf("Duplicate hash detected for %s", fileName)

	duplicatesDir := filepath.Join(filepath.Dir(p.config.FolderPath), "duplicates")
	if err := os.MkdirAll(duplicatesDir, 0755); err != nil {
		log.Printf("Error creating duplicates directory: %v", err)
		return
	}

	var originalFile db.File
	if err := p.db.Where("hash = ?", hash).First(&originalFile).Error; err != nil {
		log.Printf("Error fetching original file for hash %s: %v", hash, err)
		return
	}

	originalPath := filepath.Join(p.config.FolderPath, originalFile.Filename)
	originalDuplicatePath := filepath.Join(duplicatesDir, originalFile.Filename)
	if err := utils.CopyFile(originalPath, originalDuplicatePath); err != nil {
		log.Printf("Error copying original file %s: %v", originalFile.Filename, err)
	}

	duplicatePath := filepath.Join(duplicatesDir, fileName)
	if err := os.Rename(filePath, duplicatePath); err != nil {
		log.Printf("Error moving duplicate file %s: %v", fileName, err)
	}
}

func (p *Processor) processNewFile(filePath string, newFile db.File, mtype db.MimeType) {
	switch mtype {
	case db.MimeTypeImage:
		image, err := p.handler.handleNewImage(filePath, newFile)
		if err != nil {
			log.Printf("Error processing image %s: %v", filePath, err)
			// TODO: extract this to a function
			// file is beyond any repair
			if err := os.Remove(filePath); err != nil {
				log.Printf("Error removing file %s: %v", filePath, err)
			}
			if err := p.db.Where("file_id = ?", newFile.ID).Delete(&db.Image{}).Error; err != nil {
				log.Printf("Error deleting image for file %s: %v", newFile.Filename, err)
			}
			if err := p.db.Where("file_id = ?", newFile.ID).Delete(&db.Video{}).Error; err != nil {
				log.Printf("Error deleting video for file %s: %v", newFile.Filename, err)
			}
			if err := p.db.Delete(&newFile).Error; err != nil {
				log.Printf("Error deleting file %s: %v", newFile.Filename, err)
			}
		} else if err := p.db.Create(image).Error; err != nil {
			log.Printf("Error inserting image %s: %v", filePath, err)
		}
	case db.MimeTypeVideo:
		video, err := p.handler.handleNewVideo(filePath, newFile)
		if err != nil {
			log.Printf("Error processing video %s: %v", filePath, err)
			if err := os.Remove(filePath); err != nil {
				log.Printf("Error removing file %s: %v", filePath, err)
			}
			if err := p.db.Where("file_id = ?", newFile.ID).Delete(&db.Image{}).Error; err != nil {
				log.Printf("Error deleting image for file %s: %v", newFile.Filename, err)
			}
			if err := p.db.Where("file_id = ?", newFile.ID).Delete(&db.Video{}).Error; err != nil {
				log.Printf("Error deleting video for file %s: %v", newFile.Filename, err)
			}
			if err := p.db.Delete(&newFile).Error; err != nil {
				log.Printf("Error deleting file %s: %v", newFile.Filename, err)
			}
		} else if err := p.db.Create(video).Error; err != nil {
			log.Printf("Error inserting video %s: %v", filePath, err)
		}
	default:
		if err := os.Remove(filePath); err != nil {
			log.Printf("Error removing file %s: %v", filePath, err)
		}
		if err := p.db.Where("file_id = ?", newFile.ID).Delete(&db.Image{}).Error; err != nil {
			log.Printf("Error deleting image for file %s: %v", newFile.Filename, err)
		}
		if err := p.db.Where("file_id = ?", newFile.ID).Delete(&db.Video{}).Error; err != nil {
			log.Printf("Error deleting video for file %s: %v", newFile.Filename, err)
		}
		if err := p.db.Delete(&newFile).Error; err != nil {
			log.Printf("Error deleting file %s: %v", newFile.Filename, err)
		}
	}
}

func (p *Processor) removeNonExistentFiles(existingFilesMap map[string]db.File) {
	for _, file := range existingFilesMap {
		if err := p.db.Where("file_id = ?", file.ID).Delete(&db.Image{}).Error; err != nil {
			log.Printf("Error deleting image for file %s: %v", file.Filename, err)
		}
		if err := p.db.Where("file_id = ?", file.ID).Delete(&db.Video{}).Error; err != nil {
			log.Printf("Error deleting video for file %s: %v", file.Filename, err)
		}
		if err := p.db.Delete(&file).Error; err != nil {
			log.Printf("Error deleting file %s: %v", file.Filename, err)
		}
	}
}
