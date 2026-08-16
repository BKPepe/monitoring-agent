param(
    [alias("h")][switch]$Help,
    [alias("v")][switch]$Version,
    [switch]$Update
)

$AGENT_VERSION = "1.7.3"

if ($Help) {
    Write-Host "Windows PowerShell Status Agent v$AGENT_VERSION"
    Write-Host "Použití: .\agent.ps1 [MOŽNOSTI]"
    Write-Host ""
    Write-Host "Možnosti:"
    Write-Host "  -Help, -h      Zobrazí tuto nápovědu"
    Write-Host "  -Version, -v   Zobrazí verzi agenta"
    Write-Host "  -Update        Vynutí kontrolu a aktualizaci agenta ze serveru"
    Write-Host "  -Verbose       Zobrazí podrobný průběh sběru dat"
    Write-Host ""
    Write-Host "Konfigurace:"
    Write-Host "  Čte nastavení ze souboru agent.cfg nebo z proměnných prostředí:"
    Write-Host "  STATUS_API_URL, STATUS_AGENT_KEY, STATUS_AUTO_UPDATE,"
    Write-Host "  STATUS_REMOTE_ACTIONS_ENABLED, STATUS_ALLOWED_ACTIONS"
    exit 0
}

if ($Version) {
    Write-Host "Windows PowerShell Status Agent v$AGENT_VERSION"
    exit 0
}

# === VÝCHOZÍ KONFIGURACE ===
# Hodnoty můžete nechat zde, nebo vytvořit soubor 'agent.cfg' ve stejné složce
$API_URL = "http://localhost/status/agent_api.php"
$AGENT_KEY = "ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE"
$AUTO_UPDATE = "0" # Nastavte na "1" pro povolení automatických aktualizací agenta ze serveru
$REMOTE_ACTIONS_ENABLED = "0" # Opt-in: povolení HMAC-podepsaných vzdálených akcí ze serveru
$ALLOWED_ACTIONS = "restart_service,reboot_server" # Whitelist povolených akcí (čárkou oddělené)
# ===========================

if ($Update) { $AUTO_UPDATE = "1" }

# Načtení z Environment proměnných
if ($env:STATUS_API_URL) { $API_URL = $env:STATUS_API_URL }
if ($env:STATUS_AGENT_KEY) { $AGENT_KEY = $env:STATUS_AGENT_KEY }
if ($env:STATUS_AUTO_UPDATE) { $AUTO_UPDATE = $env:STATUS_AUTO_UPDATE }
if ($env:STATUS_REMOTE_ACTIONS_ENABLED) { $REMOTE_ACTIONS_ENABLED = $env:STATUS_REMOTE_ACTIONS_ENABLED }
if ($env:STATUS_ALLOWED_ACTIONS) { $ALLOWED_ACTIONS = $env:STATUS_ALLOWED_ACTIONS }

# Načtení z externí konfigurace 'agent.cfg'
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$CfgPath = Join-Path $ScriptPath "agent.cfg"
if (Test-Path $CfgPath) {
    foreach ($line in Get-Content $CfgPath) {
        $line = $line.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $key, $val = $line.Split("=", 2)
            $key = $key.Trim()
            $val = $val.Trim().Trim('"').Trim("'")
            switch ($key) {
                "API_URL" { $API_URL = $val }
                "AGENT_KEY" { $AGENT_KEY = $val }
                "AUTO_UPDATE" { $AUTO_UPDATE = $val }
                "REMOTE_ACTIONS_ENABLED" { $REMOTE_ACTIONS_ENABLED = $val }
                "ALLOWED_ACTIONS" { $ALLOWED_ACTIONS = $val }
            }
        }
    }
}

$LogFile = Join-Path $ScriptPath "agent.log"
$NetStateFile = Join-Path $ScriptPath "agent_net.state"

function Write-AgentLog {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts - $Message"
    Write-Output $line
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        try { Add-Content -Path (Join-Path $env:TEMP "status-agent.log") -Value $line -Encoding UTF8 } catch {}
    }
}

if ($AGENT_KEY -eq "ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE") {
    Write-AgentLog "CHYBA: Nebyl nastaven AGENT_KEY. Upravte skript nebo 'agent.cfg'."
    exit 1
}

Write-AgentLog "Získávám systémové statistiky (PowerShell)..."

# --- CPU: průměrné vytížení všech procesorů ---
$cpu = 0.0
try {
    $cpuLoad = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    if ($null -ne $cpuLoad) { $cpu = [math]::Round([double]$cpuLoad, 1) }
} catch {
    try {
        $counter = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 2
        $cpu = [math]::Round(($counter.CounterSamples | Measure-Object -Property CookedValue -Average).Average, 1)
    } catch {}
}

# --- RAM: využitá fyzická paměť v % ---
$ram = 0.0
$os_info = $null
try {
    $os_info = Get-CimInstance -ClassName Win32_OperatingSystem
    $totalKb = [double]$os_info.TotalVisibleMemorySize
    $freeKb = [double]$os_info.FreePhysicalMemory
    if ($totalKb -gt 0) { $ram = [math]::Round((($totalKb - $freeKb) / $totalKb) * 100, 1) }
} catch {}

# --- Disk: zaplnění systémového disku (obvykle C:) v % ---
$hdd = 0.0
try {
    $systemDrive = $env:SystemDrive
    if (-not $systemDrive) { $systemDrive = "C:" }
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$systemDrive'"
    if ($disk -and [double]$disk.Size -gt 0) {
        $hdd = [math]::Round((([double]$disk.Size - [double]$disk.FreeSpace) / [double]$disk.Size) * 100, 1)
    }
} catch {}

# --- Swap (stránkovací soubor): využití v % ---
$swap = 0.0
try {
    $pageFiles = Get-CimInstance -ClassName Win32_PageFileUsage
    if ($pageFiles) {
        $totalAllocated = ($pageFiles | Measure-Object -Property AllocatedBaseSize -Sum).Sum
        $totalUsed = ($pageFiles | Measure-Object -Property CurrentUsage -Sum).Sum
        if ($totalAllocated -gt 0) { $swap = [math]::Round(($totalUsed / $totalAllocated) * 100, 1) }
    }
} catch {}

# --- Load average a CPU steal time nejsou na Windows k dispozici (nejde o Linux
# koncepty s přímým ekvivalentem) - záměrně se nedopočítávají ani nenahrazují
# odhadem, jen se pošlou jako $null.
$load1 = $null; $load5 = $null; $load15 = $null
$cpuSteal = $null

# --- Disk I/O (KB/s čtení/zápis), průměr za 1s vzorek přes výkonnostní čítače ---
$diskIoRead = $null
$diskIoWrite = $null
try {
    $ioCounters = Get-Counter '\PhysicalDisk(_Total)\Disk Read Bytes/sec', '\PhysicalDisk(_Total)\Disk Write Bytes/sec' -SampleInterval 1 -MaxSamples 2 -ErrorAction Stop
    $readAvg = ($ioCounters.CounterSamples | Where-Object { $_.Path -like '*read bytes*' } | Measure-Object -Property CookedValue -Average).Average
    $writeAvg = ($ioCounters.CounterSamples | Where-Object { $_.Path -like '*write bytes*' } | Measure-Object -Property CookedValue -Average).Average
    if ($null -ne $readAvg) { $diskIoRead = [math]::Round($readAvg / 1024, 1) }
    if ($null -ne $writeAvg) { $diskIoWrite = [math]::Round($writeAvg / 1024, 1) }
} catch {}

# --- Síť: propustnost (KB/s, RX+TX) a nové chyby/zahozené pakety od posledního běhu ---
# Potřebuje 2 vzorky, proto se mezi běhy ukládá kumulativní počet bajtů/chyb a čas
# do stavového souboru vedle skriptu; první běh proto vrací $null.
$net = $null
$netErrors = $null
try {
    $now = Get-Date
    $totalBytes = 0
    $totalErrors = 0
    $adapters = Get-NetAdapterStatistics -ErrorAction Stop | Where-Object { $_.Name -notmatch '^(Loopback|vEthernet|Docker|WSL)' }
    foreach ($a in $adapters) {
        $totalBytes += [int64]$a.ReceivedBytes + [int64]$a.SentBytes
        $totalErrors += [int64]$a.ReceivedPacketErrors + [int64]$a.OutboundPacketErrors + [int64]$a.ReceivedDiscardedPackets + [int64]$a.OutboundDiscardedPackets
    }

    $prev = $null
    if (Test-Path $NetStateFile) {
        try {
            $parts = (Get-Content $NetStateFile -Raw).Trim().Split(",")
            if ($parts.Count -ge 3) {
                $prev = @{ Ts = [double]$parts[0]; Bytes = [int64]$parts[1]; Errors = [int64]$parts[2] }
            } elseif ($parts.Count -eq 2) {
                $prev = @{ Ts = [double]$parts[0]; Bytes = [int64]$parts[1]; Errors = $totalErrors }
            }
        } catch {}
    }

    "$($now.ToFileTimeUtc()),$totalBytes,$totalErrors" | Set-Content -Path $NetStateFile -Encoding ASCII -ErrorAction SilentlyContinue

    if ($prev) {
        $elapsedSec = ($now.ToFileTimeUtc() - $prev.Ts) / 10000000.0
        $deltaBytes = $totalBytes - $prev.Bytes
        if ($elapsedSec -gt 0 -and $deltaBytes -ge 0) {
            $net = [math]::Round(($deltaBytes / $elapsedSec) / 1024, 1)
        }
        $deltaErrors = $totalErrors - $prev.Errors
        if ($deltaErrors -ge 0) { $netErrors = $deltaErrors }
    }
} catch {}

# --- Uptime v sekundách ---
$uptime = 0
try {
    if ($os_info) {
        $uptime = [int]((Get-Date) - $os_info.LastBootUpTime).TotalSeconds
    }
} catch {}

# --- Název a verze OS ---
$os_version = "Windows"
try {
    if ($os_info -and $os_info.Caption) { $os_version = $os_info.Caption.Trim() }
} catch {}

# --- Systémová identita (hostname/kernel/timezone/cloud/virtualizace) ---
# reboot_required, iowait, inode usage, zombie count, fork rate a teplota jsou
# Linux/proc specifické koncepty bez čistého windowsího ekvivalentu - posílají
# se jako $null (viz payload níže), ne odhadované.
$sys_hostname = $env:COMPUTERNAME
$sys_kernel = $null
try {
    if ($os_info -and $os_info.BuildNumber) { $sys_kernel = "Build $($os_info.BuildNumber)" }
} catch {}
$sys_timezone = $null
try {
    $sys_timezone = [System.TimeZoneInfo]::Local.Id
} catch {}
$cloud_provider = $null
$virtualization = $null
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $manufacturer = ($cs.Manufacturer | Out-String).Trim().ToLower()
    $model = ($cs.Model | Out-String).Trim().ToLower()
    if ($manufacturer -match "amazon") { $cloud_provider = "AWS" }
    elseif ($manufacturer -match "google") { $cloud_provider = "Google Cloud" }
    elseif ($model -match "hvm domu|xen") { $cloud_provider = "AWS" }
    if ($model -match "virtual machine" -and $manufacturer -match "microsoft") { $virtualization = "Hyper-V" }
    elseif ($manufacturer -match "vmware") { $virtualization = "VMware" }
    elseif ($model -match "kvm" -or $manufacturer -match "qemu") { $virtualization = "KVM" }
    elseif ($manufacturer -match "xen") { $virtualization = "Xen" }
} catch {}

# --- TOP procesy dle CPU a RAM ---
$topCpuProcesses = @()
$topRamProcesses = @()
try {
    $cpuCores = [Environment]::ProcessorCount
    $procSample2 = Get-Process -ErrorAction Stop | Select-Object Id, ProcessName, TotalProcessorTime, WorkingSet64
    $stateFile = Join-Path $env:TEMP "status_agent_win_proc.json"
    $nowTicks = (Get-Date).Ticks

    $prevProcMap = @{}
    $prevTicks = 0
    if (Test-Path $stateFile) {
        try {
            $json = Get-Content $stateFile -Raw | ConvertFrom-Json
            $prevTicks = $json.ticks
            foreach ($p in $json.procs) { $prevProcMap[$p.id] = $p.cpuMs }
        } catch {}
    }

    $saveList = @()
    foreach ($p in $procSample2) {
        if ($p.TotalProcessorTime) {
            $saveList += @{ id = $p.Id; cpuMs = $p.TotalProcessorTime.TotalMilliseconds }
        }
    }
    @{ ticks = $nowTicks; procs = $saveList } | ConvertTo-Json -Depth 3 | Set-Content $stateFile -ErrorAction SilentlyContinue

    if ($prevProcMap.Count -gt 0 -and $prevTicks -gt 0) {
        $elapsedSec = ($nowTicks - $prevTicks) / 10000000.0
        if ($elapsedSec -gt 0.1) {
            $cpuRanked = foreach ($p in $procSample2) {
                if ($p.TotalProcessorTime -and $prevProcMap.ContainsKey($p.Id)) {
                    $deltaMs = $p.TotalProcessorTime.TotalMilliseconds - $prevProcMap[$p.Id]
                    if ($deltaMs -gt 0 -and $cpuCores -gt 0) {
                        [PSCustomObject]@{ name = $p.ProcessName; cpu = [math]::Round(($deltaMs / 1000.0 / $elapsedSec / $cpuCores) * 100, 1) }
                    }
                }
            }
            $topCpuProcesses = $cpuRanked | Sort-Object -Property cpu -Descending | Select-Object -First 5
        }
    }

    $topRamProcesses = $procSample2 | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First 5 |
        ForEach-Object { [PSCustomObject]@{ name = $_.ProcessName; ram_mb = [math]::Round($_.WorkingSet64 / 1MB, 1) } }
} catch {}

# --- SMART stav disků ---
$smart = "N/A"
try {
    $drives = Get-CimInstance -ClassName Win32_DiskDrive
    $failed = $drives | Where-Object { $_.Status -and $_.Status -ne "OK" }
    if ($failed) {
        $smart = "WARNING (Disk $($failed[0].Model) hlásí stav $($failed[0].Status))"
    } elseif ($drives) {
        $smart = "OK"
    }
} catch {}

# --- Naslouchající TCP porty ---
$ports = @()
try {
    $ports = Get-NetTCPConnection -State Listen -ErrorAction Stop |
        Select-Object -ExpandProperty LocalPort -Unique | Sort-Object
} catch {
    try {
        $ports = netstat -an | Select-String "LISTENING" | ForEach-Object {
            if ($_ -match ':(\d+)\s') { [int]$Matches[1] }
        } | Sort-Object -Unique
    } catch {}
}

# --- Běžící procesy (unikátní názvy) ---
$processes = @()
try {
    $processes = Get-Process | Select-Object -ExpandProperty ProcessName -Unique
} catch {}

# --- TeamSpeak proces (PID/CPU/RAM/vlákna/handles) ---
# Detekce restartu (změna PID mezi hlášeními) se dělá na serveru (agent_api.php),
# agent jen hlásí aktuální stav. "open_fds" je zde HandleCount (nejbližší windowsí
# obdoba počtu otevřených soketů/souborů - Windows nemá přímo /proc/<pid>/fd).
$ts3Process = $null
try {
    $proc = Get-Process -Name "ts3server" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        $stateFileTs = Join-Path $env:TEMP "status_agent_win_ts3.json"
        $nowTicks = (Get-Date).Ticks
        $cpuMsNow = $proc.TotalProcessorTime.TotalMilliseconds
        $ts3Cpu = 0.0

        if (Test-Path $stateFileTs) {
            try {
                $json = Get-Content $stateFileTs -Raw | ConvertFrom-Json
                $elapsedSec = ($nowTicks - $json.ticks) / 10000000.0
                if ($elapsedSec -gt 0.1) {
                    $cpuDeltaMs = $cpuMsNow - $json.cpuMs
                    $cpuCores = [Environment]::ProcessorCount
                    if ($cpuDeltaMs -gt 0 -and $cpuCores -gt 0) {
                        $ts3Cpu = [math]::Round(($cpuDeltaMs / 1000.0 / $elapsedSec / $cpuCores) * 100, 1)
                    }
                }
            } catch {}
        }
        @{ ticks = $nowTicks; cpuMs = $cpuMsNow } | ConvertTo-Json | Set-Content $stateFileTs -ErrorAction SilentlyContinue

        $ts3Process = @{
            pid = $proc.Id
            cpu = $ts3Cpu
            ram_mb = [math]::Round($proc.WorkingSet64 / 1MB, 1)
            threads = $proc.Threads.Count
            open_fds = $proc.HandleCount
            uptime_sec = [int]((Get-Date) - $proc.StartTime).TotalSeconds
        }
    }
} catch {}

# --- Service Discovery ---
$discoveredServices = @()
$detectors = @(
    @{ Name = "TeamSpeak"; Type = "teamspeak"; Port = 10011; Proc = "ts3server"; Cfg = @() },
    @{ Name = "Minecraft"; Type = "minecraft"; Port = 25565; Proc = "java"; Cfg = @() },
    @{ Name = "Nginx"; Type = "nginx"; Port = 80; Proc = "nginx"; Cfg = @("C:\nginx\conf\nginx.conf") },
    @{ Name = "Docker"; Type = "docker"; Port = $null; Proc = "dockerd"; Cfg = @("C:\ProgramData\Docker") },
    @{ Name = "PostgreSQL"; Type = "postgresql"; Port = 5432; Proc = "postgres"; Cfg = @("C:\Program Files\PostgreSQL") },
    @{ Name = "AdGuard Home"; Type = "adguard"; Port = 3000; Proc = "AdGuardHome"; Cfg = @() },
    @{ Name = "Mosquitto"; Type = "mosquitto"; Port = 1883; Proc = "mosquitto"; Cfg = @("C:\Program Files\mosquitto\mosquitto.conf") }
)
foreach ($det in $detectors) {
    $conf = 0; $evidence = @(); $missing = @()
    if ($det.Proc -and $processes -contains $det.Proc) { $conf += 30; $evidence += "process" } elseif ($det.Proc) { $missing += "process" }
    if ($det.Port -and $ports -contains $det.Port) { $conf += 25; $evidence += "port" } elseif ($det.Port) { $missing += "port" }
    $cfgFound = $false
    foreach ($cp in $det.Cfg) { if (Test-Path $cp) { $cfgFound = $true; break } }
    if ($cfgFound) { $conf += 25; $evidence += "config" } elseif ($det.Cfg.Count -gt 0) { $missing += "config" }
    if ($det.Port -and $ports -contains $det.Port) { $conf += 19; $evidence += "active_verify" } else { $missing += "active_verify" }
    if ($conf -gt 99) { $conf = 99 }
    if ($conf -ge 25) {
        $discoveredServices += @{ name = $det.Name; type = $det.Type; port = $det.Port; confidence = $conf; evidence = $evidence; missing = $missing }
    }
}

# --- Parita s Linux agenty: Tailscale / ZeroTier / UPS (null bez nastroje) ---
$tailscaleUp = $null
$tailscalePeers = $null
try {
    $tsExe = Get-Command tailscale.exe -ErrorAction Stop
    $tsRaw = & $tsExe.Source status --json 2>$null
    if ($tsRaw) {
        $tsJson = $tsRaw | ConvertFrom-Json
        $tailscaleUp = ($tsJson.BackendState -eq 'Running')
        $tailscalePeers = @($tsJson.Peer.PSObject.Properties).Count
    }
} catch {}

$zerotierNetworks = $null
try {
    $ztExe = Get-Command zerotier-cli.bat -ErrorAction SilentlyContinue
    if (-not $ztExe) { $ztExe = Get-Command zerotier-cli -ErrorAction Stop }
    $ztOut = & $ztExe.Source listnetworks 2>$null
    if ($ztOut) { $zerotierNetworks = @($ztOut | Where-Object { $_ -match ' OK ' }).Count }
} catch {}

$upsStatus = $null
$upsBattery = $null
try {
    # Bez NUT klienta zkusime aspon Windows baterii/UPS pres WMI.
    $batt = Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1
    if ($batt) {
        # BatteryStatus 1 = vybijeni (bezi na baterii), 2 = na siti
        $upsStatus = if ($batt.BatteryStatus -eq 1) { "OB" } else { "OL" }
        if ($null -ne $batt.EstimatedChargeRemaining) { $upsBattery = [int]$batt.EstimatedChargeRemaining }
    }
} catch {}

# --- Parita s Linux agenty v1.7.2: RAM detail, boot time, pending reboot, DNS latence, USB ---
$ramTotalMb = $null; $ramUsedMb = $null; $ramAvailMb = $null; $ramFreeMb = $null
$bootTime = $null
try {
    $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $ramTotalMb = [math]::Round($osInfo.TotalVisibleMemorySize / 1024)
    $ramFreeMb = [math]::Round($osInfo.FreePhysicalMemory / 1024)
    $ramAvailMb = $ramFreeMb
    $ramUsedMb = $ramTotalMb - $ramFreeMb
    $bootTime = [int][double]::Parse((Get-Date $osInfo.LastBootUpTime -UFormat %s))
} catch {}

# Windows umi "ceka na restart" precist z registru - dosavadni natvrdo $null
# byl zbytecne zahozeny signal.
$rebootRequired = $false
try {
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $rebootRequired = $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $rebootRequired = $true }
} catch { $rebootRequired = $null }

$dnsLatencyMs = $null
try {
    $dnsSw = Measure-Command { [System.Net.Dns]::GetHostAddresses('example.com') | Out-Null }
    $dnsLatencyMs = [math]::Round($dnsSw.TotalMilliseconds, 1)
} catch {}

$usbDevices = $null
try {
    $usbDevices = @(Get-PnpDevice -Class USB -Status OK -ErrorAction Stop).Count
} catch {}

$payload = @{
    agent_key = $AGENT_KEY
    agent_type = "powershell"
    version = $AGENT_VERSION
    heavy_op_interval_hours = 24
    os = $os_version
    cpu = $cpu
    cpu_steal = $cpuSteal
    iowait = $null
    ram = $ram
    swap = $swap
    hdd = $hdd
    inode_usage = $null
    load1 = $load1
    load5 = $load5
    load15 = $load15
    disk_io_read = $diskIoRead
    disk_io_write = $diskIoWrite
    net = $net
    net_errors = $netErrors
    fork_rate = $null
    temperature = $null
    uptime = $uptime
    smart = $smart
    ports = @($ports)
    processes = @($processes)
    ts3_process = $ts3Process
    zombie_count = $null
    top_cpu_processes = @($topCpuProcesses)
    top_ram_processes = @($topRamProcesses)
    hostname = $sys_hostname
    kernel = $sys_kernel
    timezone = $sys_timezone
    reboot_required = $rebootRequired
    cloud_provider = $cloud_provider
    virtualization = $virtualization
    ram_total_mb = $ramTotalMb
    ram_used_mb = $ramUsedMb
    ram_available_mb = $ramAvailMb
    ram_free_mb = $ramFreeMb
    boot_time = $bootTime
    dns_latency_ms = $dnsLatencyMs
    usb_devices = $usbDevices
    auto_update = $(if ($AUTO_UPDATE -eq "1") { 1 } else { 0 })
    tailscale_up = $tailscaleUp
    tailscale_peers = $tailscalePeers
    zerotier_networks = $zerotierNetworks
    ups_status = $upsStatus
    ups_battery_pct = $upsBattery
    discovered_services = $discoveredServices
} | ConvertTo-Json -Depth 4

$netLog = if ($null -ne $net) { "$net KB/s" } else { "N/A (první běh)" }
Write-AgentLog "Metriky - OS: $os_version, CPU: $cpu%, RAM: $ram%, swap $swap%, HDD: $hdd%, Sit: $netLog, Uptime: ${uptime}s, SMART: $smart"
Write-AgentLog "Odesílám data na $API_URL..."

try {
    # TLS 1.2 pro starší verze Windows/PowerShell
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $response = Invoke-RestMethod -Uri $API_URL -Method Post -Body $payload -ContentType "application/json; charset=utf-8" -TimeoutSec 15
    Write-AgentLog "OK: Statistiky úspěšně odeslány."
} catch {
    Write-AgentLog "CHYBA: Nepodařilo se odeslat data na server. Detaily: $($_.Exception.Message)"
    exit 1
}

# --- Vzdálené akce (opt-in přes REMOTE_ACTIONS_ENABLED=1) ---
# Stejný kontrakt jako shell/Python agenti: server může v odpovědi poslat
# HMAC-SHA256 podepsanou akci (podpis přes "action={a}|ts={t}|nonce={n}"
# klíčem agenta, platnost 30 s, whitelist v ALLOWED_ACTIONS) a agent výsledek
# VŽDY potvrdí zpět (agent_api.php větev action_result) - jinak by akce
# v administraci navždy visela ve stavu "odesláno".
function Send-ActionResult {
    param([int]$ActionId, [string]$Status, [string]$Message)
    $resultPayload = @{
        agent_key = $AGENT_KEY
        action_result = @{
            action_id = $ActionId
            status = $Status
            message = $Message
        }
    } | ConvertTo-Json -Depth 4
    try {
        Invoke-RestMethod -Uri $API_URL -Method Post -Body $resultPayload -ContentType "application/json; charset=utf-8" -TimeoutSec 10 | Out-Null
    } catch {
        Write-AgentLog "VAROVÁNÍ: Potvrzení akce $ActionId se nepodařilo odeslat: $($_.Exception.Message)"
    }
}

# Server akci posílá zanořenou v "pending_action" (viz agent_api.php).
$pendingAction = if ($response -and $response.pending_action) { $response.pending_action } else { $response }

if ($REMOTE_ACTIONS_ENABLED -eq "1" -and $pendingAction -and $pendingAction.action_id -and $pendingAction.action -and $pendingAction.timestamp -and $pendingAction.signature) {
    $actId = [int]$pendingAction.action_id
    $actType = [string]$pendingAction.action
    $actTs = [long]$pendingAction.timestamp
    $actSig = [string]$pendingAction.signature
    $actNonce = [string]$pendingAction.nonce

    $nowTs = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ([Math]::Abs($nowTs - $actTs) -gt 30) {
        Write-AgentLog "VAROVÁNÍ: Odmítnuta vzdálená akce - vypršená platnost (časové okno > 30s)"
        Send-ActionResult -ActionId $actId -Status "failed" -Message "Vypršela platnost podpisu (>30s)"
    } elseif (($ALLOWED_ACTIONS -split ",").Trim() -notcontains $actType) {
        Write-AgentLog "VAROVÁNÍ: Odmítnuta vzdálená akce '$actType' - není na seznamu ALLOWED_ACTIONS!"
        Send-ActionResult -ActionId $actId -Status "failed" -Message "Akce '$actType' není v ALLOWED_ACTIONS"
    } else {
        $hmacObj = New-Object System.Security.Cryptography.HMACSHA256
        $hmacObj.Key = [Text.Encoding]::UTF8.GetBytes($AGENT_KEY)
        $calcStr = "action=$actType|ts=$actTs|nonce=$actNonce"
        $calcSig = ([BitConverter]::ToString($hmacObj.ComputeHash([Text.Encoding]::UTF8.GetBytes($calcStr)))).Replace("-", "").ToLower()

        if ($calcSig -ne $actSig.ToLower()) {
            Write-AgentLog "VAROVÁNÍ: Odmítnuta vzdálená akce - neplatný HMAC podpis!"
            Send-ActionResult -ActionId $actId -Status "failed" -Message "Neplatný HMAC podpis"
        } else {
            Write-AgentLog "Aktivována bezpečná vzdálená akce: $actType (ID: $actId)"
            switch ($actType) {
                "restart_service" {
                    $svcName = [string]$(if ($pendingAction.service_name) { $pendingAction.service_name } else { $response.service_name })
                    if (-not $svcName -or $svcName -notmatch '^[A-Za-z0-9_. @-]+$') {
                        Send-ActionResult -ActionId $actId -Status "failed" -Message "Chybí nebo je neplatné service_name v payloadu akce"
                    } elseif (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
                        try {
                            Restart-Service -Name $svcName -Force -ErrorAction Stop
                            Write-AgentLog "Restartována služba: $svcName"
                            Send-ActionResult -ActionId $actId -Status "executed" -Message "Služba '$svcName' restartována"
                        } catch {
                            Write-AgentLog "VAROVÁNÍ: Restart služby '$svcName' selhal: $($_.Exception.Message)"
                            Send-ActionResult -ActionId $actId -Status "failed" -Message "Restart služby '$svcName' selhal: $($_.Exception.Message)"
                        }
                    } else {
                        Write-AgentLog "VAROVÁNÍ: Služba '$svcName' nenalezena."
                        Send-ActionResult -ActionId $actId -Status "failed" -Message "Služba '$svcName' nenalezena"
                    }
                }
                "reboot_server" {
                    Write-AgentLog "PROVÁDÍM REBOOT SERVERU DLE PODEPSANÉHO POKYNU..."
                    # Potvrzení musí odejít PŘED rebootem - po Restart-Computer
                    # se už nic dalšího neprovede.
                    Send-ActionResult -ActionId $actId -Status "executed" -Message "Server se restartuje"
                    Restart-Computer -Force
                }
            }
        }
    }
}

# --- Automatická aktualizace agenta (opt-in přes AUTO_UPDATE=1) ---
# Nová verze se stáhne do dočasného souboru, ověří se SHA-256 checksum z API
# odpovědi a teprve poté se atomicky nahradí tento skript. Nová verze se
# použije při příštím spuštění naplánované úlohy.
if ($AUTO_UPDATE -eq "1" -and $response -and $response.update_available -eq $true) {
    $updateUrl = $response.update_url
    $expectedSha = $response.update_sha256
    $latestVersion = $response.latest_version

    if ($updateUrl -and $expectedSha) {
        $selfPath = $MyInvocation.MyCommand.Path
        $tmpFile = Join-Path $ScriptPath ("agent-update-" + [guid]::NewGuid().ToString("N") + ".ps1")
        Write-AgentLog "K dispozici je nová verze agenta $latestVersion (aktuální $AGENT_VERSION), stahuji z $updateUrl..."

        try {
            Invoke-WebRequest -Uri $updateUrl -OutFile $tmpFile -UseBasicParsing -TimeoutSec 30

            $actualSha = (Get-FileHash -Path $tmpFile -Algorithm SHA256).Hash.ToLower()
            if ($actualSha -ne $expectedSha.ToLower()) {
                Write-AgentLog "CHYBA UPDATE: Checksum nesouhlasí (očekáván $expectedSha, stažen $actualSha). Aktualizace zrušena."
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            } else {
                # Kontrola syntaxe staženého skriptu
                $parseErrors = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile($tmpFile, [ref]$null, [ref]$parseErrors)
                if ($parseErrors -and $parseErrors.Count -gt 0) {
                    Write-AgentLog "CHYBA UPDATE: Stažený soubor neprošel kontrolou syntaxe. Aktualizace zrušena."
                    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
                } else {
                    Copy-Item $selfPath "$selfPath.bak" -Force -ErrorAction SilentlyContinue
                    Move-Item $tmpFile $selfPath -Force
                    Write-AgentLog "OK: Agent aktualizován na verzi $latestVersion. Nová verze se použije při příštím spuštění."
                }
            }
        } catch {
            Write-AgentLog "CHYBA UPDATE: Aktualizace se nezdařila: $($_.Exception.Message)"
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-AgentLog "Hotovo."
