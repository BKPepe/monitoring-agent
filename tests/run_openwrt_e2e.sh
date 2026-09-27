#!/usr/bin/env bash
# agent_openwrt.sh end to end in a busybox container (ash + busybox awk/sed/
# sort, the same tools a router has), with canned wg/mwan3/tc/uci/logread/
# iwinfo/nft/ubus in PATH. Needs docker and python3 on the host.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
. "$here/e2e_cleanup.sh"
# BK_E2E_KEEP=<dir>: keep the payloads, logs and call records there.
keep_out() {
    [ -z "${BK_E2E_KEEP:-}" ] || { mkdir -p "$BK_E2E_KEEP" && cp -R "$work/out/." "$BK_E2E_KEEP/"; }
}
trap 'bk_e2e_exit $? "$work" busybox:1.36 "${BK_E2E_NAME:-}" keep_out' EXIT
mkdir -p "$work/agent" "$work/out"
cp "$here/../vps-agent/agent_openwrt.sh" "$work/agent/"
cp -r "$here/openwrt-stubs" "$work/stubs"
chmod +x "$work"/stubs/bin/*
# BK_E2E_NAME: an optional container name, so a shared Docker host can tell
# whose run it is (and a stuck one can be removed by name).
docker run --rm ${BK_E2E_NAME:+--name "$BK_E2E_NAME"} -v "$work:/work" busybox:1.36 sh /work/stubs/run-in-container.sh
python3 "$here/assert_openwrt_payload.py" "$work/out"
