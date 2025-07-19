# MeterLoggerBuild

This repository builds the MeterLogger firmware using Docker.

## Setup

1. Clone this repo with submodules:
```bash
git clone --recursive https://github.com/nabovarme/MeterLoggerBuild.git

2. Build the image:
```bash
docker build -t meterlogger-build .

3. Run the build:
```bash
docker run --rm -it -v $(pwd)/MeterLogger:/meterlogger/MeterLogger meterlogger-build
