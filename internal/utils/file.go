package utils

import (
	"encoding/base64"
	"fmt"
	"io"
	"os"
)

func ThumbBytesToBase64(thumbBytes []byte) string {
	return "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(thumbBytes)
}

func CopyFile(src, dst string) error {
	sourceFileStat, err := os.Stat(src)
	if err != nil {
		return err
	}

	if !sourceFileStat.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", src)
	}

	source, err := os.Open(src)
	if err != nil {
		return err
	}
	defer source.Close()

	destination, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destination.Close()
	_, err = io.Copy(destination, source)
	return err
}
