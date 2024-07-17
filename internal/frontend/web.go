package frontend

import (
	"embed"
	"net/http"
	"time"

	"github.com/labstack/echo/v4"
)

var (
	//go:embed all:dist
	dist embed.FS
	//go:embed dist/index.html
	indexHTML     embed.FS
	distDirFS     = echo.MustSubFS(dist, "dist")
	distIndexHtml = echo.MustSubFS(indexHTML, "dist")
	buildTime     time.Time
)

func init() {
	buildTime = time.Now()
}

func RegisterHandlers(e *echo.Echo) {
	g := e.Group("", addCacheHeaders)
	g.FileFS("/", "index.html", distIndexHtml)
	g.StaticFS("/", distDirFS)
}

func addCacheHeaders(next echo.HandlerFunc) echo.HandlerFunc {
	return func(c echo.Context) error {
		c.Response().Header().Set("Cache-Control", "public, max-age=259200")
		c.Response().Header().Set("Last-Modified", buildTime.UTC().Format(http.TimeFormat))
		return next(c)
	}
}
