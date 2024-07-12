package server

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"picshow/internal/cache"
	"picshow/internal/config"
	"picshow/internal/database"
	"picshow/internal/frontend"
	"picshow/internal/utils"
	"strconv"

	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
)

type Server struct {
	repo   *database.Repository
	config *config.Config
	ccache *cache.Cache
}

func NewServer(
	config *config.Config,
	repo *database.Repository,
	ccache *cache.Cache,
) *Server {
	return &Server{config: config, repo: repo, ccache: ccache}
}

func (s *Server) Start() error {
	e := echo.New()

	e.Use(middleware.Logger())
	e.Use(middleware.Gzip())
	e.Use(middleware.CORS())

	frontend.RegisterHandlers(e)
	// API routes
	api := e.Group("/api")
	api.GET("/", s.getFiles)
	api.DELETE("/:id", s.deleteFile)
	api.GET("/image/:id", s.getImage)
	api.GET("/video/:id", s.streamVideo)
	api.GET("/stats", s.getStats)

	return e.Start(fmt.Sprintf(":%d", s.config.Port))
}

type FileQuery struct {
	Page     *int    `query:"page"`
	PageSize *int    `query:"page_size"`
	Order    *string `query:"order"`
	OrderDir *string `query:"direction"`
	Seed     *uint64 `query:"seed"`
	Type     *string `query:"type"`
}

func (fq *FileQuery) BindAndSetDefaults(e echo.Context) error {
	if err := e.Bind(fq); err != nil {
		return err
	}
	if fq.Page == nil {
		fq.Page = new(int)
		*fq.Page = 1
	}
	if fq.PageSize == nil {
		fq.PageSize = new(int)
		*fq.PageSize = 10
	}
	if fq.Order == nil {
		fq.Order = new(string)
		*fq.Order = "created_at"
	}
	if fq.OrderDir == nil {
		fq.OrderDir = new(string)
		*fq.OrderDir = "desc"
	}
	return nil
}

func (s *Server) getFiles(e echo.Context) error {
	query := &FileQuery{}
	if err := query.BindAndSetDefaults(e); err != nil {
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Failed to parse query"})
	}
	files, err := s.repo.GetFiles(*query.Page, *query.PageSize, utils.OrderBy(*query.Order), utils.OrderDirection(*query.OrderDir), query.Seed, query.Type)
	if err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch files"})
	}
	return e.JSON(http.StatusOK, files)
}

func (s *Server) getImage(e echo.Context) error {
	id := e.Param("id")
	fileId, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Invalid file id"})
	}

	// Generate cache key for this file
	cacheKey := cache.GenerateFileContentCacheKey(fileId)

	// Try to get the file from cache
	var cachedFile []byte
	found, err := s.ccache.GetCache(cacheKey, &cachedFile)
	if err != nil {
		// Log the error, but continue to fetch from database
		log.Printf("Error retrieving from cache: %v\n", err)
	}

	if found {
		log.Printf("Serving file from cache: %s\n", cacheKey)
		return e.Blob(http.StatusOK, http.DetectContentType(cachedFile), cachedFile)
	}

	// If not in cache, fetch from database
	file, err := s.repo.GetFile(fileId)
	if err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch file"})
	}

	if file.MimeType == database.MimeTypeImage.String() {
		filePath := filepath.Join(s.config.FolderPath, file.Filename)

		// Read file contents
		fileContents, err := os.ReadFile(filePath)
		if err != nil {
			return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to read file"})
		}

		// Cache the file contents
		if err := s.ccache.SetCache(cacheKey, fileContents); err != nil {
			// Log the error, but continue to serve the file
			log.Printf("Error caching file: %v", err)
		}

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
	file, err := s.repo.GetFile(fileId)
	if err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch file"})
	}
	f, err := os.Open(filepath.Join(s.config.FolderPath, file.Filename))
	if err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to open file"})
	}
	return e.Stream(http.StatusOK, file.Video.FullMimeType, f)
}

func (s *Server) getStats(c echo.Context) error {
	stats, err := s.repo.GetStats()
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch count"})
	}
	return c.JSON(http.StatusOK, stats)
}

func (s *Server) deleteFile(e echo.Context) error {
	id := e.Param("id")
	fileId, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Invalid file id"})
	}
	file, err := s.repo.GetFile(fileId)
	if err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch file"})
	}
	if err := os.Remove(filepath.Join(s.config.FolderPath, file.Filename)); err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to delete file"})
	}
	if err := s.repo.DeleteFile(fileId); err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to delete file from database"})
	}
	return e.NoContent(http.StatusNoContent)
}
