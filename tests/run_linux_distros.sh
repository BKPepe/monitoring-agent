#!/usr/bin/env bash
# agent.sh and agent.py with a plain --dry-run on Ubuntu 24.04, Alpine 3.24
# (busybox ps/awk/df) and Rocky 9, twice each, asserted by
# assert_real_payload.py. Debian is run_linux_e2e.sh's. Needs docker and
# python3 on the host.
#
#   run_linux_distros.sh [ubuntu|alpine|rocky|all]    (default: all)
#
# BK_E2E_NAME: prefix of the container names. BK_E2E_KEEP=<dir>: keep out/.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

case "${1:-all}" in
    ubuntu|alpine|rocky) distros="$1" ;;
    all) distros="ubuntu alpine rocky" ;;
    *) echo "usage: $0 [ubuntu|alpine|rocky|all]" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
. "$here/e2e_cleanup.sh"
keep_out() {
    # A .passed left there by an earlier run must not vouch for this one.
    [ -z "${BK_E2E_KEEP:-}" ] || { mkdir -p "$BK_E2E_KEEP" && rm -f "$BK_E2E_KEEP/.passed" &&
        cp -R "$work/out/." "$BK_E2E_KEEP/"; }
}
prefix="${BK_E2E_NAME:-bk-linux-distro-$$}"
cleanup_img="bk-distro-ubuntu"
trap 'bk_e2e_exit $? "$work" "$cleanup_img" "$prefix" keep_out' EXIT
mkdir -p "$work/agent" "$work/out"
cp "$here/../vps-agent/agent.sh" "$here/../vps-agent/agent.py" "$work/agent/"

rc=0
for d in $distros; do
    echo "== $d"
    # The base images are pinned by digest in the Dockerfiles.
    docker build -q -t "bk-distro-$d" "$here/linux-distros/$d" > /dev/null
    cleanup_img="bk-distro-$d"
    docker run --rm --name "$prefix-$d" -v "$work:/work" -v "$here/linux-distros:/harness:ro" \
        "bk-distro-$d" sh /harness/run-in-container.sh "$d"
    printf 'linux-bash %s\n' "${d}_sh2" "${d}_sh1" >> "$work/out/payload_runs.txt"
    printf 'linux-python %s\n' "${d}_py2" "${d}_py1" >> "$work/out/payload_runs.txt"
    python3 "$here/assert_real_payload.py" "$d" "$work/out" || rc=1
done
# Its own checks passed: golden.py update takes a kept out/ only with this
# (before the golden check: a new key fails that one, and this is the run
# the golden file is renewed from).
[ "$rc" != 0 ] || touch "$work/out/.passed"
# The shape against golden/linux-*.json (BK_GOLDEN_CHECK=0: update_golden.sh).
[ "${BK_GOLDEN_CHECK:-1}" = 0 ] || python3 "$here/golden.py" check "$work/out" || rc=1
exit "$rc"
