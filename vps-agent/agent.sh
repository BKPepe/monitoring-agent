#!/bin/bash
# Blood Kings Status Monitoring - VPS Agent (Bash/Shell Version)
#
# Tento skript spouštějte na vašem VPS (např. přes cron každých 5 minut).
# Nevyžaduje žádné knihovny ani Python 3 (pouze standardní sh/bash, awk, grep, df a curl).

# === VÝCHOZÍ KONFIGURACE ===
# Pokud chcete, můžete tyto hodnoty nechat zde, nebo vytvořit soubor 'agent.cfg' ve stejné složce
API_URL="http://localhost/status/agent_api.php"
AGENT_KEY="ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE"
AUTO_UPDATE="0" # Nastavte na "1" pro povolení automatických aktualizací agenta ze serveru
# ===========================

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
    RESP=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"action\":\"register\", \"token\":\"$REG_TOKEN\", \"hostname\":\"$HOSTNAME_VAL\", \"agent_type\":\"bash\"}" "$API_URL")
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

AGENT_VERSION="1.7.0"
LOG_FILE="$ScriptPath/agent.log"
NET_STATE_FILE="$ScriptPath/agent_net.state"
DISKIO_STATE_FILE="$ScriptPath/agent_diskio.state"
FORKRATE_STATE_FILE="$ScriptPath/agent_forkrate.state"

log_message() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$ts - $msg"
    # Log do souboru
    if echo "$ts - $msg" >> "$LOG_FILE" 2>/dev/null; then
        :
    else
        echo "$ts - $msg" >> /tmp/status-agent.log 2>/dev/null || true
    fi
}

if [ "$AGENT_KEY" = "ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE" ]; then
    log_message "CHYBA: Nebyl nastaven AGENT_KEY. Upravte skript nebo 'agent.cfg'."
    exit 1
fi

log_message "Získávám systémové statistiky (BASH)..."

# 1. CPU Usage (math from /proc/stat over 1 second sleep)
read_cpu_stat() {
    grep '^cpu ' /proc/stat
}

stat1=$(read_cpu_stat)
sleep 1
stat2=$(read_cpu_stat)

cpu_steal_out=$(awk -v s1="$stat1" -v s2="$stat2" '
BEGIN {
    split(s1, a1);
    split(s2, a2);

    iowait1 = a1[6] + 0;
    idle1 = a1[5] + a1[6];
    total1 = a1[2]+a1[3]+a1[4]+a1[5]+a1[6]+a1[7]+a1[8];
    steal1 = a1[9] + 0;

    iowait2 = a2[6] + 0;
    idle2 = a2[5] + a2[6];
    total2 = a2[2]+a2[3]+a2[4]+a2[5]+a2[6]+a2[7]+a2[8];
    steal2 = a2[9] + 0;

    idle_delta = idle2 - idle1;
    total_delta = total2 - total1;
    steal_delta = steal2 - steal1;
    iowait_delta = iowait2 - iowait1;

    if (total_delta == 0) {
        print "0.0 0.0 0.0";
    } else {
        cpu_pct = (1.0 - idle_delta / total_delta) * 100;
        steal_pct = (steal_delta / total_delta) * 100;
        iowait_pct = (iowait_delta / total_delta) * 100;
        printf "%.1f %.1f %.1f", cpu_pct, steal_pct, iowait_pct;
    }
}')
cpu=$(echo "$cpu_steal_out" | awk '{print $1}')
cpu_steal=$(echo "$cpu_steal_out" | awk '{print $2}')
iowait=$(echo "$cpu_steal_out" | awk '{print $3}')

# 2. RAM Usage (%)
ram=$(awk '
/^MemTotal:/ { total=$2 }
/^MemFree:/ { free=$2 }
/^Buffers:/ { buffers=$2 }
/^Cached:/ { cached=$2 }
/^MemAvailable:/ { avail=$2 }
END {
    if (!avail) {
        avail = free + buffers + cached;
    }
    used = total - avail;
    if (total == 0) {
        print 0.0;
    } else {
        printf "%.1f", (used / total) * 100;
    }
}' /proc/meminfo)

# 2.5 Swap Usage (%)
swap=$(awk '
/^SwapTotal:/ { total=$2 }
/^SwapFree:/ { free=$2 }
END {
    if (!total || total == 0) {
        print 0.0;
    } else {
        printf "%.1f", ((total - free) / total) * 100;
    }
}' /proc/meminfo)

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
    hdd=0.0
fi

# 3.05 Inode Usage (%) - stejný df, jen s -i (inode počty místo bloků)
inode_usage=$(df -iP / 2>/dev/null | tail -n 1 | awk '{print $5}' | tr -d '%')
inode_usage_json="null"
if [ -n "$inode_usage" ]; then
    inode_usage_json="$inode_usage"
fi

# 3.1 Disk I/O (KB/s čtení/zápis) - stejný tick/tock princip jako propustnost sítě níže.
# /proc/diskstats je celojaderný čítač (ne per-pid-namespace), funguje i v Dockeru s pid: host.
disk_sectors=$(awk '
$3 ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+)$/ {
    read_total += $6;
    write_total += $10;
}
END { printf "%.0f,%.0f", read_total+0, write_total+0 }
' /proc/diskstats 2>/dev/null)
if [ -z "$disk_sectors" ]; then
    disk_sectors="0,0"
fi
disk_read_sectors=$(echo "$disk_sectors" | cut -d',' -f1)
disk_write_sectors=$(echo "$disk_sectors" | cut -d',' -f2)

disk_io_read=""
disk_io_write=""
now_ts_io=$(date +%s)
if [ -f "$DISKIO_STATE_FILE" ]; then
    prev_io_ts=$(cut -d',' -f1 "$DISKIO_STATE_FILE" 2>/dev/null)
    prev_read=$(cut -d',' -f2 "$DISKIO_STATE_FILE" 2>/dev/null)
    prev_write=$(cut -d',' -f3 "$DISKIO_STATE_FILE" 2>/dev/null)
    if [ -n "$prev_io_ts" ] && [ -n "$prev_read" ] && [ -n "$prev_write" ]; then
        elapsed_io=$((now_ts_io - prev_io_ts))
        delta_read=$((disk_read_sectors - prev_read))
        delta_write=$((disk_write_sectors - prev_write))
        if [ "$elapsed_io" -gt 0 ] && [ "$delta_read" -ge 0 ] && [ "$delta_write" -ge 0 ]; then
            disk_io_read=$(awk -v d="$delta_read" -v e="$elapsed_io" 'BEGIN { printf "%.1f", (d * 512 / e) / 1024 }')
            disk_io_write=$(awk -v d="$delta_write" -v e="$elapsed_io" 'BEGIN { printf "%.1f", (d * 512 / e) / 1024 }')
        fi
    fi
fi
echo "$now_ts_io,$disk_read_sectors,$disk_write_sectors" > "$DISKIO_STATE_FILE" 2>/dev/null || true
disk_io_read_json="null"
[ -n "$disk_io_read" ] && disk_io_read_json="$disk_io_read"
disk_io_write_json="null"
[ -n "$disk_io_write" ] && disk_io_write_json="$disk_io_write"

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
if [ -z "$net_stats" ]; then
    net_stats="0,0"
fi
net_bytes=$(echo "$net_stats" | cut -d',' -f1)
net_errs_total=$(echo "$net_stats" | cut -d',' -f2)

net=""
net_errors=""
now_ts=$(date +%s)
if [ -f "$NET_STATE_FILE" ]; then
    prev_ts=$(cut -d',' -f1 "$NET_STATE_FILE" 2>/dev/null)
    prev_bytes=$(cut -d',' -f2 "$NET_STATE_FILE" 2>/dev/null)
    prev_errs=$(cut -d',' -f3 "$NET_STATE_FILE" 2>/dev/null)
    if [ -n "$prev_ts" ] && [ -n "$prev_bytes" ] && [ "$net_bytes" -gt 0 ]; then
        elapsed=$((now_ts - prev_ts))
        delta=$((net_bytes - prev_bytes))
        if [ "$elapsed" -gt 0 ] && [ "$delta" -ge 0 ]; then
            net=$(awk -v d="$delta" -v e="$elapsed" 'BEGIN { printf "%.1f", (d / e) / 1024 }')
        fi
        if [ -n "$prev_errs" ]; then
            delta_errs=$((net_errs_total - prev_errs))
            [ "$delta_errs" -ge 0 ] && net_errors="$delta_errs"
        fi
    fi
fi
echo "$now_ts,$net_bytes,$net_errs_total" > "$NET_STATE_FILE" 2>/dev/null || true

net_json="null"
if [ -n "$net" ]; then
    net_json="$net"
fi
net_errors_json="null"
if [ -n "$net_errors" ]; then
    net_errors_json="$net_errors"
fi

# 3.6 Fork rate - nové procesy od posledního běhu (delta, ne rychlost za sekundu).
# /proc/stat řádek "processes" je kumulativní čítač forků od bootu.
total_forks=$(awk '/^processes / { print $2 }' /proc/stat 2>/dev/null)
fork_rate_json="null"
if [ -n "$total_forks" ]; then
    if [ -f "$FORKRATE_STATE_FILE" ]; then
        prev_forks=$(cat "$FORKRATE_STATE_FILE" 2>/dev/null)
        if [ -n "$prev_forks" ]; then
            delta_forks=$((total_forks - prev_forks))
            [ "$delta_forks" -ge 0 ] && fork_rate_json="$delta_forks"
        fi
    fi
    echo "$total_forks" > "$FORKRATE_STATE_FILE" 2>/dev/null || true
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

# 3.8 Systémová identita (hostname/kernel/timezone/reboot-required/virtualizace/cloud)
sys_hostname=$(hostname 2>/dev/null || echo "")
sys_kernel=$(uname -r 2>/dev/null || echo "")
sys_timezone=""
if [ -f /etc/timezone ]; then
    sys_timezone=$(cat /etc/timezone 2>/dev/null)
elif [ -L /etc/localtime ]; then
    sys_timezone=$(readlink /etc/localtime 2>/dev/null | sed 's#.*zoneinfo/##')
fi
reboot_required_json="false"
[ -f /var/run/reboot-required ] && reboot_required_json="true"
virtualization_json="null"
if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt=$(systemd-detect-virt 2>/dev/null)
    [ -n "$virt" ] && [ "$virt" != "none" ] && virtualization_json="\"$virt\""
fi
cloud_provider_json="null"
dmi_text=""
for dmi_file in /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/bios_vendor; do
    [ -r "$dmi_file" ] && dmi_text="$dmi_text $(cat "$dmi_file" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
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

# 4. Uptime (sekundy)
uptime=0
if [ -f /proc/uptime ]; then
    uptime=$(cat /proc/uptime | awk '{print int($1)}')
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
        for d in $drives; do
            if ! smartctl -H "/dev/$d" 2>/dev/null | grep -q "PASSED"; then
                echo "WARNING (Disk /dev/$d selhal v SMART)"
                return
            fi
        done
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
smart=$(get_smart_status)

# 6. Aktivní naslouchající porty
ports_list=""
if [ -f /proc/net/tcp ]; then
    ports_raw=$(awk '
    NR > 1 && ($4 == "0A" || $4 == "07") {
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
    }' /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null | sort -un)
    
    for p in $ports_raw; do
        if [ -z "$ports_list" ]; then
            ports_list="$p"
        else
            ports_list="$ports_list, $p"
        fi
    done
fi

ports_json=""
IFS=',' read -r -a ports_arr <<< "$ports_list"
for p in "${ports_arr[@]}"; do
    p_trim=$(echo -n "$p" | tr -d '[:space:]')
    if [ -n "$p_trim" ]; then
        if [ -z "$ports_json" ]; then
            ports_json="$p_trim"
        else
            ports_json="$ports_json, $p_trim"
        fi
    fi
done

# 7. Běžící procesy
process_list=""
while read -r proc; do
    proc_clean=$(echo -n "$proc" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if [ -n "$proc_clean" ]; then
        if [ -z "$process_list" ]; then
            process_list="\"$proc_clean\""
        else
            process_list="$process_list, \"$proc_clean\""
        fi
    fi
done <<EOF
$(ps -eo comm 2>/dev/null | tail -n +2 | sort -u)
EOF

# 7.1 Zombie procesy a TOP RAM procesy (přes 'ps', stejná závislost jako výše).
# TOP CPU procesy se v bash verzi nepočítají - přesné "právě teď" řazení by
# vyžadovalo dvojité procházení /proc pro každý PID (drahé/pomalé v shellu);
# pro plný přehled procesů použijte Python agenta. Zombie a TOP RAM jsou levné
# (jeden běh 'ps'), proto zůstávají i v bash verzi.
zombie_count_json="null"
zc=$(ps -eo stat= 2>/dev/null | grep -c '^Z')
[ -n "$zc" ] && zombie_count_json="$zc"

top_ram_json=""
while read -r rline; do
    [ -z "$rline" ] && continue
    rname=$(echo "$rline" | awk '{print $1}')
    rrss_kb=$(echo "$rline" | awk '{print $2}')
    [ -z "$rrss_kb" ] && continue
    rname_clean=$(echo -n "$rname" | sed 's/\\/\\\\/g; s/"/\\"/g')
    rram_mb=$(awk -v k="$rrss_kb" 'BEGIN { printf "%.1f", k/1024 }')
    if [ -n "$top_ram_json" ]; then
        top_ram_json="$top_ram_json, "
    fi
    top_ram_json="$top_ram_json{\"name\": \"$rname_clean\", \"ram_mb\": $rram_mb}"
done <<EOF
$(ps -eo comm,rss --sort=-rss 2>/dev/null | tail -n +2 | head -n 5)
EOF

# 7.5 Zjištění TeamSpeak statistik (telnet query na localhost)
ts3_json_list=""
for q_port in 10011 8219; do
    # Kontrola zda port naslouchá
    if [[ ", $ports_json," =~ ", $q_port," ]] || [[ "$ports_json" =~ ^$q_port, ]] || [[ "$ports_json" =~ ,$q_port$ ]] || [ "$ports_json" = "$q_port" ]; then
        if exec 3<>/dev/tcp/127.0.0.1/$q_port; then
            read -r line <&3
            read -r line <&3
            echo -e "serverlist\nquit" >&3
            
            response=""
            while read -r line <&3; do
                response="$response $line"
                if [[ "$line" =~ error\ id= ]]; then
                    break
                fi
            done
            exec 3>&-
            
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
                        if exec 3<>/dev/tcp/127.0.0.1/$q_port; then
                            read -r line <&3
                            read -r line <&3
                            echo -e "use port=$v_port\nserverinfo\nquit" >&3
                            
                            response=""
                            while read -r line <&3; do
                                response="$response $line"
                                if [[ "$line" =~ error\ id= ]]; then
                                    break
                                fi
                            done
                            exec 3>&-
                            
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
if command -v pgrep >/dev/null 2>&1; then
    ts3_pid=$(pgrep -x ts3server | head -n1)
else
    for p in /proc/[0-9]*; do
        if [ -r "$p/comm" ] && [ "$(cat "$p/comm" 2>/dev/null)" = "ts3server" ]; then
            ts3_pid=$(basename "$p")
            break
        fi
    done
fi

ts3_process_json="null"
if [ -n "$ts3_pid" ] && [ -d "/proc/$ts3_pid" ]; then
    clk_tck=$(getconf CLK_TCK 2>/dev/null || echo 100)
    read_ts3_stat() {
        raw=$(cat "/proc/$ts3_pid/stat" 2>/dev/null)
        echo "$raw" | sed 's/^[0-9]* (.*) //'
    }
    ts3_stat1=$(read_ts3_stat)
    sleep 1
    ts3_stat2=$(read_ts3_stat)

    ts3_cpu=$(awk -v s1="$ts3_stat1" -v s2="$ts3_stat2" -v tck="$clk_tck" '
    BEGIN {
        n1 = split(s1, a1);
        n2 = split(s2, a2);
        if (n1 < 13 || n2 < 13) { print 0.0; exit; }
        delta = (a2[12] + a2[13]) - (a1[12] + a1[13]);
        if (tck == 0) tck = 100;
        printf "%.1f", (delta / tck) * 100;
    }')

    ts3_uptime=0
    if [ -f /proc/uptime ] && [ -n "$ts3_stat2" ]; then
        host_uptime=$(awk '{print $1}' /proc/uptime)
        ts3_uptime=$(awk -v s2="$ts3_stat2" -v hu="$host_uptime" -v tck="$clk_tck" '
        BEGIN {
            n2 = split(s2, a2);
            if (n2 < 20) { print 0; exit; }
            if (tck == 0) tck = 100;
            u = hu - (a2[20] / tck);
            if (u < 0) u = 0;
            printf "%.0f", u;
        }')
    fi

    ts3_ram_mb="0"
    ts3_threads="0"
    if [ -f "/proc/$ts3_pid/status" ]; then
        ts3_ram_mb=$(awk '/^VmRSS:/ { printf "%.1f", $2/1024 }' "/proc/$ts3_pid/status")
        ts3_threads=$(awk '/^Threads:/ { print $2 }' "/proc/$ts3_pid/status")
    fi
    [ -z "$ts3_ram_mb" ] && ts3_ram_mb="0"
    [ -z "$ts3_threads" ] && ts3_threads="0"

    ts3_fds="0"
    if [ -d "/proc/$ts3_pid/fd" ]; then
        ts3_fds=$(ls "/proc/$ts3_pid/fd" 2>/dev/null | wc -l | tr -d ' ')
    fi

    ts3_process_json="{\"pid\": $ts3_pid, \"cpu\": $ts3_cpu, \"ram_mb\": $ts3_ram_mb, \"threads\": $ts3_threads, \"open_fds\": $ts3_fds, \"uptime_sec\": $ts3_uptime}"
fi

# 7.7 Service Discovery - detekce běžících služeb (process + port + config + active)
discovered_json=""
detect_svc() {
    local name="$1" stype="$2" port="$3" proc="$4" cfg="$5"
    local conf=0 ev="" miss=""
    # Process (30)
    if [ -n "$proc" ] && echo ",$process_list," | grep -qi ",$proc,"; then
        conf=$((conf+30)); ev="${ev}\"process\","
    elif [ -n "$proc" ]; then miss="${miss}\"process\","; fi
    # Port (25)
    if [ -n "$port" ] && echo ",$ports_json," | grep -q ", $port,"; then
        conf=$((conf+25)); ev="${ev}\"port\","
    elif [ -n "$port" ]; then miss="${miss}\"port\","; fi
    # Config (25)
    if [ -n "$cfg" ] && [ -e "$cfg" ]; then
        conf=$((conf+25)); ev="${ev}\"config\","
    elif [ -n "$cfg" ]; then miss="${miss}\"config\","; fi
    # Active (19) - port listening = active
    if [ -n "$port" ] && echo ",$ports_json," | grep -q ", $port,"; then
        conf=$((conf+19)); ev="${ev}\"active_verify\","
    else miss="${miss}\"active_verify\","; fi
    [ $conf -gt 99 ] && conf=99
    [ $conf -lt 25 ] && return
    ev="${ev%,}"; miss="${miss%,}"
    local entry="{\"name\": \"$name\", \"type\": \"$stype\", \"port\": ${port:-null}, \"confidence\": $conf, \"evidence\": [$ev], \"missing\": [$miss]}"
    if [ -z "$discovered_json" ]; then discovered_json="$entry"; else discovered_json="$discovered_json, $entry"; fi
}
detect_svc "TeamSpeak" "teamspeak" 10011 "ts3server" ""
detect_svc "Minecraft" "minecraft" 25565 "java" ""
detect_svc "Nginx" "nginx" 80 "nginx" "/etc/nginx/nginx.conf"
detect_svc "Docker" "docker" "" "dockerd" "/var/run/docker.sock"
detect_svc "PostgreSQL" "postgresql" 5432 "postgres" "/etc/postgresql"
detect_svc "AdGuard Home" "adguard" 3000 "AdGuardHome" ""
detect_svc "WireGuard" "wireguard" 51820 "" "/etc/wireguard"
detect_svc "Mosquitto" "mosquitto" 1883 "mosquitto" "/etc/mosquitto/mosquitto.conf"

# 8. Sestavení JSON payloadu
payload=$(cat <<EOF
{
  "agent_key": "$AGENT_KEY",
  "agent_type": "bash",
  "version": "$AGENT_VERSION",
  "os": "$os_version",
  "cpu": $cpu,
  "cpu_steal": $cpu_steal,
  "iowait": $iowait,
  "ram": $ram,
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
  "uptime": $uptime,
  "smart": "$smart",
  "ports": [$ports_json],
  "processes": [$process_list],
  "teamspeak_servers": [$ts3_json_list],
  "ts3_process": $ts3_process_json,
  "zombie_count": $zombie_count_json,
  "top_cpu_processes": null,
  "top_ram_processes": [$top_ram_json],
  "hostname": "$sys_hostname",
  "kernel": "$sys_kernel",
  "timezone": "$sys_timezone",
  "reboot_required": $reboot_required_json,
  "cloud_provider": $cloud_provider_json,
  "virtualization": $virtualization_json,
  "discovered_services": [$discovered_json]
}
EOF
)

net_log="N/A (první běh)"
if [ -n "$net" ]; then
    net_log="${net} KB/s"
fi
log_message "Metriky - OS: $os_version, CPU: $cpu% (steal $cpu_steal%), RAM: $ram% (swap $swap%), HDD: $hdd%, Load: $load1/$load5/$load15, Síť: $net_log, Uptime: ${uptime}s, SMART: $smart, Porty: [$ports_json]"
log_message "Odesílám data na $API_URL..."

http_code=""
body=""

if command -v curl >/dev/null 2>&1; then
    response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d "$payload" "$API_URL")
    http_code=$(echo "$response" | tail -n 1)
    body=$(echo "$response" | head -n -1)
elif command -v wget >/dev/null 2>&1; then
    headers_file=$(mktemp /tmp/status-wget-hdr.XXXXXX 2>/dev/null || echo "/tmp/status-wget-hdr-$$")
    body=$(wget --post-data="$payload" --header="Content-Type: application/json" --server-response -q -O - "$API_URL" 2>"$headers_file")
    http_code=$(grep -E '^[[:space:]]*HTTP/' "$headers_file" | tail -n 1 | awk '{print $2}')
    rm -f "$headers_file"
else
    log_message "CHYBA: Není nainstalován ani 'curl' ani 'wget'. Nelze odeslat data."
    exit 1
fi

if [ "$http_code" = "200" ]; then
    log_message "OK: Statistiky úspěšně odeslány."
    log_message "Odpověď: $body"
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
                curl -fsS -o "$tmp_file" "$update_url" && download_ok=1
            elif command -v wget >/dev/null 2>&1; then
                wget -q -O "$tmp_file" "$update_url" && download_ok=1
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
