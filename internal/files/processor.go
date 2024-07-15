package files

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"picshow/internal/config"
	"picshow/internal/kv"
	"picshow/internal/utils"
	"sync"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"
)

type Processor struct {
	repo                   *kv.Repository
	config                 *config.Config
	handler                *handler
	batchSize              int
	concurrency            int
	existingFilesMap       *sync.Map
	existingFilesHashesMap *sync.Map
}

func NewProcessor(config *config.Config, repo *kv.Repository, batchSize, concurrency int) *Processor {
	log.Println("Creating new Processor instance")
	return &Processor{
		repo:        repo,
		config:      config,
		handler:     newHandler(config),
		batchSize:   batchSize,
		concurrency: concurrency,
	}
}

/*
	func (p *Processor) Process() error {
		log.Println("Starting processing files")
		files, err := os.ReadDir(p.config.FolderPath)
		if err != nil {
			log.Printf("Error reading directory %s: %v", p.config.FolderPath, err)
			return fmt.Errorf("error reading directory: %w", err)
		}
		log.Printf("Found %d files in directory %s", len(files), p.config.FolderPath)
		existingFilesMap, existingFilesHashesMap, err := p.repo.FindAllFiles()
		if err != nil {
			log.Printf("Error fetching existing files from repository: %v", err)
			return fmt.Errorf("error fetching existing files: %w", err)
		}
		log.Println("Fetched existing files from repository")

		processedHashes := make(map[string]bool)

		for _, file := range files {
			if file.IsDir() {
				log.Printf("Skipping directory %s", file.Name())
				continue
			}

			filePath := filepath.Join(p.config.FolderPath, file.Name())
			fileInfo, err := file.Info()
			if err != nil {
				log.Printf("Error getting file info for %s: %v", file.Name(), err)
				continue
			}

			lastModified := fileInfo.ModTime().Unix()

			// Early skipping of unmodified files
			existingFileID, existsByName := existingFilesMap[file.Name()]
			existingFile, err := p.repo.GetFileByID(existingFileID)
			if existsByName {
				if err != nil {
					log.Printf("Error fetching file %s: %v", file.Name(), err)
					continue
				}
				if existingFile.LastModified >= lastModified {
					log.Printf("File %s has not been modified since last processing, skipping", file.Name())
					processedHashes[existingFile.Hash] = true
					delete(existingFilesMap, file.Name())
					continue
				}
			}

			hash, err := p.handler.generateFileKey(filePath)
			if err != nil {
				log.Printf("Error generating hash for %s: %v", file.Name(), err)
				continue
			}

			if _, alreadyProcessed := processedHashes[hash]; alreadyProcessed {
				log.Printf("Found duplicate file: %s (hash: %s)", file.Name(), hash)
				p.handleDuplicateFile(filePath, file.Name(), hash)
				continue
			}

			existingFileID, existsByHash := existingFilesHashesMap[hash]
			if existsByHash {
				existingFile, err := p.repo.GetFileByID(existingFileID)
				if err != nil {
					log.Printf("Error fetching file %s: %v", file.Name(), err)
					continue
				}

				log.Printf("Updating existing file record for %s", file.Name())
				existingFile.Filename = file.Name()
				existingFile.LastModified = lastModified
				if err := p.repo.UpdateFile(existingFile); err != nil {
					log.Printf("Error updating file %s: %v", file.Name(), err)
					continue
				}
				delete(existingFilesMap, existingFile.Filename)
			} else {
				log.Printf("Processing new file %s", file.Name())
				mtype, err := getFileMimeType(filePath)
				if err != nil {
					log.Printf("Error detecting mime type for %s: %v", file.Name(), err)
					continue
				}

				newFile := &kv.File{
					Filename:     file.Name(),
					Hash:         hash,
					LastModified: lastModified,
					MimeType:     string(mtype),
					CreatedAt:    timestamppb.New(time.Now()),
					Size:         fileInfo.Size(),
				}
				if err := p.processNewFile(filePath, newFile, mtype); err != nil {
					log.Printf("Error processing new file %s: %v", file.Name(), err)
					continue
				}
			}

			processedHashes[hash] = true
			delete(existingFilesMap, file.Name())
		}

		p.removeNonExistentFiles(existingFilesMap)
		log.Println("Completed processing files")
		return nil
	}
*/
func (p *Processor) Process() error {
	log.Println("Starting processing files")
	files, err := os.ReadDir(p.config.FolderPath)
	if err != nil {
		log.Printf("Error reading directory %s: %v", p.config.FolderPath, err)
		return fmt.Errorf("error reading directory: %w", err)
	}
	log.Printf("Found %d files in directory %s", len(files), p.config.FolderPath)

	existingFilesMap, existingFilesHashesMap, err := p.repo.FindAllFiles()
	if err != nil {
		log.Printf("Error fetching existing files from repository: %v", err)
		return fmt.Errorf("error fetching existing files: %w", err)
	}

	// Convert regular maps to sync.Maps
	p.existingFilesMap = &sync.Map{}
	p.existingFilesHashesMap = &sync.Map{}
	for k, v := range existingFilesMap {
		p.existingFilesMap.Store(k, v)
	}
	for k, v := range existingFilesHashesMap {
		p.existingFilesHashesMap.Store(k, v)
	}
	log.Println("Fetched existing files from repository")

	// Create a channel to receive batches of files
	batchChan := make(chan []os.DirEntry)

	// Start worker goroutines
	var wg sync.WaitGroup
	errChan := make(chan error, p.concurrency)

	for i := 0; i < p.concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for batch := range batchChan {
				if err := p.processBatch(batch, existingFilesMap, existingFilesHashesMap); err != nil {
					errChan <- err
					return
				}
			}
		}()
	}

	// Send batches of files to the channel
	go func() {
		for i := 0; i < len(files); i += p.batchSize {
			end := i + p.batchSize
			if end > len(files) {
				end = len(files)
			}
			batchChan <- files[i:end]
		}
		close(batchChan)
	}()

	// Wait for all workers to finish
	wg.Wait()
	close(errChan)

	// Check for any errors
	for err := range errChan {
		if err != nil {
			return err
		}
	}

	p.removeNonExistentFiles()
	log.Println("Completed processing files")
	return nil
}

func (p *Processor) processBatch(files []os.DirEntry) error {
	processedHashes := make(map[string]bool)
	newFiles := make([]*kv.File, 0)
	updatedFiles := make([]*kv.File, 0)

	for _, file := range files {
		if file.IsDir() {
			log.Printf("Skipping directory %s", file.Name())
			continue
		}

		filePath := filepath.Join(p.config.FolderPath, file.Name())
		fileInfo, err := file.Info()
		if err != nil {
			log.Printf("Error getting file info for %s: %v", file.Name(), err)
			continue
		}

		lastModified := fileInfo.ModTime().Unix()

		// Early skipping of unmodified files
		existingFileIDInterface, existsByName := p.existingFilesMap.Load(file.Name())
		var existingFileID uint64
		if existsByName {
			existingFileID = existingFileIDInterface.(uint64)
		}
		existingFile, err := p.repo.GetFileByID(existingFileID)
		if existsByName {
			if err != nil {
				log.Printf("Error fetching file %s: %v", file.Name(), err)
				continue
			}
			if existingFile.LastModified >= lastModified {
				log.Printf("File %s has not been modified since last processing, skipping", file.Name())
				processedHashes[existingFile.Hash] = true
				p.existingFilesMap.Delete(file.Name())
				continue
			}
		}

		hash, err := p.handler.generateFileKey(filePath)
		if err != nil {
			log.Printf("Error generating hash for %s: %v", file.Name(), err)
			continue
		}

		if _, alreadyProcessed := processedHashes[hash]; alreadyProcessed {
			log.Printf("Found duplicate file: %s (hash: %s)", file.Name(), hash)
			p.handleDuplicateFile(filePath, file.Name(), hash)
			continue
		}

		existingFileIDInterface, existsByHash := p.existingFilesHashesMap.Load(hash)
		if existsByHash {
			existingFileID = existingFileIDInterface.(uint64)
			existingFile, err := p.repo.GetFileByID(existingFileID)
			if err != nil {
				log.Printf("Error fetching file %s: %v", file.Name(), err)
				continue
			}

			log.Printf("Updating existing file record for %s", file.Name())
			existingFile.Filename = file.Name()
			existingFile.LastModified = lastModified
			updatedFiles = append(updatedFiles, existingFile)
			p.existingFilesMap.Delete(existingFile.Filename)
		} else {
			log.Printf("Processing new file %s", file.Name())
			mtype, err := getFileMimeType(filePath)
			if err != nil {
				log.Printf("Error detecting mime type for %s: %v", file.Name(), err)
				continue
			}

			newFile := &kv.File{
				Filename:     file.Name(),
				Hash:         hash,
				LastModified: lastModified,
				MimeType:     string(mtype),
				CreatedAt:    timestamppb.New(time.Now()),
				Size:         fileInfo.Size(),
			}

			// Process the new file (e.g., handle images or videos)
			if err := p.processNewFileMedia(filePath, newFile, mtype); err != nil {
				log.Printf("Error processing new file %s: %v", file.Name(), err)
				continue
			}

			newFiles = append(newFiles, newFile)
		}

		processedHashes[hash] = true
		p.existingFilesMap.Delete(file.Name())
	}

	// Add new files in batch
	if len(newFiles) > 0 {
		if err := p.repo.AddBatch(newFiles); err != nil {
			return fmt.Errorf("error adding batch of new files: %w", err)
		}
	}

	// Update existing files in batch
	if len(updatedFiles) > 0 {
		if err := p.repo.UpdateBatch(updatedFiles); err != nil {
			return fmt.Errorf("error updating batch of existing files: %w", err)
		}
	}

	return nil
}

// This function handles the media-specific processing (image or video)
func (p *Processor) processNewFileMedia(filePath string, newFile *kv.File, mimeType utils.MimeType) error {
	switch mimeType {
	case utils.MimeTypeImage:
		image, err := p.handler.handleNewImage(filePath)
		if err != nil {
			return fmt.Errorf("error processing image %s: %w", filePath, err)
		}
		newFile.Media = &kv.File_Image{Image: image}
	case utils.MimeTypeVideo:
		video, err := p.handler.handleNewVideo(filePath)
		if err != nil {
			return fmt.Errorf("error processing video %s: %w", filePath, err)
		}
		newFile.Media = &kv.File_Video{Video: video}
	default:
		return fmt.Errorf("unsupported file type for %s", filePath)
	}
	return nil
}

func (p *Processor) handleDuplicateFile(filePath, fileName, hash string) {
	log.Printf("Duplicate hash detected for %s", fileName)

	duplicatesDir := filepath.Join(filepath.Dir(p.config.FolderPath), "duplicates")
	if err := os.MkdirAll(duplicatesDir, 0755); err != nil {
		log.Printf("Error creating duplicates directory: %v", err)
		return
	}

	duplicatePath := filepath.Join(duplicatesDir, fileName)
	if err := os.Rename(filePath, duplicatePath); err != nil {
		log.Printf("Error moving duplicate file %s: %v", fileName, err)
	}
}

// func (p *Processor) processNewFile(filePath string, newFile *kv.File, mimeType utils.MimeType) error {
// 	log.Printf("Processing new file %s of mime type %s", newFile.Filename, mimeType)
// 	switch mimeType {
// 	case utils.MimeTypeImage:
// 		image, err := p.handler.handleNewImage(filePath)
// 		if err != nil {
// 			p.removeInvalidFile(filePath, newFile)
// 			return fmt.Errorf("error processing image %s: %w", filePath, err)
// 		}
// 		newFile.Media = &kv.File_Image{Image: image}
// 	case utils.MimeTypeVideo:
// 		video, err := p.handler.handleNewVideo(filePath)
// 		if err != nil {
// 			p.removeInvalidFile(filePath, newFile)
// 			return fmt.Errorf("error processing video %s: %w", filePath, err)
// 		}
// 		newFile.Media = &kv.File_Video{Video: video}
// 	default:
// 		p.removeInvalidFile(filePath, newFile)
// 		return fmt.Errorf("unsupported file type for %s", filePath)
// 	}
//
// 	if err := p.repo.AddFile(newFile); err != nil {
// 		return fmt.Errorf("error adding file %s to repository: %w", filePath, err)
// 	}
// 	log.Printf("Successfully processed and added file %s", newFile.Filename)
// 	return nil
// }

// func (p *Processor) removeInvalidFile(filePath string, file *kv.File) {
// 	log.Printf("Removing invalid file %s", filePath)
// 	if err := os.Remove(filePath); err != nil {
// 		log.Printf("Error removing file %s: %v", filePath, err)
// 	}
// 	if err := p.repo.DeleteFile(file.Id); err != nil {
// 		log.Printf("Error deleting file %s: %v", file.Filename, err)
// 	}
// }

func (p *Processor) removeNonExistentFiles() {
	log.Println("Removing non-existent files from repository")
	p.existingFilesMap.Range(func(key, value interface{}) bool {
		fileName := key.(string)
		fileID := value.(uint64)
		if err := p.repo.DeleteFile(fileID); err != nil {
			log.Printf("Error deleting file %s: %v", fileName, err)
		}
		return true
	})
}
