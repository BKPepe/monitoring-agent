#!/bin/sh
# The container as a router for ../hw_smoke_selftest.sh: boot.sh's services,
# the model and board name a router's preinit writes to /tmp/sysinfo (procd's
# `system board` reads them), and dropbear with the test's throwaway key in
# the foreground until the container is removed.
# ssh arrives on eth0, which boot.sh makes the WAN, and fw4 rejects input
# there: one rule lets the test in, as a router's admin comes in from the LAN.
cat >> /etc/config/firewall <<'EOF'

config rule
	option name 'Allow-SSH-hw-smoke-selftest'
	option src 'wan'
	option proto 'tcp'
	option dest_port '22'
	option target 'ACCEPT'
EOF
. /harness/boot.sh
bk_boot /tmp/bk-boot.log /tmp/bk-env.txt
echo "hw_smoke self-test (x86_64 container)" > /tmp/sysinfo/model
echo "bk,hw-smoke-selftest" > /tmp/sysinfo/board_name
mkdir -p /etc/dropbear
cp /hwkey/id.pub /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys
dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key > /dev/null 2>&1
echo "router up, services not up:${bk_boot_fail:- none}"
exec /usr/sbin/dropbear -F -E -p 22 -r /etc/dropbear/dropbear_ed25519_host_key
