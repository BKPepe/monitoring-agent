#!/bin/bash
# Blood Kings Status Monitoring - VPS Agent (Bash/Shell Version)
#
# Tento skript spouštějte na vašem VPS (např. přes cron každých 5 minut).
# Nevyžaduje žádné knihovny ani Python 3 (pouze standardní sh/bash, awk, grep, df a curl).

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

AGENT_VERSION="0.1.1"
LOG_FILE="$ScriptPath/agent.log"
# One state file for every between-run delta (CPU, disk I/O, network, forks,
# TS3 CPU), written once per run next to the script. It used to be four files,
# one of them in /tmp where it outlived reboots and produced negative deltas.
# Plus one cache for the expensive checks (see HEAVY_OP_INTERVAL_HOURS).
STATE_FILE="$ScriptPath/agent.state"
HEAVY_CACHE_FILE="$ScriptPath/agent-heavy.cache"

VERBOSE="0"
DRY_RUN="0"
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
    esac
done

# Escapes one string for a JSON value: backslash, quote, and the control
# characters a process name may legally contain (a tab would break the whole
# report, and the server rejects invalid JSON with a 400).
json_str() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g; s/\t/ /g' | tr -d '\000-\010\013\014\016-\037' | tr '\n' ' '
}

log_message() {
    local msg="$1"
    local ts
    printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
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
    if exec 9>"$ScriptPath/.agent.lock" 2>/dev/null; then
        flock -n 9 || { log_message "Predchozi beh jeste bezi, tento koncim."; exit 0; }
    fi
fi

bk_now() { printf '%(%s)T' -1; }
now_ts=$(bk_now)

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
eval $(awk '
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
}' /proc/meminfo 2>/dev/null)
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
                if (has_type) { dev=$1; type=$2; total=$3; used=$4; avail=$5; pct=$6; mnt=$7 }
                else          { dev=$1; type="";  total=$2; used=$3; avail=$4; pct=$5; mnt=$6 }
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
if [ -n "$inode_usage" ]; then
    inode_usage_json="$inode_usage"
fi

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
    io_files=()
    for f in /proc/[0-9]*/io; do [ -r "$f" ] && io_files+=("$f"); done
    if [ "${#io_files[@]}" -gt 0 ]; then
        top_io_json=$(awk '
            FNR == 1 { pid = FILENAME; sub(/^\/proc\//, "", pid); sub(/\/io$/, "", pid) }
            /^write_bytes:/ {
                wb = $2 + 0;
                if (wb > 0) {
                    cf = "/proc/" pid "/comm"; name = "";
                    if ((getline name < cf) > 0) { close(cf) }
                    if (name != "") print wb "|" pid "|" name;
                }
            }' "${io_files[@]}" 2>/dev/null | sort -t'|' -k1,1 -rn | head -5 | awk -F'|' '
            { n = $3; gsub(/\\/, "\\\\", n); gsub(/"/, "\\\"", n); gsub(/[\t]/, " ", n);
              printf "%s{\"pid\":%s,\"name\":\"%s\",\"write_bytes\":%s}", (c++ ? "," : "["), $2, n, $1 }
            END { printf "%s", (c ? "]" : "[]") }')
    fi
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
            # Exit-status bit 3 is "DISK FAILING" (smartctl(8); 124 is timeout's
            # own code). ATA drives print PASSED/FAILED, SCSI/SAS ones
            # "SMART Health Status: OK" or a failure text.
            if [ "$sm_rc" -ne 124 ] && [ $((sm_rc & 8)) -ne 0 ]; then sm_failed="$sm_failed $d"; continue; fi
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
        if [ -n "$sm_failed" ]; then echo "WARNING (Disk /dev/${sm_failed# } selhal v SMART)"; return; fi
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
    if [[ ", $ports_json," =~ ", $q_port," ]] || [[ "$ports_json" =~ ^$q_port, ]] || [[ "$ports_json" =~ ,$q_port$ ]] || [ "$ports_json" = "$q_port" ]; then
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
                        udp_arr+=($(echo -n "$up" | tr -d '[:space:]'))
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

if [ "$http_code" = "200" ]; then
    log_debug "OK: Statistiky úspěšně odeslány."

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

    if [ "$REMOTE_ACTIONS_ENABLED" = "1" ] && [ -n "$body" ]; then
        act_id=$(echo "$body" | awk -F'"action_id":' '{print $2}' | awk -F'[,}]' '{print $1}' | tr -d '[:space:]')
        act_type=$(echo "$body" | awk -F'"action":' '{print $2}' | awk -F'[,"]' '{print $2}' | tr -d '[:space:]')
        act_ts=$(echo "$body" | awk -F'"timestamp":' '{print $2}' | awk -F'[,}]' '{print $1}' | tr -d '[:space:]')
        act_sig=$(echo "$body" | awk -F'"signature":' '{print $2}' | awk -F'[,"]' '{print $2}' | tr -d '[:space:]')
        act_nonce=$(echo "$body" | awk -F'"nonce":' '{print $2}' | awk -F'[,"]' '{print $2}' | tr -d '[:space:]')

        if [ -n "$act_id" ] && [ -n "$act_type" ] && [ -n "$act_ts" ] && [ -n "$act_sig" ]; then
            now_ts=$(bk_now)
            time_diff=$((now_ts - act_ts))
            [ $time_diff -lt 0 ] && time_diff=$(( -time_diff ))

            if [ $time_diff -le 30 ]; then
                case ",$ALLOWED_ACTIONS," in
                    *",$act_type,"*)
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

                        if [ -n "$calc_sig" ] && [ "$calc_sig" = "$act_sig" ]; then
                            log_message "Aktivována bezpečná vzdálená akce: $act_type (ID: $act_id)"
                            case "$act_type" in
                                restart_service)
                                    svc_name=$(echo "$body" | sed -n 's/.*"service_name":"\([^"]*\)".*/\1/p')
                                    if [ -n "$svc_name" ]; then
                                        if command -v systemctl >/dev/null 2>&1; then
                                            systemctl restart "$svc_name" >/dev/null 2>&1 || true
                                            log_message "Restartována služba přes systemctl: $svc_name"
                                            send_action_result "$act_id" "executed" "Služba '$svc_name' restartována přes systemctl"
                                        elif [ -x "/etc/init.d/$svc_name" ]; then
                                            /etc/init.d/"$svc_name" restart >/dev/null 2>&1 || true
                                            log_message "Restartována služba přes init.d: $svc_name"
                                            send_action_result "$act_id" "executed" "Služba '$svc_name' restartována přes init.d"
                                        else
                                            log_message "VAROVÁNÍ: Služba '$svc_name' nenalezena nebo neni spustitelná."
                                            send_action_result "$act_id" "failed" "Služba '$svc_name' nenalezena nebo neni spustitelná"
                                        fi
                                    else
                                        send_action_result "$act_id" "failed" "Chybí service_name v payloadu akce"
                                    fi
                                    ;;
                                reboot_server)
                                    log_message "PROVÁDÍM REBOOT SERVERU DLE PODEPSANÉHO POKYNU..."
                                    # Potvrzení musí odejít PŘED rebootem - jakmile
                                    # /sbin/reboot ukončí proces, už se nic dalšího neprovede.
                                    send_action_result "$act_id" "executed" "Server se restartuje"
                                    /sbin/reboot >/dev/null 2>&1 || systemctl reboot >/dev/null 2>&1 || true
                                    ;;
                            esac
                        else
                            log_message "VAROVÁNÍ: Odmítnuta vzdálená akce - neplatný HMAC podpis!"
                            send_action_result "$act_id" "failed" "Neplatný HMAC podpis"
                        fi
                        ;;
                    *)
                        log_message "VAROVÁNÍ: Odmítnuta vzdálená akce '$act_type' - není na seznamu ALLOWED_ACTIONS!"
                        send_action_result "$act_id" "failed" "Akce '$act_type' neni v ALLOWED_ACTIONS"
                        ;;
                esac
            else
                log_message "VAROVÁNÍ: Odmítnuta vzdálená akce - vypršená platnost (časové okno > 30s)"
                send_action_result "$act_id" "failed" "Vypršela platnost podpisu (>30s)"
            fi
        fi
    fi
else
    log_message "CHYBA: Server odpověděl kódem $http_code."
    log_message "Odpověď: $body"
    exit 1
fi

# 9. Automatická aktualizace agenta (opt-in přes AUTO_UPDATE=1)
# Server v odpovědi oznámí novější verzi včetně SHA-256 checksumu. Nová verze
# se stáhne do dočasného souboru, ověří se checksum i syntaxe (bash -n) a teprve
# potom se atomicky nahradí tento skript. Při dalším spuštění (cron/systemd)
# už poběží nová verze.
if [ "$AUTO_UPDATE" = "1" ]; then
    update_available=$(echo "$body" | grep -o '"update_available":[a-z]*' | cut -d: -f2)
    if [ "$update_available" = "true" ]; then
        update_url=$(echo "$body" | sed -n 's/.*"update_url":"\([^"]*\)".*/\1/p' | sed 's,\\/,/,g')
        update_sha=$(echo "$body" | sed -n 's/.*"update_sha256":"\([a-f0-9]*\)".*/\1/p')
        latest_version=$(echo "$body" | sed -n 's/.*"latest_version":"\([^"]*\)".*/\1/p')

        if [ -n "$update_url" ] && [ -n "$update_sha" ]; then
            self_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
            tmp_file=$(mktemp "$ScriptPath/agent-update.XXXXXX" 2>/dev/null || echo "/tmp/agent-update-$$")
            log_message "K dispozici je nová verze agenta $latest_version (aktuální $AGENT_VERSION), stahuji z $update_url..."

            download_ok=0
            if command -v curl >/dev/null 2>&1; then
                curl -fsS -m 60 --connect-timeout 10 -o "$tmp_file" "$update_url" && download_ok=1
            elif command -v wget >/dev/null 2>&1; then
                wget -q -T 60 -t 2 -O "$tmp_file" "$update_url" && download_ok=1
            fi

            if [ "$download_ok" = "1" ]; then
                if command -v sha256sum >/dev/null 2>&1; then
                    actual_sha=$(sha256sum "$tmp_file" | awk '{print $1}')
                else
                    actual_sha=$(shasum -a 256 "$tmp_file" 2>/dev/null | awk '{print $1}')
                fi

                if [ "$actual_sha" = "$update_sha" ]; then
                    if bash -n "$tmp_file" 2>/dev/null; then
                        cp "$self_path" "$self_path.bak" 2>/dev/null || true
                        chmod +x "$tmp_file"
                        if mv "$tmp_file" "$self_path"; then
                            log_message "OK: Agent aktualizován na verzi $latest_version. Nová verze se použije při příštím spuštění."
                            exit 0
                        else
                            log_message "CHYBA UPDATE: Nepodařilo se nahradit $self_path (práva?). Aktualizace zrušena."
                        fi
                    else
                        log_message "CHYBA UPDATE: Stažený soubor neprošel kontrolou syntaxe. Aktualizace zrušena."
                    fi
                else
                    log_message "CHYBA UPDATE: Checksum nesouhlasí (očekáván $update_sha, stažen $actual_sha). Aktualizace zrušena."
                fi
            else
                log_message "CHYBA UPDATE: Stažení nové verze se nezdařilo."
            fi
            rm -f "$tmp_file" 2>/dev/null || true
        fi
    fi
fi

log_message "Hotovo."
