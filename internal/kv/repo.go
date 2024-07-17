package kv

import (
	"encoding/binary"
	"fmt"
	"math"
	"picshow/internal/cache"
	"picshow/internal/utils"
	"slices"
	"sort"
	"strconv"
	"sync"

	"github.com/dgraph-io/badger/v2"
	"golang.org/x/exp/rand"
	"google.golang.org/protobuf/proto"
)

type Repository struct {
	db    *badger.DB
	cache *cache.Cache
}

type OP string

const (
	Create     OP = "create"
	Delete     OP = "delete"
	Favorite   OP = "favorite"
	Unfavorite OP = "unfavorite"
)

// Keys
const (
	filePrefix    = "file:"
	fileNameIndex = "fileName:"
	fileHashIndex = "fileHash:"
	statsKey      = "stats"
	allFilesKey   = "allFiles"
)

func NewRepository(db *badger.DB, cache *cache.Cache) *Repository {
	return &Repository{
		db:    db,
		cache: cache,
	}
}

func (r *Repository) Close() error {
	return r.db.Close()
}

func (r *Repository) AddFile(file *File) error {
	defer r.cache.Delete(string(cache.FilesCacheKey))
	return r.db.Update(func(txn *badger.Txn) error {
		seq, err := r.db.GetSequence([]byte("file_id_seq"), 100)
		if err != nil {
			return err
		}
		defer seq.Release()

		id, err := seq.Next()
		if err != nil {
			return err
		}
		file.Id = id
		// Marshal the file using protobuf
		fileData, err := proto.Marshal(file)
		if err != nil {
			return fmt.Errorf("failed to marshal file: %w", err)
		}

		// Store the file data
		err = txn.Set([]byte(fmt.Sprintf("%s%d", filePrefix, file.Id)), fileData)
		if err != nil {
			return fmt.Errorf("failed to store file data: %w", err)
		}

		// Store the filename index
		err = txn.Set([]byte(fmt.Sprintf("%s%s", fileNameIndex, file.Filename)), uint64ToBytes(file.Id))
		if err != nil {
			return fmt.Errorf("failed to store filename index: %w", err)
		}

		// Store the file hash index
		err = txn.Set([]byte(fmt.Sprintf("%s%s", fileHashIndex, file.Hash)), uint64ToBytes(file.Id))
		if err != nil {
			return fmt.Errorf("failed to store file hash index: %w", err)
		}

		err = r.updateStatsFromOP(Create, file)
		if err != nil {
			return fmt.Errorf("failed to update stats: %w", err)
		}
		err = r.updateAllFilesFromOP(Create, file)
		if err != nil {
			return fmt.Errorf("failed to update fileIds: %w", err)
		}
		return nil
	})
}

func (r *Repository) updateAllFilesFromOP(op OP, file *File) error {
	defer r.cache.Delete(string(cache.FilesCacheKey))
	fileIds, err := r.GetAllFileIds()
	if err != nil {
		return fmt.Errorf("failed to get stats: %w", err)
	}
	if op == Delete {
		fileIds.Ids = slices.DeleteFunc(fileIds.Ids, func(id uint64) bool {
			return id == file.Id
		})
		fileIds.VideoFileIds = slices.DeleteFunc(fileIds.VideoFileIds, func(id uint64) bool {
			return id == file.Id
		})
		fileIds.ImageFileIds = slices.DeleteFunc(fileIds.ImageFileIds, func(id uint64) bool {
			return id == file.Id
		})
		fileIds.FavoriteFileIds = slices.DeleteFunc(fileIds.FavoriteFileIds, func(id uint64) bool {
			return id == file.Id
		})
	} else {
		fileIds.Ids = append(fileIds.Ids, file.Id)
		switch file.GetMedia().(type) {
		case *File_Image:
			fileIds.ImageFileIds = append(fileIds.ImageFileIds, file.Id)
		case *File_Video:
			fileIds.VideoFileIds = append(fileIds.VideoFileIds, file.Id)
		}
	}

	err = r.UpdateFileLists(fileIds)
	if err != nil {
		return fmt.Errorf("failed to update fileLists: %w", err)
	}

	return nil
}

func (r *Repository) updateStatsFromOP(op OP, file *File) error {
	defer r.cache.Delete(string(cache.StatsCacheKey))
	stats, err := r.GetStats()
	if err != nil {
		return fmt.Errorf("failed to get stats: %w", err)
	}
	if op == Delete {
		stats.Count--
		switch file.GetMedia().(type) {
		case *File_Image:
			stats.ImageCount--
		case *File_Video:
			stats.VideoCount--
		}
		if favorite, _ := r.IsFileFavorite(file.Id); favorite {
			stats.FavoriteCount--
		}
	} else if op == Create {
		stats.Count++
		switch file.GetMedia().(type) {
		case *File_Image:
			stats.ImageCount++
		case *File_Video:
			stats.VideoCount++
		}
	} else {
		return nil
	}

	err = r.UpdateStats(stats)
	if err != nil {
		return fmt.Errorf("failed to update stats: %w", err)
	}

	return nil
}

func (r *Repository) updateFavoriteStats(op OP) error {
	defer r.cache.Delete(string(cache.StatsCacheKey))
	stats, err := r.GetStats()
	if err != nil {
		return fmt.Errorf("failed to get stats: %w", err)
	}
	if op == Unfavorite {
		stats.FavoriteCount--
	} else if op == Favorite {
		stats.FavoriteCount++
	} else {
		return nil
	}

	err = r.UpdateStats(stats)
	if err != nil {
		return fmt.Errorf("failed to update stats: %w", err)
	}

	return nil
}

func (r *Repository) IsFileFavorite(fileID uint64) (bool, error) {
	list, err := r.GetAllFileIds()
	if err != nil {
		return false, fmt.Errorf("failed to get stats: %w", err)
	}

	return slices.ContainsFunc(list.FavoriteFileIds, func(id uint64) bool {
		return id == fileID
	}), nil
}

func (r *Repository) ToggleFileFavorite(fileID uint64) error {
	r.clearCache()
	fileIds, err := r.GetAllFileIds()
	if err != nil {
		return fmt.Errorf("failed to get stats: %w", err)
	}

	favorite := slices.ContainsFunc(fileIds.FavoriteFileIds, func(id uint64) bool {
		return id == fileID
	})
	if favorite {
		err = r.updateFavoriteStats(Unfavorite)
		if err != nil {
			return err
		}
		fileIds.FavoriteFileIds = slices.DeleteFunc(fileIds.FavoriteFileIds, func(id uint64) bool {
			return id == fileID
		})
	} else {
		err = r.updateFavoriteStats(Favorite)
		if err != nil {
			return err
		}
		fileIds.FavoriteFileIds = append(fileIds.FavoriteFileIds, fileID)
	}
	return r.UpdateFileLists(fileIds)
}

func (r *Repository) FindAllFiles() (*sync.Map, *sync.Map, error) {
	fileNameMap := &sync.Map{}
	fileHashMap := &sync.Map{}

	err := r.db.View(func(txn *badger.Txn) error {
		// Iterate over fileName index
		it := txn.NewIterator(badger.DefaultIteratorOptions)
		defer it.Close()

		prefix := []byte(fileNameIndex)
		for it.Seek(prefix); it.ValidForPrefix(prefix); it.Next() {
			item := it.Item()
			k := item.Key()
			err := item.Value(func(v []byte) error {
				fileName := string(k[len(fileNameIndex):])
				fileID := bytesToUint64(v)
				fileNameMap.Store(fileName, fileID)
				return nil
			})
			if err != nil {
				return err
			}
		}

		// Iterate over fileHash index
		it.Rewind()
		prefix = []byte(fileHashIndex)
		for it.Seek(prefix); it.ValidForPrefix(prefix); it.Next() {
			item := it.Item()
			k := item.Key()
			err := item.Value(func(v []byte) error {
				fileHash := string(k[len(fileHashIndex):])
				fileID := bytesToUint64(v)
				fileHashMap.Store(fileHash, fileID)
				return nil
			})
			if err != nil {
				return err
			}
		}

		return nil
	})
	if err != nil {
		return nil, nil, fmt.Errorf("failed to find all files: %w", err)
	}

	return fileNameMap, fileHashMap, nil
}

func (r *Repository) GetFileByID(id uint64) (*File, error) {
	var file File
	err := r.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(fileKey(id))
		if err != nil {
			return fmt.Errorf("failed to get file: %w", err)
		}

		return item.Value(func(val []byte) error {
			return proto.Unmarshal(val, &file)
		})
	})
	if err != nil {
		return nil, err
	}

	return &file, nil
}

func (r *Repository) GetFilesByIds(ids []uint64) ([]*File, error) {
	files := make([]*File, 0, len(ids))

	err := r.db.View(func(txn *badger.Txn) error {
		for _, id := range ids {
			item, err := txn.Get(fileKey(id))
			if err != nil {
				if err == badger.ErrKeyNotFound {
					// Skip if the file is not found
					continue
				}
				return fmt.Errorf("failed to get file with id %d: %w", id, err)
			}

			err = item.Value(func(val []byte) error {
				file := &File{}
				if err := proto.Unmarshal(val, file); err != nil {
					return fmt.Errorf("failed to unmarshal file with id %d: %w", id, err)
				}
				files = append(files, file)
				return nil
			})
			if err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("error retrieving files: %w", err)
	}

	return files, nil
}

func (r *Repository) GetFiles(
	page, pageSize int,
	order utils.OrderBy,
	direction utils.OrderDirection,
	seed *uint64,
	mimetype *string,
) ([]*File, *Pagination, error) {
	var files []*File
	var totalRecords uint64

	err := r.db.View(func(txn *badger.Txn) error {
		// Retrieve all file IDs from allFilesKey
		item, err := txn.Get([]byte(allFilesKey))
		if err != nil {
			return fmt.Errorf("failed to get all file IDs: %w", err)
		}

		var fileList FileList
		err = item.Value(func(val []byte) error {
			return proto.Unmarshal(val, &fileList)
		})
		if err != nil {
			return fmt.Errorf("failed to unmarshal file list: %w", err)
		}

		allFileIDs := fileList.Ids

		// Filter by mimetype if specified
		if mimetype != nil {
			if *mimetype == utils.MimeTypeImage.String() {
				allFileIDs = fileList.ImageFileIds
			} else if *mimetype == utils.MimeTypeVideo.String() {
				allFileIDs = fileList.VideoFileIds
			} else if *mimetype == "favorite" {
				allFileIDs = fileList.FavoriteFileIds
			}
		}

		totalRecords = uint64(len(allFileIDs))

		// Sort file IDs based on order and direction
		if order == utils.Random {
			allFileIDs, err = r.getStableRandomOrder(allFileIDs, *seed, mimetype)
			if err != nil {
				return fmt.Errorf("failed to get stable random order: %w", err)
			}
		} else if order == utils.CreatedAt {
			if direction == utils.Desc {
				sort.Slice(allFileIDs, func(i, j int) bool {
					return allFileIDs[i] > allFileIDs[j]
				})
			} else {
				sort.Slice(allFileIDs, func(i, j int) bool {
					return allFileIDs[i] < allFileIDs[j]
				})
			}
		}

		// Calculate pagination
		offset := (page - 1) * pageSize
		end := offset + pageSize
		if end > len(allFileIDs) {
			end = len(allFileIDs)
		}

		// Fetch files for the current page
		for _, fileID := range allFileIDs[offset:end] {
			file, err := r.GetFileByID(fileID)
			if err != nil {
				return fmt.Errorf("failed to get file %d: %w", fileID, err)
			}
			files = append(files, file)
		}

		return nil
	})
	if err != nil {
		return nil, nil, err
	}

	// Prepare pagination info
	var nextPage, prevPage *uint64
	if page < int(math.Ceil(float64(totalRecords)/float64(pageSize))) {
		next := uint64(page + 1)
		nextPage = &next
	}
	if page > 1 {
		prev := uint64(page - 1)
		prevPage = &prev
	}

	pagination := &Pagination{
		TotalRecords: totalRecords,
		CurrentPage:  uint64(page),
		TotalPages:   uint64(math.Ceil(float64(totalRecords) / float64(pageSize))),
		NextPage:     nextPage,
		PrevPage:     prevPage,
	}

	return files, pagination, nil
}

func (r *Repository) getStableRandomOrder(fileIDs []uint64, seed uint64, mimetype *string) ([]uint64, error) {
	var mimetypeStr string
	if mimetype != nil {
		mimetypeStr = *mimetype
	} else {
		mimetypeStr = "all"
	}
	cacheKey := fmt.Sprintf("%s:%d:%s", cache.RandomCacheKey, seed, mimetypeStr)
	var cachedOrder []uint64
	found, err := r.cache.GetCache(cacheKey, &cachedOrder)
	if err != nil {
		return nil, fmt.Errorf("cache error: %w", err)
	}
	if found {
		return cachedOrder, nil
	}

	// If not found in cache, generate a new random order
	newOrder := make([]uint64, len(fileIDs))
	copy(newOrder, fileIDs)
	rng := rand.New(rand.NewSource(seed))
	rng.Shuffle(len(newOrder), func(i, j int) {
		newOrder[i], newOrder[j] = newOrder[j], newOrder[i]
	})

	// Cache the new order
	if err := r.cache.SetCache(cacheKey, newOrder); err != nil {
		return nil, fmt.Errorf("failed to set cache: %w", err)
	}

	return newOrder, nil
}

// GetFileByHash retrieves a file by its hash
func (r *Repository) GetFileByHash(hash string) (*File, error) {
	var fileID uint64
	err := r.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get(fileHashKey(hash))
		if err != nil {
			return fmt.Errorf("failed to get file hash: %w", err)
		}

		return item.Value(func(val []byte) error {
			id, err := strconv.ParseUint(string(val), 10, 64)
			if err != nil {
				return fmt.Errorf("failed to parse file ID: %w", err)
			}
			fileID = id
			return nil
		})
	})
	if err != nil {
		return nil, err
	}

	return r.GetFileByID(fileID)
}

// UpdateStats updates the server stats
func (r *Repository) UpdateStats(stats *Stats) error {
	return r.db.Update(func(txn *badger.Txn) error {
		statsData, err := proto.Marshal(stats)
		if err != nil {
			return fmt.Errorf("failed to marshal stats: %w", err)
		}

		return txn.Set([]byte(statsKey), statsData)
	})
}

// UpdateFileLists updates the server stats
func (r *Repository) UpdateFileLists(fileList *FileList) error {
	return r.db.Update(func(txn *badger.Txn) error {
		allFileIdsData, err := proto.Marshal(fileList)
		if err != nil {
			return fmt.Errorf("failed to marshal stats: %w", err)
		}

		return txn.Set([]byte(allFilesKey), allFileIdsData)
	})
}

// GetStats retrieves the server stats
func (r *Repository) GetStats() (*Stats, error) {
	var stats Stats
	err := r.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(statsKey))
		if err != nil {
			return fmt.Errorf("failed to get stats: %w", err)
		}

		return item.Value(func(val []byte) error {
			return proto.Unmarshal(val, &stats)
		})
	})
	if err != nil {
		return nil, err
	}

	return &stats, nil
}

// GetStats retrieves the server stats
func (r *Repository) GetAllFileIds() (*FileList, error) {
	var fileIds FileList
	err := r.db.View(func(txn *badger.Txn) error {
		item, err := txn.Get([]byte(allFilesKey))
		if err != nil {
			return fmt.Errorf("failed to get stats: %w", err)
		}

		return item.Value(func(val []byte) error {
			return proto.Unmarshal(val, &fileIds)
		})
	})
	if err != nil {
		return nil, err
	}

	return &fileIds, nil
}

func (r *Repository) UpdateFile(file *File) error {
	r.clearCacheByFileID(file.Id)

	fileData, err := proto.Marshal(file)
	if err != nil {
		return err
	}

	return r.db.Update(func(txn *badger.Txn) error {
		return txn.Set(fileKey(file.Id), fileData)
	})
}

func (r *Repository) DeleteFile(id uint64) error {
	r.clearCacheByFileID(id)
	r.clearCache()

	return r.db.Update(func(txn *badger.Txn) error {
		item, err := txn.Get(fileKey(id))
		if err != nil {
			return err
		}

		var file File
		err = item.Value(func(v []byte) error {
			return proto.Unmarshal(v, &file)
		})
		if err != nil {
			return err
		}

		if err := txn.Delete(fileKey(id)); err != nil {
			return err
		}

		if err := txn.Delete(fileHashKey(file.Hash)); err != nil {
			return err
		}

		if err := txn.Delete(fileNameKey(file.Filename)); err != nil {
			return err
		}

		if err := r.updateStatsFromOP(Delete, &file); err != nil {
			return err
		}
		if err := r.updateAllFilesFromOP(Delete, &file); err != nil {
			return err
		}

		return nil
	})
}

func (r *Repository) DeleteFiles(ids []uint64) error {
	for _, id := range ids {
		r.clearCacheByFileID(id)
	}
	r.clearCache()

	return r.db.Update(func(txn *badger.Txn) error {
		for _, id := range ids {
			if err := r.DeleteFile(id); err != nil {
				return err
			}
		}
		return nil
	})
}

func uint64ToBytes(i uint64) []byte {
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, i)
	return b
}

func bytesToUint64(b []byte) uint64 {
	return binary.BigEndian.Uint64(b)
}

// Helper functions for key generation
func fileKey(id uint64) []byte {
	return []byte(fmt.Sprintf("%s%d", filePrefix, id))
}

func fileNameKey(fileName string) []byte {
	return []byte(fmt.Sprintf("%s%s", fileNameIndex, fileName))
}

func fileHashKey(hash string) []byte {
	return []byte(fmt.Sprintf("%s%s", fileHashIndex, hash))
}

func (r *Repository) clearCacheByFileID(id uint64) {
	cacheKey := cache.GenerateFileCacheKey(id)
	contentCacheKey := cache.GenerateFileContentCacheKey(id)
	r.cache.Delete(cacheKey)
	r.cache.Delete(contentCacheKey)
}

func (r *Repository) clearCache() {
	r.cache.Delete(string(cache.StatsCacheKey))
	r.cache.Delete(string(cache.FilesCacheKey))
	r.cache.Delete(string(cache.RandomCacheKey))
}

// AddBatch adds multiple files to the repository in a single transaction
func (r *Repository) AddBatch(files []*File) error {
	defer r.cache.Delete(string(cache.FilesCacheKey))
	return r.db.Update(func(txn *badger.Txn) error {
		seq, err := r.db.GetSequence([]byte("file_id_seq"), 100)
		if err != nil {
			return err
		}
		defer seq.Release()

		for _, file := range files {
			id, err := seq.Next()
			if err != nil {
				return err
			}
			file.Id = id

			// Marshal the file using protobuf
			fileData, err := proto.Marshal(file)
			if err != nil {
				return fmt.Errorf("failed to marshal file: %w", err)
			}

			// Store the file data
			err = txn.Set(fileKey(file.Id), fileData)
			if err != nil {
				return fmt.Errorf("failed to store file data: %w", err)
			}

			// Store the filename index
			err = txn.Set(fileNameKey(file.Filename), uint64ToBytes(file.Id))
			if err != nil {
				return fmt.Errorf("failed to store filename index: %w", err)
			}

			// Store the file hash index
			err = txn.Set(fileHashKey(file.Hash), uint64ToBytes(file.Id))
			if err != nil {
				return fmt.Errorf("failed to store file hash index: %w", err)
			}

			err = r.updateStatsFromOP(Create, file)
			if err != nil {
				return fmt.Errorf("failed to update stats: %w", err)
			}

			err = r.updateAllFilesFromOP(Create, file)
			if err != nil {
				return fmt.Errorf("failed to update fileIds: %w", err)
			}
		}

		return nil
	})
}

// UpdateBatch updates multiple files in the repository in a single transaction
func (r *Repository) UpdateBatch(files []*File) error {
	for _, file := range files {
		r.clearCacheByFileID(file.Id)
	}
	r.clearCache()

	return r.db.Update(func(txn *badger.Txn) error {
		for _, file := range files {
			fileData, err := proto.Marshal(file)
			if err != nil {
				return fmt.Errorf("failed to marshal file: %w", err)
			}

			// Update the file data
			err = txn.Set(fileKey(file.Id), fileData)
			if err != nil {
				return fmt.Errorf("failed to update file data: %w", err)
			}

			// Update the filename index
			err = txn.Set(fileNameKey(file.Filename), uint64ToBytes(file.Id))
			if err != nil {
				return fmt.Errorf("failed to update filename index: %w", err)
			}

			// Update the file hash index
			err = txn.Set(fileNameKey(file.Hash), uint64ToBytes(file.Id))
			if err != nil {
				return fmt.Errorf("failed to update file hash index: %w", err)
			}
		}

		return nil
	})
}

func (r *Repository) UpdateFavoriteCount() {
	r.clearCache()
	fileIds, err := r.GetAllFileIds()
	if err != nil {
		return
	}
	stats, err := r.GetStats()
	if err != nil {
		return
	}
	stats.FavoriteCount = uint64(len(fileIds.FavoriteFileIds))
	err = r.UpdateStats(stats)
	if err != nil {
		return
	}
}
