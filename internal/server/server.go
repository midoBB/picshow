package server

import (
	"context"
	"fmt"
	// "log"
	"net/http"
	"os"
	"path/filepath"
	// "picshow/internal/cache"
	"picshow/internal/config"
	"picshow/internal/frontend"
	"picshow/internal/kv"
	"picshow/internal/utils"
	"strconv"

	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
)

type Server struct {
	e      *echo.Echo
	repo   *kv.Repository
	config *config.Config
	// ccache *cache.Cache
}

func NewServer(
	config *config.Config,
	repo *kv.Repository,
	// ccache *cache.Cache,
) *Server {
	return &Server{config: config, repo: repo /* ccache: ccache */}
}

func (s *Server) Start() error {
	e := echo.New()
	e.HideBanner = true

	// e.Use(middleware.LoggerWithConfig(middleware.LoggerConfig{
	// 	Format: "[${time_rfc3339}] ${status} ${method} ${path} ${remote_ip} ${latency_human} ${bytes_in} ${bytes_out}\n",
	// }))
	e.Use(middleware.Gzip())
	e.Use(middleware.CORS())

	frontend.RegisterHandlers(e)
	// API routes
	api := e.Group("/api")
	api.GET("/", s.getFiles)
	api.PATCH("/:id/favorite", s.toggleFavorite)
	api.GET("/:id/favorite", s.getFavoriteStatus)
	api.DELETE("/", s.deleteFiles)
	api.GET("/image/:id", s.getImage)
	api.GET("/video/:id", s.streamVideo)
	api.GET("/stats", s.getStats)

	logURLs(s.config.PORT)
	s.e = e
	return e.Start(fmt.Sprintf(":%d", s.config.PORT))
}

func (s *Server) Shutdown(ctx context.Context) error {
	return s.e.Shutdown(ctx)
}

func (s *Server) getFavoriteStatus(e echo.Context) error {
	id := e.Param("id")
	fileId, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Invalid file id"})
	}
	favorite, err := s.repo.IsFileFavorite(fileId)
	if err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch favorite status"})
	}
	return e.JSON(http.StatusOK, favorite)
}

func (s *Server) getFilesFromCache(query *fileQuery) (*FilesWithPagination, bool) {
	// cacheKey, paginationKey := cache.GenerateFilesCacheKey(*query.Page, *query.PageSize, utils.OrderBy(*query.Order), utils.OrderDirection(*query.OrderDir), query.Seed, query.Type)
	// var cachedFiles []*File
	// foundFiles, err := s.ccache.GetCache(cacheKey, &cachedFiles)
	// if err != nil {
	// 	return nil, false
	// }
	// var cachedPagination *Pagination
	// foundPagination, err := s.ccache.GetCache(paginationKey, &cachedPagination)
	// if err != nil {
	// 	return nil, false
	// }
	// if foundFiles && foundPagination {
	// 	log.Printf("Found files in cache %s", cacheKey)
	// 	result := &FilesWithPagination{
	// 		Files:      cachedFiles,
	// 		Pagination: cachedPagination,
	// 	}
	// 	return result, true
	// }
	return nil, false
}

func (s *Server) getFiles(e echo.Context) error {
	query := &fileQuery{}
	if err := query.bindAndSetDefaults(e); err != nil {
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Failed to parse query"})
	}

	cacheResult, found := s.getFilesFromCache(query)
	if found {
		return e.JSON(http.StatusOK, cacheResult)
	}
	files, pagination, err := s.repo.GetFiles(*query.Page, *query.PageSize, utils.OrderBy(*query.Order), utils.OrderDirection(*query.OrderDir), query.Seed, query.Type)
	if err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch files"})
	}
	// Map protobuf Files to server Files
	serverFiles := make([]*File, len(files))
	for i, protoFile := range files {
		serverFiles[i] = MapProtoFileToServerFile(protoFile)
	}

	serverPagination := MapProtoPaginationToServerPagination(pagination)
	result := FilesWithPagination{
		Files:      serverFiles,
		Pagination: serverPagination,
	}

	s.setQueryCache(query, result)
	return e.JSON(http.StatusOK, result)
}

func (s *Server) getImage(e echo.Context) error {
	id := e.Param("id")
	fileId, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Invalid file id"})
	}

	// // Generate cache key for this file
	// cacheKey := cache.GenerateFileContentCacheKey(fileId)
	//
	// // Try to get the file from cache
	// var cachedFile []byte
	// found, err := s.ccache.GetCache(cacheKey, &cachedFile)
	// if err != nil {
	// 	// Log the error, but continue to fetch from database
	// 	log.Printf("Error retrieving from cache: %v\n", err)
	// }
	//
	// if found {
	// 	log.Printf("Serving file from cache: %s\n", cacheKey)
	// 	return e.Blob(http.StatusOK, http.DetectContentType(cachedFile), cachedFile)
	// }
	//
	// If not in cache, fetch from database
	file, err := s.repo.GetFileByID(fileId)
	if err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch file"})
	}

	if file.MimeType == utils.MimeTypeImage.String() {
		filePath := filepath.Join(s.config.FolderPath, file.Filename)

		// Read file contents
		fileContents, err := os.ReadFile(filePath)
		if err != nil {
			return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to read file"})
		}

		// // Cache the file contents
		// if err := s.ccache.SetCache(cacheKey, fileContents); err != nil {
		// 	// Log the error, but continue to serve the file
		// 	log.Printf("Error caching file: %v", err)
		// }

		// Serve the file
		return e.Blob(http.StatusOK, http.DetectContentType(fileContents), fileContents)
	} else {
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Unsupported mimetype"})
	}
}

func (s *Server) streamVideo(e echo.Context) error {
	id := e.Param("id")
	fileId, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Invalid file id"})
	}
	file, err := s.repo.GetFileByID(fileId)
	if err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch file"})
	}
	f, err := os.Open(filepath.Join(s.config.FolderPath, file.Filename))
	if err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to open file"})
	}
	return e.Stream(http.StatusOK, file.GetVideo().FullMimeType, f)
}

func (s *Server) getStats(c echo.Context) error {
	stats, err := s.repo.GetStats()
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch count"})
	}
	return c.JSON(http.StatusOK, stats)
}

func (s *Server) deleteFiles(e echo.Context) error {
	u := new(deleteRequest)
	if err := e.Bind(u); err != nil {
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Failed to parse request body"})
	}
	idsToDelete := u.toIds()
	files, err := s.repo.GetFilesByIds(idsToDelete)
	if err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch files"})
	}
	fileIDs := make([]uint64, 0)
	for _, file := range files {
		fileIDs = append(fileIDs, file.Id)
		filePath := filepath.Join(s.config.FolderPath, file.Filename)
		if err := os.Remove(filePath); err != nil {
			return fmt.Errorf("failed to delete file %s: %w", file.Filename, err)
		}
	}
	if err := s.repo.DeleteFiles(fileIDs); err != nil {
		return fmt.Errorf("failed to delete files from database: %w", err)
	}
	return e.NoContent(http.StatusNoContent)
}

func (s *Server) toggleFavorite(e echo.Context) error {
	id := e.Param("id")
	fileId, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Invalid file id"})
	}
	if err := s.repo.ToggleFileFavorite(fileId); err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to toggle favorite file"})
	}

	return e.NoContent(http.StatusNoContent)
}

func (s *Server) setQueryCache(query *fileQuery, result FilesWithPagination) {
	// cacheKey, paginationKey := cache.GenerateFilesCacheKey(*query.Page, *query.PageSize, utils.OrderBy(*query.Order), utils.OrderDirection(*query.OrderDir), query.Seed, query.Type)
	//
	// if err := s.ccache.SetCache(cacheKey, result.Files); err != nil {
	// 	log.Printf("Error caching file: %v", err)
	// }
	// if err := s.ccache.SetCache(paginationKey, result.Pagination); err != nil {
	// 	log.Printf("Error caching file: %v", err)
	// }
}
