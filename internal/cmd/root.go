package cmd

import (
	"fmt"
	log "github.com/sirupsen/logrus"
	"github.com/spf13/cobra"
	"os"
)

var (
	logLevelStr string
	logLevel    *log.Level
	rootCmd     = &cobra.Command{
		Use:   "picshow",
		Short: "Picshow is a self-hosted image and video gallery",
		Long:  `Picshow is a self-hosted image and video gallery. It allows you to upload and organize your photos and videos. You can favorite images and videos. Picshow is built with Go.`,
		Run: func(cmd *cobra.Command, args []string) {
			serve()
		},
	}
)

func init() {
	rootCmd.PersistentFlags().StringVar(&logLevelStr, "log", "", "Set the logging level (debug, info, warn, error)")
	cobra.OnInitialize(initLogging)
}

func initLogging() {
	level, err := log.ParseLevel(logLevelStr)
	if logLevelStr != "" && err != nil {
		log.Infof("Invalid log level: %s", logLevelStr)
	}
	log.SetLevel(level)
	logLevel = &level
	log.SetFormatter(&log.TextFormatter{
		FullTimestamp:          true,
		TimestampFormat:        "2006-01-02 15:04:05",
		DisableLevelTruncation: true,
	})
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
