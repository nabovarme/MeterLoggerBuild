FROM debian:bookworm

RUN apt-get update && apt-get install -y \
    perl \
    libwww-perl \
    libjson-perl \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY watcher.pl .

CMD ["perl", "watcher.pl"]
