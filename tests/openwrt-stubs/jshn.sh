# Minimal stand-in for /usr/share/libubox/jshn.sh: a cursor over one canned
# `network.interface dump` (wan / lan / lte). Paths are what the agent
# selects; anything else reads as empty, like a missing key in jshn.
BK_SEL=""
json_init() { BK_SEL=""; }
json_load() { BK_SEL=""; }
json_cleanup() { BK_SEL=""; }
json_select() { case "$1" in ..) BK_SEL="${BK_SEL%/*}" ;; *) BK_SEL="$BK_SEL/$1" ;; esac; }
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
        /interface/0:dns-server) eval "$1='1.1.1.1 9.9.9.9'" ;;
        *) eval "$1=''" ;;
    esac
}
json_get_var() {
    case "$BK_SEL:$2" in
        /interface/0:interface) eval "$1=wan" ;;
        /interface/0:up) eval "$1=1" ;;
        /interface/0:proto) eval "$1=dhcp" ;;
        /interface/0:l3_device) eval "$1=eth0" ;;
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
