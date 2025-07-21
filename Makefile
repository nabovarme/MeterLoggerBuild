.PHONY: all build firmware sh build-esptool-image clean-containers

# Default target: build everything (only rebuild esptool.pyz if needed)
all: esptool build

# Generate a version string like: branch-commitcount-hash
GIT_VERSION := $(shell \
	cd MeterLogger && \
	git rev-parse --abbrev-ref HEAD 2>/dev/null)-$(shell \
	cd MeterLogger && \
	git rev-list HEAD --count 2>/dev/null)-$(shell \
	cd MeterLogger && \
	git describe --abbrev=4 --dirty --always 2>/dev/null)

# Ensure submodules are initialized and updated
update-submodules:
	git submodule update --init MeterLogger
	cd MeterLogger && git checkout master && git pull origin master

# Write version.txt (only if Git is available)
version.txt:
	@echo "Writing version.txt: $(GIT_VERSION)"
	@echo "$(GIT_VERSION)" > version.txt

# Ensure release directory exists on host
release-dir:
	@mkdir -p release

# Ensure esptool directory exists on host
esptool-dir:
	@mkdir -p esptool

# Build Docker image for esptool (only when Dockerfile changes)
build-esptool-image: Dockerfile.esptool
	docker build -f Dockerfile.esptool -t meterlogger-esptool .

# Build esptool.pyz (only if missing or inputs changed)
esptool/esptool.pyz: build-esptool-image esptool-dir $(shell find esptool -type f) Dockerfile.esptool
	@echo "Building esptool.pyz..."
	# Create a container from the image (detached)
	docker create --name esptool-builder meterlogger-esptool
	# Copy esptool.pyz from container to host folder
	docker cp esptool-builder:/home/meterlogger/esptool/esptool.pyz ./esptool/
	# Remove container
	docker rm esptool-builder

# Meta target to depend on the actual file
esptool: esptool/esptool.pyz

# Build main Docker images (doesn't rebuild esptool.pyz unnecessarily)
build:
	docker build -t meterlogger .

# Run container with GIT_VERSION
sh:
	docker run -it -e GIT_VERSION=$(GIT_VERSION) meterlogger:latest /bin/bash

# Firmware build (ensure release dir exists first)
firmware: version.txt release-dir
	docker run -it \
		-e GIT_VERSION=$(GIT_VERSION) \
		-v $(CURDIR)/release:/meterlogger/MeterLogger/release \
		meterlogger:latest make clean all $(MAKEFLAGS)

# Remove leftover containers (including esptool-builder)
clean-containers:
	@echo "Cleaning up stopped containers..."
	-docker rm -f esptool-builder 2>/dev/null || true
	# Optional: remove *all* stopped containers
	-docker ps -aq -f status=exited | xargs -r docker rm
