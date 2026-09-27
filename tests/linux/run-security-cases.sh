#!/bin/bash
# Security cases for agent.sh and agent.py, run inside the Debian container
# by run-in-container.sh: remote actions (digits gate, service-name rule,
# single-use nonce), the --selfcheck gate, self-update refusals and the
# rollback of a version the server keeps refusing. Every agent run talks to
# fake_api.py on 127.0.0.1 over real curl / urllib, so the code under test
# is the code that ships - no seam in the agents.
#
# Each case leaves /work/out/sec/<case>.facts (key=value lines), plus the
# POST bodies the fake server saw, its GETs and the agent's log.
# assert_security.py reads them on the host.
set -u
SRC=/agent
OUT=/work/out/sec
API=/srv/api
PORT=18080
KEY=bk-test-key-0123456789abcdef
mkdir -p "$OUT" "$API/files"

python3 /harness/fake_api.py "$API" "$PORT" &
api_pid=$!
for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/files/none" && break
    sleep 0.1
done

# restart_service must reach the init.d fixture below; with systemctl in the
# image the agents would go through it instead.
if command -v systemctl >/dev/null 2>&1; then
    echo "harness: systemctl is present, the init.d fixture would not be used" >&2
    exit 1
fi
# The service a correct restart_service runs: one line per restart.
cat > /etc/init.d/bkfake <<'EOF'
#!/bin/sh
echo "restart $*" >> /tmp/bkfake.log
EOF
chmod +x /etc/init.d/bkfake
# The same, under a name systemd would read as a target: a restart of it must
# never run (poweroff.target and emergency.target are the real ones).
cp /etc/init.d/bkfake /etc/init.d/bkfake.target
# For the warm-cache update case: three disks whose smartctl hangs (the
# agent's own `timeout 20` fires on each), in a directory put first in PATH
# for that case only.
mkdir -p /tmp/slowdisk
printf '#!/bin/sh\nprintf "sda disk\\nsdb disk\\nsdc disk\\n"\n' > /tmp/slowdisk/lsblk
printf '#!/bin/sh\necho "smartctl $*" >> /tmp/slowdisk.log\nsleep 30\n' > /tmp/slowdisk/smartctl
chmod +x /tmp/slowdisk/lsblk /tmp/slowdisk/smartctl
# What a path-traversing service name would run. It must never write /tmp/pwned.
printf '#!/bin/sh\ntouch /tmp/pwned\n' > /tmp/pwn
chmod +x /tmp/pwn

file_of() { [ "$1" = sh ] && echo agent.sh || echo agent.py; }
version_of() { # KIND FILE
    if [ "$1" = sh ]; then sed -n 's/^AGENT_VERSION="\(.*\)"$/\1/p' "$2"; else sed -n 's/^AGENT_VERSION = "\(.*\)"$/\1/p' "$2"; fi
}
sha_of() { if [ -f "$1" ]; then sha256sum "$1" | awk '{print $1}'; else echo none; fi; }

scenario() { printf '%s\n' "$1" > "$API/scenario.json"; }

# new_case KIND NAME: a fresh install directory with the agent under test and
# a config that points it at the fake server, actions and updates on.
new_case() {
    local d="/sec/$1-$2"
    rm -rf "$d"
    mkdir -p "$d"
    cp "$SRC/$(file_of "$1")" "$d/"
    printf 'API_URL="http://127.0.0.1:%s/agent_api.php"\nAGENT_KEY="%s"\nREMOTE_ACTIONS_ENABLED="1"\nAUTO_UPDATE="1"\n' "$PORT" "$KEY" > "$d/agent.cfg"
    : > "$API/posts.jsonl"
    : > "$API/gets.log"
    rm -f /tmp/pwned /tmp/bkfake.log
    echo "$d"
}

# run_agent KIND DIR LABEL [ENV...]: one ordinary run, as cron would start it.
run_agent() {
    local kind=$1 d=$2 label=$3
    shift 3
    if [ "$kind" = sh ]; then
        env "$@" bash "$d/agent.sh" > "$OUT/$label.stdout" 2> "$OUT/$label.stderr" < /dev/null
    else
        env "$@" python3 "$d/agent.py" > "$OUT/$label.stdout" 2> "$OUT/$label.stderr" < /dev/null
    fi
    echo $? > "$OUT/$label.rc"
}

# facts KIND DIR LABEL: what the assertions look at, after the case.
facts() {
    local kind=$1 d=$2 label=$3 f
    f="$d/$(file_of "$kind")"
    {
        echo "rc=$(cat "$OUT/$label.rc" 2>/dev/null)"
        echo "agent_sha=$(sha_of "$f")"
        echo "agent_version=$(version_of "$kind" "$f")"
        echo "mode=$(stat -c %a "$f" 2>/dev/null)"
        echo "prev_sha=$(sha_of "$f.prev")"
        echo "new_exists=$([ -e "$f.new" ] && echo 1 || echo 0)"
        echo "probation=$(cat "$f.probation" 2>/dev/null)"
        echo "last_ok=$(cat "$f.last-ok" 2>/dev/null)"
        echo "refused=$(cat "$f.refused" 2>/dev/null)"
        echo "pwned=$([ -e /tmp/pwned ] && echo 1 || echo 0)"
        echo "restarts=$(cat /tmp/bkfake.log 2>/dev/null | wc -l)"
        echo "files=$(cd "$d" && ls -A | tr '\n' ' ')"
    } > "$OUT/$label.facts"
    cp "$API/posts.jsonl" "$OUT/$label.posts.jsonl"
    cp "$API/gets.log" "$OUT/$label.gets"
    cp "$d/agent.log" "$OUT/$label.log" 2>/dev/null || : > "$OUT/$label.log"
}

# variant KIND VERSION NAME [MUTATION]: an update file built from the agent
# under test, with AGENT_VERSION and the end sentinel both set to VERSION.
variant() {
    local kind=$1 ver=$2 name=$3 mut=${4:-} src cur out
    src="$SRC/$(file_of "$kind")"
    cur=$(version_of "$kind" "$src")
    out="$API/files/$name"
    if [ "$kind" = sh ]; then
        sed -e "s/^AGENT_VERSION=\"$cur\"\$/AGENT_VERSION=\"$ver\"/" -e "s/^# bk-agent-end $cur\$/# bk-agent-end $ver/" "$src" > "$out"
    else
        sed -e "s/^AGENT_VERSION = \"$cur\"\$/AGENT_VERSION = \"$ver\"/" -e "s/^# bk-agent-end $cur\$/# bk-agent-end $ver/" "$src" > "$out"
    fi
    case "$mut" in
        nosentinel) sed -i '$d' "$out" ;;
        truncated) head -n $(( $(wc -l < "$out") * 6 / 10 )) "$out" > "$out.cut" && mv "$out.cut" "$out" ;;
        # The 0.1.x bash release that broke: a missing comma in the payload.
        # `bash -n` passes, the server answers 400 to every report.
        badjson) sed -i 's/^  "agent_type": "bash",$/  "agent_type": "bash"/' "$out" ;;
        # The agent.py release that went silent for 17 days: a NameError in
        # main() that py_compile does not see.
        nameerror) sed -i 's/^    cpu, cpu_steal, iowait = get_cpu_usage()$/    _bk_probe = name_that_does_not_exist\n&/' "$out" ;;
    esac
    # A variant that did not take its mutation would make its case pass
    # for the wrong reason.
    if [ -z "$mut" ] || [ "$mut" = badjson ] || [ "$mut" = nameerror ]; then
        [ "$(tail -n 1 "$out")" = "# bk-agent-end $ver" ] || { echo "harness: variant $name has no sentinel" >&2; exit 1; }
    fi
    case "$mut" in
        badjson) grep -q '^  "agent_type": "bash"$' "$out" || { echo "harness: badjson not applied" >&2; exit 1; } ;;
        nameerror) grep -q 'name_that_does_not_exist' "$out" || { echo "harness: nameerror not applied" >&2; exit 1; } ;;
    esac
    sha_of "$out"
}

act_json() { # ACTION SERVICE [EXTRA_JSON_MEMBERS]
    printf '{"action":{"action":"%s","service_name":"%s","key":"%s","action_id":41%s}}' "$1" "$2" "$KEY" "${3:-}"
}

for kind in sh py; do
    f=$(file_of "$kind")
    cur=$(version_of "$kind" "$SRC/$f")
    orig_sha=$(sha_of "$SRC/$f")
    echo "orig_sha=$orig_sha" > "$OUT/$kind-orig.facts"
    echo "version=$cur" >> "$OUT/$kind-orig.facts"

    # --- Remote actions -------------------------------------------------
    # A timestamp that is not a number never reaches arithmetic or HMAC. For
    # bash the forged value is command substitution inside $(( )) - with no
    # space in it, since the parser strips whitespace (the audit's own probe).
    d=$(new_case "$kind" act-ts)
    if [ "$kind" = sh ]; then
        scenario "$(act_json restart_service bkfake ',"raw_timestamp":"a[$(id>/tmp/pwned)]"')"
    else
        scenario "$(act_json restart_service bkfake ',"timestamp":"12a"')"
    fi
    run_agent "$kind" "$d" "$kind-act-ts"
    facts "$kind" "$d" "$kind-act-ts"

    # A leading zero: digits, but an octal error in bash arithmetic, which
    # used to end the whole run. Now: read as decimal, far outside the window.
    if [ "$kind" = sh ]; then
        d=$(new_case "$kind" act-octal)
        scenario "$(act_json restart_service bkfake ',"raw_timestamp":"08"')"
        run_agent "$kind" "$d" "$kind-act-octal"
        facts "$kind" "$d" "$kind-act-octal"
    fi

    d=$(new_case "$kind" act-traversal)
    scenario "$(act_json restart_service ../../tmp/pwn)"
    run_agent "$kind" "$d" "$kind-act-traversal"
    facts "$kind" "$d" "$kind-act-traversal"

    d=$(new_case "$kind" act-dash)
    scenario "$(act_json restart_service -H)"
    run_agent "$kind" "$d" "$kind-act-dash"
    facts "$kind" "$d" "$kind-act-dash"

    # A valid name, but a systemd unit of another type: restart_service must
    # not become a system-wide action (poweroff.target, emergency.target).
    d=$(new_case "$kind" act-unit)
    scenario "$(act_json restart_service bkfake.target)"
    run_agent "$kind" "$d" "$kind-act-unit"
    facts "$kind" "$d" "$kind-act-unit"

    d=$(new_case "$kind" act-ok)
    scenario "$(act_json restart_service bkfake)"
    run_agent "$kind" "$d" "$kind-act-ok"
    facts "$kind" "$d" "$kind-act-ok"

    # The same signed answer twice (a proxy cache, a captured response):
    # executed once.
    d=$(new_case "$kind" act-replay)
    now=$(date +%s)
    scenario "$(act_json restart_service bkfake ",\"timestamp\":$now,\"nonce\":\"feedface0123\"")"
    run_agent "$kind" "$d" "$kind-act-replay-1"
    run_agent "$kind" "$d" "$kind-act-replay"
    facts "$kind" "$d" "$kind-act-replay"

    # A nonce that cannot be remembered could be replayed: refused.
    d=$(new_case "$kind" act-nonce-ro)
    if [ "$kind" = sh ]; then mkdir "$d/agent.sh.nonces.tmp"; else mkdir "$d/vps_agent_action_nonces"; fi
    scenario "$(act_json restart_service bkfake)"
    run_agent "$kind" "$d" "$kind-act-nonce-ro"
    facts "$kind" "$d" "$kind-act-nonce-ro"

    # A bad signature is refused before the gate: no nonce is burnt.
    d=$(new_case "$kind" act-badsig)
    scenario "$(act_json restart_service bkfake ',"signature":"00ff"')"
    run_agent "$kind" "$d" "$kind-act-badsig"
    facts "$kind" "$d" "$kind-act-badsig"

    d=$(new_case "$kind" act-notallowed)
    scenario "$(act_json restart_wan bkfake)"
    run_agent "$kind" "$d" "$kind-act-notallowed"
    facts "$kind" "$d" "$kind-act-notallowed"

    # --- The --selfcheck gate -------------------------------------------
    scenario '{}'
    d=$(new_case "$kind" sc-noenv)
    if [ "$kind" = sh ]; then bash "$d/$f" --selfcheck > "$OUT/$kind-sc-noenv.stdout" 2> "$OUT/$kind-sc-noenv.stderr"; else python3 "$d/$f" --selfcheck > "$OUT/$kind-sc-noenv.stdout" 2> "$OUT/$kind-sc-noenv.stderr"; fi
    echo $? > "$OUT/$kind-sc-noenv.rc"
    facts "$kind" "$d" "$kind-sc-noenv"

    d=$(new_case "$kind" sc-env)
    if [ "$kind" = sh ]; then
        BK_UPDATE_SELFCHECK=1 bash "$d/$f" --selfcheck > "$OUT/$kind-sc-env.stdout" 2> "$OUT/$kind-sc-env.stderr"
    else
        BK_UPDATE_SELFCHECK=1 python3 "$d/$f" --selfcheck > "$OUT/$kind-sc-env.stdout" 2> "$OUT/$kind-sc-env.stderr"
    fi
    echo $? > "$OUT/$kind-sc-env.rc"
    facts "$kind" "$d" "$kind-sc-env"

    # --- Self-update ------------------------------------------------------
    good_sha=$(variant "$kind" 9.9.9 "$kind-good")
    echo "good_sha=$good_sha" >> "$OUT/$kind-orig.facts"
    d=$(new_case "$kind" upd-good)
    # The new file takes the old one's mode, whatever it is.
    chmod 0750 "$d/$f"
    scenario "{\"update\":{\"agent_type\":\"$( [ "$kind" = sh ] && echo bash || echo python )\",\"version\":\"9.9.9\",\"file\":\"$kind-good\"}}"
    run_agent "$kind" "$d" "$kind-upd-good-1"
    facts "$kind" "$d" "$kind-upd-good-1"
    # The new version's first run: its report is accepted, the probation ends.
    run_agent "$kind" "$d" "$kind-upd-good-2"
    facts "$kind" "$d" "$kind-upd-good-2"

    atype=$( [ "$kind" = sh ] && echo bash || echo python )
    for c in sha nosentinel truncated badselfcheck older same; do
        d=$(new_case "$kind" "upd-$c")
        case "$c" in
            sha)
                scenario "{\"update\":{\"agent_type\":\"$atype\",\"version\":\"9.9.9\",\"file\":\"$kind-good\",\"sha\":\"$(printf '0%.0s' $(seq 1 64))\"}}" ;;
            nosentinel|truncated)
                variant "$kind" 9.9.9 "$kind-$c" "$c" > /dev/null
                scenario "{\"update\":{\"agent_type\":\"$atype\",\"version\":\"9.9.9\",\"file\":\"$kind-$c\"}}" ;;
            badselfcheck)
                variant "$kind" 9.9.9 "$kind-$c" "$( [ "$kind" = sh ] && echo badjson || echo nameerror )" > /dev/null
                scenario "{\"update\":{\"agent_type\":\"$atype\",\"version\":\"9.9.9\",\"file\":\"$kind-$c\"}}" ;;
            older)
                variant "$kind" 0.0.1 "$kind-$c" > /dev/null
                scenario "{\"update\":{\"agent_type\":\"$atype\",\"version\":\"0.0.1\",\"file\":\"$kind-$c\"}}" ;;
            same)
                variant "$kind" "$cur" "$kind-$c" > /dev/null
                scenario "{\"update\":{\"agent_type\":\"$atype\",\"version\":\"$cur\",\"file\":\"$kind-$c\",\"force\":true}}" ;;
        esac
        run_agent "$kind" "$d" "$kind-upd-$c"
        # A file refused for what its bytes are is not fetched again for a
        # day: the second run must not download (or log) it once more.
        [ "$c" = nosentinel ] && run_agent "$kind" "$d" "$kind-upd-$c-again"
        facts "$kind" "$d" "$kind-upd-$c"
    done

    # A host without python3 must still take a good update: the bash
    # updater then checks the self-check line without a JSON parser. The
    # fake server is already running, so hiding the name costs nothing.
    if [ "$kind" = sh ]; then
        py=$(command -v python3)
        mv "$py" "$py.hidden"
        d=$(new_case sh upd-nopython)
        scenario "{\"update\":{\"agent_type\":\"bash\",\"version\":\"9.9.9\",\"file\":\"sh-good\"}}"
        run_agent sh "$d" sh-upd-nopython
        mv "$py.hidden" "$py"
        facts sh "$d" sh-upd-nopython
    fi

    # The self-check takes the heavy checks from the running agent's cache
    # (fresh: that agent refreshed it before its report). With an empty one
    # it ran SMART on every disk, and three hung disks (3 x 20 s) used up its
    # 60 s: the host refused every release. Here the cache is warm and the
    # disks hang - the update must go through, well inside the minute.
    if [ "$kind" = sh ]; then
        d=$(new_case sh upd-warmcache)
        printf 'smart\tOK (cache)\nusb\t0\ndiscovered\t\n' > "$d/agent-heavy.cache"
        rm -f /tmp/slowdisk.log
        scenario "{\"update\":{\"agent_type\":\"bash\",\"version\":\"9.9.9\",\"file\":\"sh-good\"}}"
        t0=$(date +%s)
        run_agent sh "$d" sh-upd-warmcache PATH="/tmp/slowdisk:$PATH"
        echo "secs=$(( $(date +%s) - t0 ))" > "$OUT/sh-upd-warmcache.time"
        echo "smartctl_calls=$(cat /tmp/slowdisk.log 2>/dev/null | wc -l)" >> "$OUT/sh-upd-warmcache.time"
        facts sh "$d" sh-upd-warmcache
    fi

    # Not enough room beside the agent for the new file and a copied .prev:
    # refused before anything is written (a tmpfs of a few hundred kB).
    tiny="/tiny-$kind/case"
    rm -rf "$tiny"; mkdir -p "$tiny"
    cp "$SRC/$f" "$tiny/"
    printf 'API_URL="http://127.0.0.1:%s/agent_api.php"\nAGENT_KEY="%s"\nAUTO_UPDATE="1"\n' "$PORT" "$KEY" > "$tiny/agent.cfg"
    : > "$API/gets.log"; : > "$API/posts.jsonl"
    # Fill the tmpfs up to about 1.5x the agent's size of free space.
    need=$(( $(wc -c < "$SRC/$f") * 3 / 2 / 1024 ))
    free=$(df -Pk "$tiny" | awk 'NR == 2 {print $4}')
    [ "$free" -gt "$need" ] && dd if=/dev/zero of="/tiny-$kind/filler" bs=1k count=$(( free - need )) 2>/dev/null
    scenario "{\"update\":{\"agent_type\":\"$atype\",\"version\":\"9.9.9\",\"file\":\"$kind-good\"}}"
    run_agent "$kind" "$tiny" "$kind-upd-space"
    facts "$kind" "$tiny" "$kind-upd-space"
    rm -f "/tiny-$kind/filler"

    # --- Rollback ---------------------------------------------------------
    # A version that passes every check here but that the server refuses:
    # installed, refused three times, then taken back; the restored version
    # reports at once and does not reinstall the same file.
    bad_sha=$(variant "$kind" 9.9.8 "$kind-refused")
    echo "refused_sha=$bad_sha" >> "$OUT/$kind-orig.facts"
    d=$(new_case "$kind" rb-rejected)
    scenario "{\"fail_versions\":{\"9.9.8\":400},\"update\":{\"agent_type\":\"$atype\",\"version\":\"9.9.8\",\"file\":\"$kind-refused\"}}"
    for i in 1 2 3 4 5 6; do
        run_agent "$kind" "$d" "$kind-rb-rejected-$i"
        facts "$kind" "$d" "$kind-rb-rejected-$i"
    done

    # Thirty runs without one accepted report (an agent whose transport
    # broke): taken back as well. The probation is seeded at the limit.
    runs_sha=$(variant "$kind" 9.9.7 "$kind-silent")
    echo "silent_sha=$runs_sha" >> "$OUT/$kind-orig.facts"
    d=$(new_case "$kind" rb-runs)
    cp "$d/$f" "$d/$f.prev"
    cp "$API/files/$kind-silent" "$d/$f"
    printf '9.9.7 %s %s 30 0\n' "$cur" "$runs_sha" > "$d/$f.probation"
    scenario '{}'
    run_agent "$kind" "$d" "$kind-rb-runs"
    facts "$kind" "$d" "$kind-rb-runs"

    # A probation file naming another version (a swap that never happened)
    # is dropped, not counted.
    d=$(new_case "$kind" rb-stale)
    printf '9.9.6 %s %s 29 2\n' "$cur" "$runs_sha" > "$d/$f.probation"
    scenario '{}'
    run_agent "$kind" "$d" "$kind-rb-stale"
    facts "$kind" "$d" "$kind-rb-stale"
done

# --- The shared rules, straight from agent.sh --------------------------------
# The functions are lifted out of the shipped file (not a copy), so the table
# checks the code that runs.
{
    eval "$(sed -n '/^bk_valid_service_name() {/,/^}/p' "$SRC/agent.sh")"
    eval "$(sed -n '/^bk_version_newer() {/,/^}/p' "$SRC/agent.sh")"
    for n in nginx nginx.service openvpn@server 'MSSQL$SQLEXPRESS' _x a-b.c 9 \
             "$(printf 'a%.0s' $(seq 1 128))"; do
        if bk_valid_service_name "$n"; then echo "svc ok $n"; else echo "svc refused $n"; fi
    done
    for n in '' ../x .hidden -H 'a b' a/b 'a\b' 'a:b' 'a;id' '$(id)' "$(printf 'a%.0s' $(seq 1 129))"; do
        if bk_valid_service_name "$n"; then echo "svc ok $n"; else echo "svc refused $n"; fi
    done
    for pair in "0.1.4 0.1.3" "0.1.10 0.1.9" "1.0 0.9.9" "0.2 0.1.99" "1.0.1 1.0"; do
        set -- $pair
        if bk_version_newer "$1" "$2"; then echo "ver newer $1 $2"; else echo "ver notnewer $1 $2"; fi
    done
    for pair in "0.1.3 0.1.3" "0.1.2 0.1.3" "1.0 1.0.0" "0.1.4-rc1 0.1.3" "0.1..4 0.1.3" ".1 0.0" "abc 0.1"; do
        set -- $pair
        if bk_version_newer "$1" "$2"; then echo "ver newer $1 $2"; else echo "ver notnewer $1 $2"; fi
    done
} > "$OUT/sh-rules.txt" 2>&1

kill "$api_pid" 2>/dev/null
exit 0
