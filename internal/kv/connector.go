package kv

import (
	"fmt"
	"os"
	"path/filepath"
	"picshow/internal/config"
	"time"

	log "github.com/sirupsen/logrus"

	"github.com/dgraph-io/badger/v2"
	"github.com/dgraph-io/badger/v2/options"
	"google.golang.org/protobuf/proto"
)


func GetDB(config *config.Config) (*badger.DB, error) {
	err := os.MkdirAll(config.DBPath, 0755)
	if err != nil {
		return nil, fmt.Errorf("error creating database folder: %w", err)
	}
	shouldInitialize := isNewDatabase(config.DBPath)
	log.WithFields(log.Fields{
		"dbPath": config.DBPath,
	}).Debug("Opening Badger database")
	opts := getDBOpts(config) // 16 MB value log file
	db, err := badger.Open(opts)
	if err != nil {
		log.WithError(err).Error("Failed to open Badger database")
		return nil, fmt.Errorf("failed to open Badger database: %w", err)
	}
	if shouldInitialize {
		err = initializeDB(db)
		if err != nil {
			log.WithError(err).Error("Failed to initialize Stats")
			db.Close()
			return nil, fmt.Errorf("failed to initialize Stats: %w", err)
		}
	}
	log.Info("Successfully opened Badger database")
	return db, nil
}

func getDBOpts(config *config.Config) badger.Options {
	opts := badger.DefaultOptions(config.DBPath).
		WithNumMemtables(1).
		WithSyncWrites(true).
		WithLogger(log.StandardLogger()).
		WithLoggingLevel(badger.WARNING).
		WithNumLevelZeroTables(1).
		WithNumLevelZeroTablesStall(2).
		WithValueLogLoadingMode(options.FileIO).
		WithTableLoadingMode(options.FileIO).
		WithNumCompactors(2).
		WithKeepL0InMemory(false).
		WithCompression(options.None).
		WithValueLogFileSize(16 << 20)
	return opts
}

func isNewDatabase(dbPath string) bool {
	// Check if the MANIFEST file exists, which is created when the database is first initialized
	_, err := os.Stat(filepath.Join(dbPath, "MANIFEST"))
	return os.IsNotExist(err)
}

func initializeDB(db *badger.DB) error {
	log.Debug("Initializing database")
	stats := &Stats{
		Count:         0,
		ImageCount:    0,
		VideoCount:    0,
		FavoriteCount: 0,
	}

	statsData, err := proto.Marshal(stats)
	if err != nil {
		log.WithError(err).Error("Failed to marshal initial Stats")
		return fmt.Errorf("failed to marshal initial Stats: %w", err)
	}

	err = db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(statsKey), statsData)
	})
	if err != nil {
		log.WithError(err).Error("Failed to set initial Stats in database")
		return fmt.Errorf("failed to set initial Stats in database: %w", err)
	}
	fileIds := &FileList{
		Ids:          []uint64{},
		ImageFileIds: []uint64{},
		VideoFileIds: []uint64{},
	}
	fileIdsData, err := proto.Marshal(fileIds)
	if err != nil {
		log.WithError(err).Error("Failed to marshal initial FileList")
		return fmt.Errorf("failed to marshal initial FileList: %w", err)
	}

	err = db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(allFilesKey), fileIdsData)
	})
	if err != nil {
		log.WithError(err).Error("Failed to set initial FileList in database")
		return fmt.Errorf("failed to set initial FileList in database: %w", err)
	}
	return nil
}

func BackupDB(db *badger.DB, config *config.Config, deleteOld bool) error {
	backupPath := config.BackupFolderPath
	if err := os.MkdirAll(backupPath, 0755); err != nil {
		log.WithError(err).Error("Failed to create backup folder")
		return fmt.Errorf("failed to create backup folder: %w", err)
	}
	timestamp := time.Now().Format(time.DateOnly)
	backupFile := filepath.Join(backupPath, fmt.Sprintf("backup_%s.bak", timestamp))

	// Open the backup file
	f, err := os.Create(backupFile)
	if err != nil {
		return fmt.Errorf("failed to create backup file: %w", err)
	}
	defer f.Close()
	_, err = db.Backup(f, 0)
	if err != nil {
		log.WithError(err).Error("Failed to backup database")
		return fmt.Errorf("failed to backup database: %w", err)
	}
	log.WithFields(log.Fields{
		"backupFile": backupFile,
	}).Info("Database backup completed successfully")
	if deleteOld {
		// delete the old backup files
		backupFiles, err := filepath.Glob(filepath.Join(backupPath, "backup_*.bak"))
		if err != nil {
			log.WithError(err).Warn("Failed to find old backup files")
		}
		for _, file := range backupFiles {
			if file != backupFile {
				if err := os.Remove(file); err != nil {
					log.WithError(err).Warn("Failed to delete old backup file")
				}
			}
		}
	}
	return nil
}

func RestoreDB(restoreFilePath string, config *config.Config) error {
	// Ensure the restore file exists
	if _, err := os.Stat(restoreFilePath); os.IsNotExist(err) {
		return fmt.Errorf("restore file does not exist: %w", err)
	}

	// Open the restore file
	f, err := os.Open(restoreFilePath)
	if err != nil {
		return fmt.Errorf("failed to open restore file: %w", err)
	}
	defer f.Close()

	// Create a new DB instance with the same options as in GetDB
	opts := getDBOpts(config)
	db, err := badger.Open(opts)
	if err != nil {
		return fmt.Errorf("failed to open new DB for restore: %w", err)
	}
	defer db.Close()

	// Perform the restore
	err = db.Load(f, 16)
	if err != nil {
		return fmt.Errorf("failed to restore database: %w", err)
	}

	log.WithFields(log.Fields{
		"restoreFile": restoreFilePath,
	}).Info("Database restore completed successfully")

	return nil
}
