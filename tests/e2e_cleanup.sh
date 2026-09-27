# shellcheck shell=bash
# Sourced by the run_*_e2e.sh scripts: how every run ends.
#
# The Linux and OpenWrt harnesses run as root in their containers (they write
# /etc, /usr/sbin and /root there), so on a Linux host what they leave in the
# bind-mounted work directory belongs to root, and a runner that is not root
# cannot remove it: CI's `rm -rf` failed on hundreds of files after "all
# passed" and turned the run red. Docker Desktop maps the files to the user,
# so a Mac never shows it.

# bk_e2e_exit STATUS DIR IMAGE [NAME] [HOOK] - the EXIT trap:
#   trap 'bk_e2e_exit $? "$work" IMAGE NAME HOOK' EXIT
# Whatever under DIR the calling user does not own is handed back to it by
# IMAGE (the harness's own image, as root, never pulled), then HOOK runs, DIR
# is removed, and the script exits with STATUS - the tests' result. A cleanup
# problem is a warning, never the result.
bk_e2e_exit() {
    local rc=$1 work=$2 image=$3 name=${4:-} hook=${5:-} uid gid
    set +e
    uid=$(id -u)
    gid=$(id -g)
    if [ "$uid" != 0 ] && [ -n "$(find "$work" ! -user "$uid" -print -quit 2>/dev/null)" ]; then
        docker run --rm --pull never --user 0:0 ${name:+--name "$name-chown"} \
            -v "$work:/w" "$image" chown -R "$uid:$gid" /w >/dev/null ||
            echo "warning: could not hand $work back to uid $uid" >&2
    fi
    if [ -n "$hook" ]; then
        "$hook" || echo "warning: $hook failed" >&2
    fi
    rm -rf "$work" 2>/dev/null || echo "warning: could not remove $work" >&2
    exit "$rc"
}
