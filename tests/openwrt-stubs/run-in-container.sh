#!/bin/sh
# Runs inside the busybox container (see ../run_openwrt_e2e.sh). The router
# tools the agent shells out to are replaced by the canned stubs in bin/, so
# every parser in agent_openwrt.sh sees realistic output and the payload can
# be asserted field by field. Two runs, so the second one has deltas.
set -e
mkdir -p /usr/share/libubox /etc/config /etc/init.d /root/agent /work/out

# The busybox in this image is a defconfig build and carries applets OpenWrt
# does not compile in. Removing them makes the harness answer the question it
# is actually asked: does this run on a ROUTER. `stat` is the one that bit us -
# the log trim silently never ran on any router while the test looked fine
# (OpenWrt: CONFIG_STAT is not set).
rm -f /bin/stat /usr/bin/stat
cp /work/stubs/jshn.sh /usr/share/libubox/jshn.sh
touch /etc/config/mwan3 /etc/config/sqm /etc/init.d/dnsmasq /etc/init.d/uhttpd
cp /work/agent/agent_openwrt.sh /root/agent/agent_openwrt.sh
export PATH="/work/stubs/bin:$PATH"
cd /root/agent
sh agent_openwrt.sh --dry-run > /work/out/r1.json 2>/work/out/e1.txt
sleep 2
# A log well over the 64 KB ceiling, so the next run has to trim it. Written
# before the second run because the trim happens on the first log line.
head -c 200000 /dev/zero | tr "\\0" "x" > /tmp/status-agent-openwrt.log
sh agent_openwrt.sh --dry-run > /work/out/r2.json 2>/work/out/e2.txt
wc -c < /tmp/status-agent-openwrt.log | tr -cd "0-9" > /work/out/logsize.txt
BK_STUB_NO_WAN=1 sh agent_openwrt.sh --dry-run > /work/out/r3.json 2>/work/out/e3.txt
if [ -d /tmp/status-agent-openwrt.lock ]; then echo "lock directory left behind" >&2; exit 1; fi
