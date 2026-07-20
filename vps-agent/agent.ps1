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

$AGENT_VERSION = "1.3.0"

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

$payload = @{
    agent_key = $AGENT_KEY
    agent_type = "powershell"
    version = $AGENT_VERSION
    os = $os_version
    cpu = $cpu
    ram = $ram
    hdd = $hdd
    uptime = $uptime
    smart = $smart
    ports = @($ports)
    processes = @($processes)
} | ConvertTo-Json -Depth 4

Write-AgentLog "Metriky - OS: $os_version, CPU: $cpu%, RAM: $ram%, HDD: $hdd%, Uptime: ${uptime}s, SMART: $smart"
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
