# MeterLoggerBuild

This repository builds the MeterLogger firmware using Docker.

## Setup

1. Clone this repo **with submodules** (this will fetch the `MeterLogger` source automatically):
```bash
git clone --recursive https://github.com/nabovarme/MeterLoggerBuild.git
cd MeterLoggerBuild

2. Build and run using the included Makefile:
```bash
make          # Updates submodules and builds the Docker image
make run      # Starts a shell inside the container
