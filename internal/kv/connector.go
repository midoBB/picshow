package kv

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"picshow/internal/config"
	"time"

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
	opts := badger.DefaultOptions(config.DBPath).
		WithNumMemtables(1).
		WithSyncWrites(true).
		WithNumLevelZeroTables(1).
		WithNumLevelZeroTablesStall(2).
		WithValueLogLoadingMode(options.FileIO).
		WithTableLoadingMode(options.FileIO).
		WithNumCompactors(2).
		WithKeepL0InMemory(false).
		WithCompression(options.None).
		WithValueLogFileSize(16 << 20) // 16 MB value log file
	db, err := badger.Open(opts)
	if err != nil {
		return nil, fmt.Errorf("failed to open Badger database: %w", err)
	}
	if shouldInitialize {
		err = initializeDB(db)
		if err != nil {
			db.Close()
			return nil, fmt.Errorf("failed to initialize Stats: %w", err)
		}
	}
	go runValueLogGC(db)
	return db, nil
}

func runValueLogGC(db *badger.DB) {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for range ticker.C {
		err := db.RunValueLogGC(0.7)
		if err != nil && !errors.Is(err, badger.ErrNoRewrite) {
			log.Printf("Error running ValueLogGC: %v", err)
		}
	}
}

func isNewDatabase(dbPath string) bool {
	// Check if the MANIFEST file exists, which is created when the database is first initialized
	_, err := os.Stat(filepath.Join(dbPath, "MANIFEST"))
	return os.IsNotExist(err)
}

func initializeDB(db *badger.DB) error {
	stats := &Stats{
		Count:         0,
		ImageCount:    0,
		VideoCount:    0,
		FavoriteCount: 0,
	}

	statsData, err := proto.Marshal(stats)
	if err != nil {
		return fmt.Errorf("failed to marshal initial Stats: %w", err)
	}

	err = db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(statsKey), statsData)
	})
	if err != nil {
		return fmt.Errorf("failed to set initial Stats in database: %w", err)
	}
	fileIds := &FileList{
		Ids:          []uint64{},
		ImageFileIds: []uint64{},
		VideoFileIds: []uint64{},
	}
	fileIdsData, err := proto.Marshal(fileIds)
	if err != nil {
		return fmt.Errorf("failed to marshal initial FileList: %w", err)
	}

	err = db.Update(func(txn *badger.Txn) error {
		return txn.Set([]byte(allFilesKey), fileIdsData)
	})
	if err != nil {
		return fmt.Errorf("failed to set initial FileList in database: %w", err)
	}
	return nil
}
