#!/usr/bin/env bash
# agent_openwrt.sh end to end in a busybox container (ash + busybox awk/sed/
# sort, the same tools a router has), with canned wg/mwan3/tc/uci/logread/
# iwinfo/nft/ubus in PATH. Needs docker and python3 on the host.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/agent" "$work/out"
cp "$here/../vps-agent/agent_openwrt.sh" "$work/agent/"
cp -r "$here/openwrt-stubs" "$work/stubs"
chmod +x "$work"/stubs/bin/*
docker run --rm -v "$work:/work" busybox:1.36 sh /work/stubs/run-in-container.sh
python3 "$here/assert_openwrt_payload.py" "$work/out"
