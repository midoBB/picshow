package cmd

import (
	"os"
	"path/filepath"
	"picshow/internal/config"
	"picshow/internal/kv"

	log "github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
)

// restoreCmd represents the restore command
var restoreCmd = &cobra.Command{
	Use:   "restore [file path]",
	Short: "Restores the database to the state in the provided .bak file",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		restoreFilePath := args[0]

		log.Trace("Testing log levels")
		// Ensure the file exists
		if _, err := os.Stat(restoreFilePath); os.IsNotExist(err) {
			log.WithError(err).Fatal("Restore file does not exist")
		}

		// Ensure the file has a .bak extension
		if ext := filepath.Ext(restoreFilePath); ext != ".bak" {
			log.Warn("Restore file must have a .bak extension")
		}

		// Load the configuration
		cfg, err := config.LoadConfig()
		if err != nil {
			log.WithError(err).Error("Failed to load config")
			log.Fatal("You must run picshow once to generate the config file or you can restore it manually if you have a backup file.")
		}

		// Call RestoreDB to perform the restore
		err = kv.RestoreDB(restoreFilePath, cfg)
		if err != nil {
			log.WithError(err).Fatal("Failed to restore database")
		}

		// Successful restoration
		log.Infof("Database restored successfully from %s\n", restoreFilePath)
	},
}

func init() {
	rootCmd.AddCommand(restoreCmd)
}
