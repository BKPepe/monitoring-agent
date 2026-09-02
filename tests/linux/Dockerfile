# Minimal Debian with exactly the tools agent.sh and agent.py rely on
# (procps for ps, curl/wget, awk, iproute2, util-linux for flock).
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        procps curl wget openssl python3 mawk iproute2 util-linux ca-certificates dnsutils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /agent
