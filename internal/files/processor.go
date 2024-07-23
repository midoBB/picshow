package files

import (
	"bufio"
	"context"
	"fmt"
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
	repo        *kv.Repository
	config      *config.Config
	handler     *handler
	processes   *sync.Map
	tempFiles   *sync.Map
	batchSize   int
	concurrency int
}

func NewProcessor(
	config *config.Config,
	repo *kv.Repository,
	batchSize, concurrency int,
) *Processor {
	log.Println("Creating new Processor instance")
	return &Processor{
		repo:        repo,
		config:      config,
		handler:     newHandler(config),
		batchSize:   batchSize,
		concurrency: concurrency,
		processes:   &sync.Map{},
		tempFiles:   &sync.Map{},
	}
}

func (p *Processor) Process(ctx context.Context) error {
	log.Println("starting processing files")

	// Create a new context that we can cancel
	processCtx, cancelProcess := context.WithCancel(ctx)
	defer cancelProcess()

	// Start a goroutine to handle cancellation
	go func() {
		select {
		case <-ctx.Done():
			log.Println("Received cancellation signal, initiating shutdown")
			cancelProcess()
			p.Shutdown(ctx)
		case <-processCtx.Done():
			return
		}
	}()

	existingFilesMap, existingFilesHashesMap, err := p.repo.FindAllFiles()
	if err != nil {
		log.Printf("error fetching existing files from repository: %v", err)
		return fmt.Errorf("error fetching existing files: %w", err)
	}
	log.Println("fetched existing files from repository")

	processedHashes := &sync.Map{}
	fileChan := make(chan string, p.concurrency)
	errChan := make(chan error, p.concurrency)
	var wg sync.WaitGroup
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
			case <-processCtx.Done():
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
			for filePath := range fileChan {
				if err := p.processFile(filePath, existingFilesMap, existingFilesHashesMap, processedHashes); err != nil {
					errChan <- fmt.Errorf("error processing file %s: %w", filePath, err)
				}
				atomic.AddInt64(&processedFiles, 1)
			}
		}()
	}

	fdCommand, err := findFdCommand()
	if err != nil {
		return fmt.Errorf("error finding fd command: %w", err)
	}
	log.Printf("Using %s command for file discovery", fdCommand)

	// Use fd to stream files
	cmd := exec.CommandContext(processCtx, fdCommand, ".", "-t", "f", "-d", "1", p.config.FolderPath)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("error creating stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("error starting %s command: %w", fdCommand, err)
	}

	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		select {
		case <-processCtx.Done():
			return processCtx.Err()
		case fileChan <- scanner.Text():
		}
	}

	if err := scanner.Err(); err != nil {
		log.Printf("error reading %s output: %v", fdCommand, err)
	}

	if err := cmd.Wait(); err != nil {
		log.Printf("%s command finished with error: %v", fdCommand, err)
	}

	close(fileChan)
	wg.Wait()
	close(errChan)

	// Check for any errors during processing
	for err := range errChan {
		log.Println(err)
	}

	p.removeNonExistentFiles(existingFilesMap)
	p.repo.UpdateFavoriteCount()
	log.Println("completed processing files")
	return nil
}

func findFdCommand() (string, error) {
	possibleCommands := []string{"fd", "fdfind", "fd-find"}

	for _, cmd := range possibleCommands {
		if _, err := exec.LookPath(cmd); err == nil {
			return cmd, nil
		}
	}

	return "", fmt.Errorf("could not find fd command. Please install fd, fdfind, or fd-find")
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

func (p *Processor) processFile(filePath string, existingFilesMap *sync.Map, existingFilesHashesMap *sync.Map, processedHashes *sync.Map) error {
	fileInfo, err := os.Stat(filePath)
	if err != nil {
		return fmt.Errorf("error getting file info for %s: %v", filePath, err)
	}

	lastModified := fileInfo.ModTime().Unix()
	filename := filepath.Base(filePath)

	// Early skipping of unmodified files
	existingFileIDInterface, existsByName := existingFilesMap.Load(filename)
	var existingFile *kv.File
	if existsByName {
		existingFileID, ok := existingFileIDInterface.(uint64)
		if !ok {
			return fmt.Errorf("invalid type for existingFileID for %s", filename)
		}
		existingFile, err = p.repo.GetFileByID(existingFileID)
		if err != nil {
			return fmt.Errorf("error fetching file %s: %v", filename, err)
		}
		if existingFile.LastModified >= lastModified {
			log.Printf("file %s has not been modified since last processing, skipping", filename)
			processedHashes.Store(existingFile.Hash, true)
			existingFilesMap.Delete(filename)
			return nil
		}
	}

	hash, err := p.handler.generateFileKey(filePath)
	if err != nil {
		return fmt.Errorf("error generating hash for %s: %v", filename, err)
	}

	if _, alreadyProcessed := processedHashes.Load(hash); alreadyProcessed {
		log.Printf("found duplicate file: %s (hash: %s)", filename, hash)
		p.handleDuplicateFile(filePath, filename)
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
			return fmt.Errorf("error fetching file %s: %v", filename, err)
		}
		log.Printf("updating existing file record for %s", filename)
		existingFile.Filename = filename
		existingFile.LastModified = lastModified
		if err := p.repo.UpdateFile(existingFile); err != nil {
			return fmt.Errorf("error updating file %s: %v", filename, err)
		}
		existingFilesMap.Delete(existingFile.Filename)
	} else {
		log.Printf("processing new file %s", filename)
		mimeType, err := getFileMimeType(filePath)
		if err != nil {
			return fmt.Errorf("error detecting mime type for %s: %v", filename, err)
		}
		newFile := &kv.File{
			Filename:     filename,
			Hash:         hash,
			LastModified: lastModified,
			MimeType:     string(mimeType),
			CreatedAt:    timestamppb.New(time.Now()),
			Size:         fileInfo.Size(),
		}
		if err := p.processNewFile(filePath, newFile, mimeType); err != nil {
			return fmt.Errorf("error processing new file %s: %v", filename, err)
		}
	}

	processedHashes.Store(hash, true)
	existingFilesMap.Delete(filename)
	return nil
}

func (p *Processor) Shutdown(ctx context.Context) {
	log.Println("initiating graceful shutdown of processor")

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
	case <-ctx.Done():
		log.Println("shutdown context cancelled")
	case <-time.After(utils.SHUTDOWN_TIMER):
		log.Println("processor shutdown timed out")
	}
	log.Println("processor shutdown completed")
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
