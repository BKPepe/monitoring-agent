#!/usr/bin/env bash
# agent_openwrt.sh with a plain --dry-run in the official OpenWrt rootfs
# images (x86_64): the real busybox, ubus, procd, netifd, jshn, jsonfilter,
# uci, fw4 and dnsmasq instead of stubs. openwrt-real/boot.sh brings the
# services up, the agent runs twice, assert_real_payload.py checks both runs.
# Needs docker and python3 on the host.
#
#   run_openwrt_real.sh [24.10|master|all]    (default: all)
#
# BK_OWRT_MASTER_IMAGE: another master image, e.g. a last-good digest to pin
# while an upstream snapshot is broken. BK_E2E_NAME: prefix of the container
# names. BK_E2E_KEEP=<dir>: keep out/ there.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# 24.10 is pinned, so a new point release is a commit here. master floats on
# purpose: OpenWrt work is tested on master, and a red run there is news.
img_2410="openwrt/rootfs:x86-64-24.10.8@sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"
img_master="${BK_OWRT_MASTER_IMAGE:-openwrt/rootfs:x86-64-master}"

case "${1:-all}" in
    24.10) vers="24.10" ;;
    master) vers="master" ;;
    all) vers="24.10 master" ;;
    *) echo "usage: $0 [24.10|master|all]" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
. "$here/e2e_cleanup.sh"
keep_out() {
    [ -z "${BK_E2E_KEEP:-}" ] || { mkdir -p "$BK_E2E_KEEP" && cp -R "$work/out/." "$BK_E2E_KEEP/"; }
}
prefix="${BK_E2E_NAME:-bk-owrt-real-$$}"
cleanup_img="$img_2410"
trap 'bk_e2e_exit $? "$work" "$cleanup_img" "$prefix" keep_out' EXIT
mkdir -p "$work/agent" "$work/out"
cp "$here/../vps-agent/agent_openwrt.sh" "$work/agent/"

rc=0
for ver in $vers; do
    img="$img_2410"
    [ "$ver" = master ] && img="$img_master"
    cleanup_img="$img"
    echo "== OpenWrt $ver ($img)"
    # The images are x86_64 only: on an arm64 host the flag makes docker
    # emulate instead of failing with "no matching manifest"; on CI it
    # changes nothing. NET_ADMIN reaches only the container's own network
    # namespace: fw4 loads its table there, netifd configures eth0.
    docker run --rm --platform linux/amd64 --name "$prefix-$ver" --cap-add NET_ADMIN \
        -v "$work:/work" -v "$here/openwrt-real:/harness:ro" \
        "$img" /bin/sh /harness/run-in-container.sh "$ver"
    # Which snapshot a red master run was, for the pin.
    echo "  image $(docker image inspect -f '{{join .RepoDigests " "}}' "$img" 2>/dev/null || echo '?')"
    python3 "$here/assert_real_payload.py" "openwrt-$ver" "$work/out" || rc=1
done
exit "$rc"
