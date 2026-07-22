# Blood Kings Status Monitoring - VPS Agent (Windows PowerShell Version)
#
# Tento skript spouštějte na Windows serveru pomocí Naplánovaných úloh
# (Task Scheduler), např. každých 5 minut:
#   powershell.exe -ExecutionPolicy Bypass -File C:\bloodkings\agent.ps1
#
# Vyžaduje PowerShell 5.1+ (součást Windows Server 2016+ / Windows 10+).

# === VÝCHOZÍ KONFIGURACE ===
# Hodnoty můžete nechat zde, nebo vytvořit soubor 'agent.cfg' ve stejné složce
$API_URL = "http://localhost/status/agent_api.php"
$AGENT_KEY = "ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE"
$AUTO_UPDATE = "0" # Nastavte na "1" pro povolení automatických aktualizací agenta ze serveru
# ===========================

$AGENT_VERSION = "1.7.0"

# Načtení z Environment proměnných
if ($env:STATUS_API_URL) { $API_URL = $env:STATUS_API_URL }
if ($env:STATUS_AGENT_KEY) { $AGENT_KEY = $env:STATUS_AGENT_KEY }
if ($env:STATUS_AUTO_UPDATE) { $AUTO_UPDATE = $env:STATUS_AUTO_UPDATE }

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
# CPU% je dopočítáno ze stejné dvouvzorkové techniky jako u ts3server níže
# (TotalProcessorTime před/po 1s), ne z kumulativního $proc.CPU od startu procesu.
$topCpuProcesses = @()
$topRamProcesses = @()
try {
    $cpuCores = [Environment]::ProcessorCount
    $procSample1 = Get-Process -ErrorAction Stop | Select-Object Id, ProcessName, TotalProcessorTime, WorkingSet64
    Start-Sleep -Seconds 1
    $procSample2 = Get-Process -ErrorAction Stop | Select-Object Id, ProcessName, TotalProcessorTime, WorkingSet64
    $sample1ById = @{}
    foreach ($p in $procSample1) { $sample1ById[$p.Id] = $p.TotalProcessorTime }

    $cpuRanked = foreach ($p in $procSample2) {
        if ($sample1ById.ContainsKey($p.Id)) {
            $deltaMs = ($p.TotalProcessorTime - $sample1ById[$p.Id]).TotalMilliseconds
            if ($deltaMs -gt 0 -and $cpuCores -gt 0) {
                [PSCustomObject]@{ name = $p.ProcessName; cpu = [math]::Round(($deltaMs / 1000.0 / $cpuCores) * 100, 1) }
            }
        }
    }
    $topCpuProcesses = $cpuRanked | Sort-Object -Property cpu -Descending | Select-Object -First 5

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
        $cpuTime1 = $proc.TotalProcessorTime
        Start-Sleep -Seconds 1
        $proc.Refresh()
        $cpuTime2 = $proc.TotalProcessorTime
        $cpuCores = [Environment]::ProcessorCount
        $cpuDeltaMs = ($cpuTime2 - $cpuTime1).TotalMilliseconds
        $ts3Cpu = 0.0
        if ($cpuCores -gt 0) { $ts3Cpu = [math]::Round(($cpuDeltaMs / 1000.0 / $cpuCores) * 100, 1) }

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

$payload = @{
    agent_key = $AGENT_KEY
    agent_type = "powershell"
    version = $AGENT_VERSION
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
    reboot_required = $null
    cloud_provider = $cloud_provider
    virtualization = $virtualization
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
