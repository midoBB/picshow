package files

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"picshow/internal/config"
	"picshow/internal/kv"
	"picshow/internal/utils"
	"strconv"
	"strings"
)

type handler struct {
	config *config.Config
}

func newHandler(config *config.Config) *handler {
	return &handler{config: config}
}

func getFullMimeType(filePath string) string {
	cmd := exec.Command("file", "--mime-type", filePath)
	output, err := cmd.Output()
	if err != nil {
		return ""
	}

	parts := strings.Split(string(output), ":")
	if len(parts) != 2 {
		return ""
	}

	return strings.TrimSpace(parts[1])
}

func getFileMimeType(filePath string) (utils.MimeType, error) {
	mimeType := getFullMimeType(filePath)

	if strings.Contains(mimeType, "image") {
		return utils.MimeTypeImage, nil
	} else if strings.Contains(mimeType, "video") {
		return utils.MimeTypeVideo, nil
	}
	return utils.MimeTypeOther, nil
}

// generateFileKey creates a unique key for a file based on its size and content hash
// generateFileKey creates a unique key for a file based on its size and content hash
func (h *handler) generateFileKey(filePath string) (string, error) {
	fileInfo, err := os.Stat(filePath)
	if err != nil {
		return "", fmt.Errorf("error getting file info: %w", err)
	}
	fileSize := fileInfo.Size()

	var contentHash string
	if fileSize <= 5*1024*1024 { // 5MB
		// Use xxhsum to hash the entire file for files 5MB or smaller
		cmd := exec.Command("xxhsum", filePath)
		output, err := cmd.Output()
		if err != nil {
			return "", fmt.Errorf("error executing xxhsum: %w", err)
		}

		// Parse the xxhsum output
		parts := strings.Fields(string(output))
		if len(parts) < 2 {
			return "", fmt.Errorf("unexpected xxhsum output format")
		}
		contentHash = parts[0]
	} else {
		// Use dd to read the first 5MB of the file and pipe it to xxhsum for larger files
		ddCmd := exec.Command("dd", "if="+filePath, fmt.Sprintf("bs=%dK", h.config.HashSize), "count=1")
		xxhsumCmd := exec.Command("xxhsum")

		xxhsumCmd.Stdin, _ = ddCmd.StdoutPipe()
		xxhsumOutput, err := xxhsumCmd.StdoutPipe()
		if err != nil {
			return "", fmt.Errorf("error creating pipe: %w", err)
		}

		if err := xxhsumCmd.Start(); err != nil {
			return "", fmt.Errorf("error starting xxhsum: %w", err)
		}
		if err := ddCmd.Run(); err != nil {
			return "", fmt.Errorf("error running dd: %w", err)
		}

		hashOutput := make([]byte, 64)
		n, err := xxhsumOutput.Read(hashOutput)
		if err != nil {
			return "", fmt.Errorf("error reading xxhsum output: %w", err)
		}

		if err := xxhsumCmd.Wait(); err != nil {
			return "", fmt.Errorf("error waiting for xxhsum: %w", err)
		}

		parts := strings.Fields(string(hashOutput[:n]))
		if len(parts) == 0 {
			return "", fmt.Errorf("unexpected xxhsum output format")
		}
		contentHash = parts[0]
	}

	key := fmt.Sprintf("%d_%s", fileSize, contentHash)
	return key, nil
}

func (h *handler) handleNewImage(p *Processor, filePath string) (*kv.Image, error) {
	// Get the file extension to handle GIFs separately
	ext := strings.ToLower(filepath.Ext(filePath))

	if ext == ".gif" {
		filePath = filePath + "[0]" // Identify the first frame of the GIF
	}

	cmdIdentify := exec.Command("identify", "-format", "%wx%h", filePath)
	identifyCmdKey := fmt.Sprintf("identify_%s", filePath)
	p.processes.Store(identifyCmdKey, cmdIdentify)
	output, err := cmdIdentify.Output()
	if err != nil {
		p.processes.Delete(identifyCmdKey)
		return nil, fmt.Errorf("error executing ImageMagick identify command: %w", err)
	}
	p.processes.Delete(identifyCmdKey)
	// Parse the output to get width and height
	var width, height int
	_, err = fmt.Sscanf(string(output), "%dx%d", &width, &height)
	if err != nil {
		return nil, fmt.Errorf("error parsing image dimensions: %w", err)
	}

	// Calculate thumbnail dimensions
	var thumbWidth, thumbHeight uint
	if width > height {
		thumbWidth = uint(h.config.MaxThumbnailSize)
		thumbHeight = uint(float64(height) * float64(h.config.MaxThumbnailSize) / float64(width))
	} else {
		thumbHeight = uint(h.config.MaxThumbnailSize)
		thumbWidth = uint(float64(width) * float64(h.config.MaxThumbnailSize) / float64(height))
	}

	// Generate temporary file path for thumbnail
	tempFile := filepath.Join(os.TempDir(), strconv.FormatUint(uint64(thumbWidth), 10)+"x"+strconv.FormatUint(uint64(thumbHeight), 10)+".jpg")
	// Construct and execute ImageMagick convert command
	cmd := exec.Command("convert", filePath, "-resize", strconv.Itoa(int(thumbWidth))+"x"+strconv.Itoa(int(thumbHeight)), tempFile)
	convCmdKey := fmt.Sprintf("conver_%s", tempFile)
	p.processes.Store(convCmdKey, cmd)
	err = cmd.Run()
	if err != nil {
		p.processes.Delete(convCmdKey)
		return nil, fmt.Errorf("error executing ImageMagick convert command: %w", err)
	}
	p.processes.Delete(convCmdKey)
	p.tempFiles.Store(tempFile, tempFile)
	defer os.Remove(tempFile)
	defer p.tempFiles.Delete(tempFile)
	// Read thumbnail file into memory
	thumbnailData, err := os.ReadFile(tempFile)
	if err != nil {
		return nil, fmt.Errorf("error reading thumbnail file: %w", err)
	}

	image := &kv.Image{
		FullMimeType:    getFullMimeType(filePath),
		Width:           uint64(width),
		Height:          uint64(height),
		ThumbnailWidth:  uint64(thumbWidth),
		ThumbnailHeight: uint64(thumbHeight),
		ThumbnailData:   thumbnailData,
	}

	return image, nil
}

func (h *handler) handleNewVideo(p *Processor, filePath string) (*kv.Video, error) {
	// Run ffprobe as an external command
	cmd := exec.Command("ffprobe",
		"-v", "quiet",
		"-print_format", "json",
		"-show_format",
		"-show_streams",
		filePath)
	ffprobeCmdKey := fmt.Sprintf("ffprobe_%s", filePath)
	p.processes.Store(ffprobeCmdKey, cmd)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err != nil {
		p.processes.Delete(ffprobeCmdKey)
		return nil, fmt.Errorf("error running ffprobe: %w\nstderr: %s", err, stderr.String())
	}
	p.processes.Delete(ffprobeCmdKey)

	// Parse the JSON output
	var probeResult struct {
		Streams []struct {
			CodecType string `json:"codec_type"`
			Width     int    `json:"width"`
			Height    int    `json:"height"`
		} `json:"streams"`
		Format struct {
			Duration string `json:"duration"`
		} `json:"format"`
	}

	if err := json.Unmarshal(stdout.Bytes(), &probeResult); err != nil {
		return nil, fmt.Errorf("error parsing ffprobe output: %w", err)
	}

	// Extract video information
	var width, height uint64
	for _, stream := range probeResult.Streams {
		if stream.CodecType == "video" {
			width = uint64(stream.Width)
			height = uint64(stream.Height)
			break
		}
	}

	duration, err := strconv.ParseFloat(probeResult.Format.Duration, 64)
	if err != nil {
		return nil, fmt.Errorf("error parsing video duration: %w", err)
	}

	screenshotAt := math.Floor(duration * 0.33)

	// Calculate thumbnail dimensions
	var thumbWidth, thumbHeight uint
	if width > height {
		thumbWidth = uint(h.config.MaxThumbnailSize)
		thumbHeight = uint(float64(height) * float64(h.config.MaxThumbnailSize) / float64(width))
	} else {
		thumbHeight = uint(h.config.MaxThumbnailSize)
		thumbWidth = uint(float64(width) * float64(h.config.MaxThumbnailSize) / float64(height))
	}

	// Create temporary file for the thumbnail
	thumbnailFile, err := os.CreateTemp("", "video_thumbnail_*.jpg")
	if err != nil {
		return nil, fmt.Errorf("error creating temporary file for video thumbnail: %w", err)
	}
	p.tempFiles.Store(thumbnailFile.Name(), thumbnailFile.Name())
	defer os.Remove(thumbnailFile.Name())
	defer p.tempFiles.Delete(thumbnailFile.Name())

	ffmpegCmd := exec.Command(
		"ffmpeg",
		"-ss", fmt.Sprintf("%.2f", screenshotAt),
		"-t", "0.1",
		"-i", filePath,
		"-an",
		"-vframes", "1",
		"-vf", fmt.Sprintf("scale=%d:%d:flags=fast_bilinear", thumbWidth, thumbHeight),
		"-f", "mjpeg",
		"-q:v", "5",
		"-y",
		thumbnailFile.Name(),
	)
	ffmpegCmdKey := fmt.Sprintf("ffmpeg_%s", thumbnailFile.Name())
	p.processes.Store(ffmpegCmdKey, ffmpegCmd)
	if err := ffmpegCmd.Run(); err != nil {
		p.processes.Delete(ffmpegCmdKey)
		return nil, fmt.Errorf("error processing video with FFmpeg: %w", err)
	}
	p.processes.Delete(ffmpegCmdKey)
	// Read the generated thumbnail file into memory
	thumbnailData, err := os.ReadFile(thumbnailFile.Name())
	if err != nil {
		return nil, fmt.Errorf("error reading thumbnail file: %w", err)
	}

	video := &kv.Video{
		FullMimeType:    getFullMimeType(filePath),
		Width:           width,
		Height:          height,
		ThumbnailWidth:  uint64(thumbWidth),
		ThumbnailHeight: uint64(thumbHeight),
		Length:          uint64(duration),
		ThumbnailData:   thumbnailData,
	}

	return video, nil
}
