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
import json
import urllib.request
import subprocess

# === VÝCHOZÍ KONFIGURACE ===
# Pokud chcete, můžete tyto hodnoty nechat zde, nebo vytvořit soubor 'agent.cfg' ve stejné složce
API_URL = "http://localhost/status/agent_api.php"
AGENT_KEY = "ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE"
AUTO_UPDATE = False  # Povolení automatických aktualizací agenta ze serveru
# ===========================

# Načtení z Environment proměnných
if os.environ.get("STATUS_API_URL"):
    API_URL = os.environ.get("STATUS_API_URL")
if os.environ.get("STATUS_AGENT_KEY"):
    AGENT_KEY = os.environ.get("STATUS_AGENT_KEY")
if os.environ.get("STATUS_AUTO_UPDATE"):
    AUTO_UPDATE = os.environ.get("STATUS_AUTO_UPDATE") == "1"

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
    except Exception:
        pass

AGENT_VERSION = "1.7.0"
LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent.log')
# V Docker režimu je adresář se skriptem připojený read-only, proto se stavový
# soubor pro výpočet síťové propustnosti ukládá vždy do /tmp.
NET_STATE_FILE = '/tmp/status-agent-net.state' if DOCKER_MODE else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent_net.state')

def log_message(msg):
    ts = time.strftime('%Y-%m-%d %H:%M:%S')
    log_line = f"{ts} - {msg}\n"
    sys.stdout.write(log_line)
    try:
        with open(LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(log_line)
    except Exception:
        # Fallback to /tmp
        try:
            with open('/tmp/status-agent.log', 'a', encoding='utf-8') as f:
                f.write(log_line)
        except Exception:
            pass

def get_cpu_usage():
    """
    Vypočítá využití CPU, CPU steal time a IO wait (vše v %) z /proc/stat.
    Steal (8. pole, index 7) je čas, kdy hypervisor přidělil CPU jinému
    hostiteli - na VPS důležitý signál "sousedského rušení". IO wait (5. pole,
    index 4) je dřív počítán jen jako součást "idle", teď se hlásí zvlášť -
    vysoký iowait ukazuje na pomalý/přetížený disk, ne na volnou CPU.
    Vrací (cpu_pct, steal_pct, iowait_pct).
    """
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
        return 0, 0, 0, 0

    idle1, steal1, iowait1, total1 = read_stat()
    if total1 == 0:
        return 0.0, 0.0, 0.0

    time.sleep(1)

    idle2, steal2, iowait2, total2 = read_stat()
    idle_delta = idle2 - idle1
    steal_delta = steal2 - steal1
    iowait_delta = iowait2 - iowait1
    total_delta = total2 - total1

    if total_delta == 0:
        return 0.0, 0.0, 0.0

    cpu_pct = round((1.0 - idle_delta / total_delta) * 100, 1)
    steal_pct = round((steal_delta / total_delta) * 100, 1)
    iowait_pct = round((iowait_delta / total_delta) * 100, 1)
    return cpu_pct, steal_pct, iowait_pct

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
            return 0.0
        
        return round((used / total) * 100, 1)
    except Exception:
        return 0.0

def get_swap_usage():
    """Vypočítá využití swapu v % z /proc/meminfo. Vrací 0.0, pokud swap není nakonfigurovaný."""
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
            return 0.0
        return round(((total - free) / total) * 100, 1)
    except Exception:
        return 0.0

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
            return 0.0

        return round((used / total) * 100, 1)
    except Exception:
        return 0.0

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
    try:
        with open('/proc/diskstats', 'r') as f:
            for line in f:
                fields = line.split()
                if len(fields) < 10:
                    continue
                if not _WHOLE_DISK_RE.match(fields[2]):
                    continue
                read_total += int(fields[5])   # sectors read
                write_total += int(fields[9])  # sectors written
    except Exception:
        pass
    return read_total, write_total

def get_disk_io():
    """
    Vypočítá průměrnou I/O propustnost disku (čtení/zápis) v KB/s od posledního běhu.
    Stejný tick/tock princip jako get_network_usage() - první běh vrací (None, None).
    """
    read_sectors, write_sectors = get_disk_io_sectors()
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
    """
    Statická identita hostitele (mění se zřídka, na rozdíl od CPU/RAM/disk čísel):
    hostname, kernel, timezone, reboot-required, cloud provider (best-effort dle
    DMI řetězců), virtualizace. Vrací dict, chybějící/nedetekovatelné hodnoty None.
    """
    identity = {
        'hostname': None, 'kernel': None, 'timezone': None,
        'reboot_required': None, 'cloud_provider': None, 'virtualization': None,
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
        if os.path.exists('/etc/timezone'):
            with open('/etc/timezone', 'r') as f:
                identity['timezone'] = f.read().strip()
        elif os.path.islink('/etc/localtime'):
            link = os.readlink('/etc/localtime')
            identity['timezone'] = link.split('zoneinfo/')[-1] if 'zoneinfo/' in link else None
    except Exception:
        pass

    try:
        identity['reboot_required'] = os.path.exists('/var/run/reboot-required')
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

    stats1 = read_all_stats()
    time.sleep(1)
    stats2 = read_all_stats()

    zombie_count = sum(1 for state, _ in stats2.values() if state == 'Z')

    cpu_deltas = []
    try:
        clk_tck = os.sysconf('SC_CLK_TCK')
    except Exception:
        clk_tck = 100
    for pid, (state, ticks2) in stats2.items():
        if pid not in stats1 or state == 'Z':
            continue
        ticks1 = stats1[pid][1]
        delta_ticks = ticks2 - ticks1
        if delta_ticks <= 0:
            continue
        cpu_pct = round((delta_ticks / clk_tck) * 100, 1)
        try:
            with open(f'/proc/{pid}/comm', 'r') as f:
                name = f.read().strip()
        except Exception:
            name = f'pid-{pid}'
        cpu_deltas.append({'name': name, 'cpu': cpu_pct})

    cpu_deltas.sort(key=lambda x: x['cpu'], reverse=True)
    top_cpu = cpu_deltas[:limit]

    ram_list = []
    for pid in stats2:
        try:
            with open(f'/proc/{pid}/status', 'r') as f:
                rss_kb = None
                name = f'pid-{pid}'
                for line in f:
                    if line.startswith('VmRSS:'):
                        rss_kb = int(line.split()[1])
                    elif line.startswith('Name:'):
                        name = line.split(None, 1)[1].strip()
                if rss_kb:
                    ram_list.append({'name': name, 'ram_mb': round(rss_kb / 1024, 1)})
        except Exception:
            continue

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
    net_errors = max(0, delta_errors)
    return net_kbps, net_errors

def get_uptime():
    """Uuptime v sekundách z /proc/uptime"""
    try:
        with open('/proc/uptime', 'r') as f:
            return int(float(f.readline().split()[0]))
    except Exception:
        return 0

def get_smart_status():
    """Kontrola stavu disků přes smartctl (pokud je dostupné)"""
    try:
        drives = []
        if os.path.exists('/sys/class/block'):
            for dev in os.listdir('/sys/class/block'):
                if dev.startswith('sd') or dev.startswith('nvme') or dev.startswith('vd'):
                    if os.path.exists(f'/sys/class/block/{dev}/device') and not dev[-1].isdigit():
                        drives.append(dev)
        
        if not drives:
            return "OK (Nebyly detekovány fyzické disky)"
            
        for drive in drives:
            res = subprocess.run(['smartctl', '-H', f'/dev/{drive}'], capture_output=True, text=True)
            if res.returncode != 0:
                if "not found" in res.stderr or res.returncode == 127:
                    return "N/A (smartctl chybí)"
                if "PASSED" not in res.stdout:
                    return f"WARNING (Disk /dev/{drive} selhal v SMART)"
        return "OK"
    except Exception:
        return "N/A"

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

    result = {"pid": int(pid), "cpu": 0.0, "ram_mb": 0.0, "threads": 0, "open_fds": 0, "uptime_sec": 0}

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

    stat1 = read_proc_stat(pid)
    time.sleep(1)
    stat2 = read_proc_stat(pid)

    if stat1 and stat2:
        cpu_ticks_delta = (stat2[0] + stat2[1]) - (stat1[0] + stat1[1])
        result["cpu"] = round((cpu_ticks_delta / clk_tck) * 100, 1)
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


def get_discovered_services(ports, processes):
    """Detekce běžících služeb podle portů/procesů/konfiguračních souborů.
    Vrací seznam dictů: {name, type, port, confidence, evidence, missing}.
    Confidence je součet bodů (process=30, port=25, config=25, active=19), max 99."""
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

    return results


def main():
    if AGENT_KEY == "ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE":
        log_message("CHYBA: Nebyl nastaven AGENT_KEY. Upravte skript nebo 'agent.cfg'.")
        sys.exit(1)

    log_message("Získávám systémové statistiky...")
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

    payload = {
        "agent_key": AGENT_KEY,
        "agent_type": "python",
        "version": AGENT_VERSION,
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
        "processes": processes,
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
        "discovered_services": discovered_services
    }

    net_log = f"{net} KB/s" if net is not None else "N/A (první běh)"
    log_message(f"Metriky - OS: {os_ver}, CPU: {cpu}% (steal {cpu_steal}%, iowait {iowait}%), RAM: {ram}% (swap {swap}%), HDD: {hdd}% (inode {inode_usage}%), Load: {load1}/{load5}/{load15}, Síť: {net_log}, Zombie: {zombie_count}, Uptime: {uptime}s, SMART: {smart}, Porty: {ports}")
    
    req = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )
    
    try:
        log_message(f"Odesílám data na {API_URL}...")
        with urllib.request.urlopen(req, timeout=10) as response:
            res_code = response.getcode()
            res_body = response.read().decode('utf-8')
            
            if res_code == 200:
                log_message("OK: Statistiky úspěšně odeslány.")
                log_message("Odpověď: " + res_body.strip())

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
