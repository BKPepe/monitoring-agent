# shellcheck shell=sh
# Sourced inside an official openwrt/rootfs container (run-in-container.sh,
# ../hw_smoke_selftest.sh). The image is a router's root file system without
# the boot: this brings up what a booted router has and the agent reads -
# ubusd, procd, logd, netifd (a static WAN on the container's own eth0 and an
# empty br-lan), fw4 and dnsmasq. Nothing is installed: the stock userland is
# the point. Every step it could not bring up is named in $bk_boot_fail; the
# caller runs the agent anyway, so the assertions show what it cost, and a
# service that did not come up fails the run.
#
#   bk_boot LOG ENV - daemon output goes to LOG, the facts of the image to ENV

bk_boot_fail=""

# bk_wait SECONDS CMD... - CMD every second until it succeeds (busybox has no
# `timeout` on 24.10, and sleep may not take fractions).
bk_wait() {
    _bw_n=$1
    shift
    while ! "$@" >/dev/null 2>&1; do
        [ "$_bw_n" -gt 0 ] || return 1
        sleep 1
        _bw_n=$((_bw_n - 1))
    done
}

bk_wan_up() {
    ubus call network.interface.wan status 2>/dev/null | grep -q '"up": true'
}

bk_boot() {
    _bb_log=$1
    _bb_env=$2
    # What /etc/init.d/boot creates on a router. /var is a link to /tmp in
    # the image and none of it exists; without the resolv directory dnsmasq
    # does not start.
    mkdir -p /var/run /var/lock /var/log /var/state /tmp/sysinfo /tmp/resolv.conf.d
    touch /tmp/resolv.conf.d/resolv.conf.auto

    # dnsmasq's init script asks procd for a jail, and an unprivileged
    # container cannot clone the namespaces ("jail: failed to clone/fork:
    # Operation not permitted"). Without ujail procd starts it directly. The
    # container is thrown away afterwards, and the agent never uses ujail.
    [ -x /sbin/ujail ] && mv /sbin/ujail /sbin/ujail.off

    /sbin/ubusd >> "$_bb_log" 2>&1 &
    bk_wait 10 ubus list || bk_boot_fail="$bk_boot_fail ubusd"
    # Not PID 1 here, but it still serves `system` (board, info) and
    # `service`, which the init scripts below need.
    /sbin/procd >> "$_bb_log" 2>&1 &
    bk_wait 10 ubus call system board || bk_boot_fail="$bk_boot_fail procd"
    /sbin/logd -S 64 >> "$_bb_log" 2>&1 &
    bk_wait 10 ubus list log || bk_boot_fail="$bk_boot_fail logd"

    # WAN: the address, gateway and resolver docker gave eth0, never a
    # guessed prefix. LAN: an empty bridge on 10.231.0.1/24, deliberately not
    # 192.168.1.0/24, so nothing here can be taken for the owner's network.
    _bb_addr=$(ip -4 -o addr show dev eth0 | awk '{print $4; exit}')
    _bb_gw=$(ip -4 route show default | awk '{print $3; exit}')
    _bb_dns=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
    cat > /etc/config/network <<EOF
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config device
	option name 'br-lan'
	option type 'bridge'
	option bridge_empty '1'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '10.231.0.1/24'

config interface 'wan'
	option device 'eth0'
	option proto 'static'
	option ipaddr '$_bb_addr'
	option gateway '$_bb_gw'
	list dns '$_bb_dns'
EOF
    /sbin/netifd >> "$_bb_log" 2>&1 &
    bk_wait 10 bk_wan_up || bk_boot_fail="$bk_boot_fail netifd"

    # fw4 loads `table inet fw4`, which needs NET_ADMIN (docker run
    # --cap-add NET_ADMIN, the container's own namespace only).
    /etc/init.d/firewall start >> "$_bb_log" 2>&1
    bk_wait 10 nft list table inet fw4 || bk_boot_fail="$bk_boot_fail firewall"
    # The agent's DNS check asks 127.0.0.1: without dnsmasq every dns_* is
    # null and dns_resolver_ok false.
    /etc/init.d/dnsmasq start >> "$_bb_log" 2>&1
    bk_wait 10 pidof dnsmasq || bk_boot_fail="$bk_boot_fail dnsmasq"
    # A fresh network namespace has sent no IPv4 yet, and the agent keeps
    # its IPv4/IPv6 rate state only once a counter moved: without this the
    # second run has no rate either. One echo request counts, answered or not.
    ping -c 1 -W 1 "$_bb_gw" >> "$_bb_log" 2>&1

    {
        echo "== /etc/openwrt_release"
        cat /etc/openwrt_release
        echo "== ubus call system board"
        ubus call system board
        echo "== ubus list"
        ubus list
        echo "== nft list tables"
        nft list tables
        echo "== pidof"
        for _bb_p in ubusd procd logd netifd dnsmasq; do
            echo "$_bb_p: $(pidof "$_bb_p")"
        done
        echo "== not up:${bk_boot_fail:- (all up)}"
    } > "$_bb_env" 2>&1
}
