json_init() { :; }; json_load() { :; }; json_select() { :; }; json_get_keys() { :; }; json_cleanup() { :; }; json_is_a() { return 1; }; json_add_string() { :; }; json_dump() { echo '{}'; }
json_get_var() { case "$2" in up) eval "$1=1" ;; proto) eval "$1=dhcp" ;; l3_device) eval "$1=eth0" ;; uptime) eval "$1=3600" ;; *) eval "$1=''" ;; esac; }
