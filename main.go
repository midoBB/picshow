package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"picshow/internal/cache"
	"picshow/internal/config"
	"picshow/internal/files"
	"picshow/internal/server"
	"picshow/internal/utils"
	"runtime/debug"
	"sync"
	"syscall"
	"time"

	_ "net/http/pprof"

	kvdb "picshow/internal/kv"
)

func init() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	go func() {
		log.Println(http.ListenAndServe("localhost:6060", nil))
	}()
}

func main() {
	// Defer panic recovery
	defer func() {
		if r := recover(); r != nil {
			log.Printf("Panic recovered: %v\n%s", r, debug.Stack())
			os.Exit(1)
		}
	}()

	runtimeConfig, err := config.LoadConfig()
	if err != nil {
		log.Printf("Error loading config: %v", err)
		log.Println("Starting first-run server...")

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

	repo := kvdb.NewRepository(kv, runtimeCache)
	processor := files.NewProcessor(runtimeConfig, repo, runtimeConfig.BatchSize, runtimeConfig.Concurrency, ctx, cancel)

	// Create a channel to signal when to start the shutdown process
	shutdownChan := make(chan struct{})

	// Start periodic file processing
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer func() {
			if r := recover(); r != nil {
				log.Printf("Panic in file processor: %v\n%s", r, debug.Stack())
				shutdownChan <- struct{}{}
			}
		}()
		runProcessor(ctx, processor, runtimeConfig.RefreshInterval)
	}()

	// Start the web server
	srv := server.NewServer(runtimeConfig, repo, runtimeCache)
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer func() {
			if r := recover(); r != nil {
				log.Printf("Panic in web server: %v\n%s", r, debug.Stack())
				shutdownChan <- struct{}{}
			}
		}()
		if err := srv.Start(); err != nil {
			log.Printf("Error starting server: %v", err)
			shutdownChan <- struct{}{}
		}
	}()

	// Set up signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGABRT, syscall.SIGINT, syscall.SIGTERM)

	// Wait for termination signal or panic
	select {
	case <-sigChan:
		log.Println("Received termination signal.")
	case <-shutdownChan:
		log.Println("Initiating shutdown due to panic or error.")
	}

	// Start the graceful shutdown process
	gracefulShutdown(cancel, srv, repo, processor, &wg)
}

func gracefulShutdown(
	cancel context.CancelFunc,
	srv *server.Server,
	repo *kvdb.Repository,
	processor *files.Processor,
	wg *sync.WaitGroup,
) {
	log.Println("Starting graceful shutdown...")
	// Cancel the context to stop ongoing operations
	cancel()

	// Create a timeout context for shutdown
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), utils.SHUTDOWN_TIMER)
	defer shutdownCancel()

	// Shutdown the server
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("Error shutting down server: %v", err)
	}
	processor.Shutdown(shutdownCtx)

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
		log.Println("Graceful shutdown completed")
	case <-shutdownCtx.Done():
		log.Println("Shutdown timed out")
	}
}

func runProcessor(ctx context.Context, processor *files.Processor, refreshInterval int) {
	// Function to run the processor

	runProcessorOnce := func() {
		log.Println("Starting file processing...")
		err := processor.Process()
		if err != nil {
			if err == context.Canceled {
				log.Println("File processing canceled.")
			} else {
				log.Printf("Error processing files: %v", err)
			}
		} else {
			log.Println("File processing completed successfully.")
		}
	}

	// Run processor immediately on startup
	runProcessorOnce()

	ticker := time.NewTicker(time.Duration(refreshInterval) * time.Hour)
	defer ticker.Stop()

	processingInProgress := false
	var processingMutex sync.Mutex

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			processingMutex.Lock()
			if !processingInProgress {
				processingInProgress = true
				processingMutex.Unlock()

				runProcessorOnce()

				processingMutex.Lock()
				processingInProgress = false
			}
			processingMutex.Unlock()
		}
	}
}
