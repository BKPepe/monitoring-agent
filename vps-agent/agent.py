#!/usr/bin/env python3
"""
Blood Kings Status Monitoring - VPS Agent (Python 3 Version)
Tento skript spouštějte na vašem VPS (např. přes cron každých 5 minut).
Nevyžaduje žádné externí knihovny (pouze standardní Python 3).
"""

import os
import re
import sys
import time
import socket
import json
import hmac
import hashlib
import datetime
import urllib.request
import subprocess
import threading

# subprocess.run(capture_output=...) is 3.7+; on 3.6 every tool call raised
# TypeError inside a silent except and the agent reported null for all of
# them without a word. Better to say so once.
if sys.version_info < (3, 7):
    sys.exit("agent.py vyzaduje Python 3.7+ (subprocess capture_output)")

# === VÝCHOZÍ KONFIGURACE ===
# Pokud chcete, můžete tyto hodnoty nechat zde, nebo vytvořit soubor 'agent.cfg' ve stejné složce
API_URL = "http://localhost/status/agent_api.php"
AGENT_KEY = "ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE"
AUTO_UPDATE = False  # Povolení automatických aktualizací agenta ze serveru
HEAVY_OP_INTERVAL_HOURS = 24  # Interval pro náročné operace v hodinách (výchozí 24h)
REMOTE_ACTIONS_ENABLED = False  # Opt-in: povolení HMAC-podepsaných vzdálených akcí ze serveru
ALLOWED_ACTIONS = "restart_service,reboot_server"  # Whitelist povolených akcí (čárkou oddělené)
# ===========================

# Načtení z Environment proměnných
if os.environ.get("STATUS_API_URL"):
    API_URL = os.environ.get("STATUS_API_URL")
if os.environ.get("STATUS_AGENT_KEY"):
    AGENT_KEY = os.environ.get("STATUS_AGENT_KEY")
if os.environ.get("STATUS_AUTO_UPDATE"):
    AUTO_UPDATE = os.environ.get("STATUS_AUTO_UPDATE") == "1"
if os.environ.get("STATUS_REMOTE_ACTIONS_ENABLED"):
    REMOTE_ACTIONS_ENABLED = os.environ.get("STATUS_REMOTE_ACTIONS_ENABLED") == "1"
if os.environ.get("STATUS_ALLOWED_ACTIONS"):
    ALLOWED_ACTIONS = os.environ.get("STATUS_ALLOWED_ACTIONS")
if os.environ.get("STATUS_HEAVY_OP_INTERVAL_HOURS"):
    try:
        HEAVY_OP_INTERVAL_HOURS = int(os.environ.get("STATUS_HEAVY_OP_INTERVAL_HOURS"))
    except ValueError:
        pass

# Režim pro běh v Docker kontejneru (docker-compose.agent.yml):
# kontejner běží s pid: host (=> /proc patří hostiteli) a kořenový FS hostitele
# je připojen read-only na /host, ze kterého se měří zaplnění disku a čte OS.
DOCKER_MODE = os.environ.get("DOCKER_MODE") == "1"
HOST_ROOT = os.environ.get("HOST_ROOT", "/host")

# Načtení z externí konfigurace 'agent.cfg'
cfg_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent.cfg')
if os.path.exists(cfg_path):
    try:
        with open(cfg_path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    parts = line.split('=', 1)
                    k = parts[0].strip()
                    v = parts[1].strip().strip('"').strip("'")
                    if k == "API_URL":
                        API_URL = v
                    elif k == "AGENT_KEY":
                        AGENT_KEY = v
                    elif k == "AUTO_UPDATE":
                        AUTO_UPDATE = v == "1"
                    elif k == "REMOTE_ACTIONS_ENABLED":
                        REMOTE_ACTIONS_ENABLED = v == "1"
                    elif k == "ALLOWED_ACTIONS":
                        ALLOWED_ACTIONS = v
                    elif k == 'HEAVY_OP_INTERVAL_HOURS':
                        try:
                            HEAVY_OP_INTERVAL_HOURS = int(v)
                        except ValueError:
                            pass
    except Exception:
        pass

AGENT_VERSION = "0.1.0"
LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent.log')
# V Docker režimu je adresář se skriptem připojený read-only, proto se stavový
# soubor pro výpočet síťové propustnosti ukládá vždy do /tmp.
NET_STATE_FILE = '/tmp/status-agent-net.state' if DOCKER_MODE else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent_net.state')

# Between-run state and caches live next to the script (a root-owned
# directory), not in the world-writable /tmp where any local user could
# pre-create them; only the read-only Docker mount keeps /tmp.
STATE_DIR = '/tmp' if DOCKER_MODE else os.path.dirname(os.path.abspath(__file__))

VERBOSE = '--verbose' in sys.argv or '-v' in sys.argv or os.environ.get('STATUS_VERBOSE') == '1' or sys.stdout.isatty()
# --dry-run / --print: collect, print the JSON to stdout, send nothing.
DRY_RUN = '--dry-run' in sys.argv or '--print' in sys.argv

def log_message(msg):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_line = f"{ts} - {msg}\n"
    if VERBOSE:
        # In --dry-run stdout carries the JSON; chatter goes to stderr.
        print(log_line.strip(), file=sys.stderr if DRY_RUN else sys.stdout)

    if not DOCKER_MODE:
        try:
            # Bounded: above 1 MB keep the last 500 lines. It used to grow
            # without limit - 5 lines per run including the full port list.
            try:
                if os.path.getsize(LOG_FILE) > 1048576:
                    with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as f:
                        tail = f.readlines()[-500:]
                    with open(LOG_FILE, "w", encoding="utf-8") as f:
                        f.writelines(tail)
            except OSError:
                pass
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(log_line)
        except Exception:
            pass

def log_debug(msg):
    """Progress chatter - only with --verbose; the log file keeps errors and actions."""
    if VERBOSE:
        log_message(msg)


def _boot_id():
    """Kernel boot id: counters restart from zero after a reboot, so a delta
    against a state file from the previous boot is meaningless (or, worse, a
    fabricated 0.0). Every between-run state is keyed by this."""
    try:
        with open('/proc/sys/kernel/random/boot_id', 'r') as f:
            return f.read().strip()
    except Exception:
        return None


def _atomic_write_json(path, obj):
    """State files are read by the next run: a kill mid-write must not leave a
    truncated file behind (it would cost that run its deltas)."""
    tmp = f"{path}.tmp{os.getpid()}"
    try:
        with open(tmp, 'w') as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except BaseException:
        # A full disk must not leave one orphan per run next to the script.
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

def get_cpu_usage():
    """
    Vypočítá využití CPU, CPU steal time a IO wait (vše v %) z /proc/stat.
    Steal (8. pole, index 7) je čas, kdy hypervisor přidělil CPU jinému
    hostiteli - na VPS důležitý signál "sousedského rušení". IO wait (5. pole,
    index 4) je dřív počítán jen jako součást "idle", teď se hlásí zvlášť -
    vysoký iowait ukazuje na pomalý/přetížený disk, ne na volnou CPU.
    Vrací (cpu_pct, steal_pct, iowait_pct).
    """
    state_file = os.path.join(STATE_DIR, 'vps_agent_cpu_state.json')
    now_ts = time.time()

    def read_stat():
        try:
            with open('/proc/stat', 'r') as f:
                lines = f.readlines()
            for line in lines:
                if line.startswith('cpu '):
                    fields = [float(x) for x in line.strip().split()[1:]]
                    iowait = fields[4] if len(fields) > 4 else 0.0
                    idle = fields[3] + iowait
                    steal = fields[7] if len(fields) > 7 else 0.0
                    total = sum(fields)
                    return idle, steal, iowait, total
        except IOError:
            pass
        return None, None, None, 0.0

    idle2, steal2, iowait2, total2 = read_stat()
    if total2 == 0:
        return None, None, None

    boot_id = _boot_id()
    prev_state = None
    if os.path.exists(state_file):
        try:
            with open(state_file, 'r') as f:
                prev_state = json.load(f)
            if prev_state.get('boot_id') != boot_id:
                prev_state = None
        except Exception:
            pass

    try:
        _atomic_write_json(state_file, {'ts': now_ts, 'boot_id': boot_id, 'stat': [idle2, steal2, iowait2, total2]})
    except Exception:
        pass

    if not prev_state or 'stat' not in prev_state:
        return None, None, None

    idle1, steal1, iowait1, total1 = prev_state['stat']
    idle_delta = idle2 - idle1
    steal_delta = steal2 - steal1
    iowait_delta = iowait2 - iowait1
    total_delta = total2 - total1

    if total_delta <= 0:
        return None, None, None

    cpu_pct = round((1.0 - idle_delta / total_delta) * 100, 1)
    steal_pct = round((steal_delta / total_delta) * 100, 1)
    iowait_pct = round((iowait_delta / total_delta) * 100, 1)
    return cpu_pct, steal_pct, iowait_pct

def get_tailscale():
    """(up, peer_count) z tailscale status --json; (None, None) bez Tailscale."""
    try:
        out = subprocess.run(['tailscale', 'status', '--json'], capture_output=True, text=True, timeout=10)
        if out.returncode != 0:
            return None, None
        data = json.loads(out.stdout)
        up = data.get('BackendState') == 'Running'
        peers = len(data.get('Peer') or {})
        return up, peers
    except Exception:
        return None, None


def get_zerotier_networks():
    try:
        out = subprocess.run(['zerotier-cli', 'listnetworks'], capture_output=True, text=True, timeout=10)
        if out.returncode != 0:
            return None
        return sum(1 for line in out.stdout.splitlines() if ' OK ' in line)
    except Exception:
        return None


def get_ups():
    """(status, battery_pct) z NUT upsc; (None, None) bez UPS."""
    try:
        names = subprocess.run(['upsc', '-l'], capture_output=True, text=True, timeout=10)
        name = names.stdout.split()[0] if names.returncode == 0 and names.stdout.split() else None
        if not name:
            return None, None
        data = subprocess.run(['upsc', name], capture_output=True, text=True, timeout=10)
        status = battery = None
        for line in data.stdout.splitlines():
            if line.startswith('ups.status:'):
                status = line.split(':', 1)[1].strip()
            elif line.startswith('battery.charge:'):
                try:
                    battery = int(float(line.split(':', 1)[1].strip()))
                except ValueError:
                    pass
        return status, battery
    except Exception:
        return None, None


def get_ram_detail_mb():
    """RAM detail v MB (total/used/available/free) - parita s agent.sh, který
    to posílá odjakživa; UI z toho skládá "8.2 GB / 16 GB (volné ...)"."""
    total = used = avail = free = None
    try:
        info = {}
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2 and parts[0].rstrip(':') in ('MemTotal', 'MemAvailable', 'MemFree'):
                    info[parts[0].rstrip(':')] = int(parts[1])
        if 'MemTotal' in info:
            total = info['MemTotal'] // 1024
            avail = info.get('MemAvailable', info.get('MemFree', 0)) // 1024
            free = info.get('MemFree', 0) // 1024
            used = total - avail
    except Exception:
        pass
    return total, used, avail, free


def get_tcp_retrans():
    """Kumulativní TCP retransmise z /proc/net/snmp (RetransSegs)."""
    try:
        with open('/proc/net/snmp', 'r') as f:
            lines = f.readlines()
        for i, line in enumerate(lines):
            if line.startswith('Tcp:') and i + 1 < len(lines) and lines[i + 1].startswith('Tcp:'):
                header = line.split()
                values = lines[i + 1].split()
                if 'RetransSegs' in header:
                    return int(values[header.index('RetransSegs')])
    except Exception:
        pass
    return None


def get_conntrack_count():
    try:
        with open('/proc/sys/net/netfilter/nf_conntrack_count', 'r') as f:
            return int(f.read().strip())
    except Exception:
        return None


def get_oom_kills():
    """OOM kills since boot from /proc/vmstat (kernel 4.13+). One small read,
    monotonic. The old `dmesg` scan read the whole ring buffer every run,
    counted each kill twice (two log lines per event) and shrank when the
    buffer wrapped. None where the kernel does not expose the counter."""
    try:
        with open('/proc/vmstat', 'r') as f:
            for line in f:
                if line.startswith('oom_kill '):
                    return int(line.split()[1])
    except Exception:
        pass
    return None


def get_dns_latency_ms():
    """Latency of one resolver lookup. getaddrinfo() has no timeout of its own
    and a dead resolver blocks it for 10-30 s - exactly when the report is
    most wanted - so it runs in a daemon thread with a 3 s budget; a lookup
    that did not finish has no latency to report."""
    result = {}

    def _lookup():
        try:
            t0 = time.time()
            socket.getaddrinfo('example.com', 80)
            result['ms'] = round((time.time() - t0) * 1000, 1)
        except Exception:
            pass

    th = threading.Thread(target=_lookup, daemon=True)
    th.start()
    th.join(3)
    return result.get('ms')


def get_openvpn_tunnels():
    try:
        out = subprocess.run(['pidof', 'openvpn'], capture_output=True, text=True, timeout=5)
        pids = out.stdout.split()
        return len(pids)
    except Exception:
        return None


def get_usb_devices():
    try:
        entries = os.listdir('/sys/bus/usb/devices')
        # 1-1 is a device; 1-0:1.0 is an interface (one per root hub even
        # with nothing plugged in) - only the former count.
        return sum(1 for e in entries if e and e[0].isdigit() and '-' in e and ':' not in e)
    except Exception:
        return None


def get_ram_usage():
    """Vypočítá využití RAM v % z /proc/meminfo"""
    try:
        mem = {}
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                parts = line.split(':')
                if len(parts) == 2:
                    name = parts[0].strip()
                    val = parts[1].split()[0].strip()
                    mem[name] = float(val)
        
        total = mem.get('MemTotal', 0)
        free = mem.get('MemFree', 0)
        buffers = mem.get('Buffers', 0)
        cached = mem.get('Cached', 0)
        
        available = mem.get('MemAvailable', free + buffers + cached)
        used = total - available
        
        if total == 0:
            return None
        
        return round((used / total) * 100, 1)
    except Exception:
        return None

def get_swap_usage():
    """Swap usage in % from /proc/meminfo. No swap configured is "not applicable"
    (None, a dash in the UI) - the same answer the other agents give - not 0.0 % of nothing."""
    try:
        mem = {}
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                parts = line.split(':')
                if len(parts) == 2:
                    mem[parts[0].strip()] = float(parts[1].split()[0].strip())

        total = mem.get('SwapTotal', 0)
        free = mem.get('SwapFree', 0)
        if total == 0:
            return None
        return round(((total - free) / total) * 100, 1)
    except Exception:
        return None

def get_load_average():
    """Vrátí (load1, load5, load15) z /proc/loadavg, nebo (None, None, None) při chybě."""
    try:
        with open('/proc/loadavg', 'r') as f:
            parts = f.readline().split()
        return float(parts[0]), float(parts[1]), float(parts[2])
    except Exception:
        return None, None, None

def get_hdd_usage():
    """Vypočítá zaplnění disku root / v % (v Docker režimu měří hostitelský FS přes /host)"""
    try:
        root_path = HOST_ROOT if DOCKER_MODE and os.path.isdir(HOST_ROOT) else '/'
        st = os.statvfs(root_path)
        free = st.f_bavail * st.f_frsize
        total = st.f_blocks * st.f_frsize
        used = total - free

        if total == 0:
            return None

        return round((used / total) * 100, 1)
    except Exception:
        return None

def get_inode_usage():
    """Vypočítá zaplnění inodů kořenového disku v % - stejný statvfs() jako get_hdd_usage(), jen jiná pole."""
    try:
        root_path = HOST_ROOT if DOCKER_MODE and os.path.isdir(HOST_ROOT) else '/'
        st = os.statvfs(root_path)
        total_inodes = st.f_files
        free_inodes = st.f_ffree
        if total_inodes == 0:
            return None
        used_inodes = total_inodes - free_inodes
        return round((used_inodes / total_inodes) * 100, 1)
    except Exception:
        return None

DISKIO_STATE_FILE = '/tmp/status-agent-diskio.state' if DOCKER_MODE else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent_diskio.state')
_WHOLE_DISK_RE = re.compile(r'^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme\d+n\d+)$')

def get_disk_io_sectors():
    """
    Vrátí (sectors_read, sectors_written) součet přes fyzické disky z /proc/diskstats.
    Stejně jako /proc/stat a /proc/meminfo je diskstats celojaderný čítač, ne per-pid-
    namespace - v Docker režimu (pid: host) proto funguje bez zvláštního /host přístupu,
    stejně jako existující get_cpu_usage()/get_ram_usage().
    Vynechává oddíly (sda1, nvme0n1p1) a loop/ram zařízení, aby se I/O nezapočítalo dvakrát.
    """
    read_total = 0
    write_total = 0
    matched = 0
    try:
        with open('/proc/diskstats', 'r') as f:
            for line in f:
                fields = line.split()
                if len(fields) < 10:
                    continue
                if not _WHOLE_DISK_RE.match(fields[2]):
                    continue
                matched += 1
                read_total += int(fields[5])   # sectors read
                write_total += int(fields[9])  # sectors written
    except Exception:
        return None, None
    # mmcblk / dm-only hosts and containers without diskstats match nothing:
    # that is "not measured", not a 0.0 KB/s rate.
    return (read_total, write_total) if matched else (None, None)

def get_disk_io():
    """
    Vypočítá průměrnou I/O propustnost disku (čtení/zápis) v KB/s od posledního běhu.
    Stejný tick/tock princip jako get_network_usage() - první běh vrací (None, None).
    """
    read_sectors, write_sectors = get_disk_io_sectors()
    if read_sectors is None:
        return None, None
    now = time.time()
    sector_size = 512  # /proc/diskstats vždy počítá v 512B sektorech bez ohledu na fyzickou velikost sektoru

    prev = None
    try:
        with open(DISKIO_STATE_FILE, 'r') as f:
            parts = f.read().strip().split(',')
            if len(parts) >= 3:
                prev = (float(parts[0]), int(parts[1]), int(parts[2]))
    except Exception:
        pass

    try:
        with open(DISKIO_STATE_FILE, 'w') as f:
            f.write(f"{now},{read_sectors},{write_sectors}")
    except Exception:
        pass

    if prev is None:
        return None, None

    elapsed = now - prev[0]
    delta_read = read_sectors - prev[1]
    delta_write = write_sectors - prev[2]
    if elapsed <= 0 or delta_read < 0 or delta_write < 0:
        return None, None

    read_kbps = round((delta_read * sector_size / elapsed) / 1024, 1)
    write_kbps = round((delta_write * sector_size / elapsed) / 1024, 1)
    return read_kbps, write_kbps

FORKRATE_STATE_FILE = '/tmp/status-agent-forkrate.state' if DOCKER_MODE else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent_forkrate.state')

def get_fork_rate():
    """
    Počet nově vytvořených procesů (fork) od posledního běhu agenta - ne rychlost
    za sekundu, ale delta od minula (stejně jako net_errors). /proc/stat řádek
    "processes" je kumulativní čítač forků od bootu, tick/tock stejně jako
    get_disk_io()/get_network_usage(). První běh vrací None (chybí předchozí vzorek).
    """
    total_forks = None
    try:
        with open('/proc/stat', 'r') as f:
            for line in f:
                if line.startswith('processes '):
                    total_forks = int(line.split()[1])
                    break
    except Exception:
        pass
    if total_forks is None:
        return None

    prev = None
    try:
        with open(FORKRATE_STATE_FILE, 'r') as f:
            prev = int(f.read().strip())
    except Exception:
        pass

    try:
        with open(FORKRATE_STATE_FILE, 'w') as f:
            f.write(str(total_forks))
    except Exception:
        pass

    if prev is None:
        return None
    delta = total_forks - prev
    return delta if delta >= 0 else None

def get_temperature():
    """
    Nejvyšší teplota (°C) mezi dostupnými /sys/class/thermal/thermal_zone* zónami.
    Na většině VPS vrátí None - tepelné senzory hostitele se přes virtualizaci
    obvykle nevystavují. Nejde o chybu, jen o nedostupnost dat na daném stroji.
    """
    max_temp = None
    try:
        base = '/sys/class/thermal'
        if os.path.isdir(base):
            for zone in os.listdir(base):
                if not zone.startswith('thermal_zone'):
                    continue
                temp_path = os.path.join(base, zone, 'temp')
                try:
                    with open(temp_path, 'r') as f:
                        millideg = float(f.read().strip())
                    deg = millideg / 1000.0
                    # Sanity limit - chybné čtení z virtualizovaného/chybějícího senzoru
                    # občas vrátí nesmyslné hodnoty (0, záporné, nebo stovky stupňů).
                    if 0 < deg < 150 and (max_temp is None or deg > max_temp):
                        max_temp = deg
                except Exception:
                    continue
    except Exception:
        pass
    return round(max_temp, 1) if max_temp is not None else None

def get_system_identity():
    """Statická identita hostitele kešovaná v RAM."""
    cache_file = os.path.join(STATE_DIR, 'vps_agent_identity.json')
    root = HOST_ROOT if DOCKER_MODE and os.path.isdir(HOST_ROOT) else ''

    def reboot_required():
        # /var/run/reboot-required is a Debian/Ubuntu convention; elsewhere its
        # absence proves nothing, so the answer is None, not a fabricated False.
        if not os.path.exists(root + '/etc/debian_version'):
            return None
        # Both spellings: under /host, /var/run is a symlink to /run that the
        # kernel would resolve against the container's own root.
        return any(os.path.exists(root + p) for p in ('/run/reboot-required', '/var/run/reboot-required'))

    # The cache used to be trusted forever - a kernel upgrade or a rename never
    # reached the server where /tmp survives reboots. Keyed by boot id now.
    boot_id = _boot_id()
    if os.path.exists(cache_file):
        try:
            with open(cache_file, 'r') as f:
                res = json.load(f)
            if res.get('_boot_id') == boot_id:
                res.pop('_boot_id', None)
                res['reboot_required'] = reboot_required()
                return res
        except Exception:
            pass

    identity = {
        'hostname': None, 'kernel': None, 'timezone': None,
        'reboot_required': reboot_required(),
        'cloud_provider': None, 'virtualization': None,
    }

    try:
        import socket as _socket
        identity['hostname'] = _socket.gethostname()
    except Exception:
        pass

    try:
        import platform as _platform
        identity['kernel'] = _platform.release()
    except Exception:
        pass

    try:
        if os.path.exists(root + '/etc/timezone'):
            with open(root + '/etc/timezone', 'r') as f:
                identity['timezone'] = f.read().strip()
        elif os.path.islink(root + '/etc/localtime'):
            link = os.readlink(root + '/etc/localtime')
            identity['timezone'] = link.split('zoneinfo/')[-1] if 'zoneinfo/' in link else None
    except Exception:
        pass

    try:
        res = subprocess.run(['systemd-detect-virt'], capture_output=True, text=True, timeout=3)
        virt = res.stdout.strip()
        if virt and virt != 'none':
            identity['virtualization'] = virt
    except Exception:
        pass

    # Best-effort rozpoznání cloud poskytovatele dle DMI řetězců - nepokrývá
    # všechny poskytovatele (OVH typicky vystavuje jen obecné KVM DMI bez
    # rozlišujícího řetězce), jde o orientační informaci, ne spolehlivý fakt.
    try:
        dmi_text = ''
        for dmi_file in ('/sys/class/dmi/id/sys_vendor', '/sys/class/dmi/id/product_name', '/sys/class/dmi/id/bios_vendor'):
            if os.path.exists(dmi_file):
                with open(dmi_file, 'r') as f:
                    dmi_text += f.read().strip().lower() + ' '
        provider_hints = [
            ('amazon', 'AWS'), ('google', 'Google Cloud'), ('microsoft', 'Azure'),
            ('digitalocean', 'DigitalOcean'), ('hetzner', 'Hetzner'),
            ('vultr', 'Vultr'), ('linode', 'Linode'), ('scaleway', 'Scaleway'),
        ]
        for hint, name in provider_hints:
            if hint in dmi_text:
                identity['cloud_provider'] = name
                break
    except Exception:
        pass

    try:
        _atomic_write_json(cache_file, dict(identity, _boot_id=boot_id))
        log_debug(f"Načtena identita VPS: hostname={identity['hostname']} kernel={identity['kernel']}")
    except Exception:
        pass

    return identity

def get_process_snapshot(limit=5):
    """
    Jeden společný sken /proc/<pid>/* pro tři věci najednou: počet zombie procesů,
    TOP CPU procesy a TOP RAM procesy. CPU ranking je reálný "právě teď" stav (ne
    průměr od startu procesu) - stejná dvouvzorková delta technika jako u
    get_ts3_process_info(), jen zobecněná na všechny PID najednou.
    Vrací (zombie_count, top_cpu[{name,cpu}], top_ram[{name,ram_mb}]).
    """
    def read_all_stats():
        stats = {}
        try:
            for entry in os.listdir('/proc'):
                if not entry.isdigit():
                    continue
                try:
                    with open(f'/proc/{entry}/stat', 'r') as f:
                        raw = f.read()
                    after_comm = raw[raw.rfind(')') + 2:]
                    fields = after_comm.split()
                    if len(fields) < 13:
                        continue
                    state = fields[0]
                    utime = int(fields[11])
                    stime = int(fields[12])
                    stats[entry] = (state, utime + stime)
                except Exception:
                    continue
        except Exception:
            pass
        return stats

    state_file = os.path.join(STATE_DIR, 'vps_agent_proc_state.json')
    now_ts = time.time()
    boot_id = _boot_id()
    self_pid = str(os.getpid())
    stats2 = read_all_stats()
    zombie_count = sum(1 for state, _ in stats2.values() if state == 'Z')

    prev_state = None
    if os.path.exists(state_file):
        try:
            with open(state_file, 'r') as f:
                raw = json.load(f)
                # PIDs are strings on both sides: the previous version cast the
                # saved keys to int while the live keys stayed str, so no PID
                # ever matched and the CPU ranking was always empty.
                prev_state = {str(k): v for k, v in raw.get('stats', {}).items()}
                prev_ts = raw.get('ts', now_ts)
                if raw.get('boot_id') != boot_id:
                    prev_state = None
        except Exception:
            pass

    try:
        serializable_stats = {str(k): list(v) for k, v in stats2.items()}
        _atomic_write_json(state_file, {'ts': now_ts, 'boot_id': boot_id, 'stats': serializable_stats})
    except Exception:
        pass

    # One pass over /proc/<pid>/status gives every name and RSS; both rankings
    # come from it, so neither needs a /proc walk of its own. Both values in
    # both lists so no cell in the table stays empty - a value that was not
    # read is None, never 0.
    names = {}
    rss_kb = {}
    for pid in stats2:
        try:
            with open(f'/proc/{pid}/status', 'r') as f:
                for line in f:
                    if line.startswith('Name:'):
                        names[pid] = line.split(None, 1)[1].strip()
                    elif line.startswith('VmRSS:'):
                        rss_kb[pid] = int(line.split()[1])
        except Exception:
            continue

    def ram_mb(pid):
        return round(rss_kb[pid] / 1024, 1) if pid in rss_kb else None

    cpu_deltas = []
    if prev_state:
        try:
            clk_tck = os.sysconf('SC_CLK_TCK')
        except Exception:
            clk_tck = 100
        elapsed = max(0.1, now_ts - prev_ts)
        for pid, (state, ticks2) in stats2.items():
            # The agent itself never belongs in its own ranking.
            if pid == self_pid or pid not in prev_state or state == 'Z':
                continue
            ticks1 = prev_state[pid][1]
            delta_ticks = ticks2 - ticks1
            if delta_ticks <= 0:
                continue
            cpu_pct = round(((delta_ticks / clk_tck) / elapsed) * 100, 1)
            cpu_deltas.append({'name': names.get(pid, f'pid-{pid}'), 'cpu': cpu_pct, 'ram_mb': ram_mb(pid)})

    cpu_deltas.sort(key=lambda x: x['cpu'], reverse=True)
    top_cpu = cpu_deltas[:limit]

    ram_list = [{'name': names.get(pid, f'pid-{pid}'), 'ram_mb': round(kb / 1024, 1)}
                for pid, kb in rss_kb.items() if kb and pid != self_pid]
    ram_list.sort(key=lambda x: x['ram_mb'], reverse=True)
    top_ram = ram_list[:limit]

    return zombie_count, top_cpu, top_ram

def get_network_bytes():
    """
    Vrátí (rx_bytes, tx_bytes, error_count) součet přes všechna síťová rozhraní kromě
    loopbacku a virtuálních Docker rozhraní. error_count sčítá rx_errs+rx_drop+tx_errs+tx_drop.
    """
    rx_total = 0
    tx_total = 0
    err_total = 0
    try:
        with open('/proc/net/dev', 'r') as f:
            lines = f.readlines()[2:]
        for line in lines:
            if ':' not in line:
                continue
            iface, rest = line.split(':', 1)
            iface = iface.strip()
            if iface == 'lo' or iface.startswith(('veth', 'docker', 'br-')):
                continue
            fields = rest.split()
            rx_total += int(fields[0])
            tx_total += int(fields[8])
            err_total += int(fields[2]) + int(fields[3]) + int(fields[10]) + int(fields[11])
    except Exception:
        pass
    return rx_total, tx_total, err_total

def get_network_usage():
    """
    Vypočítá průměrnou propustnost sítě (RX+TX) v KB/s a počet nových síťových chyb/
    zahozených paketů od posledního běhu agenta. Mezi spuštěními se ukládá kumulativní
    počet bajtů/chyb a čas do stavového souboru - první běh proto vrací (None, None).
    """
    rx, tx, errors = get_network_bytes()
    total_bytes = rx + tx
    now = time.time()

    prev = None
    try:
        with open(NET_STATE_FILE, 'r') as f:
            parts = f.read().strip().split(',')
            # Zpětná kompatibilita se starším stavovým souborem o 2 položkách (bez chyb)
            if len(parts) >= 3:
                prev = (float(parts[0]), int(parts[1]), int(parts[2]))
            elif len(parts) == 2:
                prev = (float(parts[0]), int(parts[1]), errors)
    except Exception:
        pass

    try:
        with open(NET_STATE_FILE, 'w') as f:
            f.write(f"{now},{total_bytes},{errors}")
    except Exception:
        pass

    if prev is None or total_bytes == 0:
        return None, None

    elapsed = now - prev[0]
    delta_bytes = total_bytes - prev[1]
    delta_errors = errors - prev[2]
    if elapsed <= 0 or delta_bytes < 0:
        # Čítač se resetoval (restart sítě/serveru) nebo neplatný interval
        return None, None

    net_kbps = round((delta_bytes / elapsed) / 1024, 1)
    net_errors = delta_errors if delta_errors >= 0 else None
    return net_kbps, net_errors

def get_uptime():
    """Uuptime v sekundách z /proc/uptime"""
    try:
        with open('/proc/uptime', 'r') as f:
            return int(float(f.readline().split()[0]))
    except Exception:
        return None

def get_smart_status():
    """SMART health, refreshed once per HEAVY_OP_INTERVAL_HOURS. smartctl wakes
    drives and costs 50-300 ms each; running it every minute was the single
    most expensive thing this agent did, for a value that changes about never."""
    cache_file = os.path.join(STATE_DIR, 'vps_agent_smart_cache.json')
    ttl = max(1, HEAVY_OP_INTERVAL_HOURS) * 3600
    try:
        if time.time() - os.path.getmtime(cache_file) < ttl:
            with open(cache_file, 'r') as f:
                cached = json.load(f)
            if isinstance(cached, dict) and isinstance(cached.get('smart'), str):
                return cached['smart']
    except Exception:
        pass
    result = _probe_smart_status()
    try:
        _atomic_write_json(cache_file, {'smart': result})
    except Exception:
        pass
    return result


def _probe_smart_status():
    try:
        drives = sorted(d for d in os.listdir('/sys/class/block')
                        if _WHOLE_DISK_RE.match(d) and os.path.exists(f'/sys/class/block/{d}/device'))
    except Exception:
        return "N/A"
    if not drives:
        return "OK (Nebyly detekovány fyzické disky)"
    failed = []
    unknown = []
    for drive in drives:
        try:
            # -n standby: do not spin a sleeping drive up just to ask how it feels.
            res = subprocess.run(['smartctl', '-H', '-n', 'standby', f'/dev/{drive}'],
                                 capture_output=True, text=True, timeout=20)
        except FileNotFoundError:
            return "N/A (smartctl chybí)"
        except Exception:
            unknown.append(drive)
            continue
        out = res.stdout
        # Exit-status bit 3 is "DISK FAILING" (smartctl(8)). ATA drives print
        # PASSED/FAILED, SCSI/SAS ones "SMART Health Status: OK" or a failure text.
        if (res.returncode & 8) or 'FAILED' in out or ('Health Status:' in out and 'Health Status: OK' not in out):
            failed.append(drive)
        elif 'PASSED' in out or 'Health Status: OK' in out:
            continue
        else:
            # No verdict: virtio disk, unsupported bridge, not root, standby.
            unknown.append(drive)
    # A failing disk wins even when another gave no verdict - an early return
    # on the first silent drive used to hide the failing one behind it.
    if failed:
        return f"WARNING (Disk /dev/{failed[0]} selhal v SMART)"
    if unknown:
        return "N/A (SMART nedostupné pro /dev/" + ", /dev/".join(unknown) + ")"
    return "OK"

def get_os_version():
    """Zjistí název a verzi operačního systému ze souboru /etc/os-release"""
    try:
        os_release = '/etc/os-release'
        if DOCKER_MODE and os.path.exists(HOST_ROOT + '/etc/os-release'):
            # V kontejneru chceme OS hostitele, ne base image
            os_release = HOST_ROOT + '/etc/os-release'
        if os.path.exists(os_release):
            with open(os_release, 'r') as f:
                for line in f:
                    if line.startswith('PRETTY_NAME='):
                        return line.split('=')[1].strip().strip('"')
        import platform
        return f"{platform.system()} {platform.release()}"
    except Exception:
        return "Linux"

def get_listening_ports():
    """Zjistí naslouchající porty (TCP i UDP) z /proc/net/"""
    ports = set()
    try:
        for proto in ['tcp', 'tcp6', 'udp', 'udp6']:
            path = f'/proc/net/{proto}'
            if os.path.exists(path):
                with open(path, 'r') as f:
                    lines = f.readlines()[1:]
                    for line in lines:
                        parts = line.strip().split()
                        if len(parts) >= 4:
                            state = parts[3]
                            if state in ['0A', '07']:  # TCP_LISTEN (0A) nebo UDP active socket (07)
                                local_address = parts[1]
                                local_port_hex = local_address.split(':')[1]
                                local_port = int(local_port_hex, 16)
                                if 0 < local_port < 65536:
                                    ports.add(local_port)
    except Exception:
        pass
    return sorted(list(ports))

def get_running_processes():
    """Vrací seznam názvů běžících procesů z /proc"""
    processes = set()
    try:
        for pid in os.listdir('/proc'):
            if pid.isdigit():
                try:
                    with open(os.path.join('/proc', pid, 'comm'), 'r') as f:
                        comm = f.read().strip()
                        if comm:
                            processes.add(comm)
                except (IOError, OSError):
                    continue
    except Exception:
        pass
    return list(processes)

def get_ts3_process_info():
    """
    Najde proces ts3server a vrátí jeho PID/CPU/RAM/vlákna/otevřené FD/uptime.
    Vrací None, pokud proces neběží. Detekce restartu (změna PID mezi hlášeními)
    se dělá na serveru (agent_api.php), ne tady - agent jen hlásí aktuální stav.
    """
    pid = None
    try:
        for entry in os.listdir('/proc'):
            if not entry.isdigit():
                continue
            try:
                with open(f'/proc/{entry}/comm', 'r') as f:
                    if f.read().strip() == 'ts3server':
                        pid = entry
                        break
            except (IOError, OSError):
                continue
    except Exception:
        pass

    if pid is None:
        return None

    # Unmeasured is None: CPU needs a previous sample of the same PID, the
    # rest needs a readable /proc entry (not always the case without root).
    result = {"pid": int(pid), "cpu": None, "ram_mb": None, "threads": None, "open_fds": None, "uptime_sec": None}

    try:
        clk_tck = os.sysconf('SC_CLK_TCK')
    except Exception:
        clk_tck = 100

    def read_proc_stat(p):
        try:
            with open(f'/proc/{p}/stat', 'r') as f:
                raw = f.read()
            # comm je v závorkách a může obsahovat mezery i závorky - proto se hledá
            # poslední ')' (doporučený způsob parsování dle proc(5))
            after_comm = raw[raw.rfind(')') + 2:]
            fields = after_comm.split()
            utime = int(fields[11])       # pole 14 (utime)
            stime = int(fields[12])       # pole 15 (stime)
            starttime = int(fields[19])   # pole 22 (starttime)
            return utime, stime, starttime
        except Exception:
            return None

    stat2 = read_proc_stat(pid)
    # One fixed file with the PID inside - the old per-PID name left a new
    # file in /tmp after every ts3server restart, forever.
    state_file = os.path.join(STATE_DIR, 'vps_agent_ts3_state.json')
    now_ts = time.time()
    prev_state = None
    if os.path.exists(state_file):
        try:
            with open(state_file, 'r') as f:
                prev_state = json.load(f)
            if str(prev_state.get('pid')) != str(pid):
                prev_state = None
        except Exception:
            pass

    try:
        if stat2:
            _atomic_write_json(state_file, {'ts': now_ts, 'pid': str(pid), 'stat': stat2})
    except Exception:
        pass

    if stat2 and prev_state and 'stat' in prev_state:
        stat1 = prev_state['stat']
        elapsed = max(0.1, now_ts - prev_state.get('ts', now_ts))
        cpu_ticks_delta = (stat2[0] + stat2[1]) - (stat1[0] + stat1[1])
        if cpu_ticks_delta >= 0:
            result["cpu"] = round(((cpu_ticks_delta / clk_tck) / elapsed) * 100, 1)
    if stat2:
        # Uptime comes from the process start time alone - it never needed the
        # previous sample, yet it used to be 0 until the second run.
        try:
            with open('/proc/uptime', 'r') as f:
                host_uptime = float(f.readline().split()[0])
            result["uptime_sec"] = max(0, int(host_uptime - (stat2[2] / clk_tck)))
        except Exception:
            pass

    try:
        with open(f'/proc/{pid}/status', 'r') as f:
            for line in f:
                if line.startswith('VmRSS:'):
                    result["ram_mb"] = round(int(line.split()[1]) / 1024, 1)
                elif line.startswith('Threads:'):
                    result["threads"] = int(line.split()[1])
    except Exception:
        pass

    try:
        result["open_fds"] = len(os.listdir(f'/proc/{pid}/fd'))
    except Exception:
        pass

    return result

def get_local_teamspeak_servers(ports):
    """Dotáže se lokálního ServerQuery portu a získá info o virtual serverech"""
    import socket
    import re
    servers = []
    for q_port in [10011, 8219]:
        if q_port in ports:
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(2)
                s.connect(('127.0.0.1', q_port))
                s.recv(1024)
                s.recv(1024)
                s.sendall(b"serverlist\nquit\n")
                
                response = ""
                while True:
                    chunk = s.recv(4096).decode('utf-8')
                    if not chunk:
                        break
                    response += chunk
                    if "error id=" in chunk:
                        break
                s.close()
                
                for part in response.split('|'):
                    if 'virtualserver_port=' in part:
                        p_match = re.search(r'virtualserver_port=(\d+)', part)
                        c_match = re.search(r'virtualserver_clientsonline=(\d+)', part)
                        m_match = re.search(r'virtualserver_maxclients=(\d+)', part)
                        n_match = re.search(r'virtualserver_name=([^\s]+)', part)
                        
                        if p_match and c_match and m_match:
                            name = n_match.group(1).replace(r'\s', ' ').replace(r'\p', '|') if n_match else ""
                            servers.append({
                                "port": int(p_match.group(1)),
                                "clients_online": int(c_match.group(1)),
                                "clients_max": int(m_match.group(1)),
                                "name": name
                            })
                break
            except Exception:
                pass
    return servers


def self_update(update_info):
    """
    Aktualizace agenta na novější verzi ze serveru.

    Bezpečnostní pojistky: soubor se stahuje do dočasného souboru, ověřuje se
    SHA-256 checksum z API odpovědi i syntaxe (py_compile) a teprve poté se
    atomicky nahradí běžící skript. Při jakémkoli selhání zůstává původní verze.
    """
    import hashlib
    import py_compile
    import tempfile

    url = update_info.get("update_url", "")
    expected_sha = update_info.get("update_sha256", "")
    latest = update_info.get("latest_version", "?")

    if not url or not expected_sha:
        return False

    self_path = os.path.abspath(__file__)
    log_message(f"K dispozici je nová verze agenta {latest} (aktuální {AGENT_VERSION}), stahuji z {url}...")

    try:
        with urllib.request.urlopen(url, timeout=15) as response:
            new_source = response.read()

        actual_sha = hashlib.sha256(new_source).hexdigest()
        if actual_sha != expected_sha:
            log_message(f"CHYBA UPDATE: Checksum nesouhlasí (očekáván {expected_sha}, stažen {actual_sha}). Aktualizace zrušena.")
            return False

        tmp_fd, tmp_path = tempfile.mkstemp(suffix='.py', dir=os.path.dirname(self_path))
        try:
            with os.fdopen(tmp_fd, 'wb') as f:
                f.write(new_source)

            py_compile.compile(tmp_path, doraise=True)

            os.chmod(tmp_path, 0o755)
            backup_path = self_path + '.bak'
            try:
                with open(self_path, 'rb') as src, open(backup_path, 'wb') as dst:
                    dst.write(src.read())
            except Exception:
                pass

            os.replace(tmp_path, self_path)
            log_message(f"OK: Agent aktualizován na verzi {latest}. Nová verze se použije při příštím spuštění.")
            return True
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
    except Exception as e:
        log_message(f"CHYBA UPDATE: Aktualizace se nezdařila: {e}")
        return False


def send_action_result(action_id, status, message):
    """Potvrzení výsledku vzdálené akce zpět na server. Bez tohohle by
    agent_actions.status zůstal navždy na 'sent' v administraci, i když se
    akce provedla - stejný kontrakt jako send_action_result() v agent.sh
    a agent_openwrt.sh (agent_api.php větev action_result)."""
    payload = {
        "agent_key": AGENT_KEY,
        "action_result": {
            "action_id": int(action_id),
            "status": status,
            "message": message,
        },
    }
    req = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )
    try:
        with urllib.request.urlopen(req, timeout=10):
            pass
    except Exception as e:
        log_message(f"VAROVÁNÍ: Potvrzení akce {action_id} se nepodařilo odeslat: {e}")


def handle_remote_action(res_body):
    """Zpracování HMAC-podepsané vzdálené akce z odpovědi serveru. Opt-in přes
    REMOTE_ACTIONS_ENABLED=1; whitelist v ALLOWED_ACTIONS; podpis se ověřuje
    proti "action={a}|ts={t}|nonce={n}" klíčem agenta a platí max. 30 s -
    identická logika jako v shell agentech, jen s poctivým JSON parsováním
    místo awk. Každá větev (úspěch i odmítnutí) hlásí výsledek zpět."""
    try:
        data = json.loads(res_body)
    except ValueError:
        return

    # Server akci posílá zanořenou v "pending_action" (viz agent_api.php);
    # top-level fallback jen pro případ budoucí změny formátu.
    act = data.get("pending_action") if isinstance(data.get("pending_action"), dict) else data

    act_id = act.get("action_id")
    act_type = act.get("action")
    act_ts = act.get("timestamp")
    act_sig = act.get("signature")
    act_nonce = act.get("nonce", "")

    if not act_id or not act_type or not act_ts or not act_sig:
        return

    if abs(int(time.time()) - int(act_ts)) > 30:
        log_message("VAROVÁNÍ: Odmítnuta vzdálená akce - vypršená platnost (časové okno > 30s)")
        send_action_result(act_id, "failed", "Vypršela platnost podpisu (>30s)")
        return

    allowed = [a.strip() for a in ALLOWED_ACTIONS.split(",") if a.strip()]
    if act_type not in allowed:
        log_message(f"VAROVÁNÍ: Odmítnuta vzdálená akce '{act_type}' - není na seznamu ALLOWED_ACTIONS!")
        send_action_result(act_id, "failed", f"Akce '{act_type}' není v ALLOWED_ACTIONS")
        return

    calc_str = f"action={act_type}|ts={act_ts}|nonce={act_nonce}"
    calc_sig = hmac.new(AGENT_KEY.encode('utf-8'), calc_str.encode('utf-8'), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(calc_sig, str(act_sig)):
        log_message("VAROVÁNÍ: Odmítnuta vzdálená akce - neplatný HMAC podpis!")
        send_action_result(act_id, "failed", "Neplatný HMAC podpis")
        return

    log_message(f"Aktivována bezpečná vzdálená akce: {act_type} (ID: {act_id})")

    if act_type == "restart_service":
        svc_name = str(act.get("service_name") or data.get("service_name") or "").strip()
        # Jméno služby jde do shellového příkazu - povolit jen bezpečné znaky,
        # i když je podepsané serverem (obrana do hloubky).
        if not svc_name or not re.fullmatch(r'[A-Za-z0-9_.@-]+', svc_name):
            send_action_result(act_id, "failed", "Chybí nebo je neplatné service_name v payloadu akce")
            return
        try:
            if subprocess.call(["systemctl", "restart", svc_name],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120) == 0:
                log_message(f"Restartována služba přes systemctl: {svc_name}")
                send_action_result(act_id, "executed", f"Služba '{svc_name}' restartována přes systemctl")
                return
        except subprocess.TimeoutExpired:
            # subprocess.call kills the client and raises; without this the
            # exception escaped to main(), the agent exited 1 and the action
            # stayed "sent" on the server forever.
            send_action_result(act_id, "failed", f"Restart '{svc_name}' přes systemctl nedoběhl do 120 s")
            return
        except OSError:
            pass
        init_script = f"/etc/init.d/{svc_name}"
        if os.access(init_script, os.X_OK):
            try:
                subprocess.call([init_script, "restart"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
            except (subprocess.TimeoutExpired, OSError) as e:
                send_action_result(act_id, "failed", f"Restart '{svc_name}' přes init.d selhal: {e}")
                return
            log_message(f"Restartována služba přes init.d: {svc_name}")
            send_action_result(act_id, "executed", f"Služba '{svc_name}' restartována přes init.d")
        else:
            log_message(f"VAROVÁNÍ: Služba '{svc_name}' nenalezena nebo není spustitelná.")
            send_action_result(act_id, "failed", f"Služba '{svc_name}' nenalezena nebo není spustitelná")
    elif act_type == "reboot_server":
        log_message("PROVÁDÍM REBOOT SERVERU DLE PODEPSANÉHO POKYNU...")
        # Potvrzení musí odejít PŘED rebootem - jakmile reboot ukončí proces,
        # už se nic dalšího neprovede.
        send_action_result(act_id, "executed", "Server se restartuje")
        for cmd in (["/sbin/reboot"], ["systemctl", "reboot"]):
            try:
                if subprocess.call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120) == 0:
                    break
            except (subprocess.TimeoutExpired, OSError):
                continue


def get_discovered_services(ports, processes):
    """Detekce běžících služeb podle portů/procesů/konfiguračních souborů.
    Vrací seznam dictů: {name, type, port, confidence, evidence, missing}.
    Confidence je součet bodů (process=30, port=25, config=25, active=19), max 99."""
    cache_file = os.path.join(STATE_DIR, 'vps_agent_services_cache.json')
    now_ts = time.time()
    cache_ttl = HEAVY_OP_INTERVAL_HOURS * 3600

    if os.path.exists(cache_file):
        try:
            mtime = os.path.getmtime(cache_file)
            if (now_ts - mtime) < cache_ttl:
                with open(cache_file, 'r') as f:
                    return json.load(f)
        except Exception:
            pass

    detectors = [
        # (name, type, port, process_pattern, config_paths)
        ("TeamSpeak", "teamspeak", 10011, "ts3server", ["/etc/ts3server.ini", "/opt/teamspeak3/ts3server.ini"]),
        ("Minecraft", "minecraft", 25565, "java", []),
        ("Nginx", "nginx", 80, "nginx", ["/etc/nginx/nginx.conf"]),
        ("Docker", "docker", None, "dockerd", ["/var/run/docker.sock"]),
        ("PostgreSQL", "postgresql", 5432, "postgres", ["/etc/postgresql", "/var/lib/pgsql/data/postgresql.conf"]),
        ("AdGuard Home", "adguard", 3000, "AdGuardHome", ["/opt/AdGuardHome/AdGuardHome.yaml", "/etc/AdGuardHome.yaml"]),
        ("WireGuard", "wireguard", 51820, None, ["/etc/wireguard", "/etc/config/wireguard"]),
        ("Mosquitto", "mosquitto", 1883, "mosquitto", ["/etc/mosquitto/mosquitto.conf", "/etc/mosquitto.conf"]),
    ]

    results = []
    for name, stype, port, proc_pattern, config_paths in detectors:
        confidence = 0
        evidence = []
        missing = []

        # 1. Process detection (30 pts)
        if proc_pattern and proc_pattern in processes:
            confidence += 30
            evidence.append("process")
        elif proc_pattern:
            missing.append("process")

        # 2. Port detection (25 pts)
        if port and port in ports:
            confidence += 25
            evidence.append("port")
        elif port:
            missing.append("port")

        # 3. Config file (25 pts)
        config_found = False
        for cp in config_paths:
            if os.path.exists(cp):
                config_found = True
                break
        if config_found:
            confidence += 25
            evidence.append("config")
        elif config_paths:
            missing.append("config")

        # 4. Active verification (19 pts) - lightweight check
        active_ok = False
        try:
            if stype == "wireguard":
                # Check if wg0 interface exists
                if os.path.exists("/sys/class/net/wg0"):
                    active_ok = True
            elif stype == "docker":
                if os.path.exists("/var/run/docker.sock"):
                    active_ok = True
            elif stype == "minecraft" and proc_pattern in processes:
                # Verify java has minecraft-related args
                for pid in os.listdir('/proc'):
                    if not pid.isdigit():
                        continue
                    try:
                        with open(f'/proc/{pid}/cmdline', 'rb') as f:
                            cmdline = f.read().decode('utf-8', errors='ignore')
                        if 'minecraft' in cmdline or 'paper' in cmdline or 'spigot' in cmdline or 'purpur' in cmdline:
                            active_ok = True
                            break
                    except (IOError, OSError):
                        continue
            elif port and port in ports:
                # Port is listening = active
                active_ok = True
        except Exception:
            pass

        if active_ok:
            confidence += 19
            evidence.append("active_verify")
        else:
            missing.append("active_verify")

        # Cap at 99
        confidence = min(confidence, 99)

        # Only report if at least some evidence found
        if confidence >= 25:
            results.append({
                "name": name,
                "type": stype,
                "port": port,
                "confidence": confidence,
                "evidence": evidence,
                "missing": missing,
            })

    try:
        with open(cache_file, 'w') as f:
            json.dump(results, f)
    except Exception:
        pass

    return results


def main():
    global AUTO_UPDATE, VERBOSE, DRY_RUN

    for arg in sys.argv[1:]:
        if arg in ('--help', '-h'):
            print(f"Python VPS Status Agent v{AGENT_VERSION}")
            print(f"Použití: {sys.argv[0]} [MOŽNOSTI]")
            print("\nMožnosti:")
            print("  --update, --auto-update      Vynutí kontrolu a aktualizaci agenta ze serveru")
            print("  --dry-run, --print           Sesbírá data a vypíše JSON, neodesílá (i bez klíče)")
            print("  --verbose, -v                Zobrazí podrobný průbeh sběru dat a odesílání")
            print("  --version, -V                Zobrazí verzi agenta")
            print("  --help, -h                   Zobrazí tuto nápovědu")
            print("\nKonfigurace:")
            print("  Čte nastavení ze souboru agent.cfg nebo proměnných prostředí:")
            print("  STATUS_API_URL, STATUS_AGENT_KEY, STATUS_AUTO_UPDATE, STATUS_HEAVY_OP_INTERVAL_HOURS,")
            print("  STATUS_REMOTE_ACTIONS_ENABLED, STATUS_ALLOWED_ACTIONS")
            sys.exit(0)
        elif arg in ('--version', '-V'):
            print(f"Python VPS Status Agent v{AGENT_VERSION}")
            sys.exit(0)
        elif arg in ('--update', '--auto-update'):
            AUTO_UPDATE = True
            VERBOSE = True
        elif arg in ('--verbose', '-v'):
            VERBOSE = True
        elif arg in ('--dry-run', '--print'):
            DRY_RUN = True
            VERBOSE = True

    if AGENT_KEY == "ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE" and not DRY_RUN:
        log_message("CHYBA: Nebyl nastaven AGENT_KEY. Upravte skript nebo 'agent.cfg'.")
        sys.exit(1)

    # One run at a time: a report stalled on a dead server must not let cron
    # stack a fresh agent on top of it every minute.
    lock_fh = None
    try:
        import fcntl
        lock_fh = open(os.path.join(STATE_DIR, 'vps_agent.lock'), 'w')
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (ImportError, OSError):
        if lock_fh is not None:
            log_message("Předchozí běh ještě běží, tento končím.")
            sys.exit(0)

    log_debug("Získávám systémové statistiky...")
    cpu, cpu_steal, iowait = get_cpu_usage()
    ram = get_ram_usage()
    swap = get_swap_usage()
    hdd = get_hdd_usage()
    inode_usage = get_inode_usage()
    load1, load5, load15 = get_load_average()
    disk_read, disk_write = get_disk_io()
    net, net_errors = get_network_usage()
    fork_rate = get_fork_rate()
    temperature = get_temperature()
    uptime = get_uptime()
    smart = get_smart_status()
    ports = get_listening_ports()
    processes = get_running_processes()
    os_ver = get_os_version()
    identity = get_system_identity()
    teamspeak_servers = get_local_teamspeak_servers(ports)
    ts3_process = get_ts3_process_info()
    zombie_count, top_cpu_processes, top_ram_processes = get_process_snapshot()
    discovered_services = get_discovered_services(ports, processes)
    # These three lived inside send_action_result() by mistake, so main()
    # died with NameError on ram_total_mb before it ever built a payload -
    # the Python agent has not delivered a single report since they were added.
    ts_up, ts_peers = get_tailscale()
    ups_status, ups_battery = get_ups()
    ram_total_mb, ram_used_mb, ram_available_mb, ram_free_mb = get_ram_detail_mb()

    payload = {
        "agent_key": AGENT_KEY,
        "agent_type": "python",
        "version": AGENT_VERSION,
        "heavy_op_interval_hours": HEAVY_OP_INTERVAL_HOURS,
        "os": os_ver,
        "cpu": cpu,
        "cpu_steal": cpu_steal,
        "iowait": iowait,
        "ram": ram,
        "swap": swap,
        "hdd": hdd,
        "inode_usage": inode_usage,
        "load1": load1,
        "load5": load5,
        "load15": load15,
        "disk_io_read": disk_read,
        "disk_io_write": disk_write,
        "net": net,
        "net_errors": net_errors,
        "fork_rate": fork_rate,
        "temperature": temperature,
        "uptime": uptime,
        "smart": smart,
        "ports": ports,
        "processes": sorted(processes),
        "teamspeak_servers": teamspeak_servers,
        "ts3_process": ts3_process,
        "zombie_count": zombie_count,
        "top_cpu_processes": top_cpu_processes,
        "top_ram_processes": top_ram_processes,
        "hostname": identity['hostname'],
        "kernel": identity['kernel'],
        "timezone": identity['timezone'],
        "reboot_required": identity['reboot_required'],
        "cloud_provider": identity['cloud_provider'],
        "virtualization": identity['virtualization'],
        "ram_total_mb": ram_total_mb,
        "ram_used_mb": ram_used_mb,
        "ram_available_mb": ram_available_mb,
        "ram_free_mb": ram_free_mb,
        "tcp_retrans": get_tcp_retrans(),
        "conntrack_count": get_conntrack_count(),
        "auto_update": 1 if AUTO_UPDATE else 0,
        "oom_kills": get_oom_kills(),
        "tailscale_up": ts_up,
        "tailscale_peers": ts_peers,
        "zerotier_networks": get_zerotier_networks(),
        "ups_status": ups_status,
        "ups_battery_pct": ups_battery,
        "boot_time": int(time.time() - uptime) if uptime else None,
        "dns_latency_ms": get_dns_latency_ms(),
        "openvpn_tunnels": get_openvpn_tunnels(),
        "usb_devices": get_usb_devices(),
        "discovered_services": discovered_services
    }

    if DRY_RUN:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        log_debug("Režim --dry-run: data se neodesílají.")
        return

    net_log = f"{net} KB/s" if net is not None else "N/A (první běh)"
    log_debug(f"Metriky - OS: {os_ver}, CPU: {cpu}% (steal {cpu_steal}%, iowait {iowait}%), RAM: {ram}% (swap {swap}%), HDD: {hdd}% (inode {inode_usage}%), Load: {load1}/{load5}/{load15}, Síť: {net_log}, Zombie: {zombie_count}, Uptime: {uptime}s, SMART: {smart}, Porty: {ports}")
    
    req = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )
    
    try:
        log_debug(f"Odesílám data na {API_URL}...")
        with urllib.request.urlopen(req, timeout=10) as response:
            res_code = response.getcode()
            res_body = response.read().decode('utf-8')
            
            if res_code == 200:
                log_debug("OK: Statistiky úspěšně odeslány.")
                log_debug("Odpověď: " + res_body.strip())

                # Vzdálené akce (opt-in přes REMOTE_ACTIONS_ENABLED=1) - v Docker
                # režimu nedávají smysl (kontejner nevidí systemd hostitele).
                if REMOTE_ACTIONS_ENABLED and not DOCKER_MODE:
                    handle_remote_action(res_body)

                # Automatická aktualizace agenta (opt-in přes AUTO_UPDATE=1).
                # V Docker režimu je skript připojen read-only z hostitele, tam se neaktualizuje.
                if AUTO_UPDATE and not DOCKER_MODE:
                    try:
                        res_json = json.loads(res_body)
                        if res_json.get("update_available"):
                            self_update(res_json)
                    except (ValueError, KeyError):
                        pass
            else:
                log_message(f"CHYBA: Server odpověděl kódem {res_code}.")
                log_message("Odpověď: " + res_body.strip())
                sys.exit(1)
    except Exception as e:
        log_message(f"CHYBA: Nepodařilo se navázat spojení se serverem. Detaily: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
