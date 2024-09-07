package cmd

import (
	"context"
	"errors"
	"os"
	"os/signal"
	"picshow/internal/cache"
	"picshow/internal/config"
	"picshow/internal/files"
	"picshow/internal/kv"
	kvdb "picshow/internal/kv"
	"picshow/internal/server"
	"picshow/internal/utils"
	"runtime/debug"
	"sync"
	"syscall"
	"time"

	"github.com/dgraph-io/badger/v2"
	log "github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(serveCmd)
}

var serveCmd = &cobra.Command{
	Use:   "serve",
	Short: "Serve the application",
	Run: func(cmd *cobra.Command, args []string) {
		serve()
	},
}

func serve() {
	// Defer panic recovery
	defer func() {
		if r := recover(); r != nil {
			log.Errorf("Panic recovered: %v\n%s", r, debug.Stack())
			os.Exit(1)
		}
	}()

	runtimeConfig, err := config.LoadConfig()
	if err != nil {
		log.Errorf("Error loading config: %v", err)
		log.Info("Starting first-run server...")

		firstRunServer := server.NewFirstRunServer()
		if err := firstRunServer.Start(); err != nil {
			log.Fatalf("Error starting first-run server: %v", err)
		}

		runtimeConfig, err = config.LoadConfig()
		if err != nil {
			log.Fatalf("Error loading config after first-run: %v", err)
		}
	}

	setLoggingFromConfig(runtimeConfig)
	if err != nil {
		log.Errorf("Error loading config: %v", err)
		log.Info("Starting first-run server...")

		firstRunServer := server.NewFirstRunServer()
		if err := firstRunServer.Start(); err != nil {
			log.Fatalf("Error starting first-run server: %v", err)
		}

		runtimeConfig, err = config.LoadConfig()
		if err != nil {
			log.Fatalf("Error loading config after first-run: %v", err)
		}
	}
	runtimeCache, err := cache.NewCache(runtimeConfig)
	if err != nil {
		log.Fatalf("Error creating cache: %v", err)
	}

	kv, err := kvdb.GetDB(runtimeConfig)
	if err != nil {
		log.Fatalf("Error creating KV repository: %v", err)
	}

	// Create a context that we can cancel
	ctx, cancel := context.WithCancel(context.Background())

	var wg sync.WaitGroup

	repo := kvdb.NewRepository(kv, runtimeCache, runtimeConfig)

	// Create a channel to signal when to start the shutdown process
	shutdownChan := make(chan struct{})

	// Start periodic file processing
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer func() {
			if r := recover(); r != nil {
				log.Errorf("Panic in file processor: %v\n%s", r, debug.Stack())
				shutdownChan <- struct{}{}
			}
		}()
		runProcessor(ctx, runtimeConfig, repo, runtimeConfig.RefreshInterval, kv)
	}()

	// Start the web server
	srv := server.NewServer(runtimeConfig, repo, runtimeCache)
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer func() {
			if r := recover(); r != nil {
				log.Errorf("Panic in web server: %v\n%s", r, debug.Stack())
				shutdownChan <- struct{}{}
			}
		}()
		if err := srv.Start(); err != nil {
			log.Errorf("Error starting server: %v", err)
			shutdownChan <- struct{}{}
		}
	}()

	// Set up signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGABRT, syscall.SIGINT, syscall.SIGTERM)

	// Wait for termination signal or panic
	select {
	case <-sigChan:
		log.Info("Received termination signal.")
	case <-shutdownChan:
		log.Info("Initiating shutdown due to panic or error.")
	}

	// Start the graceful shutdown process
	gracefulShutdown(cancel, srv, repo, &wg)
}

// prioritize the loglevel from the flag passed to the app
// over that from the config so if the flag is set ignore
// that of the config
func setLoggingFromConfig(runtimeConfig *config.Config) {
	if logLevel != nil {
		lvl, err := log.ParseLevel(runtimeConfig.LogLevel)
		if err != nil {
			log.Fatalf("Invalid log level: %v", err)
		}
		log.SetLevel(lvl)
	}
}

func gracefulShutdown(

	cancel context.CancelFunc,
	srv *server.Server,
	repo *kvdb.Repository,
	wg *sync.WaitGroup,

) {
	log.Info("Starting graceful shutdown...")
	// Cancel the context to stop ongoing operations
	cancel()

	// Create a timeout context for shutdown
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), utils.SHUTDOWN_TIMER)
	defer shutdownCancel()

	// Shutdown the server
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Errorf("Error shutting down server: %v", err)
	}

	// Close the repository
	repo.Close()
	// Wait for goroutines to finish or timeout
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		log.Info("Graceful shutdown completed")
	case <-shutdownCtx.Done():
		log.Warn("Shutdown timed out")
	}
}

func runProcessor(ctx context.Context, runtimeConfig *config.Config, repo *kvdb.Repository, refreshInterval int, db *badger.DB) {
	runProcessorOnce := func() {
		log.Info("Starting file processing...")

		processor := files.NewProcessor(runtimeConfig, repo, runtimeConfig.BatchSize, runtimeConfig.Concurrency)
		err := processor.Process(ctx)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				log.Info("File processing canceled.")
			} else {
				log.Errorf("Error processing files: %v", err)
			}
		} else {
			log.Info("File processing completed successfully.")
			kv.BackupDB(db, runtimeConfig, true)
			log.Info("Database backup completed successfully.")
		}
	}

	// Run processor immediately on startup
	runProcessorOnce()

	ticker := time.NewTicker(time.Duration(refreshInterval) * time.Hour)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			runProcessorOnce()
		}
	}
}
