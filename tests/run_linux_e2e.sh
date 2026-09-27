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
    [ -z "${BK_E2E_KEEP:-}" ] || { mkdir -p "$BK_E2E_KEEP" && cp -R "$work/out/." "$BK_E2E_KEEP/"; }
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
python3 "$here/assert_linux_payload.py" "$work/out"
python3 "$here/linux/assert_security.py" "$work/out"
