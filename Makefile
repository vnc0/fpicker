.PHONY: default build clean help fpicker-macos fpicker-linux fpicker-ios libfrida-core.a frida-core.h prepare-frida

.DEFAULT_GOAL := default
MAKEFLAGS += --no-print-directory --silent

# --- Configuration ---
FRIDA_VERSION := 17.2.3
FRIDA_RELEASE_URL := https://github.com/frida/frida/releases/download/$(FRIDA_VERSION)

# --- Host Environment Detection ---
HOST_OS := $(shell uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/')
HOST_ARCH := $(shell uname -m)

# --- Build Variables ---
OS ?= $(HOST_OS)
CC ?= clang

# Default to arm64 for iOS builds, but allow override
ifeq ($(filter fpicker-ios,$(MAKECMDGOALS)),fpicker-ios)
    ARCH ?= arm64
else
    ARCH ?= $(HOST_ARCH)
endif

# --- Common Compiler and Linker Flags ---
COMMON_CFLAGS := -fPIC -ffunction-sections -fdata-sections -Wall -Os -pipe -g3
COMMON_LDFLAGS := -ldl -lm -lresolv -pthread

# --- Source Files ---
SOURCES := fpicker.c fp_communication.c fp_standalone_mode.c fp_afl_mode.c

# --- Main Targets ---
default:
	@echo "Run 'make help' for more information."
	$(MAKE) build

build:
	@echo "Building for host system ($(HOST_OS)-$(HOST_ARCH)) ..."
	$(MAKE) ARCH=$(ARCH) \
	 fpicker-$(HOST_OS)

fpicker-macos:
	$(MAKE) OS=macos CC="xcrun -r clang" \
		ARCH=$(ARCH) \
		TARGET_LDFLAGS="-lbsm" \
		TARGET_FRAMEWORKS="-framework Foundation -framework CoreGraphics -framework AppKit -framework IOKit -framework Security" \
		fpicker-macos-$(ARCH)

fpicker-linux:
	$(MAKE) OS=linux \
		ARCH=$(ARCH) \
		TARGET_LDFLAGS="-lrt -Wl,--export-dynamic -Wl,--gc-sections,-z,noexecstack" \
		TARGET_FRAMEWORKS="" \
		fpicker-linux-$(ARCH)

fpicker-ios:
	$(MAKE) OS=ios CC="xcrun -sdk iphoneos -r clang" \
		ARCH=$(ARCH) \
		TARGET_CFLAGS="-arch $(ARCH)" \
		TARGET_LDFLAGS="-arch $(ARCH)" \
		TARGET_FRAMEWORKS="-framework Foundation -framework CoreGraphics -framework UIKit -framework IOKit -framework Security" \
		fpicker-ios-$(ARCH)
	@echo "Fakesigning fpicker-ios-$(ARCH)..."
	ldid -S fpicker-ios-$(ARCH)

# --- Build Rule ---
fpicker-%-$(ARCH): $(SOURCES) 
	@echo "Building $@..."
	rm -f libfrida-core.a frida-core.h
	$(MAKE) prepare-frida OS=$(OS) ARCH=$(ARCH)
	$(CC) $(COMMON_CFLAGS) $(TARGET_CFLAGS) $(TARGET_FRAMEWORKS) \
		$(SOURCES) -o $@ \
		-L. -lfrida-core $(COMMON_LDFLAGS) $(TARGET_LDFLAGS)
	@echo "Build complete: $@"

# --- Devkit Copy rules ---
prepare-frida: frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH)/.extracted
	@echo "Preparing Frida devkit files for $(OS)-$(ARCH)..."
	$(MAKE) libfrida-core.a
	$(MAKE) frida-core.h

libfrida-core.a: frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH)/.extracted
	@echo "Copying libfrida-core.a for $(OS)-$(ARCH)..."
	cp -f "frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH)/libfrida-core.a" .

frida-core.h: frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH)/.extracted
	@echo "Copying frida-core.h for $(OS)-$(ARCH)..."
	cp -f "frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH)/frida-core.h" .

# --- Devkit Extract Rule ---
frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH)/.extracted: frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH).tar.xz
	@if [ -d "frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH)" ]; then \
		echo "Removing existing devkit directory frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH)..."; \
		rm -rf "frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH)"; \
	fi
	@echo "Creating devkit directory frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH)..."
	@mkdir -p "frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH)"
	@echo "Extracting $< into frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH)..."
	@tar -Jxf $< -C "frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH)" --strip-components=1
	@touch $@
	@echo "Devkit for $(OS)-$(ARCH) extracted."

# --- Devkit Download Rule ---
frida-core-devkit-$(FRIDA_VERSION)-$(OS)-$(ARCH).tar.xz:
	@URL="$(FRIDA_RELEASE_URL)/$@"; \
	if [ ! -f $@ ]; then \
		echo "Downloading $$URL..."; \
		if command -v wget >/dev/null 2>&1; then \
			wget --quiet "$$URL" -O $@; \
		elif command -v curl >/dev/null 2>&1; then \
			curl --fail --silent --show-error --location "$$URL" -o $@; \
		else \
			echo "Error: Neither wget nor curl is available"; exit 1; \
		fi; \
		if [ $$? -ne 0 ] || [ ! -f $@ ] || [ $$(stat -f%z $@ 2>/dev/null || stat -c%s $@ 2>/dev/null) -lt 1000 ]; then \
			echo "Error: Download failed or file is too small"; rm -f $@; exit 1; \
		fi; \
		echo "Downloaded $@ successfully."; \
	else \
		echo "Using existing $@"; \
	fi

# --- Clean Target ---
clean:
	@echo "Cleaning..."
	rm -rf fpicker-*.dSYM
	rm -rf frida-core-devkit-*/
	rm -f fpicker-*
	rm -f libfrida-core.a frida-core.h
	rm -f frida-core-devkit-*.tar.xz
	@echo "Clean complete"

# --- Help Target ---
help:
	@echo "Usage: make TARGET [VARIABLE=VALUE ...]"
	@echo
	@echo "MAIN TARGETS:"
	@echo "  build            Build for host system ($(HOST_OS)-$(HOST_ARCH))"
	@echo "  fpicker-macos    Build for macOS"
	@echo "  fpicker-linux    Build for Linux"
	@echo "  fpicker-ios      Build for iOS"
	@echo "  prepare-frida    Prepare Frida devkit files"
	@echo "  clean            Remove all build artifacts and downloaded files"
	@echo "  help             Display this help information"
	@echo
	@echo "BUILD VARIABLES:"
	@echo "  OS               Target operating system"
	@echo "  ARCH             Target architecture"
	@echo "  CC               C compiler to use"
	@echo "  FRIDA_VERSION    Frida devkit version ($(FRIDA_VERSION))"
	@echo