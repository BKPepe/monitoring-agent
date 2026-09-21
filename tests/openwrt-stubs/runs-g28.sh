#!/bin/sh
# Agent hardening runs (G28; WAN e2e #17-#19), started by run-in-container.sh
# after the payload runs. Every run is a dry run; #19 feeds the agent a canned
# server answer through STATUS_TEST_RESPONSE, nothing is ever POSTed.
set -e
cd /root/agent
OUT=/work/out
PRIV=/var/run/status-agent-openwrt
OLD_ID=/tmp/status-agent-openwrt-identity.cache
OLD_PAYLOAD=/tmp/status-agent-openwrt-last-payload.json

# run-in-container.sh has put the payload runs' call logs aside and removed
# the private directory; the first seed below needs it back.
mkdir -p "$PRIV"

# --- #17 the identity cache is data, not code ---------------------------
# Seeded AFTER the earlier runs wrote the version stamp: on a version change
# the agent deletes both files before reading them, and a surviving `eval`
# would go unnoticed.
[ -s /tmp/status-agent-openwrt-version.stamp ] || { echo "no version stamp before the G28 runs" >&2; exit 1; }
printf "ow_hostname=\$(touch $OUT/PWNED)\now_model=\`touch $OUT/PWNED\`\n" > "$OLD_ID"
cp "$OLD_ID" "$PRIV/identity.cache"
sh agent_openwrt.sh --dry-run > $OUT/w17a.json 2>$OUT/w17a.err
# A file in the agent's own format whose VALUES are shell code: they must
# arrive as text.
{ date +%s; echo "\$(touch $OUT/PWNED)"; echo k; echo "\`touch $OUT/PWNED\`"; echo b; echo d; echo v; echo end; } > "$PRIV/identity.cache"
sh agent_openwrt.sh --dry-run > $OUT/w17b.json 2>$OUT/w17b.err
# 25 hours old: read again from ubus.
{ echo $(( $(date +%s) - 90000 )); echo stale; echo k; echo stale; echo b; echo d; echo v; echo end; } > "$PRIV/identity.cache"
sh agent_openwrt.sh --dry-run > $OUT/w17c.json 2>$OUT/w17c.err
rm -f "$OLD_ID"

# --- #18 the last payload is private and carries no key -----------------
# The state of a router coming from 0.1.6: the old world-readable copy with
# the key inside, and another version's stamp, so this run is "the first run
# after the update".
write_cfg() { # KEY [more cfg lines...]
    _key="$1"; shift
    { echo "AGENT_KEY=$_key"; for _l in "$@"; do echo "$_l"; done; } > /root/agent/agent_openwrt.cfg
}
last_payload_facts() { # TAG
    ls -l "$PRIV/last-payload.json" 2>/dev/null | cut -c1-10 > "$OUT/$1_mode.txt"
    ls -ld "$PRIV" | cut -c1-10 > "$OUT/$1_dirmode.txt"
    cp "$PRIV/last-payload.json" "$OUT/$1_last_payload.json" 2>/dev/null || true
    # Every file the agent left in /tmp or the private directory that holds the key.
    grep -rl SECRETKEY123 /tmp "$PRIV" > "$OUT/$1_keyfiles.txt" 2>/dev/null || true
    if [ -e "$OLD_PAYLOAD" ]; then echo yes > "$OUT/$1_oldfile.txt"; else echo no > "$OUT/$1_oldfile.txt"; fi
}
echo '{"agent_key": "SECRETKEY123"}' > "$OLD_PAYLOAD"
# #23 rides on the same run: a fresh, well-formed identity cache "of the old
# version", in both places the private directory can be. After an update it
# must be gone, or a parser fix takes a day to show.
mkdir -p /tmp/status-agent-openwrt-private
for _f in "$PRIV/identity.cache" /tmp/status-agent-openwrt-private/identity.cache; do
    { date +%s; echo STALE; echo k; echo STALE; echo b; echo d; echo v; echo end; } > "$_f"
done
# So must every cache a parser of the new version would read back (CORE 2.9,
# X18) - and nothing else: probe counters and results not sent yet are no
# cache. Each file carries a marker, because the run may write a fresh file
# of the same name. The keep-files sit in the fallback place only: the
# cleanup treats both places alike, and the agent never reads that one here.
for _d in "$PRIV" /tmp/status-agent-openwrt-private; do
    for _f in wifi-survey.state wifi-caps.phy0-ap0 disks.static smart.cache smart.spawn wan-path.cache cores.prev wan-rate.state; do
        echo "STALE-0.0.0" > "$_d/$_f"
    done
done
mkdir -p /tmp/status-agent-openwrt-private/probe-out
for _f in probe.count probe.attempts pending.state skipped probe-out/1.json; do
    echo "STALE-0.0.0" > "/tmp/status-agent-openwrt-private/$_f"
done
echo "STALE-0.0.0" > /tmp/status-agent-librespeed.state
echo "0.0.0" > /tmp/status-agent-openwrt-version.stamp
write_cfg SECRETKEY123
sh agent_openwrt.sh --dry-run > $OUT/w18.json 2>$OUT/w18.err
last_payload_facts w18
if [ -e /tmp/status-agent-openwrt-private/identity.cache ]; then echo yes; else echo no; fi > $OUT/w23_fallback.txt
cat /tmp/status-agent-openwrt-version.stamp > $OUT/w23_stamp.txt 2>/dev/null || true
{ grep -rl "STALE-0.0.0" "$PRIV" /tmp/status-agent-openwrt-private /tmp/status-agent-librespeed.state 2>/dev/null || true; } | sort > $OUT/w23_stale.txt
# A key with a quote in it: cutting the key out by pattern would stop at the
# escaped quote and leave the rest of the key in the file.
write_cfg 'abc"SECRETKEY123'
sh agent_openwrt.sh --dry-run > $OUT/w18b.json 2>$OUT/w18b.err
last_payload_facts w18b

# --- #19 remote actions: allow-listed, single-use, path-safe ------------
# The agent calls its targets by absolute path, so the stubs go there.
# /etc/x is where "../x" would land if the service name reached the path.
mkdir -p /sbin /etc/init.d
for _t in /sbin/ifdown /sbin/ifup /sbin/reboot /etc/init.d/dnsmasq /etc/x; do
    cp /work/stubs/action-target.sh "$_t"; chmod +x "$_t"
done
SIG=5f1d0c2e9a7b4d3c8e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d
# action_run TAG ACTION NONCE TS_OFFSET EXTRA_JSON: writes the answer at run
# time (the agent's 30 s window is real), runs the agent on it and files the
# calls and results under TAG. BK_STUB_HMAC is what the openssl stub "computes".
action_run() {
    _tag="$1"; _resp="$OUT/$1.resp"
    _ts=$(( $(date +%s) + $4 ))
    printf '200\n{"success":true,"pending_action":{"action_id":%s,"action":"%s","timestamp":%s,"nonce":"%s","signature":"%s"%s}}\n' \
        "${_tag#w19_}" "$2" "$_ts" "$3" "$SIG" "$5" > "$_resp"
    echo "# $_tag" >> $OUT/action_calls.log
    echo "# $_tag" >> $OUT/action_results.log
    echo "# $_tag ts=$_ts" >> $OUT/openssl_calls.log
    STATUS_TEST_RESPONSE="$_resp" sh agent_openwrt.sh --dry-run > "$OUT/$_tag.json" 2>"$OUT/$_tag.err"
    cat "$_resp.results" >> $OUT/action_results.log 2>/dev/null || true
}
export BK_STUB_HMAC="$SIG"
write_cfg SECRETKEY123 REMOTE_ACTIONS_ENABLED=1 ALLOWED_ACTIONS=restart_wan
action_run w19_1 restart_wan a1b2c3d4e5f60001 0 ""            # positive control
action_run w19_2 restart_wan a1b2c3d4e5f60001 0 ""            # the same nonce again
action_run w19_3 reboot_router a1b2c3d4e5f60003 0 ""          # signed, not on the list
export BK_STUB_HMAC=0000
action_run w19_4 restart_wan a1b2c3d4e5f60004 0 ""            # wrong signature
export BK_STUB_HMAC="$SIG"
action_run w19_5 restart_wan a1b2c3d4e5f60005 -100 ""         # signed, 100 s old
write_cfg SECRETKEY123 REMOTE_ACTIONS_ENABLED=1 'ALLOWED_ACTIONS="restart_wan, restart_service"'
action_run w19_6 restart_service a1b2c3d4e5f60006 0 ',"service_name":"dnsmasq"'   # positive control
action_run w19_7 restart_service a1b2c3d4e5f60007 0 ',"service_name":"../x"'
write_cfg SECRETKEY123 REMOTE_ACTIONS_ENABLED=1 ALLOWED_ACTIONS=
action_run w19_8 restart_wan a1b2c3d4e5f60008 0 ""            # an empty list allows nothing
# Remembered for 60 s, not for ever: a nonce used 100 s ago is free again
# (renew_dhcp, because it does not sleep).
write_cfg SECRETKEY123 REMOTE_ACTIONS_ENABLED=1 ALLOWED_ACTIONS=renew_dhcp
echo "$(( $(date +%s) - 100 )) a1b2c3d4e5f60009" > "$PRIV/action-nonces"
action_run w19_9 renew_dhcp a1b2c3d4e5f60009 0 ""
# A cfg WITHOUT the line keeps the full default list (routers set up before
# 0.1.7 have no such line and must not lose their actions by updating).
write_cfg SECRETKEY123 REMOTE_ACTIONS_ENABLED=1
action_run w19_11 renew_dhcp a1b2c3d4e5f60011 0 ""
# A timestamp that is not a number, by hand (action_run only writes numbers).
# It reaches shell arithmetic before any signature is checked; the run must
# neither act on it nor die of it - the exit code is kept for the assertion.
write_cfg SECRETKEY123 REMOTE_ACTIONS_ENABLED=1 ALLOWED_ACTIONS=restart_wan
printf '200\n{"success":true,"pending_action":{"action_id":10,"action":"restart_wan","timestamp":12abc,"nonce":"a1b2c3d4e5f60010","signature":"%s"}}\n' "$SIG" > $OUT/w19_10.resp
for _log in action_calls action_results openssl_calls; do echo "# w19_10" >> $OUT/$_log.log; done
_rc=0
STATUS_TEST_RESPONSE="$OUT/w19_10.resp" sh agent_openwrt.sh --dry-run > $OUT/w19_10.json 2>$OUT/w19_10.err || _rc=$?
echo "$_rc" > $OUT/w19_10_exit.txt
cat $OUT/w19_10.resp.results >> $OUT/action_results.log 2>/dev/null || true
# --- the private directory is checked, not assumed ----------------------
# Both of its places planted as symlinks into a directory somebody else can
# read: /var/run is refused, the /tmp fallback is replaced by a real 0700
# directory, and nothing lands behind the symlink. Last of the state runs,
# and cleaned up, so later runs start from the usual place.
rm -rf "$PRIV" /tmp/status-agent-openwrt-private
mkdir -p $OUT/planted
ln -s $OUT/planted "$PRIV"
ln -s $OUT/planted /tmp/status-agent-openwrt-private
sh agent_openwrt.sh --dry-run > $OUT/wpriv.json 2>$OUT/wpriv.err
ls -ld /tmp/status-agent-openwrt-private | cut -c1-10 > $OUT/wpriv_dirmode.txt
ls -l /tmp/status-agent-openwrt-private/last-payload.json 2>/dev/null | cut -c1-10 > $OUT/wpriv_mode.txt
ls -A $OUT/planted > $OUT/wpriv_planted.txt
rm -rf "$PRIV" /tmp/status-agent-openwrt-private $OUT/planted

# The seam must be out of reach of a cron run: the variable is read on one
# line only, and that line asks for --dry-run first.
grep -v '^[[:space:]]*#' agent_openwrt.sh | grep 'STATUS_TEST_RESPONSE' > $OUT/seam_guard.txt || true
# The same for every test variable, the fake root first of all: a cron run
# pointed at a fake /sys would report somebody else's disks as the router's.
grep -v '^[[:space:]]*#' agent_openwrt.sh | grep -E 'STATUS_TEST_|BK_ROOT=' > $OUT/seam_guard_all.txt || true
rm -f /root/agent/agent_openwrt.cfg
