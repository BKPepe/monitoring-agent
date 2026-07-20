#!/usr/bin/env python3
"""
Blood Kings Status Monitoring - VPS Agent (Python 3 Version)
Tento skript spouštějte na vašem VPS (např. přes cron každých 5 minut).
Nevyžaduje žádné externí knihovny (pouze standardní Python 3).
"""

import os
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

AGENT_VERSION = "1.3.0"
LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent.log')

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
    """Vypočítá využití CPU z /proc/stat"""
    def read_stat():
        try:
            with open('/proc/stat', 'r') as f:
                lines = f.readlines()
            for line in lines:
                if line.startswith('cpu '):
                    fields = [float(x) for x in line.strip().split()[1:]]
                    idle = fields[3] + fields[4]  # idle + iowait
                    total = sum(fields)
                    return idle, total
        except IOError:
            pass
        return 0, 0

    idle1, total1 = read_stat()
    if total1 == 0:
        return 0.0
    
    time.sleep(1)
    
    idle2, total2 = read_stat()
    idle_delta = idle2 - idle1
    total_delta = total2 - total1
    
    if total_delta == 0:
        return 0.0
    
    return round((1.0 - idle_delta / total_delta) * 100, 1)

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
    """Zjistí naslouchající porty z /proc/net/tcp a tcp6"""
    ports = set()
    try:
        for proto in ['tcp', 'tcp6']:
            path = f'/proc/net/{proto}'
            if os.path.exists(path):
                with open(path, 'r') as f:
                    lines = f.readlines()[1:]
                    for line in lines:
                        parts = line.strip().split()
                        if len(parts) >= 4:
                            state = parts[3]
                            if state == '0A':  # TCP_LISTEN
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


def main():
    if AGENT_KEY == "ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE":
        log_message("CHYBA: Nebyl nastaven AGENT_KEY. Upravte skript nebo 'agent.cfg'.")
        sys.exit(1)

    log_message("Získávám systémové statistiky...")
    cpu = get_cpu_usage()
    ram = get_ram_usage()
    hdd = get_hdd_usage()
    uptime = get_uptime()
    smart = get_smart_status()
    ports = get_listening_ports()
    processes = get_running_processes()
    os_ver = get_os_version()
    teamspeak_servers = get_local_teamspeak_servers(ports)
    
    payload = {
        "agent_key": AGENT_KEY,
        "agent_type": "python",
        "version": AGENT_VERSION,
        "os": os_ver,
        "cpu": cpu,
        "ram": ram,
        "hdd": hdd,
        "uptime": uptime,
        "smart": smart,
        "ports": ports,
        "processes": processes,
        "teamspeak_servers": teamspeak_servers
    }
    
    log_message(f"Metriky - OS: {os_ver}, CPU: {cpu}%, RAM: {ram}%, HDD: {hdd}%, Uptime: {uptime}s, SMART: {smart}, Porty: {ports}")
    
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
