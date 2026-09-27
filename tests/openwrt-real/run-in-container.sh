#!/bin/sh
# Runs inside an official openwrt/rootfs image (see ../run_openwrt_real.sh):
# the router's services come up (boot.sh), then agent_openwrt.sh runs twice
# with a plain --dry-run, as the owner would type it - no STATUS_TEST_* seam,
# no stub, no fake /sys. The second run has the deltas.
#
#   run-in-container.sh VER - writes /work/out/VER_r{1,2}.{json,err,rc},
#   VER_env.txt, VER_boot.log and VER_boot_fail.txt (the services not up;
#   assert_real_payload.py fails the run unless it is empty)
set -u
ver=$1
OUT=/work/out
mkdir -p "$OUT"

. /harness/boot.sh
bk_boot "$OUT/${ver}_boot.log" "$OUT/${ver}_env.txt"
sed -n -e 's/^DISTRIB_DESCRIPTION=/  /p' -e 's/^DISTRIB_REVISION=/  /p' /etc/openwrt_release
echo "  services not up:${bk_boot_fail:- none}"
echo "$bk_boot_fail" > "$OUT/${ver}_boot_fail.txt"

mkdir -p /root/agent
cp /work/agent/agent_openwrt.sh /root/agent/
cd /root/agent || exit 1
for r in 1 2; do
    [ "$r" = 1 ] || sleep 5
    sh agent_openwrt.sh --dry-run > "$OUT/${ver}_r$r.json" 2> "$OUT/${ver}_r$r.err"
    echo "$?" > "$OUT/${ver}_r$r.rc"
    echo "  r$r exit $(cat "$OUT/${ver}_r$r.rc")"
done
# The run facts after the fact: what the agent itself left in the log.
logread > "$OUT/${ver}_logread.txt" 2>&1
exit 0
