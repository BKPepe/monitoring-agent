#!/bin/bash
# Unit tests of agent.sh functions, cut out of the shipped script by name so
# they exercise its own code. Usage: agent_sh_units.sh path/to/agent.sh
set -u
src="$1"
fails=0
load() {  # load NAME: define the function NAME as agent.sh has it
    eval "$(sed -n "/^$1() {/,/^}/p" "$src")"
    declare -F "$1" >/dev/null || { echo "FAIL load $1"; exit 1; }
}
check() {  # check LABEL ACTUAL EXPECTED
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}

load bk_cpu_from_stat
# user nice system idle iowait irq softirq steal guest guest_nice
check "cpu: steal counts in the total (half the time stolen is 50 %, not 100 %)" \
    "$(bk_cpu_from_stat "cpu  100 0 100 700 100 0 0 0 0 0" "cpu  150 0 150 800 100 0 0 200 0 0")" "75.0 50.0 0.0"
check "cpu: guest is inside user, not counted twice" \
    "$(bk_cpu_from_stat "cpu  100 0 0 900 0 0 0 0 0 0" "cpu  200 0 0 1000 0 0 0 0 100 0")" "50.0 0.0 0.0"
check "cpu: counters that did not move give nothing" \
    "$(bk_cpu_from_stat "cpu  1 2 3 4 5 6 7 8 0 0" "cpu  1 2 3 4 5 6 7 8 0 0")" ""

load bk_net_stats
# eth0 only: 1 MB in, 2 MB out, 1+2+3+4 errors; wg0, tailscale0, tun0 carried
# the same bytes over eth0 already, lo and docker0 are not the host's line.
check "net: tunnels, loopback and containers stay out of the traffic" \
    "$(bk_net_stats "$(dirname "$0")/fixtures/net_dev_tunnels")" "3000000,10"

[ "$fails" -eq 0 ] && echo "agent.sh units: all passed" || echo "agent.sh units: $fails failed"
exit "$fails"
