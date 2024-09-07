package cmd

import (
	"fmt"
	"net/http"
	"picshow/internal/config"
	"picshow/internal/kv"
	"time"

	log "github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
)

var backupDestination string

func init() {
	rootCmd.AddCommand(backupCmd)
	backupCmd.Flags().StringVarP(&backupDestination, "destination", "d", "", "Specify the backup destination path")
}

var backupCmd = &cobra.Command{
	Use:   "backup",
	Short: "Backup the database",
	Run: func(cmd *cobra.Command, args []string) {
		cfg, err := config.LoadConfig()
		if err != nil {
			log.WithError(err).Error("Failed to load config")
			log.Fatal("You must run picshow once to generate the config file or you can restore it manually if you have a backup file.")
		}

		setLoggingFromConfig(cfg)

		serverRunning := checkServerRunning(cfg.PORT)
		if serverRunning {
			log.Info("Server is running. Stopping it before backup.")
			if err := stopServer(cfg.PORT); err != nil {
				log.WithError(err).Fatal("Failed to stop the server")
			}
		}

		db, err := kv.GetDB(cfg)
		if err != nil {
			log.WithError(err).Fatal("Failed to open database")
		}

		if backupDestination != "" {
			cfg.BackupFolderPath = backupDestination
		}

		err = kv.BackupDB(db, cfg, false)
		if err != nil {
			log.WithError(err).Fatal("Failed to backup database")
		}

		log.Info("Database backup successful.")

		db.Close()

		if serverRunning {
			log.Info("Restarting the server.")
			if err := startServer(cfg.PORT); err != nil {
				log.WithError(err).Fatal("Failed to restart the server")
			}
		}
	},
}

func checkServerRunning(port int) bool {
	url := fmt.Sprintf("http://localhost:%d/api/stats", port)
	_, err := http.Get(url)
	return err == nil
}

func stopServer(port int) error {
	url := fmt.Sprintf("http://localhost:%d/api/internal/stop", port)
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}
	return nil
}

func startServer(port int) error {
	url := fmt.Sprintf("http://localhost:%d/api/internal/resume", port)
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	// Wait for the server to fully start
	time.Sleep(2 * time.Second)

	// Check if the server is responding
	checkURL := fmt.Sprintf("http://localhost:%d/api/stats", port)
	for i := 0; i < 5; i++ {
		_, err := http.Get(checkURL)
		if err == nil {
			return nil
		}
		time.Sleep(1 * time.Second)
	}

	return fmt.Errorf("server did not start within the expected time")
}
