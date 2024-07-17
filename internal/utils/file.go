package utils

import (
	"encoding/base64"
)

func ThumbBytesToBase64(thumbBytes []byte) string {
	return "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(thumbBytes)
}
