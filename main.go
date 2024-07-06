package main

import (
	"log"
	"picshow/internal/config"
	"picshow/internal/db"
	"picshow/internal/files"
	"picshow/internal/server"
	"sync"
)

func main() {
	config, err := config.LoadConfig()
	if err != nil {
		log.Fatalf("Error loading config: %v", err)
	}
	db, err := db.GetDb()
	if err != nil {
		log.Fatalf("Error connecting to database: %v", err)
	}

	err = files.NewProcessor(config, db).Process()
	if err != nil {
		log.Fatalf("Error processing files: %v", err)
	}

	log.Println("Initial file processing completed successfully.")

	var wg sync.WaitGroup
	wg.Add(2)

	// Start the file watcher
	go func() {
		defer wg.Done()
		err := files.NewWatcher(config, db).WatchDirectory()
		if err != nil {
			log.Fatalf("Error watching directory: %v", err)
		}
	}()

	// Start the web server
	go func() {
		defer wg.Done()
		server := server.NewServer(config, db)
		if err := server.Start(); err != nil {
			log.Fatalf("Error starting server: %v", err)
		}
	}()

	wg.Wait()
}
