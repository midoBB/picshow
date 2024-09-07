package cmd

import (
	"picshow/internal/config"
	"picshow/internal/kv"

	log "github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(backupCmd)
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

		db, err := kv.GetDB(cfg)
		if err != nil {
			log.WithError(err).Fatal("Failed to open database")
		}
		defer db.Close()

		err = kv.BackupDB(db, cfg)
		if err != nil {
			log.WithError(err).Fatal("Failed to backup database")
		}

		log.Info("Database backup successful.")
	},
}
