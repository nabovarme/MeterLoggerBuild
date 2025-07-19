all: update-submodules build

# Ensure submodules are initialized and updated
update-submodules:
	git submodule update --init --recursive

build:
	docker build -t meterlogger .

run:
	docker run -it meterlogger:latest /bin/bash
