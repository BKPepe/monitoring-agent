#!/usr/bin/env bash
# agent.sh and agent.py end to end in a Debian container: real /proc, real
# ps, two runs each so deltas exist. Needs docker and python3 on the host.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/agent" "$work/out"
cp "$here/../vps-agent/agent.sh" "$here/../vps-agent/agent.py" "$work/agent/"
docker build -q -t bk-agent-e2e "$here/linux" >/dev/null
docker run --rm -v "$work:/work" -v "$here/linux:/harness:ro" bk-agent-e2e bash /harness/run-in-container.sh
python3 "$here/assert_linux_payload.py" "$work/out"
