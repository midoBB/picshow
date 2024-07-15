package main

import (
	"log"
	"picshow/internal/cache"
	"picshow/internal/config"
	"picshow/internal/files"
	kvdb "picshow/internal/kv"
	"picshow/internal/server"
	"sync"
	"time"
)

func main() {
	runtimeConfig, err := config.LoadConfig()
	if err != nil {
		log.Printf("Error loading config: %v", err)
		log.Println("Starting first-run server...")

		firstRunServer := server.NewFirstRunServer()
		if err := firstRunServer.Start(); err != nil {
			log.Fatalf("Error starting first-run server: %v", err)
		}

		runtimeConfig, err = config.LoadConfig()
		if err != nil {
			log.Fatalf("Error loading config after first-run: %v", err)
		}
	}
	runtimeCache, err := cache.NewCache(runtimeConfig)
	if err != nil {
		log.Fatalf("Error creating cache: %v", err)
	}

	kv, err := kvdb.GetDB(runtimeConfig)
	if err != nil {
		log.Fatalf("Error creating KV repository: %v", err)
	}

	repo := kvdb.NewRepository(kv, runtimeCache)
	// FIXME: Unhardcode the batch size and concurrency and move them to config
	processor := files.NewProcessor(runtimeConfig, repo, 50, 5)
	var wg sync.WaitGroup
	wg.Add(2)

	// Start periodic file processing
	go func() {
		defer wg.Done()

		// Function to run the processor
		runProcessor := func() {
			log.Println("Starting file processing...")
			err := processor.Process()
			if err != nil {
				log.Printf("Error processing files: %v", err)
			} else {
				log.Println("File processing completed successfully.")
			}
		}

		// Run processor immediately on startup
		runProcessor()
		log.Println(repo.GetStats())

		ticker := time.NewTicker(time.Duration(runtimeConfig.RefreshInterval) * time.Hour)
		defer ticker.Stop()

		processingInProgress := false
		var processingMutex sync.Mutex

		for {
			select {
			case <-ticker.C:
				processingMutex.Lock()
				if !processingInProgress {
					processingInProgress = true
					processingMutex.Unlock()

					runProcessor()

					processingMutex.Lock()
					processingInProgress = false
				}
				processingMutex.Unlock()
				if processingInProgress {
					log.Println("Skipping processing cycle: previous cycle still in progress.")
				}
			}
		}
	}()

	// Start the web server
	go func() {
		defer wg.Done()
		server := server.NewServer(runtimeConfig, repo, runtimeCache)
		if err := server.Start(); err != nil {
			log.Fatalf("Error starting server: %v", err)
		}
	}()

	wg.Wait()
}
