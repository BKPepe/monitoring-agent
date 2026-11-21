#!/usr/bin/env bash
# agent.sh and agent.py end to end in a Debian container: real /proc, real
# ps, two runs each so deltas exist, a run in cron's bare environment, the
# agent.py unit tests, and the security cases against a fake server
# (linux/run-security-cases.sh). Needs docker and python3 on the host.
# BK_E2E_CONTAINER names the container (default bk-linux-e2e-<pid>).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# Every agent ends with "# bk-agent-end <AGENT_VERSION>", and the updaters
# install nothing without it. A version bump that forgets the sentinel would
# leave every updated agent refusing the release as "incomplete".
sentinel_ok=1
for f in agent.sh agent.py; do
    src="$here/../vps-agent/$f"
    ver=$(sed -n -e 's/^AGENT_VERSION="\(.*\)"$/\1/p' -e 's/^AGENT_VERSION = "\(.*\)"$/\1/p' "$src" | head -n 1)
    last=$(tail -n 1 "$src")
    if [ -n "$ver" ] && [ "$last" = "# bk-agent-end $ver" ]; then
        echo "ok    $f: ends with its sentinel (# bk-agent-end $ver)"
    else
        echo "FAIL  $f: last line '$last' is not '# bk-agent-end $ver'"
        sentinel_ok=0
    fi
done
[ "$sentinel_ok" = 1 ]

work="$(mktemp -d)"
. "$here/e2e_cleanup.sh"
# BK_E2E_KEEP=<dir>: keep the payloads, logs and case facts there.
keep_out() {
    # A .passed left there by an earlier run must not vouch for this one.
    [ -z "${BK_E2E_KEEP:-}" ] || { mkdir -p "$BK_E2E_KEEP" && rm -f "$BK_E2E_KEEP/.passed" &&
        cp -R "$work/out/." "$BK_E2E_KEEP/"; }
}
name="${BK_E2E_CONTAINER:-bk-linux-e2e-$$}"
trap 'bk_e2e_exit $? "$work" bk-agent-e2e "$name" keep_out' EXIT
mkdir -p "$work/agent" "$work/out" "$work/tests"
cp "$here/../vps-agent/agent.sh" "$here/../vps-agent/agent.py" "$work/agent/"
cp "$here/test_agent_py.py" "$work/tests/"
docker build -q -t bk-agent-e2e "$here/linux" >/dev/null
# Two small tmpfs mounts: the update case for a directory without room for
# the new file.
docker run --rm --name "$name" \
    --tmpfs /tiny-sh:rw,size=512k --tmpfs /tiny-py:rw,size=512k \
    -v "$work:/work" -v "$here/linux:/harness:ro" bk-agent-e2e bash /harness/run-in-container.sh
# The payload runs for the golden check, second runs first: golden.py update
# takes the first measured value of a key in this order.
printf 'linux-bash %s\n' sh2 sh1 sh3 cron_sh_i cron_sh_c > "$work/out/payload_runs.txt"
printf 'linux-python %s\n' py2 py1 cron_py_i cron_py_c >> "$work/out/payload_runs.txt"
python3 "$here/assert_linux_payload.py" "$work/out"
python3 "$here/linux/assert_security.py" "$work/out"
# Its own checks passed: golden.py update takes a kept out/ only with this
# (before the golden check: a new key fails that one, and this is the run
# the golden file is renewed from).
touch "$work/out/.passed"
# update_golden.sh sets BK_GOLDEN_CHECK=0: it runs the harness to renew them.
[ "${BK_GOLDEN_CHECK:-1}" = 0 ] || python3 "$here/golden.py" check "$work/out"
