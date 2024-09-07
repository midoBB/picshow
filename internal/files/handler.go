package files

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"picshow/internal/config"
	"picshow/internal/kv"
	"picshow/internal/utils"
	"strconv"
	"strings"
	"time"

	"io"

	log "github.com/sirupsen/logrus"
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
		log.WithError(err).Error("Error getting file mimetype")
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
func (h *handler) generateFileKey(filePath string) (string, error) {
	fileInfo, err := os.Stat(filePath)
	if err != nil {
		log.WithError(err).Error("Error getting file info")
		return "", fmt.Errorf("error getting file info: %w", err)
	}
	fileSize := fileInfo.Size()

	var contentHash string
	if fileSize <= 5*1024*1024 { // 5MB
		log.Debugf("Hashing file %s using xxhsum", filePath)
		// Use xxhsum to hash the entire file for files 5MB or smaller
		cmd := exec.Command("xxhsum", filePath)
		output, err := cmd.Output()
		if err != nil {
			log.WithError(err).Errorf("Error executing xxhsum on %s", filePath)
			return "", fmt.Errorf("error executing xxhsum: %w", err)
		}

		// Parse the xxhsum output
		parts := strings.Fields(string(output))
		if len(parts) < 2 {
			log.Errorf("Unexpected xxhsum output format: %s", string(output))
			return "", fmt.Errorf("unexpected xxhsum output format")
		}
		contentHash = parts[0]
	} else {
		log.Debugf("Hashing file %s using xxhsum with dd", filePath)

		// Use dd to read the first 5MB of the file and pipe it to xxhsum for larger files
		ddCmd := exec.Command("dd", "if="+filePath, fmt.Sprintf("bs=%dK", h.config.HashSize), "count=1")
		xxhsumCmd := exec.Command("xxhsum")

		// Create a pipe to connect dd's stdout to xxhsum's stdin
		ddStdout, err := ddCmd.StdoutPipe()
		if err != nil {
			log.WithError(err).Errorf("Error creating stdout pipe for dd on %s", filePath)
			return "", fmt.Errorf("error creating stdout pipe for dd: %w", err)
		}
		xxhsumCmd.Stdin = ddStdout

		// Get xxhsum's stdout pipe
		xxhsumOutput, err := xxhsumCmd.StdoutPipe()
		if err != nil {
			log.WithError(err).Errorf("Error creating stdout pipe for xxhsum on %s", filePath)
			return "", fmt.Errorf("error creating stdout pipe for xxhsum: %w", err)
		}

		// Start both commands
		if err := xxhsumCmd.Start(); err != nil {
			log.WithError(err).Errorf("Error starting xxhsum on %s", filePath)
			return "", fmt.Errorf("error starting xxhsum: %w", err)
		}

		if err := ddCmd.Start(); err != nil {
			log.WithError(err).Errorf("Error starting dd on %s", filePath)
			return "", fmt.Errorf("error starting dd: %w", err)
		}

		// Wait for dd to finish
		if err := ddCmd.Wait(); err != nil {
			log.WithError(err).Errorf("Error running dd on %s", filePath)
			return "", fmt.Errorf("error running dd: %w", err)
		}

		// Close dd's stdout to signal EOF to xxhsum
		ddStdout.Close()

		// Read xxhsum output
		hashOutput, err := io.ReadAll(io.Reader(xxhsumOutput))
		if err != nil {
			log.WithError(err).Errorf("Error reading xxhsum output on %s", filePath)
			return "", fmt.Errorf("error reading xxhsum output: %w", err)
		}

		// Wait for xxhsum to finish
		if err := xxhsumCmd.Wait(); err != nil {
			log.WithError(err).Errorf("Error waiting for xxhsum on %s", filePath)
			return "", fmt.Errorf("error waiting for xxhsum: %w", err)
		}

		parts := strings.Fields(string(hashOutput))
		if len(parts) == 0 {
			log.Errorf("Unexpected xxhsum output format: %s", string(hashOutput))
			return "", fmt.Errorf("unexpected xxhsum output format")
		}

		contentHash = parts[0]
	}

	log.Debugf("Generated file key %s for %s", contentHash, filePath)

	key := fmt.Sprintf("%d_%s", fileSize, contentHash)
	return key, nil
}

func (h *handler) handleNewImage(p *Processor, filePath string) (*kv.Image, error) {
	log.Debugf("Processing new image: %s", filePath)
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
		log.WithError(err).Errorf("Error executing ImageMagick identify command on %s", filePath)
		return nil, fmt.Errorf("error executing ImageMagick identify command: %w", err)
	}
	p.processes.Delete(identifyCmdKey)
	// Parse the output to get width and height
	var width, height int
	_, err = fmt.Sscanf(string(output), "%dx%d", &width, &height)
	if err != nil {
		log.WithError(err).Errorf("Error parsing image dimensions from %s", string(output))
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

	// generate 5 random letters as fileName prefix
	fileName := rand.New(rand.NewSource(time.Now().UnixNano())).Intn(100000)
	// Generate temporary file path for thumbnail
	tempFile := filepath.Join(os.TempDir(), strconv.FormatInt(int64(fileName), 10)+strconv.FormatUint(uint64(thumbWidth), 10)+"x"+strconv.FormatUint(uint64(thumbHeight), 10)+".jpg")
	log.Debugf("Generating thumbnail for %s at %s", filePath, tempFile)
	// Construct and execute ImageMagick convert command
	cmd := exec.Command(
		"convert",
		filePath,
		"-thumbnail", strconv.Itoa(int(thumbWidth))+"x"+strconv.Itoa(int(thumbHeight)),
		"-depth", "8",
		"-quality", "85",
		"-filter", "Triangle",
		tempFile,
	)
	convCmdKey := fmt.Sprintf("conver_%s", tempFile)
	p.processes.Store(convCmdKey, cmd)
	err = cmd.Run()
	if err != nil {
		p.processes.Delete(convCmdKey)
		log.WithError(err).Errorf("Error executing ImageMagick convert command on %s", filePath)
		return nil, fmt.Errorf("error executing ImageMagick convert command: %w", err)
	}
	p.processes.Delete(convCmdKey)
	p.tempFiles.Store(tempFile, tempFile)
	defer os.Remove(tempFile)
	defer p.tempFiles.Delete(tempFile)
	// Read thumbnail file into memory
	thumbnailData, err := os.ReadFile(tempFile)
	if err != nil {
		log.WithError(err).Errorf("Error reading thumbnail file %s", tempFile)
		return nil, fmt.Errorf("error reading thumbnail file: %w", err)
	}

	log.Debugf("Generated thumbnail for %s", filePath)

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
	log.Debugf("Processing new video: %s", filePath)
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
		log.WithError(err).Errorf("Error running ffprobe on %s\nstderr: %s", filePath, stderr.String())
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
		log.WithError(err).Errorf("Error parsing ffprobe output for %s", filePath)
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
		log.WithError(err).Errorf("Error parsing video duration from %s", probeResult.Format.Duration)
		return nil, fmt.Errorf("error parsing video duration: %w", err)
	}

	log.Debugf("Generating thumbnail for video %s", filePath)

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
		log.WithError(err).Error("Error creating temporary file for video thumbnail")
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
		log.WithError(err).Errorf("Error processing video %s with FFmpeg", filePath)
		return nil, fmt.Errorf("error processing video with FFmpeg: %w", err)
	}
	p.processes.Delete(ffmpegCmdKey)
	// Read the generated thumbnail file into memory
	thumbnailData, err := os.ReadFile(thumbnailFile.Name())
	if err != nil {
		log.WithError(err).Errorf("Error reading thumbnail file %s", thumbnailFile.Name())
		return nil, fmt.Errorf("error reading thumbnail file: %w", err)
	}

	log.Debugf("Generated thumbnail for %s", filePath)

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
