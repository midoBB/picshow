package server

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"picshow/internal/config"
	"picshow/internal/firstrun"
	"time"

	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	log "github.com/sirupsen/logrus"
)

type FirstRunServer struct {
	e    *echo.Echo
	done chan bool
}

func NewFirstRunServer() *FirstRunServer {
	e := echo.New()

	e.Use(middleware.Gzip())
	e.Use(middleware.CORS())
	e.HideBanner = true
	server := &FirstRunServer{
		e:    e,
		done: make(chan bool),
	}

	// Register the handlers from web.go
	firstrun.RegisterHandlers(e)

	// Add the config API endpoint
	e.POST("/api/config", server.handleConfigSubmission)

	return server
}

func (s *FirstRunServer) Start() error {
	go func() {
		logURLs(config.GetPort())
		if err := s.e.Start(fmt.Sprintf(":%d", config.GetPort())); err != nil && err != http.ErrServerClosed {
			log.Error("First-run server error: ", err)
		}
	}()

	<-s.done // Wait for the done signal
	return nil
}

func (s *FirstRunServer) handleConfigSubmission(c echo.Context) error {
	var newConfig config.Config
	if err := c.Bind(&newConfig); err != nil {
		return c.JSON(http.StatusBadRequest, map[string]string{"error": "Invalid request body"})
	}
	if err := newConfig.Save(); err != nil {
		return c.JSON(http.StatusInternalServerError, map[string]string{"error": "Failed to save config"})
	}

	// Trigger graceful shutdown after a short delay
	go func() {
		time.Sleep(time.Second) // Give time for the response to be sent
		s.shutdown()
	}()

	return c.JSON(http.StatusOK, map[string]string{"message": "Config saved successfully"})
}

func (s *FirstRunServer) shutdown() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := s.e.Shutdown(ctx); err != nil {
		log.Error("Error during server shutdown: ", err)
	}

	log.Info("First-run server has been shut down")
	s.done <- true
}

func logURLs(port int) {
	// Log the local URL
	log.Infof("Local: http://localhost:%d/", port)

	// Get all network interfaces
	interfaces, err := net.Interfaces()
	if err != nil {
		log.Fatal("Failed to get network interfaces: ", err)
	}

	for _, iface := range interfaces {
		// Get all addresses for each interface
		addrs, err := iface.Addrs()
		if err != nil {
			log.Fatalf("Failed to get addresses for interface %v: %v", iface.Name, err)
		}

		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}

			// Log only IPv4 addresses
			if ipv4 := ip.To4(); ipv4 != nil {
				log.Infof("Network: http://%s:%d/", ipv4, port)
			}
		}
	}
}
