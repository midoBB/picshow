package main

import (
	"log"
	"picshow/internal/config"
	"picshow/internal/db"
	"picshow/internal/files"
)

func main() {
	config, err := config.LoadConfig()
	if err != nil {
		log.Fatalf("Error loading config: %v", err)
	}
	db, err := db.GetDb(config.DbPath)
	if err != nil {
		log.Fatalf("Error connecting to database: %v", err)
	}

	err = files.NewProcessor(config, db).Process()
	if err != nil {
		log.Fatalf("Error processing files: %v", err)
	}

	log.Println("Initial file processing completed successfully.")

	err = files.NewWatcher(config, db).WatchDirectory()
	if err != nil {
		log.Fatalf("Error watching directory: %v", err)
	}
}
