package files

import (
	"context"
	"fmt"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"picshow/internal/config"
	"picshow/internal/kv"
	"picshow/internal/utils"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"
)

type Processor struct {
	repo         *kv.Repository
	config       *config.Config
	handler      *handler
	batchSize    int
	concurrency  int
	ctx          context.Context
	cancel       context.CancelFunc
	shutdownChan chan struct{}
	processes    *sync.Map
	tempFiles    *sync.Map
}

func NewProcessor(
	config *config.Config,
	repo *kv.Repository,
	batchSize, concurrency int,
	ctx context.Context,
	cancel context.CancelFunc,
) *Processor {
	log.Println("Creating new Processor instance")
	return &Processor{
		repo:         repo,
		config:       config,
		handler:      newHandler(config),
		batchSize:    batchSize,
		concurrency:  concurrency,
		ctx:          ctx,
		cancel:       cancel,
		shutdownChan: make(chan struct{}),
		processes:    &sync.Map{},
		tempFiles:    &sync.Map{},
	}
}

func (p *Processor) handleDuplicateFile(filePath, filename string) {
	log.Printf("duplicate hash detected for %s", filename)

	duplicatesDir := filepath.Join(filepath.Dir(p.config.FolderPath), "duplicates")
	if err := os.MkdirAll(duplicatesDir, 0755); err != nil {
		log.Printf("error creating duplicates directory: %v", err)
		return
	}

	duplicatePath := filepath.Join(duplicatesDir, filename)
	if err := os.Rename(filePath, duplicatePath); err != nil {
		log.Printf("error moving duplicate file %s: %v", filename, err)
	}
}

func (p *Processor) Process() error {
	log.Println("starting processing files")
	defer close(p.shutdownChan)
	defer p.cancel()

	existingFilesMap, existingFilesHashesMap, err := p.repo.FindAllFiles()
	if err != nil {
		log.Printf("error fetching existing files from repository: %v", err)
		return fmt.Errorf("error fetching existing files: %w", err)
	}
	log.Println("fetched existing files from repository")

	processedHashes := &sync.Map{}
	fileChan := make(chan fs.DirEntry, p.concurrency)
	errChan := make(chan error, p.concurrency)
	var wg sync.WaitGroup
	// Add a counter for processed files
	var processedFiles int64

	// Start a goroutine to log the number of processed files every 10 seconds
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()

		for {
			select {
			case <-ticker.C:
				processed := atomic.LoadInt64(&processedFiles)
				log.Printf("Processed %d files in the last 10 seconds", processed)
				atomic.StoreInt64(&processedFiles, 0)
			case <-p.ctx.Done():
				processed := atomic.LoadInt64(&processedFiles)
				log.Printf("Processed %d files in the last 10 seconds", processed)
				return
			}
		}
	}()
	// Start worker goroutines
	for i := 0; i < p.concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for file := range fileChan {
				if err := p.processFile(file, existingFilesMap, existingFilesHashesMap, processedHashes); err != nil {
					errChan <- fmt.Errorf("error processing file %s: %w", file.Name(), err)
				}
				atomic.AddInt64(&processedFiles, 1)
			}
		}()
	}

	// Walk the directory and send files to the channel
	err = filepath.WalkDir(p.config.FolderPath, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			log.Printf("error accessing path %q: %v\n", path, err)
			return filepath.SkipDir
		}

		// If it's a directory and not the root directory, skip it
		if d.IsDir() && path != p.config.FolderPath {
			return filepath.SkipDir
		}

		// Skip the root directory itself
		if path == p.config.FolderPath {
			return nil
		}

		// At this point, we're dealing with a file in the root directory
		select {
		case <-p.ctx.Done():
			return p.ctx.Err()
		case fileChan <- d:
			return nil
		}
	})

	close(fileChan)
	wg.Wait()
	close(errChan)

	// Check for any errors during processing
	for err := range errChan {
		log.Println(err)
	}

	if err != nil {
		log.Printf("error walking directory: %v", err)
		return err
	}

	p.removeNonExistentFiles(existingFilesMap)
	log.Println("completed processing files")
	return nil
}

func (p *Processor) processFile(file os.DirEntry, existingFilesMap *sync.Map, existingFilesHashesMap *sync.Map, processedHashes *sync.Map) error {
	filePath := filepath.Join(p.config.FolderPath, file.Name())
	fileInfo, err := file.Info()
	if err != nil {
		return fmt.Errorf("error getting file info for %s: %v", file.Name(), err)
	}

	lastModified := fileInfo.ModTime().Unix()

	// Early skipping of unmodified files
	existingFileIDInterface, existsByName := existingFilesMap.Load(file.Name())
	var existingFile *kv.File
	if existsByName {
		existingFileID, ok := existingFileIDInterface.(uint64)
		if !ok {
			return fmt.Errorf("invalid type for existingFileID for %s", file.Name())
		}
		existingFile, err = p.repo.GetFileByID(existingFileID)
		if err != nil {
			return fmt.Errorf("error fetching file %s: %v", file.Name(), err)
		}
		if existingFile.LastModified >= lastModified {
			log.Printf("file %s has not been modified since last processing, skipping", file.Name())
			processedHashes.Store(existingFile.Hash, true)
			existingFilesMap.Delete(file.Name())
			return nil
		}
	}

	hash, err := p.handler.generateFileKey(filePath)
	if err != nil {
		return fmt.Errorf("error generating hash for %s: %v", file.Name(), err)
	}

	if _, alreadyProcessed := processedHashes.Load(hash); alreadyProcessed {
		log.Printf("found duplicate file: %s (hash: %s)", file.Name(), hash)
		p.handleDuplicateFile(filePath, file.Name())
		return nil
	}

	existingFileIDInterface, existsByHash := existingFilesHashesMap.Load(hash)
	if existsByHash {
		existingFileID, ok := existingFileIDInterface.(uint64)
		if !ok {
			return fmt.Errorf("invalid type for existingFileID for hash %s", hash)
		}
		existingFile, err = p.repo.GetFileByID(existingFileID)
		if err != nil {
			return fmt.Errorf("error fetching file %s: %v", file.Name(), err)
		}
		log.Printf("updating existing file record for %s", file.Name())
		existingFile.Filename = file.Name()
		existingFile.LastModified = lastModified
		if err := p.repo.UpdateFile(existingFile); err != nil {
			return fmt.Errorf("error updating file %s: %v", file.Name(), err)
		}
		existingFilesMap.Delete(existingFile.Filename)
	} else {
		log.Printf("processing new file %s", file.Name())
		mimeType, err := getFileMimeType(filePath)
		if err != nil {
			return fmt.Errorf("error detecting mime type for %s: %v", file.Name(), err)
		}
		newFile := &kv.File{
			Filename:     file.Name(),
			Hash:         hash,
			LastModified: lastModified,
			MimeType:     string(mimeType),
			CreatedAt:    timestamppb.New(time.Now()),
			Size:         fileInfo.Size(),
		}
		if err := p.processNewFile(filePath, newFile, mimeType); err != nil {
			return fmt.Errorf("error processing new file %s: %v", file.Name(), err)
		}
	}

	processedHashes.Store(hash, true)
	existingFilesMap.Delete(file.Name())
	return nil
}

func (p *Processor) Shutdown() {
	log.Println("initiating graceful shutdown of processor")
	p.cancel()

	// Terminate external processes
	p.processes.Range(func(key, value interface{}) bool {
		cmd := value.(*exec.Cmd)
		if cmd.Process != nil {
			log.Printf("terminating process: %v", cmd.Args)
			if err := cmd.Process.Kill(); err != nil {
				log.Printf("error killing process: %v", err)
			}
		}
		return true
	})

	// Clean up temporary files
	p.tempFiles.Range(func(key, value interface{}) bool {
		filePath := value.(string)
		log.Printf("removing temporary file: %s", filePath)
		if err := os.Remove(filePath); err != nil {
			log.Printf("error removing temporary file: %v", err)
		}
		return true
	})
	select {
	case <-p.shutdownChan:
		log.Println("processor shutdown completed")
	case <-time.After(utils.SHUTDOWN_TIMER):
		log.Println("processor shutdown timed out")
	}
}

func (p *Processor) processNewFile(filePath string, newFile *kv.File, mimeType utils.MimeType) error {
	switch mimeType {
	case utils.MimeTypeImage:
		image, err := p.handler.handleNewImage(p, filePath)
		if err != nil {
			return fmt.Errorf("error processing image %s: %w", filePath, err)
		}
		newFile.Media = &kv.File_Image{Image: image}
	case utils.MimeTypeVideo:
		video, err := p.handler.handleNewVideo(p, filePath)
		if err != nil {
			return fmt.Errorf("error processing video %s: %w", filePath, err)
		}
		newFile.Media = &kv.File_Video{Video: video}
	default:
		return fmt.Errorf("unsupported file type for %s", filePath)
	}
	return p.repo.AddFile(newFile)
}

func (p *Processor) removeNonExistentFiles(existingFilesMap *sync.Map) {
	log.Println("removing non-existent files from repository")
	existingFilesMap.Range(func(key, value interface{}) bool {
		filename, _ := key.(string)
		fileID, _ := value.(uint64)
		if err := p.repo.DeleteFile(fileID); err != nil {
			log.Printf("error deleting file %s: %v", filename, err)
		}
		return true
	})
}
