#!/bin/sh
# Runs inside the busybox container (see ../run_openwrt_e2e.sh). The router
# tools the agent shells out to are replaced by the canned stubs in bin/, so
# every parser in agent_openwrt.sh sees realistic output and the payload can
# be asserted field by field. Two runs, so the second one has deltas.
set -e
mkdir -p /usr/share/libubox /etc/config /etc/init.d /root/agent /work/out
cp /work/stubs/jshn.sh /usr/share/libubox/jshn.sh
touch /etc/config/mwan3 /etc/config/sqm /etc/init.d/dnsmasq /etc/init.d/uhttpd
cp /work/agent/agent_openwrt.sh /root/agent/agent_openwrt.sh
export PATH="/work/stubs/bin:$PATH"
cd /root/agent
sh agent_openwrt.sh --dry-run > /work/out/r1.json 2>/work/out/e1.txt
sleep 2
sh agent_openwrt.sh --dry-run > /work/out/r2.json 2>/work/out/e2.txt
BK_STUB_NO_WAN=1 sh agent_openwrt.sh --dry-run > /work/out/r3.json 2>/work/out/e3.txt
if [ -d /tmp/status-agent-openwrt.lock ]; then echo "lock directory left behind" >&2; exit 1; fi
