all: build

build:
	docker build -t meterlogger .

run:
	docker run -it meterlogger:latest /bin/bash
