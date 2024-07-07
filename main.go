package main

import (
	"log"
	"picshow/internal/config"
	"picshow/internal/db"
	"picshow/internal/files"
	"picshow/internal/server"
	"sync"
	"time"
)

func main() {
	runtimeConfig, err := config.LoadConfig()
	if err != nil {
		log.Fatalf("Error loading config: %v", err)
	}
	db, err := db.GetDb()
	if err != nil {
		log.Fatalf("Error connecting to database: %v", err)
	}

	processor := files.NewProcessor(runtimeConfig, db)
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
		server := server.NewServer(runtimeConfig, db)
		if err := server.Start(); err != nil {
			log.Fatalf("Error starting server: %v", err)
		}
	}()

	wg.Wait()
}
