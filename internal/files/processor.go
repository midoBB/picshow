package files

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"picshow/internal/config"
	"picshow/internal/database"
	"picshow/internal/utils"
	"strings"
)

type Processor struct {
	repo    *database.Repository
	config  *config.Config
	handler *handler
}

func NewProcessor(config *config.Config, repo *database.Repository) *Processor {
	return &Processor{
		repo:    repo,
		config:  config,
		handler: newHandler(config),
	}
}

func (p *Processor) Process() error {
	files, err := os.ReadDir(p.config.FolderPath)
	if err != nil {
		return fmt.Errorf("error reading directory: %w", err)
	}
	existingFiles, err := p.repo.FindAllFiles()
	if err != nil {
		return fmt.Errorf("error fetching existing files: %w", err)
	}

	existingFilesMap := make(map[string]database.File)
	existingFilesHashesMap := make(map[string]database.File)
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
			existingFile.Filename = file.Name()
			existingFile.LastModified = lastModified
			existingFile.Hash = hash
			if err := p.repo.UpdateFile(&existingFile); err != nil {
				log.Printf("Error updating file %s: %v", file.Name(), err)
				continue
			}
			delete(existingFilesMap, oldFileInfo.Filename)
		} else {
			newFile := database.File{
				Hash:         hash,
				Filename:     file.Name(),
				Size:         fileInfo.Size(),
				MimeType:     mtype.String(),
				LastModified: lastModified,
			}
			if err := p.repo.CreateFile(&newFile); err != nil {
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

	originalFile, err := p.repo.FindFileByHash(hash)
	if err != nil {
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

func (p *Processor) processNewFile(filePath string, newFile database.File, mtype database.MimeType) {
	switch mtype {
	case database.MimeTypeImage:
		image, err := p.handler.handleNewImage(filePath, newFile)
		if err != nil {
			log.Printf("Error processing image %s: %v", filePath, err)
			p.removeInvalidFile(filePath, &newFile)
		} else if err := p.repo.CreateImage(image); err != nil {
			log.Printf("Error inserting image %s: %v", filePath, err)
		}
	case database.MimeTypeVideo:
		video, err := p.handler.handleNewVideo(filePath, newFile)
		if err != nil {
			log.Printf("Error processing video %s: %v", filePath, err)
			p.removeInvalidFile(filePath, &newFile)
		} else if err := p.repo.CreateVideo(video); err != nil {
			log.Printf("Error inserting video %s: %v", filePath, err)
		}
	default:
		p.removeInvalidFile(filePath, &newFile)
	}
}

func (p *Processor) removeInvalidFile(filePath string, file *database.File) {
	if err := os.Remove(filePath); err != nil {
		log.Printf("Error removing file %s: %v", filePath, err)
	}
	if err := p.repo.DeleteFile(file.ID); err != nil {
		log.Printf("Error deleting file %s: %v", file.Filename, err)
	}
}

func (p *Processor) removeNonExistentFiles(existingFilesMap map[string]database.File) {
	for _, file := range existingFilesMap {
		if err := p.repo.DeleteFile(file.ID); err != nil {
			log.Printf("Error deleting file %s: %v", file.Filename, err)
		}
	}
}
