#!/usr/bin/env bash
# hw_smoke.sh - agent_openwrt.sh --dry-run on a real router, nothing installed.
#
#   tests/hw_smoke.sh [options] root@HOST
#     -p, --port PORT        ssh port (default 22)
#     -i, --identity FILE    ssh key (default: ssh's own choice)
#     -o OPTION              one more ssh option (repeatable), e.g.
#                            -o UserKnownHostsFile=FILE
#     --agent FILE           the agent to test (default: this checkout's
#                            vps-agent/agent_openwrt.sh)
#     --interval SECONDS     pause between the two dry runs (default 11;
#                            0 = one run)
#     --coexist              the router already runs the agent (see below)
#     --keep DIR             keep payloads, stderr and the router's facts
#     -h, --help
#
#   exit 0 passed | 1 validation failed | 2 usage or ssh error | 3 refused (not
#   OpenWrt, an installed agent without --coexist, --coexist with another
#   version) | 4 clean-up not verified
#
# The agent goes to a mktemp directory in /tmp over `ssh cat` (the OpenWrt
# rootfs has no sftp-server, and scp speaks SFTP now), runs with --dry-run -
# nothing is POSTed - under a 120 s watchdog, and its payloads are checked
# on this host like the CI's real-image runs (assert_real_payload.py hw,
# golden.py). Then the directory and every agent file the runs created are
# removed, and the router is listed again: anything left is exit 4. No
# opkg/apk, no cron edit, nothing outside /tmp.
#
# A dry run shares the installed agent's state: its rate state, the CPU cost
# of the last cron run, the caches and last-payload.json in its private
# directory, the version stamp (another version wipes every cache, SMART
# included) and the run lock. So a router with agent files is refused unless
# --coexist is given, and then: the installed agent must be the same version,
# the run is one (the installed agent's state gives it its deltas) with
# STATUS_TEST_TTY=1 (the cron run's cost stays), it starts between seconds 5
# and 35 of a minute with no run lock held, last-payload.json is restored,
# and only the files it created are removed. Left behind: the rate and cache
# files the dry run refreshed, so the installed agent's next report measures
# its rates over a shorter window.
#
# The host side runs under macOS's bash 3.2; validation needs python3 (3.9+).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
port=22
identity=""
agent="$here/../vps-agent/agent_openwrt.sh"
interval=11
coexist=0
keep=""
target=""
ssh_extra=()

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}
die() { # CODE MESSAGE
    echo "hw_smoke: $2" >&2
    exit "$1"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--port) [ $# -ge 2 ] || die 2 "$1 needs a value"; port=$2; shift 2 ;;
        -i|--identity) [ $# -ge 2 ] || die 2 "$1 needs a value"; identity=$2; shift 2 ;;
        -o) [ $# -ge 2 ] || die 2 "-o needs a value"; ssh_extra+=(-o "$2"); shift 2 ;;
        --agent) [ $# -ge 2 ] || die 2 "$1 needs a value"; agent=$2; shift 2 ;;
        --interval) [ $# -ge 2 ] || die 2 "$1 needs a value"; interval=$2; shift 2 ;;
        --coexist) coexist=1; shift ;;
        --keep) [ $# -ge 2 ] || die 2 "$1 needs a value"; keep=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; die 2 "unknown option $1" ;;
        *) [ -z "$target" ] || die 2 "one target only"; target=$1; shift ;;
    esac
done
[ -n "$target" ] || { usage >&2; die 2 "no target (root@HOST)"; }
case "$port" in ''|*[!0-9]*) die 2 "port '$port' is not a number" ;; esac
case "$interval" in ''|*[!0-9]*) die 2 "interval '$interval' is not a number of seconds" ;; esac
[ -s "$agent" ] || die 2 "agent '$agent' is missing or empty"
command -v python3 >/dev/null 2>&1 || die 2 "python3 is needed on this host"
[ "$coexist" = 1 ] && interval=0

local_dir="$(mktemp -d "${TMPDIR:-/tmp}/bk-hwsmoke-local.XXXXXX")" || die 2 "no local temp dir"
ssh_log="$local_dir/ssh.log"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -p "$port")
[ -n "$identity" ] && ssh_opts+=(-i "$identity" -o IdentitiesOnly=yes)
ssh_opts+=(${ssh_extra[@]+"${ssh_extra[@]}"})

# rsh SECONDS CMD - CMD on the router with no input; rshi SECONDS CMD - with
# this shell's stdin as its input. Both under a watchdog here too (macOS and
# busybox 24.10 have no `timeout`). ssh's own stderr (a key exchange warning,
# say) goes to ssh.log, never into what is checked.
rsh() {
    rshi "$@" < /dev/null
}
rshi() {
    local limit=$1 pid n=0
    shift
    # <&0: an asynchronous command's stdin is /dev/null without it.
    ssh "${ssh_opts[@]}" "$target" "$@" <&0 2>> "$ssh_log" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$n" -ge "$limit" ]; then
            kill "$pid" 2>/dev/null
            echo "watchdog: '$*' killed after $limit s" >> "$ssh_log"
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1
        n=$((n + 1))
    done
    wait "$pid"
}

# What the agent keeps on a router, and the crontab lines naming it: path,
# type and checksum, one line each, so two listings compare with diff.
# shellcheck disable=SC2016
remote_list='
for p in $(find /tmp/status-agent-* /var/run/status-agent-openwrt 2>/dev/null | sort); do
    if [ -L "$p" ]; then echo "L $p -> $(readlink "$p")"
    elif [ -d "$p" ]; then echo "D $p"
    else echo "F $p $(md5sum < "$p" 2>/dev/null | cut -d" " -f1)"; fi
done
crontab -l 2>/dev/null | grep agent_openwrt | sed "s/^/C /"
exit 0'

rdir=""
cleaned=0
cleanup_rc=0
pre="$local_dir/pre.txt"
post="$local_dir/post.txt"

# Remove the work directory and every agent path the runs created, then list
# again: anything else than before (in --coexist: a path more or less, or a
# change to the files it must leave alone) is exit 4.
cleanup_remote() {
    [ "$cleaned" = 1 ] && return 0
    cleaned=1
    [ -n "$rdir" ] || return 0
    rshi 30 "sh -s" <<EOF || { echo "hw_smoke: the clean-up on $target failed (see ssh.log)" >&2; cleanup_rc=4; }
case "$rdir" in /tmp/bk-hwsmoke.*) ;; *) exit 1 ;; esac
if [ -f "$rdir/last-payload.bak" ] && [ -s "$rdir/last-payload.dir" ]; then
    cp -p "$rdir/last-payload.bak" "\$(cat "$rdir/last-payload.dir")/last-payload.json"
fi
rm -rf "$rdir"
EOF
    # The paths the runs created, deepest first.
    rshi 30 "sh -s" <<< "$remote_list" > "$local_dir/now.txt" || cleanup_rc=4
    # (Not NR == FNR: the listing before is empty on a fresh router.)
    awk -v pre="$pre" 'BEGIN { while ((getline l < pre) > 0) { split(l, f, " "); if (f[1] != "C") seen[f[2]] = 1 } }
        $1 != "C" && !($2 in seen) { print $2 }' "$local_dir/now.txt" | sort -r > "$local_dir/new.txt"
    if [ -s "$local_dir/new.txt" ]; then
        # shellcheck disable=SC2016
        rshi 30 'while IFS= read -r p; do
            case "$p" in
                /tmp/status-agent-*|/var/run/status-agent-openwrt*)
                    if [ -d "$p" ] && [ ! -L "$p" ]; then rmdir "$p" 2>/dev/null || rm -rf "$p"; else rm -f "$p"; fi ;;
            esac
        done' < "$local_dir/new.txt" || cleanup_rc=4
    fi
    rshi 30 "sh -s" <<< "$remote_list" > "$post" || cleanup_rc=4
    if [ "$(rsh 10 "[ -e '$rdir' ] && echo left")" = left ]; then
        echo "hw_smoke: $rdir is still there" >&2
        cleanup_rc=4
    fi
    if [ "$coexist" = 1 ]; then
        # The refreshed rate and cache files may differ; a path more or less,
        # the crontab, the version stamp, the cron run's cost and the kept
        # last payload may not.
        awk '{print $1, $2}' "$pre" > "$local_dir/pre.paths"
        awk '{print $1, $2}' "$post" > "$local_dir/post.paths"
        fixed='^C |version\.stamp |/run\.(cpu|total) |/last-payload\.json '
        grep -E "$fixed" "$pre" > "$local_dir/pre.fixed"
        grep -E "$fixed" "$post" > "$local_dir/post.fixed"
        if ! diff "$local_dir/pre.paths" "$local_dir/post.paths" > "$local_dir/clean.diff" ||
            ! diff "$local_dir/pre.fixed" "$local_dir/post.fixed" >> "$local_dir/clean.diff"; then
            echo "hw_smoke: the router's agent files are not as they were:" >&2
            cat "$local_dir/clean.diff" >&2
            cleanup_rc=4
        fi
    elif ! diff "$pre" "$post" > "$local_dir/clean.diff"; then
        echo "hw_smoke: agent files left on the router:" >&2
        cat "$local_dir/clean.diff" >&2
        cleanup_rc=4
    fi
    return 0
}

finish() {
    local rc=$1
    cleanup_remote
    [ "$cleanup_rc" = 0 ] || rc=4
    if [ -n "$keep" ]; then
        mkdir -p "$keep" && cp -R "$local_dir/." "$keep/"
    fi
    rm -rf "$local_dir"
    exit "$rc"
}
trap 'finish $?' EXIT
trap 'exit 130' INT TERM

# --- 1. preflight ---------------------------------------------------------------
# shellcheck disable=SC2016
preflight='[ -f /etc/openwrt_release ] || { echo "release="; exit 0; }
. /etc/openwrt_release
echo "release=$DISTRIB_DESCRIPTION"
echo "target=$DISTRIB_TARGET"
command -v ubus >/dev/null 2>&1 && echo "ubus=yes" || echo "ubus=no"
[ -f /usr/share/libubox/jshn.sh ] && echo "jshn=yes" || echo "jshn=no"
echo "tmp_free_kb=$(df -k /tmp 2>/dev/null | awk "NR == 2 {print \$4}")"
command -v sha256sum >/dev/null 2>&1 && echo "sum=sha256sum" || echo "sum=md5sum"'
facts=$(rshi 20 "sh -s" <<< "$preflight")
rc=$?
if [ "$rc" != 0 ]; then
    cat "$ssh_log" >&2
    die 2 "ssh to $target failed (exit $rc)"
fi
fact() { printf '%s\n' "$facts" | sed -n "s/^$1=//p" | head -n 1; }
release=$(fact release)
[ -n "$release" ] || die 3 "$target has no /etc/openwrt_release: not OpenWrt, refused"
[ "$(fact ubus)" = yes ] || die 3 "$target has no ubus: refused"
[ "$(fact jshn)" = yes ] || die 3 "$target has no /usr/share/libubox/jshn.sh: refused"
free_kb=$(fact tmp_free_kb)
case "$free_kb" in ''|*[!0-9]*) free_kb=0 ;; esac
[ "$free_kb" -ge 1024 ] || die 3 "$target has ${free_kb} kB free in /tmp, 1024 needed: refused"
sum=$(fact sum)

# --- 2./3. what the agent already has there -------------------------------------
rshi 30 "sh -s" <<< "$remote_list" > "$pre" || die 2 "listing the agent files on $target failed"
installed_version=""
if [ -s "$pre" ]; then
    if [ "$coexist" != 1 ]; then
        echo "hw_smoke: $target already has agent files; a dry run would share their state:" >&2
        sed 's/^/  /' "$pre" >&2
        die 3 "refused: run with --coexist (see --help), or remove them"
    fi
    installed=$(awk '$1 == "C" { for (i = 2; i <= NF; i++) if ($i ~ /agent_openwrt[^ ]*\.sh$/) { print $i; exit } }' "$pre")
    [ -n "$installed" ] || die 3 "refused: agent files but no crontab line naming agent_openwrt*.sh, so no version to compare"
    installed_version=$(rsh 10 "sed -n 's/^AGENT_VERSION=\"\\(.*\\)\"\$/\\1/p' '$installed' | head -n 1")
    tested_version=$(sed -n 's/^AGENT_VERSION="\(.*\)"$/\1/p' "$agent" | head -n 1)
    [ -n "$installed_version" ] && [ "$installed_version" = "$tested_version" ] ||
        die 3 "refused: $installed is version '${installed_version:-?}', the tested agent '$tested_version' (the version stamp would wipe its caches)"
fi

# --- 4. upload --------------------------------------------------------------------
rdir=$(rsh 10 "mktemp -d /tmp/bk-hwsmoke.XXXXXX") || die 2 "mktemp on $target failed"
case "$rdir" in /tmp/bk-hwsmoke.*) ;; *) rdir=""; die 2 "mktemp on $target answered '$rdir'" ;; esac
rshi 60 "cat > '$rdir/agent_openwrt.sh'" < "$agent" || die 2 "upload failed"
algo=sha256
[ "$sum" = md5sum ] && algo=md5
want=$(python3 -c 'import hashlib,sys; print(hashlib.new(sys.argv[1], open(sys.argv[2], "rb").read()).hexdigest())' "$algo" "$agent")
got=$(rsh 10 "$sum '$rdir/agent_openwrt.sh'" | cut -d' ' -f1)
[ "$want" = "$got" ] || die 2 "upload corrupted: $algo here $want, there '$got'"

# --- 5./6. run and fetch ------------------------------------------------------------
runs="r1"
[ "$interval" -gt 0 ] && runs="r1 r2"
tty=""
[ "$coexist" = 1 ] && tty=1
for r in $runs; do
    [ "$r" = r1 ] || sleep "$interval"
    # The remote side: the agent in the background, killed after 120 s.
    # --coexist waits for a quiet part of the minute and keeps last-payload.json.
    rshi 200 "sh -s" <<EOF
cd "$rdir" || exit 2
if [ -n "$tty" ]; then
    n=0
    while :; do
        s=\$(date +%S); s=\${s#0}
        priv=""
        for d in /var/run/status-agent-openwrt /tmp/status-agent-openwrt-private; do [ -d "\$d" ] && { priv=\$d; break; }; done
        if [ "\$s" -ge 5 ] && [ "\$s" -le 35 ] && [ ! -d "\$priv/run.lock" ]; then break; fi
        [ \$n -ge 70 ] && { echo "no quiet moment in 70 s (run.lock held?)" > $r.err; echo 75 > $r.rc; exit 0; }
        sleep 1; n=\$((n + 1))
    done
    if [ -n "\$priv" ] && [ -f "\$priv/last-payload.json" ]; then
        cp -p "\$priv/last-payload.json" last-payload.bak && echo "\$priv" > last-payload.dir
    fi
    export STATUS_TEST_TTY=1
fi
sh ./agent_openwrt.sh --dry-run > $r.json 2> $r.err &
p=\$!
n=0
while kill -0 \$p 2>/dev/null; do
    if [ \$n -ge 120 ]; then
        kill \$p 2>/dev/null; sleep 2; kill -9 \$p 2>/dev/null
        echo "hw_smoke watchdog: the agent was killed after 120 s" >> $r.err
        break
    fi
    sleep 1; n=\$((n + 1))
done
wait \$p
echo \$? > $r.rc
exit 0
EOF
    [ $? = 0 ] || die 2 "running $r on $target failed (see $ssh_log)"
    for ext in json err rc; do
        rsh 30 "cat '$rdir/$r.$ext'" > "$local_dir/$r.$ext" || die 2 "fetching $r.$ext failed"
    done
done
rsh 20 "cat /etc/openwrt_release; ubus call system board" > "$local_dir/env.txt" 2>/dev/null

# --- 7. clean up (before validating: a failed check must not leave anything) -----
cleanup_remote

# --- 8. validate --------------------------------------------------------------------
single=()
[ "$interval" -gt 0 ] || single=(--single)
python3 "$here/assert_real_payload.py" hw "$local_dir" --agent "$agent" ${single[@]+"${single[@]}"} > "$local_dir/assert.txt"
assert_rc=$?
last="r1"
[ "$interval" -gt 0 ] && last="r2"
files=("$local_dir/r1.json")
[ "$interval" -gt 0 ] && files+=("$local_dir/r2.json")
python3 "$here/golden.py" check openwrt "${files[@]}" > "$local_dir/golden.txt"
golden_rc=$?
# The failures, with the stderr lines a check quotes under its FAIL line.
awk '/^FAIL/ { on = 1; print; next } on && /^ +\| / { print; next } { on = 0 }' \
    "$local_dir/assert.txt" "$local_dir/golden.txt"

# --- 9. summary ----------------------------------------------------------------------
python3 - "$local_dir" "$last" "$here" "$target" "$release" "$(fact target)" "$rdir" "$cleanup_rc" <<'EOF'
import json, os, sys
d, last, here, target, release, arch, rdir, cleanup_rc = sys.argv[1:]
golden_path = os.path.join(here, "golden", "openwrt.json")
def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None
p = load(os.path.join(d, last + ".json"))
if not isinstance(p, dict):
    print("hw_smoke %s  %s (%s): %s.json is no JSON object - see the FAIL lines" % (target, release, arch, last))
    print("clean-up: %s" % ("%s removed, no agent state left behind" % rdir if cleanup_rc == "0" else "NOT verified"))
    sys.exit(0)
g = load(golden_path) or {}
def rc(r):
    try:
        return open(os.path.join(d, r + ".rc")).read().strip()
    except OSError:
        return "-"
runs = [r for r in ("r1", "r2") if os.path.exists(os.path.join(d, r + ".json"))]
def secs(r):
    x = load(os.path.join(d, r + ".json")) or {}
    v = x.get("agent_run_ms")
    return "%.1f s" % (v / 1000.0) if isinstance(v, (int, float)) else "? s"
measured = [k for k, v in p.items() if v is not None]
unpinned = sorted(k for k in measured if k in g and g[k] is None)
sys.path.insert(0, here)
import assert_real_payload as a
err = [l for r in runs for l in open(os.path.join(d, r + ".err"), errors="replace").read().splitlines()]
bad = [l for l in err if not a.LOG_LINE.match(l) or any(m in l for m in a.MARKERS)]
def num(k, unit=""):
    v = p.get(k)
    return ("%s%s" % (v, unit)) if v is not None else "null"
wan = "up" if p.get("wan_up") else ("down" if p.get("wan_up") is False else "null")
print("hw_smoke %s  %s (%s)  model %s" % (target, release, arch, json.dumps(p.get("model"))))
print("agent %s  %s  exit %s" % (p.get("version"), "  ".join("%s %s" % (r, secs(r)) for r in runs), "/".join(rc(r) for r in runs)))
print("payload %d keys, %d measured, %d null" % (len(p), len(measured), len(p) - len(measured)))
if unpinned:
    print("measured here, not pinned by CI (golden null): %s" % ", ".join(unpinned))
print("stderr %d log lines, %d other or with an error marker" % (len(err) - len(bad), len(bad)))
print("cpu %s  ram %s  hdd %s  wan %s (%s, %s)  radios %d  disks %d  pkg %s" % (
    num("cpu", " %"), num("ram", " %"), num("hdd", " %"), wan, p.get("wan_proto"), p.get("wan_l3_device"),
    len(p.get("wifi_radios") or []), len(p.get("storage_disks") or []),
    (p.get("agent_tools") or {}).get("pkg_manager")))
print("clean-up: %s" % ("%s removed, no agent state left behind" % rdir if cleanup_rc == "0" else "NOT verified"))
EOF
if [ "$assert_rc" = 0 ] && [ "$golden_rc" = 0 ]; then
    [ "$cleanup_rc" = 0 ] && echo "PASS"
    exit 0
fi
echo "FAIL (details: assert.txt and golden.txt${keep:+ in $keep})"
exit 1
