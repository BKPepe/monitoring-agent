#!/bin/sh
# Blood Kings Status Monitoring - OpenWrt/TurrisOS Agent (ash + ubus)
#
# Spouštějte na routeru přes cron (crond je součástí základní instalace
# OpenWrt/TurrisOS). Nevyžaduje bash ani Python - jen standardní BusyBox ash,
# ubus/jshn (obojí je součástí libubox, tedy všude, kde běží ubus samotné) a
# curl / uclient-fetch / wget (stačí jeden z nich).
#
# Board metriky (CPU/RAM/load/uptime/teplota) čtou stejná /proc a /sys
# rozhraní jako agent.sh - jsou to jaderná rozhraní nezávislá na tom, jestli
# userland je BusyBox nebo GNU coreutils. Identitu routeru a stav WAN
# rozhraní naopak čte přes ubus, protože to (na rozdíl od /proc) nemá čistou
# univerzální alternativu - to je specifika, kterou VPS agent nemá.

# === VÝCHOZÍ KONFIGURACE ===
# Hodnoty můžete nechat zde, nebo vytvořit soubor 'agent_openwrt.cfg' ve stejné složce.
API_URL="http://localhost/status/agent_api.php"
AGENT_KEY="ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE"
AUTO_UPDATE="0" # Nastavte na "1" pro povolení automatických aktualizací agenta ze serveru
HEAVY_OP_INTERVAL_HOURS="24" # Interval pro náročné operace (opkg, detekce služeb) v hodinách (výchozí 24h)
# ===========================

if [ -n "$STATUS_API_URL" ]; then
    API_URL="$STATUS_API_URL"
fi
if [ -n "$STATUS_AGENT_KEY" ]; then
    AGENT_KEY="$STATUS_AGENT_KEY"
fi
if [ -n "$STATUS_AUTO_UPDATE" ]; then
    AUTO_UPDATE="$STATUS_AUTO_UPDATE"
fi
if [ -n "$STATUS_HEAVY_OP_INTERVAL_HOURS" ]; then
    HEAVY_OP_INTERVAL_HOURS="$STATUS_HEAVY_OP_INTERVAL_HOURS"
fi

ScriptPath=$(dirname "$0")

if [ -f "$ScriptPath/agent_openwrt.cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | tr -d '\r')
        case "$line" in
            \#*|"") continue ;;
        esac
        case "$line" in
            *=*)
                key=$(echo "${line%%=*}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                val=$(echo "${line#*=}" | sed "s/^[[:space:]]*//;s/[[:space:]]*\$//;s/^[\"']//;s/[\"']\$//")
                case "$key" in
                    API_URL) API_URL="$val" ;;
                    AGENT_KEY) AGENT_KEY="$val" ;;
                    AUTO_UPDATE) AUTO_UPDATE="$val" ;;
                    HEAVY_OP_INTERVAL_HOURS) HEAVY_OP_INTERVAL_HOURS="$val" ;;
                    REMOTE_ACTIONS_ENABLED) REMOTE_ACTIONS_ENABLED="$val" ;;
                    ALLOWED_ACTIONS) ALLOWED_ACTIONS="$val" ;;
                esac
                ;;
        esac
    done < "$ScriptPath/agent_openwrt.cfg"
fi

HEAVY_OP_INTERVAL_SEC=$(( ${HEAVY_OP_INTERVAL_HOURS:-24} * 3600 ))

if [ "$1" = "--register" ] || [ "$1" = "--auto-register" ]; then
    REG_TOKEN="$2"
    if [ -z "$REG_TOKEN" ]; then
        echo "Pouziti: $0 --register REGISTRATION_TOKEN [API_URL]"
        exit 1
    fi
    if [ -n "$3" ]; then
        API_URL="$3"
    fi
    HOSTNAME_VAL=$(uname -n 2>/dev/null || echo "OpenWrt-Router")
    echo "Registruji router na $API_URL..."
    FETCH_CMD="curl -s -X POST -H 'Content-Type: application/json' -d \"{\\\"action\\\":\\\"register\\\", \\\"token\\\":\\\"$REG_TOKEN\\\", \\\"hostname\\\":\\\"$HOSTNAME_VAL\\\", \\\"agent_type\\\":\\\"openwrt\\\"}\" \"$API_URL\""
    RESP=$(eval "$FETCH_CMD")
    NEW_KEY=$(echo "$RESP" | sed -n 's/.*"agent_key":"\([^"]*\)".*/\1/p')
    if [ -n "$NEW_KEY" ]; then
        echo "API_URL=\"$API_URL\"" > "$ScriptPath/agent_openwrt.cfg"
        echo "AGENT_KEY=\"$NEW_KEY\"" >> "$ScriptPath/agent_openwrt.cfg"
        echo "OK: Router zaregistrovan a ulozen do $ScriptPath/agent_openwrt.cfg (AGENT_KEY=$NEW_KEY)"
        exit 0
    else
        echo "CHYBA pri registraci: $RESP"
        exit 1
    fi
fi

AGENT_VERSION="0.1.0"
LOG_FILE="/tmp/status-agent-openwrt.log"
CPU_STATE_FILE="/tmp/status-agent-openwrt-cpu.state"
NET_STATE_FILE="/tmp/status-agent-openwrt-net.state"

VERBOSE="0"
[ -t 1 ] && VERBOSE="1"
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "OpenWrt Status Agent v$AGENT_VERSION"
            echo "Pouziti: $0 [MOZNOSTI]"
            echo ""
            echo "Moznosti:"
            echo "  --register TOKEN [API_URL]   Zaregistruje router na zadany monitoring server"
            echo "  --update, --auto-update      Vynuti kontrolu a aktualizaci agenta ze serveru"
            echo "  --verbose, -v                Zobrazi podrobny prubeh sberu dat a odesilani"
            echo "  --dry-run, --print           Sesbira data a vypise JSON, neodesila (i bez registrace)"
            echo "  --version, -V                Zobrazi verzi agenta"
            echo "  --help, -h                   Zobrazi tuto napovedu"
            echo ""
            echo "Konfigurace:"
            echo "  Cte nastaveni ze souboru agent_openwrt.cfg nebo z promendych prostredi:"
            echo "  STATUS_API_URL, STATUS_AGENT_KEY, STATUS_AUTO_UPDATE, STATUS_HEAVY_OP_INTERVAL_HOURS"
            exit 0
            ;;
        --version|-V)
            echo "OpenWrt Status Agent v$AGENT_VERSION"
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
            # Sesbira vsechno a vypise JSON misto odeslani.
            #
            # Vzniklo pri porovnavani Turrisu s cistym OpenWrt: na novem
            # routeru clovek potrebuje videt, co agent nasbira, JESTE NEZ ho
            # zaregistruje na server. Bez toho se musi nejdriv nasadit naostro
            # a teprve pak zjistit, ze polovina hodnot je prazdna.
            DRY_RUN="1"
            VERBOSE="1"
            ;;
    esac
done

# Automatické vyčištění starých logů z flash paměti (/root) pro prevenci opotřebení disku
for old_log in "$ScriptPath/agent_openwrt.log" "$ScriptPath/agent.log" /root/agent_openwrt.log /root/agent.log /root/status-agent-openwrt.log; do
    if [ -f "$old_log" ] && [ "$old_log" != "$LOG_FILE" ]; then
        rm -f "$old_log" 2>/dev/null || true
    fi
done

# Pri zmene verze agenta se zahodi vsechny cache narocnych operaci.
#
# Detekce sluzeb, seznam balicku a identita se cachuji az 24 hodin. Po
# aktualizaci agenta to znamena, ze oprava v tehle casti kodu se projevi
# nejdriv za den - a do te doby to vypada, ze nefunguje.
#
# Presne to se stalo pri opravce Wi-Fi detekce: router hlasil "Hostapd Wi-Fi
# AP" i po aktualizaci, protoze seznam sluzeb cetl z cache, kterou zapsala
# stara verze. Hodinu jsme hledali chybu v kodu, ktery uz byl spravne.
BK_VERSION_STAMP="/tmp/status-agent-openwrt-version.stamp"
if [ "$(cat "$BK_VERSION_STAMP" 2>/dev/null)" != "$AGENT_VERSION" ]; then
    rm -f /tmp/status-agent-openwrt-identity.cache \
          /tmp/status-agent-openwrt-opkg.cache \
          /tmp/status-agent-openwrt-services.cache 2>/dev/null || true
    echo "$AGENT_VERSION" > "$BK_VERSION_STAMP" 2>/dev/null || true
fi

json_str() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g' | tr '\n' ' '
}

# Vypise JSON hodnotu: bud null (bez uvozovek), nebo uvozovkovany retezec.
#
# Vzniklo kvuli LTE: prazdna hodnota se v tomhle skriptu drzi jako retezec
# "null" a `"$(json_str "$v")"` z ni udelal RETEZEC "null", takze UI
# poctive vypsalo `null · "null"` misto pomlcky.
json_val() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then
        printf 'null'
    else
        printf '"%s"' "$(json_str "$1")"
    fi
}

log_message() {
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$VERBOSE" = "1" ]; then
        echo "$ts - $1"
    fi
    echo "$ts - $1" >> "$LOG_FILE" 2>/dev/null || echo "$ts - $1" >> /tmp/status-agent-openwrt.log 2>/dev/null || true
}

log_debug() {
    log_message "$1"
}

# V rezimu --dry-run se klic nekontroluje: smysl toho rezimu je podivat se,
# co agent na novem routeru nasbira, jeste nez ho nekdo zaregistruje.
if [ "$AGENT_KEY" = "ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE" ] && [ "$DRY_RUN" != "1" ]; then
    log_message "CHYBA: Neni nastaven AGENT_KEY. Upravte skript nebo 'agent_openwrt.cfg'."
    exit 1
fi

if ! command -v ubus >/dev/null 2>&1; then
    log_message "CHYBA: 'ubus' neni k dispozici - tento skript je urcen pro OpenWrt/TurrisOS routery."
    exit 1
fi

JSHN="/usr/share/libubox/jshn.sh"
if [ ! -f "$JSHN" ]; then
    log_message "CHYBA: $JSHN nenalezen (soucast libubox, mel by byt pritomny vsude, kde je ubus)."
    exit 1
fi
. "$JSHN"

log_debug "Ziskavam statistiky routeru (OpenWrt agent v$AGENT_VERSION)..."

# --- 1. Board metriky - stejne /proc/techniky jako agent.sh ---

# CPU % pres dvouvzorkovy delta. Router bezi z cronu (ne kazdou sekundu jako
# s "sleep 1"), takze tick/tock stavovy soubor srovnava se vzorkem z
# predchoziho behu misto blokujiciho spani uvnitr skriptu.
cpu="null"
now_ts=$(date +%s)
stat_now=$(grep '^cpu ' /proc/stat)
if [ -f "$CPU_STATE_FILE" ]; then
    prev_stat=$(cut -d'|' -f2- "$CPU_STATE_FILE" 2>/dev/null)
    if [ -n "$prev_stat" ]; then
        cpu=$(awk -v s1="$prev_stat" -v s2="$stat_now" '
        BEGIN {
            split(s1, a1); split(s2, a2);
            idle1 = a1[5] + a1[6]; total1 = a1[2]+a1[3]+a1[4]+a1[5]+a1[6]+a1[7]+a1[8];
            idle2 = a2[5] + a2[6]; total2 = a2[2]+a2[3]+a2[4]+a2[5]+a2[6]+a2[7]+a2[8];
            idle_delta = idle2 - idle1; total_delta = total2 - total1;
            if (total_delta <= 0) { print "0.0"; } else {
                printf "%.1f", (1.0 - idle_delta / total_delta) * 100;
            }
        }')
    fi
fi
echo "${now_ts}|${stat_now}" > "$CPU_STATE_FILE" 2>/dev/null || true

# RAM % and MB breakdown - MemAvailable stejne jako moderni "free" (used = total - available),
# se zalohou na free+buffers+cached na starsich jadrech bez MemAvailable.
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

# Load average 1/5/15 - primo z /proc/loadavg, ne z ubus "system info" (ktere
# vraci stejna cisla, jen skalovana x65536 - zbytecna komplikace navic).
load1="null"; load5="null"; load15="null"
if [ -f /proc/loadavg ]; then
    load1=$(awk '{print $1}' /proc/loadavg)
    load5=$(awk '{print $2}' /proc/loadavg)
    load15=$(awk '{print $3}' /proc/loadavg)
fi

# Uptime (sekundy)
uptime_sec="null"
[ -f /proc/uptime ] && uptime_sec=$(awk '{printf "%d", $1}' /proc/uptime)

# Teplota (nejvyssi dostupna thermal zona) - volitelne, hodne routeru senzor nema.
temperature="null"
if [ -d /sys/class/thermal ]; then
    max_temp=$(for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] && cat "$z" 2>/dev/null
    done | awk '$1 > 0 && $1 < 150000 { if ($1 > max) max = $1 } END { if (max) print max }')
    [ -n "$max_temp" ] && temperature=$(awk -v m="$max_temp" 'BEGIN { printf "%.1f", m / 1000 }')
fi

# --- 2. Flash/Overlay - realny df, ne ubus "system info" root/tmp stanza.
# Na zarizenich s klasickym squashfs+overlay (vetsina beznych routeru) je
# zapisovatelna vrstva /overlay - tam se plni misto. Na zarizenich s jednim
# zapisovatelnym rootfs (napr. btrfs na Turris) /overlay neexistuje, pouzije
# se rovnou /. ---
df_target="/overlay"
[ -d "$df_target" ] || df_target="/"
hdd=$(df -P "$df_target" 2>/dev/null | tail -n 1 | awk '{gsub("%","",$5); print $5}')
# df selhal (chybejici mountpoint, prava) - nevime, ne "prazdny disk".
[ -z "$hdd" ] && hdd="null"

# --- 2b. Btrfs stav - jen zarizeni s btrfs (napr. Turris) ho maji, klasicky
# OpenWrt squashfs+jffs2/overlay btrfs vubec nezna a prikaz jen tise selze
# (zustane null). Soucet vsech 5 typu chyb pres vsechny disky v poli -
# 0 = zdrave, cokoli vic znamena problem se zapisem/ctenim/checksumy.
btrfs_errors="null"
if command -v btrfs >/dev/null 2>&1; then
    btrfs_out=$(btrfs device stats "$df_target" 2>/dev/null)
    if [ -n "$btrfs_out" ]; then
        btrfs_errors=$(echo "$btrfs_out" | awk '{sum += $NF} END {print sum+0}')
    fi
fi

# --- 2c. Flash Wear / Disk Write Rate (čte zapsané sektory z /proc/diskstats) ---
DISK_STATE_FILE="/tmp/status-agent-openwrt-disk.state"
disk_io_write="null"
if [ -f /proc/diskstats ]; then
    now_ts=$(date +%s)
    # Bez shodneho disku se nevypisuje nic (drive nula, kterou pak stejne
    # odfiltroval test -gt 0 nize - ale vzor svadel k opakovani jinde).
    # Jen cela zarizeni, ne jejich oddily.
    #
    # Bez kotvy sedel vzor i na mmcblk0p1, mmcblk0p2 a sda1 - jenze jadro
    # zapocitava I/O oddilu i do radku celeho disku, takze se stejny zapis
    # secetl dvakrat. Na routeru s aktivnim uloztem to bylo videt na prvni
    # pohled: souhrn 373,26 kB/s proti 186,6 kB/s u jedineho zapisujiciho
    # zarizeni, tedy presne dvojnasobek.
    #
    # Je to obracena chyba nez ta o par radku niz, kde kotva $ naopak vyhodila
    # mmcblk0 uplne. Obe vetve ted popisuji tutez mnozinu zarizeni.
    total_written_sectors=$(awk '$3 ~ /^(mtdblock[0-9]+|mmcblk[0-9]+|sd[a-z]|ubiblock[0-9_]+|nvme[0-9]+n[0-9]+|hd[a-z])$/ {sum += $10; n++} END {if (n>0) print sum}' /proc/diskstats 2>/dev/null)
    if [ -n "$total_written_sectors" ] && [ "$total_written_sectors" -gt 0 ]; then
        if [ -f "$DISK_STATE_FILE" ]; then
            prev_ts=$(awk '{print $1}' "$DISK_STATE_FILE" 2>/dev/null)
            prev_sec=$(awk '{print $2}' "$DISK_STATE_FILE" 2>/dev/null)
            if [ -n "$prev_ts" ] && [ -n "$prev_sec" ] && [ "$now_ts" -gt "$prev_ts" ]; then
                time_delta=$((now_ts - prev_ts))
                sec_delta=$((total_written_sectors - prev_sec))
                if [ "$sec_delta" -ge 0 ] && [ "$time_delta" -gt 0 ]; then
                    write_kb=$((sec_delta / 2))
                    disk_io_write=$(awk -v k="$write_kb" -v t="$time_delta" 'BEGIN {printf "%.2f", k / t}')
                fi
            fi
        fi
        echo "$now_ts $total_written_sectors" > "$DISK_STATE_FILE" 2>/dev/null || true
    fi
fi

# --- 3. Identita routeru (kešovaná v RAM pro eliminaci ubus volání a log spamu) ---
ID_CACHE_FILE="/tmp/status-agent-openwrt-identity.cache"
ow_hostname=""; ow_kernel=""; ow_model=""; ow_board_name=""; ow_distribution=""; ow_os_version=""; os_combined=""

if [ -f "$ID_CACHE_FILE" ]; then
    eval $(cat "$ID_CACHE_FILE" 2>/dev/null)
else
    board_json=$(ubus call system board 2>/dev/null)
    if [ -n "$board_json" ]; then
        json_load "$board_json"
        json_get_var ow_hostname hostname
        json_get_var ow_kernel kernel
        json_get_var ow_model model
        json_get_var ow_board_name board_name
        json_select release
        json_get_var ow_distribution distribution
        json_get_var ow_os_version version
        json_select ..
    fi
    os_combined="$ow_distribution $ow_os_version"
    printf "ow_hostname='%s'\now_kernel='%s'\now_model='%s'\now_board_name='%s'\now_distribution='%s'\now_os_version='%s'\nos_combined='%s'\n" \
        "$ow_hostname" "$ow_kernel" "$ow_model" "$ow_board_name" "$ow_distribution" "$ow_os_version" "$os_combined" > "$ID_CACHE_FILE" 2>/dev/null || true
    log_message "Načtena identita routeru: hostname=$ow_hostname model=$ow_model os=$os_combined kernel=$ow_kernel"
fi
log_debug "Identita: hostname=$ow_hostname model=$ow_model board=$ow_board_name os=$os_combined kernel=$ow_kernel"
# O btrfs se zminujeme jen tam, kde btrfs je.
#
# "btrfs_errors=null" na routeru s ext4 vypadalo jako chybejici udaj, i kdyz
# spravna odpoved zni "tenhle system btrfs nema". Stejny rozdil jako u Wi-Fi
# bez radia: nezmereno versus netyka se.
if [ "$btrfs_errors" != "null" ]; then
    log_debug "Uloziste: hdd=${hdd}% (${df_target}) btrfs_errors=$btrfs_errors"
else
    log_debug "Uloziste: hdd=${hdd}% (${df_target})"
fi

# --- 4. WAN stav (ubus network.interface.wan status) ---
wan_up="false"; wan_proto=""; wan_uptime="null"; wan_ipv4=""; wan_gateway=""; wan_dns=""; wan_l3_device=""
wan_json=$(ubus call network.interface.wan status 2>/dev/null)
if [ -n "$wan_json" ]; then
    json_load "$wan_json"
    json_get_var wan_up up
    json_get_var wan_proto proto
    json_get_var wan_uptime uptime
    json_get_var wan_l3_device l3_device

    # Prvni IPv4 adresa (pole "ipv4-address")
    json_get_keys ipv4_keys "ipv4-address"
    for k in $ipv4_keys; do
        json_select "ipv4-address"
        json_select "$k"
        json_get_var wan_ipv4 address
        json_select ..
        json_select ..
        break
    done

    # Brana - neni samostatne pole, dopocitava se z vychozi trasy (mask 0)
    json_get_keys route_keys route
    for k in $route_keys; do
        json_select route
        json_select "$k"
        r_mask=""
        json_get_var r_mask mask
        if [ "$r_mask" = "0" ]; then
            json_get_var wan_gateway nexthop
        fi
        json_select ..
        json_select ..
    done

    # DNS servery - pole retezcu, spojene carkou
    json_get_keys dns_keys "dns-server"
    for k in $dns_keys; do
        json_select "dns-server"
        json_get_var dns_entry "$k"
        json_select ..
        if [ -n "$dns_entry" ]; then
            if [ -n "$wan_dns" ]; then wan_dns="$wan_dns,$dns_entry"; else wan_dns="$dns_entry"; fi
        fi
    done
fi

# --- 4a. Vytizeni site (KB/s) - stejny tick/tock princip jako agent.sh, ale
# jen na WAN zarizeni (l3_device z ubus výše), ne soucet vsech rozhrani -
# u routeru by scitani LAN+WAN+WiFi davalo zavadejici cislo (provoz uvnitr
# domaci site by se zapocital jako "sitovy provoz", coz neni to, co chceme). ---
net="null"
if [ -n "$wan_l3_device" ] && [ -f /proc/net/dev ]; then
    net_bytes=$(awk -v iface="$wan_l3_device" '
    NR > 2 {
        line = $0;
        colon = index(line, ":");
        if (colon == 0) next;
        ifname = substr(line, 1, colon - 1);
        gsub(/^[ \t]+|[ \t]+$/, "", ifname);
        if (ifname != iface) next;
        n = split(substr(line, colon + 1), f, " ");
        printf "%.0f", (f[1] + 0) + (f[9] + 0);
    }' /proc/net/dev 2>/dev/null)
    if [ -n "$net_bytes" ]; then
        if [ -f "$NET_STATE_FILE" ]; then
            prev_ts=$(cut -d',' -f1 "$NET_STATE_FILE" 2>/dev/null)
            prev_bytes=$(cut -d',' -f2 "$NET_STATE_FILE" 2>/dev/null)
            if [ -n "$prev_ts" ] && [ -n "$prev_bytes" ]; then
                elapsed=$((now_ts - prev_ts))
                delta=$((net_bytes - prev_bytes))
                if [ "$elapsed" -gt 0 ] && [ "$delta" -ge 0 ]; then
                    net=$(awk -v d="$delta" -v e="$elapsed" 'BEGIN { printf "%.1f", (d / e) / 1024 }')
                fi
            fi
        fi
        echo "${now_ts},${net_bytes}" > "$NET_STATE_FILE" 2>/dev/null || true
    fi
fi

# --- 4a2. IPv4 vs IPv6 traffic counters (KB/s) ---
net_ipv4_kbps="null"
net_ipv6_kbps="null"
NET_IP_STATE_FILE="/tmp/status-agent-openwrt-net-ip.state"

v4_bytes=$(awk '/^IpExt:/ { if (hdr == "") { hdr = $0 } else { split(hdr, keys, " "); for (i = 2; i <= NF; i++) { if (keys[i] == "InOctets") in_b = $i; if (keys[i] == "OutOctets") out_b = $i; } } } END { print (in_b + out_b) + 0 }' /proc/net/netstat 2>/dev/null)
v6_bytes=$(awk '/^Ip6(In|Out)Octets/ { sum += $2 } END { print sum + 0 }' /proc/net/snmp6 2>/dev/null)

if [ -n "$v4_bytes" ] && [ "$v4_bytes" -gt 0 ]; then
    if [ -f "$NET_IP_STATE_FILE" ]; then
        prev_ts=$(cut -d',' -f1 "$NET_IP_STATE_FILE" 2>/dev/null)
        prev_v4=$(cut -d',' -f2 "$NET_IP_STATE_FILE" 2>/dev/null)
        prev_v6=$(cut -d',' -f3 "$NET_IP_STATE_FILE" 2>/dev/null)
        if [ -n "$prev_ts" ] && [ -n "$prev_v4" ] && [ "$now_ts" -gt "$prev_ts" ]; then
            elapsed=$((now_ts - prev_ts))
            d_v4=$((v4_bytes - prev_v4))
            d_v6=$((v6_bytes - prev_v6))
            if [ "$elapsed" -gt 0 ] && [ "$d_v4" -ge 0 ]; then
                net_ipv4_kbps=$(awk -v d="$d_v4" -v e="$elapsed" 'BEGIN { printf "%.1f", (d / e) / 1024 }')
            fi
            if [ "$elapsed" -gt 0 ] && [ "$d_v6" -ge 0 ]; then
                net_ipv6_kbps=$(awk -v d="$d_v6" -v e="$elapsed" 'BEGIN { printf "%.1f", (d / e) / 1024 }')
            fi
        fi
    fi
    echo "${now_ts},${v4_bytes},${v6_bytes}" > "$NET_IP_STATE_FILE" 2>/dev/null || true
fi

# --- 4b. Realna smerovatelna IPv6 - hleda se na samostatnem logickem rozhrani
# "wan6" (typicke pro PPPoE + DHCPv6-PD), protoze "wan" samo casto ma jen
# link-local fe80:: adresu, ktera pro verejne zobrazeni nema smysl. ---
wan_ipv6=""
dump_json=$(ubus call network.interface dump 2>/dev/null)
if [ -n "$dump_json" ]; then
    json_load "$dump_json"
    json_select interface
    json_get_keys iface_keys
    for k in $iface_keys; do
        json_select "$k"
        iface_name=""
        json_get_var iface_name interface
        if [ "$iface_name" = "wan6" ]; then
            json_get_keys v6_keys "ipv6-address"
            for vk in $v6_keys; do
                json_select "ipv6-address"
                json_select "$vk"
                candidate=""
                json_get_var candidate address
                json_select ..
                json_select ..
                case "$candidate" in
                    fe80:*) ;;
                    *) [ -z "$wan_ipv6" ] && wan_ipv6="$candidate" ;;
                esac
            done
        fi
        json_select ..
    done
    json_select ..
fi
log_debug "WAN: up=$wan_up proto=$wan_proto ipv4=$wan_ipv4 gateway=$wan_gateway dns=$wan_dns ipv6=$wan_ipv6 net=${net}KB/s (l3_device=$wan_l3_device)"

# --- 5. Sestaveni JSON payloadu ---
# jshn muze vracet bool jako "1"/"0" nebo "true"/"false" v zavislosti na
# verzi libubox - overujeme obe varianty, at se stav WAN nikdy tise neztrati.
case "$wan_up" in
    1|true) wan_up_json="true" ;;
    *) wan_up_json="false" ;;
esac

# --- Deep OpenWrt Telemetry ---
swap_pct=$(awk '/^SwapTotal:/ {total=$2} /^SwapFree:/ {free=$2} END { if (total > 0) printf "%.1f", ((total - free) / total) * 100; else print "0.0"; }' /proc/meminfo)
[ -z "$swap_pct" ] && swap_pct="null"

entropy="null"
[ -f /proc/sys/kernel/random/entropy_avail ] && entropy=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null)

# Pocet spojeni ma dve cesty a novejsi jadra znaji jen tu druhou.
#
# Procento se cetlo z /proc/net/nf_conntrack_count, zatimco samotny pocet o kus
# niz z /proc/sys/net/netfilter/nf_conntrack_count. Na OpenWrt SNAPSHOT
# (jadro 6.18) existuje jen ta sysctl varianta, takze router hlasil
# "conntrack_count: 24" a zaroven "conntrack_pct: null" - jedno cislo ze dvou
# mist, jedno z nich mrtve. Overeno na skutecnem routeru.
conntrack_pct="null"
conntrack_count_file=""
for _ctf in /proc/sys/net/netfilter/nf_conntrack_count /proc/net/nf_conntrack_count; do
    [ -f "$_ctf" ] && { conntrack_count_file="$_ctf"; break; }
done
if [ -n "$conntrack_count_file" ] && [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
    conntrack_pct=$(awk 'NR==1 {cnt=$1} END {if (getline < "/proc/sys/net/netfilter/nf_conntrack_max") {max=$1; if (max>0) printf "%.1f", (cnt/max)*100}}' "$conntrack_count_file" 2>/dev/null)
    # Prazdny vysledek zustava null. Nula by tvrdila "tabulka je prazdna",
    # coz je neco jineho nez "nepodarilo se to zjistit".
    case "$conntrack_pct" in
        ''|*[!0-9.]*) conntrack_pct="null" ;;
    esac
fi

# --- Upgradable & Installed Packages (cached for HEAVY_OP_INTERVAL_HOURS to avoid CPU/IO spikes) ---
upgradable_packages="null"
installed_packages="null"
OPKG_CACHE_FILE="/tmp/status-agent-openwrt-opkg.cache"
now_sec=$(date +%s)
opkg_cache_age=999999
if [ -f "$OPKG_CACHE_FILE" ]; then
    opkg_mtime=$(date -r "$OPKG_CACHE_FILE" +%s 2>/dev/null || echo 0)
    opkg_cache_age=$((now_sec - opkg_mtime))
fi

if [ $opkg_cache_age -lt $HEAVY_OP_INTERVAL_SEC ] && [ -f "$OPKG_CACHE_FILE" ]; then
    upgradable_packages=$(cut -d'|' -f1 "$OPKG_CACHE_FILE" 2>/dev/null)
    installed_packages=$(cut -d'|' -f2 "$OPKG_CACHE_FILE" 2>/dev/null)
else
    # OpenWrt 24.10 vymenilo opkg za apk (apk-tools 3).
    #
    # Overeno na snapshotu r0+35801: `command -v opkg` nevraci nic, `apk` ano.
    # Agent do ted znal jen opkg, takze na kazdem novejsim OpenWrt zustaly oba
    # pocty prazdne - a vypadalo to jako chybejici udaj, ne jako nepodporovany
    # spravce balicku.
    #
    # opkg zustava prvni kvuli starsim systemum, kde muze existovat oboji.
    if command -v opkg >/dev/null 2>&1; then
        upgradable_packages=$(opkg list-upgradable 2>/dev/null | wc -l | xargs)
        installed_packages=$(opkg list-installed 2>/dev/null | wc -l | xargs)
        echo "${upgradable_packages}|${installed_packages}" > "$OPKG_CACHE_FILE" 2>/dev/null || true
    elif command -v apk >/dev/null 2>&1; then
        # `apk list` pise hlavicku i prazdne radky, proto se pocitaji jen
        # radky zacinajici nazvem balicku.
        upgradable_packages=$(apk list --upgradable 2>/dev/null | grep -c '^[a-zA-Z0-9]' | xargs)
        installed_packages=$(apk list --installed 2>/dev/null | grep -c '^[a-zA-Z0-9]' | xargs)
        # Kazdy pocet se overuje zvlast - kdyz selze jen jeden prikaz, nema
        # to zneplatnit i ten druhy.
        #
        # Nula u nainstalovanych znamena selhani, ne prazdny system: router bez
        # jedineho balicku neexistuje. Nula u aktualizaci naopak znamena presne
        # to, co rika, a musi projit.
        case "$installed_packages" in
            ''|*[!0-9]*|0) installed_packages="null" ;;
        esac
        case "$upgradable_packages" in
            ''|*[!0-9]*) upgradable_packages="null" ;;
        esac
        if [ "$installed_packages" != "null" ]; then
            echo "${upgradable_packages}|${installed_packages}" > "$OPKG_CACHE_FILE" 2>/dev/null || true
        fi
    fi
fi

# Bez iwinfo se pocet klientu NEZJISTUJE - drive tu zustala nula, takze
# router bez iwinfo hlasil "0 pripojenych", i kdyz se na WiFi nikdo nedival.
wifi_clients_count="null"
if command -v iwinfo >/dev/null 2>&1; then
    wifi_clients_count=$(iwinfo 2>/dev/null | grep -i "assoc" | awk '{sum+=$NF; n++} END {if (n>0) print sum}')
    [ -z "$wifi_clients_count" ] && wifi_clients_count="null"
fi

interfaces_json="[]"
if [ -f /proc/net/dev ]; then
    interfaces_json=$(awk '
    NR > 2 {
        line = $0;
        colon = index(line, ":");
        if (colon > 0) {
            ifname = substr(line, 1, colon - 1);
            gsub(/^[ \t]+|[ \t]+$/, "", ifname);
            if (ifname !~ /^(lo|ifb)/) {
                split(substr(line, colon + 1), f, " ");
                rx_b = f[1] + 0;
                rx_p = f[2] + 0;
                rx_e = f[3] + 0;
                tx_b = f[9] + 0;
                tx_p = f[10] + 0;
                tx_e = f[11] + 0;
                if (count > 0) printf ", ";
                printf "{\"iface\":\"%s\",\"rx_bytes\":%.0f,\"tx_bytes\":%.0f,\"rx_packets\":%.0f,\"tx_packets\":%.0f,\"rx_errors\":%.0f,\"tx_errors\":%.0f}", ifname, rx_b, tx_b, rx_p, tx_p, rx_e, tx_e;
                count++;
            }
        }
    }
    BEGIN { printf "[" }
    END { printf "]" }' /proc/net/dev 2>/dev/null)
fi

# (Starší duplicitní bloky WiFi a LAN/DHCP odstraněny 2026-08-05 - jejich
#  výsledky vždy přepsala vylepšená verze níže, jen stály CPU navíc.)

# --- DNS (dnsmasq stats) ---
dns_queries="null"
dns_cache_hits="null"
dns_cache_misses="null"
if [ -f /tmp/dnsmasq.stats ]; then
    dns_queries=$(awk '/queries received/ {print $1}' /tmp/dnsmasq.stats 2>/dev/null)
    dns_cache_hits=$(awk '/cache hits/ {print $1}' /tmp/dnsmasq.stats 2>/dev/null)
    dns_cache_misses=$(awk '/cache misses/ {print $1}' /tmp/dnsmasq.stats 2>/dev/null)
elif pidof dnsmasq >/dev/null 2>&1; then
    kill -USR1 $(pidof dnsmasq) 2>/dev/null &
fi
[ -z "$dns_queries" ] && dns_queries="null"
[ -z "$dns_cache_hits" ] && dns_cache_hits="null"
[ -z "$dns_cache_misses" ] && dns_cache_misses="null"

# --- Firewall packet counters (iptables/nftables) ---
fw_accepted="null"
fw_dropped="null"
fw_rejected="null"
# Poznamka k "sum+0": puvodni verze vypisovala 0 i kdyz zadny radek
# neodpovidal, takze router bez iptables (firewall4/nftables) hlasil
# "0 zahozenych paketu" misto "nemerime". Ted se scita jen kdyz neco
# opravdu bylo - jinak zustava null.
# Secte pakety u pravidel s danym verdiktem. Komentar se zahazuje jeste pred
# rozborem: fw4 pise veci jako comment "!fw4: Drop excess packets", takze slovo
# "packets" v textu by jinak pricetlo, co za nim nahodou stoji.
# Pocita se jen "counter packets N" - pravidlo bez pocitadla zadne cislo nema.
_nft_verdict_packets() {
    nft list ruleset 2>/dev/null | awk -v want="$1" '
        {
            line = $0
            sub(/comment ".*/, "", line)
            nf = split(line, f, /[ \t]+/)
            hit = 0
            for (i = 1; i <= nf; i++) if (f[i] == want || f[i] == (want ";")) hit = 1
            if (!hit) next
            for (i = 2; i <= nf; i++) if (f[i] == "packets" && f[i-1] == "counter") { sum += f[i+1]; n++ }
        }
        END { if (n > 0) print sum }'
}

# Secte sloupec pkts u radku iptables s danym cilem (ACCEPT/DROP/REJECT).
_ipt_target_packets() {
    iptables -L FORWARD -v -n -x 2>/dev/null | awk -v want="$1" '
        $3 == want { sum += $1; n++ }
        END { if (n > 0) print sum }'
}

# Poradi je zamerne: nejdriv nft, teprve pak iptables.
#
# Na modernim OpenWrt (firewall4) drzi pravidla nftables, ale muze byt zaroven
# nainstalovana kompatibilni vrstva `iptables`, ktera o nich nevi a vypise
# prazdnou tabulku. Puvodni poradi proto na takovem routeru cetlo prazdno
# a firewall se netvaril, ze se nemeri - tvaril se, ze nic nezahazuje.
if command -v nft >/dev/null 2>&1 && [ -n "$(nft list ruleset 2>/dev/null | head -n 1)" ]; then
    fw_accepted=$(_nft_verdict_packets accept)
    fw_dropped=$(_nft_verdict_packets drop)
    fw_rejected=$(_nft_verdict_packets reject)
elif command -v iptables >/dev/null 2>&1; then
    fw_accepted=$(_ipt_target_packets ACCEPT)
    fw_dropped=$(_ipt_target_packets DROP)
    fw_rejected=$(_ipt_target_packets REJECT)
fi

# Bezi firewall vubec?
#
# Tenhle udaj agent nikdy neposilal, takze dlazdice "Firewall & NAT" v aplikaci
# hlasila "Neznamy stav" porad - i na routeru, ktery prave zahodil tri tisice
# paketu. Poradi zjistovani jde od nejsilnejsiho dukazu k nejslabsimu a kdyz
# nevyjde ani jeden, zustava null: "nevime" je jina informace nez "vypnuty".
firewall_enabled="null"
if command -v nft >/dev/null 2>&1 && [ -n "$(nft list tables 2>/dev/null | head -n 1)" ]; then
    # Nactena tabulka je dukaz, ze pravidla v jadre jsou.
    firewall_enabled="true"
elif command -v iptables >/dev/null 2>&1 && iptables -S 2>/dev/null | grep -q '^-'; then
    firewall_enabled="true"
elif [ -x /etc/init.d/firewall ]; then
    # Slabsi dukaz: sluzba je povolena k autostartu. Rika to, ze ma bezet,
    # ne ze bezi - proto az jako posledni.
    if /etc/init.d/firewall enabled 2>/dev/null; then
        firewall_enabled="true"
    else
        firewall_enabled="false"
    fi
fi

# Pojistka: do JSON se tahle pole vkladaji BEZ uvozovek, takze cokoli jineho
# nez cislo z nej udela neplatny dokument a server zahodi cele hlaseni - vcetne
# CPU, pameti a vseho ostatniho. Puvodni iptables vetev presne tohle delala:
# vypsala slovo "pkts" z hlavicky tabulky.
for _fw_var in fw_accepted fw_dropped fw_rejected; do
    eval "_fw_val=\$$_fw_var"
    case "$_fw_val" in
        ''|*[!0-9]*) eval "$_fw_var=null" ;;
    esac
done
[ -z "$fw_accepted" ] && fw_accepted="null"
[ -z "$fw_dropped" ] && fw_dropped="null"
[ -z "$fw_rejected" ] && fw_rejected="null"

# --- WireGuard peers (if wg command or wg0 interface exists) ---
wireguard_peers_json="[]"
if command -v wg >/dev/null 2>&1; then
    wg_dump=$(wg show all dump 2>/dev/null)
    if [ -n "$wg_dump" ]; then
        wireguard_peers_json=$(echo "$wg_dump" | awk '
        BEGIN { printf "[" }
        {
            if (count > 0) printf ", ";
            split($3, ep, ":");
            endpoint = ep[1];
            handshake = $5;
            rx = $6;
            tx = $7;
            printf "{\"interface\":\"%s\",\"public_key\":\"%s\",\"endpoint\":\"%s\",\"latest_handshake\":%s,\"rx_bytes\":%s,\"tx_bytes\":%s}", $1, substr($2,1,12)"...", endpoint, handshake, rx, tx;
            count++;
        }
        END { printf "]" }')
    fi
fi

# --- Vysledky mereni rychlosti (librespeed-cli) ---
#
# Router si vysledky odklada do /tmp/librespeed-data/<rok-mesic>/<cas>.json.
# /tmp je na OpenWrt ramdisk, takze po restartu je historie pryc - proto se
# posilaji na server, kde prezijou.
#
# Posila se jen to, co je novejsi nez posledni odeslany zaznam (stav v
# LIBRESPEED_STATE_FILE). Pri prvnim behu odejde cela dostupna historie,
# server si poradi s duplicitami sam (unikatni klic na cas mereni).
#
# Nazvy poli se u ruznych verzi librespeed lisi, proto se hleda vic variant.
# Rychlost muze byt v Mbit/s i v bajtech za sekundu - rozlisuje se podle
# radove velikosti, protoze 100 000 000 neni 100 Mbit/s zapsanych jinak,
# ale bajty.
LIBRESPEED_DIR="/tmp/librespeed-data"
LIBRESPEED_STATE_FILE="/tmp/status-agent-librespeed.state"
speedtests_json="[]"
if [ -d "$LIBRESPEED_DIR" ]; then
    last_sent=""
    [ -f "$LIBRESPEED_STATE_FILE" ] && last_sent=$(head -n 1 "$LIBRESPEED_STATE_FILE" 2>/dev/null)

    # Nejnovejsi soubory posledni - razeni podle nazvu funguje, protoze
    # jmeno je ISO cas.
    speed_files=$(find "$LIBRESPEED_DIR" -type f -name '*.json' 2>/dev/null | sort | tail -n 60)

    if [ -n "$speed_files" ]; then
        speedtests_json=$(
            printf '%s\n' "$speed_files" | while IFS= read -r f; do
                [ -f "$f" ] || continue
                # Cas mereni je v nazvu souboru (ISO 8601). printf zaruci, ze
                # kazdy zaznam skonci vlastnim radkem - jinak se obsahy
                # souboru slijou do jednoho a JSON se rozpadne.
                printf '%s|%s\n' "$(basename "$f" .json)" "$(tr -d '\n\r' < "$f")"
            done | awk -F'|' -v last_sent="$last_sent" '
                function num(s,   v) { v = s + 0; return v }
                function pick(json, keys,   i, n, arr, re, m) {
                    n = split(keys, arr, ",");
                    for (i = 1; i <= n; i++) {
                        re = "\"" arr[i] "\"[[:space:]]*:[[:space:]]*-?[0-9.]+";
                        if (match(json, re)) {
                            m = substr(json, RSTART, RLENGTH);
                            sub(/.*:[[:space:]]*/, "", m);
                            return m;
                        }
                    }
                    return "";
                }
                {
                    ts = $1;
                    # Zbytek radku je JSON; mohl obsahovat "|", proto se
                    # neskláda z $2, ale ze zbytku puvodniho radku.
                    body = substr($0, length(ts) + 2);

                    # Retezcove porovnani staci: nazev je ISO cas, ktery se
                    # radi stejne jako chronologicky.
                    if (last_sent != "" && ts <= last_sent) next;

                    dl = pick(body, "download,download_mbps,dl,downloadMbps");
                    ul = pick(body, "upload,upload_mbps,ul,uploadMbps");
                    pg = pick(body, "ping,ping_ms,latency");
                    ji = pick(body, "jitter,jitter_ms");
                    if (dl == "" && ul == "") next;

                    # Bajty za sekundu prevest na Mbit/s. Linka nad 1 Gbit/s
                    # by dala pres 1000, takze prah 1000 rozlisi jednotky.
                    if (dl != "" && num(dl) > 1000) dl = sprintf("%.2f", num(dl) * 8 / 1000000);
                    if (ul != "" && num(ul) > 1000) ul = sprintf("%.2f", num(ul) * 8 / 1000000);

                    printf "%s{\"timestamp\":\"%s\",\"download_mbps\":%s,\"upload_mbps\":%s,\"ping_ms\":%s,\"jitter_ms\":%s}",
                           (c++ ? "," : "["), ts,
                           (dl == "" ? "null" : dl), (ul == "" ? "null" : ul),
                           (pg == "" ? "null" : pg), (ji == "" ? "null" : ji);
                }
                END { printf "%s", (c ? "]" : "[]") }'
        )
        newest=$(printf '%s\n' "$speed_files" | tail -n 1)
        [ -n "$newest" ] && basename "$newest" .json > "$LIBRESPEED_STATE_FILE" 2>/dev/null
    fi
fi
[ -z "$speedtests_json" ] && speedtests_json="[]"

# --- Vsechny pripojene filesystemy ---
#
# `hdd` nese jen jedno cislo (overlay nebo /), takze pripojeny USB disk nebo
# druhy oddil nebyl videt vubec. Tohle posila kazdy skutecny filesystem
# zvlast: kde je pripojeny, na cem lezi, kolik zabira.
#
# Virtualni FS (tmpfs, devtmpfs, proc, sysfs) se vynechavaji - zaplneni
# ramdisku neni informace o ulozisti. squashfs zustava: je to sice jen pro
# cteni, ale je uzitecne videt, ze existuje.
filesystems_json="[]"
if command -v df >/dev/null 2>&1; then
    # -T (typ FS) umi coreutils i novejsi busybox; kdyz ne, jede se bez typu.
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
                if (type ~ /^(tmpfs|devtmpfs|proc|sysfs|debugfs|cgroup|overlayfs)$/) next;
                if (has_type == 0 && dev ~ /^(tmpfs|devtmpfs|none|proc|sysfs)$/) next;
                gsub("%", "", pct);
                if (pct !~ /^[0-9]+$/) next;
                printf "%s{\"mount\":\"%s\",\"device\":\"%s\",\"fstype\":\"%s\",\"total_kb\":%s,\"used_kb\":%s,\"avail_kb\":%s,\"used_pct\":%s}",
                       (n++ ? "," : "["), mnt, dev, type, total+0, used+0, avail+0, pct+0;
            }
            END { printf "%s", (n ? "]" : "[]") }')
    fi
fi
[ -z "$filesystems_json" ] && filesystems_json="[]"

# --- Zapis a cteni po jednotlivych discich ---
#
# `disk_io_write` je soucet pres vsechny disky. Tohle rozpadne stejna data
# po zarizenich, takze jde poznat, jestli se pise na flash routeru nebo na
# pripojeny USB disk. Rychlost se pocita ze zmeny proti minulemu behu -
# pri prvnim spusteni (nebo po rebootu, kdy citace spadnou) zustava null,
# protoze z jednoho odectu rychlost spocitat nelze.
DISKDEV_STATE_FILE="/tmp/status-agent-openwrt-diskdev.state"
disk_devices_json="[]"
if [ -f /proc/diskstats ]; then
    diskdev_now=$(date +%s)
    # Kotva $ za nazvem znamenala, ze `mmcblk` sedelo jen na zarizeni doslova
    # pojmenovane "mmcblk" - jenze skutecne se jmenuje mmcblk0. Stejne tak
    # mtdblock0 a ubiblock0_0. Ze seznamu tedy vypadlo hlavni uloziste routeru
    # (na Turrisu je / prave na mmcblk0p2) a zbyly jen disky sd[a-z]. Souhrnny
    # zapis o radek vys pritom mmcblk pocital, takze cislo za cele zarizeni
    # sedelo a chybel jen rozpad - o to hur se toho vsimlo.
    #
    # Oddily (mmcblk0p1, sda1) se schvalne vynechavaji: /proc/diskstats je
    # zapocitava i do celeho disku, takze by se stejny zapis vypsal dvakrat.
    diskdev_cur=$(awk '$3 ~ /^(mtdblock[0-9]+|mmcblk[0-9]+|sd[a-z]|ubiblock[0-9_]+|nvme[0-9]+n[0-9]+|hd[a-z])$/ { print $3 "|" $6 "|" $10 }' /proc/diskstats 2>/dev/null)

    if [ -n "$diskdev_cur" ]; then
        diskdev_prev_ts=""
        [ -f "$DISKDEV_STATE_FILE" ] && diskdev_prev_ts=$(head -n 1 "$DISKDEV_STATE_FILE" 2>/dev/null)

        disk_devices_json=$(printf '%s\n' "$diskdev_cur" | awk -F'|' \
            -v prev_file="$DISKDEV_STATE_FILE" -v now_ts="$diskdev_now" -v prev_ts="$diskdev_prev_ts" '
            BEGIN {
                elapsed = 0;
                if (prev_ts != "") elapsed = now_ts - prev_ts;
                while ((getline line < prev_file) > 0) {
                    n = split(line, p, "|");
                    if (n == 3) { prev_r[p[1]] = p[2]; prev_w[p[1]] = p[3]; }
                }
            }
            {
                dev = $1; r = $2; w = $3;
                # Sektor ma 512 B; delime 1024 na kB/s.
                rk = "null"; wk = "null";
                if (elapsed > 0 && (dev in prev_r) && r >= prev_r[dev] && w >= prev_w[dev]) {
                    rk = sprintf("%.1f", ((r - prev_r[dev]) * 512 / elapsed) / 1024);
                    wk = sprintf("%.1f", ((w - prev_w[dev]) * 512 / elapsed) / 1024);
                }
                printf "%s{\"device\":\"%s\",\"read_kbps\":%s,\"write_kbps\":%s,\"read_sectors_total\":%s,\"write_sectors_total\":%s}",
                       (c++ ? "," : "["), dev, rk, wk, r, w;
            }
            END { printf "%s", (c ? "]" : "[]") }')

        { echo "$diskdev_now"; printf '%s\n' "$diskdev_cur"; } > "$DISKDEV_STATE_FILE" 2>/dev/null
    fi
fi
[ -z "$disk_devices_json" ] && disk_devices_json="[]"

# --- Procesy, ktere nejvic zapisuji ---
#
# /proc/<pid>/io ma write_bytes = kolik proces skutecne poslal na uloziste.
# Vyzaduje jadro s CONFIG_TASK_IO_ACCOUNTING a beh pod rootem; kdyz to neni
# k dispozici, zustane prazdne pole - ne nuly.
#
# Hodnota je kumulativni od startu procesu, takze odpovida na "kdo toho
# nejvic zapsal", ne "kdo zrovna pise".
# Jadro bez CONFIG_TASK_IO_ACCOUNTING /proc/<pid>/io vubec nema (Turris je
# ten pripad). Posila se proto i priznak, aby rozhrani mohlo rict "tvoje
# jadro to neumi" misto toho, aby jen mlcky nic neukazalo.
top_io_json="[]"
io_accounting_json="false"
if [ -r /proc/1/io ]; then
    io_accounting_json="true"
fi
if [ "$io_accounting_json" = "true" ]; then
    top_io_json=$(
        for pid_dir in /proc/[0-9]*; do
            pid=${pid_dir#/proc/}
            [ -r "$pid_dir/io" ] || continue
            wb=$(awk '/^write_bytes:/ {print $2}' "$pid_dir/io" 2>/dev/null)
            [ -n "$wb" ] || continue
            [ "$wb" -gt 0 ] 2>/dev/null || continue
            name=$(awk '/^Name:/ {print $2}' "$pid_dir/status" 2>/dev/null)
            [ -n "$name" ] || continue
            echo "$wb|$pid|$name"
        done | sort -t'|' -k1 -rn | head -5 | awk -F'|' '
            { printf "%s{\"pid\":%s,\"name\":\"%s\",\"write_bytes\":%s}", (n++ ? "," : "["), $2, $3, $1 }
            END { printf "%s", (n ? "]" : "[]") }'
    )
fi
[ -z "$top_io_json" ] && top_io_json="[]"

# --- Top CPU & RAM processes ---
# Sloupce se hledaji podle HLAVICKY topu (busybox i procps maji jine poradi).
# Drivejsi verze "hadala" CPU jako nejvetsi cislo <= 100 v radku, takze
# hlasila u vsech procesu stejnou nesmyslnou hodnotu (20.0 %) a nulovou RAM.
top_cpu_json="[]"
top_ram_json="[]"
if command -v top >/dev/null 2>&1; then
    # procps-ng orezava sloupec COMMAND na sirku terminalu a useknute jmeno
    # oznaci plusem ("pyt+", "kr+"). -w 512 sirku vynuti; busybox top prepinac
    # nezna, proto fallback na holy beh.
    # Sampler se spousti na pozadi, aby se dalo poznat, ktery radek ve vypisu
    # je on sam.
    #
    # `top -bn1` vypisuje i sebe a na routeru chvili zabere procesor, takze
    # koncil na prvnim miste zebricku - panel "co v tu chvili bezelo" pak na
    # otazku po pricine spicky odpovidal, ze ji zpusobil nas vlastni agent.
    #
    # Dohledat rodicovstvi az potom nejde: proces uz je mrtvy a /proc o nem nic
    # nevi. $! je jediny spolehlivy zpusob, jak jeho PID znat.
    BK_TOP_OUT="/tmp/status-agent-openwrt-top.$$"
    COLUMNS=512 top -bn1 -w 512 >"$BK_TOP_OUT" 2>/dev/null &
    bk_top_pid=$!
    wait "$bk_top_pid" 2>/dev/null
    top_out=$(cat "$BK_TOP_OUT" 2>/dev/null)
    if [ -z "$top_out" ]; then
        COLUMNS=512 top -bn1 >"$BK_TOP_OUT" 2>/dev/null &
        bk_top_pid=$!
        wait "$bk_top_pid" 2>/dev/null
        top_out=$(cat "$BK_TOP_OUT" 2>/dev/null)
    fi
    rm -f "$BK_TOP_OUT" 2>/dev/null
    if [ -n "$top_out" ]; then
        top_parsed=$(echo "$top_out" | awk '
        function basename(p,   n, a) { n = split(p, a, "/"); return a[n]; }
        # Hlavicka: najdeme indexy sloupcu podle nazvu
        !found && /PID/ && (/%CPU/ || /CPU%/ || /COMMAND/) {
            for (i = 1; i <= NF; i++) {
                h = toupper($i);
                if (h == "%CPU" || h == "CPU%") cpu_i = i;
                else if (h == "%VSZ" || h == "%MEM" || h == "MEM%") mem_i = i;
                else if (h == "VSZ" || h == "RSS" || h == "RES") vsz_i = i;
                else if (h == "COMMAND" || h == "CMD" || h == "PROCESS") cmd_i = i;
                else if (h == "PID") pid_i = i;
            }
            found = 1; next;
        }
        found && $pid_i ~ /^[0-9]+$/ {
            cpu = (cpu_i ? $cpu_i : "");
            gsub(/%/, "", cpu);
            if (cpu !~ /^[0-9]+(\.[0-9]+)?$/) cpu = "";
            # Pamet: VSZ/RSS je v kB (busybox pouziva pripony m/g)
            raw = (vsz_i ? $vsz_i : "");
            mb = "";
            if (raw ~ /^[0-9]+(\.[0-9]+)?[mM]$/) { sub(/[mM]$/, "", raw); mb = raw + 0; }
            else if (raw ~ /^[0-9]+(\.[0-9]+)?[gG]$/) { sub(/[gG]$/, "", raw); mb = (raw + 0) * 1024; }
            else if (raw ~ /^[0-9]+(\.[0-9]+)?[kK]?$/) { sub(/[kK]$/, "", raw); mb = (raw + 0) / 1024; }
            # busybox top kresli strom procesu: COMMAND zacina glyfem
            # (`- , |- , +-) a skutecny prikaz je az za nim. Driv se proto
            # jako jmeno ulozilo doslova "`-".
            name = "";
            for (c = cmd_i; c <= NF; c++) {
                cand = $c;
                gsub(/^[`|+\\-]+$/, "", cand);
                if (cand == "" || cand == "`-" || cand == "|-" || cand == "+-" || cand == "-") continue;
                # Jaderna vlakna top vypisuje v hranatych zavorkach
                # ([kworker/u4:0-phy0]). basename() z nich delal "u4:0-phy0]",
                # protoze rezal podle lomitka - u nich se zavorky jen odstrani.
                if (cand ~ /^\[/) {
                    gsub(/^\[|\]$/, "", cand);
                    name = cand;
                } else {
                    name = basename(cand);
                }
                break;
            }
            gsub(/[{}"\\]/, "", name);
            # Zbytkove orezani (starsi top bez -w): "pyt+" -> "pyt"
            sub(/\+$/, "", name);
            if (name == "" || name ~ /^[`|+-]+$/) next;
            printf "%s|%s|%s|%s\n", name, cpu, mb, $pid_i;
        }' 2>/dev/null)

        # Vyhazuji se jen dve konkretni PID: agent sam a sampler, ktery prave
        # bezel. Podle jmena se nefiltruje - rucne spusteny `top`, ktery opravdu
        # zere CPU, ma zustat videt.
        if [ -n "$top_parsed" ]; then
            top_parsed=$(echo "$top_parsed" | awk -F'|' -v self="$$" -v sampler="$bk_top_pid" '
                $4 != self && $4 != sampler { printf "%s|%s|%s\n", $1, $2, $3 }')
        fi

        if [ -n "$top_parsed" ]; then
            # Obe hodnoty jdou do OBOU seznamu. Driv nesl zebricek podle CPU
            # jen cpu a zebricek podle RAM jen ram_mb, takze v tabulce mela
            # kazda radka jednu bunku prazdnou ("librespeed-cli 63,2 % / -").
            # null se posila, kdyz hodnota u procesu opravdu chybi.
            top_cpu_json=$(echo "$top_parsed" | awk -F'|' '$2 != ""' | sort -t'|' -k2 -rn | head -5 | awk -F'|' '
                BEGIN { printf "[" }
                { if (NR > 1) printf ", "; printf "{\"name\":\"%s\",\"cpu\":%.1f,\"ram_mb\":%s}", $1, $2, ($3 != "" ? sprintf("%.1f", $3) : "null") }
                END { printf "]" }')
            top_ram_json=$(echo "$top_parsed" | awk -F'|' '$3 != ""' | sort -t'|' -k3 -rn | head -5 | awk -F'|' '
                BEGIN { printf "[" }
                { if (NR > 1) printf ", "; printf "{\"name\":\"%s\",\"ram_mb\":%.1f,\"cpu\":%s}", $1, $3, ($2 != "" ? sprintf("%.1f", $2) : "null") }
                END { printf "]" }')
        fi
    fi
fi
[ -z "$top_cpu_json" ] && top_cpu_json="[]"
[ -z "$top_ram_json" ] && top_ram_json="[]"

# --- mwan3 (multi-WAN) ---
mwan3_policies_json="[]"
mwan3_active_gw=""
if [ -f /etc/config/mwan3 ]; then
    mwan3_status=$(mwan3 status 2>/dev/null)
    if [ -n "$mwan3_status" ]; then
        mwan3_active_gw=$(echo "$mwan3_status" | grep -i "active" | head -1 | awk '{print $NF}')
        mwan3_policies_json=$(echo "$mwan3_status" | awk '
        /policy/ { pol=$2 }
        /online/ { if (count > 0) printf ", "; printf "{\"policy\":\"%s\",\"interface\":\"%s\",\"status\":\"online\"}", pol, $2; count++ }
        /offline/ { if (count > 0) printf ", "; printf "{\"policy\":\"%s\",\"interface\":\"%s\",\"status\":\"offline\"}", pol, $2; count++ }
        BEGIN { printf "[" }
        END { printf "]" }')
        [ -z "$mwan3_policies_json" ] && mwan3_policies_json="[]"
    fi
fi
[ -z "$mwan3_active_gw" ] && mwan3_active_gw="null" || mwan3_active_gw="\"$mwan3_active_gw\""

# --- SQM (Smart Queue Management / CAKE) ---
sqm_enabled="false"
sqm_download_kbps="null"
sqm_upload_kbps="null"
sqm_dropped="null"
sqm_ecn="null"
if [ -f /etc/config/sqm ]; then
    sqm_enabled=$(uci get sqm.@queue[0].enabled 2>/dev/null)
    [ "$sqm_enabled" = "1" ] && sqm_enabled="true" || sqm_enabled="false"
    if [ "$sqm_enabled" = "true" ]; then
        sqm_download_kbps=$(uci get sqm.@queue[0].download 2>/dev/null)
        sqm_upload_kbps=$(uci get sqm.@queue[0].upload 2>/dev/null)
        [ -z "$sqm_download_kbps" ] && sqm_download_kbps="null"
        [ -z "$sqm_upload_kbps" ] && sqm_upload_kbps="null"
        # CAKE stats from tc
        sqm_iface=$(uci get sqm.@queue[0].interface 2>/dev/null)
        if [ -n "$sqm_iface" ] && command -v tc >/dev/null 2>&1; then
            tc_out=$(tc -s qdisc show dev "$sqm_iface" 2>/dev/null | grep -A5 "cake")
            sqm_dropped=$(echo "$tc_out" | grep -i "dropped" | awk '{print $NF}' | head -1)
            sqm_ecn=$(echo "$tc_out" | grep -i "ecn" | awk '{print $NF}' | head -1)
        fi
        [ -z "$sqm_dropped" ] && sqm_dropped="null"
        [ -z "$sqm_ecn" ] && sqm_ecn="null"
    fi
fi

# --- LTE/WWAN pripojeni pres ubus -----------------------------------------
#
# Modem nemusi byt vubec videt pres uqmi/mmcli - na Turrisu s LTE v mPCIe
# bez ModemManageru je dostupny jen jako sitove rozhrani (interface "lte",
# proto dhcp). Driv agent hlasil "zadne LTE", i kdyz spojeni bezelo.
#
# Odsud se da zjistit, jestli LTE JEDE. Sila signalu (RSRP/RSRQ/band) tudy
# dostupna neni - ta zustava null, dokud na routeru nebude uqmi/mmcli.
lte_up="null"
lte_device="null"
lte_uptime="null"
lte_ipv4="null"
if command -v ubus >/dev/null 2>&1; then
    for lte_if in lte wwan wwan0 modem lte1; do
        lte_status=$(ubus call "network.interface.${lte_if}" status 2>/dev/null)
        [ -z "$lte_status" ] && continue

        lte_up_raw=$(echo "$lte_status" | jsonfilter -e '@.up' 2>/dev/null)
        [ "$lte_up_raw" = "true" ] || [ "$lte_up_raw" = "1" ] && lte_up="true" || lte_up="false"

        lte_dev=$(echo "$lte_status" | jsonfilter -e '@.l3_device' 2>/dev/null)
        [ -z "$lte_dev" ] && lte_dev=$(echo "$lte_status" | jsonfilter -e '@.device' 2>/dev/null)
        [ -n "$lte_dev" ] && lte_device="$lte_dev"

        lte_up_sec=$(echo "$lte_status" | jsonfilter -e '@.uptime' 2>/dev/null)
        case "$lte_up_sec" in
            ''|*[!0-9]*) : ;;
            *) lte_uptime="$lte_up_sec" ;;
        esac

        lte_addr=$(echo "$lte_status" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
        [ -n "$lte_addr" ] && lte_ipv4="$lte_addr"

        break
    done
fi

# --- Signal, SIM a registrace z HiLink API modemu ----------------------------
#
# Modemy Huawei/Brovi v rezimu HiLink vystavuji na sve brane HTTP API. Je to
# jedina cesta, jak bez mmcli/uqmi zjistit silu signalu - a hlavne jedina
# cesta, jak zjistit, jestli zaloha VUBEC MUZE FUNGOVAT.
#
# `lte_up` z ubus totiz rika jen to, ze router dostal od modemu DHCP adresu.
# HiLink modem ji rozda i bez SIM karty nebo se spatnym PINem - rozhrani pak
# "bezi" devet dni v kuse, zatimco pres nej neprojde jediny paket. Proto se
# tady cte /api/monitoring/status (registrace do site) a /api/pin/status
# (stav SIM) a posila se dal jako lte_connected a lte_sim_state. Kdyz modem
# neodpovi, zustava null - "nevime" se nikdy nevydava za "funguje".
#
# Dotaz jde vylucne na branu LTE rozhrani (odvozenou z jeho vlastni adresy),
# s kratkym timeoutem, a jen kdyz rozhrani bezi.
#
# Inicializace signalu je TADY, pred HiLink blokem - driv stala az v bloku
# uqmi/mmcli pod nim a bezpodminecne prepsala vsechno, co HiLink prave
# naplnil. Na routeru bez uqmi/mmcli tak RSRP/RSRQ/SINR nikdy nedorazily,
# jen RSSI, ktere v tom resetu shodou okolnosti nebylo.
lte_rsrp="null"
lte_rsrq="null"
lte_sinr="null"
lte_band="null"
lte_carrier="null"
lte_rssi="null"
lte_pci="null"
lte_cell_id="null"
lte_bandwidth="null"
lte_plmn="null"
lte_connected="null"
lte_sim_state="null"
lte_conn_code="null"
lte_sim_code="null"
lte_service_code="null"
lte_sim_pin_left="null"
lte_sim_status_code="null"
lte_api_host=""

# Jedna hodnota z XML odpovedi: bk_xml_tag "<xml>" tag -> obsah, nebo prazdno.
bk_xml_tag() {
    printf '%s' "$1" | sed -n "s|.*<$2>\([^<]*\)</$2>.*|\1|p" | head -1
}

# GET na HiLink API modemu. Nektere firmwary (E3372h-320, Brovi E3372-325)
# odpovi na kazdy dotaz chybou 125002/125003, dokud nedostanou session cookie
# a overovaci token z /api/webserver/SesTokInfo - pak se dotaz zopakuje s
# obojim. uclient-fetch hlavicky poslat neumi, takze na takovem modemu bez
# curl/wget zustanou hodnoty null.
bk_hilink_get() {
    _hl_url="http://${lte_api_host}$1"
    _hl_body=""
    if command -v curl >/dev/null 2>&1; then
        _hl_body=$(curl -s -m 2 "$_hl_url" 2>/dev/null)
    elif command -v uclient-fetch >/dev/null 2>&1; then
        _hl_body=$(uclient-fetch -q -T 2 -O - "$_hl_url" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        _hl_body=$(wget -q -T 2 -O - "$_hl_url" 2>/dev/null)
    fi
    case "$_hl_body" in
        *"<code>125002</code>"*|*"<code>125003</code>"*|*"<code>100003</code>"*)
            _hl_tok=""
            if command -v curl >/dev/null 2>&1; then
                _hl_tok=$(curl -s -m 2 "http://${lte_api_host}/api/webserver/SesTokInfo" 2>/dev/null)
            elif command -v wget >/dev/null 2>&1; then
                _hl_tok=$(wget -q -T 2 -O - "http://${lte_api_host}/api/webserver/SesTokInfo" 2>/dev/null)
            fi
            _hl_ses=$(bk_xml_tag "$_hl_tok" SesInfo)
            _hl_ver=$(bk_xml_tag "$_hl_tok" TokInfo)
            if [ -n "$_hl_ses" ] && [ -n "$_hl_ver" ]; then
                if command -v curl >/dev/null 2>&1; then
                    _hl_body=$(curl -s -m 2 -H "Cookie: $_hl_ses" -H "__RequestVerificationToken: $_hl_ver" "$_hl_url" 2>/dev/null)
                elif command -v wget >/dev/null 2>&1; then
                    _hl_body=$(wget -q -T 2 -O - --header "Cookie: $_hl_ses" --header "__RequestVerificationToken: $_hl_ver" "$_hl_url" 2>/dev/null)
                fi
            fi
            ;;
    esac
    printf '%s' "$_hl_body"
}

if [ "$lte_up" = "true" ] && [ "$lte_ipv4" != "null" ] && [ -n "$lte_ipv4" ]; then
    lte_api_host=$(echo "$lte_ipv4" | sed 's/\.[0-9]*$/.1/')

    # -- registrace do site: /api/monitoring/status --
    # ConnectionStatus 901 = pripojeno; 902/903/905 = odpojeno; 7/11/12/14/37
    # = sit pristup nepovolila (spatna SIM, zakazana sluzba). Neznamy kod se
    # neprevadi na nic - zustane null a surovy kod jde dal k posouzeni.
    lte_mon_xml=$(bk_hilink_get /api/monitoring/status)
    _cc=$(bk_xml_tag "$lte_mon_xml" ConnectionStatus | sed 's/[^0-9]//g')
    if [ -n "$_cc" ]; then
        lte_conn_code="$_cc"
        case "$_cc" in
            901) lte_connected="true" ;;
            902|903|905|7|11|12|14|37|201|202|203|204) lte_connected="false" ;;
        esac
    fi
    _sc=$(bk_xml_tag "$lte_mon_xml" ServiceStatus | sed 's/[^0-9]//g')
    [ -n "$_sc" ] && lte_service_code="$_sc"
    # SimStatus: 1 = platna; 0/255 = neni vlozena; 2/3/4 = SIM sit NEPRIJIMA
    # (neplatna pro hlasove / datove sluzby / oboje) - typicky deaktivovana nebo
    # zablokovana operatorem. Presne to mela SIM, kvuli ktere tahle kontrola
    # vznikla: /api/pin/status hlasil 257 "pripravena" (PIN je jina osa), ale
    # SimStatus 4 a ConnectionStatus 902.
    _ss=$(bk_xml_tag "$lte_mon_xml" SimStatus | sed 's/[^0-9]//g')
    [ -n "$_ss" ] && lte_sim_status_code="$_ss"
    case "$_ss" in
        1) lte_sim_state="ready" ;;
        0|255) lte_sim_state="no_sim" ;;
        2|3|4) lte_sim_state="invalid" ;;
    esac

    # -- stav SIM: /api/pin/status --
    # SimState 257 = pripravena, 260 = ceka na PIN, 261 = ceka na PUK,
    # 255 = zadna SIM, 256/262 = neplatna nebo zablokovana.
    lte_pin_xml=$(bk_hilink_get /api/pin/status)
    _sim=$(bk_xml_tag "$lte_pin_xml" SimState | sed 's/[^0-9]//g')
    if [ -n "$_sim" ]; then
        lte_sim_code="$_sim"
        # Blokujici stavy odsud maji prednost; "pripravena" (257) jen doplni,
        # co monitoring/status nerekl - SIM bez PINu muze porad byt odmitnuta siti.
        case "$_sim" in
            260) lte_sim_state="pin_required" ;;
            261) lte_sim_state="puk_required" ;;
            255) lte_sim_state="no_sim" ;;
            256|262) lte_sim_state="invalid" ;;
            257) [ "$lte_sim_state" = "null" ] && lte_sim_state="ready" ;;
        esac
    fi
    _pin_left=$(bk_xml_tag "$lte_pin_xml" SimPinTimes | sed 's/[^0-9]//g')
    [ -n "$_pin_left" ] && lte_sim_pin_left="$_pin_left"

    # -- sila signalu: /api/device/signal --
    lte_sig_xml=$(bk_hilink_get /api/device/signal)

    if echo "$lte_sig_xml" | grep -q "<rsrp>"; then
        # Hodnoty nesou jednotky primo v textu ("-83dBm", "-6.0dB"), tak se
        # necha jen cislo. Prazdny tag = udaj modem nehlasi -> null.
        bk_xml_num() {
            _v=$(echo "$lte_sig_xml" | sed -n "s|.*<$1>\([^<]*\)</$1>.*|\1|p" | head -1)
            _v=$(echo "$_v" | sed 's/[^0-9.-]//g')
            case "$_v" in
                ''|-|.|--) printf 'null' ;;
                *) printf '%s' "$_v" ;;
            esac
        }
        bk_xml_str() {
            _v=$(echo "$lte_sig_xml" | sed -n "s|.*<$1>\([^<]*\)</$1>.*|\1|p" | head -1)
            [ -z "$_v" ] && printf 'null' || printf '"%s"' "$(json_str "$_v")"
        }

        lte_rsrp=$(bk_xml_num rsrp)
        lte_rsrq=$(bk_xml_num rsrq)
        lte_sinr=$(bk_xml_num sinr)
        lte_rssi=$(bk_xml_num rssi)
        lte_pci=$(bk_xml_num pci)
        lte_cell_id=$(bk_xml_num cell_id)
        lte_plmn=$(bk_xml_str plmn)
        lte_bandwidth=$(bk_xml_str dlbandwidth)

        # Pasmo hlasi modem jako cislo (1 = B1); ve zbytku systemu je to text.
        _band=$(echo "$lte_sig_xml" | sed -n 's|.*<band>\([^<]*\)</band>.*|\1|p' | head -1)
        [ -n "$_band" ] && lte_band="B${_band}"

        # Jmeno operatora ma jiny endpoint; bez nej zustava to, co uz mame.
        lte_plmn_xml=$(bk_hilink_get /api/net/current-plmn)
        _carrier=$(bk_xml_tag "$lte_plmn_xml" FullName)
        [ -z "$_carrier" ] && _carrier=$(bk_xml_tag "$lte_plmn_xml" ShortName)
        [ -n "$_carrier" ] && lte_carrier="$_carrier"
    fi
fi

# --- LTE/WWAN modem pres uqmi / mmcli ---
#
# Zadna inicializace na null: ta je nahore pred HiLink blokem. Tady se
# hodnota prepise jen tehdy, kdyz uqmi/mmcli opravdu neco vrati - jinak by
# router s HiLink modemem a bez techto nastroju o signal prisel.
if command -v uqmi >/dev/null 2>&1; then
    lte_signal=$(uqmi --get-signal-info 2>/dev/null)
    if [ -n "$lte_signal" ]; then
        _q=$(echo "$lte_signal" | jsonfilter -e '@.rsrp' 2>/dev/null); [ -n "$_q" ] && lte_rsrp="$_q"
        _q=$(echo "$lte_signal" | jsonfilter -e '@.rsrq' 2>/dev/null); [ -n "$_q" ] && lte_rsrq="$_q"
        _q=$(echo "$lte_signal" | jsonfilter -e '@.sinr' 2>/dev/null); [ -n "$_q" ] && lte_sinr="$_q"
        _q=$(echo "$lte_signal" | jsonfilter -e '@.band' 2>/dev/null); [ -n "$_q" ] && lte_band="$_q"
    fi
    _q=$(uqmi --get-network-registration 2>/dev/null | jsonfilter -e '@.description' 2>/dev/null)
    [ -n "$_q" ] && lte_carrier="$_q"
elif command -v mmcli >/dev/null 2>&1; then
    mm_out=$(mmcli -m any --signal-get 2>/dev/null)
    if [ -n "$mm_out" ]; then
        _q=$(echo "$mm_out" | grep -i "rsrp" | awk -F: '{gsub(/[^0-9.-]/, "", $2); print $2}'); [ -n "$_q" ] && lte_rsrp="$_q"
        _q=$(echo "$mm_out" | grep -i "rsrq" | awk -F: '{gsub(/[^0-9.-]/, "", $2); print $2}'); [ -n "$_q" ] && lte_rsrq="$_q"
        _q=$(echo "$mm_out" | grep -i "sinr" | awk -F: '{gsub(/[^0-9.-]/, "", $2); print $2}'); [ -n "$_q" ] && lte_sinr="$_q"
    fi
fi
# Fallback: Turris/OpenWrt s ModemManager pres ubus, kdyz uqmi/mmcli chybi
if [ "$lte_rsrp" = "null" ] || [ -z "$lte_rsrp" ]; then
    if command -v mmcli >/dev/null 2>&1; then
        mm_id=$(mmcli -L 2>/dev/null | sed -n 's#.*/Modem/\([0-9]*\).*#\1#p' | head -1)
        if [ -n "$mm_id" ]; then
            mmcli -m "$mm_id" --signal-setup=5 >/dev/null 2>&1
            mm_sig=$(mmcli -m "$mm_id" --signal-get 2>/dev/null)
            [ -n "$mm_sig" ] && {
                lte_rsrp=$(echo "$mm_sig" | sed -n 's/.*rsrp:[[:space:]]*\(-\?[0-9.]*\).*/\1/p' | head -1)
                lte_rsrq=$(echo "$mm_sig" | sed -n 's/.*rsrq:[[:space:]]*\(-\?[0-9.]*\).*/\1/p' | head -1)
                lte_sinr=$(echo "$mm_sig" | sed -n 's/.*snr:[[:space:]]*\(-\?[0-9.]*\).*/\1/p' | head -1)
            }
            mm_info=$(mmcli -m "$mm_id" 2>/dev/null)
            [ -n "$mm_info" ] && {
                lte_carrier=$(echo "$mm_info" | sed -n "s/.*operator name:[[:space:]]*'\?\([^'|]*\).*/\1/p" | head -1 | sed 's/[[:space:]]*$//')
                lte_band=$(echo "$mm_info" | sed -n 's/.*bands:[[:space:]]*\([^|]*\).*/\1/p' | head -1 | sed 's/[[:space:]]*$//')
            }
        fi
    fi
fi

[ -z "$lte_rsrp" ] && lte_rsrp="null"
[ -z "$lte_rsrq" ] && lte_rsrq="null"
[ -z "$lte_sinr" ] && lte_sinr="null"
[ -z "$lte_band" ] && lte_band="null"
# Zadne predbezne obalovani uvozovkami: json_val() nize rozlisi prazdnou
# hodnotu od retezce sam. Kdyz se hodnota obalila uz tady, json_val ji obalil
# podruhe a z chybejiciho operatora se stal RETEZEC "null" - presne ta chyba,
# kvuli ktere json_val() vznikl, jen o kus dal.
# Overeno na cistem OpenWrt: `"lte_carrier": "\"null\""` v payloadu.
[ -z "$lte_carrier" ] && lte_carrier="null"

# --- Services restart tracking (last 24h from logread) ---
service_restarts_json="{}"
if command -v logread >/dev/null 2>&1; then
    svc_list="dnsmasq odhcpd hostapd mwan3 uhttpd nginx wireguard"
    svc_parts=""
    for svc in $svc_list; do
        if [ -f "/etc/init.d/$svc" ]; then
            cnt=$(logread 2>/dev/null | grep -i "$svc" | grep -ci "start" 2>/dev/null)
            [ -z "$cnt" ] && cnt=0
            [ -n "$svc_parts" ] && svc_parts="$svc_parts, "
            svc_parts="${svc_parts}\"$svc\": $cnt"
        fi
    done
    [ -n "$svc_parts" ] && service_restarts_json="{$svc_parts}"
fi

# --- WAN reconnect stats (state file) ---
wan_reconnect_count=0
wan_last_reconnect="null"
bk_state_file="/tmp/bk_wan_state"
if [ -n "$wan_uptime" ] && [ "$wan_uptime" != "null" ] && [ "$wan_uptime" -gt 0 ] 2>/dev/null; then
    if [ -f "$bk_state_file" ]; then
        prev_uptime=$(awk -F= '/^uptime=/{print $2}' "$bk_state_file" 2>/dev/null)
        prev_count=$(awk -F= '/^count=/{print $2}' "$bk_state_file" 2>/dev/null)
        prev_reconnect=$(awk -F= '/^reconnect=/{print $2}' "$bk_state_file" 2>/dev/null)
        wan_reconnect_count=${prev_count:-0}
        [ -n "$prev_reconnect" ] && wan_last_reconnect="$prev_reconnect"
        # WAN uptime reset = reconnect detected
        if [ -n "$prev_uptime" ] && [ "$wan_uptime" -lt "$prev_uptime" ] 2>/dev/null; then
            wan_reconnect_count=$((wan_reconnect_count + 1))
            wan_last_reconnect=$(date +%s)
        fi
    fi
    printf "uptime=%s\ncount=%s\nreconnect=%s\n" "$wan_uptime" "$wan_reconnect_count" "$wan_last_reconnect" > "$bk_state_file" 2>/dev/null
fi

# --- Logs stats ---
# Log: busybox logread pouziva "<err>"/"<warn>", syslog-ng (Turris) pise
# uroven slovem ("err:", "error", "warning"). Drivejsi grep na "<err>"
# proto na Turrisu hlasil vzdycky nulu. Bez citelneho logu zustava null.
log_errors_24h="null"
log_warnings_24h="null"
log_buf=""
if command -v logread >/dev/null 2>&1; then
    log_buf=$(logread -l 500 2>/dev/null)
fi
if [ -z "$log_buf" ] && command -v journalctl >/dev/null 2>&1; then
    log_buf=$(journalctl --since "24 hours ago" --no-pager -n 500 2>/dev/null)
fi
if [ -z "$log_buf" ] && [ -r /var/log/messages ]; then
    log_buf=$(tail -n 500 /var/log/messages 2>/dev/null)
fi
if [ -n "$log_buf" ]; then
    log_errors_24h=$(echo "$log_buf" | grep -c -i -E '<err>|(^| )err(or)?[: ]|daemon\.err|kern\.err|critical|fatal|panic')
    log_warnings_24h=$(echo "$log_buf" | grep -c -i -E '<warn>|(^| )warn(ing)?[: ]|daemon\.warn|kern\.warn')
    [ -z "$log_errors_24h" ] && log_errors_24h=0
    [ -z "$log_warnings_24h" ] && log_warnings_24h=0
fi

# --- Tailscale / ZeroTier / UPS (NUT) - vse null-safe, bez nastroje se neposila nic ---
tailscale_up_json="null"
tailscale_peers_json="null"
if command -v tailscale >/dev/null 2>&1; then
    ts_json=$(tailscale status --json 2>/dev/null)
    if [ -n "$ts_json" ]; then
        echo "$ts_json" | grep -q '"BackendState":"Running"' && tailscale_up_json=true || tailscale_up_json=false
        tailscale_peers_json=$(echo "$ts_json" | grep -c '"TailscaleIPs"')
        # Self je v JSONu taky - odecist
        [ "$tailscale_peers_json" -gt 0 ] 2>/dev/null && tailscale_peers_json=$((tailscale_peers_json - 1))
    fi
fi

zerotier_networks_json="null"
if command -v zerotier-cli >/dev/null 2>&1; then
    zerotier_networks_json=$(zerotier-cli listnetworks 2>/dev/null | grep -c " OK ")
    [ -z "$zerotier_networks_json" ] && zerotier_networks_json=0
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

# --- OOM kills, boot time, DNS latence, OpenVPN, USB (wishlist dodelavky) ---
oom_kills="null"
if command -v dmesg >/dev/null 2>&1; then
    oom_kills=$(dmesg 2>/dev/null | grep -ci "oom-killer\|Out of memory")
    # Prazdny vystup = dmesg nesel precist, ne "zadne OOM zabiti".
    [ -z "$oom_kills" ] && oom_kills="null"
fi

# Boot time = ted - uptime; UI z toho ukaze "System bezi od" bez driftu.
boot_time="null"
[ -n "$uptime_sec" ] && [ "$uptime_sec" -gt 0 ] 2>/dev/null && boot_time=$((now_sec - uptime_sec))

# DNS latence: realny dotaz pres lokalni resolver. Busybox time vypisuje
# "real 0m 0.03s" na stderr; bez time/nslookup zustava null.
dns_latency_ms="null"
if command -v nslookup >/dev/null 2>&1 && command -v time >/dev/null 2>&1; then
    dns_t=$( { time nslookup example.com 127.0.0.1 >/dev/null 2>&1; } 2>&1 | sed -n 's/.*real[[:space:]]*\([0-9]*\)m[[:space:]]*\([0-9.]*\)s.*/\1 \2/p')
    if [ -n "$dns_t" ]; then
        dns_min=$(echo "$dns_t" | awk '{print $1}')
        dns_sec=$(echo "$dns_t" | awk '{print $2}')
        dns_latency_ms=$(awk -v m="$dns_min" -v s="$dns_sec" 'BEGIN { printf "%.0f", (m*60+s)*1000 }')
    fi
fi

# --- Odezva a rychlost linky ---------------------------------------------
#
# Server odezvu routeru zmerit nedokaze: ping z hostingu na WAN IP router
# zahodi. Merime ji proto zevnitr - je to i smysluplnejsi cislo, protoze
# rika, jak rychle odpovida INTERNET routeru, ne jak dobre je videt zvenku.
#
# Cil: nejdriv WAN brana (odezva prvniho hopu poskytovatele), pri neuspechu
# verejny resolver. Bere se prumer ze tri paketu; kdyz ping neni nebo
# neprojde, zustava null - nulou se to nenahrazuje.
wan_latency_ms="null"
if command -v ping >/dev/null 2>&1; then
    for lat_target in "$wan_gateway" "1.1.1.1"; do
        [ -z "$lat_target" ] && continue
        lat_out=$(ping -c 3 -W 2 "$lat_target" 2>/dev/null | sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p')
        if [ -n "$lat_out" ]; then
            wan_latency_ms=$(awk -v v="$lat_out" 'BEGIN { printf "%.1f", v }')
            break
        fi
    done
fi

# Rychlost WAN linky (Mbit/s) podle vyjednaneho rezimu rozhrani. Neni to
# rychlost internetu od poskytovatele, ale strop fyzicke linky - kdyz
# gigabitovy port spadne na 100 Mbit, je to prave tady videt.
wan_link_mbit="null"
if [ -n "$wan_l3_device" ]; then
    link_dev="$wan_l3_device"
    # U PPPoE/VLAN je l3_device virtualni (pppoe-wan, eth0.2) a rychlost ma
    # jen fyzicky rodic. Odriznuti prefixu "pppoe-" davalo "wan", coz neni
    # nazev zarizeni - skutecny rodic je v uci konfiguraci.
    if [ ! -e "/sys/class/net/$link_dev/speed" ]; then
        uci_dev=$(uci get network.wan.device 2>/dev/null)
        [ -z "$uci_dev" ] && uci_dev=$(uci get network.wan.ifname 2>/dev/null)
        # VLAN (eth0.2) ma rychlost az na rodicovskem rozhrani.
        [ -n "$uci_dev" ] && [ ! -e "/sys/class/net/$uci_dev/speed" ] && uci_dev=$(echo "$uci_dev" | sed 's/\..*$//')
        [ -n "$uci_dev" ] && link_dev="$uci_dev"
    fi
    # Posledni pokus: odriznout jen VLAN priponu z l3_device.
    [ ! -e "/sys/class/net/$link_dev/speed" ] && link_dev=$(echo "$wan_l3_device" | sed 's/\..*$//')
    if [ -r "/sys/class/net/$link_dev/speed" ]; then
        link_raw=$(cat "/sys/class/net/$link_dev/speed" 2>/dev/null)
        # -1 = link down nebo neznama rychlost; to neni mereni.
        case "$link_raw" in
            ''|*[!0-9-]*) : ;;
            -*) : ;;
            0) : ;;
            *) wan_link_mbit="$link_raw" ;;
        esac
    fi
fi

openvpn_tunnels="null"
if command -v pidof >/dev/null 2>&1; then
    ovpn_pids=$(pidof openvpn 2>/dev/null)
    openvpn_tunnels=$(echo "$ovpn_pids" | wc -w | tr -d '[:space:]')
    [ -z "$openvpn_tunnels" ] && openvpn_tunnels=0
fi

# USB: pocitaji se jen skutecna ZARIZENI - polozky s ':' jsou rozhrani
# jednoho zarizeni (1-1:1.0) a 'usbN' jsou root huby radice, takze drivejsi
# prosty vypis hlasil treba 16 "zarizeni" u routeru s jedinym flash diskem.
usb_devices="null"
if [ -d /sys/bus/usb/devices ]; then
    usb_devices=$(ls /sys/bus/usb/devices 2>/dev/null | grep -E '^[0-9]+-[0-9]+(\.[0-9]+)*$' | wc -l | tr -d '[:space:]')
    [ -z "$usb_devices" ] && usb_devices=0
fi

# --- WiFi per-radio detail (iwinfo) ---
wifi_radios_json="[]"
if command -v iwinfo >/dev/null 2>&1; then
    wifi_radios_json=$(for radio in $(iwinfo 2>/dev/null | awk '/^[a-z0-9]/ {print $1}'); do
        info=$(iwinfo "$radio" info 2>/dev/null)
        ssid=$(echo "$info" | grep -i "essid" | sed 's/.*ESSID: "\([^"]*\)".*/\1/' | sed 's/["\\]//g')
        [ -z "$ssid" ] || [ "$ssid" = "unknown" ] && ssid=$(echo "$info" | grep -i "essid" | awk '{print $NF}' | sed 's/["\\]//g')

        channel=$(echo "$info" | grep -i "channel" | sed -n 's/.*Channel: \([0-9]*\).*/\1/p')
        [ -z "$channel" ] && channel=$(echo "$info" | grep -i "channel" | tr -cd '0-9')

        band="2.4GHz"
        if echo "$info" | grep -qi -E '5\.[0-9]+ \?GHz|5[0-9]{3} \?MHz|a/n/ac|802\.11a|802\.11ac|5GHz'; then
            band="5GHz"
        elif echo "$info" | grep -qi -E '6\.[0-9]+ \?GHz|6[0-9]{3} \?MHz|6GHz'; then
            band="6GHz"
        elif [ -n "$channel" ] && [ "$channel" -gt 14 ] 2>/dev/null; then
            band="5GHz"
        fi

        tx_power=$(echo "$info" | grep -i "tx-power" | sed -n 's/.*Tx-Power: \([0-9-]*\).*/\1/p')
        [ -z "$tx_power" ] && tx_power="0"
        noise=$(echo "$info" | grep -i "noise" | sed -n 's/.*Noise: \([0-9-]*\).*/\1/p')
        [ -z "$noise" ] && noise="0"

        # Count MAC addresses of connected stations
        clients=$(iwinfo "$radio" assoclist 2>/dev/null | grep -iE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | wc -l | tr -cd '0-9')
        if [ -z "$clients" ] || [ "$clients" -eq 0 ] 2>/dev/null; then
            if command -v hostapd_cli >/dev/null 2>&1; then
                clients=$(hostapd_cli -i "$radio" all_sta 2>/dev/null | grep -c "^dot11RSNAStatsSTAAddress=" | tr -cd '0-9')
            fi
        fi

        [ -n "$ssid" ] || ssid="unknown"
        [ -n "$channel" ] || channel="0"
        [ -n "$clients" ] || clients="0"

        # Vytizeni kanalu: pomer busy/active z iwinfo survey - ne kazdy driver
        # to umi, pak zustava busy_pct null (zadna vymyslena nula).
        busy_pct="null"
        survey=$(iwinfo "$radio" survey 2>/dev/null | grep -i -A4 "in use")
        if [ -n "$survey" ]; then
            s_active=$(echo "$survey" | sed -n 's/.*[Aa]ctive time:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
            s_busy=$(echo "$survey" | sed -n 's/.*[Bb]usy time:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
            if [ -n "$s_active" ] && [ -n "$s_busy" ] && [ "$s_active" -gt 0 ] 2>/dev/null; then
                busy_pct=$(awk -v b="$s_busy" -v a="$s_active" 'BEGIN { printf "%.0f", (b/a)*100 }')
            fi
        fi

        printf "{\"radio\":\"%s\",\"ssid\":\"%s\",\"band\":\"%s\",\"channel\":%d,\"tx_power\":%d,\"noise\":%d,\"clients\":%d,\"busy_pct\":%s}, " \
            "$radio" "$ssid" "$band" "$channel" "$tx_power" "$noise" "$clients" "$busy_pct"
    done | sed 's/, $//')
    [ -n "$wifi_radios_json" ] && wifi_radios_json="[$wifi_radios_json]" || wifi_radios_json="[]"
fi

# --- LAN / DHCP ---
lan_subnet=""
lan_json=$(ubus call network.interface.lan status 2>/dev/null)
if [ -n "$lan_json" ]; then
    json_load "$lan_json"
    json_get_keys lan_v4_keys "ipv4-address"
    for k in $lan_v4_keys; do
        json_select "ipv4-address"
        json_select "$k"
        lan_addr=""; lan_mask=""
        json_get_var lan_addr address
        json_get_var lan_mask mask
        if [ -n "$lan_addr" ] && [ -n "$lan_mask" ]; then
            lan_subnet="$lan_addr/$lan_mask"
        fi
        json_select ..
        json_select ..
        break
    done
fi
dhcp_leases_count=0
if [ -f /tmp/dhcp.leases ]; then
    dhcp_leases_count=$(wc -l < /tmp/dhcp.leases 2>/dev/null | xargs)
fi
dhcp_reservations_count=0
if command -v uci >/dev/null 2>&1; then
    dhcp_reservations_count=$(uci show dhcp 2>/dev/null | grep -c "=host$")
fi

# --- DNS Engine, Upstream Servers & DoT/DoH Encryption ---
dns_engine="Dnsmasq"
dns_encryption="Nešifrované DNS (UDP/53)"
dns_servers="$wan_dns"

# Sifrovani se URCUJE Z DUKAZU, netvrdi se podle jmena resolveru:
#  1) aktivni spojeni na port 853 (DoT) nebo 443 na znamy DoH endpoint,
#  2) az potom konfigurace. Bez dukazu se hlasi "nelze urcit", ne DoT.
dns_active_853=0
dns_active_443=0
if command -v netstat >/dev/null 2>&1; then
    netstat -tn 2>/dev/null | grep -q ':853 .*ESTABLISHED' && dns_active_853=1
elif command -v ss >/dev/null 2>&1; then
    ss -tn state established 2>/dev/null | grep -q ':853' && dns_active_853=1
fi

if pidof kresd >/dev/null 2>&1 || [ -f /etc/config/resolver ]; then
    dns_engine="Knot Resolver (kresd)"
    res_fwd=$(uci -q get resolver.common.forward_custom 2>/dev/null)
    res_tls=$(uci -q get resolver.common.forward_upstream 2>/dev/null)
    if [ "$dns_active_853" = "1" ]; then
        dns_encryption="DoT - ověřeno (aktivní spojení na port 853)"
    elif [ -n "$res_fwd" ] && [ "$res_tls" = "1" ]; then
        dns_encryption="DoT dle konfigurace (forwarding: $res_fwd)"
    elif grep -qi -E '853|tls_|ca_file|hostname' /etc/config/resolver 2>/dev/null; then
        dns_encryption="DoT dle konfigurace resolveru"
    else
        dns_encryption="Nešifrované DNS (UDP/53) - v konfiguraci není TLS upstream"
    fi
elif pidof AdGuardHome >/dev/null 2>&1; then
    dns_engine="AdGuard Home"
    agh_cfg=$(cat /etc/AdGuardHome/AdGuardHome.yaml /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null)
    if echo "$agh_cfg" | grep -qi 'https://'; then
        dns_encryption="DoH dle konfigurace (upstream https://)"
    elif echo "$agh_cfg" | grep -qi 'tls://'; then
        dns_encryption="DoT dle konfigurace (upstream tls://)"
    elif echo "$agh_cfg" | grep -qi 'quic://'; then
        dns_encryption="DoQ dle konfigurace (upstream quic://)"
    elif [ "$dns_active_853" = "1" ]; then
        dns_encryption="DoT - ověřeno (aktivní spojení na port 853)"
    else
        dns_encryption="Nelze určit (konfigurace AdGuard Home nepřečtena)"
    fi
elif pidof unbound >/dev/null 2>&1; then
    dns_engine="Unbound"
    if grep -rqi -E 'tls-upstream:[[:space:]]*yes|forward-tls-upstream:[[:space:]]*yes' /etc/unbound/ 2>/dev/null; then
        dns_encryption="DoT dle konfigurace (tls-upstream: yes)"
    elif [ "$dns_active_853" = "1" ]; then
        dns_encryption="DoT - ověřeno (aktivní spojení na port 853)"
    else
        dns_encryption="Nešifrované DNS (UDP/53)"
    fi
elif pidof stubby >/dev/null 2>&1; then
    dns_engine="Stubby"
    dns_encryption="DoT (Stubby je DoT-only resolver)"
elif pidof https_dns_proxy >/dev/null 2>&1 || pidof cloudflared >/dev/null 2>&1 || pidof dnscrypt-proxy >/dev/null 2>&1; then
    dns_engine="DoH proxy"
    dns_encryption="DoH - běží DoH proxy (https_dns_proxy/cloudflared/dnscrypt)"
elif [ "$dns_active_853" = "1" ]; then
    dns_encryption="DoT - ověřeno (aktivní spojení na port 853)"
fi

if [ -f /tmp/resolv.conf.auto ]; then
    extra_dns=$(grep -i "nameserver" /tmp/resolv.conf.auto | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
    if [ -n "$extra_dns" ]; then
        if [ -n "$dns_servers" ]; then
            dns_servers="$dns_servers, $extra_dns"
        else
            dns_servers="$extra_dns"
        fi
    fi
fi
[ -z "$dns_servers" ] && dns_servers="Výchozí poskytovatel (WAN)"



# --- Service Discovery Scanner (cached for HEAVY_OP_INTERVAL_HOURS) ---
discovered_services_json="[]"
SVC_CACHE_FILE="/tmp/status-agent-openwrt-services.cache"
svc_cache_age=999999
if [ -f "$SVC_CACHE_FILE" ]; then
    svc_mtime=$(date -r "$SVC_CACHE_FILE" +%s 2>/dev/null || echo 0)
    svc_cache_age=$((now_sec - svc_mtime))
fi

if [ $svc_cache_age -lt $HEAVY_OP_INTERVAL_SEC ] && [ -f "$SVC_CACHE_FILE" ]; then
    discovered_services_json=$(cat "$SVC_CACHE_FILE" 2>/dev/null)
else
    disc_list=""

    # Detector helper: process + port + config + active_verify + description -> confidence
    detect_svc() {
        _name="$1"; _type="$2"; _proc="$3"; _porthex="$4"; _config="$5"; _portdec="$6"; _desc="$7"
        _conf=0; _evidence=""; _missing=""; _no_hardware=0
        # 1. Process detection
        if pidof "$_proc" >/dev/null 2>&1; then
            _conf=$((_conf + 30)); _evidence="${_evidence}\"process\","
        else
            _missing="${_missing}\"process\","
        fi
        # 2. Port detection
        #
        # Sluzba bez portu (hostapd) se sem dostavala s prazdnym vzorem - a
        # `grep -qi ""` sedi na kazdy radek, takze detektor si pripsal dukaz
        # "port", aniz cokoli hledal. Na routeru bez jedine Wi-Fi karty pak
        # hlasil "Hostapd Wi-Fi AP" s jistotou 99 %. Overeno na cistem OpenWrt.
        #
        # Bez portu se tedy nehodnoti ani jako nalezeny, ani jako chybejici -
        # ta sluzba zadny nema, takze to o ni nic nevypovida.
        if [ -z "$_porthex" ]; then
            :
        elif [ -f /proc/net/tcp ] && grep -qi "$_porthex" /proc/net/tcp 2>/dev/null; then
            _conf=$((_conf + 25)); _evidence="${_evidence}\"port\","
        elif [ -f /proc/net/tcp6 ] && grep -qi "$_porthex" /proc/net/tcp6 2>/dev/null; then
            _conf=$((_conf + 25)); _evidence="${_evidence}\"port\","
        else
            _missing="${_missing}\"port\","
        fi
        # 3. Config file
        if [ -n "$_config" ] && [ -f "$_config" ]; then
            _conf=$((_conf + 25)); _evidence="${_evidence}\"config\","
        elif [ -n "$_config" ]; then
            _missing="${_missing}\"config\","
        fi
        # 4. Active verification (service-specific, adds up to 19)
        _active_ok=0
        case "$_type" in
            teamspeak)
                if command -v nc >/dev/null 2>&1 && echo "version" | nc -w2 127.0.0.1 ${_portdec:-10011} 2>/dev/null | grep -qi "TS3"; then _active_ok=1; fi
                ;;
            minecraft)
                if [ -f /proc/net/tcp ] && grep -qi "63DD" /proc/net/tcp 2>/dev/null; then _active_ok=1; fi
                ;;
            docker)
                if [ -S /var/run/docker.sock ]; then _active_ok=1; fi
                ;;
            wireguard)
                if command -v wg >/dev/null 2>&1 && [ -n "$(wg show all dump 2>/dev/null)" ]; then _active_ok=1; fi
                ;;
            wifi)
                # Rozhoduje hardware, ne bezici proces.
                #
                # hostapd bezi i na routeru bez jedine bezdratove karty - jen
                # nema co vysilat. Jadro vystavuje kazde radio v
                # /sys/class/ieee80211 a nepotrebuje k tomu zadny balicek
                # (lsusb ani lspci na OpenWrt casto nejsou). Prazdny adresar
                # znamena, ze tam Wi-Fi opravdu neni - to neni nejistota,
                # to je odpoved.
                if [ -n "$(ls /sys/class/ieee80211 2>/dev/null)" ]; then
                    _active_ok=1
                elif [ ! -d /sys/class/ieee80211 ] && command -v iwinfo >/dev/null 2>&1 \
                     && [ -n "$(iwinfo 2>/dev/null | awk '/^[a-z0-9]/ {print $1; exit}')" ]; then
                    # Starsi jadra bez toho adresare - pak se ptame iwinfo.
                    _active_ok=1
                else
                    # Zadne radio = sluzba se nehlasi vubec. Hlasit "Wi-Fi AP
                    # na 55 %" na routeru, kde zadna karta neni, je sum: dukazy
                    # sedi (proces, konfigurak), ale zaver z nich neplyne.
                    _no_hardware=1
                fi
                ;;
            *)
                # Generic: if process + port both found, count as active
                if [ $_conf -ge 55 ]; then _active_ok=1; fi
                ;;
        esac
        if [ $_active_ok -eq 1 ]; then
            _conf=$((_conf + 19)); _evidence="${_evidence}\"active_verify\","
        else
            _missing="${_missing}\"active_verify\","
        fi
        # Cap at 99
        [ $_conf -gt 99 ] && _conf=99
        # Only report if confidence >= 50 and the hardware actually exists.
        if [ $_conf -ge 50 ] && [ $_no_hardware -eq 0 ]; then
            _evidence=$(echo "$_evidence" | sed 's/,$//')
            _missing=$(echo "$_missing" | sed 's/,$//')
            _desc_esc=$(json_str "$_desc")
            [ -n "$disc_list" ] && disc_list="$disc_list, "
            disc_list="${disc_list}{\"name\":\"$_name\",\"type\":\"$_type\",\"process\":\"$_proc\",\"port\":${_portdec:-0},\"confidence\":$_conf,\"description\":\"$_desc_esc\",\"evidence\":[$_evidence],\"missing\":[$_missing]}"
        fi
    }

    # Run detectors
    detect_svc "Knot Resolver (kresd)" "dns" "kresd" "0035" "/etc/config/resolver" 53 "Moderní DNS resolver CZ.NIC s podporou DNS-over-TLS (DoT)"
    detect_svc "Dnsmasq" "dns" "dnsmasq" "0035" "/etc/config/dhcp" 53 "DHCP server a lokální DNS keš pro domácí síť"
    detect_svc "Hostapd Wi-Fi AP" "wifi" "hostapd" "" "/etc/config/wireless" 0 "Démon pro správu bezdrátových Wi-Fi sítí (802.11)"
    detect_svc "Dropbear SSH" "ssh" "dropbear" "0016" "/etc/config/dropbear" 22 "Zabezpečený SSH přístup pro vzdálenou správu routeru"
    detect_svc "OpenSSH Server" "ssh" "sshd" "0016" "/etc/ssh/sshd_config" 22 "Plnohodnotný OpenSSH server"
    detect_svc "uHTTPd Web UI" "web" "uhttpd" "0050" "/etc/config/uhttpd" 80 "Webový server pro administraci LuCI / Rebuilt"
    detect_svc "Lighttpd Web" "web" "lighttpd" "0050" "/etc/lighttpd/lighttpd.conf" 80 "Lehký webový server pro administraci TurrisOS"
    detect_svc "Mosquitto MQTT" "mqtt" "mosquitto" "075B" "/etc/mosquitto/mosquitto.conf" 1883 "MQTT Message Broker pro IoT zařízení a chytrou domácnost (Home Assistant, senzory)"
    detect_svc "WireGuard VPN" "vpn" "wireguard" "" "/etc/config/wireguard" 51820 "Šifrovaný VPN tunel pro bezpečné připojení odkudkoliv"
    detect_svc "OpenVPN" "vpn" "openvpn" "0476" "/etc/config/openvpn" 1194 "SSL/TLS VPN server"
    detect_svc "AdGuard Home" "dns" "AdGuardHome" "0BB8" "/usr/bin/AdGuardHome" 3000 "Blokování reklam a sledování na úrovni celé sítě"
    detect_svc "Turris Sentinel / Pakon" "security" "sentinel" "" "/etc/config/sentinel" 0 "Systém detekce kybernetických hrozeb a sběru dat CZ.NIC"
    detect_svc "Samba SMB File Share" "storage" "smbd" "01BD" "/etc/samba/smb.conf" 445 "Sdílení souborů v lokální síti (NAS / Windows Share)"
    detect_svc "Nginx Web Server" "web" "nginx" "0050" "/etc/nginx/nginx.conf" 80 "Vysoce výkonný webový server a reverzní proxy"
    detect_svc "Docker Engine" "container" "dockerd" "" "/var/run/docker.sock" 2375 "Kontejnerová platforma pro spouštění aplikací"
    detect_svc "PostgreSQL DB" "database" "postgres" "1538" "/etc/postgresql/postgresql.conf" 5432 "Relační databázový systém"
    detect_svc "TeamSpeak 3 Server" "teamspeak" "ts3server" "271B" "/etc/ts3server.ini" 10011 "TeamSpeak 3 hlasový komunikační server"
    detect_svc "Minecraft Server" "minecraft" "java" "63DD" "" 25565 "Minecraft herní server"

    [ -n "$disc_list" ] && discovered_services_json="[$disc_list]" || discovered_services_json="[]"
    echo "$discovered_services_json" > "$SVC_CACHE_FILE" 2>/dev/null || true
fi

[ -z "$top_cpu_json" ] && top_cpu_json="[]"
[ -z "$top_ram_json" ] && top_ram_json="[]"
[ -z "$wifi_radios_json" ] && wifi_radios_json="[]"
[ -z "$interfaces_json" ] && interfaces_json="[]"
[ -z "$wireguard_peers_json" ] && wireguard_peers_json="[]"
[ -z "$mwan3_policies_json" ] && mwan3_policies_json="[]"
[ -z "$service_restarts_json" ] && service_restarts_json="[]"
[ -z "$mwan3_active_gw" ] && mwan3_active_gw="null"

# Sanitace všech numerických proměnných
for var in cpu ram ram_total_mb ram_used_mb ram_available_mb ram_free_mb swap_pct entropy conntrack_pct upgradable_packages wifi_clients_count dhcp_leases_count dhcp_reservations_count dns_queries dns_cache_hits dns_cache_misses fw_accepted fw_dropped fw_rejected net net_ipv4_kbps net_ipv6_kbps hdd disk_io_write btrfs_errors load1 load5 load15 uptime_sec temperature wan_uptime sqm_download_kbps sqm_upload_kbps sqm_dropped sqm_ecn lte_rsrp lte_rsrq lte_sinr wan_reconnect_count wan_last_reconnect installed_packages log_errors_24h log_warnings_24h; do
    eval "val=\$$var"
    if [ -z "$val" ] || [ "$val" = "" ]; then
        eval "$var=\"null\""
    elif ! echo "$val" | grep -q '^-\?[0-9.]\+$'; then
        eval "$var=\"null\""
    fi
done

# TCP Retransmissions & Conntrack Count & Inode Usage for OpenWrt
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
elif [ -f /proc/net/nf_conntrack ]; then
    cnt=$(wc -l < /proc/net/nf_conntrack 2>/dev/null)
    [ -n "$cnt" ] && conntrack_count_json="$cnt"
fi

inode_usage_json="null"
inode_usage=$(df -i / 2>/dev/null | tail -n 1 | awk '{print $5}' | tr -d '%')
if [ -n "$inode_usage" ] && [ "$inode_usage" -eq "$inode_usage" ] 2>/dev/null; then
    inode_usage_json="$inode_usage"
fi

payload=$(cat <<EOF
{
  "agent_key": "$(json_str "$AGENT_KEY")",
  "agent_type": "openwrt",
  "version": "$AGENT_VERSION",
  "heavy_op_interval_hours": ${HEAVY_OP_INTERVAL_HOURS:-24},
  "os": "$(json_str "$os_combined")",
  "cpu": $cpu,
  "ram": $ram,
  "ram_total_mb": $ram_total_mb,
  "ram_used_mb": $ram_used_mb,
  "ram_available_mb": $ram_available_mb,
  "ram_free_mb": $ram_free_mb,
  "swap_pct": $swap_pct,
  "entropy": $entropy,
  "conntrack_pct": $conntrack_pct,
  "tcp_retrans": $tcp_retrans_json,
  "conntrack_count": $conntrack_count_json,
  "inode_usage": $inode_usage_json,
  "upgradable_packages": $upgradable_packages,
  "wifi_clients_count": $wifi_clients_count,
  "wifi_radios": $wifi_radios_json,
  "interfaces": $interfaces_json,
  "discovered_services": $discovered_services_json,
  "lan_subnet": "$(json_str "$lan_subnet")",
  "dhcp_leases_count": $dhcp_leases_count,
  "dhcp_reservations_count": $dhcp_reservations_count,
  "dns_queries": $dns_queries,
  "dns_cache_hits": $dns_cache_hits,
  "dns_cache_misses": $dns_cache_misses,
  "dns_engine": "$(json_str "$dns_engine")",
  "dns_encryption": "$(json_str "$dns_encryption")",
  "dns_servers": "$(json_str "$dns_servers")",
  "firewall_enabled": $firewall_enabled,
  "fw_accepted": $fw_accepted,
  "fw_dropped": $fw_dropped,
  "fw_rejected": $fw_rejected,
  "wireguard_peers": $wireguard_peers_json,
  "speedtests": $speedtests_json,
  "filesystems": $filesystems_json,
  "disk_devices": $disk_devices_json,
  "top_io_processes": $top_io_json,
  "io_accounting": $io_accounting_json,
  "top_cpu_processes": $top_cpu_json,
  "top_ram_processes": $top_ram_json,
  "net": $net,
  "net_ipv4_kbps": $net_ipv4_kbps,
  "net_ipv6_kbps": $net_ipv6_kbps,
  "hdd": $hdd,
  "disk_io_write": $disk_io_write,
  "btrfs_errors": $btrfs_errors,
  "load1": $load1,
  "load5": $load5,
  "load15": $load15,
  "uptime": $uptime_sec,
  "temperature": $temperature,
  "hostname": "$(json_str "$ow_hostname")",
  "kernel": "$(json_str "$ow_kernel")",
  "model": "$(json_str "$ow_model")",
  "board_name": "$(json_str "$ow_board_name")",
  "wan_up": $wan_up_json,
  "wan_proto": "$(json_str "$wan_proto")",
  "wan_ipv4": "$(json_str "$wan_ipv4")",
  "wan_ipv6": "$(json_str "$wan_ipv6")",
  "wan_gateway": "$(json_str "$wan_gateway")",
  "wan_dns": "$(json_str "$wan_dns")",
  "wan_uptime": $wan_uptime,
  "mwan3_policies": $mwan3_policies_json,
  "mwan3_active_gw": $mwan3_active_gw,
  "sqm_enabled": $sqm_enabled,
  "sqm_download_kbps": $sqm_download_kbps,
  "sqm_upload_kbps": $sqm_upload_kbps,
  "sqm_dropped": $sqm_dropped,
  "sqm_ecn": $sqm_ecn,
  "lte_up": $lte_up,
  "lte_device": $(json_val "$lte_device"),
  "lte_uptime": $lte_uptime,
  "lte_ipv4": $(json_val "$lte_ipv4"),
  "lte_rssi": $lte_rssi,
  "lte_pci": $lte_pci,
  "lte_cell_id": $lte_cell_id,
  "lte_bandwidth": $lte_bandwidth,
  "lte_plmn": $lte_plmn,
  "lte_rsrp": $lte_rsrp,
  "lte_rsrq": $lte_rsrq,
  "lte_sinr": $lte_sinr,
  "lte_band": $(json_val "$lte_band"),
  "lte_carrier": $(json_val "$lte_carrier"),
  "lte_connected": $lte_connected,
  "lte_sim_state": $(json_val "$lte_sim_state"),
  "lte_conn_code": $lte_conn_code,
  "lte_sim_code": $lte_sim_code,
  "lte_service_code": $lte_service_code,
  "lte_sim_status_code": $lte_sim_status_code,
  "lte_sim_pin_left": $lte_sim_pin_left,
  "service_restarts": $service_restarts_json,
  "wan_reconnect_count": $wan_reconnect_count,
  "wan_last_reconnect": $wan_last_reconnect,
  "installed_packages": $installed_packages,
  "log_errors_24h": $log_errors_24h,
  "tailscale_up": $tailscale_up_json,
  "tailscale_peers": $tailscale_peers_json,
  "zerotier_networks": $zerotier_networks_json,
  "ups_status": $ups_status_json,
  "ups_battery_pct": $ups_battery_json,
  "auto_update": $([ "$AUTO_UPDATE" = "1" ] && echo 1 || echo 0),
  "oom_kills": $oom_kills,
  "boot_time": $boot_time,
  "dns_latency_ms": $dns_latency_ms,
  "wan_latency_ms": $wan_latency_ms,
  "wan_link_mbit": $wan_link_mbit,
  "openvpn_tunnels": $openvpn_tunnels,
  "usb_devices": $usb_devices,
  "log_warnings_24h": $log_warnings_24h
}
EOF
)

echo "$payload" > /tmp/status-agent-openwrt-last-payload.json 2>/dev/null || true

if [ "$DRY_RUN" = "1" ]; then
    printf '%s\n' "$payload"
    log_debug "Rezim --dry-run: data se neodesilaji."
    exit 0
fi

log_debug "Odesilam data na $API_URL..."

http_code=""
body=""

if command -v curl >/dev/null 2>&1; then
    response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d "$payload" "$API_URL")
    http_code=$(echo "$response" | tail -n 1)
    body=$(echo "$response" | head -n -1)
elif command -v uclient-fetch >/dev/null 2>&1; then
    # uclient-fetch je soucasti zakladni instalace OpenWrt a na rozdil od
    # holeho BusyBox wget ma spolehlivou HTTPS podporu (ustream-ssl).
    body=$(uclient-fetch -q -O - --post-data="$payload" --header="Content-Type: application/json" "$API_URL" 2>/dev/null)
    [ -n "$body" ] && http_code="200"
elif command -v wget >/dev/null 2>&1; then
    headers_file=$(mktemp /tmp/status-openwrt-wget-hdr.XXXXXX 2>/dev/null || echo "/tmp/status-openwrt-wget-hdr-$$")
    body=$(wget --post-data="$payload" --header="Content-Type: application/json" --server-response -q -O - "$API_URL" 2>"$headers_file")
    http_code=$(grep -E '^[[:space:]]*HTTP/' "$headers_file" | tail -n 1 | awk '{print $2}')
    rm -f "$headers_file"
else
    log_message "CHYBA: Neni k dispozici curl, uclient-fetch ani wget. Nelze odeslat data."
    exit 1
fi

if [ "$http_code" = "200" ]; then
    log_debug "OK: Statistiky uspesne odeslany."

    # Potvrzeni provedeni akce zpet na server - bez tohohle by agent_actions.status
    # zustal navzdy na 'sent' ("odeslano, ceka na potvrzeni") v administraci, i kdyz
    # se akce ve skutecnosti provedla. Samostatny lehky POST, protoze hlavni
    # telemetrie uz pro tento cyklus odesla.
    send_action_result() {
        ar_id="$1"; ar_status="$2"; ar_msg="$3"
        ar_payload="{\"agent_key\":\"$(json_str "$AGENT_KEY")\",\"action_result\":{\"action_id\":${ar_id},\"status\":\"$(json_str "$ar_status")\",\"message\":\"$(json_str "$ar_msg")\"}}"
        if command -v curl >/dev/null 2>&1; then
            curl -s -m 10 -X POST -H "Content-Type: application/json" -d "$ar_payload" "$API_URL" >/dev/null 2>&1
        elif command -v uclient-fetch >/dev/null 2>&1; then
            uclient-fetch -q -T 10 -O /dev/null --post-data="$ar_payload" --header="Content-Type: application/json" "$API_URL" >/dev/null 2>&1
        elif command -v wget >/dev/null 2>&1; then
            wget -T 10 --post-data="$ar_payload" --header="Content-Type: application/json" -q -O /dev/null "$API_URL" >/dev/null 2>&1
        fi
    }

    # --- Spracovani vzdalenych akci (Remote Actions) ---
    REMOTE_ACTIONS_ENABLED="${REMOTE_ACTIONS_ENABLED:-0}"
    ALLOWED_ACTIONS="${ALLOWED_ACTIONS:-restart_wan,restart_wireguard,reboot_router,renew_dhcp,restart_service,reconnect_pppoe}"
    
    if [ "$REMOTE_ACTIONS_ENABLED" = "1" ] && [ -n "$body" ]; then
        act_id=$(echo "$body" | awk -F'"action_id":' '{print $2}' | awk -F'[,}]' '{print $1}' | tr -d '[:space:]')
        act_type=$(echo "$body" | awk -F'"action":' '{print $2}' | awk -F'[,"]' '{print $2}' | tr -d '[:space:]')
        act_ts=$(echo "$body" | awk -F'"timestamp":' '{print $2}' | awk -F'[,}]' '{print $1}' | tr -d '[:space:]')
        act_sig=$(echo "$body" | awk -F'"signature":' '{print $2}' | awk -F'[,"]' '{print $2}' | tr -d '[:space:]')
        act_nonce=$(echo "$body" | awk -F'"nonce":' '{print $2}' | awk -F'[,"]' '{print $2}' | tr -d '[:space:]')
        
        if [ -n "$act_id" ] && [ -n "$act_type" ] && [ -n "$act_ts" ] && [ -n "$act_sig" ]; then
            now_ts=$(date +%s 2>/dev/null || echo 0)
            time_diff=$((now_ts - act_ts))
            [ $time_diff -lt 0 ] && time_diff=$(( -time_diff ))
            
            if [ $time_diff -le 30 ]; then
                calc_str="action=${act_type}|ts=${act_ts}|nonce=${act_nonce}"
                calc_sig=""
                if command -v openssl >/dev/null 2>&1; then
                    calc_sig=$(echo -n "$calc_str" | openssl dgst -sha256 -hmac "$AGENT_KEY" 2>/dev/null | awk '{print $NF}')
                fi
                
                if [ -n "$calc_sig" ] && [ "$calc_sig" = "$act_sig" ]; then
                    log_message "Aktivovana bezpecna vzdalena akce: $act_type (ID: $act_id)"
                    case "$act_type" in
                        restart_wan)
                            /sbin/ifdown wan >/dev/null 2>&1 || true
                            sleep 2
                            /sbin/ifup wan >/dev/null 2>&1 || true
                            send_action_result "$act_id" "executed" "WAN restartovano"
                            ;;
                        restart_wireguard)
                            /sbin/ifdown wg0 >/dev/null 2>&1 || true
                            sleep 1
                            /sbin/ifup wg0 >/dev/null 2>&1 || true
                            send_action_result "$act_id" "executed" "WireGuard (wg0) restartovan"
                            ;;
                        renew_dhcp)
                            ubus call network.interface.wan renew >/dev/null 2>&1 || true
                            send_action_result "$act_id" "executed" "DHCP najem na WAN obnoven"
                            ;;
                        reconnect_pppoe)
                            /sbin/ifdown wan >/dev/null 2>&1 || true
                            sleep 3
                            /sbin/ifup wan >/dev/null 2>&1 || true
                            send_action_result "$act_id" "executed" "PPPoE znovu pripojeno"
                            ;;
                        restart_service)
                            # Service name je v poli "service_name" v payloadu akce
                            svc_name=$(echo "$body" | sed -n 's/.*"service_name":"\([^"]*\)".*/\1/p')
                            if [ -n "$svc_name" ] && [ -x "/etc/init.d/$svc_name" ]; then
                                /etc/init.d/"$svc_name" restart >/dev/null 2>&1 || true
                                log_message "Restartovana sluzba: $svc_name"
                                send_action_result "$act_id" "executed" "Sluzba '$svc_name' restartovana"
                            else
                                log_message "VAROVANI: Sluzba '$svc_name' nenalezena nebo neni spustitelna."
                                send_action_result "$act_id" "failed" "Sluzba '$svc_name' nenalezena nebo neni spustitelna"
                            fi
                            ;;
                        reboot_router)
                            log_message "PROVADIM REBOOT ROUTERU DLE PODEPSANEHO POKYNU..."
                            # Potvrzeni musi odejit PRED rebootem - jakmile /sbin/reboot
                            # ukonci proces, uz se nic dalsiho neprovede.
                            send_action_result "$act_id" "executed" "Router se restartuje"
                            /sbin/reboot >/dev/null 2>&1 || true
                            ;;
                    esac
                else
                    log_message "VAROVANI: Odmitnuta vzdalena akce - neplatny HMAC podpis!"
                    send_action_result "$act_id" "failed" "Neplatny HMAC podpis"
                fi
            else
                log_message "VAROVANI: Odmitnuta vzdalena akce - vyprsena platnost (casove okno > 30s)"
                send_action_result "$act_id" "failed" "Vyprsela platnost podpisu (>30s)"
            fi
        fi
    fi
    # --- 5c. Agent-side kontroly sluzeb (LAN cile nedosazitelne z hostingu) ---
    # Server v odpovedi posila seznam 'agent_service' monitoru tohoto assetu.
    # Agent kazdy overi lokalne - bezici proces (pidof) a naslouchajici port
    # (/proc/net/tcp, tcp6 i udp) - a vysledky posle zpet jako
    # service_check_results. Zadna latence se nemeri; posila se jen fakt,
    # jestli sluzba bezi (vymyslene 0 ms by bylo horsi nez nic).
    if echo "$body" | grep -q '"service_checks":\['; then
        sc_list=$(echo "$body" | sed -n 's/.*"service_checks":\[\(.*\)\].*/\1/p' | sed 's/}[[:space:]]*,[[:space:]]*{/}|{/g')
        sc_results=""
        SC_OLD_IFS=$IFS
        IFS='|'
        for sc_obj in $sc_list; do
            sc_id=$(echo "$sc_obj" | sed -n 's/.*"monitor_id":\([0-9]*\).*/\1/p')
            sc_proc=$(echo "$sc_obj" | sed -n 's/.*"process":"\([^"]*\)".*/\1/p')
            sc_port=$(echo "$sc_obj" | sed -n 's/.*"port":\([0-9]*\).*/\1/p')
            [ -z "$sc_id" ] && continue
            sc_running=0
            sc_detail=""
            if [ -n "$sc_proc" ] && pidof "$sc_proc" >/dev/null 2>&1; then
                sc_running=1
                sc_detail="Proces $sc_proc bezi"
            fi
            if [ "$sc_running" = "0" ] && [ -n "$sc_port" ] && [ "$sc_port" != "0" ]; then
                sc_hex=$(printf ':%04X' "$sc_port" 2>/dev/null)
                if grep -qi "$sc_hex" /proc/net/tcp 2>/dev/null || grep -qi "$sc_hex" /proc/net/tcp6 2>/dev/null || grep -qi "$sc_hex" /proc/net/udp 2>/dev/null; then
                    sc_running=1
                    sc_detail="Port $sc_port nasloucha"
                fi
            fi
            if [ "$sc_running" = "0" ]; then
                sc_detail="Na routeru nebezi proces '${sc_proc:-?}' ani nenasloucha port ${sc_port:-0}"
            fi
            sc_bool="false"
            [ "$sc_running" = "1" ] && sc_bool="true"
            [ -n "$sc_results" ] && sc_results="$sc_results, "
            sc_results="${sc_results}{\"monitor_id\":$sc_id,\"running\":$sc_bool,\"detail\":\"$(json_str "$sc_detail")\"}"
        done
        IFS=$SC_OLD_IFS

        if [ -n "$sc_results" ]; then
            sc_payload="{\"agent_key\":\"$(json_str "$AGENT_KEY")\",\"service_check_results\":[$sc_results]}"
            if command -v curl >/dev/null 2>&1; then
                curl -s -m 10 -X POST -H "Content-Type: application/json" -d "$sc_payload" "$API_URL" >/dev/null 2>&1
            elif command -v uclient-fetch >/dev/null 2>&1; then
                uclient-fetch -q -T 10 -O /dev/null --post-data="$sc_payload" --header="Content-Type: application/json" "$API_URL" >/dev/null 2>&1
            elif command -v wget >/dev/null 2>&1; then
                wget -T 10 --post-data="$sc_payload" --header="Content-Type: application/json" -q -O /dev/null "$API_URL" >/dev/null 2>&1
            fi
            log_debug "Odeslany vysledky agent-side kontrol sluzeb."
        fi
    fi

    # --- 6. Automatická aktualizace agenta (opt-in přes AUTO_UPDATE=1) ---
    # Server v odpovědi oznámí novější verzi včetně SHA-256 checksumu. Nová verze
    # se stáhne do dočasného souboru, ověří se checksum i syntaxe (sh -n) a teprve
    # potom se atomicky nahradí tento skript. Při dalším spuštění (cron) už poběží
    # nová verze.
    if [ "$AUTO_UPDATE" = "1" ]; then
        update_available=$(echo "$body" | grep -o '"update_available":[a-z]*' | cut -d: -f2)
        if [ "$update_available" = "true" ]; then
            update_url=$(echo "$body" | sed -n 's/.*"update_url":"\([^"]*\)".*/\1/p' | sed 's,\\/,/,g')
            update_sha=$(echo "$body" | sed -n 's/.*"update_sha256":"\([a-f0-9]*\)".*/\1/p')
            latest_version=$(echo "$body" | sed -n 's/.*"latest_version":"\([^"]*\)".*/\1/p')

            if [ -n "$update_url" ] && [ -n "$update_sha" ]; then
                self_path="$0"
                tmp_file=$(mktemp /tmp/status-openwrt-update.XXXXXX 2>/dev/null || echo "/tmp/status-openwrt-update-$$")
                log_message "K dispozici je nova verze agenta $latest_version (aktualni $AGENT_VERSION), stahuji z $update_url..."

                download_ok=0
                if command -v curl >/dev/null 2>&1; then
                    curl -fsS -o "$tmp_file" "$update_url" && download_ok=1
                elif command -v uclient-fetch >/dev/null 2>&1; then
                    uclient-fetch -q -O "$tmp_file" "$update_url" && download_ok=1
                elif command -v wget >/dev/null 2>&1; then
                    wget -q -O "$tmp_file" "$update_url" && download_ok=1
                fi

                if [ "$download_ok" = "1" ]; then
                    actual_sha=""
                    if command -v sha256sum >/dev/null 2>&1; then
                        actual_sha=$(sha256sum "$tmp_file" | awk '{print $1}')
                    elif command -v shasum >/dev/null 2>&1; then
                        actual_sha=$(shasum -a 256 "$tmp_file" 2>/dev/null | awk '{print $1}')
                    fi

                    if [ -n "$actual_sha" ] && [ "$actual_sha" = "$update_sha" ]; then
                        if sh -n "$tmp_file" 2>/dev/null; then
                            cp "$self_path" "$self_path.bak" 2>/dev/null || true
                            chmod +x "$tmp_file"
                            if mv "$tmp_file" "$self_path"; then
                                log_message "OK: Agent aktualizovan na verzi $latest_version. Nova verze se pouzije pri pristim spusteni."
                                exit 0
                            else
                                log_message "CHYBA UPDATE: Nepodarilo se nahradit $self_path (prava?). Aktualizace zrusena."
                            fi
                        else
                            log_message "CHYBA UPDATE: Stazeny soubor neprosel kontrolou syntaxe. Aktualizace zrusena."
                        fi
                    else
                        log_message "CHYBA UPDATE: Checksum nesouhlasi (oceavan $update_sha, stazen $actual_sha). Aktualizace zrusena."
                    fi
                else
                    log_message "CHYBA UPDATE: Stazeni nove verze se nezdarilo."
                fi
                rm -f "$tmp_file" 2>/dev/null || true
            fi
        fi
    fi

    log_debug "Hotovo."
else
    log_message "CHYBA: Odeslani selhalo (HTTP $http_code). Odpoved: $body"
    exit 1
fi
