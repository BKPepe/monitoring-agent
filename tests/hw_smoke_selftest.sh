#!/usr/bin/env bash
# hw_smoke.sh against an OpenWrt 24.10 container that stands in for a router
# (openwrt-real/router.sh, ssh on 127.0.0.1 only) - never a real one. Needs
# docker, ssh, ssh-keygen and python3.
#
# hw_smoke.sh runs under /bin/bash, which on macOS is the 3.2 a Mac user has
# (BK_HW_BASH: another one). BK_E2E_NAME: the container's name.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# The same pin as run_openwrt_real.sh.
img="openwrt/rootfs:x86-64-24.10.8@sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"
hw_bash="${BK_HW_BASH:-/bin/bash}"
agent="$here/../vps-agent/agent_openwrt.sh"
name="${BK_E2E_NAME:-bk-hwsmoke-$$}"
work="$(mktemp -d)"
cleanup() {
    docker rm -f "$name" > /dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -C bk-hwsmoke-selftest -f "$work/id"
mkdir "$work/key"
cp "$work/id.pub" "$work/key/id.pub"
docker run -d --rm --platform linux/amd64 --name "$name" --cap-add NET_ADMIN -p 127.0.0.1::22 \
    -v "$work/key:/hwkey:ro" -v "$here/openwrt-real:/harness:ro" \
    "$img" /bin/sh /harness/router.sh > /dev/null
port=$(docker port "$name" 22/tcp | head -n 1 | sed 's/.*://')
ssh_o=(-p "$port" -i "$work/id" -o "UserKnownHostsFile=$work/known_hosts" -o StrictHostKeyChecking=accept-new)
n=0
until ssh -o BatchMode=yes -o ConnectTimeout=3 "${ssh_o[@]}" root@127.0.0.1 true 2> /dev/null; do
    n=$((n + 1))
    [ "$n" -lt 60 ] || { docker logs "$name" >&2; echo "the router container never answered ssh" >&2; exit 1; }
    sleep 1
done
echo "router: $name on 127.0.0.1:$port ($(docker logs "$name" 2>&1 | grep 'router up' || true))"

failed=0
t() { # LABEL GOT WANT
    if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1 (got '$2', want '$3')"; failed=$((failed + 1)); fi
}
# hw LOG [hw_smoke options...] - its exit code in $rc, its output in LOG.
hw() {
    local log=$1
    shift
    rc=0
    "$hw_bash" "$here/hw_smoke.sh" -p "$port" -i "$work/id" \
        -o "UserKnownHostsFile=$work/known_hosts" -o StrictHostKeyChecking=accept-new \
        "$@" root@127.0.0.1 > "$work/$log" 2>&1 || rc=$?
    sed 's/^/    | /' "$work/$log"
}
in_box() { docker exec "$name" sh -c "$1"; }
# The cases after one that left something behind would test a dirty router.
stop_if_failed() {
    [ "$failed" = 0 ] || { echo "hw_smoke self-test: stopped after $failed failures"; exit 1; }
}
# Everything of the agent and of the test on the router, with checksums.
# shellcheck disable=SC2016
state() {
    in_box 'for p in $(find /tmp/status-agent-* /var/run/status-agent-openwrt /tmp/bk-hwsmoke.* 2>/dev/null | sort); do
        if [ -d "$p" ]; then echo "D $p"; else echo "F $p $(md5sum < "$p" | cut -d" " -f1)"; fi
    done; crontab -l 2>/dev/null | sed "s/^/C /"; true'
}

echo "== A: a router without the agent"
hw A.log --interval 5
t "A: exit 0" "$rc" 0
t "A: the summary ends in PASS" "$(tail -n 1 "$work/A.log")" PASS
t "A: nothing of the agent or the test is left on the router" "$(state)" ""
stop_if_failed

echo "== C: a broken agent is caught, and the router is cleaned up anyway"
sed '1a\
echo "sh: foo: not found" >&2' "$agent" > "$work/broken-stderr.sh"
hw C1.log --interval 0 --agent "$work/broken-stderr.sh"
t "C1 raw tool stderr: exit 1" "$rc" 1
t "C1: the stray line is named" "$(grep -c 'sh: foo: not found' "$work/C1.log" || true)" 1
t "C1: nothing left on the router" "$(state)" ""
sed 's/^  "agent_type": "openwrt",$/  "agent_type": "openwrt"/' "$agent" > "$work/broken-json.sh"
t "C2: the typo is really in the copy" "$(cmp -s "$agent" "$work/broken-json.sh" && echo same || echo differs)" differs
hw C2.log --interval 0 --agent "$work/broken-json.sh"
t "C2 invalid JSON: exit 1" "$rc" 1
t "C2: nothing left on the router" "$(state)" ""
stop_if_failed

echo "== B: a router that runs the agent"
docker cp "$agent" "$name:/root/agent_openwrt.sh"
in_box 'echo "* * * * * /root/agent_openwrt.sh" > /tmp/bk-cron && crontab /tmp/bk-cron && rm /tmp/bk-cron &&
    cd /root && sh agent_openwrt.sh --dry-run > /dev/null 2>&1'
before=$(state)
t "B: the installed agent left its state and a crontab line" \
    "$(printf '%s\n' "$before" | awk '/status-agent/ {n++} /^C / {c++} END {print (n >= 3 && c == 1) ? "yes" : "no"}')" yes
hw B1.log --interval 5
t "B1 without --coexist: exit 3 (refused)" "$rc" 3
t "B1: the router's agent files are untouched" "$(state)" "$before"
hw B2.log --coexist
t "B2 --coexist: exit 0" "$rc" 0
after=$(state)
t "B2: no path more or less" "$(printf '%s\n' "$after" | awk '{print $1, $2}')" "$(printf '%s\n' "$before" | awk '{print $1, $2}')"
fixed='^C |version\.stamp |/run\.(cpu|total) |/last-payload\.json '
t "B2: crontab, version stamp, run cost and last payload as they were" \
    "$(printf '%s\n' "$after" | grep -E "$fixed" || true)" "$(printf '%s\n' "$before" | grep -E "$fixed" || true)"
in_box "sed -i 's/^AGENT_VERSION=.*/AGENT_VERSION=\"0.0.1\"/' /root/agent_openwrt.sh"
before=$(state)
hw B3.log --coexist
t "B3 --coexist with another installed version: exit 3" "$rc" 3
t "B3: untouched" "$(state)" "$before"

echo "== D: not OpenWrt"
in_box 'mv /etc/openwrt_release /etc/openwrt_release.off'
hw D.log
t "D: exit 3" "$rc" 3
t "D: untouched" "$(state)" "$before"

echo "hw_smoke self-test: $([ "$failed" = 0 ] && echo "all passed" || echo "$failed failed")"
[ "$failed" = 0 ]
