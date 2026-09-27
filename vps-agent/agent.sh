#!/bin/bash
# Blood Kings Status Monitoring - VPS Agent (Bash/Shell Version)
#
# Tento skript spouštějte na vašem VPS (např. přes cron každých 5 minut).
# Nevyžaduje žádné knihovny ani Python 3 (pouze standardní sh/bash, awk, grep, df a curl).

# cron starts jobs with PATH=/usr/bin:/bin on Debian and most distributions,
# while smartctl, sysctl and friends live in the sbin directories: a metric
# the manual `--verbose` test measured came out null on every cron run after
# it. The system directories are appended when missing, not prepended, so a
# PATH the operator set on purpose (a systemd unit, a newer tool in /opt)
# keeps its order.
for _bk_dir in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    case ":$PATH:" in
        *":$_bk_dir:"*) ;;
        *) PATH="${PATH:+$PATH:}$_bk_dir" ;;
    esac
done
export PATH

# === VÝCHOZÍ KONFIGURACE ===
# Pokud chcete, můžete tyto hodnoty nechat zde, nebo vytvořit soubor 'agent.cfg' ve stejné složce
API_URL="http://localhost/status/agent_api.php"
AGENT_KEY="ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE"
_env_remote_actions="$REMOTE_ACTIONS_ENABLED"
_env_allowed_actions="$ALLOWED_ACTIONS"
AUTO_UPDATE="0" # Nastavte na "1" pro povolení automatických aktualizací agenta ze serveru
HEAVY_OP_INTERVAL_HOURS="24" # How often the expensive checks rerun (SMART, USB, service discovery)
REMOTE_ACTIONS_ENABLED="0"   # "1" enables HMAC-signed remote actions from the server
ALLOWED_ACTIONS="restart_service,reboot_server"
# ===========================

# Numeric output must not depend on the host locale: with a comma-decimal
# locale `sort -rn` scrambles the top-process lists. It also keeps tool output
# untranslated, which the parsers below rely on.
export LC_ALL=C
# The bare REMOTE_ACTIONS_ENABLED / ALLOWED_ACTIONS env names were the only
# ones read before this version; they were captured above the defaults so
# existing systemd units and Docker files keep working.
[ -n "$_env_remote_actions" ] && REMOTE_ACTIONS_ENABLED="$_env_remote_actions"
[ -n "$_env_allowed_actions" ] && ALLOWED_ACTIONS="$_env_allowed_actions"

# Načtení z Environment proměnných
if [ -n "$STATUS_API_URL" ]; then
    API_URL="$STATUS_API_URL"
fi
if [ -n "$STATUS_AGENT_KEY" ]; then
    AGENT_KEY="$STATUS_AGENT_KEY"
fi
if [ -n "$STATUS_AUTO_UPDATE" ]; then
    AUTO_UPDATE="$STATUS_AUTO_UPDATE"
fi
[ -n "$STATUS_HEAVY_OP_INTERVAL_HOURS" ] && HEAVY_OP_INTERVAL_HOURS="$STATUS_HEAVY_OP_INTERVAL_HOURS"
[ -n "$STATUS_REMOTE_ACTIONS_ENABLED" ] && REMOTE_ACTIONS_ENABLED="$STATUS_REMOTE_ACTIONS_ENABLED"
[ -n "$STATUS_ALLOWED_ACTIONS" ] && ALLOWED_ACTIONS="$STATUS_ALLOWED_ACTIONS"

# Načtení z externí konfigurace 'agent.cfg'
ScriptPath=$(dirname "$(readlink -f "$0")" 2>/dev/null || dirname "$0")
if [ -f "$ScriptPath/agent.cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | tr -d '\r' | xargs) # trim whitespace
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]] && [[ "$line" =~ = ]]; then
            key=$(echo "${line%%=*}" | xargs)
            val=$(echo "${line#*=}" | xargs | sed 's/^["'\''\(]*//;s/["'\''\)]*$//')
            if [ "$key" = "API_URL" ]; then
                API_URL="$val"
            elif [ "$key" = "AGENT_KEY" ]; then
                AGENT_KEY="$val"
            elif [ "$key" = "AUTO_UPDATE" ]; then
                AUTO_UPDATE="$val"
            # These three were env-only before, i.e. unreachable from cron's
            # empty environment even though the docs pointed at agent.cfg.
            elif [ "$key" = "HEAVY_OP_INTERVAL_HOURS" ]; then
                HEAVY_OP_INTERVAL_HOURS="$val"
            elif [ "$key" = "REMOTE_ACTIONS_ENABLED" ]; then
                REMOTE_ACTIONS_ENABLED="$val"
            elif [ "$key" = "ALLOWED_ACTIONS" ]; then
                ALLOWED_ACTIONS="$val"
            fi
        fi
    done < "$ScriptPath/agent.cfg"
fi

# Zpracování příkazu pro automatickou registraci: ./agent.sh --register REGISTRATION_TOKEN [API_URL]
if [ "$1" = "--register" ] || [ "$1" = "--auto-register" ]; then
    REG_TOKEN="$2"
    if [ -z "$REG_TOKEN" ]; then
        echo "Použití: $0 --register REGISTRATION_TOKEN [API_URL]"
        exit 1
    fi
    if [ -n "$3" ]; then
        API_URL="$3"
    fi
    HOSTNAME_VAL=$(hostname 2>/dev/null || echo "Linux-Server")
    echo "Registruji nového agenta na $API_URL..."
    RESP=$(curl -s -m 20 -X POST -H "Content-Type: application/json" -d "{\"action\":\"register\", \"token\":\"$REG_TOKEN\", \"hostname\":\"$HOSTNAME_VAL\", \"agent_type\":\"bash\"}" "$API_URL")
    NEW_KEY=$(echo "$RESP" | sed -n 's/.*"agent_key":"\([^"]*\)".*/\1/p')
    if [ -n "$NEW_KEY" ]; then
        echo "API_URL=\"$API_URL\"" > "$ScriptPath/agent.cfg"
        echo "AGENT_KEY=\"$NEW_KEY\"" >> "$ScriptPath/agent.cfg"
        echo "OK: Agent byl úspěšně zaregistrován a nastavení bylo uloženo do $ScriptPath/agent.cfg (AGENT_KEY=$NEW_KEY)"
        exit 0
    else
        echo "CHYBA při registraci: $RESP"
        exit 1
    fi
fi

AGENT_VERSION="0.1.3"
LOG_FILE="$ScriptPath/agent.log"
# One state file for every between-run delta (CPU, disk I/O, network, forks,
# TS3 CPU), written once per run next to the script. It used to be four files,
# one of them in /tmp where it outlived reboots and produced negative deltas.
# Plus one cache for the expensive checks (see HEAVY_OP_INTERVAL_HOURS).
STATE_FILE="$ScriptPath/agent.state"
HEAVY_CACHE_FILE="$ScriptPath/agent-heavy.cache"
BK_LOCK_FILE="$ScriptPath/.agent.lock"
# Self-update bookkeeping sits next to the script itself and is named after
# it, so agent.sh and agent.py installed in one directory never share a file.
#   .prev       the version this one replaced (a hardlink, a copy if not)
#   .probation  "<new> <old> <sha256> <runs> <rejected>" from the swap until
#               the new version's first accepted report
#   .last-ok    "<version> <unix time>" of the last accepted report
#   .refused    "<sha256> <unix time>" of a file this host took back or
#               refused for what its bytes are (no end sentinel, bad syntax,
#               failed self-check): not downloaded again for 24 h
#   .nonces     remote-action nonces already used
BK_SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
BK_PROBATION="$BK_SELF.probation"
BK_LAST_OK="$BK_SELF.last-ok"
BK_REFUSED="$BK_SELF.refused"
BK_NONCE_FILE="$BK_SELF.nonces"
# A new version that the server refused this many times, or that did not get
# a single report through in this many runs, is replaced by the previous one.
# Refusals (4xx) count fast; runs with no answer only after a long outage, so
# a network outage alone does not roll anything back after a few minutes.
BK_ROLLBACK_REJECTED=3
BK_ROLLBACK_RUNS=30
# The script's own arguments, for the restarted run after a rollback.
BK_ARGS=("$@")

VERBOSE="0"
DRY_RUN="0"
SELFCHECK="0"
[ -t 1 ] && VERBOSE="1"
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "Linux BASH Status Agent v$AGENT_VERSION"
            echo "Pouziti: $0 [MOZNOSTI]"
            echo ""
            echo "Moznosti:"
            echo "  --register TOKEN [API_URL]   Zaregistruje agenta na zadany monitoring server"
            echo "  --update, --auto-update      Vynuti kontrolu a aktualizaci agenta ze serveru"
            echo "  --dry-run, --print           Sesbira data a vypise JSON, neodesila (i bez klice)"
            echo "  --verbose, -v                Zobrazi podrobny prubeh sberu dat a odesilani"
            echo "  --version, -V                Zobrazi verzi agenta"
            echo "  --help, -h                   Zobrazi tuto napovedu"
            echo ""
            echo "Konfigurace:"
            echo "  Cte nastaveni ze souboru agent.cfg nebo z promendych prostredi:"
            echo "  STATUS_API_URL, STATUS_AGENT_KEY, STATUS_AUTO_UPDATE, STATUS_HEAVY_OP_INTERVAL_HOURS"
            exit 0
            ;;
        --version|-V)
            echo "Linux BASH Status Agent v$AGENT_VERSION"
            exit 0
            ;;
        --update|--auto-update)
            AUTO_UPDATE="1"
            VERBOSE="1"
            ;;
        --verbose|-v)
            VERBOSE="1"
            ;;
        --dry-run|--print)
            DRY_RUN="1"
            VERBOSE="1"
            ;;
        --selfcheck)
            SELFCHECK="1"
            ;;
    esac
done
# --selfcheck: the updater runs a freshly downloaded copy this way before it
# replaces the running agent. It is the whole collection of a dry run,
# printed as ONE line {"agent_type","agent_version","payload"}: a release
# that dies halfway, or builds a payload that is not JSON (a missing comma
# passes `bash -n` and then earns a 400 on every report, for ever), is
# refused before it is installed. Only the updater sets BK_UPDATE_SELFCHECK=1:
# a hand-typed --selfcheck must not quietly turn into some other run.
if [ "$SELFCHECK" = "1" ]; then
    if [ "$BK_UPDATE_SELFCHECK" != "1" ]; then
        echo "--selfcheck spousti jen aktualizace agenta (BK_UPDATE_SELFCHECK=1)." >&2
        exit 2
    fi
    # A scratch directory of its own: the running agent holds the real lock
    # at this moment, and its log, counters and heavy cache must not be
    # written by a version that may use another format.
    BK_SC_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bk-selfcheck.XXXXXX" 2>/dev/null) || { echo "selfcheck: mktemp -d failed" >&2; exit 3; }
    trap 'rm -rf "$BK_SC_DIR"' EXIT
    LOG_FILE="$BK_SC_DIR/agent.log"
    STATE_FILE="$BK_SC_DIR/agent.state"
    # A COPY of the heavy cache, mtime and all (the running agent refreshed
    # it just before its report): with an empty one the self-check would run
    # SMART on every disk, and a host whose disks answer slowly (20 s each
    # for a hung smartctl) ran out of the 60 s and refused every release for
    # good. The copy is what the new version reads on its first real run too.
    cp -p "$HEAVY_CACHE_FILE" "$BK_SC_DIR/agent-heavy.cache" 2>/dev/null || true
    HEAVY_CACHE_FILE="$BK_SC_DIR/agent-heavy.cache"
    BK_LOCK_FILE="$BK_SC_DIR/.agent.lock"
    DRY_RUN="1"
    VERBOSE="0"
    # Not needed to build a payload, and this output is not a report.
    AGENT_KEY=""
fi
# A dry run keeps its own state series: run by hand between two cron ticks it
# used to overwrite the counters, and the next cron report shipped forks and
# network errors for a fraction of the interval as if they covered all of it.
[ "$DRY_RUN" = "1" ] && STATE_FILE="$STATE_FILE.dryrun"

# Escapes one string for a JSON value: backslash, quote, and the control
# characters a process name may legally contain (a tab would break the whole
# report, and the server rejects invalid JSON with a 400).
json_str() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g; s/\t/ /g' | tr -d '\000-\010\013\014\016-\037' | tr '\n' ' '
}

log_message() {
    local msg="$1"
    local ts
    printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1 2>/dev/null || ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$VERBOSE" = "1" ]; then
        # In --dry-run stdout is the JSON payload; keep the chatter on stderr
        # so `agent.sh --dry-run | python3 -m json.tool` just works.
        if [ "$DRY_RUN" = "1" ]; then echo "$ts - $msg" >&2; else echo "$ts - $msg"; fi
    fi
    echo "$ts - $msg" >> "$LOG_FILE" 2>/dev/null || echo "$ts - $msg" >> /tmp/status-agent.log 2>/dev/null || true
}

# Debug lines used to reach the log file unconditionally - five per run, one
# carrying the whole port list - so agent.log grew about 250 MB a year with
# no rotation. They are written only with --verbose now.
log_debug() {
    [ "$VERBOSE" = "1" ] && log_message "$1"
    return 0
}

# And the log stays bounded: above 1 MB keep the last 500 lines.
bk_trim_log() {
    local size
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null)
    if [ -n "$size" ] && [ "$size" -gt 1048576 ] 2>/dev/null; then
        tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
    fi
}
bk_trim_log

if [ "$AGENT_KEY" = "ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE" ] && [ "$DRY_RUN" != "1" ]; then
    log_message "CHYBA: Nebyl nastaven AGENT_KEY. Upravte skript nebo 'agent.cfg'."
    exit 1
fi

log_debug "Získávám systémové statistiky (BASH)..."

# One run at a time: a stalled report (server down, hung disk) must not let
# cron stack a new agent on top of it every minute.
if command -v flock >/dev/null 2>&1; then
    # The brace group puts the stderr redirect in place BEFORE exec tries to
    # open the lock file - on the exec line itself it came too late, so an
    # unwritable directory printed the error every minute.
    if { exec 9>"$BK_LOCK_FILE"; } 2>/dev/null; then
        flock -n 9 || { log_message "Predchozi beh jeste bezi, tento koncim."; exit 0; }
    fi
fi

# printf's %()T needs bash 4.2; older bash falls back to date (measured, not fabricated).
bk_now() { printf '%(%s)T' -1 2>/dev/null || date +%s; }
now_ts=$(bk_now)

# Remembers a file (by its sha256) this host will not install for a day.
bk_refuse_sha() {
    printf '%s %s\n' "$1" "$(bk_now)" > "$BK_REFUSED.tmp" 2>/dev/null \
        && mv -f "$BK_REFUSED.tmp" "$BK_REFUSED" 2>/dev/null
}

# --- Probation of a freshly installed version ------------------------------
# The updater checks a download as well as it can before the swap, but some
# failures only show against the real server: a payload it rejects, a
# transport that no longer connects. Until the first accepted report the
# updater's .probation file counts this version's runs and refusals; past the
# limits the previous version (.prev) comes back and runs at once, and the
# refused file is remembered for a day so the same offer does not reinstall
# it straight away. This runs before any collection, so a version that fails
# later in the run still reaches it. A dry run is not a report run.
bk_probation_save() { # RUNS REJECTED
    printf '%s %s %s %s %s\n' "$pb_new" "$pb_old" "$pb_sha" "$1" "$2" > "$BK_PROBATION.tmp" 2>/dev/null \
        && mv -f "$BK_PROBATION.tmp" "$BK_PROBATION" 2>/dev/null
}
bk_probation_check() {
    [ -f "$BK_PROBATION" ] || return 0
    pb_new=""; pb_old=""; pb_sha=""; pb_runs=""; pb_rej=""
    read -r pb_new pb_old pb_sha pb_runs pb_rej < "$BK_PROBATION" 2>/dev/null
    # Left behind by a swap that never happened, or by an older update: this
    # version is not on probation.
    if [ "$pb_new" != "$AGENT_VERSION" ]; then
        rm -f "$BK_PROBATION" 2>/dev/null
        return 0
    fi
    # A count that is not a small number is a damaged file: start over.
    case "$pb_runs" in ''|*[!0-9]*|??????????*) pb_runs=0 ;; esac
    case "$pb_rej" in ''|*[!0-9]*|??????????*) pb_rej=0 ;; esac
    if [ "$pb_rej" -lt "$BK_ROLLBACK_REJECTED" ] && [ "$pb_runs" -lt "$BK_ROLLBACK_RUNS" ]; then
        pb_runs=$((pb_runs + 1))
        bk_probation_save "$pb_runs" "$pb_rej"
        return 0
    fi
    rm -f "$BK_PROBATION" 2>/dev/null
    if [ ! -f "$BK_SELF.prev" ] || ! bash -n "$BK_SELF.prev" 2>/dev/null; then
        log_message "CHYBA UPDATE: Verze $AGENT_VERSION nedoručila žádný report ($pb_runs běhů, $pb_rej odmítnutí serverem), ale předchozí verze ($BK_SELF.prev) chybí nebo je poškozená - zůstávám."
        return 0
    fi
    if ! mv -f "$BK_SELF.prev" "$BK_SELF" 2>/dev/null; then
        log_message "CHYBA UPDATE: Vrácení předchozí verze $pb_old se nezdařilo (práva k $BK_SELF?)."
        return 0
    fi
    bk_refuse_sha "$pb_sha"
    log_message "VAROVÁNÍ: Verze $AGENT_VERSION nedoručila žádný report ($pb_runs běhů, $pb_rej odmítnutí serverem), vrácena předchozí verze $pb_old."
    # The restored script takes over this run. exec keeps fd 9, and its own
    # `exec 9>` reopens the lock file, which drops and retakes the lock.
    exec bash "$BK_SELF" "${BK_ARGS[@]}"
}
pb_new=""
[ "$DRY_RUN" = "1" ] || bk_probation_check

# Previous-run state, read as plain key=value lines - never eval'ed.
st_boot_id=""; st_cpu=""; st_diskio=""; st_net=""; st_forks=""; st_ts3=""
if [ -f "$STATE_FILE" ]; then
    while IFS='=' read -r st_k st_v; do
        case "$st_k" in
            boot_id) st_boot_id="$st_v" ;;
            cpu) st_cpu="$st_v" ;;
            diskio) st_diskio="$st_v" ;;
            net) st_net="$st_v" ;;
            forks) st_forks="$st_v" ;;
            ts3) st_ts3="$st_v" ;;
        esac
    done < "$STATE_FILE"
fi
# Kernel counters restart at zero after a reboot; a delta against the previous
# boot came out negative - or, for CPU, as a fabricated 0.0. The saved state is
# trusted only within the same boot.
cur_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
if [ -n "$st_boot_id" ] && [ "$st_boot_id" != "$cur_boot_id" ]; then
    st_cpu=""; st_diskio=""; st_net=""; st_forks=""; st_ts3=""
fi

# 1. CPU usage from the /proc/stat delta against the previous run.
stat_now=$(grep '^cpu ' /proc/stat 2>/dev/null)
# Not measured = null, not zero: the first run, the run after a reboot and an
# unreadable /proc/stat alike.
cpu="null"; cpu_steal="null"; iowait="null"
prev_stat="${st_cpu#*|}"
if [ -n "$st_cpu" ] && [ -n "$prev_stat" ] && [ -n "$stat_now" ]; then
    cpu_steal_out=$(awk -v s1="$prev_stat" -v s2="$stat_now" '
    BEGIN {
        split(s1, a1); split(s2, a2);
        iowait1 = a1[6] + 0; idle1 = a1[5] + a1[6];
        total1 = a1[2]+a1[3]+a1[4]+a1[5]+a1[6]+a1[7]+a1[8];
        steal1 = a1[9] + 0;
        iowait2 = a2[6] + 0; idle2 = a2[5] + a2[6];
        total2 = a2[2]+a2[3]+a2[4]+a2[5]+a2[6]+a2[7]+a2[8];
        steal2 = a2[9] + 0;
        idle_delta = idle2 - idle1; total_delta = total2 - total1;
        steal_delta = steal2 - steal1; iowait_delta = iowait2 - iowait1;
        # No output when the counters did not advance or went backwards -
        # the caller keeps null instead of a 0.0 nobody measured.
        if (total_delta > 0) {
            printf "%.1f %.1f %.1f", (1.0 - idle_delta / total_delta) * 100, (steal_delta / total_delta) * 100, (iowait_delta / total_delta) * 100;
        }
    }')
    [ -n "$cpu_steal_out" ] && read -r cpu cpu_steal iowait <<< "$cpu_steal_out"
fi
new_st_cpu=""
[ -n "$stat_now" ] && new_st_cpu="${now_ts}|${stat_now}"

# 2. RAM Usage (%) & MB breakdown
eval "$(awk '
/^MemTotal:/ { total=int($2/1024) }
/^MemFree:/ { free=int($2/1024) }
/^Buffers:/ { buffers=int($2/1024) }
/^Cached:/ { cached=int($2/1024) }
/^MemAvailable:/ { avail=int($2/1024) }
END {
    if (!avail) { avail = free + buffers + cached; }
    used = total - avail;
    if (used < 0) used = 0;
    pct = (total == 0) ? "0.0" : sprintf("%.1f", (used / total) * 100);
    print "ram=" pct "; ram_total_mb=" total "; ram_used_mb=" used "; ram_available_mb=" avail "; ram_free_mb=" free;
}' /proc/meminfo 2>/dev/null)"
[ -z "$ram" ] && ram="null"
# Kdyz se /proc/meminfo neprecte, NENI to stroj s 0 MB pameti - hodnoty
# zustavaji null a server i UI to zobrazi jako "nezmereno".
[ -z "$ram_total_mb" ] && ram_total_mb="null"
[ -z "$ram_used_mb" ] && ram_used_mb="null"
[ -z "$ram_available_mb" ] && ram_available_mb="null"
[ -z "$ram_free_mb" ] && ram_free_mb="null"

# 2.5 Swap Usage (%)
swap=$(awk '
/^SwapTotal:/ { total=$2 }
/^SwapFree:/ { free=$2 }
END {
    # No swap configured is "not applicable" - null, like the other agents -
    # not 0.0 % of nothing.
    if (total > 0) {
        printf "%.1f", ((total - free) / total) * 100;
    }
}' /proc/meminfo)
[ -z "$swap" ] && swap="null"

# 2.6 Load average (1/5/15 min)
load_out="null null null"
if [ -f /proc/loadavg ]; then
    load_out=$(awk '{print $1" "$2" "$3}' /proc/loadavg)
fi
load1=$(echo "$load_out" | awk '{print $1}')
load5=$(echo "$load_out" | awk '{print $2}')
load15=$(echo "$load_out" | awk '{print $3}')

# 3. HDD Usage (%)
hdd=$(df -P / | tail -n 1 | awk '{print $5}' | tr -d '%')
if [ -z "$hdd" ]; then
    # df selhal - nevime, ne "prazdny disk".
    hdd="null"
fi

# 3.02 All mounted filesystems
#
# `hdd` above is a single number for `/`. On a VPS with a separate /var, /srv
# or an attached volume that number says nothing about the disk that is
# actually filling up - the OpenWrt agent has reported per-mount usage for a
# while, the VPS agent did not, so the storage card showed top writers but no
# sizes at all. Same output shape as agent_openwrt.sh on purpose.
filesystems_json="[]"
if command -v df >/dev/null 2>&1; then
    df_out=$(df -PT 2>/dev/null) || df_out=""
    df_has_type=1
    if [ -z "$df_out" ]; then
        df_out=$(df -P 2>/dev/null)
        df_has_type=0
    fi
    if [ -n "$df_out" ]; then
        filesystems_json=$(echo "$df_out" | awk -v has_type="$df_has_type" '
            NR == 1 { next }
            {
                # Right-anchored on the Capacity column ("42%"): a device or a
                # mount point with a space in it (/media/My Disk, a LABEL= device)
                # shifted every number by one under the old fixed columns.
                p = 0; for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+%$/) { p = i; break }
                if (p == 0) next;
                pct = $p; avail = $(p - 1); used = $(p - 2); total = $(p - 3);
                if (has_type) { type = $(p - 4); dl = p - 5 } else { type = ""; dl = p - 4 }
                dev = $1; for (i = 2; i <= dl; i++) dev = dev " " $i;
                mnt = $(p + 1); for (i = p + 2; i <= NF; i++) mnt = mnt " " $i;
                if (mnt == "") next;
                # Virtual filesystems are not storage - reporting tmpfs as a
                # "disk" would make a machine look full when RAM fills a cache.
                if (type ~ /^(tmpfs|devtmpfs|proc|sysfs|debugfs|cgroup|cgroup2|overlay|overlayfs|squashfs|ramfs|mqueue|tracefs|securityfs|pstore|bpf|configfs|fusectl|nsfs|autofs|binfmt_misc|efivarfs)$/) next;
                if (has_type == 0 && dev ~ /^(tmpfs|devtmpfs|none|proc|sysfs|overlay|udev)$/) next;
                # Docker/snap bind mounts repeat the same device many times.
                if (mnt ~ /^\/(proc|sys|dev)(\/|$)/) next;
                if (mnt ~ /^\/var\/lib\/docker\//) next;
                if (mnt ~ /^\/snap\//) next;
                gsub("%", "", pct);
                if (pct !~ /^[0-9]+$/) next;
                # Escaped before they become JSON strings.
                gsub(/[^[:print:]]/, " ", mnt); gsub(/\\/, "\\\\", mnt); gsub(/"/, "\\\"", mnt);
                gsub(/[^[:print:]]/, " ", dev); gsub(/\\/, "\\\\", dev); gsub(/"/, "\\\"", dev);
                gsub(/[^[:print:]"\\]/, " ", type);
                printf "%s{\"mount\":\"%s\",\"device\":\"%s\",\"fstype\":\"%s\",\"total_kb\":%s,\"used_kb\":%s,\"avail_kb\":%s,\"used_pct\":%s}",
                       (n++ ? "," : "["), mnt, dev, type, total+0, used+0, avail+0, pct+0;
            }
            END { printf "%s", (n ? "]" : "[]") }')
    fi
fi
[ -z "$filesystems_json" ] && filesystems_json="[]"

# 3.05 Inode Usage (%) - stejný df, jen s -i (inode počty místo bloků)
inode_usage=$(df -iP / 2>/dev/null | tail -n 1 | awk '{print $5}' | tr -d '%')
inode_usage_json="null"
# df prints a literal "-" in the IUse% column for a filesystem that reports no
# inode total - btrfs always, some tmpfs mounts too. That is not a number, and
# writing it into the payload made the JSON invalid, so the server rejected
# the ENTIRE report (CPU, RAM, disk, everything) on every run of every btrfs
# host. Unmeasurable inode usage is null, like everywhere else.
case "$inode_usage" in
    ''|*[!0-9]*) : ;;
    *) inode_usage_json="$inode_usage" ;;
esac

# 3.1 Disk I/O (KB/s read/write) - the same tick/tock principle as network
# throughput. /proc/diskstats is a whole-kernel counter (not per pid
# namespace), so it works in Docker with pid: host too.
disk_sectors=$(awk '
$3 ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+)$/ {
    matched++; read_total += $6; write_total += $10;
}
END { if (matched) printf "%.0f,%.0f", read_total, write_total }
' /proc/diskstats 2>/dev/null)
# No matching device (mmcblk / dm-only hosts, containers without diskstats):
# nothing was measured, so no rate - not a 0.0 KB/s.
disk_io_read_json="null"
disk_io_write_json="null"
new_st_diskio=""
if [ -n "$disk_sectors" ]; then
    disk_read_sectors=${disk_sectors%,*}
    disk_write_sectors=${disk_sectors#*,}
    if [ -n "$st_diskio" ]; then
        IFS=',' read -r prev_io_ts prev_read prev_write <<< "$st_diskio"
        if [ -n "$prev_io_ts" ] && [ -n "$prev_read" ] && [ -n "$prev_write" ]; then
            elapsed_io=$((now_ts - prev_io_ts))
            delta_read=$((disk_read_sectors - prev_read))
            delta_write=$((disk_write_sectors - prev_write))
            if [ "$elapsed_io" -gt 0 ] && [ "$delta_read" -ge 0 ] && [ "$delta_write" -ge 0 ]; then
                disk_io_read_json=$(awk -v d="$delta_read" -v e="$elapsed_io" 'BEGIN { printf "%.1f", (d * 512 / e) / 1024 }')
                disk_io_write_json=$(awk -v d="$delta_write" -v e="$elapsed_io" 'BEGIN { printf "%.1f", (d * 512 / e) / 1024 }')
            fi
        fi
    fi
    new_st_diskio="$now_ts,$disk_read_sectors,$disk_write_sectors"
fi

# 3.5 Propustnost sítě (KB/s, RX+TX) a síťové chyby/zahozené pakety - potřebuje 2 vzorky,
# proto se mezi běhy ukládá kumulativní počet bajtů/chyb a čas; první běh vrací null.
net_stats=$(awk '
NR > 2 {
    line = $0;
    colon = index(line, ":");
    if (colon == 0) next;
    iface = substr(line, 1, colon - 1);
    gsub(/^[ \t]+|[ \t]+$/, "", iface);
    if (iface == "lo" || iface ~ /^veth/ || iface ~ /^docker/ || iface ~ /^br-/) next;
    n = split(substr(line, colon + 1), f, " ");
    total += (f[1] + 0) + (f[9] + 0);
    errs += (f[3] + 0) + (f[4] + 0) + (f[11] + 0) + (f[12] + 0);
}
END { printf "%.0f,%.0f", total, errs }
' /proc/net/dev 2>/dev/null)
# An unreadable /proc/net/dev is "unknown", not a silent 0 B/s.
net_json="null"
net_errors_json="null"
new_st_net=""
if [ -n "$net_stats" ]; then
    net_bytes=${net_stats%,*}
    net_errs_total=${net_stats#*,}
    if [ -n "$st_net" ] && [ "$net_bytes" -gt 0 ] 2>/dev/null; then
        IFS=',' read -r prev_ts prev_bytes prev_errs <<< "$st_net"
        if [ -n "$prev_ts" ] && [ -n "$prev_bytes" ]; then
            elapsed=$((now_ts - prev_ts))
            delta=$((net_bytes - prev_bytes))
            if [ "$elapsed" -gt 0 ] && [ "$delta" -ge 0 ]; then
                net_json=$(awk -v d="$delta" -v e="$elapsed" 'BEGIN { printf "%.1f", (d / e) / 1024 }')
            fi
            if [ -n "$prev_errs" ]; then
                delta_errs=$((net_errs_total - prev_errs))
                [ "$delta_errs" -ge 0 ] && net_errors_json="$delta_errs"
            fi
        fi
    fi
    new_st_net="$now_ts,$net_bytes,$net_errs_total"
fi

# 3.6 Fork rate - nové procesy od posledního běhu (delta, ne rychlost za sekundu).
# /proc/stat řádek "processes" je kumulativní čítač forků od bootu.
total_forks=$(awk '/^processes / { print $2 }' /proc/stat 2>/dev/null)
fork_rate_json="null"
new_st_forks=""
if [ -n "$total_forks" ]; then
    if [ -n "$st_forks" ]; then
        delta_forks=$((total_forks - st_forks))
        [ "$delta_forks" -ge 0 ] && fork_rate_json="$delta_forks"
    fi
    new_st_forks="$total_forks"
fi

# 3.65 TCP Retransmissions & Conntrack Count
tcp_retrans_json="null"
if [ -f /proc/net/snmp ]; then
    # Druhý řádek "Tcp:" nese hodnoty, první je hlavička. Dřív se tu čekalo,
    # že bude čtvrtý v souboru (NR==4) - jenže před ním jsou ještě Ip: a Icmp:,
    # takže se podmínka nikdy netrefila a retransmise se nezměřily na žádném
    # systému. Ověřeno proti /proc/net/snmp: hodnoty jsou na 6. řádku.
    tcp_retrans=$(awk '/^Tcp:/ {n++; if (n == 2) print $13}' /proc/net/snmp 2>/dev/null)
    [ -n "$tcp_retrans" ] && tcp_retrans_json="$tcp_retrans"
fi

conntrack_count_json="null"
if [ -f /proc/sys/net/netfilter/nf_conntrack_count ]; then
    cnt=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
    [ -n "$cnt" ] && conntrack_count_json="$cnt"
fi

# 3.7 Teplota (°C) - nejvyšší mezi dostupnými thermal zónami. Na většině VPS null,
# tepelné senzory hostitele se přes virtualizaci obvykle nevystavují.
temperature_json="null"
if [ -d /sys/class/thermal ]; then
    max_temp_millideg=$(for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] && cat "$z" 2>/dev/null
    done | awk '$1 > 0 && $1 < 150000 { if ($1 > max) max = $1 } END { if (max) print max }')
    if [ -n "$max_temp_millideg" ]; then
        temperature_json=$(awk -v m="$max_temp_millideg" 'BEGIN { printf "%.1f", m / 1000 }')
    fi
fi

# 3.8 System identity - computed every run. It is four cheap reads, and the
# old cache in /tmp was eval'ed as root: a local user who created that file
# first got a shell as the cron user.
sys_hostname=$(hostname 2>/dev/null || echo "")
sys_kernel=$(uname -r 2>/dev/null || echo "")
sys_timezone=""
if [ -f /etc/timezone ]; then
    sys_timezone=$(cat /etc/timezone 2>/dev/null)
elif [ -L /etc/localtime ]; then
    sys_timezone=$(readlink /etc/localtime 2>/dev/null | sed 's#.*zoneinfo/##')
fi
virtualization_json="null"
if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt=$(systemd-detect-virt 2>/dev/null)
    [ -n "$virt" ] && [ "$virt" != "none" ] && virtualization_json="\"$(json_str "$virt")\""
fi
cloud_provider_json="null"
dmi_text=""
for dmi_file in /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/bios_vendor; do
    [ -r "$dmi_file" ] && dmi_text="$dmi_text $(tr '[:upper:]' '[:lower:]' < "$dmi_file" 2>/dev/null)"
done
case "$dmi_text" in
    *amazon*) cloud_provider_json="\"AWS\"" ;;
    *google*) cloud_provider_json="\"Google Cloud\"" ;;
    *microsoft*) cloud_provider_json="\"Azure\"" ;;
    *digitalocean*) cloud_provider_json="\"DigitalOcean\"" ;;
    *hetzner*) cloud_provider_json="\"Hetzner\"" ;;
    *vultr*) cloud_provider_json="\"Vultr\"" ;;
    *linode*) cloud_provider_json="\"Linode\"" ;;
    *scaleway*) cloud_provider_json="\"Scaleway\"" ;;
esac
# /var/run/reboot-required is a Debian/Ubuntu convention; anywhere else its
# absence proves nothing, so the answer is null rather than a fabricated false.
reboot_required_json="null"
if [ -f /etc/debian_version ]; then
    reboot_required_json="false"
    [ -f /var/run/reboot-required ] && reboot_required_json="true"
fi

# 3b. Procesy, ktere nejvic zapisuji
#
# /proc/<pid>/io existuje jen s CONFIG_TASK_IO_ACCOUNTING. Bezny server ho
# ma, mensi zarizeni (napr. Turris) ne - proto se posila i priznak, aby
# rozhrani mohlo rict "jadro to neumi" misto mlceni.
#
# Hodnota je kumulativni od startu procesu: odpovida na "kdo toho nejvic
# zapsal", ne "kdo zrovna pise".
top_io_json="[]"
io_accounting_json="false"
if [ -r /proc/1/io ]; then
    io_accounting_json="true"
    # One awk over every readable /proc/<pid>/io instead of two forks per
    # process - on a 300-process host that was ~600 forks a minute, the single
    # biggest cost of this script. Readability is checked with the builtin
    # test first so awk never trips over a file it cannot open.
    # The paths are fed to awk as DATA and read with getline, never passed as
    # input files. A process can exit between the readability test and awk's
    # open(), and both mawk and gawk treat an unopenable input file as fatal:
    # awk would exit right there, skip every remaining process and never run
    # END, so the ranking came out truncated or empty on any busy host. The
    # test above cannot close that window; getline returns -1 and moves on.
    top_io_json=$(
        for f in /proc/[0-9]*/io; do [ -r "$f" ] && printf '%s\n' "$f"; done | awk '
            {
                f = $0; pid = f; sub(/^\/proc\//, "", pid); sub(/\/io$/, "", pid);
                wb = "";
                while ((getline line < f) > 0) {
                    if (line ~ /^write_bytes:/) { split(line, a, " "); wb = a[2] }
                }
                close(f);
                if (wb == "" || wb + 0 <= 0) next;
                cf = "/proc/" pid "/comm"; name = "";
                if ((getline name < cf) > 0) close(cf);
                close(cf);
                if (name != "") print wb "|" pid "|" name;
            }' 2>/dev/null | sort -rn | head -5 | awk -F'|' '
            { n = $3; gsub(/[^[:print:]]/, " ", n); gsub(/\\/, "\\\\", n); gsub(/"/, "\\\"", n);
              printf "%s{\"pid\":%s,\"name\":\"%s\",\"write_bytes\":%s}", (c++ ? "," : "["), $2, n, $1 }
            END { printf "%s", (c ? "]" : "[]") }')
fi
[ -z "$top_io_json" ] && top_io_json="[]"

# 4. Uptime (sekundy)
# Bez /proc/uptime nevime, jak dlouho stroj bezi - nula by tvrdila, ze se
# prave nastartoval. Radek 848 na to uz je pripraveny: pocita boot_time jen
# kdyz je uptime cislo vetsi nez nula.
uptime="null"
if [ -f /proc/uptime ]; then
    uptime=$(cat /proc/uptime | awk '{print int($1)}')
    [ -z "$uptime" ] && uptime="null"
fi

# 5. SMART kontrola stavu disků
get_smart_status() {
    if command -v smartctl >/dev/null 2>&1; then
        drives=$(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk" {print $1}')
        if [ -z "$drives" ]; then
            for dev in /sys/class/block/*; do
                if [ -e "$dev" ]; then
                    name=$(basename "$dev")
                    if [[ "$name" =~ ^(sd[a-z]|nvme[0-9]n[0-9]|vd[a-z])$ ]]; then
                        if [ -z "$drives" ]; then
                            drives="$name"
                        else
                            drives="$drives $name"
                        fi
                    fi
                fi
            done
        fi
        if [ -z "$drives" ]; then
            echo "OK (Nebyly detekovány fyzické disky)"
            return
        fi
        sm_failed=""; sm_unknown=""
        for d in $drives; do
            sm_out=$(timeout 20 smartctl -H -n standby "/dev/$d" 2>/dev/null); sm_rc=$?
            # 124 is timeout firing, 125-127 mean the wrapper itself could not
            # run (no `timeout` installed at all gives 127). None of those is a
            # verdict about the disk - and 127 & 8 is nonzero, so without this
            # every healthy drive on such a host was reported as failing.
            case "$sm_rc" in
                124|125|126|127) sm_unknown="$sm_unknown $d"; continue ;;
            esac
            # Exit-status bit 3 is "DISK FAILING" (smartctl(8); 124 is timeout's
            # own code). ATA drives print PASSED/FAILED, SCSI/SAS ones
            # "SMART Health Status: OK" or a failure text.
            if [ $((sm_rc & 8)) -ne 0 ]; then sm_failed="$sm_failed $d"; continue; fi
            case "$sm_out" in
                *FAILED*) sm_failed="$sm_failed $d" ;;
                *"Health Status: OK"*|*PASSED*) : ;;
                *"Health Status:"*) sm_failed="$sm_failed $d" ;;
                # No verdict: virtio disk, unsupported bridge, not root, standby.
                # Reporting that as WARNING painted healthy VPS disks red for months.
                *) sm_unknown="$sm_unknown $d" ;;
            esac
        done
        # A failing disk wins even when another gave no verdict - an early
        # return on the first silent drive used to hide the failing one behind it.
        if [ -n "$sm_failed" ]; then echo "WARNING (Disk /dev/$(echo "${sm_failed# }" | sed 's| |, /dev/|g') selhal v SMART)"; return; fi
        if [ -n "$sm_unknown" ]; then echo "N/A (SMART nedostupné pro /dev/$(echo "${sm_unknown# }" | sed 's| |, /dev/|g'))"; return; fi
        echo "OK"
    else
        echo "N/A (smartctl chybí)"
    fi
}
get_os_version() {
    if [ -f /etc/os-release ]; then
        pretty_name=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')
        if [ -n "$pretty_name" ]; then
            echo "$pretty_name"
            return
        fi
    fi
    echo "$(uname -s) $(uname -r)"
}
os_version=$(get_os_version)

# 6. Listening ports - straight out of awk, joined once.
ports_json=""
if [ -f /proc/net/tcp ]; then
    ports_json=$(awk '
    NR > 1 && ($4 == "0A" || $4 == "07") {
        split($2, addr, ":"); hex = addr[2]; dec = 0;
        for (i = 1; i <= length(hex); i++) { dec = dec * 16 + index("0123456789abcdef", tolower(substr(hex, i, 1))) - 1 }
        if (dec > 0 && dec < 65536) print dec;
    }' /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null | sort -un | awk '{ printf "%s%s", (n++ ? ", " : ""), $1 }')
fi

# 7. One process snapshot for everything below - the process list, zombies,
# the top-CPU/RAM lists and the TS3 PID. It used to be four separate `ps` runs
# plus a fork or two per listed process. `comm` goes last so a name with
# spaces ("tmux: server") cannot shift the numeric columns.
bk_ps_raw=$(ps -eo pid=,ppid=,stat=,%cpu=,rss=,comm= 2>/dev/null)

process_list=""
zombie_count_json="null"
if [ -n "$bk_ps_raw" ]; then
    process_list=$(printf '%s\n' "$bk_ps_raw" | awk '
        { name = $6; for (i = 7; i <= NF; i++) name = name " " $i; print name }' | sort -u | awk '
        { n = $0; gsub(/\\/, "\\\\", n); gsub(/"/, "\\\"", n); gsub(/[\t]/, " ", n);
          printf "%s\"%s\"", (c++ ? ", " : ""), n }')
    # ps answered, so a count of zero zombies is a measurement here.
    zombie_count_json=$(printf '%s\n' "$bk_ps_raw" | awk '$3 ~ /^Z/ { z++ } END { print (z ? z : 0) }')
fi

# The agent's own process tree must not show up in its own ranking (the
# sampler used to top the list on routers). Parentage comes from the same
# snapshot; a later lookup would find the helpers already gone.
bk_ps_snapshot=""
if [ -n "$bk_ps_raw" ]; then
    bk_ps_snapshot=$(printf '%s\n' "$bk_ps_raw" | awk -v self="$$" '
        { ppid[$1] = $2; line[$1] = $0 }
        END {
            for (p in line) {
                q = p; depth = 0; ours = 0;
                while (q != "" && q != "0" && depth < 8) {
                    if (q == self) { ours = 1; break }
                    q = ppid[q]; depth++;
                }
                if (!ours) print line[p];
            }
        }')
fi

# Top lists built inside awk - no per-line forks. Both values in both lists so
# no cell in the table stays empty; a value ps did not give is null, never 0.
bk_top_json() {  # $1 = sort column: 4 = %cpu, 5 = rss
    printf '%s\n' "$bk_ps_snapshot" | sort -k"$1","$1" -rn | head -n 5 | awk '
        NF >= 6 {
            name = $6; for (i = 7; i <= NF; i++) name = name " " $i;
            gsub(/\\/, "\\\\", name); gsub(/"/, "\\\"", name); gsub(/[\t]/, " ", name);
            cpu = ($4 ~ /^[0-9.]+$/) ? $4 : "null";
            ram = ($5 ~ /^[0-9]+$/) ? sprintf("%.1f", $5 / 1024) : "null";
            printf "%s{\"name\": \"%s\", \"cpu\": %s, \"ram_mb\": %s}", (c++ ? ", " : ""), name, cpu, ram
        }'
}
top_cpu_json=""; top_ram_json=""
if [ -n "$bk_ps_snapshot" ]; then
    top_cpu_json=$(bk_top_json 4)
    top_ram_json=$(bk_top_json 5)
fi

# One TeamSpeak ServerQuery exchange: bk_ts3_query PORT CMD [CMD...]
#
# The query is plain text over a TCP connection to localhost. It used to run
# over bash's built-in socket redirection, which is also the primitive every
# reverse shell is built from - a hosting malware scanner quarantined this
# exact file for it (the other three agents, which do not use it, were served
# fine), so the server stopped offering agent.sh at all and no bash agent
# could update. The literal device path is kept out of this comment too: a
# signature matches a string, not an intention.
# python3 or nc asks the same question without carrying that shape; where
# neither exists the TeamSpeak statistics stay unknown, which is the honest
# answer and not a fabricated zero.
#
# The port and the commands go through the environment, never interpolated
# into the Python source - a value from /proc/net/udp has no business being
# code.
bk_ts3_query() {
    _ts_port="$1"
    shift
    _ts_cmd=$(printf '%s\n' "$@")
    _ts_out=""

    if command -v python3 >/dev/null 2>&1; then
        _ts_out=$(BK_TS3_PORT="$_ts_port" BK_TS3_CMD="$_ts_cmd" python3 -c '
import os, socket, sys
try:
    sock = socket.create_connection(("127.0.0.1", int(os.environ["BK_TS3_PORT"])), timeout=5)
except Exception:
    sys.exit(1)
sock.settimeout(5)
buf = ""
try:
    sock.sendall((os.environ["BK_TS3_CMD"] + "\nquit\n").encode())
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk.decode("utf-8", "replace")
        if "error id=" in buf:
            break
except Exception:
    pass
finally:
    sock.close()
sys.stdout.write(" ".join(buf.split("\n")))
' 2>/dev/null)
    fi

    if [ -z "$_ts_out" ] && command -v nc >/dev/null 2>&1; then
        # -w bounds the wait; timeout covers the nc variants that ignore it.
        _ts_out=$(printf '%s\nquit\n' "$_ts_cmd" | timeout 8 nc -w 5 127.0.0.1 "$_ts_port" 2>/dev/null | tr '\n' ' ')
    fi

    printf '%s' "$_ts_out"
}

# 7.5 Zjištění TeamSpeak statistik (ServerQuery na localhost)
ts3_json_list=""
for q_port in 10011 8219; do
    # Kontrola zda port naslouchá
    if [[ ", $ports_json," == *", $q_port,"* ]] || [[ "$ports_json" =~ ^$q_port, ]] || [[ "$ports_json" =~ ,$q_port$ ]] || [ "$ports_json" = "$q_port" ]; then
        response=$(bk_ts3_query "$q_port" "serverlist")
        if [ -n "$response" ]; then
            servers_parsed=$(echo "$response" | awk '
            BEGIN { RS="|" }
            /virtualserver_port=/ {
                port = 9987;
                online = 0;
                max = 0;
                name = "";
                
                n = split($0, attrs, " ");
                for (i=1; i<=n; i++) {
                    if (attrs[i] ~ /^virtualserver_port=/) {
                        split(attrs[i], kv, "=");
                        port = kv[2];
                    }
                    if (attrs[i] ~ /^virtualserver_clientsonline=/) {
                        split(attrs[i], kv, "=");
                        online = kv[2];
                    }
                    if (attrs[i] ~ /^virtualserver_maxclients=/) {
                        split(attrs[i], kv, "=");
                        max = kv[2];
                    }
                    if (attrs[i] ~ /^virtualserver_name=/) {
                        split(attrs[i], kv, "=");
                        name = kv[2];
                        gsub(/\\s/, " ", name);
                        gsub(/\\p/, "|", name);
                    }
                }
                print port "," online "," max "," name;
            }')
            
            while read -r s_line; do
                if [ -n "$s_line" ]; then
                    IFS=',' read -r s_port s_online s_max s_name <<< "$s_line"
                    s_name_clean=$(echo -n "$s_name" | sed 's/\\/\\\\/g; s/"/\\"/g')
                    if [ -n "$ts3_json_list" ]; then
                        ts3_json_list="$ts3_json_list, "
                    fi
                    ts3_json_list="$ts3_json_list{\"port\": $s_port, \"clients_online\": $s_online, \"clients_max\": $s_max, \"name\": \"$s_name_clean\"}"
                fi
            done <<< "$servers_parsed"
            
            # ZÁLOŽNÍ PLÁN: Pokud serverlist nic nevrátil (např. chybí práva pro hosta), zkusíme skenovat UDP porty a dotázat se jich napřímo
            if [ -z "$ts3_json_list" ]; then
                udp_ports=""
                if [ -f /proc/net/udp ]; then
                    udp_raw=$(awk '
                    NR > 1 {
                        split($2, addr, ":");
                        hex = addr[2];
                        dec = 0;
                        for (i=1; i<=length(hex); i++) {
                            c = substr(hex, i, 1);
                            val = index("0123456789abcdef", tolower(c)) - 1;
                            dec = dec * 16 + val;
                        }
                        port = dec;
                        if (port > 0 && port < 65536) {
                            print port;
                        }
                    }' /proc/net/udp /proc/net/udp6 2>/dev/null | sort -un)
                    for p in $udp_raw; do
                        if [ -z "$udp_ports" ]; then
                            udp_ports="$p"
                        else
                            udp_ports="$udp_ports, $p"
                        fi
                    done
                fi
                
                # Sestavit pole z portů, přidáme i výchozí 9987 a uživatelský 11515 pro jistotu
                udp_arr=()
                if [ -n "$udp_ports" ]; then
                    IFS=',' read -r -a raw_udp <<< "$udp_ports"
                    for up in "${raw_udp[@]}"; do
                        up=${up//[[:space:]]/}
                        [ -n "$up" ] && udp_arr+=("$up")
                    done
                fi
                udp_arr+=("9987" "11515")
                
                # Zkusit každý UDP port napřímo přes ServerQuery 'use port=X'
                for v_port in "${udp_arr[@]}"; do
                    if [ -n "$v_port" ]; then
                        response=$(bk_ts3_query "$q_port" "use port=$v_port" "serverinfo")
                        if [ -n "$response" ]; then
                            if [[ "$response" =~ virtualserver_clientsonline=([0-9]+) ]]; then
                                online="${BASH_REMATCH[1]}"
                                if [[ "$response" =~ virtualserver_maxclients=([0-9]+) ]]; then
                                    max="${BASH_REMATCH[1]}"
                                    
                                    name=""
                                    if [[ "$response" =~ virtualserver_name=([^[:space:]]+) ]]; then
                                        name="${BASH_REMATCH[1]}"
                                        name=$(echo "$name" | sed 's/\\s/ /g; s/\\p/|/g')
                                    fi
                                    
                                    s_name_clean=$(echo -n "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')
                                    if [ -n "$ts3_json_list" ]; then
                                        ts3_json_list="$ts3_json_list, "
                                    fi
                                    ts3_json_list="$ts3_json_list{\"port\": $v_port, \"clients_online\": $online, \"clients_max\": $max, \"name\": \"$s_name_clean\"}"
                                fi
                            fi
                        fi 2>/dev/null
                    fi
                done
            fi
            break
        fi 2>/dev/null
    fi
done

# 7.6 TeamSpeak proces (PID/CPU/RAM/vlákna/otevřené FD) - detekce restartu (změna PID
# mezi hlášeními) se dělá na serveru (agent_api.php), agent jen hlásí aktuální stav.
ts3_pid=""
if [ -n "$bk_ps_raw" ]; then
    ts3_pid=$(printf '%s\n' "$bk_ps_raw" | awk '$6 == "ts3server" { print $1; exit }')
fi

ts3_process_json="null"
new_st_ts3=""
if [ -n "$ts3_pid" ] && [ -d "/proc/$ts3_pid" ]; then
    clk_tck=$(getconf CLK_TCK 2>/dev/null || echo 100)
    ts3_stat=$(sed 's/^[0-9]* (.*) //' "/proc/$ts3_pid/stat" 2>/dev/null)
    # CPU as a delta against the previous run of the same PID, like the host
    # CPU - the 1-second sleep this used to take made every run a second longer.
    ts3_cpu="null"
    ts3_ticks=""
    if [ -n "$ts3_stat" ]; then
        ts3_ticks=$(awk -v s="$ts3_stat" 'BEGIN { n = split(s, a); if (n >= 13) print a[12] + a[13] }')
        if [ -n "$ts3_ticks" ] && [ -n "$st_ts3" ]; then
            IFS=',' read -r prev_ts3_pid prev_ts3_ticks prev_ts3_ts <<< "$st_ts3"
            if [ "$prev_ts3_pid" = "$ts3_pid" ] && [ -n "$prev_ts3_ticks" ] && [ -n "$prev_ts3_ts" ]; then
                ts3_cpu=$(awk -v t1="$prev_ts3_ticks" -v t2="$ts3_ticks" -v s1="$prev_ts3_ts" -v s2="$now_ts" -v tck="$clk_tck" '
                BEGIN { dt = s2 - s1; if (tck <= 0) tck = 100; if (dt > 0 && t2 >= t1) printf "%.1f", ((t2 - t1) / tck) / dt * 100 }')
                [ -z "$ts3_cpu" ] && ts3_cpu="null"
            fi
        fi
        [ -n "$ts3_ticks" ] && new_st_ts3="$ts3_pid,$ts3_ticks,$now_ts"
    fi
    ts3_uptime="null"
    if [ -n "$ts3_stat" ] && [ -r /proc/uptime ]; then
        host_uptime=$(awk '{print $1}' /proc/uptime)
        ts3_uptime=$(awk -v s2="$ts3_stat" -v hu="$host_uptime" -v tck="$clk_tck" '
        BEGIN { n = split(s2, a); if (n >= 20) { if (tck <= 0) tck = 100; u = hu - (a[20] / tck); if (u < 0) u = 0; printf "%.0f", u } }')
        [ -z "$ts3_uptime" ] && ts3_uptime="null"
    fi
    # Unreadable /proc entries (not root) are unknown, not zero.
    ts3_ram_mb="null"; ts3_threads="null"; ts3_fds="null"
    if [ -r "/proc/$ts3_pid/status" ]; then
        ts3_ram_mb=$(awk '/^VmRSS:/ { printf "%.1f", $2/1024 }' "/proc/$ts3_pid/status")
        ts3_threads=$(awk '/^Threads:/ { print $2 }' "/proc/$ts3_pid/status")
        [ -z "$ts3_ram_mb" ] && ts3_ram_mb="null"
        [ -z "$ts3_threads" ] && ts3_threads="null"
    fi
    if [ -r "/proc/$ts3_pid/fd" ]; then
        ts3_fds=$(find "/proc/$ts3_pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
        [ -z "$ts3_fds" ] && ts3_fds="null"
    fi
    ts3_process_json="{\"pid\": $ts3_pid, \"cpu\": $ts3_cpu, \"ram_mb\": $ts3_ram_mb, \"threads\": $ts3_threads, \"open_fds\": $ts3_fds, \"uptime_sec\": $ts3_uptime}"
fi

# 7.7 Service Discovery - detekce běžících služeb (process + port + config + active)
discovered_json=""
detect_svc() {
    local name="$1" stype="$2" port="$3" proc="$4" cfg="$5"
    local conf=0 ev="" miss=""
    # The process list is `"a", "b"` and the port list `22, 80` - the old
    # patterns (`,nginx,` and `, 80,`) never matched the quotes and skipped
    # the first port, so process evidence was never awarded on any bash agent.
    local procs_flat=",${process_list//\"/},"
    procs_flat=${procs_flat//, /,}
    local ports_flat=",${ports_json//, /,},"
    local port_hit=0
    [ -n "$port" ] && case "$ports_flat" in *",$port,"*) port_hit=1 ;; esac
    # Process (30)
    if [ -n "$proc" ]; then
        case "$procs_flat" in
            *",$proc,"*) conf=$((conf+30)); ev="${ev}\"process\"," ;;
            *) miss="${miss}\"process\"," ;;
        esac
    fi
    # Port (25)
    if [ -n "$port" ]; then
        if [ "$port_hit" = "1" ]; then conf=$((conf+25)); ev="${ev}\"port\","; else miss="${miss}\"port\","; fi
    fi
    # Config (25)
    if [ -n "$cfg" ] && [ -e "$cfg" ]; then
        conf=$((conf+25)); ev="${ev}\"config\","
    elif [ -n "$cfg" ]; then miss="${miss}\"config\","; fi
    # Active (19) - port listening = active
    if [ "$port_hit" = "1" ]; then
        conf=$((conf+19)); ev="${ev}\"active_verify\","
    else miss="${miss}\"active_verify\","; fi
    [ $conf -gt 99 ] && conf=99
    [ $conf -lt 25 ] && return
    ev="${ev%,}"; miss="${miss%,}"
    local entry="{\"name\": \"$name\", \"type\": \"$stype\", \"port\": ${port:-null}, \"confidence\": $conf, \"evidence\": [$ev], \"missing\": [$miss]}"
    if [ -z "$discovered_json" ]; then discovered_json="$entry"; else discovered_json="$discovered_json, $entry"; fi
}
# --- The expensive checks, on a schedule (HEAVY_OP_INTERVAL_HOURS) ---------
# SMART wakes disks and costs 50-300 ms per drive, the discovery runs eight
# probes, a USB count changes about never. Their last result lives in a small
# cache next to the script and is refreshed once per interval - the way the
# OpenWrt agent has worked since 1.5.x. This setting was advertised in --help
# for months while nothing read it.
heavy_due=1
if [ -f "$HEAVY_CACHE_FILE" ]; then
    heavy_min=$(( ${HEAVY_OP_INTERVAL_HOURS:-24} * 60 ))
    [ "$heavy_min" -lt 1 ] 2>/dev/null && heavy_min=1
    [ -z "$(find "$HEAVY_CACHE_FILE" -mmin +"$heavy_min" 2>/dev/null)" ] && heavy_due=0
fi
smart="N/A"; usb_devices_json="null"; discovered_json=""
if [ "$heavy_due" = "1" ]; then
    smart=$(get_smart_status)
    if [ -d /sys/bus/usb/devices ]; then
        # Entries like 1-1 are devices; 1-0:1.0 are interfaces (one per root hub
        # even with nothing plugged in) and usb1 the hubs themselves - excluded.
        usb_devices_json=$(find /sys/bus/usb/devices -mindepth 1 -maxdepth 1 -name '[0-9]*-[0-9]*' ! -name '*:*' 2>/dev/null | wc -l | tr -d ' ')
        [ -z "$usb_devices_json" ] && usb_devices_json="null"
    fi
    detect_svc "TeamSpeak" "teamspeak" 10011 "ts3server" ""
    detect_svc "Minecraft" "minecraft" 25565 "java" ""
    detect_svc "Nginx" "nginx" 80 "nginx" "/etc/nginx/nginx.conf"
    detect_svc "Docker" "docker" "" "dockerd" "/var/run/docker.sock"
    detect_svc "PostgreSQL" "postgresql" 5432 "postgres" "/etc/postgresql"
    detect_svc "AdGuard Home" "adguard" 3000 "AdGuardHome" ""
    detect_svc "WireGuard" "wireguard" 51820 "" "/etc/wireguard"
    detect_svc "Mosquitto" "mosquitto" 1883 "mosquitto" "/etc/mosquitto/mosquitto.conf"
    { printf 'smart\t%s\nusb\t%s\ndiscovered\t%s\n' "$smart" "$usb_devices_json" "$discovered_json"; } > "$HEAVY_CACHE_FILE.tmp" 2>/dev/null \
        && mv "$HEAVY_CACHE_FILE.tmp" "$HEAVY_CACHE_FILE" 2>/dev/null
else
    while IFS=$'\t' read -r hk hv; do
        case "$hk" in
            smart) smart="$hv" ;;
            usb) usb_devices_json="$hv" ;;
            discovered) discovered_json="$hv" ;;
        esac
    done < "$HEAVY_CACHE_FILE"
fi
[ -z "$usb_devices_json" ] && usb_devices_json="null"

# 8. Sestavení JSON payloadu

# --- Tailscale / ZeroTier / UPS (NUT) - vse null-safe, bez nastroje se neposila nic ---
tailscale_up_json="null"
tailscale_peers_json="null"
if command -v tailscale >/dev/null 2>&1; then
    ts_json=$(tailscale status --json 2>/dev/null)
    if [ -n "$ts_json" ]; then
        # `tailscale status --json` is indented ("BackendState": "Running") -
        # the old pattern without the space never matched, so this was always false.
        echo "$ts_json" | grep -Eq '"BackendState": *"Running"' && tailscale_up_json=true || tailscale_up_json=false
        tailscale_peers_json=$(echo "$ts_json" | grep -c '"TailscaleIPs"')
        # Self je v JSONu taky - odecist
        [ "$tailscale_peers_json" -gt 0 ] 2>/dev/null && tailscale_peers_json=$((tailscale_peers_json - 1))
    fi
fi

zerotier_networks_json="null"
if command -v zerotier-cli >/dev/null 2>&1; then
    # `grep -c` prints 0 on empty input, so a daemon that is down looked like
    # "0 networks"; the count is taken only when the CLI actually answered.
    zt_out=$(zerotier-cli listnetworks 2>/dev/null) && zerotier_networks_json=$(printf '%s\n' "$zt_out" | grep -c " OK ")
fi

ups_status_json="null"
ups_battery_json="null"
if command -v upsc >/dev/null 2>&1; then
    ups_name=$(upsc -l 2>/dev/null | head -1)
    if [ -n "$ups_name" ]; then
        ups_data=$(upsc "$ups_name" 2>/dev/null)
        ups_st=$(echo "$ups_data" | sed -n 's/^ups.status: //p' | head -1)
        ups_bat=$(echo "$ups_data" | sed -n 's/^battery.charge: //p' | head -1 | tr -cd '0-9')
        [ -n "$ups_st" ] && ups_status_json="\"$ups_st\""
        [ -n "$ups_bat" ] && ups_battery_json="$ups_bat"
    fi
fi

# --- Parita s OpenWrt agentem v1.5.4: OOM, boot time, DNS latence, OpenVPN, USB ---
# OOM kills from /proc/vmstat (kernel 4.13+): one small read, monotonic since
# boot. The old `dmesg | grep -c` scanned the whole ring buffer every minute,
# counted each kill twice (two log lines per event), shrank when the buffer
# wrapped, and printed 0 when dmesg was not readable at all.
oom_kills_json="null"
oom_line=$(awk '/^oom_kill / { print $2 }' /proc/vmstat 2>/dev/null)
[ -n "$oom_line" ] && oom_kills_json="$oom_line"

boot_time_json="null"
[ -n "$uptime" ] && [ "$uptime" -gt 0 ] 2>/dev/null && boot_time_json=$(( now_ts - uptime ))

# DNS latence pres lokalni resolver (getent/nslookup s time); bez naradi null.
dns_latency_ms_json="null"
if command -v nslookup >/dev/null 2>&1; then
    dns_t0=$(date +%s%N 2>/dev/null)
    case "$dns_t0" in *N) dns_t0="";; esac
    if [ -n "$dns_t0" ]; then
        # Bounded: a dead resolver used to stall the whole report for nslookup's
        # full retry sequence. A failed lookup has no latency, so null.
        if command -v timeout >/dev/null 2>&1; then
            timeout 3 nslookup example.com >/dev/null 2>&1 && dns_ok=1 || dns_ok=0
        else
            nslookup example.com >/dev/null 2>&1 && dns_ok=1 || dns_ok=0
        fi
        dns_t1=$(date +%s%N)
        [ "$dns_ok" = "1" ] && dns_latency_ms_json=$(( (dns_t1 - dns_t0) / 1000000 ))
    fi
fi

openvpn_tunnels_json="null"
if command -v pidof >/dev/null 2>&1; then
    openvpn_tunnels_json=$(pidof openvpn 2>/dev/null | wc -w | tr -d '[:space:]')
    [ -z "$openvpn_tunnels_json" ] && openvpn_tunnels_json=0
fi

payload=$(cat <<EOF
{
  "agent_key": "$(json_str "$AGENT_KEY")",
  "agent_type": "bash",
  "version": "$AGENT_VERSION",
  "os": "$(json_str "$os_version")",
  "cpu": $cpu,
  "cpu_steal": $cpu_steal,
  "iowait": $iowait,
  "ram": $ram,
  "ram_total_mb": $ram_total_mb,
  "ram_used_mb": $ram_used_mb,
  "ram_available_mb": $ram_available_mb,
  "ram_free_mb": $ram_free_mb,
  "swap": $swap,
  "hdd": $hdd,
  "inode_usage": $inode_usage_json,
  "load1": $load1,
  "load5": $load5,
  "load15": $load15,
  "disk_io_read": $disk_io_read_json,
  "disk_io_write": $disk_io_write_json,
  "net": $net_json,
  "net_errors": $net_errors_json,
  "fork_rate": $fork_rate_json,
  "temperature": $temperature_json,
  "filesystems": $filesystems_json,
  "top_io_processes": $top_io_json,
  "io_accounting": $io_accounting_json,
  "uptime": $uptime,
  "smart": "$(json_str "$smart")",
  "ports": [$ports_json],
  "processes": [$process_list],
  "teamspeak_servers": [$ts3_json_list],
  "ts3_process": $ts3_process_json,
  "zombie_count": $zombie_count_json,
  "top_cpu_processes": [$top_cpu_json],
  "top_ram_processes": [$top_ram_json],
  "hostname": "$(json_str "$sys_hostname")",
  "kernel": "$(json_str "$sys_kernel")",
  "timezone": "$(json_str "$sys_timezone")",
  "reboot_required": $reboot_required_json,
  "cloud_provider": $cloud_provider_json,
  "tcp_retrans": $tcp_retrans_json,
  "conntrack_count": $conntrack_count_json,
  "virtualization": $virtualization_json,
  "tailscale_up": $tailscale_up_json,
  "tailscale_peers": $tailscale_peers_json,
  "zerotier_networks": $zerotier_networks_json,
  "ups_status": $ups_status_json,
  "ups_battery_pct": $ups_battery_json,
  "auto_update": $([ "$AUTO_UPDATE" = "1" ] && echo 1 || echo 0),
  "oom_kills": $oom_kills_json,
  "boot_time": $boot_time_json,
  "dns_latency_ms": $dns_latency_ms_json,
  "openvpn_tunnels": $openvpn_tunnels_json,
  "usb_devices": $usb_devices_json,
  "discovered_services": [$discovered_json]
}
EOF
)

# This run's counters, one atomic write, only what was actually measured.
{
    printf 'boot_id=%s\n' "$cur_boot_id"
    if [ -n "$new_st_cpu" ]; then printf 'cpu=%s\n' "$new_st_cpu"; fi
    if [ -n "$new_st_diskio" ]; then printf 'diskio=%s\n' "$new_st_diskio"; fi
    if [ -n "$new_st_net" ]; then printf 'net=%s\n' "$new_st_net"; fi
    if [ -n "$new_st_forks" ]; then printf 'forks=%s\n' "$new_st_forks"; fi
    if [ -n "$new_st_ts3" ]; then printf 'ts3=%s\n' "$new_st_ts3"; fi
} > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null \
    || log_message "VAROVANI: stav se nepodarilo ulozit do $STATE_FILE - delta metriky (CPU, sit, disk) zustanou null."

if [ "$SELFCHECK" = "1" ]; then
    # One line for the updater. The payload's newlines are layout only and
    # become tabs: JSON whitespace between tokens, but still an invalid
    # control character inside a string, so a value that escaped json_str
    # fails the updater's parse here just as it would fail on the server.
    printf '{"agent_type":"bash","agent_version":"%s","payload":%s}\n' "$(json_str "$AGENT_VERSION")" "$(printf '%s' "$payload" | tr '\n' '\t')"
    exit 0
fi
if [ "$DRY_RUN" = "1" ]; then
    printf '%s\n' "$payload"
    log_debug "Rezim --dry-run: data se neodesilaji."
    exit 0
fi

net_log="N/A (první běh)"
if [ "$net_json" != "null" ]; then
    net_log="${net_json} KB/s"
fi
log_debug "Metriky - OS: $os_version, CPU: $cpu% (steal $cpu_steal%), RAM: $ram% (swap $swap%), HDD: $hdd%, Load: $load1/$load5/$load15, Síť: $net_log, Uptime: ${uptime}s, SMART: $smart, Porty: [$ports_json]"
log_debug "Odesílám data na $API_URL..."

http_code=""
body=""

if command -v curl >/dev/null 2>&1; then
    response=$(curl -s -m 30 --connect-timeout 10 -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d "$payload" "$API_URL")
    http_code=$(echo "$response" | tail -n 1)
    body=$(echo "$response" | head -n -1)
elif command -v wget >/dev/null 2>&1; then
    headers_file=$(mktemp /tmp/status-wget-hdr.XXXXXX 2>/dev/null || echo "/tmp/status-wget-hdr-$$")
    body=$(wget -T 30 -t 2 --post-data="$payload" --header="Content-Type: application/json" --server-response -q -O - "$API_URL" 2>"$headers_file")
    http_code=$(grep -E '^[[:space:]]*HTTP/' "$headers_file" | tail -n 1 | awk '{print $2}')
    rm -f "$headers_file"
else
    log_message "CHYBA: Není nainstalován ani 'curl' ani 'wget'. Nelze odeslat data."
    exit 1
fi

# Shared by the four agents (agent.sh, agent.py, agent.ps1, agent_openwrt.sh):
# 1-128 characters, a letter, digit or underscore first, then those and
# "_ . @ $ -". No "/" or "\" (the name becomes part of a path run as root),
# no leading "." (no "..") and no leading "-" (systemctl would read an
# option). "@" is a systemd template instance, "$" a Windows one
# (MSSQL$SQLEXPRESS). The "\$" below keeps "$-" from expanding to the
# shell's option flags inside the pattern.
bk_valid_service_name() {
    case "$1" in
        ''|[!A-Za-z0-9_]*|*[!A-Za-z0-9_.@\$-]*) return 1 ;;
    esac
    [ "${#1}" -le 128 ]
}
# restart_service restarts a service, not the machine. systemctl takes the
# unit type from the suffix: "systemctl restart poweroff.target" (or
# emergency.target, or a .mount) is a system-wide action that ALLOWED_ACTIONS
# never allowed - reboot_server is an entry of its own. A name with no suffix
# stays a service (systemctl adds ".service"), and so does "php8.2-fpm".
bk_service_unit_ok() {
    case "$1" in
        *.target|*.mount|*.automount|*.socket|*.device|*.swap|*.path|*.timer|*.slice|*.scope) return 1 ;;
    esac
    return 0
}

if [ "$http_code" = "200" ]; then
    log_debug "OK: Statistiky úspěšně odeslány."
    # The stamp a version on probation waits for: which version the server
    # accepted a report from, and when. It ends the probation.
    printf '%s %s\n' "$AGENT_VERSION" "$(bk_now)" > "$BK_LAST_OK.tmp" 2>/dev/null \
        && mv -f "$BK_LAST_OK.tmp" "$BK_LAST_OK" 2>/dev/null
    rm -f "$BK_PROBATION" 2>/dev/null

    # Potvrzení provedení akce zpět na server - bez tohohle by agent_actions.status
    # zůstal navždy na 'sent' ("odesláno, čeká na potvrzení") v administraci, i když
    # se akce ve skutečnosti provedla (stejný gap, jaký měl dřív agent_openwrt.sh).
    # Samostatný lehký POST, protože hlavní telemetrie už pro tento cyklus odešla.
    send_action_result() {
        ar_id="$1"; ar_status="$2"; ar_msg="$3"
        ar_payload="{\"agent_key\":\"$(json_str "$AGENT_KEY")\",\"action_result\":{\"action_id\":${ar_id},\"status\":\"$(json_str "$ar_status")\",\"message\":\"$(json_str "$ar_msg")\"}}"
        if command -v curl >/dev/null 2>&1; then
            curl -s -m 10 -X POST -H "Content-Type: application/json" -d "$ar_payload" "$API_URL" >/dev/null 2>&1
        elif command -v wget >/dev/null 2>&1; then
            wget -T 10 --post-data="$ar_payload" --header="Content-Type: application/json" -q -O /dev/null "$API_URL" >/dev/null 2>&1
        fi
    }

    # --- Remote Actions (Opt-in přes REMOTE_ACTIONS_ENABLED=1) ---
    REMOTE_ACTIONS_ENABLED="${REMOTE_ACTIONS_ENABLED:-0}"
    ALLOWED_ACTIONS="${ALLOWED_ACTIONS:-restart_service,reboot_server}"

    # bk_action_gate: what a correctly SIGNED action still has to pass - the
    # gate agent_openwrt.sh has had since 0.1.7. Sets act_refused to the
    # reason, or leaves it empty. Without it a signed answer could be
    # replayed for as long as its timestamp held, and service_name went into
    # the command as it came: a signed "../../tmp/x" ran /tmp/x as root, and
    # the same answer replayed ran it again.
    bk_action_gate() {
        act_refused=""
        # Single use. A signature is good for 30 s either side of its
        # timestamp, so at most 60 s after its first use - that long the
        # nonce is remembered. Written BEFORE the action runs: a reboot
        # would not come back to do it.
        case "$act_nonce" in
            ''|*[!A-Za-z0-9]*) act_refused="nonce chybí nebo má nepovolené znaky"; return 0 ;;
        esac
        nonce_keep=""; nonce_seen=0
        if [ -f "$BK_NONCE_FILE" ]; then
            while read -r n_ts n_val; do
                case "$n_ts" in ''|*[!0-9]*) continue ;; esac
                [ "${#n_ts}" -le 18 ] || continue
                [ $((now_ts - 10#$n_ts)) -gt 60 ] && continue
                [ "$n_val" = "$act_nonce" ] && nonce_seen=1
                nonce_keep="$nonce_keep$n_ts $n_val
"
            done < "$BK_NONCE_FILE"
        fi
        if [ "$nonce_seen" = "1" ]; then
            act_refused="nonce už byl použit (opakovaná odpověď)"; return 0
        fi
        # A nonce that cannot be remembered could be replayed: refuse.
        if ! printf '%s%s %s\n' "$nonce_keep" "$now_ts" "$act_nonce" > "$BK_NONCE_FILE.tmp" 2>/dev/null \
            || ! mv -f "$BK_NONCE_FILE.tmp" "$BK_NONCE_FILE" 2>/dev/null; then
            act_refused="nonce nejde uložit do $BK_NONCE_FILE"; return 0
        fi
        # Allow-list. The type is checked first: a comma inside it would
        # match across two entries of the list.
        case "$act_type" in
            *[!a-z_]*) act_refused="neplatný typ akce"; return 0 ;;
        esac
        allowed_list=$(printf '%s' "$ALLOWED_ACTIONS" | tr -d ' \t\r')
        case ",$allowed_list," in
            *",$act_type,"*) ;;
            *) act_refused="akce '$act_type' není v ALLOWED_ACTIONS"; return 0 ;;
        esac
        if [ "$act_type" = "restart_service" ]; then
            svc_name=$(echo "$body" | sed -n 's/.*"service_name":"\([^"]*\)".*/\1/p')
            bk_valid_service_name "$svc_name" || { act_refused="neplatný název služby"; return 0; }
            bk_service_unit_ok "$svc_name" || { act_refused="'$svc_name' není služba (jednotka systemd jiného typu)"; return 0; }
        fi
        return 0
    }

    if [ "$REMOTE_ACTIONS_ENABLED" = "1" ] && [ -n "$body" ]; then
        act_id=$(echo "$body" | awk -F'"action_id":' '{print $2}' | awk -F'[,}]' '{print $1}' | tr -d '[:space:]')
        act_type=$(echo "$body" | awk -F'"action":' '{print $2}' | awk -F'[,"]' '{print $2}' | tr -d '[:space:]')
        act_ts=$(echo "$body" | awk -F'"timestamp":' '{print $2}' | awk -F'[,}]' '{print $1}' | tr -d '[:space:]')
        act_sig=$(echo "$body" | awk -F'"signature":' '{print $2}' | awk -F'[,"]' '{print $2}' | tr -d '[:space:]')
        act_nonce=$(echo "$body" | awk -F'"nonce":' '{print $2}' | awk -F'[,"]' '{print $2}' | tr -d '[:space:]')
        # Both are used as numbers BEFORE any signature is checked: the
        # timestamp in shell arithmetic, the id unquoted in the result JSON.
        # A timestamp like a[$(id)] ran that command as root inside $(( )).
        # Digits only, at most 18 of them (no overflow), read as decimal
        # (10#) so a leading zero is not an octal error that ends the run.
        # Not a number = no action.
        case "$act_id$act_ts" in
            *[!0-9]*)
                log_message "VAROVÁNÍ: Vzdálená akce má nečíselné action_id nebo timestamp, ignoruji ji."
                act_id=""; act_ts="" ;;
        esac
        if [ "${#act_id}" -gt 18 ] || [ "${#act_ts}" -gt 18 ]; then
            log_message "VAROVÁNÍ: Vzdálená akce má příliš dlouhé action_id nebo timestamp, ignoruji ji."
            act_id=""; act_ts=""
        fi

        if [ -n "$act_id" ] && [ -n "$act_type" ] && [ -n "$act_ts" ] && [ -n "$act_sig" ]; then
            now_ts=$(bk_now)
            time_diff=$((now_ts - 10#$act_ts))
            [ $time_diff -lt 0 ] && time_diff=$(( -time_diff ))

            if [ $time_diff -le 30 ]; then
                calc_str="action=${act_type}|ts=${act_ts}|nonce=${act_nonce}"
                calc_sig=""
                if command -v openssl >/dev/null 2>&1; then
                    calc_sig=$(echo -n "$calc_str" | openssl dgst -sha256 -hmac "$AGENT_KEY" 2>/dev/null | awk '{print $NF}')
                elif command -v python3 >/dev/null 2>&1; then
                    # Via the environment, not interpolated into Python source:
                    # the nonce comes from the server and a quote in it would
                    # have been code running as root.
                    calc_sig=$(BK_KEY="$AGENT_KEY" BK_MSG="$calc_str" python3 -c "import hmac, hashlib, os; print(hmac.new(os.environ['BK_KEY'].encode(), os.environ['BK_MSG'].encode(), hashlib.sha256).hexdigest())" 2>/dev/null)
                fi

                act_refused=""
                # The gate only ever sees a verified signature: an unsigned
                # answer learns nothing about the list and burns no nonce.
                if [ -n "$calc_sig" ] && [ "$calc_sig" = "$act_sig" ]; then
                    bk_action_gate
                fi
                if [ -n "$act_refused" ]; then
                    log_message "VAROVÁNÍ: Odmítnuta vzdálená akce $act_type (ID: $act_id): $act_refused"
                    send_action_result "$act_id" "failed" "Odmítnuto: $act_refused"
                elif [ -n "$calc_sig" ] && [ "$calc_sig" = "$act_sig" ]; then
                    log_message "Aktivována bezpečná vzdálená akce: $act_type (ID: $act_id)"
                    case "$act_type" in
                        restart_service)
                            # svc_name was read and checked by bk_action_gate.
                            if command -v systemctl >/dev/null 2>&1; then
                                systemctl restart "$svc_name" 9>&- >/dev/null 2>&1 || true
                                log_message "Restartována služba přes systemctl: $svc_name"
                                send_action_result "$act_id" "executed" "Služba '$svc_name' restartována přes systemctl"
                            elif [ -f "/etc/init.d/$svc_name" ] && [ -x "/etc/init.d/$svc_name" ]; then
                                # -f as well as -x: a directory passes -x.
                                # 9>&- closes the run lock for the child: a daemon
                                # started by an init script inherits open fds and
                                # would otherwise hold the lock for as long as it lives.
                                /etc/init.d/"$svc_name" restart 9>&- >/dev/null 2>&1 || true
                                log_message "Restartována služba přes init.d: $svc_name"
                                send_action_result "$act_id" "executed" "Služba '$svc_name' restartována přes init.d"
                            else
                                log_message "VAROVÁNÍ: Služba '$svc_name' nenalezena nebo neni spustitelná."
                                send_action_result "$act_id" "failed" "Služba '$svc_name' nenalezena nebo neni spustitelná"
                            fi
                            ;;
                        reboot_server)
                            log_message "PROVÁDÍM REBOOT SERVERU DLE PODEPSANÉHO POKYNU..."
                            # Potvrzení musí odejít PŘED rebootem - jakmile
                            # /sbin/reboot ukončí proces, už se nic dalšího neprovede.
                            send_action_result "$act_id" "executed" "Server se restartuje"
                            /sbin/reboot >/dev/null 2>&1 || systemctl reboot >/dev/null 2>&1 || true
                            ;;
                        *)
                            # On the list but unknown to this version: say
                            # so, or the action stays "sent" for ever.
                            send_action_result "$act_id" "failed" "Tato verze agenta akci '$act_type' nezná"
                            ;;
                    esac
                else
                    log_message "VAROVÁNÍ: Odmítnuta vzdálená akce - neplatný HMAC podpis!"
                    send_action_result "$act_id" "failed" "Neplatný HMAC podpis"
                fi
            else
                log_message "VAROVÁNÍ: Odmítnuta vzdálená akce - vypršená platnost (časové okno > 30s)"
                send_action_result "$act_id" "failed" "Vypršela platnost podpisu (>30s)"
            fi
        fi
    fi
else
    # A version on probation that the server turns away is counted: a few
    # refusals take it back (bk_probation_check). Only 4xx - the server read
    # the report and said no; a 5xx or no answer at all is not this
    # version's doing and counts only as a run.
    case "$http_code" in
        4??)
            if [ -f "$BK_PROBATION" ] && [ "$pb_new" = "$AGENT_VERSION" ]; then
                pb_rej=$((pb_rej + 1))
                bk_probation_save "$pb_runs" "$pb_rej"
            fi
            ;;
    esac
    log_message "CHYBA: Server odpověděl kódem $http_code."
    log_message "Odpověď: $body"
    exit 1
fi

# 9. Automatická aktualizace agenta (opt-in přes AUTO_UPDATE=1)
# The server offers a version and the SHA-256 of its file. The download
# replaces this script only when it is, in this order:
#   - strictly newer than this version: a server that serves an older file
#     (a pinned submodule reverted) must not downgrade the fleet;
#   - not a file this host rolled back or refused within the last day (so
#     a bad release is not downloaded and logged again every run);
#   - the file the server hashed;
#   - complete: its last line is "# bk-agent-end <offered version>". A
#     transfer cut short can still pass `bash -n` and the checksum is taken
#     from the same server;
#   - valid bash, and a working agent: `--selfcheck` runs its whole dry-run
#     collection and prints the payload, which must parse as JSON;
# and then by a rename inside this directory, never a copy across
# filesystems, with the current version kept as .prev and a .probation file
# that brings it back if the new one gets no report through.

# 0 when $1 is a newer dotted-numeric version than $2 ("0.1.10" > "0.1.9").
# Anything else (a "-rc1" suffix, an empty string) cannot be shown to be
# newer and is not installed.
bk_version_newer() {
    local a="$1" b="$2" x y
    case "$a" in ''|.*|*.|*..*|*[!0-9.]*) return 1 ;; esac
    case "$b" in ''|.*|*.|*..*|*[!0-9.]*) return 1 ;; esac
    while [ -n "$a" ] || [ -n "$b" ]; do
        x=${a%%.*}; y=${b%%.*}
        if [ "$a" = "$x" ]; then a=""; else a=${a#*.}; fi
        if [ "$b" = "$y" ]; then b=""; else b=${b#*.}; fi
        # Long enough to overflow is not a version anyone released.
        { [ "${#x}" -le 18 ] && [ "${#y}" -le 18 ]; } || return 1
        x=$((10#${x:-0})); y=$((10#${y:-0}))
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 1
}

# 0 when file $1 holds exactly one line: the --selfcheck answer of a bash
# agent of version $2.
bk_selfcheck_ok() {
    local lines line
    lines=$(wc -l < "$1" 2>/dev/null)
    [ "${lines//[[:space:]]/}" = "1" ] || return 1
    if command -v python3 >/dev/null 2>&1; then
        # A real JSON parse. The payload is put together by hand in bash, and
        # what matters is that the server will be able to read it. The
        # payload member is optional in the contract (so it can change);
        # when present it has to be this agent's payload.
        python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
if not isinstance(d, dict) or d.get("agent_type") != "bash" or d.get("agent_version") != sys.argv[2]:
    sys.exit(1)
p = d.get("payload")
if p is not None and not (isinstance(p, dict) and p.get("agent_type") == "bash" and p.get("version") == sys.argv[2]):
    sys.exit(1)
' "$1" "$2" 2>/dev/null
        return $?
    fi
    # No python3: the contract's opening members and a closing brace. A
    # payload that is not JSON gets past this one; the server then refuses
    # its reports and the probation takes the version back.
    IFS= read -r line < "$1" || return 1
    case "$line" in
        "{\"agent_type\":\"bash\",\"agent_version\":\"$2\""*"}") return 0 ;;
    esac
    return 1
}

bk_update_refused() { # MESSAGE [SHA to remember]
    log_message "CHYBA UPDATE: $1 Aktualizace zrušena."
    rm -f "$BK_SELF.new" 2>/dev/null
    # A refusal for what the file IS (not for a full disk or a failed
    # download) will not change until the server serves other bytes.
    [ -n "${2:-}" ] && bk_refuse_sha "$2"
    return 0
}

bk_self_update() {
    local update_available update_url update_sha latest_version new actual_sha last_line
    local self_kb self_mode free_kb need_kb rb_sha rb_ts sc_dir sc_rc sc_why download_ok
    update_available=$(echo "$body" | grep -o '"update_available":[a-z]*' | cut -d: -f2)
    [ "$update_available" = "true" ] || return 0
    update_url=$(echo "$body" | sed -n 's/.*"update_url":"\([^"]*\)".*/\1/p' | sed 's,\\/,/,g')
    update_sha=$(echo "$body" | sed -n 's/.*"update_sha256":"\([a-f0-9]*\)".*/\1/p')
    latest_version=$(echo "$body" | sed -n 's/.*"latest_version":"\([^"]*\)".*/\1/p')
    { [ -n "$update_url" ] && [ -n "$update_sha" ]; } || return 0

    # Debug level: the server repeats its offer with every report, and a
    # refusal that stands until the server changes must not fill the log.
    if ! bk_version_newer "$latest_version" "$AGENT_VERSION"; then
        log_debug "Aktualizace na '$latest_version' odmítnuta: není novější než $AGENT_VERSION."
        return 0
    fi
    if [ -f "$BK_REFUSED" ]; then
        rb_sha=""; rb_ts=""
        read -r rb_sha rb_ts < "$BK_REFUSED" 2>/dev/null
        case "$rb_ts" in ''|*[!0-9]*) rb_ts=0 ;; esac
        [ "${#rb_ts}" -le 18 ] || rb_ts=0
        if [ "$rb_sha" = "$update_sha" ] && [ $((now_ts - 10#$rb_ts)) -lt 86400 ]; then
            log_debug "Aktualizace na $latest_version odložena: tento soubor byl na tomto stroji odmítnut nebo vrácen zpět před méně než 24 h."
            return 0
        fi
    fi
    # The self-check below must not be able to hang the agent for good.
    if ! command -v timeout >/dev/null 2>&1; then
        log_message "CHYBA UPDATE: Chybí příkaz 'timeout' (coreutils), bez něj nejde novou verzi ověřit. Aktualizace zrušena."
        return 0
    fi
    # Room for the new file beside this one and for a copied .prev where a
    # hardlink is not possible, checked before anything is written: a full
    # disk breaks far more on the host than this agent. A df that says
    # nothing does not stop the update - the writes below then fail cleanly.
    self_kb=$(( $(wc -c < "$BK_SELF") / 1024 + 1 ))
    need_kb=$(( 2 * self_kb + 64 ))
    free_kb=$(df -Pk "$ScriptPath" 2>/dev/null | awk 'NR == 2 {print $4}')
    case "$free_kb" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$free_kb" -lt "$need_kb" ]; then
                log_message "CHYBA UPDATE: Vedle $BK_SELF není místo na novou verzi (volno ${free_kb} kB, potřeba ${need_kb} kB). Aktualizace zrušena."
                return 0
            fi
            ;;
    esac

    # One fixed name in this directory: a run killed mid-download leaves one
    # file the next attempt overwrites, and the final rename stays inside one
    # filesystem (a rename is atomic, a cross-filesystem mv is a copy that
    # cron can catch half written).
    new="$BK_SELF.new"
    rm -f "$new" 2>/dev/null
    log_message "K dispozici je nová verze agenta $latest_version (aktuální $AGENT_VERSION), stahuji z $update_url..."
    download_ok=0
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m 60 --connect-timeout 10 -o "$new" "$update_url" 9>&- && download_ok=1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 60 -t 2 -O "$new" "$update_url" 9>&- && download_ok=1
    fi
    if [ "$download_ok" != "1" ]; then
        bk_update_refused "Stažení nové verze se nezdařilo."
        return 0
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        actual_sha=$(sha256sum "$new" | awk '{print $1}')
    else
        actual_sha=$(shasum -a 256 "$new" 2>/dev/null | awk '{print $1}')
    fi
    if [ "$actual_sha" != "$update_sha" ]; then
        bk_update_refused "Checksum nesouhlasí (očekáván $update_sha, stažen $actual_sha)."
        return 0
    fi
    last_line=$(tail -n 1 "$new" 2>/dev/null)
    if [ "$last_line" != "# bk-agent-end $latest_version" ]; then
        bk_update_refused "Stažený soubor nekončí řádkem '# bk-agent-end $latest_version' (neúplný přenos nebo jiná verze)." "$actual_sha"
        return 0
    fi
    if ! bash -n "$new" 2>/dev/null; then
        bk_update_refused "Stažený soubor neprošel kontrolou syntaxe." "$actual_sha"
        return 0
    fi
    # Output to files, not $( ): a probe the self-check leaves behind (a hung
    # smartctl) would keep a pipe open and the capture waiting for ever.
    sc_dir=$(mktemp -d "${TMPDIR:-/tmp}/bk-update.XXXXXX" 2>/dev/null)
    if [ -z "$sc_dir" ]; then
        bk_update_refused "Nelze vytvořit dočasný adresář pro samokontrolu."
        return 0
    fi
    # No -k: busybox timeout before 1.36 has no such option, and an unknown
    # option would fail every self-check - and be remembered as the file's
    # fault. The self-check does not trap TERM.
    BK_UPDATE_SELFCHECK=1 timeout 60 bash "$new" --selfcheck > "$sc_dir/out" 2> "$sc_dir/err" < /dev/null 9>&-
    sc_rc=$?
    if [ "$sc_rc" != "0" ] || ! bk_selfcheck_ok "$sc_dir/out" "$latest_version"; then
        sc_why=$(head -c 300 "$sc_dir/err" 2>/dev/null | tr '\n' ' ')
        rm -rf "$sc_dir"
        bk_update_refused "Nová verze neprošla samokontrolou (--selfcheck, kód $sc_rc)${sc_why:+: $sc_why}" "$actual_sha"
        return 0
    fi
    rm -rf "$sc_dir"

    # The current version stays beside the new one for the probation.
    rm -f "$BK_SELF.prev" 2>/dev/null
    if ! ln "$BK_SELF" "$BK_SELF.prev" 2>/dev/null && ! cp -p "$BK_SELF" "$BK_SELF.prev" 2>/dev/null; then
        rm -f "$BK_SELF.prev" 2>/dev/null
        bk_update_refused "Nelze uložit současnou verzi jako $BK_SELF.prev."
        return 0
    fi
    # The mode of the file it replaces (an agent kept at 0700 stays 0700).
    self_mode=$(stat -c %a "$BK_SELF" 2>/dev/null)
    case "$self_mode" in
        [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) chmod "$self_mode" "$new" 2>/dev/null ;;
        *) chmod +x "$new" 2>/dev/null ;;
    esac
    # The data on the disk before the name points at it: a power cut right
    # after the rename must not leave the name on an empty file. GNU sync
    # with a file argument flushes that file only; an older one ignores the
    # argument and flushes everything, which is slower but just as safe.
    sync "$new" 2>/dev/null || sync
    # Written BEFORE the rename, so the new version never runs without it;
    # if the rename fails, the old version finds a file naming another
    # version and drops it.
    pb_new="$latest_version"; pb_old="$AGENT_VERSION"; pb_sha="$update_sha"
    if ! bk_probation_save 0 0; then
        bk_update_refused "Nelze zapsat $BK_PROBATION - bez něj by vadnou verzi nešlo vrátit."
        return 0
    fi
    if ! mv -f "$new" "$BK_SELF" 2>/dev/null; then
        rm -f "$BK_PROBATION" 2>/dev/null
        bk_update_refused "Nepodařilo se nahradit $BK_SELF (práva?)."
        return 0
    fi
    sync "$ScriptPath" 2>/dev/null
    log_message "OK: Agent aktualizován na verzi $latest_version. Nová verze se použije při příštím spuštění."
    exit 0
}

if [ "$AUTO_UPDATE" = "1" ]; then
    bk_self_update
fi

log_message "Hotovo."
# bk-agent-end 0.1.3
