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

AGENT_VERSION="1.3.0"
LOG_FILE="$ScriptPath/agent.log"

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

cpu=$(awk -v s1="$stat1" -v s2="$stat2" '
BEGIN {
    split(s1, a1);
    split(s2, a2);
    
    idle1 = a1[5] + a1[6];
    total1 = a1[2]+a1[3]+a1[4]+a1[5]+a1[6]+a1[7]+a1[8];
    
    idle2 = a2[5] + a2[6];
    total2 = a2[2]+a2[3]+a2[4]+a2[5]+a2[6]+a2[7]+a2[8];
    
    idle_delta = idle2 - idle1;
    total_delta = total2 - total1;
    
    if (total_delta == 0) {
        print 0.0;
    } else {
        printf "%.1f", (1.0 - idle_delta / total_delta) * 100;
    }
}')

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

# 3. HDD Usage (%)
hdd=$(df -P / | tail -n 1 | awk '{print $5}' | tr -d '%')
if [ -z "$hdd" ]; then
    hdd=0.0
fi

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
    NR > 1 && $4 == "0A" {
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
    }' /proc/net/tcp /proc/net/tcp6 2>/dev/null | sort -un)
    
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

# 8. Sestavení JSON payloadu
payload=$(cat <<EOF
{
  "agent_key": "$AGENT_KEY",
  "agent_type": "bash",
  "version": "$AGENT_VERSION",
  "os": "$os_version",
  "cpu": $cpu,
  "ram": $ram,
  "hdd": $hdd,
  "uptime": $uptime,
  "smart": "$smart",
  "ports": [$ports_json],
  "processes": [$process_list],
  "teamspeak_servers": [$ts3_json_list]
}
EOF
)

log_message "Metriky - OS: $os_version, CPU: $cpu%, RAM: $ram%, HDD: $hdd%, Uptime: ${uptime}s, SMART: $smart, Porty: [$ports_json]"
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
