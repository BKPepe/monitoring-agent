# Ubuntu 24.04 LTS as a server has it, plus exactly what the Linux agents
# need. Nothing more: a tool a stock server lacks has to show as a null.
FROM ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        procps python3 iproute2 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
