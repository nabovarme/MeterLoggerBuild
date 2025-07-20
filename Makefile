# Default target: ensure version.txt exists, update submodules, build
all: build

# Generate a version string like: branch-commitcount-hash
GIT_VERSION := $(shell \
	cd MeterLogger && \
	git rev-parse --abbrev-ref HEAD 2>/dev/null)-$(shell \
	cd MeterLogger && \
	git rev-list HEAD --count 2>/dev/null)-$(shell \
	cd MeterLogger && \
	git describe --abbrev=4 --dirty --always 2>/dev/null)

# Write version.txt (only if Git is available)
version.txt:
	@echo "Writing version.txt: $(GIT_VERSION)"
	@echo "$(GIT_VERSION)" > version.txt

# Ensure submodules are initialized and updated
update-submodules:
	git submodule update --init MeterLogger
	cd MeterLogger && git checkout master && git pull origin master

# Ensure release directory exists on host
release-dir:
	@mkdir -p release

# Build Docker image
build:
	docker build -t meterlogger .

# Run container and inject GIT_VERSION as environment variable
sh:
	docker run -it -e GIT_VERSION=$(GIT_VERSION) meterlogger:latest /bin/bash

# Firmware build (ensure release dir exists first)
firmware: version.txt release-dir
	docker run -it \
		-e GIT_VERSION=$(GIT_VERSION) \
		-v $(CURDIR)/release:/meterlogger/MeterLogger/release \
		meterlogger:latest make clean all $(MAKEFLAGS)
