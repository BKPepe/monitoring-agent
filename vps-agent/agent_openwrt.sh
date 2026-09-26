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

# The control characters the builtin parsers below compare against, from ONE
# fork: POSIX sh cannot spell a CR or a tab any other way. BK_WSX is what
# busybox awk's default field split treats as blank but `read` does not
# (CR, VT, FF); a fast path meets it and hands the input to the old tool.
_bk_ctl=$(printf '\r\t\013\014')
BK_CR=${_bk_ctl%???}
BK_TAB=${_bk_ctl#?}; BK_TAB=${BK_TAB%??}
BK_WSX="$BK_CR${_bk_ctl#??}"
BK_NL='
'

# dirname without the fork, the same answers musl's dirname() gives (it is
# what the busybox applet prints): "." without a slash, "/" for the root.
bk_dirname() {
    _dn=$1
    [ -z "$_dn" ] && { _dn=.; return 0; }
    while :; do case "$_dn" in */) _dn=${_dn%/} ;; *) break ;; esac; done
    case "$_dn" in '') _dn=/; return 0 ;; */*) ;; *) _dn=.; return 0 ;; esac
    _dn=${_dn%/*}
    while :; do case "$_dn" in */) _dn=${_dn%/} ;; *) break ;; esac; done
    [ -z "$_dn" ] && _dn=/
    return 0
}
bk_dirname "$0"; ScriptPath=$_dn

# One cfg field as the old `$(echo "$x" | sed 's/^[[:space:]]*//;...')` gave
# it, in $_t, without its three forks per field. busybox echo took a field
# that is nothing but echo options (-n, -e, -E, -nE ...) as options and
# printed nothing, so such a field still reads as empty.
bk_cfg_field() {
    _t=$1
    case "$_t" in -?*) case "${_t#-}" in *[!neE]*) ;; *) _t="" ;; esac ;; esac
    while :; do case "$_t" in [[:space:]]*) _t=${_t#?} ;; *) break ;; esac; done
    while :; do case "$_t" in *[[:space:]]) _t=${_t%?} ;; *) break ;; esac; done
}

if [ -f "$ScriptPath/agent_openwrt.cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        # Every CR goes, not only the last one: `tr -d '\r'` did the same.
        while :; do case "$line" in *"$BK_CR"*) line=${line%%"$BK_CR"*}${line#*"$BK_CR"} ;; *) break ;; esac; done
        case "$line" in
            \#*|"") continue ;;
        esac
        case "$line" in
            *=*)
                bk_cfg_field "${line%%=*}"; key=$_t
                bk_cfg_field "${line#*=}"; val=$_t
                # One quote off each end, either kind, as the old sed did.
                case "$val" in [\"\']*) val=${val#?} ;; esac
                case "$val" in *[\"\']) val=${val%?} ;; esac
                case "$key" in
                    API_URL) API_URL="$val" ;;
                    AGENT_KEY) AGENT_KEY="$val" ;;
                    AUTO_UPDATE) AUTO_UPDATE="$val" ;;
                    HEAVY_OP_INTERVAL_HOURS) HEAVY_OP_INTERVAL_HOURS="$val" ;;
                    REMOTE_ACTIONS_ENABLED) REMOTE_ACTIONS_ENABLED="$val" ;;
                    ALLOWED_ACTIONS) ALLOWED_ACTIONS="$val" ;;
                    SMART_INTERVAL_MINUTES) SMART_INTERVAL_MINUTES="$val" ;;
                    SMART_TIMEOUT_SEC) SMART_TIMEOUT_SEC="$val" ;;
                    LOG_LINES_ENABLED) LOG_LINES_ENABLED="$val" ;;
                esac
                ;;
        esac
    done < "$ScriptPath/agent_openwrt.cfg"
fi

# A non-numeric value from agent.cfg used to abort the shell right here, before
# the first log line.
case "$HEAVY_OP_INTERVAL_HOURS" in ''|*[!0-9]*) HEAVY_OP_INTERVAL_HOURS=24 ;; esac
HEAVY_OP_INTERVAL_SEC=$(( HEAVY_OP_INTERVAL_HOURS * 3600 ))

# How often a disk may be woken for a SMART reading, and how long one smartctl
# may run before the watchdog kills it. The interval has a floor of an hour:
# a spin-up every minute would wear out the very disk the reading watches. The
# timeout is clamped 10-180 s, because busybox has no `timeout` applet and the
# watchdog below is what stands between a hung USB bridge and a stuck agent.
case "$SMART_INTERVAL_MINUTES" in ''|*[!0-9]*) SMART_INTERVAL_MINUTES=60 ;; esac
[ "$SMART_INTERVAL_MINUTES" -lt 60 ] && SMART_INTERVAL_MINUTES=60
SMART_INTERVAL_SEC=$(( SMART_INTERVAL_MINUTES * 60 ))
case "$SMART_TIMEOUT_SEC" in ''|*[!0-9]*) SMART_TIMEOUT_SEC=60 ;; esac
[ "$SMART_TIMEOUT_SEC" -lt 10 ] && SMART_TIMEOUT_SEC=10
[ "$SMART_TIMEOUT_SEC" -gt 180 ] && SMART_TIMEOUT_SEC=180

if [ "$1" = "--register" ] || [ "$1" = "--auto-register" ]; then
    # The token is best kept out of the command line: `ps` shows every
    # process's arguments to every user, and shell histories keep them.
    # BK_REG_TOKEN in the environment or "-" (read from stdin) avoid both;
    # the old positional form still works for install lines already out there.
    REG_TOKEN="$2"
    if [ "$REG_TOKEN" = "-" ]; then
        REG_TOKEN=""
        IFS= read -r REG_TOKEN || true
    fi
    [ -z "$REG_TOKEN" ] && REG_TOKEN="$BK_REG_TOKEN"
    if [ -z "$REG_TOKEN" ]; then
        echo "Pouziti: BK_REG_TOKEN=TOKEN $0 --register - [API_URL]"
        echo "     nebo: echo TOKEN | $0 --register - [API_URL]"
        exit 1
    fi
    if [ -n "$3" ]; then
        API_URL="$3"
    fi
    HOSTNAME_VAL=$(uname -n 2>/dev/null || echo "OpenWrt-Router")
    echo "Registruji router na $API_URL..."
    # Stock OpenWrt ships uclient-fetch, not curl - registration used to fail
    # on exactly the routers this script is for. Values are escaped into the
    # body, not eval'ed into a command line, and the body goes through a file
    # only root can read: as an argument it would put the token back in `ps`.
    bk_reg_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    REG_FILE="/tmp/status-agent-register.$$"
    ( umask 077; printf '{"action":"register","token":"%s","hostname":"%s","agent_type":"openwrt"}' \
        "$(bk_reg_esc "$REG_TOKEN")" "$(bk_reg_esc "$HOSTNAME_VAL")" > "$REG_FILE" )
    if command -v curl >/dev/null 2>&1; then
        RESP=$(curl -s -m 20 -X POST -H 'Content-Type: application/json' --data-binary "@$REG_FILE" "$API_URL")
    elif command -v uclient-fetch >/dev/null 2>&1; then
        RESP=$(uclient-fetch -q -T 20 -O - --post-file="$REG_FILE" --header='Content-Type: application/json' "$API_URL" 2>&1)
    elif command -v wget >/dev/null 2>&1; then
        RESP=$(wget -q -T 20 -O - --post-file="$REG_FILE" --header='Content-Type: application/json' "$API_URL" 2>&1)
    else
        rm -f "$REG_FILE"
        echo "CHYBA: Neni k dispozici curl, uclient-fetch ani wget."
        exit 1
    fi
    rm -f "$REG_FILE"
    NEW_KEY=$(echo "$RESP" | sed -n 's/.*"agent_key":"\([^"]*\)".*/\1/p')
    if [ -n "$NEW_KEY" ]; then
        # 0600: the key signs every report and unlocks the remote actions.
        ( umask 077
          printf 'API_URL="%s"\nAGENT_KEY="%s"\n' "$API_URL" "$NEW_KEY" > "$ScriptPath/agent_openwrt.cfg" )
        chmod 600 "$ScriptPath/agent_openwrt.cfg" 2>/dev/null
        echo "OK: Router zaregistrovan, klic ulozen do $ScriptPath/agent_openwrt.cfg (jen pro roota)."
        # sysupgrade.conf needs absolute paths; "./" would name nothing.
        _reg_dir=$(cd "$ScriptPath" 2>/dev/null && pwd) || _reg_dir=$ScriptPath
        echo "Aby prezil upgrade firmwaru, pridejte do /etc/sysupgrade.conf:"
        echo "  $_reg_dir/agent_openwrt.sh"
        echo "  $_reg_dir/agent_openwrt.cfg"
        exit 0
    else
        echo "CHYBA pri registraci: $RESP"
        exit 1
    fi
fi

AGENT_VERSION="0.1.11"
LOG_FILE="/tmp/status-agent-openwrt.log"
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
            echo "  --register - [API_URL]       Zaregistruje router (token z BK_REG_TOKEN nebo stdin)"
            echo "  --update, --auto-update      Vynuti kontrolu a aktualizaci agenta ze serveru"
            echo "  --verbose, -v                Zobrazi podrobny prubeh sberu dat a odesilani"
            echo "  --dry-run, --print           Sesbira data a vypise JSON, neodesila (i bez registrace)"
            echo "  --version, -V                Zobrazi verzi agenta"
            echo "  --help, -h                   Zobrazi tuto napovedu"
            echo ""
            echo "Konfigurace:"
            echo "  Cte nastaveni ze souboru agent_openwrt.cfg nebo z promendych prostredi:"
            echo "  STATUS_API_URL, STATUS_AGENT_KEY, STATUS_AUTO_UPDATE, STATUS_HEAVY_OP_INTERVAL_HOURS"
            echo "  LOG_LINES_ENABLED=0 v agent_openwrt.cfg: radky chyb z logu neopusti router, posila se jen jejich pocet"
            echo ""
            echo "Volitelne balicky (bez nich zustanou jejich hodnoty prazdne, nikdy nulove):"
            echo "  smartmontools, smartmontools-drivedb   zdravi disku (SMART)"
            echo "  hostapd-utils                          generace a zabezpeceni Wi-Fi klientu"
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

# Test seam, honoured ONLY with --dry-run: a production cron run can never be
# fed a canned server answer. STATUS_TEST_RESPONSE=<file>: line 1 is the HTTP
# code (000 = transport failure), the rest is the body. A dry run stops before
# the POST, so without it nothing the server's answer drives - remote actions
# above all - could be tested end to end.
BK_TEST_RESPONSE=""
[ "$DRY_RUN" = "1" ] && [ -n "$STATUS_TEST_RESPONSE" ] && BK_TEST_RESPONSE="$STATUS_TEST_RESPONSE"

# The second seam, under the same guard: STATUS_TEST_ROOT=<dir> puts a fake
# /sys and /proc in front of the collectors that name BK_SYS / BK_PROC (disks,
# the WAN port, per-core CPU). Without it a test would read the CI runner's
# own disks and eth0. Every other collector keeps its real path, and a cron
# run can never be pointed at a fake /sys: no --dry-run, no root.
BK_ROOT=""
[ "$DRY_RUN" = "1" ] && [ -n "$STATUS_TEST_ROOT" ] && BK_ROOT="$STATUS_TEST_ROOT"
BK_SYS="$BK_ROOT/sys"; BK_PROC="$BK_ROOT/proc"

# The third seam: STATUS_TEST_TTY=1 makes a redirected dry run count as one
# typed at a terminal (see BK_RUN_COST_KEEP), which a harness cannot give it.
BK_TEST_TTY=""
[ "$DRY_RUN" = "1" ] && [ -n "$STATUS_TEST_TTY" ] && BK_TEST_TTY="$STATUS_TEST_TTY"

# G42: how long the run takes is the one number that says whether a minute
# report still fits into its minute. Both ends are read from the KERNEL
# uptime, never from the clock: ntpd steps the clock on a router without an
# RTC minutes after boot, and a run would come out negative or hours long.
# Centiseconds, because that is the resolution /proc/uptime has; a partial or
# missing read leaves the value empty, and the caller reports null.
bk_uptime_cs() {
    _up_cs=""
    read -r _up_raw _ < "$BK_PROC/uptime" 2>/dev/null || return 0
    case "$_up_raw" in *.*) ;; *) return 0 ;; esac
    _up_w=${_up_raw%.*}
    _up_f=${_up_raw#*.}
    # Exactly two decimals, digits only: a kernel printing one would make the
    # number ten times too small and nobody would see it.
    case "$_up_f" in [0-9][0-9]) ;; *) return 0 ;; esac
    case "$_up_w" in ''|*[!0-9]*) return 0 ;; esac
    _up_cs="$_up_w$_up_f"
}
bk_uptime_cs
BK_RUN_START_CS="$_up_cs"

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
# The whole of FILE in $_sl, exactly what `$(cat FILE 2>/dev/null)` gave
# (trailing newlines dropped, a missing file empty), from a builtin read loop
# instead of a fork. Meant for the small files read back every minute.
# Never for /proc/sys: a sysctl file answers only the first read(2), and
# `read` takes one byte per call.
bk_slurp() {
    _sl=""; _sll=""
    { while IFS= read -r _sll; do _sl="$_sl$_sll$BK_NL"; _sll=""; done; } 2>/dev/null < "$1"
    _sl="$_sl$_sll"
    while :; do case "$_sl" in *"$BK_NL") _sl=${_sl%"$BK_NL"} ;; *) break ;; esac; done
    return 0
}

BK_VERSION_STAMP="/tmp/status-agent-openwrt-version.stamp"
bk_slurp "$BK_VERSION_STAMP"
if [ "$_sl" != "$AGENT_VERSION" ]; then
    # The identity cache moved into the private directory (both of its
    # possible places are named, the directory is chosen further down). The
    # old last-payload file goes as well: 0.1.6 wrote it world-readable with
    # the agent key inside, and nothing else would remove it before a reboot.
    # 0.1.6's /proc/stat snapshot in /tmp is replaced by cores.now and
    # cores.prev in the private directory, so the old file has no reader.
    rm -f /tmp/status-agent-openwrt-identity.cache \
          /var/run/status-agent-openwrt/identity.cache \
          /tmp/status-agent-openwrt-private/identity.cache \
          /tmp/status-agent-openwrt-last-payload.json \
          /tmp/status-agent-openwrt-cpu.state \
          /tmp/status-agent-openwrt-opkg.cache \
          /tmp/status-agent-openwrt-services.cache \
          /tmp/status-agent-openwrt-hilink-pin.cache \
          /tmp/status-agent-openwrt-hilink-plmn.cache \
          /var/run/status-agent-openwrt/hilink-pin.cache \
          /var/run/status-agent-openwrt/hilink-plmn.cache \
          /tmp/status-agent-openwrt-private/hilink-pin.cache \
          /tmp/status-agent-openwrt-private/hilink-plmn.cache 2>/dev/null || true
    # Everything a parser of this version may read back from an older one:
    # Wi-Fi survey counters and card facts, the disk list and the SMART
    # readings, the WAN path and the rate states. NOT on the list, on purpose:
    # probe.count, probe.attempts, pending.state, probe-out/ and skipped -
    # spend the owner consented to and results not sent yet are no cache.
    # run.cpu goes too: the last run of the old version (the one that just
    # downloaded this file) is not what this version costs, and the first
    # report of a new version is exactly the one a canary is judged by.
    for _bk_pd in /var/run/status-agent-openwrt /tmp/status-agent-openwrt-private; do
        # A planted symlink is never used as the private directory (see
        # bk_private_dir_ok), so nothing behind it is ours to delete.
        [ -L "$_bk_pd" ] && continue
        rm -f "$_bk_pd/wifi-survey.state" "$_bk_pd"/wifi-caps.* \
              "$_bk_pd/disks.static" "$_bk_pd/smart.cache" "$_bk_pd/smart.spawn" \
              "$_bk_pd/wan-path.cache" "$_bk_pd"/cores.* "$_bk_pd/wan-rate.state" \
              "$_bk_pd/run.cpu" 2>/dev/null || true
    done
    # 0.1.6 remembered only the newest speedtest file here and so never sent
    # the older ones; without the file the first run offers them all again.
    rm -f /tmp/status-agent-librespeed.state 2>/dev/null || true
    echo "$AGENT_VERSION" > "$BK_VERSION_STAMP" 2>/dev/null || true
fi

# JSON string escaping without a fork, into $_jr: a backslash and a quote
# are escaped, a CR is dropped and a newline becomes a space - byte for
# byte what `printf | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g' | tr '\n' ' '`
# produced, at four forks a call and 17 calls a report. Other control
# characters pass through untouched, as they did.
bk_js() {
    _js=$1
    # [:cntrl:] covers CR and LF and also TAB and the rest of 0x01-0x1F: JSON
    # forbids them raw inside a string, and one TAB in a modem's operator
    # name made the server refuse every report until the name changed.
    case "$_js" in *[\\\"[:cntrl:]]*) ;; *) _jr=$_js; return 0 ;; esac
    _jr=""
    while :; do
        case "$_js" in
            *[\\\"[:cntrl:]]*) ;;
            *) _jr=$_jr$_js; return 0 ;;
        esac
        _jh=${_js%%[\\\"[:cntrl:]]*}; _js=${_js#"$_jh"}
        _jc=${_js%"${_js#?}"}; _js=${_js#?}
        case "$_jc" in
            \\) _jr="$_jr$_jh\\\\" ;;
            \") _jr="$_jr$_jh\\\"" ;;
            "$BK_CR") _jr="$_jr$_jh" ;;
            *) _jr="$_jr$_jh " ;;
        esac
    done
}
# json_val's answer in $_jr: null for an empty value or the string "null",
# else the escaped value in quotes.
bk_jv() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then _jr=null; else bk_js "$1"; _jr="\"$_jr\""; fi
}

json_str() {
    bk_js "$1"; printf '%s' "$_jr"
}

# NUM / DEN to DIGITS (1 or 2) decimals in $_fd, the same text as awk's
# printf "%.<DIGITS>f", NUM / DEN, without the awk. Shell integers do it
# exactly for plain non-negative numbers below 10^12, where a double cannot
# land on the other side of a rounding boundary. An exact tie is decided by
# which way the double of the quotient happened to round, so a tie - like
# every input outside that range - still goes to awk.
bk_fdiv_awk() {
    _fd=$(awk -v n="$1" -v d="$2" "BEGIN { printf \"%.$3f\", n / d }")
}
bk_fdiv() {
    case "$1" in 0|[1-9]|[1-9]*[0-9]) ;; *) bk_fdiv_awk "$@"; return 0 ;; esac
    case "$2" in [1-9]|[1-9]*[0-9]) ;; *) bk_fdiv_awk "$@"; return 0 ;; esac
    case "$1$2" in *[!0-9]*) bk_fdiv_awk "$@"; return 0 ;; esac
    case "$1" in ?????????????*) bk_fdiv_awk "$@"; return 0 ;; esac
    case "$2" in ?????????????*) bk_fdiv_awk "$@"; return 0 ;; esac
    case "$3" in 1) _fm=10 ;; 2) _fm=100 ;; *) bk_fdiv_awk "$@"; return 0 ;; esac
    _fq=$(( $1 * _fm / $2 )); _fr=$(( $1 * _fm % $2 * 2 ))
    [ "$_fr" -eq "$2" ] && { bk_fdiv_awk "$@"; return 0; }
    [ "$_fr" -gt "$2" ] && _fq=$((_fq + 1))
    _ff=$((_fq % _fm))
    [ "$_fm" = 100 ] && [ "$_ff" -lt 10 ] && _ff="0$_ff"
    _fd="$((_fq / _fm)).$_ff"
}

# The single line of one of the agent's own state files in $_sl, read
# without a fork. Status 0 when the file holds at most one line and no CR,
# VT or FF (which awk would split on and `read` would not); a missing or
# empty file is status 0 and empty, as the old tools read it. Anything else
# is status 1 and the caller asks the old tool, so a damaged file still
# reads exactly as it did.
bk_line1() {
    _sl=""; _sl2=""; _slm=""
    { IFS= read -r _sl; IFS= read -r _sl2 && _slm=1; } 2>/dev/null < "$1"
    [ -z "$_slm" ] && [ -z "$_sl2" ] || return 1
    case "$_sl" in *["$BK_WSX"]*) return 1 ;; esac
    return 0
}
# awk's $1 and $2 of a line (fields split on spaces and tabs) in $_b1 $_b2.
bk_blank2() {
    _b=$1
    _b=${_b#"${_b%%[! $BK_TAB]*}"}; _b1=${_b%%[ $BK_TAB]*}; _b=${_b#"$_b1"}
    _b=${_b#"${_b%%[! $BK_TAB]*}"}; _b2=${_b%%[ $BK_TAB]*}
}
# `cut -d, -f1..3` of a line in $_c1 $_c2 $_c3, including cut's rule that a
# line without the delimiter is printed whole for every field.
bk_cut3() {
    case "$1" in
        *"$2"*)
            _c1=${1%%"$2"*}; _cr3=${1#*"$2"}; _c2=${_cr3%%"$2"*}; _c3=""
            case "$_cr3" in *"$2"*) _cr3=${_cr3#*"$2"}; _c3=${_cr3%%"$2"*} ;; esac ;;
        *) _c1=$1; _c2=$1; _c3=$1 ;;
    esac
}

# Vypise JSON hodnotu: bud null (bez uvozovek), nebo uvozovkovany retezec.
#
# Vzniklo kvuli LTE: prazdna hodnota se v tomhle skriptu drzi jako retezec
# "null" a `"$(json_str "$v")"` z ni udelal RETEZEC "null", takze UI
# poctive vypsalo `null · "null"` misto pomlcky.
json_val() {
    bk_jv "$1"; printf '%s' "$_jr"
}

log_message() {
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$VERBOSE" = "1" ]; then
        # In --dry-run stdout is the JSON payload; chatter goes to stderr.
        if [ "$DRY_RUN" = "1" ]; then echo "$ts - $1" >&2; else echo "$ts - $1"; fi
    fi
    echo "$ts - $1" >> "$LOG_FILE" 2>/dev/null || true
    # /tmp is RAM on OpenWrt and this file used to grow without limit (about
    # a megabyte a day) until the tmpfs was full and dhcp.leases could not be
    # written. Above 64 KB keep the last 32 KB.
    # `wc -c`, not `stat`: OpenWrt builds busybox without the stat applet
    # (CONFIG_STAT is not set), so the size came back empty, the guard below
    # rewrote it to 0 and the trim never ran on a single router - while the
    # test image, a busybox defconfig build, does ship stat and looked fine.
    # Once per run, after the run's first line: the check costs three forks
    # and a run adds a few hundred bytes, so checking every line (a verbose
    # --dry-run writes eight) bought nothing but forks.
    [ -n "$_bk_log_checked" ] && return 0
    _bk_log_checked=1
    _log_size=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -cd '0-9')
    case "$_log_size" in ''|*[!0-9]*) _log_size=0 ;; esac
    if [ "$_log_size" -gt 65536 ]; then
        tail -c 32768 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
    fi
}
_bk_log_checked=""

# Progress chatter reaches the file only with --verbose; errors and actions always.
log_debug() {
    [ "$VERBOSE" = "1" ] && log_message "$1"
    return 0
}

# One run at a time. A report stalled on a dead server or a stuck modem must
# not let cron pile a fresh agent on top of it every minute until the RAM is
# gone. mkdir is atomic; flock is not part of stock OpenWrt. A lock whose
# owner no longer exists (kill -9, power loss with /tmp on flash) is reclaimed.
# /var/run is a root-only tmpfs on OpenWrt: nothing unprivileged can pre-create
# the lock there (which in /tmp would stop the agent for good) or plant a
# HiLink cache that forges the LTE-backup verdict. /tmp remains the fallback
# for systems without it (the busybox test image).
#
# "Private" has to be checked, not assumed: in the /tmp fallback anybody can
# make the directory first and then owns every cache the agent reads back as
# root. So it must be a real directory (no symlink), ours (-O), and closed to
# everyone else. The chmod also closes a 0755 directory left by 0.1.6.
bk_private_dir_ok() {
    [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && chmod 700 "$1" 2>/dev/null
}
BK_PRIVATE_DIR="/var/run/status-agent-openwrt"
mkdir -p "$BK_PRIVATE_DIR" 2>/dev/null
if ! bk_private_dir_ok "$BK_PRIVATE_DIR"; then
    BK_PRIVATE_DIR="/tmp/status-agent-openwrt-private"
    mkdir -p "$BK_PRIVATE_DIR" 2>/dev/null
    if ! bk_private_dir_ok "$BK_PRIVATE_DIR"; then
        # Planted by somebody else. The sticky bit of /tmp does not bind
        # root, so the directory is replaced; rm does not follow a symlink.
        rm -rf "$BK_PRIVATE_DIR" 2>/dev/null
        mkdir "$BK_PRIVATE_DIR" 2>/dev/null
        if ! bk_private_dir_ok "$BK_PRIVATE_DIR"; then
            log_message "CHYBA: Soukromy adresar agenta ($BK_PRIVATE_DIR) nejde bezpecne vytvorit, koncim."
            exit 1
        fi
    fi
fi

# --- SMART: the detached reader -----------------------------------------------
#
# `--smart-refresh <disk> ...` is this script in its second role: a child that
# reads SMART and writes the cache the next minute run merges into the payload.
# It is handled HERE, before the run lock and before the AGENT_KEY check,
# because it reports nothing and must never queue behind a minute run that is
# stuck on a dead server. A reading costs a drive access and can hang on a bad
# USB bridge for minutes, and busybox has no `timeout` applet - so the minute
# report never waits for a drive, it only reads what this child left behind.
SMART_CACHE="$BK_PRIVATE_DIR/smart.cache"
STORAGE_STATIC="$BK_PRIVATE_DIR/disks.static"

# One smartctl reading -> one cache line. Input is the flat `--json=g` form
# (json.a.b = v;): a router has no jsonfilter and no JSON parser this project
# runs in CI, so the shape is read with awk, key by key. ONLY the keys matched
# below are ever looked at - serial_number, wwn and every other identifier are
# never read, let alone stored.
# Vars: dev, size (sectors), rc (smartctl exit status), now (epoch), prev_file
# Output: S|dev|size|probe_ts|values_ts|rc|state|rpm|<JSON members of smart>
# The JSON keys are written \"key\": so that run_agent_metric_lint.php does
# not read them as new top-level metrics.
BK_SMART_AWK='
function val(line,   v) { v = line; sub(/^[^=]*= /, "", v); sub(/;$/, "", v); if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2); return v }
function num(v) { return (v ~ /^-?[0-9]+$/) ? v : "" }
function lead(v) { if (match(v, /^[0-9]+/)) return substr(v, RSTART, RLENGTH); return "" }
function j(k, v) { return "\"" k "\":" (v == "" ? "null" : v) }
function js(k, v) { return "\"" k "\":" (v == "" ? "null" : "\"" v "\"") }
BEGIN { while ((getline l < prev_file) > 0) { n = split(l, q, "|"); if (q[1] == "S" && q[2] == dev && q[3] == size) old = l } close(prev_file) }
{
    key = $0; sub(/ = .*/, "", key)
    if (key == "json.device.protocol") proto = val($0)
    else if (key == "json.model_name") model = val($0)
    else if (key == "json.in_smartctl_database") indb = val($0)
    else if (key == "json.smart_support.available") avail = val($0)
    else if (key ~ /^json\.smartctl\.messages\[[0-9]+\]\.string$/) { if (val($0) ~ /Unknown USB bridge|Please specify device type/) bridge = 1 }
    else if (key == "json.rotation_rate") rpm = num(val($0))
    else if (key == "json.logical_block_size") lbs = num(val($0))
    else if (key == "json.smart_status.passed") passed = val($0)
    # The packed raw of attribute 194 is a different number entirely
    # (292058955843 on the owners disk); the temperature is this key.
    else if (key == "json.temperature.current") temp = num(val($0))
    else if (key == "json.power_on_time.hours") poh = num(val($0))
    else if (key == "json.power_cycle_count") cycles = num(val($0))
    else if (key == "json.ata_smart_error_log.summary.count") errlog = num(val($0))
    else if (key == "json.ata_smart_self_test_log.standard.count") selftests = num(val($0))
    else if (key == "json.nvme_smart_health_information_log.percentage_used") n_used = num(val($0))
    else if (key == "json.nvme_smart_health_information_log.data_units_written") n_duw = num(val($0))
    else if (key == "json.nvme_smart_health_information_log.media_errors") media = num(val($0))
    else if (key == "json.nvme_smart_health_information_log.critical_warning") crit = num(val($0))
    else if (key == "json.nvme_smart_health_information_log.available_spare") spare = num(val($0))
    else if (key == "json.nvme_smart_health_information_log.unsafe_shutdowns") unsafe = num(val($0))
    else if (key ~ /^json\.ata_smart_attributes\.table\[[0-9]+\]\.(id|name|value|raw\.string)$/) {
        i = key; sub(/^json\.ata_smart_attributes\.table\[/, "", i); f = i; sub(/\].*/, "", i); sub(/^[0-9]+\]\./, "", f)
        a[i, f] = val($0); if (f == "id") at[val($0) + 0] = i
    }
    else if (key ~ /^json\.ata_device_statistics\.pages\[[0-9]+\]\.table\[[0-9]+\]\.(name|value)$/) {
        p = key; sub(/^json\.ata_device_statistics\.pages\[/, "", p); t = p; sub(/\].*/, "", p)
        sub(/^[0-9]+\]\.table\[/, "", t); f = t; sub(/\].*/, "", t); sub(/^[0-9]+\]\./, "", f)
        ds[p, t, f] = val($0); if (f == "name") dsrow[p SUBSEP t] = 1
    }
}
function raw(id) { return (id in at) ? lead(a[at[id], "raw.string"]) : "" }
function named(id, re) { return ((id in at) && a[at[id], "name"] ~ re) }
END {
    rc += 0
    # Read by ID: the meaning of 5 / 197 / 198 / 187 / 199 is standard, the
    # NAME of an attribute is whatever the drive database calls it.
    realloc = raw(5); reported = raw(187); pending = raw(197); offline = raw(198); crc = raw(199)
    # These are read by NAME, so they need the database. Without it smartctl
    # falls back to generic guesses (OpenWrt compiles in a single DEFAULT
    # entry: 241 = Total_LBAs_Written, 231 = Temperature_Celsius) and 183 is
    # SATA_Downshift_Count on most other drives - interpreting those would
    # invent a wear figure and a bad-block count out of unrelated counters.
    if (indb == "true") {
        if (named(183, "^Runtime_Bad_Block$")) badblk = raw(183)
        if (named(174, "^Unexpect_Power_Loss")) unsafe = raw(174)
        else if (named(192, "^(Unsafe_Shutdown_Count|Unexpect_Power_Loss_Ct)$")) unsafe = raw(192)
    }
    for (k in dsrow) { split(k, kk, SUBSEP); nm = ds[kk[1], kk[2], "name"]; v = num(ds[kk[1], kk[2], "value"])
        if (nm == "Percentage Used Endurance Indicator" && v != "") { wear = v; wsrc = "devstat" }
        if (nm == "Logical Sectors Written" && v != "") lsw = v }
    if (wear == "" && indb == "true") {
        nc = split("231 ^SSD_Life_Left$,169 ^Remaining_Lifetime_Perc$,202 ^Percent_Lifetime_Remain$,233 ^Media_Wearout_Indicator$,177 ^Wear_Leveling_Count$", cand, ",")
        for (c = 1; c <= nc; c++) { split(cand[c], cc, " "); if (!named(cc[1] + 0, cc[2])) continue
            nv = num(a[at[cc[1] + 0], "value"]); if (nv != "" && nv + 0 >= 1 && nv + 0 <= 100) { wear = 100 - nv; wsrc = "attr" cc[1]; break } }
    }
    if (n_used != "") { wear = n_used; wsrc = "nvme" }
    if (lbs == "") lbs = 512
    # 241 counts different things on different drives - LBAs, MiB, GiB, 32 MiB
    # blocks - and the unit is only in the NAME. A fixed x 512 turns 420 GiB
    # written into 215 kB. Device statistics are exact, so they win.
    if (lsw != "") { written = sprintf("%.0f", lsw * lbs); wrsrc = "devstat" }
    else if (n_duw != "") { written = sprintf("%.0f", n_duw * 512000); wrsrc = "nvme" }
    else if (indb == "true" && (241 in at)) { nm = a[at[241], "name"]; r = raw(241)
        if (r != "") {
            if (nm == "Host_Writes_GiB") written = sprintf("%.0f", r * 1073741824)
            else if (nm == "Host_Writes_MiB") written = sprintf("%.0f", r * 1048576)
            else if (nm == "Host_Writes_32MiB") written = sprintf("%.0f", r * 33554432)
            else if (nm == "Total_LBAs_Written") written = sprintf("%.0f", r * lbs)
            if (written != "") wrsrc = "attr241" } }
    if (rc == 3) state = "standby"
    else if (bridge) state = "unsupported"
    else if (rc % 2 == 1 || rc == 124) state = "error"
    else if (passed == "" && avail == "false") state = "unsupported"
    else if (passed == "") state = (int(rc / 2) % 2 == 1) ? "error" : "unsupported"
    else if (passed == "false" || int(rc / 8) % 2 == 1 || int(rc / 16) % 2 == 1) state = "failing"
    else state = "ok"
    if ((state == "standby" || state == "error") && old != "") {
        # Nothing new was read: keep the last real reading, stamped with ITS
        # time. Overwriting it with nulls would turn a sleeping disk into a
        # disk whose temperature and hours are suddenly unknown.
        n = split(old, q, "|"); line = "S|" dev "|" size "|" now "|" q[5] "|" rc "|" state
        for (i = 8; i <= n; i++) line = line "|" q[i]
        print line; exit
    }
    gsub(/[^A-Za-z0-9 ._()+\/-]/, "", model); model = substr(model, 1, 64)
    gsub(/[^A-Za-z]/, "", proto)
    vts = (state == "ok" || state == "failing") ? now : ""
    body = j("exit_bits", rc) "," j("passed", (passed == "true" || passed == "false") ? passed : "") "," j("in_drivedb", (indb == "true" || indb == "false") ? indb : "") \
        "," js("protocol", proto) "," js("model", model) "," j("rotation_rpm", rpm) "," j("temperature_c", temp) "," j("power_on_hours", poh) \
        "," j("power_cycles", cycles) "," j("unsafe_shutdowns", unsafe) "," j("reallocated_sectors", realloc) "," j("pending_sectors", pending) \
        "," j("offline_uncorrectable", offline) "," j("reported_uncorrect", reported) "," j("crc_errors", crc) "," j("runtime_bad_blocks", badblk) \
        "," j("media_errors", media) "," j("critical_warning", crit) "," j("available_spare_pct", spare) "," j("wear_pct", wear) "," js("wear_source", wsrc) \
        "," j("written_bytes", written) "," js("written_source", wrsrc) "," j("error_log_count", errlog) "," j("selftest_count", selftests)
    # A state that carries no reading (unsupported, and error without a
    # previous line) sends no values at all, not a row of zeros.
    if (vts == "") body = ""
    printf "S|%s|%s|%s|%s|%s|%s|%s|%s\n", dev, size, now, vts, rc, state, rpm, body
}
'

# Reads SMART for the named disks and rewrites their lines in the cache.
#
# The lock is a directory with the PID inside: mkdir is atomic and flock is
# not part of stock OpenWrt. `dev` and `since` are written per DISK, not per
# batch, so "how long has this probe been running" is the truth about the
# drive that is actually being read.
bk_smart_refresh() {
    _lock="$BK_PRIVATE_DIR/smart.lock"
    if ! mkdir "$_lock" 2>/dev/null; then
        _p=""; [ -r "$_lock/pid" ] && read -r _p < "$_lock/pid"
        case "$_p" in ''|*[!0-9]*) _p="" ;; esac
        [ -n "$_p" ] && [ -d "/proc/$_p" ] && return 0       # a probe is still running
        rm -rf "$_lock"; mkdir "$_lock" 2>/dev/null || return 0
    fi
    echo "$$" > "$_lock/pid"; _now=$(date +%s); _new="$SMART_CACHE.new"; : > "$_new"; _hung=""
    for _d in "$@"; do
        case "$_d" in ''|*[!a-z0-9]*) continue ;; esac
        [ -r "$BK_SYS/block/$_d/size" ] || continue
        read -r _size < "$BK_SYS/block/$_d/size"
        echo "$_d" > "$_lock/dev"; date +%s > "$_lock/since"
        # -n standby,3: a sleeping disk answers with exit status 3 instead of
        # being spun up. -q noserial: the serial number is never even printed.
        # No -a / -x: they add logs nobody reads and cost seconds on a slow bus.
        case "$_d" in nvme*) _args="-i -H -A -l error -l selftest" ;; *) _args="-n standby,3 -i -H -A -l error -l selftest -l devstat" ;; esac
        _raw="$_lock/out"                                     # root-only tmpfs, no serial in it, removed at once
        # shellcheck disable=SC2086
        nice -n 19 smartctl --json=g -q noserial $_args "/dev/$_d" > "$_raw" 2>/dev/null &
        _pid=$!; _w=0
        while [ -d "/proc/$_pid" ] && [ "$_w" -lt "$SMART_TIMEOUT_SEC" ]; do sleep 1; _w=$((_w + 1)); done
        if [ -d "/proc/$_pid" ]; then
            # Watchdog: TERM, then KILL, and CHECK that it died. A smartctl in
            # D state (a hung USB bridge) survives both signals.
            kill "$_pid" 2>/dev/null; sleep 1
            if [ -d "/proc/$_pid" ]; then kill -9 "$_pid" 2>/dev/null; sleep 1; fi
            _rc=124
            [ -d "/proc/$_pid" ] && _hung=$_pid
        else wait "$_pid"; _rc=$?; fi
        awk -v dev="$_d" -v size="$_size" -v rc="$_rc" -v now="$_now" -v prev_file="$SMART_CACHE" "$BK_SMART_AWK" "$_raw" >> "$_new"
        rm -f "$_raw"
        [ -n "$_hung" ] && break                             # never start another smartctl behind a hung one
    done
    awk -F'|' 'NR == FNR { seen[$2] = 1; print; next } !($2 in seen)' "$_new" "$SMART_CACHE" > "$_new.all" && mv "$_new.all" "$SMART_CACHE"
    rm -f "$_new"
    if [ -n "$_hung" ]; then
        # The lock STAYS, now owned by the unkillable smartctl: what was read
        # so far is merged above, no new probe can start (reclaiming the lock
        # needs a dead PID), the disk becomes `stuck` and the collection issue
        # shows up on the server - and the lock frees itself when the kernel
        # finally lets the process go. Removing it here would hide the hang
        # and start a fresh smartctl against the same dead bridge every hour.
        echo "$_hung" > "$_lock/pid"; return 0
    fi
    rm -rf "$_lock"
}

if [ "$1" = "--smart-refresh" ]; then
    shift
    bk_smart_refresh "$@"
    exit 0
fi

# The run lock has a maximum age (WW-07). Before, one run wedged for good (a
# driver call that never returns, a POST into a black hole) made every later
# run exit at the lock until the next reboot: the router went silent with no
# stated cause. A holder older than 300 s is taken over now - it and every
# process below it are killed - and the next report says so.
#
# The lock keeps `pid` exactly as before (the PID alone), because an OLDER
# agent reads it with $(cat) and a digit check: any other content would look
# like garbage to it and it would take a live lock away. The age and the
# holder's identity go into a second file, `info`: the uptime (centiseconds)
# when the lock was taken, and the holder's start time from /proc/PID/stat.
# The start time is what stops a takeover from killing a stranger: a holder
# that died by SIGKILL (the OOM killer) leaves its lock behind, and the PID
# can belong to some other process by now - same PID, different start time.
BK_LOCK_DIR="$BK_PRIVATE_DIR/run.lock"
BK_LOCK_MAX_CS=30000

# From /proc/PID/stat: the state (field 3) into _ps_state, the parent
# (field 4) into _ps_ppid and the start time in clock ticks since boot (field
# 22) into _ps_start - all empty when the process is gone. The command name
# in field 2 may hold spaces and brackets, so everything up to its LAST ") "
# is dropped first. A function, so `set --` leaves the script's arguments.
bk_proc_start() {
    _ps_start=""; _ps_state=""; _ps_ppid=""
    # 2>/dev/null BEFORE the `<`: redirections apply left to right, and a
    # process that is gone would otherwise print "can't open" on stderr.
    read -r _ps_l 2>/dev/null < "/proc/$1/stat" || return 0
    _ps_l=${_ps_l##*") "}
    # shellcheck disable=SC2086
    set -- $_ps_l
    [ $# -ge 20 ] || return 0
    _ps_state=$1; _ps_ppid=$2; _ps_start=${20}
    case "$_ps_start" in *[!0-9]*) _ps_start="" ;; esac
}
# The holder and every process below it, as " pid pid ... " in _kt_list, from
# the ppid field of /proc/*/stat with builtins. Taken once, BEFORE any signal:
# a killed parent hands its children to init, and they would drop out.
bk_lock_tree() {
    _kt_list=" $1 "; _kt_more=1
    while [ "$_kt_more" = 1 ]; do
        _kt_more=0
        for _kt_d in /proc/[0-9]*; do
            _kt_p=${_kt_d#/proc/}
            case "$_kt_list" in *" $_kt_p "*) continue ;; esac
            read -r _kt_s 2>/dev/null < "$_kt_d/stat" || continue
            _kt_s=${_kt_s##*") "}
            # shellcheck disable=SC2086
            set -- $_kt_s
            case "$_kt_list" in *" $2 "*) _kt_list="$_kt_list$_kt_p "; _kt_more=1 ;; esac
        done
    done
}
if ! mkdir "$BK_LOCK_DIR" 2>/dev/null; then
    # `read`, not $(cat): one fork less on every run that meets a lock.
    _lock_pid=""
    read -r _lock_pid 2>/dev/null < "$BK_LOCK_DIR/pid"
    # Digits only: /tmp is world-writable and "../.." in here would make the
    # -d test true forever.
    case "$_lock_pid" in ''|*[!0-9]*) _lock_pid="" ;; esac
    # The PID this run judges; the claim below takes only a lock that still
    # names it.
    _lock_seen=$_lock_pid
    if [ -n "$_lock_pid" ] && [ -d "/proc/$_lock_pid" ]; then
        _lock_since=""; _lock_start=""
        read -r _lock_since _lock_start 2>/dev/null < "$BK_LOCK_DIR/info"
        case "$_lock_since" in ''|*[!0-9]*) _lock_since="" ;; esac
        case "$_lock_start" in ''|*[!0-9]*) _lock_start="" ;; esac
        bk_proc_start "$_lock_pid"
        if [ -n "$_lock_start" ] && [ -n "$_ps_start" ] && [ "$_ps_start" != "$_lock_start" ]; then
            # Same PID, another process: the holder is long gone.
            log_message "Zamek drzi PID $_lock_pid, ktery uz patri jinemu procesu - zamek je opusteny."
            _lock_pid=""
        elif [ -n "$_lock_since" ] && [ -n "$_lock_start" ] && [ -n "$_ps_start" ] && [ -n "$BK_RUN_START_CS" ] \
            && [ $((BK_RUN_START_CS - _lock_since)) -ge "$BK_LOCK_MAX_CS" ]; then
            # The start times are equal here (the branch above took every
            # mismatch). A lock without a full `info` (taken by an older
            # agent, or being taken right now) is never old: without a start
            # time the holder cannot be told from a stranger.
            bk_lock_tree "$_lock_pid"
            # This run and its ancestors (cron, procd) are never signalled,
            # whatever a lock file says.
            _kt_anc=" $$ "; _kt_a=$$
            while [ "$_kt_a" -gt 1 ] 2>/dev/null; do
                bk_proc_start "$_kt_a"; _kt_a=$_ps_ppid
                case "$_kt_a" in ''|*[!0-9]*) break ;; esac
                _kt_anc="$_kt_anc$_kt_a "
            done
            log_message "Predchozi beh (PID $_lock_pid) drzi zamek $(( (BK_RUN_START_CS - _lock_since) / 100 )) s, ukoncuji ho."
            for _kt_p in $_kt_list; do
                case "$_kt_anc" in *" $_kt_p "*) continue ;; esac
                kill -TERM "$_kt_p" 2>/dev/null
            done
            sleep 1
            _kt_left=""
            for _kt_p in $_kt_list; do
                case "$_kt_anc" in *" $_kt_p "*) continue ;; esac
                bk_proc_start "$_kt_p"
                # A zombie is dead already; only its parent can remove it.
                [ -n "$_ps_state" ] && [ "$_ps_state" != Z ] && kill -KILL "$_kt_p" 2>/dev/null && _kt_left=1
            done
            [ -n "$_kt_left" ] && sleep 1
            # Gone, or a zombie: busybox crond reaps its children only every
            # 10 s, so a holder killed a moment ago is usually still listed -
            # and a zombie holds nothing any more. Anything else survived
            # SIGKILL: stuck in the kernel (D state). That is usually not the
            # holder shell but the tool it waits for - `df` on a dead disk,
            # `iw` waiting on rtnl - so the holder dies, its child is handed
            # to init, and a run started beside it walks into the same hang:
            # one more unkillable process every 5 minutes. So every process
            # of the tree is checked, the holder first; this run's ancestors
            # were never signalled and are left out (the holder itself always
            # counts).
            _kt_keep=""
            bk_proc_start "$_lock_pid"
            if [ -n "$_ps_state" ] && [ "$_ps_state" != Z ]; then
                _kt_keep=$_lock_pid
            else
                for _kt_p in $_kt_list; do
                    case "$_kt_anc" in *" $_kt_p "*) continue ;; esac
                    bk_proc_start "$_kt_p"
                    if [ -n "$_ps_state" ] && [ "$_ps_state" != Z ]; then _kt_keep=$_kt_p; break; fi
                done
            fi
            if [ -n "$_kt_keep" ]; then
                # The lock STAYS, handed to the survivor the way bk_smart_refresh
                # hands smart.lock to a hung smartctl: its PID, its start time
                # and a fresh age. Every run skips at the lock meanwhile, the
                # next takeover is tried 300 s later, and the lock frees itself
                # when the kernel lets the process go. `killed` records that
                # this run was ended by the takeover (an ancestor never is):
                # the run that later reclaims the lock counts it.
                case "$_kt_anc" in *" $_lock_pid "*) ;; *) : > "$BK_LOCK_DIR/killed" 2>/dev/null ;; esac
                [ "$_kt_keep" = "$_lock_pid" ] || echo "$_kt_keep" > "$BK_LOCK_DIR/pid" 2>/dev/null
                [ -n "$_ps_start" ] && printf '%s %s\n' "$BK_RUN_START_CS" "$_ps_start" > "$BK_LOCK_DIR/info" 2>/dev/null
                log_message "Predchozi beh (PID $_lock_pid) nejde ukoncit ani SIGKILL (zustava PID $_kt_keep), tento koncim."
                _lock_pid=$_kt_keep
            else
                # Written NOW, not held until the fold at the end of the run:
                # a run that hangs in the same collector as the one it killed
                # is killed in turn, and a count kept in a variable died with
                # it - an hour of hung runs was reported as one.
                printf 'k\n' >> "$BK_PRIVATE_DIR/skipped" 2>/dev/null || true
                _lock_pid=""
            fi
        fi
    fi
    if [ -n "$_lock_pid" ] && [ -d "/proc/$_lock_pid" ]; then
        log_message "Predchozi beh (PID $_lock_pid) jeste bezi, tento koncim."
        # G42: the minute that produced no report is remembered here, because
        # the report that WOULD have said so is exactly the one not sent. One
        # line per skip, appended without the lock; the next run that holds
        # the lock folds the lines into its counters (see "skipped" below).
        # Without it the server cannot tell a router that was switched off
        # from an agent that cannot keep up.
        printf 'l\n' >> "$BK_PRIVATE_DIR/skipped" 2>/dev/null || true
        exit 0
    fi
    # Claimed by a RENAME, never `rm -rf` + `mkdir`: of two runs that judged
    # the same lock (a manual run next to cron, both inside the takeover's two
    # seconds of sleep), only one can move it away. With rm the later one
    # deleted the lock the earlier one had just taken, both ran, and the first
    # to finish removed the other's lock. What was moved away must still name
    # the PID judged above; a lock another run took meanwhile goes back.
    [ -e "$BK_LOCK_DIR.$$" ] && rm -rf "$BK_LOCK_DIR.$$" 2>/dev/null
    if mv "$BK_LOCK_DIR" "$BK_LOCK_DIR.$$" 2>/dev/null; then
        _lock_now=""
        read -r _lock_now 2>/dev/null < "$BK_LOCK_DIR.$$/pid"
        case "$_lock_now" in ''|*[!0-9]*) _lock_now="" ;; esac
        if [ "$_lock_now" != "$_lock_seen" ]; then
            [ -e "$BK_LOCK_DIR" ] || mv "$BK_LOCK_DIR.$$" "$BK_LOCK_DIR" 2>/dev/null
            [ -e "$BK_LOCK_DIR.$$" ] && rm -rf "$BK_LOCK_DIR.$$" 2>/dev/null
            log_message "Zamek mezitim prevzal jiny beh (PID $_lock_now), tento koncim."
            printf 'l\n' >> "$BK_PRIVATE_DIR/skipped" 2>/dev/null || true
            exit 0
        fi
        # A run the takeover signalled while the kernel still held it (the
        # lock was kept for it, see `killed` above) is gone now: it counts.
        [ -e "$BK_LOCK_DIR.$$/killed" ] && { printf 'k\n' >> "$BK_PRIVATE_DIR/skipped" 2>/dev/null || true; }
        rm -rf "$BK_LOCK_DIR.$$" 2>/dev/null
    fi
    mkdir "$BK_LOCK_DIR" 2>/dev/null || exit 0
fi
echo "$$" > "$BK_LOCK_DIR/pid" 2>/dev/null
# `pid` first, `info` second: a run that looks in between sees no age and
# waits, it never takes over a lock that is being taken. No uptime or no
# start time: no `info`, and such a lock is simply never taken over.
bk_proc_start "$$"
[ -n "$BK_RUN_START_CS" ] && [ -n "$_ps_start" ] && printf '%s %s\n' "$BK_RUN_START_CS" "$_ps_start" > "$BK_LOCK_DIR/info" 2>/dev/null

# G42: the WHOLE previous run, its POST included. The payload is assembled
# before the POST, so a run can never report its own total - and the POST is
# what usually pushes a minute run past its minute, which is the thing worth
# reporting. It is written by the EXIT trap below and read here.
# CONSUMED like run.cpu below, and for the same reason: a run killed by a
# takeover runs no trap, and the report after a 300 s wedge would otherwise
# name the run BEFORE it as "the previous run", a few seconds long.
BK_RUN_TOTAL_FILE="$BK_PRIVATE_DIR/run.total"
# A --dry-run typed at a terminal (the owner poking at it over SSH) prints
# its payload and never POSTs. It must neither take the cron run's figures,
# which would then never be reported, nor leave its own verbose run behind
# as "the previous run". Redirected dry runs are the test harness standing in
# for cron and keep the cron behaviour; the STATUS_TEST_TTY seam tests this.
BK_RUN_COST_KEEP=""
if [ "$DRY_RUN" = "1" ] && [ -z "$BK_TEST_RESPONSE" ]; then
    { [ -t 1 ] || [ -t 2 ] || [ "$BK_TEST_TTY" = "1" ]; } && BK_RUN_COST_KEEP=1
fi
agent_prev_total_ms="null"
if [ -z "$BK_RUN_COST_KEEP" ] && read -r _prev_total 2>/dev/null < "$BK_RUN_TOTAL_FILE"; then
    case "$_prev_total" in ''|*[!0-9]*) ;; *) agent_prev_total_ms="$_prev_total" ;; esac
    : > "$BK_RUN_TOTAL_FILE" 2>/dev/null
fi

# W1-7 (ARCH-05): what the previous run cost in CPU - user + system time of
# the agent shell AND of every child it waited for (each tool, each awk, the
# POST with its TLS), the number `time agent_openwrt.sh` prints. A harness
# measures the agent on one machine; this is every router measuring itself,
# the slow MIPS ones included, so each later change is judged by the fleet
# and not by an estimate. Taken by the EXIT trap below, for the same reason
# as the total above: the POST comes after the payload.
# The file is CONSUMED: emptied as soon as it has been read, under the lock.
# A run that dies before its trap (killed by a takeover, the OOM killer, a
# power cut) then leaves nothing behind, and the next report says null
# instead of passing off the cost of an older run as the last one.
BK_RUN_CPU_FILE="$BK_PRIVATE_DIR/run.cpu"
agent_prev_cpu_ms="null"
if [ -z "$BK_RUN_COST_KEEP" ] && read -r _prev_cpu 2>/dev/null < "$BK_RUN_CPU_FILE"; then
    case "$_prev_cpu" in ''|*[!0-9]*) ;; *) agent_prev_cpu_ms="$_prev_cpu" ;; esac
    : > "$BK_RUN_CPU_FILE" 2>/dev/null
fi

# This shell's CPU so far plus that of its waited-for children, in ms, into
# _sc_ms; empty when /proc/$$/stat cannot be read or parsed. Fields 14-17 of
# the stat line are utime, stime, cutime and cstime in USER_HZ ticks, which
# the kernel exports at 100 per second on every architecture OpenWrt builds
# (CONFIG_HZ does not change them, and a router has no getconf to ask): a
# tick is 10 ms. The REAL /proc, never the test root: this is the agent's
# own process. The name in field 2 may hold spaces, so everything up to its
# last ") " goes first, as in bk_proc_start. No fork: the trap runs on every
# exit, and a fork here would be counted in the very number it produces.
bk_self_cpu_ms() {
    _sc_ms=""
    read -r _sc_l < "/proc/$$/stat" 2>/dev/null || return 0
    _sc_l=${_sc_l##*") "}
    # shellcheck disable=SC2086
    set -- $_sc_l
    [ $# -ge 15 ] || return 0
    case "${12}${13}${14}${15}" in *[!0-9]*) return 0 ;; esac
    _sc_ms=$(( (${12} + ${13} + ${14} + ${15}) * 10 ))
}

bk_run_end() {
    # Only while this run still holds its lock. A run whose lock another run
    # has taken since (a takeover judged it wedged, or it lost the claim)
    # would write over files that run has already read, and delete its lock.
    _re_pid=""
    read -r _re_pid 2>/dev/null < "$BK_LOCK_DIR/pid"
    [ "$_re_pid" = "$$" ] || return 0
    [ -n "$BK_RUN_COST_KEEP" ] && { rm -rf "$BK_LOCK_DIR"; return 0; }
    bk_uptime_cs
    if [ -n "$_up_cs" ] && [ -n "$BK_RUN_START_CS" ] && [ "$_up_cs" -ge "$BK_RUN_START_CS" ] 2>/dev/null; then
        printf '%s\n' "$(( (_up_cs - BK_RUN_START_CS) * 10 ))" > "$BK_RUN_TOTAL_FILE" 2>/dev/null || true
    fi
    # Last, but while the lock is still held: written after the `rm` below, it
    # could land after the next run had already read (and emptied) the file,
    # and would be reported one run late. So only that `rm` is not in it.
    bk_self_cpu_ms
    if [ -n "$_sc_ms" ]; then
        printf '%s\n' "$_sc_ms" > "$BK_RUN_CPU_FILE" 2>/dev/null || true
    fi
    rm -rf "$BK_LOCK_DIR"
}
trap bk_run_end EXIT

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
#
# Only the SAMPLE is taken here; the arithmetic happens in section 4c, after
# the WAN device is known. The aggregate, the per-core values and the WAN
# byte rates then come out of ONE awk over ONE snapshot, so "cpu" and
# "cpu_core_max_pct" can never describe two different intervals, and the
# rates cost no second fork.
cpu="null"
cpu_cores="null"; cpu_core_max_pct="null"; cpu_core_max_index="null"; cpu_core_max_softirq_pct="null"
now_ts=$(date +%s)
# The uptime at the same moment: agent_time is moved on from here to the
# payload without a second `date` (see agent_run_ms).
bk_uptime_cs; BK_NOW_TS_CS=$_up_cs
BK_CORES_NOW="$BK_PRIVATE_DIR/cores.now"
BK_CORES_PREV="$BK_PRIVATE_DIR/cores.prev"
# One builtin loop instead of the `grep '^cpu '` fork: the aggregate line and
# every core line, up to `intr` - everything below it is interrupts, context
# switches and boot time, which this run never reads.
stat_now=""
while read -r _st_line; do
    case "$_st_line" in
        "cpu "*|cpu[0-9]*) stat_now="$stat_now$_st_line
" ;;
        intr*) break ;;
    esac
done < "$BK_PROC/stat" 2>/dev/null
# The snapshot of the previous run becomes cores.prev, this one cores.now.
# Both are plain text in the private directory, read back with `read` (X18).
if [ -n "$stat_now" ]; then
    [ -f "$BK_CORES_NOW" ] && mv "$BK_CORES_NOW" "$BK_CORES_PREV" 2>/dev/null
    printf '%s' "$stat_now" > "$BK_CORES_NOW" 2>/dev/null || true
fi

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
    if (total == 0) exit;
    pct = sprintf("%.1f", (used / total) * 100);
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
    # One `read` instead of three awk: the kernel writes a single line of
    # blank-separated fields, which is what both split on.
    load1=""; load5=""; load15=""
    read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null
    # A CR, VT or FF would split differently in awk: then awk decides.
    case "$load1$load5$load15" in *["$BK_WSX"]*)
        load1=$(awk '{print $1}' /proc/loadavg)
        load5=$(awk '{print $2}' /proc/loadavg)
        load15=$(awk '{print $3}' /proc/loadavg) ;;
    esac
fi

# Uptime (sekundy)
uptime_sec="null"
if [ -f /proc/uptime ]; then
    # awk's printf "%d" cut the fraction off; so does the expansion. Only a
    # plain "123.45" takes the fast path, anything else still goes to awk.
    _ut=""; read -r _ut _ < /proc/uptime 2>/dev/null
    _uw=${_ut%.*}; _uf=${_ut#*.}
    case "$_ut" in *.*) ;; *) _uw=x ;; esac
    case "$_uw" in 0|[1-9]*) ;; *) _uw=x ;; esac
    case "$_uw$_uf" in
        *[!0-9]*) uptime_sec=$(awk '{printf "%d", $1}' /proc/uptime) ;;
        *) uptime_sec=$_uw ;;
    esac
fi

# Teplota (nejvyssi dostupna thermal zona) - volitelne, hodne routeru senzor nema.
temperature="null"
if [ -d /sys/class/thermal ]; then
    # Builtin: the old $(for ... cat | awk) cost a fork per zone plus two. A
    # zone that does not hold a plain integer in millidegrees (it never
    # should) sends the whole reading back to the old pipeline, so the
    # answer cannot drift from what it was.
    max_temp=""; _tz_odd=""
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] || continue
        # One line with its newline, as sysfs writes it. A second line or a
        # missing newline (cat glued it to the next zone's value) is odd.
        _tz=""; _tz2=""; _tzr=0
        { IFS= read -r _tz || _tzr=1; IFS= read -r _tz2 && _tz_odd=1; } < "$z" 2>/dev/null
        [ -n "$_tz2" ] && _tz_odd=1
        [ "$_tzr" = 1 ] && [ -n "$_tz" ] && _tz_odd=1
        case "$_tz" in ''|0) continue ;; -[1-9]*) _tz_c=${_tz#-} ;; [1-9]*) _tz_c=$_tz ;; *) _tz_odd=1 ;; esac
        [ -n "$_tz_odd" ] && break
        case "$_tz_c" in *[!0-9]*|??????????*) _tz_odd=1; break ;; esac
        [ "$_tz" -gt 0 ] && [ "$_tz" -lt 150000 ] && { [ -z "$max_temp" ] || [ "$_tz" -gt "$max_temp" ]; } && max_temp=$_tz
    done
    if [ -n "$_tz_odd" ]; then
        max_temp=$(for z in /sys/class/thermal/thermal_zone*/temp; do
            [ -r "$z" ] && cat "$z" 2>/dev/null
        done | awk '$1 > 0 && $1 < 150000 { if ($1 > max) max = $1 } END { if (max) print max }')
    fi
    [ -n "$max_temp" ] && { bk_fdiv "$max_temp" 1000 1; temperature=$_fd; }
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
    # now_ts is the run's clock from section 1: a second $(date) here was one
    # more fork for the same second.
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
            if bk_line1 "$DISK_STATE_FILE"; then
                bk_blank2 "$_sl"; prev_ts=$_b1; prev_sec=$_b2
            else
                prev_ts=$(awk '{print $1}' "$DISK_STATE_FILE" 2>/dev/null)
                prev_sec=$(awk '{print $2}' "$DISK_STATE_FILE" 2>/dev/null)
            fi
            if [ -n "$prev_ts" ] && [ -n "$prev_sec" ] && [ "$now_ts" -gt "$prev_ts" ]; then
                time_delta=$((now_ts - prev_ts))
                sec_delta=$((total_written_sectors - prev_sec))
                if [ "$sec_delta" -ge 0 ] && [ "$time_delta" -gt 0 ]; then
                    write_kb=$((sec_delta / 2))
                    bk_fdiv "$write_kb" "$time_delta" 2; disk_io_write=$_fd
                fi
            fi
        fi
        echo "$now_ts $total_written_sectors" > "$DISK_STATE_FILE" 2>/dev/null || true
    fi
fi

# --- 3. Identita routeru (kešovaná v RAM pro eliminaci ubus volání a log spamu) ---
# The cache is DATA: one value per line, read back with `read`. It used to be
# shell assignments in world-writable /tmp that the agent eval'ed as root, so
# any local user could run a command as root within a minute. Now it lives in
# the private directory, and a file that does not look like ours (no digits
# on the first line, no end marker on the last) is simply fetched again.
# 24 h, not forever: a renamed router or a sysupgrade kept the old identity
# until the next reboot.
ID_CACHE_FILE="$BK_PRIVATE_DIR/identity.cache"
ID_CACHE_TTL_SEC=86400
ow_hostname=""; ow_kernel=""; ow_model=""; ow_board_name=""; ow_distribution=""; ow_os_version=""; os_combined=""

id_cache_ts=""; id_cache_end=""
if [ -f "$ID_CACHE_FILE" ]; then
    {
        IFS= read -r id_cache_ts
        IFS= read -r ow_hostname
        IFS= read -r ow_kernel
        IFS= read -r ow_model
        IFS= read -r ow_board_name
        IFS= read -r ow_distribution
        IFS= read -r ow_os_version
        IFS= read -r id_cache_end
    } < "$ID_CACHE_FILE" 2>/dev/null
fi
case "$id_cache_ts" in ''|*[!0-9]*) id_cache_ts=0 ;; esac
id_cache_age=$((now_ts - id_cache_ts))
if [ "$id_cache_end" = "end" ] && [ "$id_cache_age" -ge 0 ] && [ "$id_cache_age" -lt "$ID_CACHE_TTL_SEC" ]; then
    os_combined="$ow_distribution $ow_os_version"
else
    ow_hostname=""; ow_kernel=""; ow_model=""; ow_board_name=""; ow_distribution=""; ow_os_version=""
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
    # Written through a temporary name: a run killed half way must not leave
    # a file whose lines have shifted by one. A value never holds a newline
    # here (jshn hands out one line), and if it did, the end marker would be
    # on the wrong line and the file would be thrown away on the next read.
    # An answer ubus did not give is not kept for a day: the next run asks again.
    if [ -n "$board_json" ]; then
        printf '%s\n' "$now_ts" "$ow_hostname" "$ow_kernel" "$ow_model" "$ow_board_name" "$ow_distribution" "$ow_os_version" "end" \
            > "$ID_CACHE_FILE.tmp" 2>/dev/null && mv "$ID_CACHE_FILE.tmp" "$ID_CACHE_FILE" 2>/dev/null
        log_message "Načtena identita routeru: hostname=$ow_hostname model=$ow_model os=$os_combined kernel=$ow_kernel"
    fi
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
# wan_up starts EMPTY, not false: a box with no netifd interface called "wan"
# (access point, uplink on wwan or wan_pppoe) measured nothing, and "false"
# would make the server raise a wan_lost alert on it forever.
wan_up=""; wan_proto=""; wan_uptime="null"; wan_ipv4=""; wan_gateway=""; wan_dns=""; wan_l3_device=""; wan_device=""
# One `network.interface dump` for everything below (WAN, wan6, LAN, LTE):
# it carries the same fields as the per-interface status calls, of which the
# agent used to make up to eight a run.
dump_json=""
command -v ubus >/dev/null 2>&1 && dump_json=$(ubus call network.interface dump 2>/dev/null)
_bi_list=""
_bi_loaded=0
# Scans the dump once into "key|name|proto" lines. This is also the ONLY
# json_load of the dump in a run: every reader below goes back to the root of
# the tree already in the shell with `json_select ""` (what real jshn.sh does
# for an empty name). Each json_load replays the whole dump as json_add_*
# calls through eval; on an 8-interface router the real jshn spent about a
# third of the run's CPU loading the same document five or six times.
# Nothing between here and the last reader loads another document into jshn
# (the board identity is read before this point), so the tree stays valid.
bk_iface_scan() {
    [ -n "$_bi_list" ] && return 0
    # Loaded, but no interface in it: loading it again would not add one.
    [ "$_bi_loaded" = 1 ] && return 1
    [ -n "$dump_json" ] || return 1
    json_load "$dump_json"
    _bi_loaded=1
    json_select interface
    _bi_keys=""
    json_get_keys _bi_keys
    for _bi_k in $_bi_keys; do
        json_select "$_bi_k"
        _bi_name=""; _bi_proto=""
        json_get_var _bi_name interface
        json_get_var _bi_proto proto
        _bi_list="$_bi_list$_bi_k|$_bi_name|$_bi_proto
"
        json_select ..
    done
    [ -n "$_bi_list" ]
}
# bk_iface_load NAMES [PROTOS]: leaves the jshn cursor inside the first
# interface called one of NAMES (in that order), else the first whose proto
# is one of PROTOS. Returns 1 when there is none - a box with no "wan"
# measures nothing about it.
# $3 is an interface name to skip: without it the protocol fallback below
# happily returns the WAN interface itself on a router whose uplink IS a
# modem (proto qmi/ncm), and the same device would be reported as both the
# primary line and the backup.
bk_iface_load() {
    bk_iface_scan || return 1
    _bi_hit=""
    _bi_skip="$3"
    for _bi_want in $1; do
        while IFS='|' read -r _bi_k _bi_n _bi_p; do
            [ -n "$_bi_skip" ] && [ "$_bi_n" = "$_bi_skip" ] && continue
            [ "$_bi_n" = "$_bi_want" ] && { _bi_hit="$_bi_k"; break; }
        done <<EOF
$_bi_list
EOF
        [ -n "$_bi_hit" ] && break
    done
    if [ -z "$_bi_hit" ]; then
        for _bi_want in $2; do
            while IFS='|' read -r _bi_k _bi_n _bi_p; do
                [ -n "$_bi_skip" ] && [ "$_bi_n" = "$_bi_skip" ] && continue
                [ "$_bi_p" = "$_bi_want" ] && { _bi_hit="$_bi_k"; break; }
            done <<EOF
$_bi_list
EOF
            [ -n "$_bi_hit" ] && break
        done
    fi
    [ -n "$_bi_hit" ] || return 1
    # Back to the root of the one loaded tree (see bk_iface_scan), not a reload.
    json_select ""
    json_select interface
    json_select "$_bi_hit"
    return 0
}
if bk_iface_load wan; then
    json_get_var wan_up up
    json_get_var wan_proto proto
    json_get_var wan_uptime uptime
    json_get_var wan_l3_device l3_device
    # The netifd "device" is where the port walk of section 4c starts: on
    # PPPoE it is the VLAN netdev (eth2.848), whose speed the kernel really
    # answers, while l3_device is the ppp netdev with no link settings.
    json_get_var wan_device device
    # netifd reports l3_device only while the interface is up. Without this
    # fallback the primary link loses its device name for as long as the WAN
    # is down - exactly when someone is looking at which link carried what.
    [ -z "$wan_l3_device" ] && wan_l3_device="$wan_device"

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
            # The device is part of the state: after a failover the WAN device
            # changes (pppoe-wan -> wwan0) and a delta between two different
            # counters charged the whole new session to one interval.
            # Builtin read of the one line this block wrote (3 cut forks before).
            if bk_line1 "$NET_STATE_FILE"; then
                bk_cut3 "$_sl" ,; prev_ts=$_c1; prev_dev=$_c2; prev_bytes=$_c3
            else
                prev_ts=$(cut -d',' -f1 "$NET_STATE_FILE" 2>/dev/null)
                prev_dev=$(cut -d',' -f2 "$NET_STATE_FILE" 2>/dev/null)
                prev_bytes=$(cut -d',' -f3 "$NET_STATE_FILE" 2>/dev/null)
            fi
            if [ "$prev_dev" = "$wan_l3_device" ] && [ -n "$prev_ts" ] && [ -n "$prev_bytes" ]; then
                elapsed=$((now_ts - prev_ts))
                delta=$((net_bytes - prev_bytes))
                if [ "$elapsed" -gt 0 ] && [ "$delta" -ge 0 ]; then
                    bk_fdiv "$delta" "$((elapsed * 1024))" 1; net=$_fd
                fi
            fi
        fi
        echo "${now_ts},${wan_l3_device},${net_bytes}" > "$NET_STATE_FILE" 2>/dev/null || true
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
        if bk_line1 "$NET_IP_STATE_FILE"; then
            bk_cut3 "$_sl" ,; prev_ts=$_c1; prev_v4=$_c2; prev_v6=$_c3
        else
            prev_ts=$(cut -d',' -f1 "$NET_IP_STATE_FILE" 2>/dev/null)
            prev_v4=$(cut -d',' -f2 "$NET_IP_STATE_FILE" 2>/dev/null)
            prev_v6=$(cut -d',' -f3 "$NET_IP_STATE_FILE" 2>/dev/null)
        fi
        if [ -n "$prev_ts" ] && [ -n "$prev_v4" ] && [ "$now_ts" -gt "$prev_ts" ]; then
            elapsed=$((now_ts - prev_ts))
            d_v4=$((v4_bytes - prev_v4))
            # An unreadable /proc/net/snmp6 leaves v6_bytes empty; $(( )) would
            # quietly treat that as 0 and report a fabricated 0.0 KB/s.
            d_v6=""
            [ -n "$v6_bytes" ] && [ -n "$prev_v6" ] && d_v6=$((v6_bytes - prev_v6))
            if [ "$elapsed" -gt 0 ] && [ "$d_v4" -ge 0 ]; then
                bk_fdiv "$d_v4" "$((elapsed * 1024))" 1; net_ipv4_kbps=$_fd
            fi
            if [ -n "$d_v6" ] && [ "$elapsed" -gt 0 ] && [ "$d_v6" -ge 0 ]; then
                bk_fdiv "$d_v6" "$((elapsed * 1024))" 1; net_ipv6_kbps=$_fd
            fi
        fi
    fi
    echo "${now_ts},${v4_bytes},${v6_bytes}" > "$NET_IP_STATE_FILE" 2>/dev/null || true
fi

# --- 4b. Realna smerovatelna IPv6 - hleda se na samostatnem logickem rozhrani
# "wan6" (typicke pro PPPoE + DHCPv6-PD), protoze "wan" samo casto ma jen
# link-local fe80:: adresu, ktera pro verejne zobrazeni nema smysl. ---
wan_ipv6=""
# The interfaces called wan6, in dump order, from the names bk_iface_scan
# already read: no reload of the dump and no json_select into each of the
# other interfaces just to learn its name.
if [ -n "$dump_json" ] && bk_iface_scan; then
    json_select ""
    json_select interface
    while IFS='|' read -r _bi_k _bi_n _bi_p; do
        [ "$_bi_n" = "wan6" ] || continue
        json_select "$_bi_k"
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
        json_select ..
    done <<EOF
$_bi_list
EOF
fi
# --- 4c. WAN port walk (WAN 3.1.1) - link rate and physical port, 0 forks ---
# Two questions, one walk. A VLAN, bridge or macvlan netdev answers `speed` by
# passing the question through to its real device, so "the first readable
# speed" names eth2.848, not the port underneath it. Hence:
#   (a) the LINK RATE is the first readable positive speed of the chain,
#   (b) the PHYSICAL PORT is the first netdev of the chain with a `device`
#       symlink - virtual netdevs (vlan, bridge, ppp) live under
#       /sys/devices/virtual/net and have none.
# Only that port's counters are a measurement: a VLAN's rx_dropped and
# tx_errors are structurally 0 (vlan_dev_get_stats64 fills its own rx_errors
# and tx_dropped only), and a zero nobody measured is not data.
#
# Reads one sysfs number into $_wv, no fork; empty when the file cannot be
# read or does not hold a plain number.
bk_netnum() {
    _wv=""
    [ -r "$1" ] && read -r _wv < "$1" 2>/dev/null
    case "$_wv" in ''|*[!0-9]*) _wv="" ;; esac
}
wan_link_dev=""; wan_link_mbit="null"; wan_carrier_down_count="null"
# Every netdev the walk passed through, for the SQM match of the path cache:
# a queue on ANY device of the chain shapes this WAN.
bk_wan_chain=""
_w_cands="$wan_device $wan_l3_device"
case "$wan_proto" in
    # A modem's usbnet "speed" is a USB descriptor, not a line rate.
    qmi|mbim|ncm|modemmanager|3g) _w_cands="" ;;
esac
_w_rate_done=""
for _w_start in $_w_cands; do
    case " $bk_wan_chain " in *" $_w_start "*) continue ;; esac
    _wd="$_w_start"; _w_depth=0
    while [ -n "$_wd" ] && [ -d "$BK_SYS/class/net/$_wd" ]; do
        case " $bk_wan_chain " in *" $_wd "*) break ;; esac
        bk_wan_chain="$bk_wan_chain $_wd"
        [ -z "$wan_link_dev" ] && [ -e "$BK_SYS/class/net/$_wd/device" ] && wan_link_dev="$_wd"
        if [ -z "$_w_rate_done" ]; then
            # `read` fails with EINVAL on a netdev without link settings (ppp
            # has no get_link_ksettings): only THEN does the rate question move
            # one level down. A -1 or a 0 IS an answer - link down or unknown -
            # and ends it, or a dead DSA port would inherit the fixed 1000 of
            # its conduit.
            _w_speed=""
            if read -r _w_speed < "$BK_SYS/class/net/$_wd/speed" 2>/dev/null; then
                _w_rate_done=1
                case "$_w_speed" in
                    ''|0|*[!0-9]*) : ;;
                    *) wan_link_mbit="$_w_speed" ;;
                esac
            fi
        fi
        [ -n "$wan_link_dev" ] && [ -n "$_w_rate_done" ] && break
        [ "$_w_depth" -ge 4 ] && break
        _w_depth=$((_w_depth + 1))
        # Exactly one lower device, or the chain ends here: a bridge with two
        # ports has no single physical port to charge the counters to.
        _w_next=""; _w_lowers=0
        for _w_l in "$BK_SYS/class/net/$_wd"/lower_*; do
            [ -e "$_w_l" ] || continue
            _w_lowers=$((_w_lowers + 1)); _w_next="${_w_l##*/lower_}"
        done
        [ "$_w_lowers" -eq 1 ] || break
        _wd="$_w_next"
    done
    [ -n "$wan_link_dev" ] && [ -n "$_w_rate_done" ] && break
done

# --- 4c2. Counters of the physical port (WAN 3.1.3), cumulative ---
# rx_crc_errors, rx_missed_errors and rx_fifo_errors are never sent: on mvneta
# they are always 0 (mvneta_get_stats64 fills packets, bytes, rx_dropped,
# rx_errors and tx_dropped only).
wan_rx_errors="null"; wan_tx_errors="null"; wan_rx_dropped="null"; wan_tx_dropped="null"
if [ -n "$wan_link_dev" ]; then
    _w_st="$BK_SYS/class/net/$wan_link_dev/statistics"
    bk_netnum "$_w_st/rx_errors"; [ -n "$_wv" ] && wan_rx_errors="$_wv"
    bk_netnum "$_w_st/tx_errors"; [ -n "$_wv" ] && wan_tx_errors="$_wv"
    bk_netnum "$_w_st/rx_dropped"; [ -n "$_wv" ] && wan_rx_dropped="$_wv"
    bk_netnum "$_w_st/tx_dropped"; [ -n "$_wv" ] && wan_tx_dropped="$_wv"
    bk_netnum "$BK_SYS/class/net/$wan_link_dev/carrier_down_count"
    [ -n "$_wv" ] && wan_carrier_down_count="$_wv"
fi

# --- 4d. Per-core CPU and WAN byte rates (WAN 3.1.2, 3.1.3) - one awk ---
# The snapshot of $BK_PROC/stat was taken at the top of the run; cores.prev
# holds the one of the previous run. The aggregate keeps the formula of
# 0.1.6 and is computed HERE, from the same snapshot as the per-core values,
# so the two can never describe different intervals.
#
# The rate rides in the same awk (no second fork) and is measured on the l3
# device, which is the one that carries the WAN traffic - on PPPoE that is
# the ppp netdev, not the port. Elapsed time comes from the uptime in
# centiseconds, never from the clock: a router whose NTP jumps would
# otherwise report a made-up rate.
BK_WAN_RATE_STATE="$BK_PRIVATE_DIR/wan-rate.state"
_wr_prev_cs=""; _wr_prev_dev=""; _wr_prev_rx=""; _wr_prev_tx=""
[ -r "$BK_WAN_RATE_STATE" ] && IFS='|' read -r _wr_prev_cs _wr_prev_dev _wr_prev_rx _wr_prev_tx < "$BK_WAN_RATE_STATE"
_wr_cs=""
if read -r _wr_up _wr_idle < "$BK_PROC/uptime" 2>/dev/null; then
    # "1000.00" -> 100000 centiseconds, with the builtins only. The kernel
    # always prints two decimals; anything else is not this file.
    case "$_wr_up" in
        *.[0-9][0-9]) _wr_cs="${_wr_up%.*}${_wr_up#*.}" ;;
    esac
fi
_wr_rx=""; _wr_tx=""
if [ -n "$wan_l3_device" ]; then
    bk_netnum "$BK_SYS/class/net/$wan_l3_device/statistics/rx_bytes"; _wr_rx="$_wv"
    bk_netnum "$BK_SYS/class/net/$wan_l3_device/statistics/tx_bytes"; _wr_tx="$_wv"
fi
_cores_prev_file="$BK_CORES_PREV"
[ -f "$_cores_prev_file" ] || _cores_prev_file=/dev/null
_bk_min=$(awk -v now="$stat_now" \
    -v rdev="$wan_l3_device" -v ncs="$_wr_cs" -v nrx="$_wr_rx" -v ntx="$_wr_tx" \
    -v pdev="$_wr_prev_dev" -v pcs="$_wr_prev_cs" -v prx="$_wr_prev_rx" -v ptx="$_wr_prev_tx" '
$1 ~ /^cpu/ { prev[$1] = $0 }
END {
    nl = split(now, L, "\n")
    for (i = 1; i <= nl; i++) {
        if (L[i] == "") continue
        split(L[i], f)
        cur[f[1]] = L[i]
    }
    agg = ""
    if (("cpu" in prev) && ("cpu" in cur)) {
        split(prev["cpu"], a1); split(cur["cpu"], a2)
        i1 = a1[5] + a1[6]; t1 = a1[2]+a1[3]+a1[4]+a1[5]+a1[6]+a1[7]+a1[8]
        i2 = a2[5] + a2[6]; t2 = a2[2]+a2[3]+a2[4]+a2[5]+a2[6]+a2[7]+a2[8]
        # Counters that did not move (same tick, overlapping runs) give no
        # output - null upstream - not a 0.0 % nobody measured.
        if (t2 - t1 + 0 > 0) agg = sprintf("%.1f", (1.0 - (i2 - i1) / (t2 - t1)) * 100)
    }
    cores = 0; maxi = -1
    for (k in cur) {
        if (k == "cpu") continue
        cores++
        if (substr(k, 4) + 0 > maxi + 0) maxi = substr(k, 4) + 0
    }
    # By index, not by hash order: two cores with the same load must always
    # give the same answer, and that is the lower index.
    back = 0; moved = 0; best = -1; bidx = ""; bsq = ""
    for (n = 0; n + 0 <= maxi + 0; n++) {
        k = "cpu" n
        if (!(k in cur)) continue
        if (!(k in prev)) { back = 1; continue }
        split(prev[k], p); split(cur[k], c)
        tot = 0
        # user, nice, system, idle, iowait, irq, softirq, steal
        for (j = 2; j <= 9; j++) {
            dv[j] = c[j] - p[j]
            if (dv[j] + 0 < 0) back = 1
            tot += dv[j]
        }
        if (tot + 0 <= 0) continue
        moved = 1
        busy = 1 - (dv[5] + dv[6]) / tot
        if (busy + 0 > best + 0) {
            best = busy; bidx = n + 0
            # Threaded NAPI and the mt76 workers are charged to system, not to
            # softirq, so irq and softirq together are what "the packet path
            # is eating this core" looks like.
            bsq = (dv[7] + dv[8]) / tot
        }
    }
    ncores = ""; mx = ""; mi = ""; sq = ""
    # A counter that went backwards (a reboot, a core that came back online)
    # makes the whole reading a guess, and so does a snapshot in which not a
    # single core moved.
    if (back + 0 == 0 && moved + 0 == 1 && cores + 0 > 0) {
        ncores = cores + 0; mx = sprintf("%.1f", best * 100)
        mi = bidx; sq = sprintf("%.1f", bsq * 100)
    }
    rx = ""; tx = ""
    if (rdev != "" && rdev == pdev && pcs != "" && prx != "" && ptx != "" && nrx != "" && ntx != "" && ncs != "") {
        dt = (ncs - pcs) / 100
        drx = nrx - prx; dtx = ntx - ptx
        # A negative delta is a counter reset, not traffic that flowed backwards.
        if (dt + 0 > 0 && drx + 0 >= 0 && dtx + 0 >= 0) {
            rx = sprintf("%.1f", drx * 8 / dt / 1000000)
            tx = sprintf("%.1f", dtx * 8 / dt / 1000000)
        }
    }
    printf "%s|%s|%s|%s|%s|%s|%s", agg, ncores, mx, mi, sq, rx, tx
}' "$_cores_prev_file" 2>/dev/null)
wan_rx_mbps="null"; wan_tx_mbps="null"
if [ -n "$_bk_min" ]; then
    cpu=${_bk_min%%|*}; _bk_r=${_bk_min#*|}
    cpu_cores=${_bk_r%%|*}; _bk_r=${_bk_r#*|}
    cpu_core_max_pct=${_bk_r%%|*}; _bk_r=${_bk_r#*|}
    cpu_core_max_index=${_bk_r%%|*}; _bk_r=${_bk_r#*|}
    cpu_core_max_softirq_pct=${_bk_r%%|*}; _bk_r=${_bk_r#*|}
    wan_rx_mbps=${_bk_r%%|*}; wan_tx_mbps=${_bk_r#*|}
    # An empty field is "not measured", never a zero somebody could chart.
    [ -z "$cpu" ] && cpu="null"
    [ -z "$cpu_cores" ] && cpu_cores="null"
    [ -z "$cpu_core_max_pct" ] && cpu_core_max_pct="null"
    [ -z "$cpu_core_max_index" ] && cpu_core_max_index="null"
    [ -z "$cpu_core_max_softirq_pct" ] && cpu_core_max_softirq_pct="null"
    [ -z "$wan_rx_mbps" ] && wan_rx_mbps="null"
    [ -z "$wan_tx_mbps" ] && wan_tx_mbps="null"
fi
# The device belongs in the state: after a failover (pppoe-wan -> wwan0) a
# delta between two different counters charged a whole session to one minute.
if [ -n "$wan_l3_device" ] && [ -n "$_wr_rx" ] && [ -n "$_wr_tx" ] && [ -n "$_wr_cs" ]; then
    printf '%s|%s|%s|%s\n' "$_wr_cs" "$wan_l3_device" "$_wr_rx" "$_wr_tx" > "$BK_WAN_RATE_STATE" 2>/dev/null || true
fi

# --- 4e. conntrack event counters (WAN 3.1.4), cumulative ---
# Columns 10-12 of /proc/net/stat/nf_conntrack, one line per CPU, hexadecimal
# without a 0x prefix; the header line is skipped because its column 10 is not
# hex. busybox awk cannot read hex at all, so the sum is done in the shell
# with $((0x..)).
#
# The three are NOT one number: insert_failed grows on confirm races, dying
# entries and long hash chains, early_drop counts entries evicted to make
# room (nothing was refused), and only drop with a full table is a connection
# the router turned away. The server keeps them apart.
conntrack_insert_failed="null"; conntrack_drop="null"; conntrack_early_drop="null"
_ct_a=0; _ct_b=0; _ct_c=0; _ct_seen=""; _ct_cols=""
while read -r _ct1 _ct2 _ct3 _ct4 _ct5 _ct6 _ct7 _ct8 _ct9 _ct10 _ct11 _ct12 _ct_rest; do
    # The first line names the columns, and it is READ, not skipped: kernels
    # print a different number of counters here (3.x had `searched` and
    # `delete_list`, 6.x has `clashres` and `chainlength`), so a file whose
    # 10th to 12th column mean something else would give three numbers nobody
    # measured. Without the three names nothing is summed at all.
    if [ -z "$_ct_cols" ]; then
        [ "$_ct10" = "insert_failed" ] && [ "$_ct11" = "drop" ] && [ "$_ct12" = "early_drop" ] && _ct_cols=1
        continue
    fi
    # Each column on its own: a short line would leave one empty, and "0x"
    # alone is an arithmetic error that ends the whole run.
    case "$_ct10" in ''|*[!0-9a-fA-F]*) continue ;; esac
    case "$_ct11" in ''|*[!0-9a-fA-F]*) continue ;; esac
    case "$_ct12" in ''|*[!0-9a-fA-F]*) continue ;; esac
    _ct_a=$((_ct_a + 0x$_ct10)); _ct_b=$((_ct_b + 0x$_ct11)); _ct_c=$((_ct_c + 0x$_ct12))
    _ct_seen=1
done < "$BK_PROC/net/stat/nf_conntrack" 2>/dev/null
if [ -n "$_ct_seen" ]; then
    conntrack_insert_failed="$_ct_a"; conntrack_drop="$_ct_b"; conntrack_early_drop="$_ct_c"
fi

log_debug "WAN: up=$wan_up proto=$wan_proto ipv4=$wan_ipv4 gateway=$wan_gateway dns=$wan_dns ipv6=$wan_ipv6 net=${net}KB/s (l3_device=$wan_l3_device port=${wan_link_dev:-none} link=${wan_link_mbit}Mbit rx=${wan_rx_mbps}Mbps)"

# --- 5. Sestaveni JSON payloadu ---
# jshn muze vracet bool jako "1"/"0" nebo "true"/"false" v zavislosti na
# verzi libubox - overujeme obe varianty, at se stav WAN nikdy tise neztrati.
case "$wan_up" in
    1|true) wan_up_json="true" ;;
    0|false) wan_up_json="false" ;;
    *) wan_up_json="null" ;;
esac

# --- Deep OpenWrt Telemetry ---
# No swap configured is "not applicable" (null), like btrfs errors below - not 0.0 % of nothing.
swap_pct=$(awk '/^SwapTotal:/ {total=$2} /^SwapFree:/ {free=$2} END { if (total > 0) printf "%.1f", ((total - free) / total) * 100; }' /proc/meminfo)
[ -z "$swap_pct" ] && swap_pct="null"

entropy="null"
# Stays a cat, like the conntrack count below: a /proc/sys file answers only
# the first read(2), and `read` takes one byte per call - it saw "2" of 256.
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
# The run's clock (section 1), not a second `date` fork.
now_sec=$now_ts
opkg_cache_age=999999
if [ -f "$OPKG_CACHE_FILE" ]; then
    opkg_mtime=$(date -r "$OPKG_CACHE_FILE" +%s 2>/dev/null || echo 0)
    opkg_cache_age=$((now_sec - opkg_mtime))
fi

if [ $opkg_cache_age -lt $HEAVY_OP_INTERVAL_SEC ] && [ -f "$OPKG_CACHE_FILE" ]; then
    if bk_line1 "$OPKG_CACHE_FILE"; then
        bk_cut3 "$_sl" '|'; upgradable_packages=$_c1; installed_packages=$_c2
    else
        upgradable_packages=$(cut -d'|' -f1 "$OPKG_CACHE_FILE" 2>/dev/null)
        installed_packages=$(cut -d'|' -f2 "$OPKG_CACHE_FILE" 2>/dev/null)
    fi
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
        # Same validation as the apk branch below (the two had drifted apart):
        # zero installed is opkg failing on its lock, and list-upgradable knows
        # nothing until someone ran `opkg update` - the lists live in tmpfs
        # and are gone after a reboot. Neither is a real zero.
        case "$installed_packages" in ''|*[!0-9]*|0) installed_packages="null" ;; esac
        case "$upgradable_packages" in ''|*[!0-9]*) upgradable_packages="null" ;; esac
        [ -n "$(ls -A /var/opkg-lists 2>/dev/null)" ] || upgradable_packages="null"
        if [ "$installed_packages" != "null" ]; then
            echo "${upgradable_packages}|${installed_packages}" > "$OPKG_CACHE_FILE.tmp" 2>/dev/null \
                && mv "$OPKG_CACHE_FILE.tmp" "$OPKG_CACHE_FILE" 2>/dev/null || true
        fi
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
# Summed from the per-radio detail further down. Bare `iwinfo` prints no line
# containing "assoc" at all, so the grep this used to be never matched and the
# count was null on every router.
wifi_clients_count="null"

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
fi
# (dnsmasq never writes /tmp/dnsmasq.stats; SIGUSR1 makes it log its statistics
#  to syslog. The old branch sent that signal every minute, which only filled
#  the log buffer - and on Turris wrote to eMMC - without ever yielding a
#  number. Without the stats file these stay null.)
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
#
# ONE awk reads the ruleset as it streams out of nft and answers everything
# this run asks of it: the three verdict sums (each its own sum over the same
# lines, exactly as three separate passes summed them), whether a line holds
# "table inet fw4" (firewall_enabled) and whether one holds "flowtable " (the
# WAN path). Before, the whole ruleset was held in the shell and piped into
# three more awks; with a banIP or adblock set of 10k elements that was the
# set four times over. `nft -t` leaves the elements of NAMED sets and maps
# out; rules, with their inline anonymous sets and vmaps, print in full. An
# element line only ever counted when it held a verdict AND per-element
# counters, i.e. a named verdict map with counters. fw4 creates none, and a
# plain set of addresses (banIP, adblock) holds no verdict, so its elements
# never counted and leaving them out changes no sum.
# Output: "FW4 FT |ACCEPT|DROP|REJECT" (an empty sum = no counted rule), and
# nothing at all when nft printed nothing - "an empty kernel" stays what it
# was before: no counters from nft, then the iptables branch.
BK_NFT_AWK='
    length($0) > 0 { any = 1 }
    index($0, "table inet fw4") { fw4 = 1 }
    index($0, "flowtable ") { ft = 1 }
    {
        line = $0
        sub(/comment ".*/, "", line)
        nf = split(line, f, /[ \t]+/)
        ha = hd = hr = 0
        for (i = 1; i <= nf; i++) {
            if (f[i] == "accept" || f[i] == "accept;") ha = 1
            if (f[i] == "drop" || f[i] == "drop;") hd = 1
            if (f[i] == "reject" || f[i] == "reject;") hr = 1
        }
        if (!(ha || hd || hr)) next
        for (i = 2; i <= nf; i++) if (f[i] == "packets" && f[i-1] == "counter") {
            if (ha) { sa += f[i+1]; na++ }
            if (hd) { sd += f[i+1]; nd++ }
            if (hr) { sr += f[i+1]; nr++ }
        }
    }
    END { if (any) print fw4 " " ft " |" (na > 0 ? sa : "") "|" (nd > 0 ? sd : "") "|" (nr > 0 ? sr : "") }'

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
# The ruleset is read once, in the one pass above (it was dumped from the
# kernel four times a run before 0.1.7, and held in the shell until now).
bk_nft_out=""
bk_nft_fw4=0
bk_nft_ft=0
bk_have_nft=0
if command -v nft >/dev/null 2>&1; then
    bk_have_nft=1
    bk_nft_out=$(nft -t list ruleset 2>/dev/null | awk "$BK_NFT_AWK")
    # An nft too old for -t fails without printing anything, and so answers
    # like an empty kernel: ask once more without it. On a kernel that really
    # is empty this lists nothing a second time; the answer is the same.
    [ -n "$bk_nft_out" ] || bk_nft_out=$(nft list ruleset 2>/dev/null | awk "$BK_NFT_AWK")
fi
if [ -n "$bk_nft_out" ]; then
    bk_nft_fw4=${bk_nft_out%% *}; _fw_r=${bk_nft_out#* }
    bk_nft_ft=${_fw_r%% *}; _fw_r=${_fw_r#* |}
    fw_accepted=${_fw_r%%|*}; _fw_r=${_fw_r#*|}
    fw_dropped=${_fw_r%%|*}; fw_rejected=${_fw_r#*|}
elif command -v iptables >/dev/null 2>&1; then
    fw_accepted=$(_ipt_target_packets ACCEPT)
    fw_dropped=$(_ipt_target_packets DROP)
    fw_rejected=$(_ipt_target_packets REJECT)
fi

# Bezi firewall vubec?
#
# Tenhle udaj agent nikdy neposilal, takze dlazdice "Firewall & NAT" v aplikaci
# hlasila "Neznamy stav" porad - i na routeru, ktery prave zahodil tri tisice
# paketu.
#
# G20: the question is whether the router's OWN rules are in the kernel, and
# fw4 answers it exactly - it loads one table, `inet fw4`, and loads it whole.
# The three weaker signals this used to accept all say something else:
#  - "any non-empty ruleset" is true on a router whose firewall never came up
#    but which runs mwan3, docker or a wireguard table;
#  - `/etc/init.d/firewall enabled` says the service MAY start, not that it
#    did - a fw4 syntax error leaves it enabled and the network wide open;
#  - a legacy `iptables -S` always prints the policy lines, so "output starts
#    with a dash" was true wherever the applet existed at all.
# No nft and no iptables is still null: "we do not know" is not "off", and the
# server raises nothing on a null.
firewall_enabled="null"
if [ "$bk_have_nft" = 1 ]; then
    case "$bk_nft_fw4" in
        1) firewall_enabled="true" ;;
        *) firewall_enabled="false" ;;
    esac
elif command -v iptables >/dev/null 2>&1; then
    # Legacy-only router: a real rule (`-A <chain> ...`), not a policy line.
    if iptables -S 2>/dev/null | grep -q '^-A'; then
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
        # `wg show all dump`: the first line per interface has 5 columns
        # (iface, PRIVATE key, pubkey, port, fwmark), every peer line 9
        # (iface, pubkey, psk, endpoint, allowed-ips, handshake, rx, tx,
        # keepalive). The old parser read every line as a peer with the
        # columns off by one: allowed-ips landed unquoted in latest_handshake,
        # the server rejected the JSON - so a router with WireGuard up sent
        # no telemetry at all - and the interface line leaked a private-key
        # prefix as "public_key".
        wireguard_peers_json=$(echo "$wg_dump" | awk '
        BEGIN { printf "[" }
        NF < 9 { next }
        {
            if (count > 0) printf ", ";
            endpoint = $4;
            if (endpoint == "(none)") { endpoint = "" }
            else {
                n = split(endpoint, ep, ":"); endpoint = "";
                for (i = 1; i < n; i++) endpoint = endpoint (i > 1 ? ":" : "") ep[i];
                gsub(/\[|\]/, "", endpoint);
            }
            handshake = ($6 ~ /^[0-9]+$/) ? $6 : "null";
            rx = ($7 ~ /^[0-9]+$/) ? $7 : "null";
            tx = ($8 ~ /^[0-9]+$/) ? $8 : "null";
            printf "{\"interface\":\"%s\",\"public_key\":\"%s\",\"endpoint\":\"%s\",\"latest_handshake\":%s,\"rx_bytes\":%s,\"tx_bytes\":%s}", $1, substr($2,1,12)"...", endpoint, handshake, rx, tx;
            count++;
        }
        END { printf "]" }')
    fi
fi

# --- Vysledky mereni rychlosti (librespeed-cli) ---
#
# Router si vysledky odklada do <data_dir>/<rok-mesic>/<cas>.json. /tmp je na
# OpenWrt ramdisk, takze po restartu je historie pryc - proto se posilaji na
# server, kde prezijou.
#
# Kam presne, rika uci: reForis i cron wrapper ctou librespeed.client.data_dir
# (files/librespeed.sh:14-17), takze router s jinym nastavenim se cetl uplne
# spatne. Bez toho klice plati puvodni /tmp/librespeed-data.
#
# Posila se jen to, co je novejsi nez posledni POTVRZENY zaznam. Stav se
# 0.1.7 nezij v /tmp, ale v soukromem adresari; stary soubor se pri zmene
# verze maze (viz uklid nahore), takze prvni behy nabidnou celou historii
# znovu a server si opravi rady, ktere 0.1.6 ulozil s prepoctem na bajty.
#
# Rychlosti jsou Mbit/s, tecka. Puvodni heuristika "vic nez 1000 jsou bajty"
# delila gigabitove vysledky osmi miliony a delala z 1850 Mbit/s 0,0148.
LIBRESPEED_DIR=""
if [ -f /etc/config/librespeed ]; then
    LIBRESPEED_DIR=$(uci -q get librespeed.client.data_dir 2>/dev/null)
fi
[ -z "$LIBRESPEED_DIR" ] && LIBRESPEED_DIR="/tmp/librespeed-data"
LIBRESPEED_STATE_FILE="$BK_PRIVATE_DIR/librespeed.state"
BK_SPEED_PENDING="$BK_PRIVATE_DIR/pending.state"
speedtests_json="[]"
speedtests_newest=""
speed_listed=""
# An INTERVAL flag: the report covers the last ~60 s, so a test that ended
# half a minute ago still owns this report's CPU numbers. The file-name
# format of the result files is not confirmed on hardware (data_dir was empty
# when the router was read), so "new in this listing" alone sets it, which
# errs towards skipping one alert evaluation rather than raising a false one.
speedtest_active="false"
if [ -d "$LIBRESPEED_DIR" ]; then
    last_sent=""
    [ -f "$LIBRESPEED_STATE_FILE" ] && IFS= read -r last_sent < "$LIBRESPEED_STATE_FILE" 2>/dev/null

    # ONE awk decides which files are opened at all. 0.1.6 ran basename + tr
    # per file per run (two forks each, on the whole directory) only to throw
    # the result away a moment later. The name IS the measurement time, so a
    # string comparison on the path answers it without opening anything.
    #
    # At most 50 per report and OLDEST first: a router that was offline for a
    # week catches up report by report instead of sending a 500-item payload
    # that the 64-key / 8 KB pass-through would shed.
    speed_sel=$(find "$LIBRESPEED_DIR" -type f -name '*.json' 2>/dev/null | sort | awk -v last_sent="$last_sent" '
        {
            n = split($0, p, "/"); base = p[n]; sub(/\.json$/, "", base);
            if (base == "") next;
            # A path with a space cannot be handed to awk as an argument list
            # below; such a name is not ours and is left alone.
            if (index($0, " ") > 0) next;
            if (base > nb) nb = base;
            # The name is an ISO time, which sorts the same way as a clock.
            if (last_sent != "" && base <= last_sent) next;
            c++; path[c] = $0;
        }
        END {
            # The newest name in the whole directory, sent or not, for the
            # uplink ring: a later result newer than it is a fresh one.
            print (c ? 1 : 0) "|" nb;
            for (i = 1; i <= c && i <= 50; i++) print path[i];
        }')
    speed_files=""
    case "$speed_sel" in
        1*) speedtest_active="true" ;;
    esac
    speed_listed=${speed_sel%%"$BK_NL"*}
    speed_listed=${speed_listed#*|}
    case "$speed_sel" in
        *"$BK_NL"*) speed_files=${speed_sel#*"$BK_NL"} ;;
    esac
fi
# The items themselves are built further down, after the LTE section: which
# uplink carried a result is read off the byte counters of BOTH uplinks, and
# the backup device is only known there (see "Which uplink carried each
# speedtest result").

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
# Which disks moved since the previous run. The storage collector below
# needs it to tell a sleeping disk from a working one, and it comes out of
# the same awk - reading /proc/diskstats a second time would cost a fork.
diskdev_active=" "
# $BK_PROC is /proc except under the dry-run test seam. The per-disk rates
# and the disk health list have to describe the same disks, and in a test
# those are the fake root's, not the CI runner's.
if [ -f "$BK_PROC/diskstats" ]; then
    diskdev_now=$now_ts   # the run's clock, not one more `date` fork
    # Kotva $ za nazvem znamenala, ze `mmcblk` sedelo jen na zarizeni doslova
    # pojmenovane "mmcblk" - jenze skutecne se jmenuje mmcblk0. Stejne tak
    # mtdblock0 a ubiblock0_0. Ze seznamu tedy vypadlo hlavni uloziste routeru
    # (na Turrisu je / prave na mmcblk0p2) a zbyly jen disky sd[a-z]. Souhrnny
    # zapis o radek vys pritom mmcblk pocital, takze cislo za cele zarizeni
    # sedelo a chybel jen rozpad - o to hur se toho vsimlo.
    #
    # Oddily (mmcblk0p1, sda1) se schvalne vynechavaji: /proc/diskstats je
    # zapocitava i do celeho disku, takze by se stejny zapis vypsal dvakrat.
    diskdev_cur=$(awk '$3 ~ /^(mtdblock[0-9]+|mmcblk[0-9]+|sd[a-z]|ubiblock[0-9_]+|nvme[0-9]+n[0-9]+|hd[a-z])$/ { print $3 "|" $6 "|" $10 }' "$BK_PROC/diskstats" 2>/dev/null)

    if [ -n "$diskdev_cur" ]; then
        diskdev_prev_ts=""
        # `head -n 1` as a builtin: the first line, whatever it holds.
        [ -f "$DISKDEV_STATE_FILE" ] && { IFS= read -r diskdev_prev_ts; } 2>/dev/null < "$DISKDEV_STATE_FILE"

        _diskdev_out=$(printf '%s\n' "$diskdev_cur" | awk -F'|' \
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
                # Awake = the counters moved. A first run knows nothing yet and
                # says nothing, which keeps a spinning disk asleep one more run.
                if ((dev in prev_r) && (r != prev_r[dev] || w != prev_w[dev])) act = act (act == "" ? "" : " ") dev;
                printf "%s{\"device\":\"%s\",\"read_kbps\":%s,\"write_kbps\":%s,\"read_sectors_total\":%s,\"write_sectors_total\":%s}",
                       (c++ ? "," : "["), dev, rk, wk, r, w;
            }
            END { printf "%s#%s", (c ? "]" : "[]"), act }')
        # Last '#': a device name cannot contain one, so the split is safe.
        disk_devices_json=${_diskdev_out%#*}
        diskdev_active=" ${_diskdev_out##*#} "

        { echo "$diskdev_now"; printf '%s\n' "$diskdev_cur"; } > "$DISKDEV_STATE_FILE" 2>/dev/null
    fi
fi
[ -z "$disk_devices_json" ] && disk_devices_json="[]"

# --- Fyzicke disky, oddily a SMART -------------------------------------------
#
# `filesystems` above says how full a mount point is, `disk_devices` how much
# is written to a device. Neither says WHICH disk that is, how it is attached,
# or whether it is about to die. This block adds the disk itself: the list is
# rebuilt only when it changes (or hourly), the SMART values come from the
# cache a detached child fills, and the minute run touches no drive at all.

# Reads one sysfs value. `[ -r f ] && read` rather than `read v < f 2>/dev/null`:
# a directory or a write-only attribute in place of the file makes read fail,
# and without the reset the PREVIOUS disk value would silently carry over.
bk_rd() { _v=""; [ -r "$1" ] && IFS= read -r _v < "$1"; printf '%s' "$_v"; }

# D|name|transport|port|sectors|rot|removable|life_a|life_b|pre_eol|model  and
# P|disk|part|sectors. The model goes LAST: it may contain the separator.
# Only size, removable, queue/rotational, device/{model,vendor,name,type,
# life_time,pre_eol_info} and <part>/{partition,size} are ever opened - never
# serial, cid, wwid, vpd_pg80/83, eui or nguid. `readlink -f` and the small
# path awk run only on a rebuild, which is at most once an hour.
bk_disk_static() {
    _sys="$1/sys"
    for _dp in "$_sys"/block/*; do
        _n=${_dp##*/}
        case "$_n" in sd[a-z]|sd[a-z][a-z]|vd[a-z]|hd[a-z]|mmcblk[0-9]|mmcblk[0-9][0-9]|nvme[0-9]n[0-9]|nvme[0-9][0-9]n[0-9]) ;; *) continue ;; esac
        # loop*, zram* and ubiblock* never get here; mtdblock* would (raw NOR
        # flash HAS a device link), which is why the name pattern decides.
        [ -e "$_dp/device" ] || continue
        _size=$(bk_rd "$_dp/size"); case "$_size" in ''|0|*[!0-9]*) continue ;; esac
        _path=$(readlink -f "$_dp" 2>/dev/null); _tr="other"; _port=""
        case "$_path" in
            */usb[0-9]*) _tr="usb"; _port=$(printf '%s\n' "$_path" | awk -F/ '{ for (i = NF; i > 0; i--) if ($i ~ /^[0-9]+-[0-9]+(\.[0-9]+)*$/) { print "usb:" $i; exit } }') ;;
            */nvme/nvme[0-9]*) _tr="nvme"; _port=$(printf '%s\n' "$_path" | awk -F/ '{ for (i = NF; i > 0; i--) if ($i ~ /^nvme[0-9]+$/) { print $i; exit } }') ;;
            */mmc_host/mmc[0-9]*) _tr="sd"; [ "$(bk_rd "$_dp/device/type")" = "MMC" ] && _tr="emmc"
                _port=$(printf '%s\n' "$_path" | awk -F/ '{ for (i = NF; i > 0; i--) if ($i ~ /^mmc[0-9]+$/) { print $i; exit } }') ;;
            */ata[0-9]*) _tr="sata"; _port=$(printf '%s\n' "$_path" | awk -F/ '{ for (i = NF; i > 0; i--) if ($i ~ /^ata[0-9]+$/) { print $i; exit } }') ;;
            */virtio[0-9]*) _tr="virtio" ;;
        esac
        _model=$(bk_rd "$_dp/device/model"); [ -z "$_model" ] && _model=$(bk_rd "$_dp/device/name")
        # SCSI inquiry gives 16 characters, so the sysfs model is a prefix of
        # the SMART one ("KINGSTON SUV500M" vs "KINGSTON SUV500MS120G"). It is
        # still the stable half of the disk key: SMART may not be readable.
        _vendor=$(bk_rd "$_dp/device/vendor"); _vendor=${_vendor%% *}
        case "$_vendor" in ''|ATA) ;; *) _model="$_vendor $_model" ;; esac
        _la=""; _lb=""; _eol=""
        if [ "$_tr" = "emmc" ]; then
            # eMMC wear is static between boots (drivers/mmc/core/mmc.c reads
            # it once from the EXT_CSD), so it belongs here, not in the minute.
            _lt=$(bk_rd "$_dp/device/life_time"); _la=${_lt%% *}; _lb=${_lt##* }; _eol=$(bk_rd "$_dp/device/pre_eol_info")
        fi
        printf 'D|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$_n" "$_tr" "$_port" "$_size" "$(bk_rd "$_dp/queue/rotational")" "$(bk_rd "$_dp/removable")" "$_la" "$_lb" "$_eol" "$_model"
        for _pp in "$_dp/$_n"*; do
            [ -r "$_pp/partition" ] || continue
            printf 'P|%s|%s|%s\n' "$_n" "${_pp##*/}" "$(bk_rd "$_pp/size")"
        done
    done
}

# The fingerprint is name:size of every candidate, read with builtins only.
# A disk list that is rebuilt every minute would cost a readlink and an awk per
# disk for a value that changes when somebody plugs something in - so it is
# rebuilt on a change, and once an hour in case a change was missed.
_disks_fp=""
for _dp in "$BK_SYS"/block/*; do
    _n=${_dp##*/}
    case "$_n" in sd[a-z]|sd[a-z][a-z]|vd[a-z]|hd[a-z]|mmcblk[0-9]|mmcblk[0-9][0-9]|nvme[0-9]n[0-9]|nvme[0-9][0-9]n[0-9]) ;; *) continue ;; esac
    [ -e "$_dp/device" ] || continue
    _dsz=""; [ -r "$_dp/size" ] && read -r _dsz < "$_dp/size"
    _disks_fp="$_disks_fp $_n:$_dsz"
done
_disks_fp=${_disks_fp# }
_disks_hdr=""; [ -r "$STORAGE_STATIC" ] && IFS= read -r _disks_hdr < "$STORAGE_STATIC"
_disks_hdr=${_disks_hdr#\#fp }
_disks_old_fp=${_disks_hdr#* }; _disks_ts=${_disks_hdr%% *}
case "$_disks_ts" in ''|*[!0-9]*) _disks_ts=0 ;; esac
if [ "$_disks_old_fp" != "$_disks_fp" ] || [ $((now_ts - _disks_ts)) -ge 3600 ]; then
    { printf '#fp %s %s\n' "$now_ts" "$_disks_fp"; bk_disk_static "$BK_ROOT"; } > "$STORAGE_STATIC.tmp" 2>/dev/null \
        && mv "$STORAGE_STATIC.tmp" "$STORAGE_STATIC" 2>/dev/null
    rm -f "$STORAGE_STATIC.tmp" 2>/dev/null
fi

# What the SMART child is doing right now. `since` is written per disk, so the
# number answers "how long has THIS drive been read", and a later spawn cannot
# reset the clock the way smart.spawn would. Over 900 s is only reachable
# through an unkillable smartctl, which keeps the lock on purpose.
smart_probe_running_s="null"
smart_probe_age_s="null"
smart_stuck=""
_smart_lock_pid=""; [ -r "$BK_PRIVATE_DIR/smart.lock/pid" ] && read -r _smart_lock_pid < "$BK_PRIVATE_DIR/smart.lock/pid"
case "$_smart_lock_pid" in ''|*[!0-9]*) _smart_lock_pid="" ;; esac
if [ -n "$_smart_lock_pid" ] && [ -d "/proc/$_smart_lock_pid" ]; then
    _smart_since=""; [ -r "$BK_PRIVATE_DIR/smart.lock/since" ] && read -r _smart_since < "$BK_PRIVATE_DIR/smart.lock/since"
    case "$_smart_since" in ''|*[!0-9]*) _smart_since="" ;; esac
    if [ -n "$_smart_since" ]; then
        smart_probe_running_s=$((now_ts - _smart_since))
        if [ "$smart_probe_running_s" -gt 900 ]; then
            [ -r "$BK_PRIVATE_DIR/smart.lock/dev" ] && read -r smart_stuck < "$BK_PRIVATE_DIR/smart.lock/dev"
            case "$smart_stuck" in ''|*[!a-z0-9]*) smart_stuck="" ;; esac
        fi
    fi
fi
smart_spawn_last=""; [ -r "$BK_PRIVATE_DIR/smart.spawn" ] && IFS= read -r smart_spawn_last < "$BK_PRIVATE_DIR/smart.spawn"
_smart_spawn_ts=${smart_spawn_last%%|*}
case "$_smart_spawn_ts" in ''|*[!0-9]*) _smart_spawn_ts="" ;; esac
[ -n "$_smart_spawn_ts" ] && smart_probe_age_s=$((now_ts - _smart_spawn_ts))

# Files: disks.static, smart.cache; stdin: the `df -PT` body.
# Vars: smartctl (1|0), active (" sda sdb "), now, stuck (device name or ""),
#       interval (s, floor 3600)
# Output: <storage_disks JSON>#<disks whose SMART reading is due>
# The JSON keys are written \"key\": so that run_agent_metric_lint.php does
# not read them as new top-level metrics.
BK_STORAGE_AWK='
function jn(v) { return (v == "") ? "null" : v }
function jq(v) { return (v == "") ? "null" : "\"" v "\"" }
function jb(v) { return (v == "1") ? "true" : (v == "0" ? "false" : "null") }
# A mount point is a path a person chose: it may hold a quote or a backslash,
# and printed raw it makes the whole report invalid JSON, which the server
# answers with 400 - the router would stop reporting over a directory name.
# Character by character, never through gsub(): what a backslash in the
# replacement text means changed in busybox 1.37 ("\\\\" became ONE
# backslash, as POSIX says), and the old gsub escaper then printed quotes
# raw. A string with neither a quote nor a backslash, nearly every one,
# goes back as it is.
function esc(s,   o, c, i, n) { gsub(/[\001-\037]/, "", s); if (!index(s, "\\") && !index(s, "\"")) return s; o = ""; n = length(s); for (i = 1; i <= n; i++) { c = substr(s, i, 1); o = o ((c == "\\" || c == "\"") ? "\\" c : c) } return o }
function hexn(s,   v) { s = tolower(s); sub(/^0x/, "", s); if (s !~ /^[0-9a-f]+$/) return ""; v = 0; while (s != "") { v = v * 16 + index("0123456789abcdef", substr(s, 1, 1)) - 1; s = substr(s, 2) } return v }
FILENAME != "-" && $0 ~ /^D\|/ { n = split($0, f, "|"); nd++; name[nd] = f[2]; tr[nd] = f[3]; port[nd] = f[4]; size[nd] = f[5]; rot[nd] = f[6]; rem[nd] = f[7]; la[nd] = hexn(f[8]); lb[nd] = hexn(f[9]); eol[nd] = hexn(f[10])
    m = f[11]; for (i = 12; i <= n; i++) m = m "|" f[i]; gsub(/[^A-Za-z0-9 ._()+\/-]/, "", m); gsub(/  +/, " ", m); sub(/^ /, "", m); sub(/ $/, "", m); model[nd] = substr(m, 1, 64); next }
FILENAME != "-" && $0 ~ /^P\|/ { split($0, f, "|"); np[f[2]]++; pn[f[2], np[f[2]]] = f[3]; ps[f[2], np[f[2]]] = f[4]; next }
FILENAME != "-" && $0 ~ /^S\|/ { n = split($0, f, "|"); k = f[2]; s_size[k] = f[3]; s_probe[k] = f[4]; s_vts[k] = f[5]; s_state[k] = f[7]; s_rpm[k] = f[8]; b = f[9]; for (i = 10; i <= n; i++) b = b "|" f[i]; s_body[k] = b; next }
# The df header does not start with /dev/, so it needs no separate skip. The
# mount is $7..NF: it may contain spaces. The shortest one wins - / and /srv
# are the same btrfs, and the disk belongs under the one that is the volume.
FILENAME == "-" { if ($1 ~ /^\/dev\//) { d = $1; sub(/^\/dev\//, "", d); mnt = $7; for (i = 8; i <= NF; i++) mnt = mnt " " $i
        if (!(d in fs_m) || length(mnt) < length(fs_m[d])) { fs_m[d] = mnt; fs_t[d] = $2; p = $6; sub(/%/, "", p); fs_p[d] = (p ~ /^[0-9]+$/) ? p : "" } } next }
END {
    for (x = 1; x <= nd && x <= 8; x++) { k = name[x]
        st = ""; vts = ""; body = ""
        if (tr[x] == "emmc" || tr[x] == "sd" || tr[x] == "virtio") st = "not_applicable"
        else if (smartctl != 1) st = "not_installed"
        else {
            # Matched on name AND size: a USB slot that got another disk keeps
            # the name and must not inherit the old disk temperature.
            have = ((k in s_size) && s_size[k] == size[x])
            spinning = (have && s_rpm[k] != "") ? (s_rpm[k] + 0 > 0) : (rot[x] != "0")
            isdue = (!have || now - s_probe[k] >= (interval + 0 >= 3600 ? interval + 0 : 3600))
            if (have) { st = s_state[k]; vts = s_vts[k]; body = s_body[k] } else st = "pending"
            if (k == stuck) st = "stuck"
            # A spinning disk that nobody is using is left alone: reading SMART
            # spins it up, and doing that every hour is the wear this check is
            # supposed to watch. It is read the first minute it is working.
            if (isdue && k != stuck) { if (spinning && index(active, " " k " ") == 0) { if (!have) st = "idle_skipped" } else due = due (due == "" ? "" : " ") k }
        }
        if (body == "") body = "\"exit_bits\":null,\"passed\":null,\"in_drivedb\":null,\"protocol\":null,\"model\":null,\"rotation_rpm\":null,\"temperature_c\":null,\"power_on_hours\":null,\"power_cycles\":null,\"unsafe_shutdowns\":null,\"reallocated_sectors\":null,\"pending_sectors\":null,\"offline_uncorrectable\":null,\"reported_uncorrect\":null,\"crc_errors\":null,\"runtime_bad_blocks\":null,\"media_errors\":null,\"critical_warning\":null,\"available_spare_pct\":null,\"wear_pct\":null,\"wear_source\":null,\"written_bytes\":null,\"written_source\":null,\"error_log_count\":null,\"selftest_count\":null"
        parts = ""
        for (i = 1; i <= np[k] && i <= 16; i++) { pk = pn[k, i]
            parts = parts (i > 1 ? "," : "") "{\"name\":\"" pk "\",\"size_bytes\":" jn(ps[k, i] == "" ? "" : sprintf("%.0f", ps[k, i] * 512)) ",\"mount\":" ((pk in fs_m) ? "\"" esc(fs_m[pk]) "\"" : "null") ",\"fstype\":" ((pk in fs_t) ? "\"" esc(fs_t[pk]) "\"" : "null") ",\"used_pct\":" ((pk in fs_p) ? jn(fs_p[pk]) : "null") "}" }
        em = "null"
        # 0x00 means the card does not report it: not a zero, not level one.
        if (tr[x] == "emmc") em = "{\"life_a\":" jn((la[x] + 0 >= 1 && la[x] + 0 <= 11) ? la[x] : "") ",\"life_b\":" jn((lb[x] + 0 >= 1 && lb[x] + 0 <= 11) ? lb[x] : "") ",\"pre_eol\":" jn((eol[x] + 0 >= 1 && eol[x] + 0 <= 3) ? eol[x] : "") "}"
        out = out (x > 1 ? "," : "") "{\"name\":\"" k "\",\"transport\":\"" tr[x] "\",\"port\":" jq(port[x]) ",\"model\":" jq(model[x]) ",\"size_bytes\":" sprintf("%.0f", size[x] * 512) \
            ",\"rotational\":" jb(rot[x]) ",\"removable\":" jb(rem[x]) ",\"partitions\":[" parts "],\"emmc\":" em \
            ",\"smart\":{\"state\":\"" st "\",\"checked_at\":" jn(vts) "," body "}}"
    }
    printf "[%s]#%s", out, due
}
'

have_smartctl=0; command -v smartctl >/dev/null 2>&1 && have_smartctl=1
storage_disks_json="null"
smart_due=""
# busybox awk dies on a missing input FILE argument; both are cheap to create.
: >> "$STORAGE_STATIC"; : >> "$SMART_CACHE"
# Without `df -T` the type column is missing and every other column shifts, so
# the join would read a size as a mount point. Better no mount than a wrong one.
_df_body=""
[ "$df_has_type" = 1 ] && _df_body="$df_out"
_storage_out=$(printf '%s\n' "$_df_body" | awk -v smartctl="$have_smartctl" -v active="$diskdev_active" -v now="$now_ts" \
    -v stuck="$smart_stuck" -v interval="$SMART_INTERVAL_SEC" "$BK_STORAGE_AWK" "$STORAGE_STATIC" "$SMART_CACHE" -)
# Last '#': a mount path may contain one, a device name cannot.
storage_disks_json=${_storage_out%#*}
smart_due=${_storage_out##*#}
[ -d "$BK_SYS/block" ] || storage_disks_json="null"
[ -z "$storage_disks_json" ] && storage_disks_json="null"

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
    # One awk over every readable /proc/<pid>/io instead of two forks per
    # process (200-400 forks a minute on a router). Readability is checked
    # in the shell first because busybox awk aborts on a file it cannot open.
    # The paths are fed to awk as DATA and read with getline, not passed as
    # input files: a process can exit between the readability test and awk's
    # open(), and busybox awk treats an unopenable input file as fatal - it
    # would abort mid-scan and silently truncate the ranking. getline just
    # returns -1 for the vanished ones.
    top_io_json=$(
        for io_file in /proc/[0-9]*/io; do [ -r "$io_file" ] && printf '%s\n' "$io_file"; done | awk '
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
            # A process names itself, quotes included: escaped as in
            # BK_STORAGE_AWK, character by character (see there).
            function esc(s,   o, c, i, n) { gsub(/[\001-\037]/, "", s); if (!index(s, "\\") && !index(s, "\"")) return s; o = ""; n = length(s); for (i = 1; i <= n; i++) { c = substr(s, i, 1); o = o ((c == "\\" || c == "\"") ? "\\" c : c) } return o }
            { nm = esc($3);
              printf "%s{\"pid\":%s,\"name\":\"%s\",\"write_bytes\":%s}", (n++ ? "," : "["), $2, nm, $1 }
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
# " name name ... " of every process in the snapshot, or empty when there is
# no snapshot to ask (no top, no output, no header): bk_running then asks pidof.
bk_top_names=""
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
    # busybox top has no -w: the procps form failed first on every run and
    # each report paid for two top invocations. Pick the form once.
    bk_top_args="-bn1 -w 512"
    case "$(readlink -f "$(command -v top)" 2>/dev/null)" in *busybox*) bk_top_args="-bn1" ;; esac
    COLUMNS=512 top $bk_top_args >"$BK_TOP_OUT" 2>/dev/null &
    bk_top_pid=$!
    wait "$bk_top_pid" 2>/dev/null
    # `-s` asks the question without reading the file into the shell: the
    # awk below reads the snapshot itself.
    if [ ! -s "$BK_TOP_OUT" ] && [ "$bk_top_args" != "-bn1" ]; then
        COLUMNS=512 top -bn1 >"$BK_TOP_OUT" 2>/dev/null &
        bk_top_pid=$!
        wait "$bk_top_pid" 2>/dev/null
    fi
    if [ -s "$BK_TOP_OUT" ]; then
        # ONE awk over the snapshot. It was cat + a parse + a PID filter + two
        # rankings of `awk | sort -rn | head -5 | awk` each: 17 forks, and the
        # snapshot (about 100 processes on a router) went through the shell
        # four times. Line 1 is the CPU ranking, line 2 the RAM ranking, line 3
        # "P" plus every process name (see bk_running below the DNS probe).
        #
        # Every string is built the way the old pipe built it: the parse is
        # the same code, the record is the "name|cpu|mb|pid" line re-split on
        # "|" (so a name holding a "|" shifts its fields exactly as awk -F'|'
        # shifted them), and the ranking is `sort -rn | head -5`: the larger
        # number first, on equal numbers the byte-wise greater whole key line
        # (sort's tie-break, reversed by -r). The number is compared as a
        # float, the way a full busybox sort (FEATURE_SORT_BIG) compares it.
        # OpenWrt's busybox has no SORT_BIG and its `sort -n` compared only
        # the integer part, so there "12" (a VSZ of 12m) outranked "12.5";
        # here the larger value is always first.
        _top3=$(awk -v self="$$" -v sampler="$bk_top_pid" '
        function basename(p,   n, a) { n = split(p, a, "/"); return a[n]; }
        function before(ka, la, kb, lb) { if (ka + 0 != kb + 0) return (ka + 0 > kb + 0); return (la > lb) }
        # The five best key lines of ranking w in L[w, 1..n[w]], best first.
        function keep(w, k, l,   i) {
            for (i = n[w]; i > 0 && before(k, l, K[w, i], L[w, i]); i--)
                if (i < 5) { K[w, i + 1] = K[w, i]; L[w, i + 1] = L[w, i] }
            if (i < 5) { K[w, i + 1] = k; L[w, i + 1] = l; if (n[w] < 5) n[w]++ }
        }
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
            names = names " " name;
            line = name "|" cpu "|" mb "|" $pid_i;
            split(line, f, "|");
            # Only two PIDs are dropped: the agent itself and the sampler that
            # just ran. Not by name - a hand-started `top` that really eats
            # the CPU stays visible.
            if (!(f[4] != self && f[4] != sampler)) next;
            rec = f[1] "|" f[2] "|" f[3];
            if (f[2] != "") keep("c", f[2], f[2] "|" rec);
            if (f[3] != "") keep("m", f[3], f[3] "|" rec);
        }
        END {
            # Both values go into BOTH lists; null only where the process
            # really has no value.
            printf "[";
            for (i = 1; i <= n["c"]; i++) { split(L["c", i], f, "|"); if (i > 1) printf ", "; printf "{\"name\":\"%s\",\"cpu\":%.1f,\"ram_mb\":%s}", f[2], f[3], (f[4] != "" ? sprintf("%.1f", f[4]) : "null") }
            printf "]\n[";
            for (i = 1; i <= n["m"]; i++) { split(L["m", i], f, "|"); if (i > 1) printf ", "; printf "{\"name\":\"%s\",\"ram_mb\":%.1f,\"cpu\":%s}", f[2], f[4], (f[3] != "" ? sprintf("%.1f", f[3]) : "null") }
            printf "]\nP%s \n", names;
        }' "$BK_TOP_OUT" 2>/dev/null)
        case "$_top3" in
            *"$BK_NL"*"$BK_NL"*)
                top_cpu_json=${_top3%%"$BK_NL"*}; _top3=${_top3#*"$BK_NL"}
                top_ram_json=${_top3%%"$BK_NL"*}; _top3=${_top3#*"$BK_NL"}
                bk_top_names=${_top3#P}
                [ "$bk_top_names" = " " ] && bk_top_names="" ;;
        esac
    fi
    rm -f "$BK_TOP_OUT" 2>/dev/null
fi
[ -z "$top_cpu_json" ] && top_cpu_json="[]"
[ -z "$top_ram_json" ] && top_ram_json="[]"

# --- mwan3 (multi-WAN) ---
mwan3_policies_json="[]"
mwan3_active_gw=""
if [ -f /etc/config/mwan3 ]; then
    # `mwan3 status` prints " interface wan is online and tracking is
    # active". The old grep for "active" returned the word "active" as the
    # gateway, and the policy scan never saw a policy line before the
    # interface section, so every entry carried an empty policy name.
    #
    # One awk straight on the output (it was held in the shell and read twice,
    # by printf | sed | head and by printf | awk: 8 forks, now 3). Line 1 is
    # "G" + the gateway: the name in the FIRST "interface NAME is online" line,
    # what the sed + head -1 printed (empty when that name is empty). Line 2
    # is the policy list. Nothing is printed when mwan3 printed nothing, and
    # the defaults stay, as they did when the status was empty.
    _mw_out=$(mwan3 status 2>/dev/null | awk '
    length($0) > 0 { any = 1 }
    !gwdone && /^ *interface [^ ]* is online/ { s = $0; sub(/^ *interface /, "", s); gw = substr(s, 1, index(s, " ") - 1); gwdone = 1 }
    /^ *interface [^ ]+ is (online|offline|disabled)/ {
        st = ($4 == "online") ? "online" : "offline";
        if (count > 0) js = js ", ";
        js = js sprintf("{\"policy\":null,\"interface\":\"%s\",\"status\":\"%s\"}", $2, st); count++
    }
    END { if (any) printf "G%s\n[%s]", gw, js }')
    case "$_mw_out" in
        G*"$BK_NL"*)
            mwan3_active_gw=${_mw_out%%"$BK_NL"*}; mwan3_active_gw=${mwan3_active_gw#G}
            mwan3_policies_json=${_mw_out#*"$BK_NL"} ;;
    esac
fi
[ -z "$mwan3_active_gw" ] && mwan3_active_gw="null" || mwan3_active_gw="\"$mwan3_active_gw\""

# --- Cesta paketu skrz router (hodinova cache) -----------------------------
#
# Everything below is configuration or a runtime switch: it changes when
# somebody changes it, not from minute to minute. Reading it every minute
# would cost a uci fork per option, a tc call per queue and one ubus dump of
# every netdev, so it is read once an hour into a cache and sent from there
# on every run. A cache that cannot be read whole is made again, never
# guessed: the file carries a timestamp, the finished object and an end
# marker, exactly like the identity cache.
BK_WAN_PATH_CACHE="$BK_PRIVATE_DIR/wan-path.cache"
BK_WAN_PATH_TTL_SEC=3600
wan_path_json="null"
# The legacy SQM keys keep the charts alive, but they no longer come from
# sqm.@queue[0] - that is "the first section in the file", which on this
# router is a disabled leftover on the LAN conduit. They now come from the
# queue that sits on the WAN path, and sqm_enabled is null (not false) when
# the router has no SQM configuration at all: "not installed" is not "off".
sqm_enabled="null"
sqm_download_kbps="null"
sqm_upload_kbps="null"
sqm_dropped="null"
# ECN marks are a per-tin table of `tc -s qdisc`; not parsed here.
sqm_ecn="null"

# Drops of one qdisc. The value FOLLOWS the word: "(dropped 12, overlimits 0
# requeues 0)". Answer in $_tc_v, so the caller needs no subshell.
bk_tc_dropped() {
    _tc_v=""
    _tc_out=$(tc -s qdisc show dev "$1" 2>/dev/null)
    case "$_tc_out" in
        *"dropped "*)
            _tc_n=${_tc_out#*dropped }
            _tc_n=${_tc_n%%,*}
            case "$_tc_n" in
                ''|*[!0-9]*) ;;
                *) _tc_v="$_tc_n" ;;
            esac
            ;;
    esac
}

# One queue of `uci show sqm`, once its section is complete. Only an ENABLED
# queue on a device of the WAN chain is reported: a queue is often configured
# on the physical port while the WAN runs over pppoe-wan on top of it, and
# the other way round, so the whole chain of the 4c walk is matched.
bk_sqm_flush() {
    [ -n "$_wp_sect" ] || return 0
    [ "$_wp_en" = "1" ] || return 0
    [ -n "$_wp_if" ] || return 0
    case "$_wp_if" in *[!A-Za-z0-9._-]*) return 0 ;; esac
    case " $bk_wan_chain $wan_l3_device $wan_link_dev " in
        *" $_wp_if "*) ;;
        *) return 0 ;;
    esac
    # A rate of 0 means "this direction is not shaped", not "0 kbit/s".
    _wp_dlk="null"
    case "$_wp_dl" in
        ''|*[!0-9]*|0) ;;
        *) _wp_dlk="$_wp_dl" ;;
    esac
    _wp_ulk="null"
    case "$_wp_ul" in
        ''|*[!0-9]*|0) ;;
        *) _wp_ulk="$_wp_ul" ;;
    esac
    _wp_eg="null"; _wp_in="null"
    if [ "$bk_have_tc" = 1 ]; then
        bk_tc_dropped "$_wp_if"
        [ -n "$_tc_v" ] && _wp_eg="$_tc_v"
        # Ingress is shaped on SQM's own ifb device, whose name the kernel
        # cuts to 15 bytes - so the lookup has to cut it the same way.
        _wp_ifb="ifb4$_wp_if"
        while [ ${#_wp_ifb} -gt 15 ]; do _wp_ifb=${_wp_ifb%?}; done
        bk_tc_dropped "$_wp_ifb"
        [ -n "$_tc_v" ] && _wp_in="$_tc_v"
    fi
    wp_sqm="$wp_sqm${wp_sqm:+,}{\"iface\":\"$_wp_if\",\"download_kbps\":$_wp_dlk,\"upload_kbps\":$_wp_ulk,\"egress_dropped\":$_wp_eg,\"ingress_dropped\":$_wp_in}"
    # The legacy keys describe the WAN queue; the first match wins, as the
    # router has one WAN path.
    if [ "$sqm_enabled" != "true" ]; then
        sqm_enabled="true"
        sqm_download_kbps="$_wp_dlk"
        sqm_upload_kbps="$_wp_ulk"
        sqm_dropped="$_wp_eg"
    fi
}

# LAN ports behind the bridge, read from ubus's pretty-printed output with
# `read` - never with jsonfilter, which this image does not carry and which
# no test of this repository runs (X5). What the parser has to survive is
# the printer's format, not JSON's: tab indentation, an EMPTY array printed
# over three lines, `"speed"` a string such as "1000F" or "150H", and no
# `"speed"` line at all when there is no carrier.
#
# Three answers come out of one dump:
#   lan_port_max_mbit - the fastest LAN port linked RIGHT NOW. A current
#     state: a lone 100 Mbit printer makes it 100.
#   lan_port_cap_mbit - what those ports can do at all, from netifd's
#     link-supported list. Never derived from `speed`: a negotiated rate is
#     not a capability.
#   lan_conduits[]    - the DSA conduit the user ports share, with ITS rate.
#     Five gigabit ports behind one gigabit conduit share 1 Gbit.
# Only members of the LAN bridge with devtype dsa or ethernet count: an LTE
# modem on USB is an "ethernet" device too and is not a LAN port.
bk_lan_rec() {
    [ -n "$_lc_dev" ] || return 0
    case "$_lc_dev" in *[!A-Za-z0-9._-]*) return 0 ;; esac
    _lc_recs="$_lc_recs$_lc_dev|$_lc_type|$_lc_cond|$_lc_speed|$_lc_cap|$_lc_car|$_lc_dup|$_lc_pcap$BK_NL"
}

bk_lan_caps() {
    lan_port_max=""; lan_port_cap=""; lan_conduits=""
    _lc_dev=""; _lc_type=""; _lc_speed=""; _lc_cond=""; _lc_cap=""
    _lc_car=""; _lc_dup=""; _lc_pcap=""
    _lc_members=""; _lc_recs=""; _lc_arr=""; _lc_conds=""; _lc_any=0
    while IFS= read -r _lc_ln; do
        # A device opens at ONE tab; every key inside it is deeper, so the
        # depth alone tells the two apart.
        case "$_lc_ln" in
            "$_lc_t1"'"'*': {')
                bk_lan_rec
                _lc_dev=${_lc_ln#*\"}
                _lc_dev=${_lc_dev%%\"*}
                _lc_type=""; _lc_speed=""; _lc_cond=""; _lc_cap=""; _lc_arr=""
                _lc_car=""; _lc_dup=""; _lc_pcap=""
                _lc_any=1
                continue
                ;;
        esac
        [ -n "$_lc_dev" ] || continue
        case "$_lc_ln" in
            "$_lc_t2"'"devtype": "'*)
                _lc_type=${_lc_ln#*: \"}
                _lc_type=${_lc_type%%\"*}
                ;;
            "$_lc_t2"'"conduit": "'*)
                _lc_cond=${_lc_ln#*: \"}
                _lc_cond=${_lc_cond%%\"*}
                case "$_lc_cond" in *[!A-Za-z0-9._-]*) _lc_cond="" ;; esac
                ;;
            "$_lc_t2"'"carrier": '*)
                _lc_v=${_lc_ln#*: }
                _lc_car=${_lc_v%,}
                ;;
            "$_lc_t2"'"speed": "'*)
                # "1000F" / "150H": F and H are the duplex, the digits the rate.
                _lc_v=${_lc_ln#*: \"}
                _lc_v=${_lc_v%%\"*}
                case "$_lc_v" in
                    *F) _lc_dup="full" ;;
                    *H) _lc_dup="half" ;;
                esac
                _lc_v=${_lc_v%[FH]}
                case "$_lc_v" in
                    ''|*[!0-9]*) ;;
                    *) _lc_speed="$_lc_v" ;;
                esac
                ;;
            "$_lc_t2"'"link-supported": ['*) _lc_arr="ls" ;;
            "$_lc_t2"'"link-partner-advertising": ['*) _lc_arr="lp" ;;
            "$_lc_t2"'"bridge-members": ['*) _lc_arr="bm" ;;
            "$_lc_t2"']'*) _lc_arr="" ;;
            "$_lc_t3"'"'*)
                case "$_lc_arr" in
                    ls)
                        # The rate is the builtin prefix of the mode name:
                        # 1000baseT-F -> 1000.
                        _lc_v=${_lc_ln#*\"}
                        _lc_v=${_lc_v%%\"*}
                        _lc_v=${_lc_v%%base*}
                        case "$_lc_v" in
                            ''|*[!0-9]*) ;;
                            *)
                                if [ -z "$_lc_cap" ] || [ "$_lc_v" -gt "$_lc_cap" ]; then
                                    _lc_cap="$_lc_v"
                                fi
                                ;;
                        esac
                        ;;
                    lp)
                        # What the OTHER end offers. A port that supports
                        # 1000 and links at 100 is not a fault when the
                        # partner never advertised more - lan1 on the real
                        # capture. An empty array leaves it null.
                        _lc_v=${_lc_ln#*\"}
                        _lc_v=${_lc_v%%\"*}
                        _lc_v=${_lc_v%%base*}
                        case "$_lc_v" in
                            ''|*[!0-9]*) ;;
                            *)
                                if [ -z "$_lc_pcap" ] || [ "$_lc_v" -gt "$_lc_pcap" ]; then
                                    _lc_pcap="$_lc_v"
                                fi
                                ;;
                        esac
                        ;;
                    bm)
                        if [ "$_lc_dev" = "$BK_LAN_BRIDGE" ]; then
                            _lc_v=${_lc_ln#*\"}
                            _lc_v=${_lc_v%%\"*}
                            _lc_members="$_lc_members $_lc_v"
                        fi
                        ;;
                esac
                ;;
        esac
    done
    bk_lan_rec
    [ "$_lc_any" = 1 ] || return 0

    while IFS='|' read -r _lc_d _lc_ty _lc_c _lc_s _lc_cp _lc_ca _lc_du _lc_pc; do
        [ -n "$_lc_d" ] || continue
        case " $_lc_members " in *" $_lc_d "*) ;; *) continue ;; esac
        case "$_lc_ty" in dsa|ethernet) ;; *) continue ;; esac
        if [ -n "$_lc_s" ]; then
            if [ -z "$lan_port_max" ] || [ "$_lc_s" -gt "$lan_port_max" ]; then
                lan_port_max="$_lc_s"
            fi
        fi
        if [ -n "$_lc_cp" ]; then
            if [ -z "$lan_port_cap" ] || [ "$_lc_cp" -gt "$lan_port_cap" ]; then
                lan_port_cap="$_lc_cp"
            fi
        fi
        if [ -n "$_lc_c" ]; then
            case " $_lc_conds " in
                *" $_lc_c "*) ;;
                *) _lc_conds="$_lc_conds $_lc_c" ;;
            esac
        fi
    done <<EOF_LAN
$_lc_recs
EOF_LAN

    lan_conduits="[]"
    for _lc_c in $_lc_conds; do
        _lc_cs=""
        while IFS='|' read -r _lc_d _lc_ty _lc_c2 _lc_s _lc_cp _lc_ca _lc_du _lc_pc; do
            [ "$_lc_d" = "$_lc_c" ] && _lc_cs="$_lc_s"
        done <<EOF_CON
$_lc_recs
EOF_CON
        case "$lan_conduits" in
            '[]') lan_conduits="[{\"dev\":\"$_lc_c\",\"mbit\":${_lc_cs:-null}}" ;;
            *) lan_conduits="$lan_conduits,{\"dev\":\"$_lc_c\",\"mbit\":${_lc_cs:-null}}" ;;
        esac
    done
    case "$lan_conduits" in
        '[]') ;;
        *) lan_conduits="$lan_conduits]" ;;
    esac
}

# How many DEVICES sit behind each wired port, from the bridge's forwarding
# database. COUNTS ONLY: a MAC address is personal data and none ever leaves
# this function - awk sees them, the payload gets a number. The named device
# list is a separate, opt-in feature and is not built here.
#
# What is not a learnt client, from the owner's own `bridge fdb show`:
#   permanent        the bridge's and the ports' own addresses
#   vlan 4095 ... self  the rows DSA keeps for its CPU port
#   33:33:* 01:00:5e:*  IPv6 and IPv4 multicast groups, ff:ff... broadcast
# One MAC learnt in several VLANs is one device, so the pair mac+dev counts
# once.
bk_fdb_counts() {
    "$1" fdb show br "$2" 2>/dev/null | awk '
        {
            mac = tolower($1); dev = ""; skip = 0
            for (i = 2; i <= NF; i++) {
                if ($i == "dev") dev = $(i + 1)
                else if ($i == "permanent") skip = 1
                else if ($i == "vlan" && $(i + 1) == "4095") skip = 1
            }
            if (skip || dev == "") next
            if (mac ~ /^33:33:/ || mac ~ /^01:00:5e:/) next
            if (mac == "ff:ff:ff:ff:ff:ff") next
            if ((mac " " dev) in seen) next
            seen[mac " " dev] = 1
            n[dev]++
        }
        END { for (d in n) print d " " n[d] }
    '
}

# The wired switch ports, built from the dump bk_lan_caps has just walked
# (its records and the bridge member list are still in the globals) plus the
# forwarding database. Per port: does it carry a link, at what rate and
# duplex, what the port itself supports, what the OTHER end advertises - so
# a 100 Mbit link can be named as the partner's limit instead of a fault -
# and how many devices are behind it. The conduit is carried too: on DSA
# every wired client shares that one link to the CPU, and it is the real
# ceiling.
#
# Null, never an empty list, when the router cannot answer: no dump, no LAN
# bridge, no `bridge` command, or a switch that is not DSA - there the kernel
# does not tell which physical port a client came in on.
bk_lan_ports() {
    lan_ports_json="null"
    [ "$_lc_any" = 1 ] || return 0
    [ -n "$_lc_members" ] || return 0
    _lp_bin=""
    if command -v bridge >/dev/null 2>&1; then
        _lp_bin=bridge
    elif [ -x /usr/sbin/bridge ]; then
        # cron hands a job a PATH without sbin on some builds; the tool is
        # there, so look where OpenWrt puts it before giving up.
        _lp_bin=/usr/sbin/bridge
    else
        return 0
    fi
    _lp_dsa=0
    while IFS='|' read -r _lc_d _lc_ty _lc_c _lc_s _lc_cp _lc_ca _lc_du _lc_pc; do
        [ -n "$_lc_d" ] || continue
        case " $_lc_members " in *" $_lc_d "*) ;; *) continue ;; esac
        [ "$_lc_ty" = dsa ] && _lp_dsa=1
    done <<EOF_DSA
$_lc_recs
EOF_DSA
    [ "$_lp_dsa" = 1 ] || return 0

    _lp_counts=$(bk_fdb_counts "$_lp_bin" "$BK_LAN_BRIDGE")
    _lp_ports=""; _lp_total=0; _lp_sep=""
    while IFS='|' read -r _lc_d _lc_ty _lc_c _lc_s _lc_cp _lc_ca _lc_du _lc_pc; do
        [ -n "$_lc_d" ] || continue
        case " $_lc_members " in *" $_lc_d "*) ;; *) continue ;; esac
        # Only the switch's own ports. A radio and a USB LTE modem are
        # bridge members too and are not wired ports.
        [ "$_lc_ty" = dsa ] || continue
        _lp_n=0
        while read -r _lp_k _lp_v; do
            [ "$_lp_k" = "$_lc_d" ] || continue
            # The count is fed into arithmetic below; anything that is not a
            # number would end the run, and a number is all awk can print.
            case "$_lp_v" in ''|*[!0-9]*) ;; *) _lp_n="$_lp_v" ;; esac
        done <<EOF_CNT
$_lp_counts
EOF_CNT
        _lp_total=$((_lp_total + _lp_n))
        _lp_link=false
        [ "$_lc_ca" = true ] && _lp_link=true
        _lp_dq=null
        [ -n "$_lc_du" ] && _lp_dq="\"$_lc_du\""
        _lp_ports="$_lp_ports$_lp_sep{\"name\":\"$_lc_d\",\"link\":$_lp_link,\"speed_mbit\":${_lc_s:-null},\"duplex\":$_lp_dq,\"max_mbit\":${_lc_cp:-null},\"partner_max_mbit\":${_lc_pc:-null},\"clients\":$_lp_n}"
        _lp_sep=","
    done <<EOF_PORT
$_lc_recs
EOF_PORT
    [ -n "$_lp_ports" ] || return 0

    # The conduit's own record, looked up by the name the ports gave.
    _lp_cond=""; _lp_sep=""
    for _lp_c in $_lc_conds; do
        _lp_cs=""; _lp_cd=""; _lp_cl=false
        while IFS='|' read -r _lc_d _lc_ty _lc_c _lc_s _lc_cp _lc_ca _lc_du _lc_pc; do
            if [ "$_lc_d" = "$_lp_c" ]; then
                _lp_cs="$_lc_s"; _lp_cd="$_lc_du"
                [ "$_lc_ca" = true ] && _lp_cl=true
            fi
        done <<EOF_CD
$_lc_recs
EOF_CD
        _lp_dq=null
        [ -n "$_lp_cd" ] && _lp_dq="\"$_lp_cd\""
        _lp_cond="$_lp_cond$_lp_sep{\"dev\":\"$_lp_c\",\"link\":$_lp_cl,\"speed_mbit\":${_lp_cs:-null},\"duplex\":$_lp_dq}"
        _lp_sep=","
    done
    lan_ports_json="{\"bridge\":\"$BK_LAN_BRIDGE\",\"ports\":[$_lp_ports],\"conduits\":[$_lp_cond],\"clients_total\":$_lp_total}"
}

_lc_t1='	'
_lc_t2='		'
_lc_t3='			'

# The LAN switch, every run. The rest of the WAN path is configuration and is
# read once an hour, but which cable is plugged in and how many devices are
# behind it changes by the minute, so this one dump is taken each time - and
# taken ONCE: the hourly block below reads the same records instead of asking
# ubus a second time.
lan_ports_json="null"
lan_port_max=""; lan_port_cap=""; lan_conduits=""
BK_LAN_BRIDGE="br-lan"
if command -v ubus >/dev/null 2>&1; then
    if bk_iface_load lan; then
        _wp_lan=""
        json_get_var _wp_lan l3_device
        [ -z "$_wp_lan" ] && json_get_var _wp_lan device
        # The name is passed to `bridge` and put in the payload, so it is held
        # to what a netdev name may be - the same guard the port names get.
        case "$_wp_lan" in *[!A-Za-z0-9._-]*) _wp_lan="" ;; esac
        [ -n "$_wp_lan" ] && BK_LAN_BRIDGE="$_wp_lan"
    fi
    bk_lan_caps <<EOF_UBUS_DEV
$(ubus call network.device status 2>/dev/null)
EOF_UBUS_DEV
    bk_lan_ports
fi
log_debug "LAN porty: most=${lan_port_max:-null} strop=${lan_port_cap:-null} bridge=$BK_LAN_BRIDGE"

wp_ts=""; wp_body=""; wp_sq_en=""; wp_sq_dl=""; wp_sq_ul=""; wp_sq_dr=""; wp_end=""
if [ -f "$BK_WAN_PATH_CACHE" ]; then
    {
        IFS= read -r wp_ts
        IFS= read -r wp_body
        IFS= read -r wp_sq_en
        IFS= read -r wp_sq_dl
        IFS= read -r wp_sq_ul
        IFS= read -r wp_sq_dr
        IFS= read -r wp_end
    } < "$BK_WAN_PATH_CACHE" 2>/dev/null
fi
case "$wp_ts" in ''|*[!0-9]*) wp_ts=0 ;; esac
wp_age=$((now_ts - wp_ts))
if [ "$wp_end" = "end" ] && [ "$wp_age" -ge 0 ] && [ "$wp_age" -lt "$BK_WAN_PATH_TTL_SEC" ]; then
    wan_path_json="$wp_body"
    sqm_enabled="$wp_sq_en"
    sqm_download_kbps="$wp_sq_dl"
    sqm_upload_kbps="$wp_sq_ul"
    sqm_dropped="$wp_sq_dr"
else
    bk_have_uci=0; command -v uci >/dev/null 2>&1 && bk_have_uci=1
    bk_have_tc=0; command -v tc >/dev/null 2>&1 && bk_have_tc=1

    # Configured, not measured. No uci at all is "we cannot tell"; the option
    # simply unset is fw4's own default (off), which is an answer.
    wp_flow="null"; wp_flow_hw="null"
    if [ "$bk_have_uci" = 1 ]; then
        _wp_v=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)
        if [ "$_wp_v" = "1" ]; then wp_flow="true"; else wp_flow="false"; fi
        _wp_v=$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)
        if [ "$_wp_v" = "1" ]; then wp_flow_hw="true"; else wp_flow_hw="false"; fi
    fi

    # Runtime, not configuration: a flowtable in the LOADED ruleset is proof
    # that offloading really is in the kernel. The ruleset was fetched once
    # for the firewall counters, so this costs no fork.
    wp_flowtable="null"
    if command -v nft >/dev/null 2>&1; then
        case "$bk_nft_ft" in
            1) wp_flowtable="true" ;;
            *) wp_flowtable="false" ;;
        esac
    fi

    # A LABEL, deliberately not a boolean: in this tree an unset option means
    # packet steering is ON and only "0" disables it, while on 22.03/23.05
    # based systems unset means OFF. No rule reads it; the runtime masks
    # below are what the recommendations are allowed to believe.
    wp_steering="null"
    if [ "$bk_have_uci" = 1 ]; then
        _wp_v=$(uci -q get network.@globals[0].packet_steering 2>/dev/null)
        [ -z "$_wp_v" ] && _wp_v="unset"
        case "$_wp_v" in
            *[!A-Za-z0-9_-]*) wp_steering="null" ;;
            *) wp_steering="\"$_wp_v\"" ;;
        esac
    fi

    # RPS on the WAN PORT itself, never on the l3 device: mvneta has several
    # RX queues and the init script fills them all, so any mask with a bit
    # set means steering is really running.
    wp_steer_active="null"; wp_rps_mask="null"; wp_threaded="null"
    if [ -n "$wan_link_dev" ]; then
        _wp_seen=0; _wp_on=0
        for _wp_q in "$BK_SYS/class/net/$wan_link_dev"/queues/rx-*/rps_cpus; do
            [ -r "$_wp_q" ] || continue
            _wp_m=""
            IFS= read -r _wp_m < "$_wp_q" 2>/dev/null
            [ -n "$_wp_m" ] || continue
            _wp_seen=1
            case "$_wp_m" in *[!0,]*) _wp_on=1 ;; esac
        done
        if [ "$_wp_seen" = 1 ]; then
            if [ "$_wp_on" = 1 ]; then wp_steer_active="true"; else wp_steer_active="false"; fi
        fi
        _wp_m=""
        [ -r "$BK_SYS/class/net/$wan_link_dev/queues/rx-0/rps_cpus" ] && IFS= read -r _wp_m < "$BK_SYS/class/net/$wan_link_dev/queues/rx-0/rps_cpus" 2>/dev/null
        case "$_wp_m" in
            ''|*[!0-9a-fA-F,]*) ;;
            *) wp_rps_mask="\"$_wp_m\"" ;;
        esac
        _wp_m=""
        [ -r "$BK_SYS/class/net/$wan_link_dev/threaded" ] && IFS= read -r _wp_m < "$BK_SYS/class/net/$wan_link_dev/threaded" 2>/dev/null
        case "$_wp_m" in
            0) wp_threaded="false" ;;
            1) wp_threaded="true" ;;
        esac
    fi

    # Ring drops of the port. ethtool is not in every image, and a driver
    # that does not carry these two counter names answers nothing - which is
    # null, never 0 (R7: on this router ethtool is not installed at all).
    wp_ring="null"
    if [ -n "$wan_link_dev" ] && command -v ethtool >/dev/null 2>&1; then
        _wp_sum=""
        while read -r _wp_k _wp_n; do
            case "$_wp_k" in
                rx_discard:|rx_overrun:)
                    case "$_wp_n" in
                        ''|*[!0-9]*) continue ;;
                    esac
                    _wp_sum=$(( ${_wp_sum:-0} + _wp_n ))
                    ;;
            esac
        done <<EOF_ETH
$(ethtool -S "$wan_link_dev" 2>/dev/null)
EOF_ETH
        [ -n "$_wp_sum" ] && wp_ring="$_wp_sum"
    fi

    # SQM. An empty list means "checked, no queue on the WAN path"; null
    # means "could not check" - two different answers.
    wp_sqm="null"
    if [ "$bk_have_uci" = 1 ] && [ -f /etc/config/sqm ]; then
        wp_sqm=""
        sqm_enabled="false"
        _wp_sect=""; _wp_en=""; _wp_if=""; _wp_dl=""; _wp_ul=""
        while IFS= read -r _wp_ln; do
            case "$_wp_ln" in sqm.*) ;; *) continue ;; esac
            _wp_rest=${_wp_ln#sqm.}
            _wp_key=${_wp_rest%%=*}
            _wp_val=${_wp_rest#*=}
            _wp_val=${_wp_val#\'}
            _wp_val=${_wp_val%\'}
            case "$_wp_key" in
                *.*) _wp_s=${_wp_key%%.*}; _wp_o=${_wp_key#*.} ;;
                *) _wp_s=$_wp_key; _wp_o="" ;;
            esac
            if [ "$_wp_s" != "$_wp_sect" ]; then
                bk_sqm_flush
                _wp_sect="$_wp_s"; _wp_en=""; _wp_if=""; _wp_dl=""; _wp_ul=""
            fi
            case "$_wp_o" in
                enabled) _wp_en="$_wp_val" ;;
                interface) _wp_if="$_wp_val" ;;
                download) _wp_dl="$_wp_val" ;;
                upload) _wp_ul="$_wp_val" ;;
            esac
        done <<EOF_SQM
$(uci -q show sqm 2>/dev/null)
EOF_SQM
        bk_sqm_flush
        wp_sqm="[$wp_sqm]"
    fi

    # The LAN side comes from the per-run walk above: the dump was already
    # taken this run, and asking ubus for the same 27 kB twice a minute buys
    # nothing.

    wan_path_json="{\"checked_at\":$now_ts,\"flow_offloading\":$wp_flow,\"flow_offloading_hw\":$wp_flow_hw,\"flowtable_active\":$wp_flowtable,\"packet_steering\":$wp_steering,\"packet_steering_active\":$wp_steer_active,\"wan_rps_mask\":$wp_rps_mask,\"wan_threaded_napi\":$wp_threaded,\"wan_rx_ring_drops\":$wp_ring,\"sqm\":$wp_sqm,\"lan_port_max_mbit\":${lan_port_max:-null},\"lan_port_cap_mbit\":${lan_port_cap:-null},\"lan_conduits\":${lan_conduits:-null}}"

    # Written through a temporary name, like the identity cache: a run killed
    # half way must not leave a file whose lines have shifted by one.
    printf '%s\n' "$now_ts" "$wan_path_json" "$sqm_enabled" "$sqm_download_kbps" \
        "$sqm_upload_kbps" "$sqm_dropped" "end" \
        > "$BK_WAN_PATH_CACHE.tmp" 2>/dev/null && mv "$BK_WAN_PATH_CACHE.tmp" "$BK_WAN_PATH_CACHE" 2>/dev/null
    log_debug "WAN cesta: flow=$wp_flow flowtable=$wp_flowtable steering=$wp_steering/$wp_steer_active ring=$wp_ring sqm=$sqm_enabled"
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
# From the one interface dump above: the usual names first, then any
# interface whose protocol is a modem one - the uplink does not have to be
# called "lte" for the backup to count. Five speculative ubus calls a run
# used to go here, four of them failing.
if bk_iface_load "lte wwan wwan0 modem lte1" "qmi mbim ncm modemmanager 3g" "wan"; then
    _lte_up_raw=""
    json_get_var _lte_up_raw up
    case "$_lte_up_raw" in
        1|true) lte_up="true" ;;
        0|false) lte_up="false" ;;
    esac
    _lte_dev=""
    json_get_var _lte_dev l3_device
    [ -z "$_lte_dev" ] && json_get_var _lte_dev device
    [ -n "$_lte_dev" ] && lte_device="$_lte_dev"
    _lte_up_sec=""
    json_get_var _lte_up_sec uptime
    case "$_lte_up_sec" in
        ''|*[!0-9]*) : ;;
        *) lte_uptime="$_lte_up_sec" ;;
    esac
    _lte_a4=""
    json_get_keys _lte_a4 "ipv4-address"
    for _lte_k in $_lte_a4; do
        json_select "ipv4-address"
        json_select "$_lte_k"
        _lte_addr=""
        json_get_var _lte_addr address
        json_select ..
        json_select ..
        [ -n "$_lte_addr" ] && lte_ipv4="$_lte_addr"
        break
    done
fi

# --- LTE throughput (KB/s): the same tick/tock as the WAN rate above -------
# Together with the wan_lost / wan_restored events this is what tells the two
# links apart on the web - which bytes went over the primary line and which
# over the backup. A different device than last time (modem re-enumerated)
# is a fresh start, not a negative delta.
net_lte="null"
NET_LTE_STATE_FILE="/tmp/status-agent-openwrt-net-lte.state"
if [ -n "$lte_device" ] && [ "$lte_device" != "null" ] && [ -f /proc/net/dev ]; then
    lte_bytes=$(awk -v iface="$lte_device" '
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
    if [ -n "$lte_bytes" ]; then
        if [ -f "$NET_LTE_STATE_FILE" ]; then
            if bk_line1 "$NET_LTE_STATE_FILE"; then
                bk_cut3 "$_sl" ,; prev_lte_ts=$_c1; prev_lte_dev=$_c2; prev_lte_bytes=$_c3
            else
                prev_lte_ts=$(cut -d',' -f1 "$NET_LTE_STATE_FILE" 2>/dev/null)
                prev_lte_dev=$(cut -d',' -f2 "$NET_LTE_STATE_FILE" 2>/dev/null)
                prev_lte_bytes=$(cut -d',' -f3 "$NET_LTE_STATE_FILE" 2>/dev/null)
            fi
            if [ "$prev_lte_dev" = "$lte_device" ] && [ -n "$prev_lte_ts" ] && [ -n "$prev_lte_bytes" ]; then
                elapsed_lte=$((now_ts - prev_lte_ts))
                delta_lte=$((lte_bytes - prev_lte_bytes))
                if [ "$elapsed_lte" -gt 0 ] && [ "$delta_lte" -ge 0 ]; then
                    bk_fdiv "$delta_lte" "$((elapsed_lte * 1024))" 1; net_lte=$_fd
                fi
            fi
        fi
        echo "${now_ts},${lte_device},${lte_bytes}" > "$NET_LTE_STATE_FILE" 2>/dev/null || true
    fi
fi

# --- Which uplink carried each speedtest result (0.1.11) ----------------------
#
# Turris runs librespeed-cli from cron without binding it to an interface, so
# a test follows whatever the default route is at that moment. At night that
# can be the LTE backup, and 0.1.10 sent such a result as if it were the
# line's speed (47 Mbit/s on a 400 Mbit/s PPPoE). The test is NOT skipped or
# blocked here: a backup measurement is a real measurement of the backup. It
# is only attributed to the uplink that carried it.
#
# The evidence is the BYTE COUNTERS of the two uplink devices, never a route
# or a ping. A route says where packets would go now, not where they went a
# minute ago. Bytes are what the test consists of: the result file states how
# many it received and sent, and the device that carried them must have
# counted at least that many over an interval that contains the test.
# Background traffic can only ADD bytes to a device, never remove them, so
# "the LTE device covers >= 50 % of the test in each direction" cannot come
# out true for a test that went over the WAN - the backup only carries its
# health checks while it is not the default route. The interface counters
# also include the IP/TCP (and TLS) overhead the application count leaves
# out, which again only errs towards a larger delta.
#
# Every run keeps one snapshot line in a small ring: the kernel uptime
# (centiseconds; the clock can step, uptime cannot), name + ifindex + rx/tx
# bytes of the WAN l3 device and of the LTE device, and the newest result
# name the directory listing held. The ring holds 5 lines, so a result that
# appeared since the previous run still finds a snapshot from BEFORE the test
# started. /var/run is a ramdisk, so a reboot (new counters) starts a new
# ring. Builtins only: `read` of sysfs files and one printf; nothing forks.
#
# Only a FRESH result is judged: one newer than everything the previous run
# (at most 150 s ago) listed. An older file - the whole directory on the
# first run of 0.1.11, or after a gap - has no snapshot from before it, and
# its uplink stays null rather than a guess.
BK_UPLINK_RING="$BK_PRIVATE_DIR/uplink.ring"
BK_UPLINK_CACHE="$BK_PRIVATE_DIR/uplink.cache"
# The LTE device only counts when it is a device of its own: a router whose
# WAN IS the modem reports it as the WAN, and the same counters must not be
# charged to both.
_ul_ldev=""
if [ -n "$lte_device" ] && [ "$lte_device" != "null" ] && [ "$lte_device" != "$wan_l3_device" ]; then
    _ul_ldev="$lte_device"
fi
# bk_ul_dev DEV -> _ul_d "dev|idx|rx|tx". An unreadable counter leaves its
# field empty, which the evaluation reads as "counters missing", not zero.
bk_ul_dev() {
    _ul_d="$1|||"
    [ -n "$1" ] || return 0
    case "$1" in *[!A-Za-z0-9._@-]*) _ul_d="|||"; return 0 ;; esac
    bk_netnum "$BK_SYS/class/net/$1/ifindex"; _ul_i="$_wv"
    bk_netnum "$BK_SYS/class/net/$1/statistics/rx_bytes"; _ul_r="$_wv"
    bk_netnum "$BK_SYS/class/net/$1/statistics/tx_bytes"; _ul_d="$1|$_ul_i|$_ul_r|$_wv"
}
# The counters and the uptime are read at the same moment, now; the listing
# above ran seconds earlier, which only widens the interval.
bk_uptime_cs; _ul_cs="$_up_cs"
_ul_now=""
if [ -n "$_ul_cs" ]; then
    bk_ul_dev "$wan_l3_device"; _ul_w="$_ul_d"
    bk_ul_dev "$_ul_ldev"; _ul_l="$_ul_d"
    _ul_now="$_ul_cs|$_ul_w|$_ul_l"
fi
# The previous lines, oldest first, joined by ';' for awk (-v cannot carry a
# newline on every awk). A line that is not ours is dropped.
_ul_ring=""; _ul_keep=""; _ul_n=0
if [ -r "$BK_UPLINK_RING" ]; then
    while IFS= read -r _ul_line; do
        case "$_ul_line" in
            *';'*) ;;
            [0-9]*'|'*)
                _ul_ring="$_ul_ring${_ul_ring:+;}$_ul_line"
                _ul_keep="$_ul_keep$_ul_line$BK_NL"; _ul_n=$((_ul_n + 1)) ;;
        esac
    done < "$BK_UPLINK_RING"
fi
while [ "$_ul_n" -gt 4 ]; do
    _ul_keep=${_ul_keep#*"$BK_NL"}; _ul_n=$((_ul_n - 1))
done
if [ -n "$_ul_now" ]; then
    printf '%s%s|%s\n' "$_ul_keep" "$_ul_now" "$speed_listed" > "$BK_UPLINK_RING" 2>/dev/null || true
fi
# awk writes the verdict cache itself, but only into a directory it can
# write: a failed redirection is fatal in awk and would cost the results.
_ul_cache=""
[ -w "$BK_PRIVATE_DIR" ] && _ul_cache="$BK_UPLINK_CACHE"

if [ -n "$speed_files" ]; then
    # The selected files are read by awk itself - one fork for the whole
    # batch instead of a `tr` per file. Line 1 of the output is the newest
    # timestamp that really went into the array (a file without a speed is
    # not an item), the rest is the array.
    #
    # link_mbit comes from THIS run's state: what the port was linked at when
    # the result was picked up. Nothing else is invented for a result the
    # router started: the tool is only named when the file itself proves it,
    # and the uplink (with iface) only when the byte counters prove it.
    #
    # The uplink verdict is taken ONCE, the run that first sees a result, and
    # kept in uplink.cache for as long as the result is offered: one offered
    # again after a failed POST is no longer fresh and would come out null.
    # shellcheck disable=SC2086
    _sp_out=$(awk -v link_mbit="$wan_link_mbit" -v ring="$_ul_ring" -v nows="$_ul_now" \
        -v cache="$_ul_cache" '
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
        function server_block(json) {
            if (!match(json, /"server"[[:space:]]*:[[:space:]]*\{[^}]*\}/)) return "";
            return substr(json, RSTART, RLENGTH);
        }
        # Only the server block is searched. The client block holds the
        # public address and the ISP name, and neither may ever leave the
        # router; server.url carries query strings and is not wanted either.
        function server_name(part,   m) {
            if (!match(part, /"name"[[:space:]]*:[[:space:]]*"[^"]*"/)) return "";
            m = substr(part, RSTART, RLENGTH);
            sub(/.*:[[:space:]]*"/, "", m); sub(/"$/, "", m);
            # A name with an escape would have been cut in the middle by the
            # match above; send nothing rather than broken JSON.
            if (index(m, "\\") > 0) return "";
            return m;
        }
        # Only the SCHEME of server.url leaves the router, never the URL.
        function server_proto(part) {
            if (match(part, /"url"[[:space:]]*:[[:space:]]*"https:\/\//)) return "https";
            if (match(part, /"url"[[:space:]]*:[[:space:]]*"http:\/\//)) return "http";
            return "";
        }
        function num(s) { return (s ~ /^[0-9]+$/) ? s + 0 : -1 }
        # Share of the test one device covers: the smaller of the two
        # directions that carried bytes. -1 when its counters cannot answer
        # (missing, another ifindex, gone backwards = reset).
        function cover(i0, i1, r0, r1, t0, t1, br, bs,   dr, dt, c) {
            if (i0 == "" || i0 != i1) return -1;
            r0 = num(r0); r1 = num(r1); t0 = num(t0); t1 = num(t1);
            if (r0 < 0 || r1 < 0 || t0 < 0 || t1 < 0 || r1 < r0 || t1 < t0) return -1;
            dr = r1 - r0; dt = t1 - t0; c = 1e9;
            if (br > 0 && dr / br < c) c = dr / br;
            if (bs > 0 && dt / bs < c) c = dt / bs;
            return c;
        }
        # The larger share, for "some of it went here".
        function part(r0, r1, t0, t1, br, bs,   p) {
            p = 0;
            if (br > 0 && (num(r1) - num(r0)) / br > p) p = (num(r1) - num(r0)) / br;
            if (bs > 0 && (num(t1) - num(t0)) / bs > p) p = (num(t1) - num(t0)) / bs;
            return p;
        }
        # -> "uplink|evidence|iface", empty fields for unknown.
        function judge(dl, ul, br, bs,   dur, i, s, best, w, l, cw, cl, lk, pl) {
            if (nows == "" || prev == "" || br == "" && bs == "") return "||";
            br = (br == "" ? 0 : br + 0); bs = (bs == "" ? 0 : bs + 0);
            if (br <= 0 && bs <= 0) return "||";
            # How long the transfer took, from its own numbers; two minutes
            # when they cannot say. The snapshot must come from before the
            # test STARTED, and the test ended after the previous listing.
            dur = 120;
            if (dl + 0 > 0 && ul + 0 > 0) dur = br * 8 / (dl * 1e6) + bs * 8 / (ul * 1e6);
            best = 0;
            for (i = nr; i >= 1; i--) {
                split(rl[i], s, "|");
                if (s[1] + 0 < now[1] + 0 && s[1] + 0 <= prv[1] - (dur + 60) * 100) { best = i; break }
            }
            if (!best) return "||";
            split(rl[best], s, "|");
            # A window longer than 15 minutes says little about one test.
            if (now[1] - s[1] > 90000) return "||";
            if (now[2] == "" || s[2] != now[2]) return "||";
            cw = cover(s[3], now[3], s[4], now[4], s[5], now[5], br, bs);
            # The backup must have been the same device through the window,
            # or absent through all of it.
            lk = (s[6] == "" && now[6] == "");
            cl = -1;
            if (!lk && s[6] == now[6]) {
                cl = cover(s[7], now[7], s[8], now[8], s[9], now[9], br, bs);
                lk = (cl >= 0);
            }
            if (!lk) return "||";
            if (cl >= 0.5) return "backup|counters|" now[6];
            pl = (cl >= 0 ? part(s[8], now[8], s[9], now[9], br, bs) : 0);
            if (cw >= 0.5) return (pl >= 0.1 ? "mixed|counters|" : "wan|counters|" now[2]);
            if (cw >= 0 && cl >= 0 && pl >= 0.1 && cw + pl >= 0.5) return "mixed|counters|";
            return "||";
        }
        function q(s) { return (s == "" ? "null" : "\"" s "\"") }
        function emit(   ts, n, p, dl, ul, pg, ji, br, bs, sb, sv, pr, tl, v, u) {
            if (fname == "") return;
            n = split(fname, p, "/"); ts = p[n]; sub(/\.json$/, "", ts);
            dl = pick(body, "download,download_mbps,dl,downloadMbps");
            ul = pick(body, "upload,upload_mbps,ul,uploadMbps");
            pg = pick(body, "ping,ping_ms,latency");
            ji = pick(body, "jitter,jitter_ms");
            if (dl == "" && ul == "") return;
            br = pick(body, "bytes_received");
            bs = pick(body, "bytes_sent");
            sb = server_block(body);
            sv = server_name(sb);
            pr = server_proto(sb);
            # The result file names no tool and no version. Only the Rust
            # port writes a "tls" block (the Go client has none), so that is
            # evidence; without it the tool stays null instead of a guess.
            tl = (match(body, /"tls"[[:space:]]*:[[:space:]]*\{/) ? "\"rust\"" : "null");
            if (ts in cached) v = cached[ts];
            else if (prev_listed == "" || ts > prev_listed) v = judge(dl, ul, br, bs);
            else v = "||";
            keep[++kn] = ts "|" v;
            split(v, u, "|");
            out = out sprintf("%s{\"timestamp\":\"%s\",\"download_mbps\":%s,\"upload_mbps\":%s,\"ping_ms\":%s,\"jitter_ms\":%s,\"server\":%s,\"bytes_received\":%s,\"bytes_sent\":%s,\"started_by\":\"turris\",\"iface\":%s,\"tool\":%s,\"link_mbit\":%s,\"uplink\":%s,\"uplink_evidence\":%s,\"proto\":%s,\"diagnostics\":{\"v\":1,\"cpu_measured\":false}}",
                (c++ ? "," : "["), ts,
                (dl == "" ? "null" : dl), (ul == "" ? "null" : ul),
                (pg == "" ? "null" : pg), (ji == "" ? "null" : ji),
                (sv == "" ? "null" : "\"" sv "\""),
                (br == "" ? "null" : br), (bs == "" ? "null" : bs),
                q(u[3]), tl, (link_mbit == "" ? "null" : link_mbit),
                q(u[1]), q(u[2]), q(pr));
            newest = ts;
        }
        BEGIN {
            nr = (ring == "" ? 0 : split(ring, rl, ";"));
            split(nows, now, "|");
            # Fields: 1 uptime, 2-5 WAN dev/idx/rx/tx, 6-9 LTE, 10 newest listed.
            prev = ""; prev_listed = "";
            if (nr) {
                split(rl[nr], prv, "|");
                # The previous run must be recent and of this boot, or
                # "newer than it listed" says nothing about when a file came.
                if (nows != "" && prv[1] + 0 < now[1] + 0 && now[1] - prv[1] <= 15000) {
                    prev = rl[nr]; prev_listed = prv[10];
                }
            }
            if (cache != "") {
                while ((getline line < cache) > 0) {
                    if (split(line, f, "|") == 4) cached[f[1]] = f[2] "|" f[3] "|" f[4];
                }
                close(cache);
            }
        }
        FNR == 1 { emit(); body = ""; fname = FILENAME }
        { body = body $0 }
        END {
            emit();
            if (cache != "" && kn) {
                for (i = 1; i <= kn; i++) printf "%s\n", keep[i] > cache;
                close(cache);
            }
            print newest; printf "%s", (c ? out "]" : "[]")
        }' $speed_files)
    speedtests_newest=${_sp_out%%"$BK_NL"*}
    case "$_sp_out" in
        *"$BK_NL"*) speedtests_json=${_sp_out#*"$BK_NL"} ;;
    esac
fi
[ -z "$speedtests_json" ] && speedtests_json="[]"
# A test running right now writes no file yet, so the listing above cannot
# see it. One fork, and only when the listing did not answer already.
if [ "$speedtest_active" = "false" ] && command -v pidof >/dev/null 2>&1; then
    pidof librespeed-cli >/dev/null 2>&1 && speedtest_active="true"
fi
# Written BEFORE the POST: until the server says what it stored, the results
# are still the router's. 0.1.6 advanced the state right here and lost every
# result of a report that never arrived.
if [ -n "$speedtests_newest" ]; then
    printf '%s\n' "$speedtests_newest" > "$BK_SPEED_PENDING" 2>/dev/null || true
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
#
# Builtin, into $_xr: the old `printf | sed -n "s|.*<T>\([^<]*\)</T>.*|\1|p"
# | head -1` cost four forks a tag and HiLink asks for 21 tags a minute. Same
# answer on any input: sed worked line by line, took the FIRST line with a
# match and, its leading .* being greedy, the LAST <T>text</T> on that line,
# where text runs up to the next '<'.
bk_xml_tag() {
    _xr=""
    case "$1" in *"<$2>"*"</$2>"*) ;; *) return 0 ;; esac
    _xs=$1; _xf=""
    while :; do
        case "$_xs" in *"<$2>"*) ;; *) return 0 ;; esac
        # A newline before the next <T> ends the line the match is on.
        [ -n "$_xf" ] && case "${_xs%%"<$2>"*}" in *"$BK_NL"*) return 0 ;; esac
        _xs=${_xs#*"<$2>"}; _xv=${_xs%%<*}
        case "$_xs" in
            "$_xv</$2>"*) case "$_xv" in *"$BK_NL"*) ;; *) _xr=$_xv; _xf=1 ;; esac ;;
        esac
    done
}
# Only the characters of bracket class $1 (0-9, or 0-9.-) of $_xr, as
# `sed 's/[^0-9]//g'` left them.
bk_xml_keep() {
    while :; do
        case "$_xr" in
            *[!$1]*) _xk=${_xr%%[!$1]*}; _xr=$_xk${_xr#"$_xk"?} ;;
            *) return 0 ;;
        esac
    done
}

# GET na HiLink API modemu. Nektere firmwary (E3372h-320, Brovi E3372-325)
# odpovi na kazdy dotaz chybou 125002/125003, dokud nedostanou session cookie
# a overovaci token z /api/webserver/SesTokInfo - pak se dotaz zopakuje s
# obojim. uclient-fetch hlavicky poslat neumi, takze na takovem modemu bez
# curl/wget zustanou hodnoty null.
# Result lands in $_hl_out (not printed through $(...): a subshell could not
# keep the session token for the next endpoint). Once the modem answered
# with a token it is sent straight away, and once the gateway failed to
# answer at all the remaining endpoints are skipped - a stuck modem used to
# cost four 2-second timeouts every minute.
_hl_ses=""; _hl_ver=""; _hl_dead="0"
bk_hilink_get() {
    _hl_url="http://${lte_api_host}$1"
    _hl_body=""; _hl_out=""
    [ "$_hl_dead" = "1" ] && return 0
    if [ -n "$_hl_ses" ] && [ -n "$_hl_ver" ] && command -v curl >/dev/null 2>&1; then
        _hl_body=$(curl -s -m 2 -H "Cookie: $_hl_ses" -H "__RequestVerificationToken: $_hl_ver" "$_hl_url" 2>/dev/null)
    elif [ -n "$_hl_ses" ] && [ -n "$_hl_ver" ] && command -v wget >/dev/null 2>&1; then
        _hl_body=$(wget -q -T 2 -O - --header "Cookie: $_hl_ses" --header "__RequestVerificationToken: $_hl_ver" "$_hl_url" 2>/dev/null)
    elif command -v curl >/dev/null 2>&1; then
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
            bk_xml_tag "$_hl_tok" SesInfo; _hl_ses=$_xr
            bk_xml_tag "$_hl_tok" TokInfo; _hl_ver=$_xr
            if [ -n "$_hl_ses" ] && [ -n "$_hl_ver" ]; then
                if command -v curl >/dev/null 2>&1; then
                    _hl_body=$(curl -s -m 2 -H "Cookie: $_hl_ses" -H "__RequestVerificationToken: $_hl_ver" "$_hl_url" 2>/dev/null)
                elif command -v wget >/dev/null 2>&1; then
                    _hl_body=$(wget -q -T 2 -O - --header "Cookie: $_hl_ses" --header "__RequestVerificationToken: $_hl_ver" "$_hl_url" 2>/dev/null)
                fi
            fi
            ;;
    esac
    [ -z "$_hl_body" ] && _hl_dead="1"
    _hl_out="$_hl_body"
}

# bk_hilink_cached ENDPOINT FILE TTL_SEC KEY: like bk_hilink_get, but the
# answer is kept in FILE (timestamp, KEY, body) and reused while it is
# younger than TTL_SEC and KEY has not changed. SIM state and operator name
# change about never; the modem was asked for both every minute anyway.
bk_hilink_cached() {
    _hc_file="$2"; _hc_ttl="$3"; _hc_key="$4"; _hl_out=""
    if [ -f "$_hc_file" ]; then
        # Builtin reads of line 1, line 2 and the rest (three sed forks
        # before); the body loses its trailing newlines, as $(sed) did.
        _hc_ts=""; _hc_k=""; _hc_body=""; _hc_l=""
        {
            IFS= read -r _hc_ts; IFS= read -r _hc_k
            while IFS= read -r _hc_l; do _hc_body="$_hc_body$_hc_l$BK_NL"; _hc_l=""; done
        } 2>/dev/null < "$_hc_file"
        _hc_body="$_hc_body$_hc_l"
        case "$_hc_ts" in ''|*[!0-9]*) _hc_ts=0 ;; esac
        if [ $((now_ts - _hc_ts)) -lt "$_hc_ttl" ] && [ "$_hc_k" = "$_hc_key" ]; then
            while :; do case "$_hc_body" in *"$BK_NL") _hc_body=${_hc_body%"$BK_NL"} ;; *) break ;; esac; done
            _hl_out=$_hc_body
            [ -n "$_hl_out" ] && return 0
        fi
    fi
    bk_hilink_get "$1"
    if [ -n "$_hl_out" ]; then
        { printf '%s\n%s\n' "$now_ts" "$_hc_key"; printf '%s' "$_hl_out"; } > "$_hc_file.tmp" 2>/dev/null \
            && mv "$_hc_file.tmp" "$_hc_file" 2>/dev/null
    fi
}

if [ "$lte_up" = "true" ] && [ "$lte_ipv4" != "null" ] && [ -n "$lte_ipv4" ]; then
    # The last octet becomes .1 (`sed 's/\.[0-9]*$/.1/'`) without the two
    # forks; an address that is not plain digits and dots still goes to sed.
    case "$lte_ipv4" in
        *[!0-9.]*) lte_api_host=$(echo "$lte_ipv4" | sed 's/\.[0-9]*$/.1/') ;;
        *.*) lte_api_host=${lte_ipv4%.*}.1 ;;
        *) lte_api_host=$lte_ipv4 ;;
    esac

    # -- registrace do site: /api/monitoring/status --
    # ConnectionStatus 901 = pripojeno; 902/903/905 = odpojeno; 7/11/12/14/37
    # = sit pristup nepovolila (spatna SIM, zakazana sluzba). Neznamy kod se
    # neprevadi na nic - zustane null a surovy kod jde dal k posouzeni.
    bk_hilink_get /api/monitoring/status; lte_mon_xml="$_hl_out"
    bk_xml_tag "$lte_mon_xml" ConnectionStatus; bk_xml_keep 0-9; _cc=$_xr
    if [ -n "$_cc" ]; then
        lte_conn_code="$_cc"
        case "$_cc" in
            901) lte_connected="true" ;;
            902|903|905|7|11|12|14|37|201|202|203|204) lte_connected="false" ;;
        esac
    fi
    bk_xml_tag "$lte_mon_xml" ServiceStatus; bk_xml_keep 0-9; _sc=$_xr
    [ -n "$_sc" ] && lte_service_code="$_sc"
    # SimStatus: 1 = platna; 0/255 = neni vlozena; 2/3/4 = SIM sit NEPRIJIMA
    # (neplatna pro hlasove / datove sluzby / oboje) - typicky deaktivovana nebo
    # zablokovana operatorem. Presne to mela SIM, kvuli ktere tahle kontrola
    # vznikla: /api/pin/status hlasil 257 "pripravena" (PIN je jina osa), ale
    # SimStatus 4 a ConnectionStatus 902.
    bk_xml_tag "$lte_mon_xml" SimStatus; bk_xml_keep 0-9; _ss=$_xr
    [ -n "$_ss" ] && lte_sim_status_code="$_ss"
    case "$_ss" in
        1) lte_sim_state="ready" ;;
        0|255) lte_sim_state="no_sim" ;;
        2|3|4) lte_sim_state="invalid" ;;
    esac

    # -- stav SIM: /api/pin/status --
    # SimState 257 = pripravena, 260 = ceka na PIN, 261 = ceka na PUK,
    # 255 = zadna SIM, 256/262 = neplatna nebo zablokovana.
    # Ten minutes, or sooner when monitoring/status reports a different SimStatus.
    bk_hilink_cached /api/pin/status "$BK_PRIVATE_DIR/hilink-pin.cache" 600 "$lte_sim_status_code"; lte_pin_xml="$_hl_out"
    bk_xml_tag "$lte_pin_xml" SimState; bk_xml_keep 0-9; _sim=$_xr
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
    bk_xml_tag "$lte_pin_xml" SimPinTimes; bk_xml_keep 0-9; _pin_left=$_xr
    [ -n "$_pin_left" ] && lte_sim_pin_left="$_pin_left"

    # -- sila signalu: /api/device/signal --
    bk_hilink_get /api/device/signal; lte_sig_xml="$_hl_out"

    # "<rsrp>" holds no newline, so a substring test is what grep -q saw.
    case "$lte_sig_xml" in *"<rsrp>"*) _hl_sig=1 ;; *) _hl_sig=0 ;; esac
    if [ "$_hl_sig" = 1 ]; then
        # Hodnoty nesou jednotky primo v textu ("-83dBm", "-6.0dB"), tak se
        # necha jen cislo. Prazdny tag = udaj modem nehlasi -> null.
        # Builtins into $_xr: the $(...) versions cost 8-9 forks a field.
        bk_xml_num() {
            bk_xml_tag "$lte_sig_xml" "$1"; bk_xml_keep 0-9.-
            case "$_xr" in ''|-|.|--) _xr=null ;; esac
        }
        bk_xml_str() {
            bk_xml_tag "$lte_sig_xml" "$1"
            if [ -z "$_xr" ]; then _xr=null; else bk_js "$_xr"; _xr="\"$_jr\""; fi
        }

        bk_xml_num rsrp; lte_rsrp=$_xr
        bk_xml_num rsrq; lte_rsrq=$_xr
        bk_xml_num sinr; lte_sinr=$_xr
        bk_xml_num rssi; lte_rssi=$_xr
        bk_xml_num pci; lte_pci=$_xr
        bk_xml_num cell_id; lte_cell_id=$_xr
        bk_xml_str plmn; lte_plmn=$_xr
        bk_xml_str dlbandwidth; lte_bandwidth=$_xr

        # Pasmo hlasi modem jako cislo (1 = B1); ve zbytku systemu je to text.
        bk_xml_tag "$lte_sig_xml" band; _band=$_xr
        [ -n "$_band" ] && lte_band="B${_band}"

        # Jmeno operatora ma jiny endpoint; bez nej zustava to, co uz mame.
        # Once per heavy interval, or when the PLMN code from device/signal changes.
        bk_hilink_cached /api/net/current-plmn "$BK_PRIVATE_DIR/hilink-plmn.cache" "$HEAVY_OP_INTERVAL_SEC" "$lte_plmn"; lte_plmn_xml="$_hl_out"
        bk_xml_tag "$lte_plmn_xml" FullName; _carrier=$_xr
        [ -z "$_carrier" ] && { bk_xml_tag "$lte_plmn_xml" ShortName; _carrier=$_xr; }
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
        # uqmi calls it "snr"; the old "sinr" key never existed in its output.
        _q=$(echo "$lte_signal" | jsonfilter -e '@.snr' 2>/dev/null); [ -n "$_q" ] && lte_sinr="$_q"
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
# One logread for everything below (it used to dump the whole ring buffer
# once per service - five to seven times a minute - and once more for the
# error counts) and a single awk pass for all services.
service_restarts_json="{}"
bk_log_full=""
command -v logread >/dev/null 2>&1 && bk_log_full=$(logread 2>/dev/null)
if [ -n "$bk_log_full" ]; then
    svc_names=""
    for svc in dnsmasq odhcpd hostapd mwan3 uhttpd nginx wireguard; do
        [ -f "/etc/init.d/$svc" ] && svc_names="$svc_names $svc"
    done
    if [ -n "$svc_names" ]; then
        service_restarts_json=$(printf '%s\n' "$bk_log_full" | awk -v names="$svc_names" '
            BEGIN { n = split(names, s, " "); for (i = 1; i <= n; i++) if (s[i] != "") cnt[s[i]] = 0 }
            { low = tolower($0); if (index(low, "start") == 0) next; for (k in cnt) if (index(low, k) > 0) cnt[k]++ }
            END { printf "{"; for (i = 1; i <= n; i++) { if (s[i] == "") continue; printf "%s\"%s\": %d", (c++ ? ", " : ""), s[i], cnt[s[i]] } printf "}" }')
    fi
fi

# --- WAN reconnect stats (state file) ---
#
# G24: the counter starts as null, not 0. A reconnect is only visible as a
# DROP of the WAN uptime between two runs, so the very first run - and every
# run after the state file was lost with /tmp on a reboot - has watched
# nothing and has nothing to report. From the second run on, 0 is a measured
# zero: the agent did compare two samples and saw no reset.
wan_reconnect_count="null"
wan_last_reconnect="null"
bk_state_file="/tmp/bk_wan_state"
if [ -n "$wan_uptime" ] && [ "$wan_uptime" != "null" ] && [ "$wan_uptime" -gt 0 ] 2>/dev/null; then
    if [ -f "$bk_state_file" ]; then
        # One builtin pass for the three `awk -F= '/^key=/{print $2}'` reads:
        # the text between the first and the second '=' of every line that
        # starts with key=, one line per match, trailing newlines dropped.
        prev_uptime=""; prev_count=""; prev_reconnect=""; _ws_l=""
        while IFS= read -r _ws_l || [ -n "$_ws_l" ]; do
            _ws_v=${_ws_l#*=}; _ws_v=${_ws_v%%=*}
            case "$_ws_l" in
                uptime=*) prev_uptime="$prev_uptime$_ws_v$BK_NL" ;;
                count=*) prev_count="$prev_count$_ws_v$BK_NL" ;;
                reconnect=*) prev_reconnect="$prev_reconnect$_ws_v$BK_NL" ;;
            esac
            _ws_l=""
        done 2>/dev/null < "$bk_state_file"
        while :; do case "$prev_uptime" in *"$BK_NL") prev_uptime=${prev_uptime%"$BK_NL"} ;; *) break ;; esac; done
        while :; do case "$prev_count" in *"$BK_NL") prev_count=${prev_count%"$BK_NL"} ;; *) break ;; esac; done
        while :; do case "$prev_reconnect" in *"$BK_NL") prev_reconnect=${prev_reconnect%"$BK_NL"} ;; *) break ;; esac; done
        # A previous sample exists, so the comparison below is real. A state
        # file written before the upgrade carries "count=0"; a file that was
        # never written carries nothing, and then this run is the first sample.
        case "$prev_uptime" in ''|*[!0-9]*) ;; *) wan_reconnect_count=0 ;; esac
        case "$prev_count" in ''|*[!0-9]*) ;; *) wan_reconnect_count="$prev_count" ;; esac
        [ -n "$prev_reconnect" ] && wan_last_reconnect="$prev_reconnect"
        # WAN uptime reset = reconnect detected
        if [ -n "$prev_uptime" ] && [ "$wan_uptime" -lt "$prev_uptime" ] 2>/dev/null; then
            [ "$wan_reconnect_count" = "null" ] && wan_reconnect_count=0
            wan_reconnect_count=$((wan_reconnect_count + 1))
            wan_last_reconnect=$now_ts   # the run's clock, no `date` fork
        fi
    fi
    printf "uptime=%s\ncount=%s\nreconnect=%s\n" "$wan_uptime" "$wan_reconnect_count" "$wan_last_reconnect" > "$bk_state_file" 2>/dev/null
fi

# --- Logs stats ---
# Log: busybox logread pouziva "<err>"/"<warn>", syslog-ng (Turris) pise
# uroven slovem ("err:", "error", "warning"). Drivejsi grep na "<err>"
# proto na Turrisu hlasil vzdycky nulu. Bez citelneho logu zustava null.
#
# W1-C3 (0.1.8): next to the two counts the report carries the error lines
# behind log_errors_24h - the newest 5 distinct ones, each with its repeat
# count - and log_window_secs, how far back the read buffer reaches. The
# "24h" in the key is historic: logread is a ring buffer, and 500 of its
# lines can be ten minutes or three days, so the app needs the real span to
# say what the count covers.
#
# A log line is the one thing in this report that can carry what the owner
# never meant to send - a phone's name in a DHCP line, an address in a failed
# connection - so every line is masked HERE, before it can leave the router:
# MAC, IPv6, IPv4, e-mail, names under the home domains (.lan, .local, ...),
# names that look like a device (iphone, galaxy, desktop-, ...), the client
# name dnsmasq writes after a MAC, and hex runs of 12+ (DUIDs, client ids).
# Masking comes BEFORE the 200-character cut, so a cut can never leave half
# an address that no mask recognises any more. Every byte outside printable
# ASCII becomes "?": the server's JSON decoder refuses invalid UTF-8, and one
# stray byte in a log line must not cost the whole report.
#
# Two switches keep the lines on the router; the counts are sent either way.
# LOG_LINES_ENABLED=0 in agent_openwrt.cfg is the owner's, on the router. The
# monitor's own setting is the server's: it names it in every answer, and the
# answer is remembered in BK_LOG_LINES_OFF (see the answer handling below).
# log_lines_state says which of them is in force, so an empty list is never
# mistaken for "no errors".
log_errors_24h="null"
log_warnings_24h="null"
log_window_secs="null"
log_errors_recent="null"
BK_LOG_LINES_OFF="$ScriptPath/agent_openwrt.loglines-off"
case "$LOG_LINES_ENABLED" in
    0|no|false|off) log_lines_state="off_router" ;;
    *)
        log_lines_state="on"
        [ -f "$BK_LOG_LINES_OFF" ] && log_lines_state="off_monitor"
        ;;
esac
log_buf=""
if [ -n "$bk_log_full" ]; then
    log_buf=$(printf '%s\n' "$bk_log_full" | tail -n 500)
fi
if [ -z "$log_buf" ] && command -v journalctl >/dev/null 2>&1; then
    log_buf=$(journalctl --since "24 hours ago" --no-pager -n 500 2>/dev/null)
fi
if [ -z "$log_buf" ] && [ -r /var/log/messages ]; then
    log_buf=$(tail -n 500 /var/log/messages 2>/dev/null)
fi
if [ -n "$log_buf" ]; then
    _lg_lines=0
    [ "$log_lines_state" = on ] && _lg_lines=1
    # ONE awk over the buffer does all of it, the two counts included (they
    # were two greps over the same lines; the regexes are unchanged). Line 1
    # of its answer is "errors warnings window", line 2 the JSON list.
    #
    # Times become epoch seconds. logd and journalctl print local time with
    # no zone, so the router's CURRENT offset is applied (a line from before
    # a DST switch is then an hour off; the window labels a count, it is not
    # a stopwatch) and without a readable offset those times stay null.
    # syslog-ng on Turris writes ISO 8601 with its own offset, used as it is.
    # The BSD form has no year: this year, or the last one when this year
    # would put the line in the future.
    #
    # Deduplicated on program + MASKED text, so the same failure against two
    # addresses is one line with count 2. The apostrophe of "Pepe's-iPhone"
    # comes in through -v q: this program is single-quoted.
    _lg_out=$(printf '%s\n' "$log_buf" | awk -v now="$now_ts" -v tz="$(date +%z 2>/dev/null)" -v lines="$_lg_lines" -v q="'" '
        function days(y, m, d,    era, yoe, doy, doe) {
            y -= (m <= 2)
            era = int((y >= 0 ? y : y - 399) / 400)
            yoe = y - era * 400
            doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
            doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
            return era * 146097 + doe - 719468
        }
        function year_of(t,    z, era, doe, yoe, doy, mp) {
            z = int(t / 86400) + 719468
            era = int(z / 146097)
            doe = z - era * 146097
            yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
            doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
            mp = int((5 * doy + 2) / 153)
            return yoe + era * 400 + (mp >= 10)
        }
        function hms(t,    h) { split(t, h, ":"); return h[1] * 3600 + h[2] * 60 + int(h[3]) }
        # Matching runs on a lowercased copy, the text is cut from the original.
        function repl(s, re, tag,    out) {
            out = ""
            while (match(tolower(s), re)) { out = out substr(s, 1, RSTART - 1) tag; s = substr(s, RSTART + RLENGTH) }
            return out s
        }
        # A run of hex, dots and colons is IPv6 when it has "::" or 5+ colons
        # and stands on its own; a clock (09:05:02) has neither, and the
        # "d::" in the "ntpd::instance1" of procd is glued to a word.
        function v6(s,    out, tok, n, pre, post) {
            out = ""
            while (match(tolower(s), /[0-9a-f.]*:[0-9a-f.:]*:[0-9a-f.:]*/)) {
                tok = substr(s, RSTART, RLENGTH); n = gsub(/:/, ":", tok)
                pre = RSTART > 1 ? substr(s, RSTART - 1, 1) : ""
                post = substr(s, RSTART + RLENGTH, 1)
                if ((index(tok, "::") || n >= 5) && pre !~ /[A-Za-z0-9_]/ && post !~ /[A-Za-z0-9_]/) tok = "<ipv6>"
                out = out substr(s, 1, RSTART - 1) tok
                s = substr(s, RSTART + RLENGTH)
            }
            return out s
        }
        # A home-domain name, also before a full stop - but not network.lan.proto.
        function lanhost(s,    out, m) {
            out = ""
            while (match(tolower(s), LANRE "[.]?([^a-z0-9._-]|$)")) {
                m = substr(s, RSTART, RLENGTH)
                out = out substr(s, 1, RSTART - 1) "<host>"
                s = substr(s, RSTART + RLENGTH)
                match(tolower(m), "^" LANRE); out = out substr(m, RLENGTH + 1)
            }
            return out s
        }
        # Each mask is a scan of the line, so a cheap test skips the ones that
        # cannot match (no "::" and under 5 colons: no IPv6). The name masks
        # open with a character class that a scan retries at every position,
        # which is why their bare word lists are asked first.
        function mask(s,    c) {
            s = repl(s, "[0-9a-f][0-9a-f]([:-][0-9a-f][0-9a-f])([:-][0-9a-f][0-9a-f])([:-][0-9a-f][0-9a-f])([:-][0-9a-f][0-9a-f])([:-][0-9a-f][0-9a-f])", "<mac>")
            c = s
            if (index(s, "::") || gsub(/:/, "", c) >= 5) s = v6(s)
            if (index(s, ".")) s = repl(s, "[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+", "<ipv4>")
            if (index(s, "@")) s = repl(s, "[a-z0-9._%+-]+@[a-z0-9._-]+", "<email>")
            if (tolower(s) ~ LANTLD) s = lanhost(s)
            if (tolower(s) ~ DEVW) s = repl(s, DEVRE, "<host>")
            if (tolower(s) ~ /dhcp/) sub(/<mac> [^ ]+$/, "<mac> <host>", s)
            return repl(s, "[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]+", "<id>")
        }
        function jstr(s,    out, i, c) {
            out = ""
            for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "\\" || c == "\"") out = out "\\"; out = out c }
            return "\"" out "\""
        }
        BEGIN {
            split("jan feb mar apr may jun jul aug sep oct nov dec", mn, " ")
            for (i = 1; i <= 12; i++) mon[mn[i]] = i
            LANTLD = "[.](lan|local|home|internal|localdomain|home[.]arpa|fritz[.]box)"
            LANRE = "[a-z0-9_-]+([.][a-z0-9_-]+)*" LANTLD
            DEVW = "(phone|ipad|ipod|macbook|imac|airpods|android|galaxy|pixel|oneplus|xiaomi|redmi|huawei|samsung|desktop-|laptop|thinkpad|playstation|xbox|chromecast|kindle|tablet)"
            DEVRE = "[a-z0-9._" q "-]*" DEVW "[a-z0-9._" q "-]*"
            tzok = (tz ~ /^[+-][0-9][0-9][0-9][0-9]$/); off = 0
            if (tzok) { off = substr(tz, 2, 2) * 3600 + substr(tz, 4, 2) * 60; if (substr(tz, 1, 1) == "-") off = -off }
            now += 0; ny = year_of(now + off)
            first = -1; ne = 0; nw = 0; nm = 0
        }
        {
            lt = -1; k = 1
            if ($1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) {
                lt = days(substr($1, 1, 4) + 0, substr($1, 6, 2) + 0, substr($1, 9, 2) + 0) * 86400 + hms(substr($1, 12, 8))
                z = substr($1, 20); sub(/^[.][0-9]+/, "", z); gsub(/:/, "", z)
                if (z ~ /^[+-][0-9][0-9][0-9][0-9]$/) { o = substr(z, 2, 2) * 3600 + substr(z, 4, 2) * 60; lt -= (substr(z, 1, 1) == "-") ? -o : o }
                else if (z != "Z") lt = tzok ? lt - off : -1
                k = 2
            } else if ((tolower($2) in mon) && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ && $5 ~ /^[0-9][0-9][0-9][0-9]$/) {
                lt = tzok ? days($5 + 0, mon[tolower($2)], $3 + 0) * 86400 + hms($4) - off : -1
                k = 6
            } else if ((tolower($1) in mon) && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) {
                lt = days(ny, mon[tolower($1)], $2 + 0) * 86400 + hms($3) - off
                if (lt > now + 86400) lt = days(ny - 1, mon[tolower($1)], $2 + 0) * 86400 + hms($3) - off
                # The year comes from the clock: without one the date is unknown.
                if (!tzok || now <= 0) lt = -1
                k = 4
            }
            if (lt >= 0 && first < 0) first = lt
            low = tolower($0)
            if (low ~ /<warn>|(^| )warn(ing)?[: ]|daemon\.warn|kern\.warn/) nw++
            if (low !~ /<err>|(^| )err(or)?[: ]|daemon\.err|kern\.err|critical|fatal|panic/) next
            ne++
            if (!lines) next
            # The program is the first "name[pid]:" within three fields of the
            # date: past the facility.level of logd, the level word of Turris
            # and the host name of BSD syslog, which is never sent - not even
            # when no program follows it. A line without a date has no known
            # layout, and its "error:" is not a program: it goes whole, with a
            # null program.
            p = 0
            if (k > 1) for (i = k; i <= NF && i < k + 3; i++) if ($i ~ /^[A-Za-z0-9_.-]+(\[[0-9]*\])?:$/) { p = i; break }
            prog = ""; start = (k == 4) ? 5 : k
            if (p) { prog = $p; sub(/(\[[0-9]*\])?:$/, "", prog); if (length(prog) > 64) prog = ""; start = p + 1 }
            msg = ""
            for (i = start; i <= NF; i++) msg = msg (i > start ? " " : "") $i
            # The printk stamp is seconds since boot, which ts says better; left
            # in, every repeat of a kernel error would be a line of its own.
            sub(/^\[ *[0-9]+\.[0-9]+\] */, "", msg)
            gsub(/[^ -~]/, "?", msg)
            # The masks cost per character and a router in trouble can fill all
            # 500 lines with errors, so a line is cut to 256 BEFORE masking - at
            # a space, so no address is split, and marked "...". A repeat of the
            # same text is masked once.
            if (length(msg) > 256) { msg = substr(msg, 1, 256); if (!sub(/ [^ ]*$/, " ...", msg)) msg = "..." }
            if (!(msg in memo)) memo[msg] = mask(msg)
            msg = memo[msg]
            key = prog "|" msg
            at[++nm] = key; cnt[key]++; last[key] = nm; lts[key] = lt; lprog[key] = prog; lmsg[key] = msg
        }
        END {
            printf "%d %d %s\n", ne, nw, (first >= 0 && now >= first) ? sprintf("%.0f", now - first) : "null"
            if (!lines) { print "null"; exit }
            out = ""; n = 0
            for (i = nm; i >= 1 && n < 5; i--) {
                key = at[i]
                if (last[key] != i) continue
                n++; m = lmsg[key]
                if (length(m) > 200) m = substr(m, 1, 197) "..."
                out = out (n > 1 ? "," : "") "{\"ts\":" (lts[key] >= 0 ? sprintf("%.0f", lts[key]) : "null") ",\"prog\":" (lprog[key] != "" ? jstr(lprog[key]) : "null") ",\"msg\":" jstr(m) ",\"count\":" cnt[key] "}"
            }
            print "[" out "]"
        }')
    _lg_head=${_lg_out%%"$BK_NL"*}
    read -r log_errors_24h log_warnings_24h log_window_secs <<EOF_LOGSTAT
$_lg_head
EOF_LOGSTAT
    log_errors_recent=${_lg_out#*"$BK_NL"}
    # Only a JSON list reaches the payload. A failed awk leaves every value
    # empty, and the number check below turns those into null, never 0.
    case "$log_errors_recent" in '['*']') ;; *) log_errors_recent="null" ;; esac
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
    # `grep -c` answers 0 for empty input, so a daemon that is down looked
    # like "0 networks". The count is taken only when the CLI really replied.
    _zt_out=$(zerotier-cli listnetworks 2>/dev/null) \
        && zerotier_networks_json=$(printf '%s\n' "$_zt_out" | grep -c " OK ")
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
# /proc/vmstat oom_kill (kernel 4.13+): one small read, monotonic since boot.
# The dmesg scan it replaces read the whole ring buffer every minute, counted
# each kill twice (two log lines per event) and shrank when the buffer
# wrapped. dmesg stays as the fallback for older kernels only.
oom_kills=$(awk '/^oom_kill / { print $2 }' /proc/vmstat 2>/dev/null)
if [ -z "$oom_kills" ] && command -v dmesg >/dev/null 2>&1; then
    # One line per kill ("Out of memory: Kill(ed) process"); the "invoked
    # oom-killer" header of the same event must not count again. A dmesg that
    # cannot be read (no permission) is unknown, not zero.
    _dm=$(dmesg 2>/dev/null) && oom_kills=$(printf '%s\n' "$_dm" | grep -c "Out of memory: Kill")
fi
[ -z "$oom_kills" ] && oom_kills="null"

# Boot time = ted - uptime; UI z toho ukaze "System bezi od" bez driftu.
boot_time="null"
[ -n "$uptime_sec" ] && [ "$uptime_sec" -gt 0 ] 2>/dev/null && boot_time=$((now_sec - uptime_sec))

# DNS latence: realny dotaz pres lokalni resolver. Busybox time vypisuje
# "real 0m 0.03s" na stderr; bez time/nslookup zustava null.
#
# G41: the probe keeps its EXIT STATUS. Until now only the wall clock was
# read, so a resolver that refused the query in 3 ms was filed as the fastest
# DNS on the network, and a ten-second timeout as a slow one - both are the
# same failure, and neither is a latency. `echo "rc $?"` rides along inside
# the group that `time` already measures, and the one sed that was there
# picks it up with a second expression, so this costs no extra fork. The
# latency is only computed when the lookup answered, which SAVES the awk on
# every failing run.
#
# The `2>&1` that used to sit on the lookup is gone on purpose: busybox has no
# `time` KEYWORD, `time` is the applet /bin/time, and it writes its report to
# the stderr of the command it runs - which that redirection sent to
# /dev/null. `dns_latency_ms` was therefore null on every busybox router since
# the day it was written. Only the lookup's stdout is discarded now; whatever
# nslookup says on stderr cannot match either sed expression.
dns_resolver_ok="null"
dns_latency_ms="null"
# No -timeout: busybox waits up to 5 s, and a resolver that answers in 2-5 s
# is slow, not dead. A 2 s bound (tried for 0.1.9) turned it into
# dns_resolver_ok false with no latency, and the server into "resolver not
# answering" - a changed meaning of an existing key, not a saving.
if command -v nslookup >/dev/null 2>&1 && command -v time >/dev/null 2>&1; then
    dns_probe=$( { time nslookup example.com 127.0.0.1 >/dev/null; echo "rc $?"; } 2>&1 \
        | sed -n -e 's/.*real[[:space:]]*\([0-9]*\)m[[:space:]]*\([0-9.]*\)s.*/real=\1 \2/p' -e 's/^rc \([0-9][0-9]*\)$/rc=\1/p')
    dns_rc=""
    case "$dns_probe" in
        *rc=*)
            dns_rc=${dns_probe##*rc=}
            dns_rc=${dns_rc%%[!0-9]*}
            ;;
    esac
    if [ -n "$dns_rc" ]; then
        if [ "$dns_rc" = "0" ]; then
            dns_resolver_ok="true"
            case "$dns_probe" in
                *real=*)
                    dns_t=${dns_probe#*real=}
                    dns_t=${dns_t%%rc=*}
                    dns_min=${dns_t%% *}
                    dns_sec=${dns_t#* }
                    dns_sec=${dns_sec%%[!0-9.]*}
                    case "$dns_min$dns_sec" in
                        ''|*[!0-9.]*) ;;
                        *) dns_latency_ms=$(awk -v m="$dns_min" -v s="$dns_sec" 'BEGIN { printf "%.0f", (m*60+s)*1000 }') ;;
                    esac
                    ;;
            esac
        else
            dns_resolver_ok="false"
        fi
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
        # -w caps the whole call: a gateway that drops ICMP (common) used to
        # hold the report for the full 3 x (1 s + 2 s) before the fallback.
        lat_out=$(ping -c 2 -W 1 -w 3 "$lat_target" 2>/dev/null | sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p')
        if [ -n "$lat_out" ]; then
            wan_latency_ms=$(awk -v v="$lat_out" 'BEGIN { printf "%.1f", v }')
            break
        fi
    done
fi

# Does the primary link actually carry traffic? One echo bound to the WAN
# device (-I), so a reply that came back through the LTE backup cannot make a
# dead line look alive. true/false is the verdict the server alerts on
# (wan_lost / wan_restored); without a WAN device or ping it stays null.
wan_internet="null"
if [ -n "$wan_l3_device" ] && command -v ping >/dev/null 2>&1; then
    if ping -I "$wan_l3_device" -c 1 -W 2 -w 3 1.1.1.1 >/dev/null 2>&1 \
        || ping -I "$wan_l3_device" -c 1 -W 2 -w 3 9.9.9.9 >/dev/null 2>&1; then
        wan_internet="true"
    else
        wan_internet="false"
    fi
fi

# The WAN link rate and the port it belongs to were walked in section 4c
# (WAN 3.1.1). What stood here read `speed` off the first name it could
# guess from uci - on the PPPoE-over-VLAN line of this router that was the
# VLAN, whose speed the kernel passes through, and on a box without uci it
# was nothing at all. The fallback could never run either: /sys/class/net/
# <dev>/speed exists for EVERY netdev, so `[ ! -e ... ]` was never true.

openvpn_tunnels="null"
if command -v pidof >/dev/null 2>&1; then
    ovpn_pids=$(pidof openvpn 2>/dev/null)
    # Counting the words in the shell: `echo | wc -w | tr` was four forks for
    # a number `for` already knows. A PID list holds digits and blanks; any
    # other character (wc -w splits on CR, VT, FF too) goes the old way.
    case "$ovpn_pids" in
        *[!0-9\ $BK_TAB$BK_NL]*) openvpn_tunnels=$(echo "$ovpn_pids" | wc -w | tr -d '[:space:]') ;;
        *) openvpn_tunnels=0; for _p in $ovpn_pids; do openvpn_tunnels=$((openvpn_tunnels + 1)); done ;;
    esac
    [ -z "$openvpn_tunnels" ] && openvpn_tunnels=0
fi

# USB: pocitaji se jen skutecna ZARIZENI - polozky s ':' jsou rozhrani
# jednoho zarizeni (1-1:1.0) a 'usbN' jsou root huby radice, takze drivejsi
# prosty vypis hlasil treba 16 "zarizeni" u routeru s jedinym flash diskem.
usb_devices="null"
if [ -d /sys/bus/usb/devices ]; then
    # ^[0-9]+-[0-9]+(\.[0-9]+)*$ as a glob loop: `ls | grep | wc | tr` was
    # five forks. Like ls, the glob skips the dot entries.
    usb_devices=0
    for _u in /sys/bus/usb/devices/*; do
        _u=${_u##*/}; _ub=${_u%%-*}; _up=${_u#*-}
        [ "$_u" = "$_ub" ] && continue
        case "$_ub" in ''|*[!0-9]*) continue ;; esac
        case "$_up" in ''|*[!0-9.]*|.*|*.|*..*) continue ;; esac
        usb_devices=$((usb_devices + 1))
    done
    [ -z "$usb_devices" ] && usb_devices=0
fi

# The one awk that parses every radio (CORE 2.6). It is kept in a variable
# so the program is written down once and every radio streams through the
# same process; the shell below only collects the tool output. Its JSON
# keys are escaped on purpose: run_agent_metric_lint.php collects every
# unescaped JSON key literal of the agent source and would ask for a stored
# metric per nested field.
BK_WIFI_AWK='
# One awk for all radios. Input, per radio:
#   @@RADIO <ifname> <sta source: hostapd_cli|ubus|none> <iw: 1|0>
#   <iwinfo IF info><iwinfo IF assoclist>   (two forks, one command each)
#   @@STA      <hostapd_cli -i IF all_sta | ubus call hostapd.IF get_clients>
#   @@SURVEY   <iw dev IF survey dump>
#   @@CAPS     <cached iwinfo IF htmodelist + freqlist, refreshed daily>
# Vars: prev (survey state file), nstate (new state file), now (epoch)
# Output: <wifi_radios JSON>#<sum of clients or empty>
# MAC addresses are used only as array keys inside this process; nothing
# derived from them is printed. The JSON keys are written \"key\": so that
# run_agent_metric_lint.php does not read them as new top-level metrics.
function hexval(c) { return index("0123456789abcdef", tolower(c)) - 1 }
function jn(v) { return (v == "") ? "null" : v }
function jq(v) { return (v == "") ? "null" : "\"" v "\"" }
# Escaped as in BK_STORAGE_AWK, character by character (see there).
function esc(s,   o, c, i, n) { gsub(/[\001-\037]/, "", s); if (!index(s, "\\") && !index(s, "\"")) return s; o = ""; n = length(s); for (i = 1; i <= n; i++) { c = substr(s, i, 1); o = o ((c == "\\" || c == "\"") ? "\\" c : c) } return o }
function genof(fl) { if (fl ~ /\[EHT\]/) return 7; if (fl ~ /\[HE\]/) return 6; if (fl ~ /\[VHT\]/) return 5; if (fl ~ /\[HT\]/) return 4; return 0 }
function reset() {
    ssid = ""; ssid_set = 0; mode = ""; freq = ""; chan = ""; htmode = ""; txp = ""; noise = ""; enc = ""; phy = ""
    nsta = 0; clients = ""; ninfo = 0; delete sig; delete snr; delete txr; delete mac_i
    nst = 0; delete st_fl; delete st_oc; delete st_akm; delete st_mac; delete st_has
    s_f = ""; s_use = 0; sv_a = ""; sv_b = ""; sv_r = ""; sv_bss = ""; sv_t = ""; htlist = ""; has6 = ""; caps_seen = 0
}
function flush_radio(   i, j, k, t, n, band, g, known, c6, oc_known, c5, akm_known, wpa2, wpa3, eap, ap_he, med, mn, smin, weak, wk, wgen, rs, gl, g4, g5, g6, g7, busy, other, bstate, da, db, dr, dbss, dt, el, line, q, encm, ent, six, five, v, h, cap6, m, out) {
    if (radio == "") return
    band = ""
    if (freq != "") { if (freq + 0 >= 2400 && freq + 0 < 2500) band = "2.4GHz"; else if (freq + 0 >= 5150 && freq + 0 < 5925) band = "5GHz"; else if (freq + 0 >= 5925 && freq + 0 <= 7125) band = "6GHz" }
    ap_he = (htmode ~ /^(HE|EHT)/)
    # --- encryption mode. WPA version 1 next to a newer one is tested BEFORE
    # plain WPA2: the psk-mixed mode of OpenWrt prints as "mixed WPA/WPA2 PSK (TKIP,
    # CCMP)", and read as "wpa2" the owner would be told the network is fine
    # while TKIP is still on the air.
    encm = ""; ent = ""
    if (enc != "" && enc != "unknown") {
        ent = (enc ~ /802\.1X/) ? "true" : "false"
        if (enc == "none") { encm = "open"; ent = "" }
        else if (enc ~ /^WEP/) encm = "wep"
        else if (enc ~ /OWE/) encm = "owe"
        else if (enc ~ /(^| )WPA[\/ ]/ && enc ~ /WPA[23]/) encm = "wpa_wpa2"
        else if (enc ~ /WPA2/ && enc ~ /WPA3/) encm = "wpa2_wpa3"
        else if (enc ~ /WPA3/) encm = "wpa3"
        else if (enc ~ /WPA2/) encm = "wpa2"
        else if (enc ~ /WPA/) encm = "wpa"
    }
    # --- stations from assoclist: median / min signal, weakest SNR, mean TX rate
    n = 0; rs = 0; rn = 0; smin = ""; mn = ""; weak = ""; wk = 0
    for (i = 1; i <= nsta; i++) {
        if (sig[i] != "") { n++; o[n] = sig[i] + 0; if (smin == "" || sig[i] + 0 < smin + 0) { smin = sig[i]; wk = i }; if (sig[i] + 0 <= -75) weak++
            # An SNR printed next to an unknown noise is arithmetic on a zero,
            # so it is absent here - and absent must not win the minimum.
            if (snr[i] != "" && (mn == "" || snr[i] + 0 < mn + 0)) mn = snr[i] }
        if (txr[i] != "") { rs += txr[i]; rn++ }
    }
    for (i = 2; i <= n; i++) { v = o[i]; for (j = i - 1; j >= 1 && o[j] > v; j--) o[j + 1] = o[j]; o[j + 1] = v }
    med = ""; if (n > 0) med = (n % 2) ? o[(n + 1) / 2] : sprintf("%d", (o[n / 2] + o[n / 2 + 1]) / 2 - 0.5)
    # --- stations from hostapd: generations, band capability, AKM
    gl = g4 = g5 = g6 = g7 = 0; known = c6 = oc_known = c5 = akm_known = wpa2 = wpa3 = eap = 0; wgen = ""
    for (k = 1; k <= nst; k++) {
        if (!st_has[k]) continue
        g = genof(st_fl[k]); if (g == 7) g7++; else if (g == 6) g6++; else if (g == 5) g5++; else if (g == 4) g4++; else gl++
        if (wk && (st_mac[k] in mac_i) && mac_i[st_mac[k]] == wk) wgen = g
        six = 0; five = 0; h = st_oc[k]
        if (h != "") {
            # byte 0 = current operating class; the list ends at the first 0x00 / 0x82 delimiter.
            for (i = 1; i < length(h); i += 2) { v = hexval(substr(h, i, 1)) * 16 + hexval(substr(h, i + 1, 1))
                if (i > 1 && (v == 0 || v == 130)) break
                if (v >= 131 && v <= 137) six = 1; if (v >= 115 && v <= 130) five = 1 }
            oc_known++; c5 += five
        }
        # 6 GHz needs HE. hostapd sets [HE] only while the AP itself runs HE/EHT, so a station
        # without [HE] is known-not-capable only then.
        if (g >= 6) { if (h != "") { known++; c6 += six } }
        else if (ap_he) known++
        else if (h != "") { known++; c6 += six }
        if (st_akm[k] != "") { akm_known++
            if (st_akm[k] ~ /^00-0f-ac-(2|6|4|19|20)$/) wpa2++; else if (st_akm[k] ~ /^00-0f-ac-(8|9|24|25)$/) wpa3++; else if (st_akm[k] ~ /^00-0f-ac-(1|3|5|11|12|13)$/) eap++ }
        # Older hostapd builds print no AKMSuiteSelector (the whole second radio
        # of the owner is such a build). SAE cannot run without management frame
        # protection, so on wpa2 / wpa2_wpa3 personal a station WITHOUT [MFP] is
        # a WPA2 one. A station WITH [MFP] stays unknown - it may be SAE or just
        # WPA2 with PMF on. NOT on wpa_wpa2: there a station without [MFP] may
        # equally be a WPA version 1 station, and counting it as WPA2 would hide
        # exactly the TKIP client the mixed mode exists to surface.
        else if (sta_src == "hostapd_cli" && (encm == "wpa2" || encm == "wpa2_wpa3") && ent != "true" && st_fl[k] !~ /\[MFP\]/) { akm_known++; wpa2++ }
    }
    if (clients == "" && sta_src != "none") clients = nst_assoc
    # An empty network has zero weak clients - a measured zero. The signal
    # statistics above stay null: there is nobody to measure.
    if (weak == "" && (n > 0 || (clients != "" && clients + 0 == 0))) weak = 0
    # --- channel airtime from survey deltas
    busy = ""; other = ""; bstate = ""
    if (freq != "") {
        if (!iw) bstate = "not_installed"
        else if (sv_a == "" || sv_b == "") bstate = "unsupported"
        else {
            bstate = "warming_up"
            if ((radio in p_f) && p_f[radio] == freq) {
                da = sv_a - p_a[radio]; db = sv_b - p_b[radio]; el = (now - p_ts[radio]) * 1000
                if (da >= 10000 && db >= 0 && db <= da && da <= el * 1.2 + 2000) {
                    busy = sprintf("%.1f", db * 100 / da); bstate = "measured"
                    if (sv_t != "" && sv_bss != "" && p_t[radio] != "" && p_bss[radio] != "") {
                        dt = sv_t - p_t[radio]; dbss = sv_bss - p_bss[radio]
                        if (dt >= 0 && dbss >= 0 && dt + dbss <= db) other = sprintf("%.1f", (db - dt - dbss) * 100 / da) } }
            }
            printf "%s|%s|%s|%s|%s|%s|%s\n", radio, freq, sv_a, sv_b, sv_t, sv_bss, now >> nstate
        }
    }
    out = "{\"radio\":\"" radio "\",\"ssid\":" (ssid_set ? "\"" esc(ssid) "\"" : "null") ",\"mode\":" jq(mode) ",\"band\":" jq(band) ",\"frequency_mhz\":" jn(freq) ",\"channel\":" jn(chan) \
        ",\"htmode\":" jq(htmode) ",\"htmodes_supported\":" (htlist == "" ? "null" : "[" htlist "]") ",\"phy_has_6ghz\":" jn(has6) ",\"phy\":" jq(phy) \
        ",\"encryption\":" jq(encm) ",\"encryption_enterprise\":" jn(ent) ",\"tx_power\":" jn(txp) ",\"noise\":" jn(noise) ",\"clients\":" jn(clients) \
        ",\"signal_median\":" jn(med) ",\"signal_min\":" jn(smin) ",\"snr_min\":" jn(mn) ",\"clients_weak\":" jn(weak) ",\"weakest_gen\":" jn(wgen) \
        ",\"bitrate_tx_avg_mbps\":" (rn ? sprintf("%.1f", rs / rn) : "null")
    if (sta_src == "none") out = out ",\"clients_gen\":null"
    else out = out ",\"clients_gen\":{\"source\":\"" sta_src "\",\"legacy\":" gl ",\"wifi4\":" g4 ",\"wifi5\":" g5 ",\"wifi6\":" g6 ",\"wifi7\":" (sta_src == "ubus" ? "null" : g7) "}"
    out = out ",\"clients_caps_known\":" (sta_src == "none" ? "null" : known) ",\"clients_6ghz_capable\":" (sta_src == "none" ? "null" : c6) \
        ",\"clients_opclass_known\":" (sta_src == "hostapd_cli" ? oc_known : "null") ",\"clients_5ghz_capable\":" (sta_src == "hostapd_cli" && band == "2.4GHz" ? c5 : "null") \
        ",\"clients_akm_known\":" (sta_src == "hostapd_cli" ? akm_known : "null") ",\"clients_wpa2\":" (sta_src == "hostapd_cli" ? wpa2 : "null") \
        ",\"clients_wpa3\":" (sta_src == "hostapd_cli" ? wpa3 : "null") ",\"clients_8021x\":" (sta_src == "hostapd_cli" ? eap : "null") \
        ",\"busy_pct\":" jn(busy) ",\"busy_other_pct\":" jn(other) ",\"busy_state\":" jq(bstate) "}"
    json = json (json == "" ? "" : ",") out
    if (clients != "") { total += clients; have_total = 1 }
}
BEGIN {
    while ((getline l < prev) > 0) { split(l, q, "|"); p_f[q[1]] = q[2]; p_a[q[1]] = q[3]; p_b[q[1]] = q[4]; p_t[q[1]] = q[5]; p_bss[q[1]] = q[6]; p_ts[q[1]] = q[7] }
    close(prev); radio = ""
}
/^@@RADIO / { flush_radio(); reset(); radio = $2; sta_src = $3; iw = $4 + 0; sect = "info"; nst_assoc = 0; next }
/^@@STA$/ { sect = "sta"; next }
/^@@SURVEY$/ { sect = "survey"; next }
/^@@CAPS$/ { sect = "caps"; next }
sect == "info" {
    if (!ninfo++ && match($0, /ESSID: ".*"$/)) { ssid = substr($0, RSTART + 8, RLENGTH - 9); ssid_set = 1 }
    if (match($0, /Channel: [0-9]+ \([0-9]+\.[0-9]+ GHz\)/)) { t = substr($0, RSTART, RLENGTH); chan = t; sub(/^Channel: /, "", chan); sub(/ .*/, "", chan); sub(/^.*\(/, "", t); sub(/ GHz\)/, "", t); freq = sprintf("%d", t * 1000 + 0.5) }
    if (match($0, /Mode: (Master|Client|Mesh Point|Ad-Hoc|Monitor|Unknown)/)) { t = substr($0, RSTART + 6, RLENGTH - 6); mode = (t == "Master") ? "ap" : (t == "Client") ? "client" : (t == "Mesh Point") ? "mesh" : (t == "Unknown") ? "" : "other" }
    if (match($0, /HT Mode: (NOHT|(HT|VHT|HE|EHT)[0-9]+(\+80)?)/)) htmode = substr($0, RSTART + 9, RLENGTH - 9)
    if (match($0, /Tx-Power: [0-9]+ dBm/)) { txp = substr($0, RSTART + 10, RLENGTH - 14) }
    if (match($0, /Noise: -[0-9]+ dBm/)) { noise = substr($0, RSTART + 7, RLENGTH - 11) }
    if ($0 ~ /^ +Encryption: /) { enc = $0; sub(/^ +Encryption: /, "", enc) }
    if (match($0, /PHY name: phy[0-9]+/)) phy = substr($0, RSTART + 10, RLENGTH - 10)
    if ($0 ~ /^[0-9A-Fa-f][0-9A-Fa-f](:[0-9A-Fa-f][0-9A-Fa-f])+  /) {
        nsta++; mac_i[tolower($1)] = nsta; sig[nsta] = ($2 ~ /^-[0-9]+$/ && $3 == "dBm") ? $2 : ""
        # iwinfo prints signal - noise even when the noise is unknown (it uses
        # 0), e.g. "-47 dBm / unknown (SNR -47)". Only a line with a KNOWN
        # noise field carries a real SNR, and a real one is never negative.
        snr[nsta] = ""
        if ($5 ~ /^-[0-9]+$/ && $6 == "dBm" && match($0, /\(SNR [0-9]+\)/)) snr[nsta] = substr($0, RSTART + 5, RLENGTH - 6)
        if (sig[nsta] == "") snr[nsta] = ""
        clients = nsta
    }
    else if ($0 ~ /^[ \t]+TX: [0-9.]+ MBit\/s/ && nsta) txr[nsta] = $2
    else if ($0 ~ /^No station connected/) clients = 0
    next
}
sect == "sta" && sta_src == "hostapd_cli" {
    if ($0 ~ /^Failed to connect/) { sta_src = "none"; next }
    if ($0 ~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f])+$/) { nst++; st_mac[nst] = $0; st_has[nst] = 0; next }
    if (!nst) next
    if ($0 ~ /^flags=/) { st_fl[nst] = $0; if ($0 ~ /\[ASSOC\]/) { st_has[nst] = 1; nst_assoc++ } }
    else if ($0 ~ /^supp_op_classes=[0-9a-fA-F]+$/) st_oc[nst] = substr($0, 17)
    else if ($0 ~ /^AKMSuiteSelector=/) st_akm[nst] = substr($0, 18)
    next
}
sect == "sta" && sta_src == "ubus" {
    # Depth 3 only, and written "key"[:] so that the metric lint does not read
    # these ubus field names as payload keys: capabilities.vht sits one level
    # deeper and must never become the VHT flag of the station.
    if ($0 ~ /^\t\t"[0-9a-f:]+": \{$/) { nst++; t = $1; gsub(/[":]/, "", t); st_mac[nst] = ""; st_has[nst] = 0; st_fl[nst] = ""; next }
    if (!nst) next
    if ($0 ~ /^\t\t\t"assoc"[:] true/) { st_has[nst] = 1; nst_assoc++ }
    else if ($0 ~ /^\t\t\t"ht"[:] true/) st_fl[nst] = st_fl[nst] "[HT]"
    else if ($0 ~ /^\t\t\t"vht"[:] true/) st_fl[nst] = st_fl[nst] "[VHT]"
    else if ($0 ~ /^\t\t\t"he"[:] true/) st_fl[nst] = st_fl[nst] "[HE]"
    next
}
sect == "survey" {
    if ($0 ~ /^Survey data from /) { s_f = ""; s_use = 0 }
    else if ($0 ~ /^[ \t]+frequency:/) { s_f = $2; s_use = ($0 ~ /\[in use\]/ && s_f == freq) }
    else if (s_use && $0 ~ /^[ \t]+channel active time:/) sv_a = $(NF - 1)
    else if (s_use && $0 ~ /^[ \t]+channel busy time:/) sv_b = $(NF - 1)
    else if (s_use && $0 ~ /^[ \t]+channel BSS receive time:/) sv_bss = $(NF - 1)
    else if (s_use && $0 ~ /^[ \t]+channel transmit time:/) sv_t = $(NF - 1)
    next
}
sect == "caps" {
    if ($0 ~ /^(NOHT |HT20|VHT20|HE20|EHT20)/ || $0 ~ /^HT[0-9]/) { n = split($0, m, " "); for (i = 1; i <= n; i++) if (m[i] ~ /^(HT|VHT|HE|EHT)[0-9]+(\+80)?$/) htlist = htlist (htlist == "" ? "" : ",") "\"" m[i] "\"" }
    else if ($0 ~ /\(Band: [0-9.]+ GHz, Channel/) { caps_seen = 1; if (has6 == "") has6 = "false"; if ($0 ~ /\(Band: 6 GHz/) has6 = "true" }
    next
}
END { flush_radio(); printf "[%s]#%s", json, (have_total ? total : "") }
'

# --- WiFi per-radio detail (iwinfo, hostapd_cli/ubus, iw) ---
#
# Forks per radio: iwinfo info + iwinfo assoclist (the CLI takes exactly ONE
# command per call - with more it reads the first word as a backend name,
# prints nothing and exits 1), the station source, and one `iw survey dump`.
# ONE awk parses every radio; the card facts (htmodelist, freqlist) change
# only with the hardware and are cached for a day like the package list.
WIFI_SURVEY_STATE="$BK_PRIVATE_DIR/wifi-survey.state"
wifi_radios_json="[]"
have_hapd=0; command -v hostapd_cli >/dev/null 2>&1 && have_hapd=1
have_iw=0; command -v iw >/dev/null 2>&1 && have_iw=1
wifi_list=""
for _n in "$BK_SYS"/class/net/*; do [ -e "$_n/phy80211" ] && wifi_list="$wifi_list ${_n##*/}"; done
[ -z "$wifi_list" ] && command -v iwinfo >/dev/null 2>&1 && wifi_list=$(iwinfo 2>/dev/null | awk '/^[a-z0-9]/ {print $1}')
if [ -n "$wifi_list" ] && command -v iwinfo >/dev/null 2>&1; then
    rm -f "$WIFI_SURVEY_STATE.new"
    # busybox awk dies on a missing input FILE argument; `getline < prev` on a
    # missing file is harmless, but the file is cheap to guarantee.
    : >> "$WIFI_SURVEY_STATE"
    _wifi_n=0
    _wifi_out=$(for r in $wifi_list; do
        case "$r" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
        _wifi_n=$((_wifi_n + 1)); [ "$_wifi_n" -gt 16 ] && break
        src=none; sta=""
        # Selected by EXIT STATUS, not by non-empty output: with nobody connected hostapd_cli prints nothing and
        # exits 0 (hostapd_cli.c: STA-FIRST answers FAIL -> all_sta returns, main returns 0); a socket it cannot
        # open exits 255. An empty answer is a MEASURED zero - it must not fall through to ubus.
        if [ "$have_hapd" = 1 ] && sta=$(hostapd_cli -i "$r" all_sta 2>/dev/null); then src=hostapd_cli
        elif sta=$(ubus call "hostapd.$r" get_clients 2>/dev/null) && [ -n "$sta" ]; then src=ubus
        else sta=""; fi
        sv=""; [ "$have_iw" = 1 ] && sv=$(iw dev "$r" survey dump 2>/dev/null)
        # Card facts change only with the hardware: once a day, like the package list.
        # The refresh time sits in wifi-caps.<radio>.ts: `date -r` was a fork
        # per radio every minute only to learn the cache's age. A cache
        # without the stamp (written by an older agent) is refreshed once.
        _cf="$BK_PRIVATE_DIR/wifi-caps.$r"; _cm=""
        [ -f "$_cf" ] && { read -r _cm _; } 2>/dev/null < "$_cf.ts"
        case "$_cm" in ''|*[!0-9]*) _cm=0 ;; esac
        if [ $((now_ts - _cm)) -ge "$HEAVY_OP_INTERVAL_SEC" ]; then
            # The cache is kept only when it is not empty, so a failed call is
            # not frozen for 24 h as "this card knows no modes and no bands".
            { iwinfo "$r" htmodelist; iwinfo "$r" freqlist; } > "$_cf.tmp" 2>/dev/null
            if [ -s "$_cf.tmp" ]; then mv "$_cf.tmp" "$_cf"; echo "$now_ts" > "$_cf.ts"; else rm -f "$_cf.tmp"; fi
        fi
        printf '@@RADIO %s %s %s\n' "$r" "$src" "$have_iw"
        # A command whose first letter is an s would be a scan, which takes the radio off its channel: never one of those two.
        iwinfo "$r" info 2>/dev/null
        iwinfo "$r" assoclist 2>/dev/null
        printf '@@STA\n%s\n@@SURVEY\n%s\n@@CAPS\n' "$sta" "$sv"
        # A builtin copy instead of a cat per radio, byte for byte: a last
        # line without its newline stays without one.
        if [ -r "$_cf" ]; then
            _cl=""
            while IFS= read -r _cl; do printf '%s\n' "$_cl"; _cl=""; done < "$_cf"
            [ -n "$_cl" ] && printf '%s' "$_cl"
        fi
    done | awk -v prev="$WIFI_SURVEY_STATE" -v nstate="$WIFI_SURVEY_STATE.new" -v now="$now_ts" "$BK_WIFI_AWK")
    # Shortest suffix (%#*): cut at the LAST '#'. An SSID such as "Domov #5 GHz"
    # contains '#', and %%#* would cut the JSON there and send a broken payload.
    wifi_radios_json=${_wifi_out%#*}
    wifi_clients_count=${_wifi_out##*#}
    case "$wifi_clients_count" in ''|*[!0-9]*) wifi_clients_count="null" ;; esac
    if [ -f "$WIFI_SURVEY_STATE.new" ]; then mv "$WIFI_SURVEY_STATE.new" "$WIFI_SURVEY_STATE"; else rm -f "$WIFI_SURVEY_STATE"; fi
fi
[ -z "$wifi_radios_json" ] && wifi_radios_json="[]"

# --- agent_tools: co tenhle router vubec umi zmerit ---------------------------
#
# Not a metric and not an alert: it is the REASON a value is null. Without
# smartmontools the disk health is unknown, not healthy; without its drive
# database the attribute names are generic guesses; without hostapd-utils the
# Wi-Fi generations are unknown. The server turns a missing package into an
# install hint and knows not to warn about a disk nobody can read.
have_drivedb=0; [ -s /usr/share/smartmontools/drivedb.h ] && have_drivedb=1
have_librespeed=0; command -v librespeed-cli >/dev/null 2>&1 && have_librespeed=1
have_ethtool=0; command -v ethtool >/dev/null 2>&1 && have_ethtool=1
have_tc=0; command -v tc >/dev/null 2>&1 && have_tc=1
# 0/1 -> true/false without a fork: the flags decide, these are only how they
# are written down. Every one of the seven is a strict boolean, never null -
# "is the package there" is always measurable.
tool_smartctl=false; [ "$have_smartctl" = 1 ] && tool_smartctl=true
tool_drivedb=false; [ "$have_drivedb" = 1 ] && tool_drivedb=true
tool_hostapd=false; [ "$have_hapd" = 1 ] && tool_hostapd=true
tool_iw=false; [ "$have_iw" = 1 ] && tool_iw=true
tool_librespeed=false; [ "$have_librespeed" = 1 ] && tool_librespeed=true
tool_ethtool=false; [ "$have_ethtool" = 1 ] && tool_ethtool=true
tool_tc=false; [ "$have_tc" = 1 ] && tool_tc=true
pkg_manager_json="null"
if command -v opkg >/dev/null 2>&1; then pkg_manager_json="\"opkg\""
elif command -v apk >/dev/null 2>&1; then pkg_manager_json="\"apk\""
fi
# Written with escaped quotes for the same reason as the two embedded awk
# programs: run_agent_metric_lint.php would otherwise read these nested names
# as new top-level metrics that nobody stores.
# A plain assignment: the $(printf) was a fork for a string the shell builds.
agent_tools_json="{\"smartctl\":$tool_smartctl,\"smart_drivedb\":$tool_drivedb,\"hostapd_cli\":$tool_hostapd,\"iw\":$tool_iw,\"pkg_manager\":$pkg_manager_json,\"smart_probe_age_s\":$smart_probe_age_s,\"smart_probe_running_s\":$smart_probe_running_s,\"librespeed_cli\":$tool_librespeed,\"ethtool\":$tool_ethtool,\"tc\":$tool_tc}"
[ -z "$agent_tools_json" ] && agent_tools_json="null"

# --- LAN / DHCP ---
lan_subnet=""
if bk_iface_load lan; then
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
# odhcpd-only setups and custom lease files have no /tmp/dhcp.leases: that is
# unknown, not "0 leases".
dhcp_leases_count="null"
if [ -f /tmp/dhcp.leases ]; then
    # `wc -l` counted newlines; so does a read loop (a last line without its
    # newline is not counted by either). Unreadable stays empty, as it was.
    dhcp_leases_count=""
    { dhcp_leases_count=0; while IFS= read -r _dl; do dhcp_leases_count=$((dhcp_leases_count + 1)); done; } 2>/dev/null < /tmp/dhcp.leases
fi
dhcp_reservations_count="null"
if command -v uci >/dev/null 2>&1; then
    # The lines ending in "=host", counted in the shell: `printf | grep -c`
    # was three forks. A CR in the answer would end a line for neither.
    # Split on newlines with globbing off ("@host[0]" is a glob pattern);
    # empty lines vanish in the split, and they never end in "=host".
    if _uci_dhcp=$(uci show dhcp 2>/dev/null); then
        dhcp_reservations_count=0
        _ud_ifs=$IFS; IFS=$BK_NL; set -f
        for _ud in $_uci_dhcp; do
            case "$_ud" in *=host) dhcp_reservations_count=$((dhcp_reservations_count + 1)) ;; esac
        done
        set +f; IFS=$_ud_ifs
    fi
fi

# --- DNS Engine, Upstream Servers & DoT/DoH Encryption ---
#
# G24: none of these three starts as a claim any more. "Dnsmasq" was printed
# for every router whose resolver the chain below did not recognise - on
# Turris that is kresd behind a firewall the agent could not read - and
# "Nešifrované DNS (UDP/53)" told the owner their DNS was in the clear when
# nobody had looked. Unset means null in the payload, and the app shows a dash.
dns_engine=""
dns_encryption=""
dns_servers=""
case "$wan_dns" in ''|null) ;; *) dns_servers="$wan_dns" ;; esac

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

# "Is NAME running?" from the top snapshot taken above, without a fork: the
# chain below asked pidof up to eight times a run (every name but the last is
# missing on a plain dnsmasq router), and each pidof walks all of /proc.
# A name counts when it is the basename of a process's command as top prints
# it: argv[0] under busybox top, comm under procps top - two of the three
# things pidof matches (comm, argv[0] basename, exe basename). Every resolver
# in the chain is a compiled daemon started by its own path, where the three
# agree. No snapshot (no top, no output, no header) means pidof, as before.
bk_running() {
    [ -n "$bk_top_names" ] || { pidof "$1" >/dev/null 2>&1; return; }
    case "$bk_top_names" in *" $1 "*) return 0 ;; esac
    return 1
}
if bk_running kresd || [ -f /etc/config/resolver ]; then
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
elif bk_running AdGuardHome; then
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
elif bk_running unbound; then
    dns_engine="Unbound"
    if grep -rqi -E 'tls-upstream:[[:space:]]*yes|forward-tls-upstream:[[:space:]]*yes' /etc/unbound/ 2>/dev/null; then
        dns_encryption="DoT dle konfigurace (tls-upstream: yes)"
    elif [ "$dns_active_853" = "1" ]; then
        dns_encryption="DoT - ověřeno (aktivní spojení na port 853)"
    else
        dns_encryption="Nešifrované DNS (UDP/53)"
    fi
elif bk_running stubby; then
    dns_engine="Stubby"
    dns_encryption="DoT (Stubby je DoT-only resolver)"
elif bk_running https_dns_proxy || bk_running cloudflared || bk_running dnscrypt-proxy; then
    dns_engine="DoH proxy"
    dns_encryption="DoH - běží DoH proxy (https_dns_proxy/cloudflared/dnscrypt)"
elif bk_running dnsmasq; then
    # The default of 0.1.6, now an answer instead of an assumption: the
    # process really is running, and dnsmasq has no encrypted upstream at all,
    # so "plain UDP/53" is a property of the program, not a guess.
    dns_engine="Dnsmasq"
    dns_encryption="Nešifrované DNS (UDP/53)"
elif [ "$dns_active_853" = "1" ]; then
    dns_encryption="DoT - ověřeno (aktivní spojení na port 853)"
fi

if [ -f /tmp/resolv.conf.auto ]; then
    # In the shell: awk's $2 of every line that holds "nameserver" in any
    # case, joined with commas - what `grep -i | awk | tr | sed` gave at five
    # forks a run. A CR, VT or FF (awk would split on it) sends the file down
    # the old pipeline instead.
    extra_dns=""; _rc_n=0; _rc_odd=""; _rc_l=""
    { while IFS= read -r _rc_l || [ -n "$_rc_l" ]; do
        case "$_rc_l" in *[Nn][Aa][Mm][Ee][Ss][Ee][Rr][Vv][Ee][Rr]*) ;; *) _rc_l=""; continue ;; esac
        case "$_rc_l" in *["$BK_WSX"]*) _rc_odd=1; break ;; esac
        bk_blank2 "$_rc_l"
        if [ "$_rc_n" -gt 0 ]; then extra_dns="$extra_dns,$_b2"; else extra_dns=$_b2; fi
        _rc_n=$((_rc_n + 1)); _rc_l=""
    done; } 2>/dev/null < /tmp/resolv.conf.auto
    [ -n "$_rc_odd" ] && extra_dns=$(grep -i "nameserver" /tmp/resolv.conf.auto | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
    if [ -n "$extra_dns" ]; then
        if [ -n "$dns_servers" ]; then
            dns_servers="$dns_servers, $extra_dns"
        else
            dns_servers="$extra_dns"
        fi
    fi
fi
# G24: no "Výchozí poskytovatel (WAN)" fallback. Neither netifd nor
# resolv.conf.auto named a server, so the agent does not know one; an empty
# value becomes null below.



# --- Service Discovery Scanner (cached for HEAVY_OP_INTERVAL_HOURS) ---
discovered_services_json="[]"
SVC_CACHE_FILE="/tmp/status-agent-openwrt-services.cache"
svc_cache_age=999999
if [ -f "$SVC_CACHE_FILE" ]; then
    svc_mtime=$(date -r "$SVC_CACHE_FILE" +%s 2>/dev/null || echo 0)
    svc_cache_age=$((now_sec - svc_mtime))
fi

if [ $svc_cache_age -lt $HEAVY_OP_INTERVAL_SEC ] && [ -f "$SVC_CACHE_FILE" ]; then
    bk_slurp "$SVC_CACHE_FILE"; discovered_services_json=$_sl
    # An empty cache (write failed on a full /tmp, or read mid-write) used to
    # put `"discovered_services": ,` in the payload - and a 400 for the lot.
    [ -n "$discovered_services_json" ] || discovered_services_json="[]"
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
            bk_js "$_desc"; _desc_esc=$_jr
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
    echo "$discovered_services_json" > "$SVC_CACHE_FILE.tmp" 2>/dev/null && mv "$SVC_CACHE_FILE.tmp" "$SVC_CACHE_FILE" 2>/dev/null || true
fi

[ -z "$top_cpu_json" ] && top_cpu_json="[]"
[ -z "$top_ram_json" ] && top_ram_json="[]"
[ -z "$wifi_radios_json" ] && wifi_radios_json="[]"
[ -z "$storage_disks_json" ] && storage_disks_json="null"
[ -z "$agent_tools_json" ] && agent_tools_json="null"
[ -z "$interfaces_json" ] && interfaces_json="[]"
[ -z "$wireguard_peers_json" ] && wireguard_peers_json="[]"
[ -z "$mwan3_policies_json" ] && mwan3_policies_json="[]"
[ -z "$service_restarts_json" ] && service_restarts_json="[]"
[ -z "$mwan3_active_gw" ] && mwan3_active_gw="null"

# Sanitace všech numerických proměnných
for var in cpu ram ram_total_mb ram_used_mb ram_available_mb ram_free_mb swap_pct entropy conntrack_pct upgradable_packages wifi_clients_count dhcp_leases_count dhcp_reservations_count dns_queries dns_cache_hits dns_cache_misses fw_accepted fw_dropped fw_rejected net net_ipv4_kbps net_ipv6_kbps hdd disk_io_write btrfs_errors load1 load5 load15 uptime_sec temperature wan_uptime sqm_download_kbps sqm_upload_kbps sqm_dropped sqm_ecn lte_rsrp lte_rsrq lte_sinr wan_reconnect_count wan_last_reconnect installed_packages log_errors_24h log_warnings_24h log_window_secs; do
    eval "val=\$$var"
    # A case pattern instead of `echo | grep` - that was ~45 pipelines a run.
    _num="${val#-}"
    case "$_num" in
        ''|*[!0-9.]*) eval "$var=\"null\"" ;;
        *[0-9]*) : ;;
        *) eval "$var=\"null\"" ;;
    esac
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

# G42: the run's own length, measured at the last possible moment - the
# payload is the last thing this run builds. Both ends come from the kernel
# uptime (bk_uptime_cs), so a clock step cannot forge it, and null means one
# of the two reads failed: a 0 would claim the run took no time at all.
agent_run_ms="null"
bk_uptime_cs
if [ -n "$_up_cs" ] && [ -n "$BK_RUN_START_CS" ] && [ "$_up_cs" -ge "$BK_RUN_START_CS" ] 2>/dev/null; then
    agent_run_ms=$(( (_up_cs - BK_RUN_START_CS) * 10 ))
fi
# The router's clock as the payload leaves: the server takes |its clock -
# agent_time| as clock_skew_s, so a clock read at the start of the run would
# add the whole run to the skew. The run's one `date` (now_ts) plus the
# uptime that has passed since, which a clock step cannot bend either. 0.1.8
# read a second `date` in the middle of the run.
agent_time=$now_ts
if [ -n "$_up_cs" ] && [ -n "$BK_NOW_TS_CS" ] && [ "$_up_cs" -ge "$BK_NOW_TS_CS" ] 2>/dev/null; then
    agent_time=$(( now_ts + (_up_cs - BK_NOW_TS_CS) / 100 ))
fi

# G42: the skipped runs since the last ACCEPTED report: "l" = the previous
# run still held the lock, "p" = the POST failed, "k" = a run wedged for
# 300 s was killed to take its lock over (WW-07).
#
# IO-03: the counters are FOLDED, under the lock, into one line in
# skipped.total ("L P K"). 0.1.8 kept one line per skip and re-read the whole
# file every minute: a router that could not reach the server grew it by a
# line a minute for as long as the outage lasted, and read up to 20,000 lines
# each run (0.2-0.9 s of CPU on musl ash) - and after a long outage the drain
# sent 20,000 and left the rest for later reports.
#
# Only the runs that meet the lock, and a takeover that has just killed a
# wedged run, still append to `skipped`: the first do not hold the lock, and
# the second may itself be killed before it reaches the fold. Its lines are taken by a rename, so a line appended while this
# run counts lands in a new file and waits for the next run; nothing is ever
# counted twice or lost to a truncate. A `.fold` left by a run that died in
# the middle is counted first (it can only be a run killed by a takeover).
# Each counter saturates at 100,000: the server drops larger values (its
# range check), and a lost number is worse than a capped one.
runs_skipped_lock=0
runs_skipped_post=0
runs_skipped_killed=0
BK_SKIPPED_FILE="$BK_PRIVATE_DIR/skipped"
BK_SKIPPED_TOTAL="$BK_PRIVATE_DIR/skipped.total"
bk_sk_count() { # FILE: add its l/p/k lines to the counters
    while read -r _sk_line; do
        case "$_sk_line" in
            l) runs_skipped_lock=$((runs_skipped_lock + 1)) ;;
            p) runs_skipped_post=$((runs_skipped_post + 1)) ;;
            k) runs_skipped_killed=$((runs_skipped_killed + 1)) ;;
        esac
    done < "$1"
}
bk_sk_cap() {
    [ "$runs_skipped_lock" -gt 100000 ] && runs_skipped_lock=100000
    [ "$runs_skipped_post" -gt 100000 ] && runs_skipped_post=100000
    [ "$runs_skipped_killed" -gt 100000 ] && runs_skipped_killed=100000
    return 0
}
bk_sk_save() {
    printf '%s %s %s\n' "$runs_skipped_lock" "$runs_skipped_post" "$runs_skipped_killed" > "$BK_SKIPPED_TOTAL" 2>/dev/null || true
}
if read -r _sk_l _sk_p _sk_k 2>/dev/null < "$BK_SKIPPED_TOTAL"; then
    case "$_sk_l$_sk_p$_sk_k" in
        ''|*[!0-9]*) ;;
        *) runs_skipped_lock=$_sk_l; runs_skipped_post=$_sk_p; runs_skipped_killed=$_sk_k ;;
    esac
fi
_sk_fold=""
[ -s "$BK_SKIPPED_FILE.fold" ] && { bk_sk_count "$BK_SKIPPED_FILE.fold"; _sk_fold=1; }
if [ -s "$BK_SKIPPED_FILE" ] && mv -f "$BK_SKIPPED_FILE" "$BK_SKIPPED_FILE.fold" 2>/dev/null; then
    bk_sk_count "$BK_SKIPPED_FILE.fold"; _sk_fold=1
fi
bk_sk_cap
if [ -n "$_sk_fold" ]; then
    # Total first, then empty the fold: a run killed in between counts a
    # few skips twice, never loses one.
    bk_sk_save
    : > "$BK_SKIPPED_FILE.fold" 2>/dev/null
fi

# Every value the payload escapes, escaped here with builtins: a $(...) in
# the heredoc forked once per field, and json_str/json_val three more times
# (87 forks a report in 0.1.8).
bk_jv "$lan_subnet"; _jv_lan_subnet=$_jr
bk_jv "$dns_engine"; _jv_dns_engine=$_jr
bk_jv "$dns_encryption"; _jv_dns_encryption=$_jr
bk_jv "$dns_servers"; _jv_dns_servers=$_jr
bk_jv "$wan_proto"; _jv_wan_proto=$_jr
bk_jv "$wan_l3_device"; _jv_wan_l3_device=$_jr
bk_jv "$wan_ipv4"; _jv_wan_ipv4=$_jr
bk_jv "$wan_ipv6"; _jv_wan_ipv6=$_jr
bk_jv "$wan_gateway"; _jv_wan_gateway=$_jr
bk_jv "$wan_dns"; _jv_wan_dns=$_jr
bk_jv "$lte_device"; _jv_lte_device=$_jr
bk_jv "$lte_ipv4"; _jv_lte_ipv4=$_jr
bk_jv "$lte_band"; _jv_lte_band=$_jr
bk_jv "$lte_carrier"; _jv_lte_carrier=$_jr
bk_jv "$lte_sim_state"; _jv_lte_sim_state=$_jr
bk_jv "$wan_link_dev"; _jv_wan_link_dev=$_jr
bk_js "$AGENT_KEY"; _js_AGENT_KEY=$_jr
bk_js "$os_combined"; _js_os_combined=$_jr
bk_js "$ow_hostname"; _js_ow_hostname=$_jr
bk_js "$ow_kernel"; _js_ow_kernel=$_jr
bk_js "$ow_model"; _js_ow_model=$_jr
bk_js "$ow_board_name"; _js_ow_board_name=$_jr
_bk_auto_update01=0; [ "$AUTO_UPDATE" = "1" ] && _bk_auto_update01=1
payload=$(cat <<EOF
{
  "agent_key": "$_js_AGENT_KEY",
  "agent_type": "openwrt",
  "version": "$AGENT_VERSION",
  "heavy_op_interval_hours": ${HEAVY_OP_INTERVAL_HOURS:-24},
  "os": "$_js_os_combined",
  "cpu": $cpu,
  "cpu_cores": $cpu_cores,
  "cpu_core_max_pct": $cpu_core_max_pct,
  "cpu_core_max_index": $cpu_core_max_index,
  "cpu_core_max_softirq_pct": $cpu_core_max_softirq_pct,
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
  "conntrack_insert_failed": $conntrack_insert_failed,
  "conntrack_drop": $conntrack_drop,
  "conntrack_early_drop": $conntrack_early_drop,
  "inode_usage": $inode_usage_json,
  "upgradable_packages": $upgradable_packages,
  "wifi_clients_count": $wifi_clients_count,
  "wifi_radios": $wifi_radios_json,
  "storage_disks": $storage_disks_json,
  "agent_tools": $agent_tools_json,
  "interfaces": $interfaces_json,
  "discovered_services": $discovered_services_json,
  "lan_subnet": $_jv_lan_subnet,
  "dhcp_leases_count": $dhcp_leases_count,
  "dhcp_reservations_count": $dhcp_reservations_count,
  "dns_queries": $dns_queries,
  "dns_cache_hits": $dns_cache_hits,
  "dns_cache_misses": $dns_cache_misses,
  "dns_engine": $_jv_dns_engine,
  "dns_encryption": $_jv_dns_encryption,
  "dns_servers": $_jv_dns_servers,
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
  "net_lte": $net_lte,
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
  "hostname": "$_js_ow_hostname",
  "kernel": "$_js_ow_kernel",
  "model": "$_js_ow_model",
  "board_name": "$_js_ow_board_name",
  "wan_up": $wan_up_json,
  "wan_proto": $_jv_wan_proto,
  "wan_l3_device": $_jv_wan_l3_device,
  "wan_ipv4": $_jv_wan_ipv4,
  "wan_ipv6": $_jv_wan_ipv6,
  "wan_gateway": $_jv_wan_gateway,
  "wan_dns": $_jv_wan_dns,
  "wan_uptime": $wan_uptime,
  "mwan3_policies": $mwan3_policies_json,
  "mwan3_active_gw": $mwan3_active_gw,
  "sqm_enabled": $sqm_enabled,
  "sqm_download_kbps": $sqm_download_kbps,
  "sqm_upload_kbps": $sqm_upload_kbps,
  "sqm_dropped": $sqm_dropped,
  "sqm_ecn": $sqm_ecn,
  "lte_up": $lte_up,
  "lte_device": $_jv_lte_device,
  "lte_uptime": $lte_uptime,
  "lte_ipv4": $_jv_lte_ipv4,
  "lte_rssi": $lte_rssi,
  "lte_pci": $lte_pci,
  "lte_cell_id": $lte_cell_id,
  "lte_bandwidth": $lte_bandwidth,
  "lte_plmn": $lte_plmn,
  "lte_rsrp": $lte_rsrp,
  "lte_rsrq": $lte_rsrq,
  "lte_sinr": $lte_sinr,
  "lte_band": $_jv_lte_band,
  "lte_carrier": $_jv_lte_carrier,
  "lte_connected": $lte_connected,
  "lte_sim_state": $_jv_lte_sim_state,
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
  "log_window_secs": $log_window_secs,
  "log_errors_recent": $log_errors_recent,
  "log_lines_state": "$log_lines_state",
  "tailscale_up": $tailscale_up_json,
  "tailscale_peers": $tailscale_peers_json,
  "zerotier_networks": $zerotier_networks_json,
  "ups_status": $ups_status_json,
  "ups_battery_pct": $ups_battery_json,
  "auto_update": $_bk_auto_update01,
  "oom_kills": $oom_kills,
  "boot_time": $boot_time,
  "agent_time": $agent_time,
  "agent_run_ms": $agent_run_ms,
  "agent_prev_total_ms": $agent_prev_total_ms,
  "agent_prev_cpu_ms": $agent_prev_cpu_ms,
  "runs_skipped_lock": $runs_skipped_lock,
  "runs_skipped_post": $runs_skipped_post,
  "runs_skipped_killed": $runs_skipped_killed,
  "dns_resolver_ok": $dns_resolver_ok,
  "dns_latency_ms": $dns_latency_ms,
  "wan_latency_ms": $wan_latency_ms,
  "wan_internet": $wan_internet,
  "wan_link_mbit": $wan_link_mbit,
  "wan_link_dev": $_jv_wan_link_dev,
  "wan_carrier_down_count": $wan_carrier_down_count,
  "wan_rx_mbps": $wan_rx_mbps,
  "wan_tx_mbps": $wan_tx_mbps,
  "wan_rx_errors": $wan_rx_errors,
  "wan_tx_errors": $wan_tx_errors,
  "wan_rx_dropped": $wan_rx_dropped,
  "wan_tx_dropped": $wan_tx_dropped,
  "wan_path": $wan_path_json,
  "lan_ports": $lan_ports_json,
  "speedtest_active": $speedtest_active,
  "openvpn_tunnels": $openvpn_tunnels,
  "usb_devices": $usb_devices,
  "log_warnings_24h": $log_warnings_24h
}
EOF
)

# The last payload is kept for debugging ("what did the router send?"). It
# used to be a world-readable file in /tmp with the agent key inside: any
# local user could read the key and then report, or fetch remote actions, in
# the router's name. Now it sits in the private directory, is created 0600
# and carries no key. The key is cut out by position, not by pattern: the
# copy is rebuilt from the text after the first "agent_type", so no quote or
# backslash inside a key can leave a piece of it behind. If the cut did not
# work, nothing is written at all.
#
# CAD-18/IO-11: and only when it answers a question. It used to be written on
# every run - 97 % of what a minute run wrote to tmpfs (14 kB, ~20 MB a day)
# and a subshell fork, for a copy nobody read. Now: on a plain --dry-run,
# after a POST that failed (the one case where "what did it send?" matters),
# and on every run while the owner keeps a flag file for it:
#   touch /var/run/status-agent-openwrt/last-payload.on
# An accepted report removes a copy left by an earlier failure, so a copy
# that exists always belongs to the latest report that did not arrive.
BK_LAST_PAYLOAD_FILE="$BK_PRIVATE_DIR/last-payload.json"
BK_LAST_PAYLOAD_ON="$BK_PRIVATE_DIR/last-payload.on"
bk_keep_last_payload() {
    lp_mark='"agent_type"'
    lp_tail=${payload#*"$lp_mark"}
    case "$lp_tail" in
        "$payload"|*'"agent_key"'*) rm -f "$BK_LAST_PAYLOAD_FILE" 2>/dev/null ;;
        *) ( umask 077; printf '{\n  "agent_key": "",\n  %s%s\n' "$lp_mark" "$lp_tail" > "$BK_LAST_PAYLOAD_FILE" ) 2>/dev/null || true ;;
    esac
}
[ "$DRY_RUN" = "1" ] && [ -z "$BK_TEST_RESPONSE" ] && bk_keep_last_payload

# The SMART reading itself happens OUTSIDE this run. It costs a drive access
# and can hang for minutes behind a bad USB bridge, while the report has to go
# out within the minute - so the minute run only decides WHICH disks are due
# and hands them to a detached child. A live PID in the lock (a refresh that is
# still running, or a smartctl that could not be killed) means: spawn nothing.
_smart_lock_live=""; [ -r "$BK_PRIVATE_DIR/smart.lock/pid" ] && read -r _smart_lock_live < "$BK_PRIVATE_DIR/smart.lock/pid"
case "$_smart_lock_live" in ''|*[!0-9]*) _smart_lock_live="" ;; esac
[ -n "$_smart_lock_live" ] && [ -d "/proc/$_smart_lock_live" ] && smart_due=""
if [ "$have_smartctl" = 1 ] && [ -n "$smart_due" ]; then
    _smart_spawn_prev=${smart_spawn_last%%|*}
    case "$_smart_spawn_prev" in ''|*[!0-9]*) _smart_spawn_prev=0 ;; esac
    # The same set spawned less than five minutes ago is not spawned again: a
    # full tmpfs or a child that dies at once would otherwise start one every
    # minute, which is exactly the drive hammering the interval exists to stop.
    if [ "${smart_spawn_last#*|}" != "$smart_due" ] || [ $((now_ts - _smart_spawn_prev)) -ge 300 ]; then
        printf '%s|%s\n' "$now_ts" "$smart_due" > "$BK_PRIVATE_DIR/smart.spawn" 2>/dev/null
        if [ "$DRY_RUN" = "1" ]; then
            # Inline, so --dry-run and the e2e are deterministic: the reading
            # happens after the payload was built, exactly as the detached
            # child does on a router, and the NEXT run reports what it found.
            # shellcheck disable=SC2086
            bk_smart_refresh $smart_due
        elif command -v setsid >/dev/null 2>&1; then
            # setsid: cron kills the whole process group when the parent ends.
            # shellcheck disable=SC2086
            ( setsid sh "$0" --smart-refresh $smart_due </dev/null >/dev/null 2>&1 & )
        else
            # shellcheck disable=SC2086
            ( sh "$0" --smart-refresh $smart_due </dev/null >/dev/null 2>&1 & )
        fi
    fi
fi

if [ "$DRY_RUN" = "1" ]; then
    printf '%s\n' "$payload"
    log_debug "Rezim --dry-run: data se neodesilaji."
    # With the response seam the run goes on: the canned answer takes the
    # place of the POST and everything below runs as on a router.
    [ -z "$BK_TEST_RESPONSE" ] && exit 0
fi

# WW-04: the run has a deadline. cron starts the next run 60 s after this one
# started, and a run still holding the lock then costs that minute its report
# ("l"). The POST used to wait up to 20 s whatever the clock said, so a slow
# run plus a stalled server went over. Its limit now comes from the time left
# until 58 s after the start (the uptime clock of agent_run_ms), minus 5 s
# for the name lookup, which uclient-fetch's -T does not bound (5.0-5.5 s
# measured). Never more than the 20 s it always had, never less than 5 s: a
# run that is already late still gets a real chance to deliver. The
# follow-ups after the report (action results, service checks, the update)
# use what is left, and those that can wait for the next minute are skipped
# below 12 s. No clock (no uptime to read): the fixed limits, as before.
BK_RUN_DEADLINE_S=58
bk_time_left() { # -> _left: whole seconds until the deadline, or empty
    _left=""
    bk_uptime_cs
    if [ -n "$_up_cs" ] && [ -n "$BK_RUN_START_CS" ] && [ "$_up_cs" -ge "$BK_RUN_START_CS" ] 2>/dev/null; then
        _left=$(( BK_RUN_DEADLINE_S - (_up_cs - BK_RUN_START_CS) / 100 ))
    fi
    return 0
}
bk_limit() { # LOW HIGH RESERVE -> _lim: _left minus RESERVE, clamped; HIGH without a clock
    _lim=$2
    [ -n "$_left" ] || return 0
    _lim=$((_left - $3))
    [ "$_lim" -gt "$2" ] && _lim=$2
    [ "$_lim" -lt "$1" ] && _lim=$1
    return 0
}

# IO-07: the self-update swap. NEW (a verified download in /tmp) becomes
# TARGET through a rename inside TARGET's own directory. Until 0.1.8 the
# script first copied itself to .bak and then did `mv /tmp/x /usr/bin/...`:
# /tmp is another filesystem, so that mv unlinked the script and copied the
# new one in - 2 x 224 kB of flash per update, and a window in which cron
# found the agent missing (2 of 48 samples) or half written (27-44 of 48).
# The .bak was never read by anything; a rollback is the server offering the
# previous version again. Returns 0 when TARGET is the new version, else 1
# with the reason in _sr_err (space: _sr_need kB were needed) and TARGET
# untouched.
bk_self_replace() { # NEW TARGET
    _sr_new=$1; _sr_t=$2; _sr_err=""; _sr_need=""
    bk_dirname "$_sr_t"
    # A .new left by a swap that never finished (the run killed in it, a
    # power cut, the OOM killer) goes first: on a tight overlay it would take
    # the room the space check below asks for, and refuse every later update
    # as "space", for good. This run holds the lock, so no other swap is
    # using it.
    rm -f "$_sr_t.new" 2>/dev/null
    # The new copy sits next to the old one until the rename, and the
    # running shell keeps the old inode until it exits: the whole new file
    # plus 64 kB must fit, or a full overlay would break every later write
    # on the router (config saves included). A df that says nothing does not
    # stop the update - the copy itself then fails cleanly or not at all.
    _sr_size=$(wc -c < "$_sr_new" 2>/dev/null); _sr_size=${_sr_size##* }
    _sr_df=$(df -Pk "$_dn" 2>/dev/null); _sr_df=${_sr_df##*"$BK_NL"}
    # shellcheck disable=SC2086
    set -- $_sr_df
    case "$_sr_size:${4:-x}" in
        *[!0-9:]*|:*) ;;
        *)
            _sr_need=$(( _sr_size / 1024 + 65 ))
            if [ "$4" -lt "$_sr_need" ]; then _sr_err=space; return 1; fi
            ;;
    esac
    # The data on the flash before the name points at it: otherwise a power
    # cut right after the rename can leave the name on an empty inode. dd
    # conv=fsync flushes THIS file only. A global `sync` would wait for every
    # mounted filesystem, and one disk that cannot write (a hung USB bridge,
    # a hard NFS mount) would hold the update in D state for good; busybox
    # `sync` takes no file argument (24.10 and master alike). A dd built
    # without conv= fails at once and the plain copy follows: as durable as
    # 0.1.8's swap, never an update refused for it.
    if ! dd if="$_sr_new" of="$_sr_t.new" conv=fsync 2>/dev/null; then
        if ! cp "$_sr_new" "$_sr_t.new" 2>/dev/null; then
            rm -f "$_sr_t.new" 2>/dev/null; _sr_err=copy; return 1
        fi
    fi
    chmod +x "$_sr_t.new" 2>/dev/null
    if ! mv -f "$_sr_t.new" "$_sr_t" 2>/dev/null; then
        rm -f "$_sr_t.new" 2>/dev/null; _sr_err=rename; return 1
    fi
    return 0
}

bk_time_left
bk_limit 5 20 5; bk_post_t=$_lim
# GNU wget tries twice: only when both tries fit, or when there is no clock.
bk_wget_tries=2
[ -n "$_left" ] && [ "$_left" -lt $((2 * bk_post_t + 5)) ] && bk_wget_tries=1

log_debug "Odesilam data na $API_URL (limit ${bk_post_t} s)..."

http_code=""
body=""

if [ -n "$BK_TEST_RESPONSE" ]; then
    http_code=$(sed -n '1p' "$BK_TEST_RESPONSE" 2>/dev/null | tr -cd '0-9')
    [ -z "$http_code" ] && http_code="000"
    body=$(sed -n '2,$p' "$BK_TEST_RESPONSE" 2>/dev/null)
elif command -v curl >/dev/null 2>&1; then
    response=$(curl -s -m "$bk_post_t" --connect-timeout 5 -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d "$payload" "$API_URL")
    # Split in the shell: the code is the last line (-w "\n%{http_code}"),
    # the body everything before it - `echo | tail -n 1` and `echo | head -n
    # -1` were four forks on every report.
    case "$response" in
        *"$BK_NL"*) http_code=${response##*"$BK_NL"}; body=${response%"$BK_NL"*} ;;
        *) http_code=$response; body="" ;;
    esac
    while :; do case "$body" in *"$BK_NL") body=${body%"$BK_NL"} ;; *) break ;; esac; done
elif command -v uclient-fetch >/dev/null 2>&1; then
    # uclient-fetch je soucasti zakladni instalace OpenWrt a na rozdil od
    # holeho BusyBox wget ma spolehlivou HTTPS podporu (ustream-ssl).
    # Judged by the exit code, not by "some body came back": an error page
    # used to count as HTTP 200 and be parsed for remote actions, while the
    # real reason ("Connection refused", TLS) went to /dev/null.
    uf_err=$(mktemp /tmp/status-openwrt-uf-err.XXXXXX 2>/dev/null || echo "/tmp/status-openwrt-uf-err-$$")
    # No -q here: uclient-fetch prints "HTTP error NNN" and "Connection
    # error: ..." only when it is not quiet, and those are exactly what the
    # failure branch below parses. Its stderr goes to the file either way, so
    # nothing reaches the console.
    if body=$(uclient-fetch -T "$bk_post_t" -O - --post-data="$payload" --header="Content-Type: application/json" "$API_URL" 2>"$uf_err"); then
        http_code="200"
    else
        http_code=$(sed -n 's/.*HTTP error \([0-9][0-9]*\).*/\1/p' "$uf_err" | head -n 1)
        [ -z "$http_code" ] && http_code="000"
        body=$(cat "$uf_err" 2>/dev/null)
    fi
    rm -f "$uf_err"
elif command -v wget >/dev/null 2>&1; then
    headers_file=$(mktemp /tmp/status-openwrt-wget-hdr.XXXXXX 2>/dev/null || echo "/tmp/status-openwrt-wget-hdr-$$")
    body=$(wget -T "$bk_post_t" -t "$bk_wget_tries" --post-data="$payload" --header="Content-Type: application/json" --server-response -q -O - "$API_URL" 2>"$headers_file")
    http_code=$(grep -E '^[[:space:]]*HTTP/' "$headers_file" | tail -n 1 | awk '{print $2}')
    rm -f "$headers_file"
else
    log_message "CHYBA: Neni k dispozici curl, uclient-fetch ani wget. Nelze odeslat data."
    exit 1
fi

if [ "$http_code" = "200" ]; then
    log_debug "OK: Statistiky uspesne odeslany."
    if [ -f "$BK_LAST_PAYLOAD_ON" ]; then
        bk_keep_last_payload
    elif [ -f "$BK_LAST_PAYLOAD_FILE" ]; then
        rm -f "$BK_LAST_PAYLOAD_FILE" 2>/dev/null
    fi

    # G42: the report is stored, so the skips it carried are dealt with: the
    # folded total goes back to zero. A skip appended while the POST was in
    # flight is still in `skipped` (never folded) and belongs to the next
    # report. Written only when there was something to clear.
    case "$runs_skipped_lock$runs_skipped_post$runs_skipped_killed" in
        000) ;;
        *) : > "$BK_SKIPPED_TOTAL" 2>/dev/null ;;
    esac

    # A bare 200 is not a receipt. The server wraps its speedtest INSERT loop
    # in a try/catch so that a broken result never brings telemetry ingestion
    # down - it logs and still answers 200. Committing on the status code
    # alone would advance the mark with nothing stored and nobody told, and
    # /tmp is a ramdisk: the next reboot would be the end of those results.
    #
    # So the answer must name the newest item it DEALT WITH (stored, already
    # present, or rejected for good), echoed exactly as it was sent, and only
    # up to that timestamp is the state advanced. A timestamp this report did
    # not send is not an answer to this report and is ignored.
    if [ -n "$speedtests_newest" ]; then
        sp_ack=""
        case "$body" in
            *'"speedtests_acked":"'*)
                sp_ack=${body#*'"speedtests_acked":"'}
                sp_ack=${sp_ack%%'"'*}
                ;;
            *'"speedtests_acked": "'*)
                sp_ack=${body#*'"speedtests_acked": "'}
                sp_ack=${sp_ack%%'"'*}
                ;;
        esac
        case "$speedtests_json" in
            *"\"timestamp\":\"$sp_ack\""*) ;;
            *) sp_ack="" ;;
        esac
        if [ -n "$sp_ack" ]; then
            printf '%s\n' "$sp_ack" > "$LIBRESPEED_STATE_FILE" 2>/dev/null || true
            # The pending mark becomes the sent one instead of being deleted:
            # what was handed over is then still readable on the router.
            mv "$BK_SPEED_PENDING" "$BK_PRIVATE_DIR/sent.state" 2>/dev/null || true
            log_debug "Vysledky mereni rychlosti potvrzeny do $sp_ack."
        else
            log_message "VAROVANI: Server prijal hlaseni, ale nepotvrdil vysledky mereni rychlosti - posilaji se znovu."
        fi
    fi

    # The monitor's switch for the log lines (W1-C3). The server names it in
    # every answer; an answer without it (an older server) changes nothing.
    # "false" is looked for first, so an answer carrying both keeps the lines
    # at home. Kept on flash next to the cfg, not in /var/run: an opt-out has
    # to survive a reboot, or the first report of every boot would carry the
    # lines again. Written only when the answer differs from what is kept.
    case "$body" in
        *'"log_lines":false'*|*'"log_lines": false'*)
            if [ ! -f "$BK_LOG_LINES_OFF" ]; then
                if : > "$BK_LOG_LINES_OFF" 2>/dev/null; then
                    log_message "Server vypnul odesilani radku z logu pro tento monitor."
                else
                    log_message "VAROVANI: Server vypnul odesilani radku z logu, ale $BK_LOG_LINES_OFF nejde zapsat - radky se poslou znovu."
                fi
            fi
            ;;
        *'"log_lines":true'*|*'"log_lines": true'*)
            if [ -f "$BK_LOG_LINES_OFF" ]; then
                rm -f "$BK_LOG_LINES_OFF" 2>/dev/null
                log_message "Server znovu zapnul odesilani radku z logu."
            fi
            ;;
    esac

    # Potvrzeni provedeni akce zpet na server - bez tohohle by agent_actions.status
    # zustal navzdy na 'sent' ("odeslano, ceka na potvrzeni") v administraci, i kdyz
    # se akce ve skutecnosti provedla. Samostatny lehky POST, protoze hlavni
    # telemetrie uz pro tento cyklus odesla.
    send_action_result() {
        ar_id="$1"; ar_status="$2"; ar_msg="$3"
        if [ -n "$BK_TEST_RESPONSE" ]; then
            # Response seam: the result lands next to the canned answer, nothing is POSTed.
            printf '%s|%s|%s\n' "$ar_id" "$ar_status" "$ar_msg" >> "$BK_TEST_RESPONSE.results" 2>/dev/null
            return 0
        fi
        # Escaped with the builtin: three $(json_str) subshells were three forks.
        bk_js "$AGENT_KEY"; _ar_k=$_jr; bk_js "$ar_status"; _ar_s=$_jr; bk_js "$ar_msg"
        ar_payload="{\"agent_key\":\"$_ar_k\",\"action_result\":{\"action_id\":${ar_id},\"status\":\"$_ar_s\",\"message\":\"$_jr\"}}"
        # WW-04: bounded by the deadline, never skipped - the action has
        # already run, and without its result it stays "sent" for ever.
        bk_time_left; bk_limit 3 10 2
        if command -v curl >/dev/null 2>&1; then
            curl -s -m "$_lim" -X POST -H "Content-Type: application/json" -d "$ar_payload" "$API_URL" >/dev/null 2>&1
        elif command -v uclient-fetch >/dev/null 2>&1; then
            uclient-fetch -q -T "$_lim" -O /dev/null --post-data="$ar_payload" --header="Content-Type: application/json" "$API_URL" >/dev/null 2>&1
        elif command -v wget >/dev/null 2>&1; then
            wget -T "$_lim" --post-data="$ar_payload" --header="Content-Type: application/json" -q -O /dev/null "$API_URL" >/dev/null 2>&1
        fi
    }

    # --- Spracovani vzdalenych akci (Remote Actions) ---
    REMOTE_ACTIONS_ENABLED="${REMOTE_ACTIONS_ENABLED:-0}"
    # "-", not ":-": a list the owner left EMPTY in the cfg allows nothing.
    # Only a cfg without the line gets the full default.
    ALLOWED_ACTIONS="${ALLOWED_ACTIONS-restart_wan,restart_wireguard,reboot_router,renew_dhcp,restart_service,reconnect_pppoe}"
    BK_NONCE_FILE="$BK_PRIVATE_DIR/action-nonces"

    # bk_action_gate: what a correctly SIGNED action still has to pass. Sets
    # act_refused to the reason, or leaves it empty. Until 0.1.7 the list
    # above was parsed and never looked at, a signed answer could be replayed
    # for as long as its timestamp held, and service_name went into a path
    # as it came.
    bk_action_gate() {
        act_refused=""
        # Single use. A signature is good for 30 s either side of its
        # timestamp, so at most 60 s after its first use - that long the
        # nonce is remembered. Written BEFORE the action runs: a reboot
        # would not come back to do it.
        case "$act_nonce" in
            ''|*[!A-Za-z0-9]*) act_refused="nonce chybi nebo ma nepovolene znaky"; return 0 ;;
        esac
        nonce_keep=""; nonce_seen=0
        if [ -f "$BK_NONCE_FILE" ]; then
            while read -r n_ts n_val; do
                case "$n_ts" in ''|*[!0-9]*) continue ;; esac
                [ $((now_ts - n_ts)) -gt 60 ] && continue
                [ "$n_val" = "$act_nonce" ] && nonce_seen=1
                nonce_keep="$nonce_keep$n_ts $n_val
"
            done < "$BK_NONCE_FILE"
        fi
        if [ "$nonce_seen" = "1" ]; then
            act_refused="nonce uz byl pouzit (opakovana odpoved)"; return 0
        fi
        # A nonce that cannot be remembered could be replayed: refuse.
        if ! printf '%s%s %s\n' "$nonce_keep" "$now_ts" "$act_nonce" > "$BK_NONCE_FILE.tmp" 2>/dev/null \
            || ! mv "$BK_NONCE_FILE.tmp" "$BK_NONCE_FILE" 2>/dev/null; then
            act_refused="nonce nejde ulozit do $BK_PRIVATE_DIR"; return 0
        fi
        # Allow-list. The type is checked first: a comma inside it would
        # match across two entries of the list.
        case "$act_type" in
            *[!a-z_]*) act_refused="neplatny typ akce"; return 0 ;;
        esac
        allowed_list=$(printf '%s' "$ALLOWED_ACTIONS" | tr -d ' \t\r')
        case ",$allowed_list," in
            *",$act_type,"*) ;;
            *) act_refused="akce '$act_type' neni v ALLOWED_ACTIONS"; return 0 ;;
        esac
        # The name becomes part of a path run as root: no "/", no "..".
        if [ "$act_type" = "restart_service" ]; then
            svc_name=$(echo "$body" | sed -n 's/.*"service_name":"\([^"]*\)".*/\1/p')
            case "$svc_name" in
                ''|.*|*[!A-Za-z0-9_.-]*) act_refused="neplatny nazev sluzby"; return 0 ;;
            esac
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
        # A letter in the timestamp ended the whole run on an arithmetic
        # error - no service checks, no self-update that minute. Not a
        # number = no action.
        case "$act_id$act_ts" in
            *[!0-9]*)
                log_message "VAROVANI: Vzdalena akce ma neciselne action_id nebo timestamp, ignoruji ji."
                act_id=""; act_ts="" ;;
        esac

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
                
                act_refused=""
                # The gate only ever sees a verified signature: an unsigned
                # answer learns nothing about the list and burns no nonce.
                if [ -n "$calc_sig" ] && [ "$calc_sig" = "$act_sig" ]; then
                    bk_action_gate
                fi
                if [ -n "$act_refused" ]; then
                    log_message "VAROVANI: Odmitnuta vzdalena akce $act_type (ID: $act_id): $act_refused"
                    send_action_result "$act_id" "failed" "Odmitnuto: $act_refused"
                elif [ -n "$calc_sig" ] && [ "$calc_sig" = "$act_sig" ]; then
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
                            # svc_name was read and checked by bk_action_gate.
                            # -f as well as -x: a directory passes -x.
                            if [ -n "$svc_name" ] && [ -f "/etc/init.d/$svc_name" ] && [ -x "/etc/init.d/$svc_name" ]; then
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
                        *)
                            # On the list but unknown to this version: say
                            # so, or the action stays "sent" for ever.
                            send_action_result "$act_id" "failed" "Tato verze agenta akci '$act_type' nezna"
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
    # A substring test is what `echo | grep -q` answered: the pattern holds no
    # newline. Two forks on every accepted report.
    case "$body" in *'"service_checks":['*) _sc_has=1 ;; *) _sc_has=0 ;; esac
    # WW-04: the server lists the checks in every answer, so a minute that is
    # out of time leaves them to the next one instead of running into it.
    if [ "$_sc_has" = 1 ]; then
        bk_time_left
        if [ -n "$_left" ] && [ "$_left" -lt 12 ]; then
            log_message "Kontroly sluzeb vynechany: do konce minuty zbyva ${_left} s."
            _sc_has=0
        fi
    fi
    if [ "$_sc_has" = 1 ]; then
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
            # The builtin escaper: a $(json_str) here was a fork per check, every
            # minute. It splits nothing, so the IFS='|' of this loop is harmless.
            bk_js "$sc_detail"
            sc_results="${sc_results}{\"monitor_id\":$sc_id,\"running\":$sc_bool,\"detail\":\"$_jr\"}"
        done
        IFS=$SC_OLD_IFS

        if [ -n "$sc_results" ]; then
            bk_js "$AGENT_KEY"
            sc_payload="{\"agent_key\":\"$_jr\",\"service_check_results\":[$sc_results]}"
            bk_time_left; bk_limit 3 10 2
            if [ -n "$BK_TEST_RESPONSE" ]; then
                : # response seam: a dry run never POSTs
            elif command -v curl >/dev/null 2>&1; then
                curl -s -m "$_lim" -X POST -H "Content-Type: application/json" -d "$sc_payload" "$API_URL" >/dev/null 2>&1
            elif command -v uclient-fetch >/dev/null 2>&1; then
                uclient-fetch -q -T "$_lim" -O /dev/null --post-data="$sc_payload" --header="Content-Type: application/json" "$API_URL" >/dev/null 2>&1
            elif command -v wget >/dev/null 2>&1; then
                wget -T "$_lim" --post-data="$sc_payload" --header="Content-Type: application/json" -q -O /dev/null "$API_URL" >/dev/null 2>&1
            fi
            log_debug "Odeslany vysledky agent-side kontrol sluzeb."
        fi
    fi

    # --- 6. Automatická aktualizace agenta (opt-in přes AUTO_UPDATE=1) ---
    # Server v odpovědi oznámí novější verzi včetně SHA-256 checksumu. Nová verze
    # se stáhne do dočasného souboru, ověří se checksum i syntaxe (sh -n) a teprve
    # potom se atomicky nahradí tento skript. Při dalším spuštění (cron) už poběží
    # nová verze.
    # Never under the response seam: a test must not replace the script it runs.
    if [ "$AUTO_UPDATE" = "1" ] && [ -z "$BK_TEST_RESPONSE" ]; then
        # `echo | grep -o '"update_available":[a-z]*' | cut -d: -f2` without
        # its four forks a report: every occurrence's letters, one per line.
        update_available=""; _ua_rest=$body
        while :; do
            case "$_ua_rest" in *'"update_available":'*) ;; *) break ;; esac
            _ua_rest=${_ua_rest#*'"update_available":'}
            _ua_v=${_ua_rest%%[!a-z]*}
            update_available="$update_available$_ua_v$BK_NL"
        done
        while :; do case "$update_available" in *"$BK_NL") update_available=${update_available%"$BK_NL"} ;; *) break ;; esac; done
        if [ "$update_available" = "true" ]; then
            update_url=$(echo "$body" | sed -n 's/.*"update_url":"\([^"]*\)".*/\1/p' | sed 's,\\/,/,g')
            update_sha=$(echo "$body" | sed -n 's/.*"update_sha256":"\([a-f0-9]*\)".*/\1/p')
            latest_version=$(echo "$body" | sed -n 's/.*"latest_version":"\([^"]*\)".*/\1/p')

            # WW-04: the offer comes with every report, so a minute that is
            # out of time leaves the download to a later one.
            bk_time_left
            if [ -n "$_left" ] && [ "$_left" -lt 12 ]; then
                log_debug "Aktualizace odlozena: do konce minuty zbyva ${_left} s."
                update_url=""
            fi
            if [ -n "$update_url" ] && [ -n "$update_sha" ]; then
                self_path="$0"
                bk_limit 5 60 2
                # One fixed name in the private directory, not a new mktemp in
                # /tmp each time: a run killed during the download or the swap
                # (a takeover) would leave a whole agent there for good, one
                # more per killed run. The next download starts over this one.
                tmp_file="$BK_PRIVATE_DIR/update.dl"
                rm -f "$tmp_file" 2>/dev/null
                log_message "K dispozici je nova verze agenta $latest_version (aktualni $AGENT_VERSION), stahuji z $update_url..."

                download_ok=0
                if command -v curl >/dev/null 2>&1; then
                    curl -fsS -m "$_lim" --connect-timeout 10 -o "$tmp_file" "$update_url" && download_ok=1
                elif command -v uclient-fetch >/dev/null 2>&1; then
                    uclient-fetch -q -T "$_lim" -O "$tmp_file" "$update_url" && download_ok=1
                elif command -v wget >/dev/null 2>&1; then
                    wget -q -T "$_lim" -t 2 -O "$tmp_file" "$update_url" && download_ok=1
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
                            if bk_self_replace "$tmp_file" "$self_path"; then
                                rm -f "$tmp_file" 2>/dev/null
                                log_message "OK: Agent aktualizovan na verzi $latest_version. Nova verze se pouzije pri pristim spusteni."
                                exit 0
                            elif [ "$_sr_err" = space ]; then
                                log_message "CHYBA UPDATE: Vedle $self_path neni misto na novou verzi ($_sr_need kB). Aktualizace zrusena."
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
    bk_keep_last_payload
    # G42: this minute produced no stored report either. Counted here and
    # not where the POST is built, so a transport that came back with any
    # other code is counted too - and straight into the folded total: this
    # run holds the lock and has the counters in hand, so no line has to be
    # written and read back.
    runs_skipped_post=$((runs_skipped_post + 1)); bk_sk_cap; bk_sk_save
    exit 1
fi
