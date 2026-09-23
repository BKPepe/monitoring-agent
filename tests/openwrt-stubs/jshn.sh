# Minimal stand-in for /usr/share/libubox/jshn.sh: a cursor over one canned
# `network.interface dump` (wan / lan / lte). Paths are what the agent
# selects; anything else reads as empty, like a missing key in jshn.
BK_SEL=""
# BK_STUB_WAN picks the WAN line of the canned dump; bin/ubus follows the same
# switch. The default is a plain DHCP port on eth0, which exists both in the
# container and in the fake root. The rest are the branches of the WAN walk
# (WAN 3.1.1), one netdev chain each, built by mkroot.sh:
#   pppoe  the owner's line, PPPoE over VLAN 848 over eth2
#   ppp0   a lone ppp netdev with nothing below it
#   eth2   the port itself, DHCP
#   brwan  a bridge over the single port eth2
#   brwan2 a bridge over two ports
#   dsa    a DSA user port whose carrier is down, above the conduit eth1
case "$BK_STUB_WAN" in
    pppoe)  BK_STUB_PROTO=pppoe; BK_STUB_DEV=eth2.848; BK_STUB_L3=pppoe-wan ;;
    ppp0)   BK_STUB_PROTO=pppoe; BK_STUB_DEV=ppp0; BK_STUB_L3=ppp0 ;;
    eth2)   BK_STUB_PROTO=dhcp; BK_STUB_DEV=eth2; BK_STUB_L3=eth2 ;;
    brwan)  BK_STUB_PROTO=dhcp; BK_STUB_DEV=br-wan; BK_STUB_L3=br-wan ;;
    brwan2) BK_STUB_PROTO=dhcp; BK_STUB_DEV=br-wan2; BK_STUB_L3=br-wan2 ;;
    dsa)    BK_STUB_PROTO=dhcp; BK_STUB_DEV=wan; BK_STUB_L3=wan ;;
    *)      BK_STUB_PROTO=dhcp; BK_STUB_DEV=eth0; BK_STUB_L3=eth0 ;;
esac
json_init() { BK_SEL=""; }
# Each load of the interface dump is logged with the agent's PID: a run loads
# it once and reads everything from that one tree (a real jshn load replays
# the whole dump through eval). echo is a builtin, so this adds no fork.
json_load() {
    BK_SEL=""
    case "$1" in *'"interface"'*) echo "$$" >> /work/out/jshn_calls.log ;; esac
}
json_cleanup() { BK_SEL=""; }
# An empty name goes back to the root, as in the real jshn.sh: the agent loads
# the interface dump once and returns to its root with `json_select ""`.
json_select() { case "$1" in "") BK_SEL="" ;; ..) BK_SEL="${BK_SEL%/*}" ;; *) BK_SEL="$BK_SEL/$1" ;; esac; }
json_is_a() { return 1; }
json_get_type() { eval "$1=''"; }
json_add_string() { :; }; json_add_int() { :; }; json_add_boolean() { :; }
json_add_object() { :; }; json_close_object() { :; }; json_add_array() { :; }; json_close_array() { :; }
json_dump() { echo '{}'; }
json_get_keys() {
    # jshn: `json_get_keys VAR [KEY]` lists the children of KEY under the
    # current cursor without selecting it.
    _p="$BK_SEL"; [ -n "$2" ] && _p="$BK_SEL/$2"
    case "$_p" in
        /interface) eval "$1='0 1 2'" ;;
        /interface/0/ipv4-address|/interface/0/route|/interface/1/ipv4-address|/interface/2/ipv4-address) eval "$1='0'" ;;
        *) eval "$1=''" ;;
    esac
}
json_get_values() {
    case "$BK_SEL:$2" in
        # Documentation addresses (RFC 5737): no resolver anybody runs, and
        # no address of the owner's line, ever reaches this repository.
        /interface/0:dns-server) eval "$1='192.0.2.53 198.51.100.53'" ;;
        *) eval "$1=''" ;;
    esac
}
json_get_var() {
    case "$BK_SEL:$2" in
        # `ubus call system board` (the cursor is at the root)
        :hostname) eval "$1=turris" ;;
        :kernel) eval "$1=5.15.148" ;;
        :model) eval "$1='Turris Omnia'" ;;
        :board_name) eval "$1=cznic,turris-omnia" ;;
        /release:distribution) eval "$1=TurrisOS" ;;
        /release:version) eval "$1=7.2.3" ;;
        /interface/0:interface) eval "$1=wan" ;;
        /interface/0:up) eval "$1=1" ;;
        # The WAN line comes from the BK_STUB_WAN switch at the top.
        /interface/0:proto) eval "$1=$BK_STUB_PROTO" ;;
        /interface/0:l3_device) eval "$1=$BK_STUB_L3" ;;
        /interface/0:device) eval "$1=$BK_STUB_DEV" ;;
        /interface/0:uptime) eval "$1=3600" ;;
        /interface/0/ipv4-address/0:address) eval "$1=203.0.113.10" ;;
        /interface/0/ipv4-address/0:mask) eval "$1=24" ;;
        /interface/0/route/0:mask) eval "$1=0" ;;
        /interface/0/route/0:nexthop) eval "$1=203.0.113.1" ;;
        /interface/1:interface) eval "$1=lan" ;;
        /interface/1:up) eval "$1=1" ;;
        /interface/1:proto) eval "$1=static" ;;
        /interface/1/ipv4-address/0:address) eval "$1=192.168.1.1" ;;
        /interface/1/ipv4-address/0:mask) eval "$1=24" ;;
        /interface/2:interface) eval "$1=lte" ;;
        /interface/2:up) eval "$1=1" ;;
        /interface/2:proto) eval "$1=dhcp" ;;
        # loopback: exists in the container, so the LTE rate path has counters to read
        /interface/2:l3_device) eval "$1=lo" ;;
        /interface/2:uptime) eval "$1=700" ;;
        /interface/2/ipv4-address/0:address) eval "$1=192.168.8.100" ;;
        *) eval "$1=''" ;;
    esac
}
