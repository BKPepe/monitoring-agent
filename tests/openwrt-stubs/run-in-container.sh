#!/bin/sh
# Runs inside the busybox container (see ../run_openwrt_e2e.sh). The router
# tools the agent shells out to are replaced by the canned stubs in bin/, so
# every parser in agent_openwrt.sh sees realistic output and the payload can
# be asserted field by field. /sys and /proc are replaced too, where the agent
# reads them through its dry-run seam: mkroot.sh builds the owner's Turris
# Omnia plus one synthetic device per parser branch the Omnia cannot show.
#
# The payload runs (every run is a dry run, nothing is ever POSTed):
#   r1   first run: no deltas, no caches
#   r2   11 s later: the disks, /proc/stat, the conntrack counters, the uptime
#        and the WAN byte counters all moved, and the log is oversized
#   r2b  what the work started behind r2's payload has found, and a run in
#        which nothing at all moved since the one before it
#   r3   a bare access point: no netifd interface, no hostapd_cli, smartctl,
#        iw, and no conntrack file either
#   r4   the router with eMMC, and a smartctl that ignores TERM
#   r5   a SMART lock held by a live process
# Then, on a clean private directory, the scenario runs - wpppoe and wwalk1..5
# (one branch of the WAN walk each), wsmart, wlock, wspeed*/wack* (where the
# speedtest results come from and what a 200 really acknowledges), wpath1..8
# (the path the packets take), wfw1..3 (what "the firewall is up" is read
# from), wdns1/wdns3 (the DNS probe's exit status) and wrun1..7 (the run's own
# clock and the runs that produced no report) - and the hardening runs
# (runs-g28.sh).
set -e
mkdir -p /usr/share/libubox /etc/config /etc/init.d /root/agent /work/out

# The busybox in this image is a defconfig build and carries applets OpenWrt
# does not compile in. Removing them makes the harness answer the question it
# is actually asked: does this run on a ROUTER. `stat` is the one that bit us -
# the log trim silently never ran on any router while the test looked fine
# (OpenWrt: CONFIG_STAT is not set).
rm -f /bin/stat /usr/bin/stat
# Same story: no `timeout` on a router (CONFIG_TIMEOUT is not set), so a
# watchdog built on it would pass here and hang there.
rm -f /bin/timeout /usr/bin/timeout
# Neither is tc an applet of a router image: sqm-scripts brings it, and the
# owner's router does not have it (REAL_FACTS). Without removing busybox's own
# the "no tc, so the queue drops are unknown" case could not be built at all.
rm -f /bin/tc /usr/bin/tc
# OpenWrt has a root-only /var/run tmpfs; the agent keeps its lock and caches there.
mkdir -p /var/run
cp /work/stubs/jshn.sh /usr/share/libubox/jshn.sh
touch /etc/config/mwan3 /etc/config/sqm /etc/config/librespeed /etc/init.d/dnsmasq /etc/init.d/uhttpd
# G20: the weakest of the three signals 0.1.6 accepted, kept alive on purpose.
# It answers "enabled" in EVERY run below, including the ones where no
# firewall rule is in the kernel at all - so a fall-back to it is visible.
printf '#!/bin/sh\n[ "$1" = enabled ] && exit 0\nexit 1\n' > /etc/init.d/firewall
chmod +x /etc/init.d/firewall
cp /work/agent/agent_openwrt.sh /root/agent/agent_openwrt.sh
export PATH="/work/stubs/bin:$PATH"
OUT=/work/out
PRIV=/var/run/status-agent-openwrt
sh /work/stubs/mkroot.sh /tmp/fakeroot > /dev/null
sh /work/stubs/mkroot.sh /tmp/fakeroot-emmc emmc > /dev/null
export STATUS_TEST_ROOT=/tmp/fakeroot
# The stubs first: a wrong stub makes every parser check on it wrong too.
sh /work/stubs/selftest.sh
cd /root/agent
# run TAG: one dry run; afterwards the disk caches as that run left them.
run() {
    sh agent_openwrt.sh --dry-run > "$OUT/$1.json" 2> "$OUT/e${1#r}.txt"
    for _f in smart.cache disks.static; do
        cp "$PRIV/$_f" "$OUT/$1_$_f" 2>/dev/null || true
    done
}
stub_off() { for _s; do mv "/work/stubs/bin/$_s" "/work/stubs/$_s.off"; done; }
stub_on() { for _s; do mv "/work/stubs/$_s.off" "/work/stubs/bin/$_s"; done; }

# --- librespeed results ------------------------------------------------------
# Where they land is a uci option, not a constant: reForis and the cron
# wrapper both honour librespeed.client.data_dir. The stub answers /srv/speed,
# and /tmp/librespeed-data - the hard-coded default of 0.1.6 - holds a file
# that NO run reading uci may ever send.
#
# The addresses in these fixtures are from the documentation ranges of
# RFC 5737; nothing here belongs to the owner. They are in the files on
# purpose: "the client block never leaves the router" is only provable when
# there is something to leak.
speed_file() {
    mkdir -p "$1/2026-09"
    cat > "$1/2026-09/$2.json"
}
mkdir -p /srv/speed
# A run that failed: no speed anywhere, so it is not an item at all.
speed_file /srv/speed "2026-09-20T05:10:00+02:00" <<'M'
{"timestamp":"2026-09-20T05:10:00.000000000+02:00","error":"connection reset by peer"}
M
# The Go client, and the result that W01 destroyed: 1850.23 Mbit/s became
# 0.0148 because "more than 1000 must be bytes per second".
speed_file /srv/speed "2026-09-20T05:23:41+02:00" <<'M'
[{"timestamp":"2026-09-20T05:23:41.123456789+02:00","server":{"name":"Prague, Czech Republic (CESNET)","url":"https://speed.example/backend/empty.php?id=42"},"client":{"ip":"198.51.100.5","hostname":"host.example","region":"","country":"CZ","org":"AS64496 Example ISP"},"bytes_sent":1692000000,"bytes_received":2531000000,"ping":2.1,"jitter":0.3,"upload":902.4,"download":1850.23,"share":"https://speed.example/results/1234.png"}]
M
# The owner's own Rust port. Only it writes a "tls" block, which is the one
# piece of evidence in the file about which tool wrote it.
speed_file /srv/speed "2026-09-20T05:41:02+02:00" <<'M'
[{"timestamp":"2026-09-20T05:41:02.000000000+02:00","server":{"name":"Praha (CESNET)","url":"https://speed.example/backend/"},"client":{"ip":"198.51.100.5","org":"AS64496 Example ISP"},"bytes_sent":900000000,"bytes_received":1200000000,"ping":3.4,"jitter":0.6,"upload":410.5,"download":880.75,"share":"","tls":{"version":"TLS1.3","cipher":"TLS_AES_128_GCM_SHA256"}}]
M
# A half-finished measurement: the download is there, the upload is not.
speed_file /srv/speed "2026-09-20T06:02:00+02:00" <<'M'
[{"timestamp":"2026-09-20T06:02:00.000000000+02:00","server":{"name":"Brno"},"bytes_received":500000000,"ping":5.0,"jitter":1.2,"download":120.5}]
M
# The hard-coded default directory. Only a run whose uci cannot answer may
# ever send this one.
speed_file /tmp/librespeed-data "2019-01-01T00:00:00+01:00" <<'M'
[{"timestamp":"2019-01-01T00:00:00.000000000+01:00","server":{"name":"Fallback"},"bytes_sent":1,"bytes_received":2,"ping":9.9,"jitter":9.9,"upload":1.5,"download":2.5}]
M
# 60 results in one directory: at most 50 leave per report, and the OLDEST
# first - a router that was offline for a week catches up in order instead of
# sending a payload the ingest would shed.
mkdir -p /srv/speed60/2026-09
_i=1
while [ $_i -le 60 ]; do
    _h=$(( (_i - 1) / 60 + 1 ))
    _m=$(( (_i - 1) % 60 ))
    [ $_m -lt 10 ] && _m="0$_m"
    printf '[{"timestamp":"2026-09-19T0%s:%s:00.000000000+02:00","server":{"name":"S%s"},"bytes_sent":1000,"bytes_received":2000,"ping":1.0,"jitter":0.1,"upload":10.0,"download":%s.0}]\n' \
        "$_h" "$_m" "$_i" "$_i" > "/srv/speed60/2026-09/2026-09-19T0$_h:$_m:00+02:00.json"
    _i=$((_i + 1))
done
# ethtool is NOT in the owner's image (REAL_FACTS), so no payload run may see
# it. The wpath runs below put it back to prove the ring-drop parser.
stub_off ethtool

run r1
# 11 s, not 2: the second survey sample is +12,000 ms of channel time, and the
# agent believes a delta only if that much wall clock has really passed. The
# gate is never loosened for the test, and there is no fake clock.
sleep 11
cp /tmp/fakeroot/proc/diskstats.2 /tmp/fakeroot/proc/diskstats
# The same 11 s in the fake root: the second /proc/stat sample (core 0 drowning
# in softirq), the busy conntrack counters, an uptime 11.00 s later - the rate
# is measured against THAT, not against the clock - and 15.4 MB received plus
# 2.2 MB sent on the WAN device of the default stub answers.
cp /tmp/fakeroot/proc/stat.2 /tmp/fakeroot/proc/stat
cp /tmp/fakeroot/proc/net/stat/nf_conntrack.2 /tmp/fakeroot/proc/net/stat/nf_conntrack
echo "1011.00 1522.00" > /tmp/fakeroot/proc/uptime
echo 15400000 > /tmp/fakeroot/sys/class/net/eth0/statistics/rx_bytes
echo 2200000 > /tmp/fakeroot/sys/class/net/eth0/statistics/tx_bytes
# A log well over the 64 KB ceiling, so the next run has to trim it. Written
# before the second run because the trim happens on the first log line.
head -c 200000 /dev/zero | tr "\\0" "x" > /tmp/status-agent-openwrt.log
run r2
wc -c < /tmp/status-agent-openwrt.log | tr -cd "0-9" > $OUT/logsize.txt
run r2b
# hostapd-utils, smartmontools and iw are optional packages.
stub_off hostapd_cli smartctl iw
# (a subshell with export: an assignment in front of a FUNCTION call is not
# exported by every shell)
# A kernel without conntrack accounting: the three event counters must come
# back null, not as the zeros of a table nobody could read.
mv /tmp/fakeroot/proc/net/stat/nf_conntrack /tmp/fakeroot/proc/net/stat/nf_conntrack.off
( export BK_STUB_NO_WAN=1; run r3 )
mv /tmp/fakeroot/proc/net/stat/nf_conntrack.off /tmp/fakeroot/proc/net/stat/nf_conntrack
stub_on hostapd_cli smartctl iw
if [ -d /tmp/status-agent-openwrt.lock ]; then echo "lock directory left behind" >&2; exit 1; fi
# 10 s is the floor of the timeout's clamp: sde's smartctl sleeps through it.
echo "SMART_TIMEOUT_SEC=10" > /root/agent/agent_openwrt.cfg
( export STATUS_TEST_ROOT=/tmp/fakeroot-emmc; run r4 )
# sde's smartctl ignores TERM (the ignore survives its `exec`), so the watchdog
# has to reach for KILL. Both are recorded right here: after the KILL nothing
# of that probe may be left running, and the lock must be free again. The
# process check has to happen BEFORE the `sleep 300` below, whose name would
# match the same grep.
if [ -d "$PRIV/smart.lock" ]; then echo yes; else echo no; fi > $OUT/r4_lock.txt
ps 2>/dev/null | grep "[s]leep 30" | wc -l | tr -cd "0-9" > $OUT/r4_procs.txt
rm -f /root/agent/agent_openwrt.cfg
# What an unkillable smartctl leaves behind, which a container cannot produce
# for real: the lock, owned by a process that is still alive.
sleep 300 &
_held=$!
mkdir -p "$PRIV/smart.lock"
echo "$_held" > "$PRIV/smart.lock/pid"; echo sda > "$PRIV/smart.lock/dev"
echo $(( $(date +%s) - 1000 )) > "$PRIV/smart.lock/since"
run r5
if [ -d "$PRIV/smart.lock" ]; then echo yes; else echo no; fi > $OUT/r5_lock.txt

# --- from here on: scenario runs, each on a private directory of its own ---
# The payload runs' call logs are COUNTED ("asked once, then cached", "one
# smartctl call per disk"), and later runs would add to them: they are put
# aside in core/. A scenario run starts without caches and rightly asks again.
kill "$_held" 2>/dev/null || true
rm -rf "$PRIV" /tmp/status-agent-openwrt-private
mkdir -p $OUT/core
for _log in $OUT/*_calls.log $OUT/iwinfo_scan.log; do
    [ -f "$_log" ] && mv "$_log" $OUT/core/
done
# The owner's line: PPPoE over VLAN 848 over eth2. The rate state is planted
# with the counters of the PPP netdev 11.00 s of uptime ago, so this run has
# to answer 100.0 / 10.0 Mbit/s. The port eth2 below it carries 0.7 GB more,
# which is what a rate read off the port instead of the l3 device would show.
mkdir -p "$PRIV"
printf '100000|pppoe-wan|39669766851|2433851191\n' > "$PRIV/wan-rate.state"
BK_STUB_WAN=pppoe sh agent_openwrt.sh --dry-run > $OUT/wpppoe.json 2> $OUT/wpppoe.err
rm -rf "$PRIV" /tmp/status-agent-openwrt-private

# --- wwalk1..wwalk5: one branch of the WAN walk each (WAN 3.1.1) ------------
# The Omnia has one WAN line and can show one branch per run; mkroot.sh builds
# the netdev chain of each one and jshn.sh/bin/ubus answer the matching dump.
# wwalk1 additionally carries a COMPLETE rate state that names another device
# (eth9): 11 s passed and the counters are there, and the rate still has to be
# null - a delta between two different interfaces is a fabricated number.
mkdir -p "$PRIV"
printf '100000|eth9|40420604195|2752225303\n' > "$PRIV/wan-rate.state"
# These five runs also read a conntrack file from a kernel that prints its
# counters in another order (no insert_failed at all). It is full of hex
# numbers, and not one of them may be reported: the header has to be read,
# not skipped.
cp /tmp/fakeroot/proc/net/stat/nf_conntrack /tmp/fakeroot/proc/net/stat/nf_conntrack.keep
cp /tmp/fakeroot/proc/net/stat/nf_conntrack.other /tmp/fakeroot/proc/net/stat/nf_conntrack
for _w in "wwalk1 eth2" "wwalk2 brwan" "wwalk3 brwan2" "wwalk4 ppp0" "wwalk5 dsa"; do
    # shellcheck disable=SC2086
    set -- $_w
    BK_STUB_WAN="$2" sh agent_openwrt.sh --dry-run > "$OUT/$1.json" 2> "$OUT/$1.err"
    rm -rf "$PRIV" /tmp/status-agent-openwrt-private
    mkdir -p "$PRIV"
done
mv /tmp/fakeroot/proc/net/stat/nf_conntrack.keep /tmp/fakeroot/proc/net/stat/nf_conntrack
rm -rf "$PRIV" /tmp/status-agent-openwrt-private
# --- wsmart: a disk that falls asleep between two readings -------------------
# No r-run can show this: sdb is already asleep the first time anybody looks
# at it, so there is nothing to carry over. Here it HAS a reading (planted,
# two hours old, so it is due again) and the disk counters say it is awake, so
# it is really probed - and the probe answers "in standby, no data". The last
# real reading has to survive that, stamped with ITS own time, instead of
# turning into a row of nulls that reads as "this disk is now unknown".
rm -rf "$PRIV" /tmp/status-agent-openwrt-private
mkdir -p "$PRIV"
_old=$(( $(date +%s) - 7200 ))
echo "$_old" > $OUT/wsmart_ts.txt
printf 'S|sdb|1953525168|%s|%s|0|ok|5400|"exit_bits":0,"passed":true,"in_drivedb":true,"protocol":"ATA","model":"WD Elements 25A2","rotation_rpm":5400,"temperature_c":38,"power_on_hours":9000,"power_cycles":120,"unsafe_shutdowns":null,"reallocated_sectors":0,"pending_sectors":0,"offline_uncorrectable":null,"reported_uncorrect":0,"crc_errors":0,"runtime_bad_blocks":null,"media_errors":null,"critical_warning":null,"available_spare_pct":null,"wear_pct":null,"wear_source":null,"written_bytes":null,"written_source":null,"error_log_count":0,"selftest_count":0\n' "$_old" "$_old" > "$PRIV/smart.cache"
# The disk-rate state is planted too, with counters far below the current
# ones: that is what "this disk is working" looks like to the agent.
{ date +%s; echo "sdb|1|1"; } > /tmp/status-agent-openwrt-diskdev.state
sh agent_openwrt.sh --dry-run > $OUT/wsmart.json 2> $OUT/wsmart.err
cp "$PRIV/smart.cache" $OUT/wsmart_smart.cache
sh agent_openwrt.sh --dry-run > $OUT/wsmart2.json 2> $OUT/wsmart2.err
rm -rf "$PRIV" /tmp/status-agent-openwrt-private

# --- wlock: a probe is already running ---------------------------------------
# r5 shows the lock a HUNG smartctl leaves behind, where no disk is due anyway.
# This is the ordinary case: the cache is empty, so every disk is due, and a
# refresh from a minute ago is still working. Not one new smartctl may start -
# two of them on the same bus is how a marginal USB bridge is brought down.
mkdir -p "$PRIV"
sleep 300 &
_busy=$!
mkdir -p "$PRIV/smart.lock"
echo "$_busy" > "$PRIV/smart.lock/pid"; echo sda > "$PRIV/smart.lock/dev"; date +%s > "$PRIV/smart.lock/since"
wc -l < $OUT/smartctl_calls.log | tr -cd "0-9" > $OUT/wlock_before.txt
sh agent_openwrt.sh --dry-run > $OUT/wlock.json 2> $OUT/wlock.err
wc -l < $OUT/smartctl_calls.log | tr -cd "0-9" > $OUT/wlock_after.txt
if [ -d "$PRIV/smart.lock" ]; then echo yes; else echo no; fi > $OUT/wlock_lock.txt
kill "$_busy" 2>/dev/null || true
rm -rf "$PRIV" /tmp/status-agent-openwrt-private

# --- wspeed*: where the results come from and what is re-sent ----------------
fresh() { rm -rf "$PRIV" /tmp/status-agent-openwrt-private; mkdir -p "$PRIV"; }
fresh
# Without the uci option the agent has to look in the hard-coded default, and
# only there: the file waiting in /tmp/librespeed-data belongs to no other run.
BK_STUB_LIBRESPEED=off sh agent_openwrt.sh --dry-run > $OUT/wspeedfb.json 2> $OUT/wspeedfb.err
fresh
BK_STUB_SPEED_DIR=/srv/speed60 sh agent_openwrt.sh --dry-run > $OUT/wspeed60.json 2> $OUT/wspeed60.err
fresh
# W01 repair. 0.1.6 kept the newest sent name in /tmp and never offered the
# older results again, so the rows the server has to repair would never come
# back. The upgrade DELETES that file instead of migrating it - the natural
# thing to do would switch the repair off and no payload would look wrong.
echo "0.1.6" > /tmp/status-agent-openwrt-version.stamp
printf '2026-09-20T06:02:00+02:00\n' > /tmp/status-agent-librespeed.state
sh agent_openwrt.sh --dry-run > $OUT/wspeedold.json 2> $OUT/wspeedold.err
if [ -f /tmp/status-agent-librespeed.state ]; then echo yes; else echo no; fi > $OUT/wspeedold_state.txt

# --- wack1..wack5: a bare 200 is not a receipt (WAN 3.1.6) -------------------
# The server wraps its speedtest INSERT in a try/catch and answers 200 even
# when nothing was stored, so the answer has to NAME what it dealt with.
# Everything below goes through the response seam: line 1 is the HTTP code.
resp() { printf '%s\n%s\n' "$1" "$2" > /tmp/wack-resp.json; }
fresh
# The POST never arrives: the mark must stay where it is.
resp 000 ''
# The agent exits non-zero when the report did not arrive, which is the point
# of this run - `set -e` must not take it for a broken harness.
STATUS_TEST_RESPONSE=/tmp/wack-resp.json sh agent_openwrt.sh --dry-run > $OUT/wack1.json 2> $OUT/wack1.err || true
if [ -f "$PRIV/pending.state" ]; then echo yes; else echo no; fi > $OUT/wack1_pending.txt
# A bare 200 with no ack key at all: everything is offered again.
resp 200 '{"status":"ok"}'
STATUS_TEST_RESPONSE=/tmp/wack-resp.json sh agent_openwrt.sh --dry-run > $OUT/wack2.json 2> $OUT/wack2.err
# An ack naming the SECOND of the three items: only the third may be left.
resp 200 '{"status":"ok","speedtests_acked":"2026-09-20T05:41:02+02:00"}'
STATUS_TEST_RESPONSE=/tmp/wack-resp.json sh agent_openwrt.sh --dry-run > $OUT/wack3.json 2> $OUT/wack3.err
# ... and an ack for a timestamp this report never sent is no answer to it.
resp 200 '{"status":"ok","speedtests_acked":"2027-01-01T00:00:00+01:00"}'
STATUS_TEST_RESPONSE=/tmp/wack-resp.json sh agent_openwrt.sh --dry-run > $OUT/wack4.json 2> $OUT/wack4.err
resp 200 '{"status":"ok","speedtests_acked":"2026-09-20T06:02:00+02:00"}'
STATUS_TEST_RESPONSE=/tmp/wack-resp.json sh agent_openwrt.sh --dry-run > $OUT/wack5.json 2> $OUT/wack5.err
if [ -f "$PRIV/sent.state" ]; then echo yes; else echo no; fi > $OUT/wack5_sent.txt
STATUS_TEST_RESPONSE=/tmp/wack-resp.json sh agent_openwrt.sh --dry-run > $OUT/wack6.json 2> $OUT/wack6.err
# A test running right now writes no file yet: only pidof can see it.
BK_STUB_TEST_RUNNING=1 sh agent_openwrt.sh --dry-run > $OUT/wactive.json 2> $OUT/wactive.err

# --- wpath1..wpath8: the path the packets take (WAN 3.1.5) -------------------
# Every run starts on an empty private directory, because the answer is cached
# for an hour and a second run would only read the cache back.
stub_on ethtool
fresh
BK_STUB_WAN=eth2 sh agent_openwrt.sh --dry-run > $OUT/wpath1.json 2> $OUT/wpath1.err
fresh
# A driver whose MIB carries neither counter name: null, never 0.
BK_STUB_WAN=eth2 BK_STUB_ETHTOOL=other sh agent_openwrt.sh --dry-run > $OUT/wpath2.json 2> $OUT/wpath2.err
fresh
# Offloading configured off and really not in the kernel, and the uci label
# that says "0" instead of being absent.
BK_STUB_WAN=eth2 BK_STUB_UCI_FLOW=off BK_STUB_NFT=noflow BK_STUB_UCI_STEERING=0 \
    sh agent_openwrt.sh --dry-run > $OUT/wpath3.json 2> $OUT/wpath3.err
fresh
# Nothing installed: no nft, no tc, no ethtool. Every one of them is a null.
stub_off nft tc ethtool
BK_STUB_WAN=eth2 sh agent_openwrt.sh --dry-run > $OUT/wpath4.json 2> $OUT/wpath4.err
stub_on nft tc
fresh
# A router with no SQM configuration at all: "not installed" is not "off".
mv /etc/config/sqm /etc/config/sqm.off
BK_STUB_WAN=eth2 sh agent_openwrt.sh --dry-run > $OUT/wpath5.json 2> $OUT/wpath5.err
mv /etc/config/sqm.off /etc/config/sqm
fresh
# No ubus answer at all: the LAN side is unknown, not empty.
( export BK_STUB_NO_WAN=1; sh agent_openwrt.sh --dry-run > $OUT/wpath6.json 2> $OUT/wpath6.err )
fresh
# Both gigabit cables are out: the fastest port LINKED is lan1 at 100, and
# every port still supports 1000. A cap read off a negotiated rate cannot tell
# the two apart.
BK_STUB_WAN=eth2 BK_STUB_UBUS_DEV=lan1only sh agent_openwrt.sh --dry-run > $OUT/wpath7.json 2> $OUT/wpath7.err
fresh
# The owner's file with its WAN queue switched off as well: a section that
# names the very port the traffic takes, and is disabled. "Configured once"
# is not "shaping now", so nothing may be reported for it.
BK_STUB_WAN=eth2 BK_STUB_SQM=off sh agent_openwrt.sh --dry-run > $OUT/wpath8.json 2> $OUT/wpath8.err
fresh

# --- wfw1..wfw3: what "the firewall is up" is read from (G20) ---------------
# fw4 loads ONE table, `inet fw4`, and loads it whole. A kernel holding
# somebody else's table, a kernel holding nothing, and a router without nft
# are three different answers, and not one of them may come from
# /etc/init.d/firewall - which says the service MAY start and answers
# "enabled" in all three.
BK_STUB_NFT=foreign sh agent_openwrt.sh --dry-run > $OUT/wfw1.json 2> $OUT/wfw1.err
fresh
BK_STUB_NFT=empty sh agent_openwrt.sh --dry-run > $OUT/wfw2.json 2> $OUT/wfw2.err
fresh
# Neither nft nor iptables: unknown, not "off". The image has no iptables
# applet at all, which is what a router without the compat layer looks like.
stub_off nft
sh agent_openwrt.sh --dry-run > $OUT/wfw3.json 2> $OUT/wfw3.err
stub_on nft
fresh

# --- wdns1, wdns3: the DNS probe keeps its exit status (G41) ----------------
# The answering case is every payload run: the stub resolves. Here the
# resolver refuses - instantly, which is the point: three milliseconds are not
# a latency - and then there is no resolver client at all.
BK_STUB_DNS=fail sh agent_openwrt.sh --dry-run > $OUT/wdns1.json 2> $OUT/wdns1.err
fresh
stub_off nslookup
mv /bin/nslookup /bin/nslookup.off
sh agent_openwrt.sh --dry-run > $OUT/wdns3.json 2> $OUT/wdns3.err
mv /bin/nslookup.off /bin/nslookup
stub_on nslookup
fresh

# --- wrun1..wrun7: the run's own clock and the skipped runs (G42) -----------
# A second agent while the first still holds the lock: it writes no report at
# all, and the report after it is the only place that can say so.
sleep 300 &
_busy=$!
mkdir -p "$PRIV/run.lock"
echo "$_busy" > "$PRIV/run.lock/pid"
sh agent_openwrt.sh --dry-run > $OUT/wrun1.json 2> $OUT/wrun1.err
kill "$_busy" 2>/dev/null || true
rm -rf "$PRIV/run.lock"
# A POST that never arrives (line 1 of the canned answer is 000); the agent
# exits non-zero, which is correct here and must not stop the harness.
resp 000 ''
STATUS_TEST_RESPONSE=/tmp/wack-resp.json sh agent_openwrt.sh --dry-run > $OUT/wrun2.json 2> $OUT/wrun2.err || true
# The report the server takes carries both counters - and afterwards they are
# dealt with, so the next one is back to a measured zero.
resp 200 '{"status":"ok"}'
STATUS_TEST_RESPONSE=/tmp/wack-resp.json sh agent_openwrt.sh --dry-run > $OUT/wrun3.json 2> $OUT/wrun3.err
STATUS_TEST_RESPONSE=/tmp/wack-resp.json sh agent_openwrt.sh --dry-run > $OUT/wrun4.json 2> $OUT/wrun4.err
fresh
# The run's own length. logread (one call per run, between the two uptime
# reads) moves the fake router's uptime 4.20 s forward, so the answer is
# exactly 4200 ms; the run after it reports the same number as the PREVIOUS
# run's total, which the EXIT trap wrote after the POST.
BK_STUB_UPTIME_BUMP=1 sh agent_openwrt.sh --dry-run > $OUT/wrun5.json 2> $OUT/wrun5.err
sh agent_openwrt.sh --dry-run > $OUT/wrun6.json 2> $OUT/wrun6.err
fresh
# No uptime to read: the run cannot time itself and says so.
mv /tmp/fakeroot/proc/uptime /tmp/fakeroot/proc/uptime.off
sh agent_openwrt.sh --dry-run > $OUT/wrun7.json 2> $OUT/wrun7.err
mv /tmp/fakeroot/proc/uptime.off /tmp/fakeroot/proc/uptime
fresh

# Agent hardening (identity cache, last payload, remote actions); the version
# stamp it needs was written by the runs above and lives outside $PRIV.
sh /work/stubs/runs-g28.sh
