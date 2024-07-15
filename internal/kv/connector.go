package kv

import (
	"fmt"
	"os"
	"path/filepath"
	"picshow/internal/config"

	"github.com/dgraph-io/badger/v3"
	"google.golang.org/protobuf/proto"
)

func GetDB(config *config.Config) (*badger.DB, error) {
	err := os.MkdirAll(config.DBPath, 0755)
	if err != nil {
		return nil, fmt.Errorf("error creating database folder: %w", err)
	}
	shouldInitialize := isNewDatabase(config.DBPath)
	opts := badger.DefaultOptions(config.DBPath).WithValueLogFileSize(1 << 27)
	db, err := badger.Open(opts)
	if err != nil {
		return nil, fmt.Errorf("failed to open Badger database: %w", err)
	}

	// Check if the database is new and initialize Stats if necessary
	if shouldInitialize {
		err = initializeDB(db)
		if err != nil {
			db.Close()
			return nil, fmt.Errorf("failed to initialize Stats: %w", err)
		}
	}

	return db, nil
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
