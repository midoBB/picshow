package db

import (
	"database/sql"
	_ "embed"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

//go:embed schema.sql
var schema string

func createSchema(dbPath string) error {
	if _, err := os.Stat(dbPath); errors.Is(err, os.ErrNotExist) {
		db, err := sql.Open("sqlite3", dbPath)
		if err != nil {
			return fmt.Errorf("error opening database: %w", err)
		}
		defer db.Close()
		_, err = db.Exec(schema)
		if err != nil {
			return fmt.Errorf("error creating database schema: %w", err)
		}
	}
	return nil
}

func GetDb(dbPath string) (*gorm.DB, error) {
	log.Println(schema)
	dataFolder, exists := os.LookupEnv("$XDG_DATA_HOME")
	if !exists {
		dataFolder = os.Getenv("HOME") + "/.local/share"
	}

	folderPath := filepath.Join(dataFolder, "picshow")
	dbName := filepath.Join(folderPath, "picshow.db")

	err := os.MkdirAll(folderPath, 0755)
	if err != nil {
		return nil, fmt.Errorf("error creating database folder: %w", err)
	}

	err = createSchema(dbName)
	if err != nil {
		return nil, fmt.Errorf("error creating database schema: %w", err)
	}

	newLogger := logger.New(
		log.New(os.Stdout, "\r\n", log.LstdFlags), // io writer
		logger.Config{
			SlowThreshold:             time.Second, // Slow SQL threshold
			LogLevel:                  logger.Info, // Log level
			IgnoreRecordNotFoundError: false,       // Don't ignore ErrRecordNotFound error
			Colorful:                  true,        // Enable color
		},
	)
	db, err := gorm.Open(sqlite.Open(dbName), &gorm.Config{
		Logger: newLogger,
	})
	if err != nil {
		return nil, fmt.Errorf("error opening database: %w", err)
	}
	return db, nil
}
