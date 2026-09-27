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
    # A .passed left there by an earlier run must not vouch for this one.
    [ -z "${BK_E2E_KEEP:-}" ] || { mkdir -p "$BK_E2E_KEEP" && rm -f "$BK_E2E_KEEP/.passed" &&
        cp -R "$work/out/." "$BK_E2E_KEEP/"; }
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
# Its own checks passed: golden.py update takes a kept out/ only with this.
# Before the golden check on purpose - a new key fails that one, and this is
# the run the golden file is renewed from.
touch "$work/out/.passed"
# Every payload run (out/payload_runs.txt) has the shape of golden/openwrt.json.
# update_golden.sh sets BK_GOLDEN_CHECK=0: it runs the harness to renew them.
[ "${BK_GOLDEN_CHECK:-1}" = 0 ] || python3 "$here/golden.py" check "$work/out"
