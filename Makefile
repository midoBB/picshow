# Makefile

# Phony targets
.PHONY: all build-x64 build-arm dev clean build-frontends deploy run-frontend run-firstrun run-backend

# Variables
GO = go
GOOS = linux
GOARCH_AMD64 = amd64
GOARCH_ARM = arm
CGO_ENABLED = 0
LDFLAGS = -ldflags="-s -w"

# Main executable
EXECUTABLE = picshow

# Directories
FRONTEND_DIR = internal/frontend
FIRSTRUN_DIR = internal/firstrun

# Timestamp files
FRONTEND_TIMESTAMP = $(FRONTEND_DIR)/.build_timestamp
FIRSTRUN_TIMESTAMP = $(FIRSTRUN_DIR)/.build_timestamp

# Go source files
GO_FILES := $(shell find . -name '*.go')

# Frontend source files (excluding dist folders)
FRONTEND_FILES := $(shell find $(FRONTEND_DIR) -type f \( -name '*.tsx' -o -name '*.ts' -o -name '*.css' -o -name '*.html' \) -not -path "*/dist/*")
FIRSTRUN_FILES := $(shell find $(FIRSTRUN_DIR) -type f \( -name '*.tsx' -o -name '*.ts' -o -name '*.css' -o -name '*.html' \) -not -path "*/dist/*")

all: build-x64

$(FRONTEND_TIMESTAMP): $(FRONTEND_FILES)
	cd $(FRONTEND_DIR) && pnpm build
	touch $@

$(FIRSTRUN_TIMESTAMP): $(FIRSTRUN_FILES)
	cd $(FIRSTRUN_DIR) && pnpm build
	touch $@

build-frontends: $(FRONTEND_TIMESTAMP) $(FIRSTRUN_TIMESTAMP)

build-arm: $(FRONTEND_TIMESTAMP) $(FIRSTRUN_TIMESTAMP) $(GO_FILES)
	env CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) GOARCH=$(GOARCH_ARM) $(GO) build $(LDFLAGS) -o $(EXECUTABLE)_arm

build-x64: $(FRONTEND_TIMESTAMP) $(FIRSTRUN_TIMESTAMP) $(GO_FILES)
	env CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) GOARCH=$(GOARCH_AMD64) $(GO) build $(LDFLAGS) -o $(EXECUTABLE)_x64

dev:
	air

run-frontend:
	cd $(FRONTEND_DIR) && pnpm dev

run-firstrun:
	cd $(FIRSTRUN_DIR) && pnpm dev

run-backend:
	$(GO) run .

clean:
	rm -f $(EXECUTABLE)_x64 $(EXECUTABLE)_arm
	rm -rf $(FRONTEND_DIR)/dist $(FIRSTRUN_DIR)/dist
	rm -f $(FRONTEND_TIMESTAMP) $(FIRSTRUN_TIMESTAMP)

deploy: build-arm
	./deploy.sh
