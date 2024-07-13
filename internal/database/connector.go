package database

import (
	"database/sql"
	_ "embed"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"picshow/internal/config"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

//go:embed schema.sql
var schema string

func createSchema(dbPath string) error {
	if _, err := os.Stat(dbPath); errors.Is(err, os.ErrNotExist) {
		db, err := sql.Open("sqlite", dbPath)
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

func GetDb(config *config.Config) (*gorm.DB, error) {
	dbName := filepath.Join(config.DBPath, "picshow.db")
	err := os.MkdirAll(config.DBPath, 0755)
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
			SlowThreshold:             time.Second,  // Slow SQL threshold
			LogLevel:                  logger.Error, // Log level
			IgnoreRecordNotFoundError: true,         // Don't ignore ErrRecordNotFound error
			Colorful:                  true,         // Enable color
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
