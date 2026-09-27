#!/usr/bin/env bash
# Renews the golden payloads (tests/golden/*.json) from fresh harness runs;
# see tests/README.md, "Golden payloads". Commit the diff of tests/golden/
# together with the agent change that caused it.
#
#   update_golden.sh [openwrt|linux|all] [--accept KEY]...    (default: all)
#
# openwrt runs run_openwrt_e2e.sh (about 10 min) and run_openwrt_real.sh
# (1-2 min), linux runs run_linux_e2e.sh and run_linux_distros.sh (about
# 6 min). Every harness still has to pass all its other checks: a golden file
# is never made from a run that failed (golden.py update wants the .passed
# each harness writes). A key that changes its shape or goes is refused
# unless --accept KEY names it: the agent change intends it. BK_E2E_KEEP=<dir>
# keeps the runs (<dir>/stub, real, debian, distros); with passed runs
# already kept, call `python3 tests/golden.py update AGENT DIR...` directly.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: $0 [openwrt|linux|all] [--accept KEY]..." >&2; exit 2; }
what=all
accept=()
while [ $# -gt 0 ]; do
    case "$1" in
        openwrt|linux|all) what=$1 ;;
        --accept) [ $# -ge 2 ] || usage; accept+=(--accept "$2"); shift ;;
        *) usage ;;
    esac
    shift
done
case "$what" in
    openwrt) agents="openwrt" ;;
    linux) agents="linux" ;;
    *) agents="openwrt linux" ;;
esac

if [ -n "${BK_E2E_KEEP:-}" ]; then
    keep="$BK_E2E_KEEP"
    mkdir -p "$keep"
else
    keep="$(mktemp -d)"
    trap 'rm -rf "$keep"' EXIT
fi
# The harnesses skip their own golden check: renewing it is the point.
export BK_GOLDEN_CHECK=0

dirs=()
for a in $agents; do
    if [ "$a" = openwrt ]; then
        BK_E2E_KEEP="$keep/stub" bash "$here/run_openwrt_e2e.sh"
        BK_E2E_KEEP="$keep/real" bash "$here/run_openwrt_real.sh" all
        # The stub runs first: masked data of a real router, every collector
        # fed. The real images add what only they measure.
        python3 "$here/golden.py" update openwrt ${accept[@]+"${accept[@]}"} "$keep/stub" "$keep/real"
        dirs+=("$keep/stub" "$keep/real")
    else
        BK_E2E_KEEP="$keep/debian" bash "$here/run_linux_e2e.sh"
        BK_E2E_KEEP="$keep/distros" bash "$here/run_linux_distros.sh" all
        python3 "$here/golden.py" update linux-bash ${accept[@]+"${accept[@]}"} "$keep/debian" "$keep/distros"
        python3 "$here/golden.py" update linux-python ${accept[@]+"${accept[@]}"} "$keep/debian" "$keep/distros"
        dirs+=("$keep/debian" "$keep/distros")
    fi
done
# What the harnesses will check from now on.
python3 "$here/golden.py" check "${dirs[@]}"
git -C "$here/.." status --short -- tests/golden
