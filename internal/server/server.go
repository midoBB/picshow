package server

import (
	"fmt"
	"net/http"
	"path/filepath"
	"picshow/internal/config"
	"picshow/internal/db"
	"strconv"

	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	"gorm.io/gorm"
)

type Server struct {
	db     *gorm.DB
	config *config.Config
}

func NewServer(config *config.Config, db *gorm.DB) *Server {
	return &Server{db: db, config: config}
}

func (s *Server) Start() error {
	e := echo.New()

	e.Use(middleware.Logger())
	e.Use(middleware.Recover())
	e.Use(middleware.CORS())

	e.GET("/", s.getFiles)
	e.GET("/:id", s.getFile)
	e.GET("/stats", s.getStats)
	return e.Start(fmt.Sprintf(":%d", s.config.Port))
}

type FileQuery struct {
	Page     *int    `query:"page"`
	PageSize *int    `query:"page_size"`
	Order    *string `query:"order"`
	OrderDir *string `query:"direction"`
	Seed     *uint64 `query:"seed"`
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
	files, err := db.GetFiles(s.db, *query.Page, *query.PageSize, db.OrderBy(*query.Order), db.OrderDirection(*query.OrderDir), query.Seed)
	if err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch files"})
	}
	return e.JSON(http.StatusOK, files)
}

func (s *Server) getFile(e echo.Context) error {
	id := e.Param("id")
	fileId, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Invalid file id"})
	}
	file, err := db.GetFile(s.db, fileId)
	if err != nil {
		return e.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch file"})
	}
	if file.MimeType == db.MimeTypeImage.String() {
		return e.File(filepath.Join(s.config.FolderPath, file.Filename))
	} else {
		// TODO: Here we will need to create a stream from the file
		return e.JSON(http.StatusBadRequest, map[string]string{"error": "Unsupported mimetype"})
	}
}

func (s *Server) getStats(c echo.Context) error {
	stats, err := db.GetStats(s.db)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to fetch count"})
	}
	return c.JSON(http.StatusOK, stats)
}
