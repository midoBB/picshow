# Project name
PROJECT_NAME := picshow

# Source directory
SRC_DIR := src

# Frontend directory
FRONTEND_DIR := app_frontend

# First run frontend directory
FIRST_RUN_DIR := first_run_frontend

# Timestamp files
FRONTEND_TIMESTAMP = $(FRONTEND_DIR)/.build_timestamp
FIRSTRUN_TIMESTAMP = $(FIRST_RUN_DIR)/.build_timestamp

# Output directory
TARGET_DIR := target

# x86_64 MUSL target
X86_64_TARGET := x86_64-unknown-linux-musl
X86_64_BIN := $(TARGET_DIR)/$(X86_64_TARGET)/release/$(PROJECT_NAME)

# ARMv7 MUSL target
ARMV7_TARGET := armv7-unknown-linux-musleabihf
ARMV7_BIN := $(TARGET_DIR)/$(ARMV7_TARGET)/release/$(PROJECT_NAME)

# Find all Rust source files
RUST_FILES := $(shell find $(SRC_DIR) -name '*.rs')

# Find all the javascript files
JS_FILES := $(shell find $(FRONTEND_DIR) -name '*.tsx' -o -name '*.ts' -o -name '*.svg')
JS_NO_SVG := $(shell find $(FRONTEND_DIR) -name '*.tsx' -o -name '*.ts')


# Frontend source files (excluding dist folders)
FRONTEND_FILES := $(shell find $(FRONTEND_DIR) -type f \( -name '*.tsx' -o -name '*.ts' -o -name '*.css' -o -name '*.html' \) -not -path "*/dist/*" -not -path "*/node_modules/*")
FIRSTRUN_FILES := $(shell find $(FIRST_RUN_DIR) -type f \( -name '*.tsx' -o -name '*.ts' -o -name '*.css' -o -name '*.html' \) -not -path "*/dist/*" -not -path "*/node_modules/*")

# Default target
all: $(PROJECT_NAME)_x64 $(PROJECT_NAME)_arm

$(FRONTEND_TIMESTAMP): $(FRONTEND_FILES)
	@cd $(FRONTEND_DIR) && pnpm install && pnpm build
	@touch $@

$(FIRSTRUN_TIMESTAMP): $(FIRSTRUN_FILES)
	@cd $(FIRST_RUN_DIR) && pnpm install && pnpm build
	@touch $@

frontends: $(FRONTEND_TIMESTAMP) $(FIRSTRUN_TIMESTAMP)
	@echo "Frontends built"
.PHONY: frontends

format: $(RUST_FILES) $(JS_FILES)
	@rustfmt --emit files --edition 2021 $(RUST_FILES)
	@echo "Rust files formatted"
	@cd $(FRONTEND_DIR) && pnpm install
	@$(FRONTEND_DIR)/node_modules/.bin/prettier $(JS_NO_SVG) --write --log-level error
	@echo "JS files formatted"
.PHONY: format

# x86_64 MUSL target
$(PROJECT_NAME)_x64: format Cargo.toml Cargo.lock frontends
	@cargo build --target $(X86_64_TARGET) --release --quiet
	@rm -f $(PROJECT_NAME)_x64
	@mv $(X86_64_BIN) -f $(PROJECT_NAME)_x64
	@echo 'Built x86_64 MUSL target'

# ARMv7 MUSL target
$(PROJECT_NAME)_arm: format Cargo.toml Cargo.lock frontends
	@cargo build --target $(ARMV7_TARGET) --release --quiet
	@rm -f $(PROJECT_NAME)_arm
	@mv $(ARMV7_BIN) -f $(PROJECT_NAME)_arm
	@echo 'Built ARMv7 MUSL target'

# Clean build artifacts
.PHONY: clean
clean:
	@cargo clean
	@rm -f $(PROJECT_NAME)_x64 $(PROJECT_NAME)_arm
	@cd $(FRONTEND_DIR) && rm -rf dist node_modules
	@cd $(FIRST_RUN_DIR) && rm -rf dist node_modules
	@echo "Project Cleaned"

.PHONY: run
run:
	@cargo run -- serve -l debug

.PHONY: run-front
run-front:
	@cd $(FRONTEND_DIR) && pnpm run dev

gen-docs: Cargo.toml Cargo.lock
	@cargo doc --no-deps

.PHONY: docs
docs: gen-docs
	@xdg-open target/doc/picshow/index.html &
	@xdg-open /home/mh/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/share/doc/rust/html/std/index.html &


deploy: $(PROJECT_NAME)_arm
	./deploy.sh
