package files

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"picshow/internal/config"
	"picshow/internal/db"
	"strings"
	"time"

	"github.com/illarion/gonotify"
	"gorm.io/gorm"
)

type Watcher struct {
	db      *gorm.DB
	config  *config.Config
	handler *handler
}

func NewWatcher(config *config.Config, db *gorm.DB) *Watcher {
	return &Watcher{
		db:      db,
		config:  config,
		handler: newHandler(config, db),
	}
}

func (w *Watcher) WatchDirectory() error {
	// on startup we skip the count of events equivalent to the number of items in db
	var count int64
	err := w.db.Model(&db.File{}).Count(&count).Error
	if err != nil {
		return fmt.Errorf("error getting count of files: %w", err)
	}
	watcher, err := gonotify.NewDirWatcher(gonotify.IN_CREATE|gonotify.IN_DELETE|gonotify.IN_MOVED_FROM|gonotify.IN_MOVED_TO, w.config.FolderPath)
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
				w.handleCreate(event.Name)
			case event.Mask&gonotify.IN_MOVED_TO == gonotify.IN_MOVED_TO:
				w.handleMovedTo(event.Name)
			case event.Mask&gonotify.IN_DELETE == gonotify.IN_DELETE:
				fallthrough
			case event.Mask&gonotify.IN_MOVED_FROM == gonotify.IN_MOVED_FROM:
				w.handleRemove(event.Name)
			}
		}
	}
}

func (w *Watcher) handleCreate(filePath string) {
	hash, err := w.handler.generateFileKey(filePath)
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
	newFile := db.File{
		Hash:     hash,
		Filename: filepath.Base(filePath),
		Size:     fileInfo.Size(),
		MimeType: mtype.String(),
	}

	result := w.db.Create(&newFile)
	if result.Error != nil {
		if strings.Contains(result.Error.Error(), "UNIQUE constraint failed: files.hash") {
			err = os.Remove(filePath)
			if err != nil {
				log.Printf("Error deleting duplicate file %v", err)
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
	if mtype == db.MimeTypeImage {
		if image, err := w.handler.handleNewImage(filePath, newFile); err != nil {
			log.Printf("Error processing image %s: %v", filePath, err)
		} else {
			w.db.Create(&image)
		}
	} else if mtype == db.MimeTypeVideo {
		if video, err := w.handler.handleNewVideo(filePath, newFile); err != nil {
			log.Printf("Error processing video %s: %v", filePath, err)
		} else {
			w.db.Create(&video)
		}
	}
}

func (w *Watcher) handleMovedTo(filePath string) {
	hash, err := w.handler.generateFileKey(filePath)
	if err != nil {
		log.Printf("Error generating hash for moved file %s: %v", filePath, err)
		return
	}

	var existingFile db.File
	if err := w.db.Where("hash = ?", hash).First(&existingFile).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			// If the file doesn't exist in the database, treat it as a new file
			w.handleCreate(filePath)
		} else {
			log.Printf("Error checking for existing file %s: %v", filePath, err)
		}
		return
	}

	// Update the filename if it has changed
	newFilename := filepath.Base(filePath)
	if existingFile.Filename != newFilename {
		if err := w.db.Model(&existingFile).Update("filename", newFilename).Error; err != nil {
			log.Printf("Error updating moved file %s: %v", filePath, err)
		}
	}
}

func (w *Watcher) handleRemove(filePath string) {
	filename := filepath.Base(filePath)
	if err := w.db.Where("filename = ?", filename).Delete(&db.File{}).Error; err != nil {
		log.Printf("Error deleting removed file %s: %v", filePath, err)
	}
}
