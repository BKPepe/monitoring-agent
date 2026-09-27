# CmdletBinding gives the script the common -Verbose switch the help text has
# promised for a while; without it PowerShell rejected the parameter outright.
[CmdletBinding()]
param(
    [alias("h")][switch]$Help,
    [alias("v")][switch]$Version,
    [switch]$Update,
    [alias("Print")][switch]$DryRun,
    [switch]$SelfCheck
)

$AGENT_VERSION = "0.1.0"

# -SelfCheck is the self-update's behaviour gate: before a downloaded copy may
# replace this file, the updater runs it with -SelfCheck, and it has to collect,
# build its JSON payload and say which agent and version it is (see
# Invoke-AgentSelfCheck). A parse check alone let a release through that failed
# only at run time. Honoured only with BK_UPDATE_SELFCHECK=1, which only the
# updater sets: a task line or a person typing -SelfCheck gets an error, not an
# agent that quietly stopped reporting.
$SelfCheckMode = $false
if ($SelfCheck) {
    if ($env:BK_UPDATE_SELFCHECK -ne "1") {
        [Console]::Error.WriteLine("-SelfCheck is for the agent's own updater only (BK_UPDATE_SELFCHECK=1).")
        exit 2
    }
    $SelfCheckMode = $true
}

if ($Help) {
    Write-Host "Windows PowerShell Status Agent v$AGENT_VERSION"
    Write-Host "Použití: .\agent.ps1 [MOŽNOSTI]"
    Write-Host ""
    Write-Host "Možnosti:"
    Write-Host "  -Help, -h      Zobrazí tuto nápovědu"
    Write-Host "  -Version, -v   Zobrazí verzi agenta"
    Write-Host "  -Update        Vynutí kontrolu a aktualizaci agenta ze serveru"
    Write-Host "  -DryRun        Sesbírá data a vypíše JSON, neodesílá (i bez klíče)"
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
$SelfPath = $MyInvocation.MyCommand.Path
# Self-update and remote-action state, next to the script and named after it
# (as agent.sh and agent.py do): the rename that swaps in a new version is
# only atomic inside one directory, on one volume.
$PrevFile = "$SelfPath.prev"            # the version before the last update
$PendingFile = "$SelfPath.probation"    # JSON: an update still on probation
$LastOkFile = "$SelfPath.last-ok"       # "<version> <unix ts>" of the last accepted report
$RejectedFile = "$SelfPath.rejected"    # "<sha256> <version> <unix ts>" of a file refused or rolled back
$NonceFile = "$SelfPath.nonces"         # "<unix ts> <nonce>" per signed action let through
# Windows PowerShell 5.1 writes a BOM with -Encoding UTF8; these files are read
# back by this script only, but a BOM would glue itself to the first field.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Probation: an update is proven by the new version's first accepted report.
# Until then every run counts, and the previous version comes back when the
# server has refused (HTTP 4xx) this many reports, or when this many runs have
# passed without one accepted. The second limit is large on purpose: a network
# outage right after an update is not the new version's fault.
$ROLLBACK_AFTER_REFUSED = 3
$ROLLBACK_AFTER_RUNS = 30
# A rolled-back file is not taken again for this long. A later fix published
# under the same version has another sha256 and is taken at once.
$REJECTED_SHA_HOURS = 24
# The downloaded copy's -SelfCheck runs the whole collection; Windows
# PowerShell 5.1 start plus the CIM queries take several seconds on a small VM.
$SELFCHECK_TIMEOUT_SEC = 60

function Write-AgentLog {
    param([string]$Message)
    # A self-check prints exactly one JSON object; any other line would make
    # the updater refuse the file.
    if ($SelfCheckMode) { return }
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts - $Message"
    # In -DryRun stdout is the JSON payload; keep the chatter on the host stream.
    if ($DryRun) { Write-Host $line } else { Write-Output $line }
    try {
        # Bounded: above 1 MB keep the last 500 lines. It grew without limit before.
        try {
            if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
                # Read fully first, then write. Piping Get-Content straight into
                # Set-Content on the SAME file has both handles open at once,
                # which throws - and the empty catch below swallowed it, so the
                # 1 MB bound was never actually enforced.
                $tail = @(Get-Content $LogFile -Tail 500)
                Set-Content -Path $LogFile -Value $tail -Encoding UTF8
            }
        } catch {}
        Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        try { Add-Content -Path (Join-Path $env:TEMP "status-agent.log") -Value $line -Encoding UTF8 } catch {}
    }
}

# The functions below that RETURN a value never call Write-AgentLog: in
# PowerShell a log line written inside such a function becomes part of its
# return value (and a non-empty "reason" out of nothing).

function Get-UnixNow { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# A small state file through a temporary name and a rename: a run killed
# mid-write leaves the old content, not half a line. Throws on failure; the
# caller decides whether that refuses something (the nonce store does).
function Save-StateText {
    param([string]$Path, [string]$Text)
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Text, $Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
}

# 1 when $A is newer than $B, 0 when equal, -1 when older, $null when either
# is not plain dotted digits. Such an offer is refused, never guessed at.
function Compare-AgentVersion {
    param([string]$A, [string]$B)
    $re = '^[0-9]{1,9}(\.[0-9]{1,9}){0,5}\z'
    if ($A -cnotmatch $re -or $B -cnotmatch $re) { return $null }
    $pa = $A.Split('.'); $pb = $B.Split('.')
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = 0; if ($i -lt $pa.Count) { $x = [int]$pa[$i] }
        $y = 0; if ($i -lt $pb.Count) { $y = [int]$pb[$i] }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

# The one service-name rule of all four agents: a letter, digit or "_" first
# (no leading "-" or ".": no option injection, no ".."), then letters, digits
# and _ . @ $ - ("$" for instance names such as MSSQL$SQLEXPRESS, "@" for
# systemd templates), 128 characters at most. Nothing that Restart-Service
# -Name reads as a wildcard (* ? [ ]) - "*" would restart every service - and
# no path separator or space. -cmatch: a case-insensitive match lets the Kelvin
# sign through as "k". \z: "$" would also match before a trailing newline.
function Test-ServiceName {
    param([string]$Name)
    return ($Name -cmatch '^[A-Za-z0-9_][A-Za-z0-9_.@$-]{0,127}\z')
}

# What a correctly SIGNED action still has to pass: "" when it may run, else
# the reason. The order of agent_openwrt.sh's bk_action_gate: single use, the
# allow-list, the service name. Called only after the signature matched, so an
# unsigned answer learns nothing about the list and burns no nonce. Until now
# this agent had no replay protection: a signed answer could be replayed for
# as long as its timestamp held (SEC-09).
function Get-ActionRefusal {
    param([string]$Type, [string]$Nonce, [long]$NowTs, [string]$ServiceName)
    # Single use. A signature is good for 30 s either side of its timestamp,
    # so at most 60 s after its first use; that long the nonce is remembered.
    # Written BEFORE the action runs: after a reboot nothing would write it.
    if ($Nonce -cnotmatch '^[A-Za-z0-9]{1,128}\z') { return "nonce chybí nebo má nepovolené znaky" }
    $keep = @()
    if (Test-Path -LiteralPath $NonceFile) {
        # A store that cannot be read cannot say the nonce is new.
        try { $lines = [System.IO.File]::ReadAllLines($NonceFile) } catch { return "nonce nejde přečíst z $NonceFile" }
        foreach ($l in $lines) {
            $f = $l.Split(' ')
            if ($f.Count -ne 2 -or $f[0] -cnotmatch '^[0-9]{1,18}\z') { continue }
            if (($NowTs - [long]$f[0]) -gt 60) { continue }
            if ($f[1] -ceq $Nonce) { return "nonce už byl použit (opakovaná odpověď)" }
            $keep += $l
        }
    }
    # A nonce that cannot be remembered could be replayed: refuse.
    $keep += "$NowTs $Nonce"
    try { Save-StateText -Path $NonceFile -Text (($keep -join "`n") + "`n") } catch { return "nonce nejde uložit do $ScriptPath" }
    # The type before the list: a comma inside it would match across two entries.
    if ($Type -cnotmatch '^[a-z_]{1,64}\z') { return "neplatný typ akce" }
    $allowed = @($ALLOWED_ACTIONS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($allowed -cnotcontains $Type) { return "akce '$Type' není v ALLOWED_ACTIONS" }
    if ($Type -ceq "restart_service" -and -not (Test-ServiceName $ServiceName)) { return "neplatný název služby" }
    return ""
}

# The last line of every agent file is "# bk-agent-end <version>". A download
# cut short can still parse - a truncated OpenWrt agent did, and installed
# itself - but it cannot end with this line. "" or the reason.
function Test-AgentSentinel {
    param([string]$Path, [string]$Version)
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { return "stažený soubor nejde přečíst" }
    $take = [Math]::Min($bytes.Length, 512)
    $tail = [System.Text.Encoding]::UTF8.GetString($bytes, $bytes.Length - $take, $take)
    # CR too: the same file saved with Windows line ends is still the same file.
    $tail = $tail.TrimEnd([char[]]@(13, 10, 32, 9))
    $last = $tail.Substring($tail.LastIndexOf([char]10) + 1).TrimEnd([char]13)
    if ($last -cne "# bk-agent-end $Version") { return "stažený soubor nekončí řádkem '# bk-agent-end $Version' (neúplný?)" }
    return ""
}

# The self-check process and whatever it started. pwsh 7 (.NET Core 3+) has
# Kill($true) for the whole tree; Windows PowerShell 5.1 (.NET Framework) has
# not, and taskkill /T does the same there.
function Stop-SelfCheckTree {
    param($Proc)
    try { $Proc.Kill($true); return } catch {}
    try { & taskkill.exe /T /F /PID $Proc.Id 2>&1 | Out-Null } catch {}
    try { $Proc.Kill() } catch {}
}

# Runs the downloaded copy with -SelfCheck under a time limit. It has to exit 0
# and print one JSON object naming this agent type and the offered version.
# "" or the reason.
function Invoke-AgentSelfCheck {
    param([string]$Path, [string]$Version)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    # The engine of this run: the task runs Windows PowerShell 5.1 or pwsh 7,
    # and the new file has to work in that one.
    $psi.FileName = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Path`" -SelfCheck"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables["BK_UPDATE_SELFCHECK"] = "1"
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { return "self-check nejde spustit: $($_.Exception.Message)" }
    # Both pipes are drained asynchronously: a child that fills one while we
    # wait on the other would never exit.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($SELFCHECK_TIMEOUT_SEC * 1000)) {
        Stop-SelfCheckTree $proc
        return "self-check nedoběhl do $SELFCHECK_TIMEOUT_SEC s"
    }
    $proc.WaitForExit()
    # The reads end at EOF, and EOF comes when the LAST holder of the pipe
    # closes it: a process the self-check left running keeps it open, and an
    # unbounded .Result then held this run (and, with IgnoreNew, every later
    # scheduled run) for as long as that process lived.
    if (-not $outTask.Wait(5000)) {
        Stop-SelfCheckTree $proc
        return "self-check nechal běžet proces, který drží jeho výstup"
    }
    [void]$errTask.Wait(5000)
    if ($proc.ExitCode -ne 0) { return "self-check skončil kódem $($proc.ExitCode)" }
    $out = ([string]$outTask.Result).Trim()
    $obj = $null
    if ($out.StartsWith("{")) { try { $obj = ConvertFrom-Json -InputObject $out -ErrorAction Stop } catch {} }
    if (-not $obj -or $obj -is [array]) { return "self-check nevypsal jeden JSON objekt" }
    if ([string]$obj.agent_type -cne "powershell") { return "self-check hlásí agent_type '$($obj.agent_type)'" }
    if ([string]$obj.agent_version -cne $Version) { return "self-check hlásí verzi '$($obj.agent_version)' místo $Version" }
    return ""
}

# The verified download sits in this directory, so the swap is a rename on
# one volume (IO-07). [IO.File]::Replace (ReplaceFile) turns the current file
# into .prev and the new one into the script, and the new file keeps the
# script's own ACL. The old way (Copy-Item .bak, Move-Item) had a window with
# no agent.ps1 at all, and nothing ever read the .bak. "" or the reason; on
# failure the script is the old one.
function Invoke-AgentSwap {
    param([string]$NewPath)
    $replaceErr = ""
    try {
        [System.IO.File]::Replace($NewPath, $SelfPath, $PrevFile)
        return ""
    } catch { $replaceErr = $_.Exception.Message }
    # A volume without ReplaceFile (some network shares): copy, then move.
    try {
        Copy-Item -LiteralPath $SelfPath -Destination $PrevFile -Force -ErrorAction Stop
        Move-Item -LiteralPath $NewPath -Destination $SelfPath -Force -ErrorAction Stop
        return ""
    } catch {
        # ReplaceFile can fail half way with the old file already under the
        # backup name: put it back.
        if (-not (Test-Path -LiteralPath $SelfPath) -and (Test-Path -LiteralPath $PrevFile)) {
            Copy-Item -LiteralPath $PrevFile -Destination $SelfPath -Force -ErrorAction SilentlyContinue
        }
        return "nahrazení $SelfPath selhalo ($replaceErr / $($_.Exception.Message))"
    }
}

function Read-PendingUpdate {
    if (-not (Test-Path -LiteralPath $PendingFile)) { return $null }
    try { return ([System.IO.File]::ReadAllText($PendingFile) | ConvertFrom-Json) } catch { return $null }
}

# A report the server read and refused (HTTP 4xx) while an update is on
# probation: the class of a release whose payload the server rejects (REL-01).
# Only these count toward the fast rollback; a timeout or DNS failure is not
# the new version's fault.
function Register-UpdateRefusal {
    param($ErrorRecord)
    $code = 0
    try { $code = [int]$ErrorRecord.Exception.Response.StatusCode } catch {}
    if ($code -lt 400 -or $code -gt 499) { return }
    $p = Read-PendingUpdate
    if (-not $p -or [string]$p.version -cne $AGENT_VERSION) { return }
    try {
        $p.refused = [int]$p.refused + 1
        Save-StateText -Path $PendingFile -Text ($p | ConvertTo-Json -Compress)
    } catch {}
}

# Start of every real run: a version on probation counts this run, and goes
# back to .prev when it has had its chances (MISS-owrt-bak: the old .bak was
# never read by anything). Called as a statement, so its log lines reach the
# task's output.
function Invoke-UpdateProbation {
    $p = Read-PendingUpdate
    if (-not $p) {
        if (Test-Path -LiteralPath $PendingFile) { Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue }
        return
    }
    # A marker for another version is left from a swap that failed or was
    # undone by hand; without a .prev there is nothing to go back to.
    if ([string]$p.version -cne $AGENT_VERSION -or -not (Test-Path -LiteralPath $PrevFile)) {
        Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue
        return
    }
    # Proven already: a run that stamped last-ok and died before clearing this.
    $ok = ""
    try { if (Test-Path -LiteralPath $LastOkFile) { $ok = ([System.IO.File]::ReadAllText($LastOkFile)).Trim() } } catch {}
    $okf = $ok.Split(' ')
    if ($okf.Count -eq 2 -and $okf[0] -ceq $AGENT_VERSION -and $okf[1] -cmatch '^[0-9]{1,18}\z' -and [long]$okf[1] -ge [long]$p.since) {
        Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue
        return
    }
    $runs = 0; $refused = 0
    try { $runs = [int]$p.runs + 1; $refused = [int]$p.refused } catch {}
    if ($refused -lt $ROLLBACK_AFTER_REFUSED -and $runs -le $ROLLBACK_AFTER_RUNS) {
        try {
            $p.runs = $runs
            Save-StateText -Path $PendingFile -Text ($p | ConvertTo-Json -Compress)
        } catch {}
        return
    }
    $badSha = [string]$p.sha256
    if ($badSha -cnotmatch '^[0-9a-f]{64}\z') {
        try { $badSha = (Get-FileHash -LiteralPath $SelfPath -Algorithm SHA256).Hash.ToLowerInvariant() } catch {}
    }
    try {
        # [NullString]: a plain $null reaches .NET as "" and Replace throws.
        [System.IO.File]::Replace($PrevFile, $SelfPath, [NullString]::Value)
    } catch {
        try {
            Copy-Item -LiteralPath $PrevFile -Destination $SelfPath -Force -ErrorAction Stop
        } catch {
            Write-AgentLog "CHYBA UPDATE: Verze $AGENT_VERSION neprošla zkušební dobou, ale návrat na $($p.from) se nezdařil: $($_.Exception.Message)"
            return
        }
    }
    Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue
    try { Save-StateText -Path $RejectedFile -Text "$badSha $AGENT_VERSION $(Get-UnixNow)`n" } catch {}
    Write-AgentLog "CHYBA UPDATE: Verze $AGENT_VERSION nedoručila hlášení ($refused odmítnuto serverem, $($runs - 1) běhů bez přijetí). Vrácena předchozí verze $($p.from); tento soubor se $REJECTED_SHA_HOURS h znovu nestáhne."
    exit 1
}

# The self-update (opt-in, AUTO_UPDATE=1). Called as a statement, so its log
# lines reach the task's output. Everything is checked on a download next to
# the script before the script itself is touched; any refusal leaves it
# byte-identical.
function Invoke-SelfUpdate {
    param($Response)
    $updateUrl = [string]$Response.update_url
    $expectedSha = ([string]$Response.update_sha256).ToLowerInvariant()
    $latestVersion = [string]$Response.latest_version
    if (-not $updateUrl -or -not $expectedSha) { return }

    # Forward only. A deploy of an older file (a reverted submodule, a second
    # publisher) must not downgrade the fleet, and an unparsable version is not
    # guessed at. Write-Verbose, not the log: the server repeats the offer on
    # every run.
    if ((Compare-AgentVersion $latestVersion $AGENT_VERSION) -ne 1) {
        Write-Verbose "Nabídnutá verze '$latestVersion' není novější než $AGENT_VERSION, neaktualizuji."
        return
    }
    # A file this agent rolled back, or refused for what its bytes are (no
    # end line, no parse, a failed self-check), in the last day is not
    # fetched again: a broken release would otherwise be downloaded and
    # self-checked on every run.
    $rej = ""
    try { if (Test-Path -LiteralPath $RejectedFile) { $rej = ([System.IO.File]::ReadAllText($RejectedFile)).Trim() } } catch {}
    $rf = $rej.Split(' ')
    if ($rf.Count -eq 3 -and $rf[0] -ceq $expectedSha -and $rf[2] -cmatch '^[0-9]{1,18}\z' -and ((Get-UnixNow) - [long]$rf[2]) -lt ($REJECTED_SHA_HOURS * 3600)) {
        Write-Verbose "Verze $latestVersion ($expectedSha) byla odmítnuta, do $REJECTED_SHA_HOURS h ji znovu nestahuji."
        return
    }
    # The download sits next to the script until the rename: room for twice
    # the current file, or a full disk would take the next state write and log
    # line with it. A volume that reports nothing (a share) does not stop it.
    $need = 2 * (Get-Item -LiteralPath $SelfPath).Length
    $free = $null
    try { $free = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($SelfPath)).AvailableFreeSpace } catch {}
    if ($null -ne $free -and $free -lt $need) {
        Write-AgentLog "CHYBA UPDATE: Vedle $SelfPath není místo na novou verzi (volno $free B, potřeba $need B). Aktualizace zrušena."
        return
    }

    Write-AgentLog "K dispozici je nová verze agenta $latestVersion (aktuální $AGENT_VERSION), stahuji z $updateUrl..."
    # One fixed name, removed first: a run killed in an earlier update leaves
    # at most this one file. It ends in .ps1 because -File runs nothing else.
    $newFile = Join-Path $ScriptPath "agent-update.ps1"
    Remove-Item -LiteralPath $newFile -Force -ErrorAction SilentlyContinue
    $refusal = ""
    $badBytes = $false
    try {
        Invoke-WebRequest -Uri $updateUrl -OutFile $newFile -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $actualSha = (Get-FileHash -LiteralPath $newFile -Algorithm SHA256).Hash.ToLowerInvariant()
        # A mismatch is the transport's fault, not the file's: tried again next run.
        if ($actualSha -cne $expectedSha) { $refusal = "Checksum nesouhlasí (očekáván $expectedSha, stažen $actualSha)" }
        # From here on a refusal is a property of these exact bytes.
        if (-not $refusal) { $badBytes = $true; $refusal = Test-AgentSentinel -Path $newFile -Version $latestVersion }
        if (-not $refusal) {
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($newFile, [ref]$null, [ref]$parseErrors)
            if ($parseErrors -and $parseErrors.Count -gt 0) { $refusal = "Stažený soubor neprošel kontrolou syntaxe" }
        }
        if (-not $refusal) {
            $refusal = Invoke-AgentSelfCheck -Path $newFile -Version $latestVersion
            # An engine that cannot be started says nothing about the file.
            if ($refusal -like "self-check nejde spustit*") { $badBytes = $false }
        }
        if (-not $refusal) {
            $badBytes = $false
            # On the disk before the name points at it: a power cut right
            # after the rename must not leave the name on an empty file.
            $fs = [System.IO.File]::Open($newFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            try { $fs.Flush($true) } finally { $fs.Dispose() }
            # Probation marker BEFORE the swap. If the swap then fails, the
            # marker names a version this file is not, and the next run drops it.
            $marker = [ordered]@{ version = $latestVersion; from = $AGENT_VERSION; sha256 = $expectedSha; since = (Get-UnixNow); runs = 0; refused = 0 }
            Save-StateText -Path $PendingFile -Text ($marker | ConvertTo-Json -Compress)
            $refusal = Invoke-AgentSwap -NewPath $newFile
            if ($refusal) { Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        $refusal = "Aktualizace se nezdařila: $($_.Exception.Message)"
    }
    Remove-Item -LiteralPath $newFile -Force -ErrorAction SilentlyContinue
    if ($refusal -and $badBytes) {
        try { Save-StateText -Path $RejectedFile -Text "$expectedSha $latestVersion $(Get-UnixNow)`n" } catch {}
        Write-AgentLog "CHYBA UPDATE: $refusal. Aktualizace zrušena; tento soubor se $REJECTED_SHA_HOURS h znovu nestáhne."
    } elseif ($refusal) {
        Write-AgentLog "CHYBA UPDATE: $refusal. Aktualizace zrušena."
    } else {
        Write-AgentLog "OK: Agent aktualizován na verzi $latestVersion. Nová verze se použije při příštím spuštění, předchozí zůstává jako $PrevFile."
    }
}

if ($AGENT_KEY -eq "ZDE_VLOZTE_UNIKATNI_KLIC_Z_ADMINISTRACE" -and -not $DryRun -and -not $SelfCheckMode) {
    Write-AgentLog "CHYBA: Nebyl nastaven AGENT_KEY. Upravte skript nebo 'agent.cfg'."
    exit 1
}

# A dry run or a self-check is not a run of the installed agent: it neither
# counts toward a probation nor rolls anything back.
if (-not $DryRun -and -not $SelfCheckMode) { Invoke-UpdateProbation }

Write-AgentLog "Získávám systémové statistiky (PowerShell)..."

# --- CPU: průměrné vytížení všech procesorů ---
# Unmeasured stays $null - the old 0.0 default sent "idle" to the server
# whenever WMI failed, which is not what happened.
$cpu = $null
try {
    $cpuLoad = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
    if ($null -ne $cpuLoad) { $cpu = [math]::Round([double]$cpuLoad, 1) }
} catch {
    try {
        # Performance data through CIM, not Get-Counter: counter paths are
        # localized ("\Prozessor(_Total)\Prozessorzeit (%)" on a German
        # Windows), the CIM class names are not.
        $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        if ($perf) { $cpu = [math]::Round([double]$perf.PercentProcessorTime, 1) }
    } catch { Write-AgentLog "VAROVANI: CPU nelze zmerit: $($_.Exception.Message)" }
}

# --- RAM: využitá fyzická paměť v % ---
$ram = $null
$os_info = $null
try {
    $os_info = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $totalKb = [double]$os_info.TotalVisibleMemorySize
    $freeKb = [double]$os_info.FreePhysicalMemory
    if ($totalKb -gt 0) { $ram = [math]::Round((($totalKb - $freeKb) / $totalKb) * 100, 1) }
} catch { Write-AgentLog "VAROVANI: RAM nelze zmerit: $($_.Exception.Message)" }

# --- Disk: zaplnění systémového disku (obvykle C:) v % ---
$hdd = $null
try {
    $systemDrive = $env:SystemDrive
    if (-not $systemDrive) { $systemDrive = "C:" }
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$systemDrive'"
    if ($disk -and [double]$disk.Size -gt 0) {
        $hdd = [math]::Round((([double]$disk.Size - [double]$disk.FreeSpace) / [double]$disk.Size) * 100, 1)
    }
} catch { Write-AgentLog "VAROVANI: disk nelze zmerit: $($_.Exception.Message)" }

# --- Swap (stránkovací soubor): využití v % ---
$swap = $null
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

# --- Disk I/O (KB/s čtení/zápis) ---
# Formatted performance data through CIM: locale-independent (Get-Counter
# paths are translated on non-English Windows and silently returned nothing)
# and instant - the old two-sample counter made every run a second longer.
$diskIoRead = $null
$diskIoWrite = $null
try {
    $ioPerf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop
    if ($ioPerf) {
        $diskIoRead = [math]::Round([double]$ioPerf.DiskReadBytesPersec / 1024, 1)
        $diskIoWrite = [math]::Round([double]$ioPerf.DiskWriteBytesPersec / 1024, 1)
    }
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

    # A self-check writes no state: it is not a run of the installed agent.
    if (-not $SelfCheckMode) {
        "$($now.ToFileTimeUtc()),$totalBytes,$totalErrors" | Set-Content -Path $NetStateFile -Encoding ASCII -ErrorAction SilentlyContinue
    }

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
$uptime = $null
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
    if (-not $SelfCheckMode) {
        @{ ticks = $nowTicks; procs = $saveList } | ConvertTo-Json -Depth 3 | Set-Content $stateFile -ErrorAction SilentlyContinue
    }

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
# Win32_DiskDrive.Status is a device-manager state, not disk health - it says
# "OK" on a drive whose SMART is failing. The Storage module's HealthStatus
# (Healthy / Warning / Unhealthy) is the real verdict; without it the answer
# is N/A, not a reassuring OK.
$smart = "N/A (Storage modul neni k dispozici)"
try {
    $pdisks = @(Get-PhysicalDisk -ErrorAction Stop)
    $bad = $pdisks | Where-Object { $_.HealthStatus -and $_.HealthStatus -ne "Healthy" }
    if ($bad) {
        $smart = "WARNING (Disk $($bad[0].FriendlyName) hlasi stav $($bad[0].HealthStatus))"
    } elseif ($pdisks.Count -gt 0) {
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
        $ts3Cpu = $null

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
        if (-not $SelfCheckMode) {
            @{ ticks = $nowTicks; cpuMs = $cpuMsNow } | ConvertTo-Json | Set-Content $stateFileTs -ErrorAction SilentlyContinue
        }

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
        # No peers = no Peer object at all; reading .PSObject off $null threw
        # and took tailscale_up down with it.
        $tailscalePeers = if ($tsJson.Peer) { @($tsJson.Peer.PSObject.Properties).Count } else { 0 }
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
    # The same Win32_OperatingSystem instance as above - it used to be
    # queried a second time here.
    if ($os_info) {
        $ramTotalMb = [math]::Round($os_info.TotalVisibleMemorySize / 1024)
        $ramFreeMb = [math]::Round($os_info.FreePhysicalMemory / 1024)
        $ramAvailMb = $ramFreeMb
        $ramUsedMb = $ramTotalMb - $ramFreeMb
        # Unix epoch straight from DateTimeOffset - `-UFormat %s` is
        # culture-formatted on Windows PowerShell 5.1 and failed to parse.
        $bootTime = [int][DateTimeOffset]::new([DateTime]$os_info.LastBootUpTime).ToUnixTimeSeconds()
    }
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
    # Devices only: the USB class also lists every root hub and host
    # controller, so an empty machine reported three or four "devices".
    $usbDevices = @(Get-PnpDevice -PresentOnly -Status OK -ErrorAction Stop | Where-Object { $_.InstanceId -like 'USB\VID_*' }).Count
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

if ($SelfCheckMode) {
    # The updater's behaviour gate (Invoke-AgentSelfCheck): the payload must
    # survive a JSON round trip and carry this file's identity. Nothing was
    # written and nothing is sent; the key is never printed.
    $check = $null
    try { $check = ConvertFrom-Json -InputObject $payload -ErrorAction Stop } catch {}
    if (-not $check -or [string]$check.agent_type -cne "powershell" -or [string]$check.version -cne $AGENT_VERSION) {
        [Console]::Error.WriteLine("self-check: the payload is not valid JSON or does not name this agent")
        exit 3
    }
    $summary = [ordered]@{ agent_type = [string]$check.agent_type; agent_version = $AGENT_VERSION; payload_keys = @($check.PSObject.Properties).Count }
    [Console]::Out.WriteLine(($summary | ConvertTo-Json -Compress))
    exit 0
}

if ($DryRun) {
    Write-Output $payload
    Write-AgentLog "Rezim -DryRun: data se neodesilaji."
    exit 0
}

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
    Register-UpdateRefusal $_
    exit 1
}

# The server took the report: the last-ok stamp, and an update on probation
# is proven (its marker goes, .prev stays for the next update to replace).
try { Save-StateText -Path $LastOkFile -Text "$AGENT_VERSION $(Get-UnixNow)`n" } catch {}
if (Test-Path -LiteralPath $PendingFile) { Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue }

# --- Vzdálené akce (opt-in přes REMOTE_ACTIONS_ENABLED=1) ---
# Stejný kontrakt jako shell/Python agenti: server může v odpovědi poslat
# HMAC-SHA256 podepsanou akci (podpis přes "action={a}|ts={t}|nonce={n}"
# klíčem agenta, platnost 30 s, whitelist v ALLOWED_ACTIONS) a agent výsledek
# VŽDY potvrdí zpět (agent_api.php větev action_result) - jinak by akce
# v administraci navždy visela ve stavu "odesláno".
function Send-ActionResult {
    # [long]: the id passed the digits-only gate, which allows more than [int] holds.
    param([long]$ActionId, [string]$Status, [string]$Message)
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
    $actIdRaw = [string]$pendingAction.action_id
    $actTsRaw = [string]$pendingAction.timestamp
    # Digits only, before either is used as a number: [int]/[long] casts take
    # "0x1F", "1e3" and " 12 ", and in agent.sh the same field reached shell
    # arithmetic, where it ran a command (SEC-01). Not a number = no action,
    # and no result either - there is no id to report it under. The rest of
    # the run (self-update) still happens.
    if ($actIdRaw -cnotmatch '^[0-9]{1,18}\z' -or $actTsRaw -cnotmatch '^[0-9]{1,18}\z') {
        Write-AgentLog "VAROVÁNÍ: Vzdálená akce má nečíselné action_id nebo timestamp, ignoruji ji."
    } else {
        $actId = [long]$actIdRaw
        $actTs = [long]$actTsRaw
        $actType = [string]$pendingAction.action
        $actSig = [string]$pendingAction.signature
        $actNonce = [string]$pendingAction.nonce
        $svcName = [string]$(if ($pendingAction.service_name) { $pendingAction.service_name } else { $response.service_name })

        $nowTs = Get-UnixNow
        if ([Math]::Abs($nowTs - $actTs) -gt 30) {
            Write-AgentLog "VAROVÁNÍ: Odmítnuta vzdálená akce - vypršená platnost (časové okno > 30s)"
            Send-ActionResult -ActionId $actId -Status "failed" -Message "Vypršela platnost podpisu (>30s)"
        } else {
            $hmacObj = New-Object System.Security.Cryptography.HMACSHA256
            $hmacObj.Key = [Text.Encoding]::UTF8.GetBytes($AGENT_KEY)
            $calcStr = "action=$actType|ts=$actTs|nonce=$actNonce"
            $calcSig = ([BitConverter]::ToString($hmacObj.ComputeHash([Text.Encoding]::UTF8.GetBytes($calcStr)))).Replace("-", "").ToLowerInvariant()

            if ($calcSig -cne $actSig.ToLowerInvariant()) {
                # Before the allow-list: an unsigned answer used to learn
                # from the reply which actions this agent allows.
                Write-AgentLog "VAROVÁNÍ: Odmítnuta vzdálená akce - neplatný HMAC podpis!"
                Send-ActionResult -ActionId $actId -Status "failed" -Message "Neplatný HMAC podpis"
            } else {
                $actRefused = Get-ActionRefusal -Type $actType -Nonce $actNonce -NowTs $nowTs -ServiceName $svcName
                if ($actRefused) {
                    Write-AgentLog "VAROVÁNÍ: Odmítnuta vzdálená akce $actType (ID: $actId): $actRefused"
                    Send-ActionResult -ActionId $actId -Status "failed" -Message "Odmítnuto: $actRefused"
                } else {
                    Write-AgentLog "Aktivována bezpečná vzdálená akce: $actType (ID: $actId)"
                    switch ($actType) {
                        "restart_service" {
                            # $svcName passed Test-ServiceName in the gate.
                            if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
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
                        default {
                            # On the list but unknown to this version: say so,
                            # or the action stays "sent" for ever.
                            Send-ActionResult -ActionId $actId -Status "failed" -Message "Tato verze agenta akci '$actType' nezná"
                        }
                    }
                }
            }
        }
    }
}

# --- Automatická aktualizace agenta (opt-in přes AUTO_UPDATE=1) ---
# Invoke-SelfUpdate: forward only, sha256, the end line, a parse, the new
# file's own -SelfCheck, free space, then ReplaceFile in this directory with
# the old file kept as .prev and a probation that brings it back.
if ($AUTO_UPDATE -eq "1" -and $response -and $response.update_available -eq $true) {
    Invoke-SelfUpdate -Response $response
}

Write-AgentLog "Hotovo."
# The updater requires this to be the file's last line (Test-AgentSentinel).
# It carries the same version as $AGENT_VERSION; bump both together.
# bk-agent-end 0.1.0
