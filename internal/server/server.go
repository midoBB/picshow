package server

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"picshow/internal/cache"
	"picshow/internal/config"
	"picshow/internal/frontend"
	"picshow/internal/kv"
	"picshow/internal/utils"
	"strconv"
	"time"

	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	log "github.com/sirupsen/logrus"
)

type Server struct {
	e      *echo.Echo
	repo   *kv.Repository
	config *config.Config
	ccache *cache.Cache
}

func NewServer(
	config *config.Config,
	repo *kv.Repository,
	ccache *cache.Cache,
) *Server {
	return &Server{config: config, repo: repo, ccache: ccache}
}

func (s *Server) Start() error {
	e := echo.New()
	e.HideBanner = true
	e.Use(middleware.RequestLoggerWithConfig(middleware.RequestLoggerConfig{
		LogURI:    true,
		LogStatus: true,
		LogValuesFunc: func(c echo.Context, values middleware.RequestLoggerValues) error {
			log.WithFields(log.Fields{
				"URI":    values.URI,
				"status": values.Status,
			}).Info("request")
			return nil
		},
	}))
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
	api.GET("/internal/stop", s.stopDB)
	api.GET("/internal/resume", s.resumeDB)

	logURLs(s.config.PORT)
	s.e = e
	return e.Start(fmt.Sprintf(":%d", s.config.PORT))
}

func (s *Server) stopDB(c echo.Context) error {
	log.Info("Stopping database")
	s.repo.Close()
	return c.NoContent(http.StatusNoContent)
}

func (s *Server) resumeDB(c echo.Context) error {
	log.Info("Resuming database")
	s.repo.Open()
	return c.NoContent(http.StatusNoContent)
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
	cacheKey, paginationKey := cache.GenerateFilesCacheKey(*query.Page, *query.PageSize, utils.OrderBy(*query.Order), utils.OrderDirection(*query.OrderDir), query.Seed, query.Type)
	var cachedFiles []*File
	foundFiles, err := s.ccache.GetCache(cacheKey, &cachedFiles)
	if err != nil {
		return nil, false
	}
	var cachedPagination *Pagination
	foundPagination, err := s.ccache.GetCache(paginationKey, &cachedPagination)
	if err != nil {
		return nil, false
	}
	if foundFiles && foundPagination {
		log.Debugf("Found files in cache %s", cacheKey)
		result := &FilesWithPagination{
			Files:      cachedFiles,
			Pagination: cachedPagination,
		}
		return result, true
	}
	return nil, false
}

func (s *Server) getFiles(e echo.Context) error {
	query := &fileQuery{}
	if err := query.bindAndSetDefaults(e); err != nil {
		log.Errorf("Failed to parse query: %v", err)
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Failed to parse query"})
	}

	cacheResult, found := s.getFilesFromCache(query)
	if found {
		log.Debugf("Returning files from cache for query: %v", query)
		return e.JSON(http.StatusOK, cacheResult)
	}
	files, pagination, err := s.repo.GetFiles(*query.Page, *query.PageSize, utils.OrderBy(*query.Order), utils.OrderDirection(*query.OrderDir), query.Seed, query.Type)
	if err != nil {
		log.Errorf("Failed to fetch files from repository: %v", err)
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
	log.Debugf("Returning %d files for query: %v", len(serverFiles), query)
	return e.JSON(http.StatusOK, result)
}

func (s *Server) getImage(e echo.Context) error {
	id := e.Param("id")
	fileId, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		log.Errorf("Invalid file ID: %v", err)
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Invalid file id"})
	}

	// If not in cache, fetch from database
	file, err := s.repo.GetFileByID(fileId)
	if err != nil {
		log.Errorf("Failed to fetch file from repository: %v", err)
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch file"})
	}

	// Set cache control and last-modified headers
	e.Response().Header().Set("Cache-Control", "public, max-age=259200")
	lastModified := time.Unix(file.LastModified, 0).UTC().Format(http.TimeFormat)
	e.Response().Header().Set("Last-Modified", lastModified)

	// Check if the client has a valid cached version
	if ifModifiedSince := e.Request().Header.Get("If-Modified-Since"); ifModifiedSince != "" {
		ifModifiedSinceTime, err := time.Parse(http.TimeFormat, ifModifiedSince)
		if err == nil && !time.Unix(file.LastModified, 0).After(ifModifiedSinceTime) {
			log.Debugf("Returning 304 Not Modified for file ID: %d", fileId)
			return e.NoContent(http.StatusNotModified)
		}
	}
	if file.MimeType == utils.MimeTypeImage.String() {
		filePath := filepath.Join(s.config.FolderPath, file.Filename)

		// Read file contents
		fileContents, err := os.ReadFile(filePath)
		if err != nil {
			log.Errorf("Failed to read file: %v", err)
			return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to read file"})
		}

		// Serve the file
		log.Debugf("Serving image file: %s", file.Filename)
		return e.Blob(http.StatusOK, http.DetectContentType(fileContents), fileContents)
	} else {
		log.Warnf("Unsupported mimetype for file ID: %d", fileId)
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Unsupported mimetype"})
	}
}

func (s *Server) streamVideo(e echo.Context) error {
	id := e.Param("id")
	fileId, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		log.Errorf("Invalid file ID: %v", err)
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Invalid file id"})
	}
	file, err := s.repo.GetFileByID(fileId)
	if err != nil {
		log.Errorf("Failed to fetch file from repository: %v", err)
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch file"})
	}

	e.Response().Header().Set("Cache-Control", "public, max-age=259200")
	lastModified := time.Unix(file.LastModified, 0).UTC().Format(http.TimeFormat)
	e.Response().Header().Set("Last-Modified", lastModified)

	if ifModifiedSince := e.Request().Header.Get("If-Modified-Since"); ifModifiedSince != "" {
		ifModifiedSinceTime, err := time.Parse(http.TimeFormat, ifModifiedSince)
		if err == nil && !time.Unix(file.LastModified, 0).After(ifModifiedSinceTime) {
			log.Debugf("Returning 304 Not Modified for file ID: %d", fileId)
			return e.NoContent(http.StatusNotModified)
		}
	}
	f, err := os.Open(filepath.Join(s.config.FolderPath, file.Filename))
	if err != nil {
		log.Errorf("Failed to open file: %v", err)
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to open file"})
	}
	log.Debugf("Streaming video file: %s", file.Filename)
	return e.Stream(http.StatusOK, file.GetVideo().FullMimeType, f)
}

func (s *Server) getStats(c echo.Context) error {
	stats, err := s.repo.GetStats()
	if err != nil {
		log.Errorf("Failed to fetch stats from repository: %v", err)
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch count"})
	}
	log.Debugf("Returning stats: %+v", stats)
	return c.JSON(http.StatusOK, MapProtoStatsToServerStats(stats))
}

func (s *Server) deleteFiles(e echo.Context) error {
	u := new(deleteRequest)
	if err := e.Bind(u); err != nil {
		log.Errorf("Failed to parse delete request body: %v", err)
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Failed to parse request body"})
	}
	idsToDelete := u.toIds()
	files, err := s.repo.GetFilesByIds(idsToDelete)
	if err != nil {
		log.Errorf("Failed to fetch files from repository: %v", err)
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch files"})
	}
	fileIDs := make([]uint64, 0)
	for _, file := range files {
		fileIDs = append(fileIDs, file.Id)
		filePath := filepath.Join(s.config.FolderPath, file.Filename)
		if err := os.Remove(filePath); err != nil {
			log.Errorf("Failed to delete file %s: %v", file.Filename, err)
			return fmt.Errorf("failed to delete file %s: %w", file.Filename, err)
		}
		log.Infof("Deleted file: %s", file.Filename)
	}
	if err := s.repo.DeleteFiles(fileIDs); err != nil {
		log.Errorf("Failed to delete files from database: %v", err)
		return fmt.Errorf("failed to delete files from database: %w", err)
	}
	log.Infof("Deleted %d files from database", len(fileIDs))
	return e.NoContent(http.StatusNoContent)
}

func (s *Server) toggleFavorite(e echo.Context) error {
	id := e.Param("id")
	fileId, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		log.Errorf("Invalid file ID: %v", err)
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Invalid file id"})
	}
	if err := s.repo.ToggleFileFavorite(fileId); err != nil {
		log.Errorf("Failed to toggle favorite status for file ID %d: %v", fileId, err)
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to toggle favorite file"})
	}
	log.Infof("Toggled favorite status for file ID: %d", fileId)
	return e.NoContent(http.StatusNoContent)
}

func (s *Server) setQueryCache(query *fileQuery, result FilesWithPagination) {
	cacheKey, paginationKey := cache.GenerateFilesCacheKey(*query.Page, *query.PageSize, utils.OrderBy(*query.Order), utils.OrderDirection(*query.OrderDir), query.Seed, query.Type)

	if err := s.ccache.SetCache(cacheKey, result.Files); err != nil {
		log.Errorf("Error caching files for query %v: %v", query, err)
	}
	if err := s.ccache.SetCache(paginationKey, result.Pagination); err != nil {
		log.Errorf("Error caching pagination for query %v: %v", query, err)
	}
	log.Debugf("Cached files and pagination for query: %v", query)
}
