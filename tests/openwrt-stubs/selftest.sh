#!/bin/sh
# The stubs are the test's idea of a router; when one of them is wrong, every
# parser check built on it is wrong with it. So the refusals and edge cases
# the real tools have are pinned here, before the first agent run. One line
# per check in /work/out/stub_selftest.txt; the call logs this leaves behind
# are removed again so the counting checks start from zero.
OUT=/work/out
R=$OUT/stub_selftest.txt
: > "$R"
t() { # NAME CONDITION...
    _name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "ok   $_name" >> "$R"; else echo "FAIL $_name" >> "$R"; fi
}
eq() { [ "$1" = "$2" ]; }
T=/tmp/bk-selftest; rm -rf $T; mkdir -p $T

# iwinfo: one command per call, like iwinfo_cli.c
iwinfo phy0-ap0 info assoclist > $T/o 2> $T/e; _rc=$?
t "iwinfo: two commands in one call - exit 1" eq "$_rc" 1
t "iwinfo: two commands in one call - nothing on stdout" eq "$(wc -c < $T/o | tr -cd 0-9)" 0
t "iwinfo: two commands in one call - 'No such wireless backend' on stderr" grep -q "No such wireless backend: phy0-ap0" $T/e
t "iwinfo: bare call lists six radios" eq "$(iwinfo | grep -c '^[a-z0-9]')" 6
t "iwinfo: phy0-ap0 is the Omnia capture" eq "$(iwinfo phy0-ap0 info | grep -c 'Channel: 36 (5.180 GHz)  HT Mode: HE80')" 1
t "iwinfo: phy0-ap0 has four stations, phy3-ap0 six" eq "$(iwinfo phy0-ap0 assoclist | grep -c ' ms ago'),$(iwinfo phy3-ap0 assoclist | grep -c ' ms ago')" "4,6"
iwinfo wlan0 scan > /dev/null 2>&1
t "iwinfo: a scan leaves its marker" grep -q SCAN $OUT/iwinfo_scan.log
t "iwinfo: every call is logged with its arguments" grep -qx "phy0-ap0 info assoclist" $OUT/iwinfo_calls.log

# hostapd_cli: empty AP = nothing + exit 0; no socket = 255
hostapd_cli -i wlan7 all_sta > $T/o 2>/dev/null; _rc=$?
t "hostapd_cli: an AP with nobody on it prints nothing and exits 0" eq "$_rc,$(wc -c < $T/o | tr -cd 0-9)" "0,0"
hostapd_cli -i wlan1 all_sta > /dev/null 2>&1; _rc=$?
t "hostapd_cli: no socket exits 255" eq "$_rc" 255
t "hostapd_cli: phy0-ap0 has four stations, two with an operating-class list" eq "$(hostapd_cli -i phy0-ap0 all_sta | grep -c '^flags='),$(hostapd_cli -i phy0-ap0 all_sta | grep -c '^supp_op_classes=')" "4,2"

# iw: sample 1, then sample 2; the USB adapter has no survey at all
t "iw: first survey call serves sample 1" eq "$(iw dev phy0-ap0 survey dump | grep -c '35029953 ms')" 1
t "iw: later calls serve sample 2 (+12,000 ms)" eq "$(iw dev phy0-ap0 survey dump | grep -c '35041953 ms')" 1
iw dev phy3-ap0 survey dump > $T/o 2>/dev/null; _rc=$?
t "iw: phy3-ap0 answers nothing, exit 0" eq "$_rc,$(wc -c < $T/o | tr -cd 0-9)" "0,0"

# smartctl
A="--json=g -q noserial -n standby,3 -i -H -A"
# shellcheck disable=SC2086
t "smartctl: no identifiers with -q noserial" eq "$(smartctl $A /dev/sda | grep -c 'DECOYSERIAL\|4276994270\|serial_number\|wwn')" 0
t "smartctl: decoy serial and WWN without -q noserial" eq "$(smartctl --json=g -i /dev/sda | grep -c 'DECOYSERIAL-0042\|json.wwn.id = 4276994270')" 2
# shellcheck disable=SC2086
smartctl $A /dev/sdb > /dev/null; _rc=$?
t "smartctl: a sleeping disk asked with -n standby,3 exits 3" eq "$_rc" 3
smartctl --json=g -q noserial -i /dev/sdb > /dev/null; _rc=$?
t "smartctl: the same disk asked without the flag answers (exit 0)" eq "$_rc" 0
# shellcheck disable=SC2086
smartctl $A /dev/sdc > $T/o; _rc=$?
t "smartctl: unknown USB bridge - message and exit 1" eq "$_rc,$(grep -c 'Unknown USB bridge' $T/o)" "1,1"
# shellcheck disable=SC2086
smartctl $A /dev/nvme0n1 > $T/o; _rc=$?
t "smartctl: NVMe critical warning 4, 2 media errors, exit 8" eq "$_rc,$(grep -c 'critical_warning = 4;\|media_errors = 2;' $T/o)" "8,2"
# shellcheck disable=SC2086
smartctl $A /dev/sdd > $T/o
# 231 and 194 BOTH come out as Temperature_Celsius without the database: a
# parser that keys attributes by name has to survive the collision.
t "smartctl: sdd is outside the drive database - 241/231 get generic names, 194 and 231 collide on Temperature_Celsius, written bytes only from devstat" eq "$(grep -c 'in_smartctl_database = false;' $T/o),$(grep -c 'name = "Total_LBAs_Written";' $T/o),$(grep -c 'name = "Temperature_Celsius";' $T/o),$(grep -c 'name = "Logical Sectors Written";' $T/o)" "1,1,2,1"
# shellcheck disable=SC2086
smartctl $A /dev/sde > /dev/null 2>&1 &
_p=$!; sleep 1; kill "$_p" 2>/dev/null; sleep 1
if [ -d "/proc/$_p" ]; then _term=ignored; else _term=died; fi
kill -9 "$_p" 2>/dev/null; sleep 1
if [ -d "/proc/$_p" ]; then _kill=alive; else _kill=gone; fi
t "smartctl: sde ignores TERM and dies of KILL" eq "$_term,$_kill" "ignored,gone"

# ubus: hostapd answers without netifd; the device status is the capture itself
t "ubus: hostapd objects answer on a box without netifd interfaces" eq "$(BK_STUB_NO_WAN=1 ubus call hostapd.phy0-ap0 get_clients | grep -c '"he": true')" 2
BK_STUB_NO_WAN=1 ubus call network.interface dump > /dev/null 2>&1; _rc=$?
t "ubus: network.interface fails on such a box" eq "$_rc" 1
t "ubus: nested capabilities.vht is there to trip a loose parser" eq "$(ubus call hostapd.wlan6 get_clients | grep -c '"vht"')" 2
ubus call network.device status > $T/o
t "ubus: network.device status is the real capture, byte for byte" cmp -s $T/o /work/stubs/omnia/ubus_network_device_status.json
t "ubus: BK_STUB_WAN=pppoe is PPPoE over eth2.848" eq "$(BK_STUB_WAN=pppoe ubus call network.interface.wan status)" '{"up":true,"proto":"pppoe","device":"eth2.848","l3_device":"pppoe-wan"}'

# df
t "df -PT: the mount point with a space, a # and quotes" eq "$(df -PT | grep -c '/mnt/usb #1 "disk"$')" 1
t "df: any other call is the real df" df -P /

# fake roots
F=/tmp/fakeroot; E=/tmp/fakeroot-emmc
t "root: the Omnia has no mmcblk0, the eMMC variant has" eq "$(ls $F/sys/block | grep -c mmcblk),$(ls $E/sys/block | grep -c '^mmcblk0$')" "0,1"
t "root: the real block list is there (8 loop, 3 mtdblock, sda)" eq "$(ls $F/sys/block | grep -c '^loop[0-7]$\|^mtdblock[0-2]$\|^sda$')" 12
t "root: decoy identifier files exist to be never read" eq "$(grep -rl SERIALLEAK $F/sys | wc -l | tr -cd 0-9),$(grep -rl SERIALLEAK $E/sys | wc -l | tr -cd 0-9)" "9,13"
_x=unset; if read -r _x < $F/sys/class/net/pppoe-wan/speed; then _rd=ok; else _rd=failed; fi 2>/dev/null
t "root: reading the speed of a ppp netdev fails, as on a router" eq "$_rd" failed
t "root: only the physical port has a device link" eq "$([ -e $F/sys/class/net/eth2/device ] && echo y)$([ -e $F/sys/class/net/eth2.848/device ] || echo n)$([ -e $F/sys/class/net/pppoe-wan/device ] || echo n)" ynn
t "root: the WAN chain is pppoe-wan -> eth2.848 -> eth2" eq "$(ls $F/sys/class/net/pppoe-wan | grep lower_),$(ls $F/sys/class/net/eth2.848 | grep lower_)" "lower_eth2.848,lower_eth2"
t "root: softnet_stat is the real capture (2 CPUs, 15 columns)" eq "$(awk 'NF == 15' $F/proc/net/softnet_stat | wc -l | tr -cd 0-9)" 2
t "root: the branches of the WAN walk - a bridge over one port, one over two, a lone ppp" eq "$(ls $F/sys/class/net/br-wan | grep -c lower_),$(ls $F/sys/class/net/br-wan2 | grep -c lower_),$(ls $F/sys/class/net/ppp0 | grep -c lower_)" "1,2,0"
t "root: the DSA port has a device link, answers -1 and sits above a conduit at 1000" eq "$([ -e $F/sys/class/net/wan/device ] && echo y),$(cat $F/sys/class/net/wan/speed),$(cat $F/sys/class/net/eth1/speed)" "y,-1,1000"
t "root: the real conntrack capture has no drops at all" eq "$(awk 'NR > 1 { print $10 $11 $12 }' $F/proc/net/stat/nf_conntrack | tr -d '0\n')" ""
t "root: a conntrack file of a kernel that has no insert_failed column at all" eq "$(awk 'NR == 1 { print $10 "/" $11 "/" $12 }' $F/proc/net/stat/nf_conntrack.other)" "drop/early_drop/icmp_error"
t "root: its busy copy carries 3 / 1 / 0x12 over two CPUs, in hex" eq "$(awk 'NR > 1 { print $10 "/" $11 "/" $12 }' $F/proc/net/stat/nf_conntrack.2 | tr '\n' ' ')" "00000002/00000001/00000012 00000001/00000000/00000000 "
t "root: the second /proc/stat sample moves core 0 by 5,240 softirq ticks" eq "$(awk '/^cpu0 / { print $8 }' $F/proc/stat.2) $(awk '/^cpu0 / { print $8 }' $F/proc/stat)" "5550 310"

# applets a router does not have
if command -v timeout > /dev/null 2>&1; then _a=present; else _a=absent; fi
t "image: no timeout applet" eq "$_a" absent
if command -v stat > /dev/null 2>&1; then _a=present; else _a=absent; fi
t "image: no stat applet" eq "$_a" absent
if command -v jsonfilter > /dev/null 2>&1; then _a=present; else _a=absent; fi
t "image: no jsonfilter - JSON is read with awk and read" eq "$_a" absent
if [ -x /bin/tc ] || [ -x /usr/bin/tc ]; then _a=present; else _a=absent; fi
t "image: no tc of its own - only the stub, so removing it really removes it" eq "$_a" absent
if [ -x /bin/ethtool ] || [ -x /usr/bin/ethtool ]; then _a=present; else _a=absent; fi
t "image: no ethtool of its own - the owner's router has none either" eq "$_a" absent

# tc: egress and ingress are two qdiscs on two devices, and they must not
# answer with the same number.
t "tc: the egress qdisc of a device reports its own drops" eq "$(tc -s qdisc show dev eth2 | sed -n 's/.*dropped \([0-9]*\),.*/\1/p' | head -1)" 12
t "tc: SQM's ingress device is another qdisc with another number" eq "$(tc -s qdisc show dev ifb4eth2 | sed -n 's/.*dropped \([0-9]*\),.*/\1/p' | head -1)" 34
# ethtool: the two names the mvneta driver accumulates ring drops into sit
# among two dozen others; another driver has neither.
t "ethtool: rx_discard and rx_overrun are in the MIB (5 and 2)" eq "$(ethtool -S eth2 | awk '/rx_discard:|rx_overrun:/ { s += $2 } END { print s }')" 7
t "ethtool: another driver names neither counter" eq "$(BK_STUB_ETHTOOL=other ethtool -S eth2 | grep -c 'rx_discard:\|rx_overrun:')" 0
# uci: an option that is not set exits 1 with no output, which is a different
# answer from "no uci at all".
uci -q get network.@globals[0].packet_steering > $T/o 2>&1; _rc=$?
t "uci: an unset option exits 1 and prints nothing" eq "$_rc,$(wc -c < $T/o | tr -cd 0-9)" "1,0"
t "uci: the stale sqm section on the LAN conduit is disabled, the WAN one is not" eq "$(uci -q show sqm | grep -c \'1\')" 1
# The ubus device dump is the real capture: an empty array over three lines
# and a speed that is a string with the duplex letter on it.
t "ubus: the device dump prints an empty array over three lines (12 of them)" eq "$(ubus call network.device status | grep -c '^			$')" 12
t "ubus: lan0 is a dsa port behind the conduit eth1, linked at 1000F" eq "$(ubus call network.device status | grep -c '"conduit": "eth1"')" 5

# nft: three rulesets, and the difference between them is the whole of G20.
t "nft: the default ruleset holds the fw4 table" eq "$(nft list ruleset | grep -c 'table inet fw4')" 1
t "nft: the foreign ruleset holds mwan3 and no fw4 at all" eq "$(BK_STUB_NFT=foreign nft list ruleset | grep -c 'inet fw4')" 0
BK_STUB_NFT=empty nft list ruleset > $T/o 2>&1; _rc=$?
t "nft: an empty kernel answers 0 and prints nothing" eq "$_rc,$(wc -c < $T/o | tr -cd 0-9)" "0,0"
# nslookup: the two answers G41 needs, and the refusal really is instant.
nslookup example.com 127.0.0.1 > $T/o 2> $T/e; _rc=$?
t "nslookup: the resolver answers - exit 0" eq "$_rc" 0
BK_STUB_DNS=fail nslookup example.com 127.0.0.1 > $T/o 2> $T/e; _rc=$?
t "nslookup: a refusal exits 1 and says so on stderr, with nothing on stdout" eq "$_rc,$(wc -c < $T/o | tr -cd 0-9),$(grep -c refused $T/e)" "1,0,1"
# logread: the one call every full run makes is where the fake router's clock
# moves; without the variable it may not move at all.
cp $F/proc/uptime $T/uptime.keep
logread > /dev/null 2>&1
t "logread: without the variable the uptime stays where it was" eq "$(cat $F/proc/uptime)" "$(cat $T/uptime.keep)"
BK_STUB_UPTIME_BUMP=1 logread > /dev/null 2>&1
t "logread: with BK_STUB_UPTIME_BUMP=1 the uptime moves 4.20 s forward" eq "$(awk -v a="$(awk '{print $1}' $T/uptime.keep)" -v b="$(awk '{print $1}' $F/proc/uptime)" 'BEGIN { printf "%.2f", b - a }')" "4.20"
cp $T/uptime.keep $F/proc/uptime

rm -rf $T
rm -f $OUT/*_calls.log $OUT/iwinfo_scan.log /tmp/bk-stub-iw.*.count
