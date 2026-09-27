# agent.ps1 tests, run by tests/run_windows_e2e.sh inside a PowerShell 7
# container with mock_api.ps1 listening on 127.0.0.1:18080.
#
# What Linux pwsh cannot show: Windows PowerShell 5.1 itself (PSScriptAnalyzer's
# compatibility rules stand in for its syntax), CIM/WMI metrics (they come back
# null here), the real service cmdlets (stubs/BkWindowsStubs stands in for
# Get-Service and Restart-Service and logs every restart), NTFS ACLs and
# ReplaceFile (.NET maps File.Replace to rename(2) on Linux).
param(
    [string]$AgentSrc = "/work/src/agent.ps1",
    [string]$Work = "/work",
    [string]$MockUrl = "http://127.0.0.1:18080",
    [string]$Stubs = "/harness/stubs"
)

$ErrorActionPreference = "Stop"
$MockDir = Join-Path $Work "mock"
$Key = "test-agent-key-0123456789"
$script:Passed = 0
$script:Failed = @()

function Check([string]$Name, [bool]$Ok, [string]$Detail = "") {
    if ($Ok) { $script:Passed++; Write-Host "PASS $Name" }
    else { $script:Failed += $Name; Write-Host "FAIL $Name $Detail" }
}

$SrcText = [System.IO.File]::ReadAllText($AgentSrc)
$SrcVersion = [regex]::Match($SrcText, '(?m)^\$AGENT_VERSION = "([^"]+)"').Groups[1].Value

# ---------------------------------------------------------------- static ---
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($AgentSrc, [ref]$null, [ref]$parseErrors)
Check "parse: no errors" ($parseErrors.Count -eq 0) (($parseErrors | ForEach-Object { $_.ToString() }) -join "; ")

$srcBytes = [System.IO.File]::ReadAllBytes($AgentSrc)
# Windows PowerShell 5.1 reads a BOM-less file as ANSI: every Czech message
# would reach the server garbled.
Check "encoding: UTF-8 BOM" ($srcBytes[0] -eq 0xEF -and $srcBytes[1] -eq 0xBB -and $srcBytes[2] -eq 0xBF)
$lastLine = ($SrcText.TrimEnd("`r", "`n") -split "`n")[-1].TrimEnd("`r")
Check "sentinel: last line is '# bk-agent-end $SrcVersion'" ($lastLine -ceq "# bk-agent-end $SrcVersion") "last line: '$lastLine'"

# Production runs Windows PowerShell 5.1; these tests run pwsh 7. The
# compatibility rules flag 7-only syntax (?:, ??, &&) and commands/types a
# 5.1 profile lacks.
try {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    $profile51 = "win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework"
    $settings = @{
        IncludeRules = @("PSUseCompatibleSyntax", "PSUseCompatibleCommands", "PSUseCompatibleTypes")
        Rules = @{
            PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @("5.1", "7.0") }
            PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @($profile51) }
            PSUseCompatibleTypes = @{ Enable = $true; TargetProfiles = @($profile51) }
        }
    }
    $findings = @(Invoke-ScriptAnalyzer -Path $AgentSrc -Settings $settings)
    Check "PSScriptAnalyzer: 5.1 compatible" ($findings.Count -eq 0) (($findings | ForEach-Object { "$($_.Line): $($_.Message)" }) -join "; ")
    $errFindings = @(Invoke-ScriptAnalyzer -Path $AgentSrc -Severity Error)
    Check "PSScriptAnalyzer: no Error findings" ($errFindings.Count -eq 0) (($errFindings | ForEach-Object { "$($_.RuleName) $($_.Line): $($_.Message)" }) -join "; ")
} catch {
    Check "PSScriptAnalyzer available" $false $_.Exception.Message
}

# ------------------------------------------------- units from the real file ---
# The functions are taken out of agent.ps1's own syntax tree, so the unit tests
# exercise the shipped code, not a copy.
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($fn.Name -in @("Test-ServiceName", "Compare-AgentVersion", "Test-AgentSentinel")) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}

$goodNames = @("wuauserv", "MSSQL`$SQLEXPRESS", "getty@tty1", "ssh", "_svc", "a.b-c_d", ("a" * 128))
$badNames = @("", "*", "wuau*", "svc?", "a[1]", "a b", "-rf", ".hidden", "..", "a/b", "a\b", "svc`n", "svc;calc",
    "`$(whoami)", "a,b", ("a" * 129), "$([char]0x212A)elvin", "sv$([char]0x0441)")
foreach ($n in $goodNames) { Check "service name accepted: '$n'" (Test-ServiceName $n) }
foreach ($n in $badNames) { Check "service name refused: '$($n -replace "`n", '\n')'" (-not (Test-ServiceName $n)) }

Check "version: 0.1.10 newer than 0.1.9" ((Compare-AgentVersion "0.1.10" "0.1.9") -eq 1)
Check "version: 0.1.0 equal 0.1" ((Compare-AgentVersion "0.1.0" "0.1") -eq 0)
Check "version: 0.0.9 older than 0.1.0" ((Compare-AgentVersion "0.0.9" "0.1.0") -eq -1)
Check "version: '1.0-beta' unparsable" ($null -eq (Compare-AgentVersion "1.0-beta" "0.1.0"))
Check "version: '' unparsable" ($null -eq (Compare-AgentVersion "" "0.1.0"))
Check "version: '0.1.1\n' unparsable" ($null -eq (Compare-AgentVersion "0.1.1`n" "0.1.0"))

$sentDir = Join-Path $Work "sentinel"
New-Item -ItemType Directory -Force -Path $sentDir | Out-Null
$sp = Join-Path $sentDir "x.ps1"
[System.IO.File]::WriteAllText($sp, "Write-Host 1`n# bk-agent-end 1.2.3`n")
Check "sentinel unit: LF accepted" ((Test-AgentSentinel -Path $sp -Version "1.2.3") -eq "")
[System.IO.File]::WriteAllText($sp, "Write-Host 1`r`n# bk-agent-end 1.2.3`r`n`r`n")
Check "sentinel unit: CRLF + blank line accepted" ((Test-AgentSentinel -Path $sp -Version "1.2.3") -eq "")
Check "sentinel unit: other version refused" ((Test-AgentSentinel -Path $sp -Version "1.2.4") -ne "")
[System.IO.File]::WriteAllText($sp, "# bk-agent-end 1.2.3`nWrite-Host 1`n")
Check "sentinel unit: not the last line refused" ((Test-AgentSentinel -Path $sp -Version "1.2.3") -ne "")
[System.IO.File]::WriteAllText($sp, "")
Check "sentinel unit: empty file refused" ((Test-AgentSentinel -Path $sp -Version "1.2.3") -ne "")

# --------------------------------------------------------------- helpers ---
function New-Sandbox {
    param([string]$Name, [string]$AutoUpdate = "0", [string]$Actions = "0", [string]$Allowed = "restart_service", [byte[]]$AgentBytes = $srcBytes)
    $sb = Join-Path $Work "sb/$Name"
    if (Test-Path $sb) { Remove-Item -Recurse -Force $sb }
    New-Item -ItemType Directory -Force -Path (Join-Path $sb "tmp") | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $sb "agent.ps1"), $AgentBytes)
    $cfg = @(
        "API_URL=$MockUrl/agent_api.php",
        "AGENT_KEY=$Key",
        "AUTO_UPDATE=$AutoUpdate",
        "REMOTE_ACTIONS_ENABLED=$Actions",
        "ALLOWED_ACTIONS=$Allowed"
    )
    Set-Content -Path (Join-Path $sb "agent.cfg") -Value $cfg
    return $sb
}

function Invoke-Agent {
    param([string]$Sb, [string[]]$AgentArgs = @(), [hashtable]$ExtraEnv = @{})
    $psi = [System.Diagnostics.ProcessStartInfo]::new("pwsh")
    foreach ($a in @("-NoProfile", "-NonInteractive", "-File", (Join-Path $Sb "agent.ps1")) + $AgentArgs) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.Environment["TEMP"] = (Join-Path $Sb "tmp")
    foreach ($k in @("BK_UPDATE_SELFCHECK", "STATUS_API_URL", "STATUS_AGENT_KEY", "STATUS_AUTO_UPDATE", "STATUS_REMOTE_ACTIONS_ENABLED", "STATUS_ALLOWED_ACTIONS")) {
        [void]$psi.Environment.Remove($k)
    }
    # The service stubs load only because Linux pwsh has no Get-Service.
    $psi.Environment["PSModulePath"] = "$Stubs$([System.IO.Path]::PathSeparator)$($env:PSModulePath)"
    $psi.Environment["BK_STUB_SERVICES"] = "wuauserv,MSSQL`$SQLEXPRESS,getty@tty1"
    $psi.Environment["BK_STUB_RESTART_LOG"] = (Join-Path $Sb "restarted.log")
    foreach ($k in $ExtraEnv.Keys) { $psi.Environment[$k] = $ExtraEnv[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(240000)) { $p.Kill($true); throw "agent run in $Sb did not finish in 240 s" }
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $o.Result; Err = $e.Result }
}

function Set-Response([int]$Code, $Body) {
    $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Compress -Depth 10 }
    [System.IO.File]::WriteAllText((Join-Path $MockDir "response.txt"), "$Code`n$json")
}

function Reset-MockLogs {
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $MockDir "requests.log"), (Join-Path $MockDir "downloads.log")
}

function Get-Posts {
    $f = Join-Path $MockDir "requests.log"
    if (-not (Test-Path $f)) { return @() }
    return @(Get-Content $f | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-ActionResults { return @(Get-Posts | Where-Object { $_.action_result } | ForEach-Object { $_.action_result }) }

function Get-Downloads {
    $f = Join-Path $MockDir "downloads.log"
    if (-not (Test-Path $f)) { return @() }
    return @(Get-Content $f | Where-Object { $_ })
}

function Get-Sha([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Get-Sig([string]$Type, [string]$Ts, [string]$Nonce) {
    $h = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Key))
    $raw = $h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("action=$Type|ts=$Ts|nonce=$Nonce"))
    return ([BitConverter]::ToString($raw)).Replace("-", "").ToLowerInvariant()
}

function Now { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# A signed pending_action answer. -Ts and -Id may be anything (strings too),
# -Sig overrides the computed signature. The default timestamp is 15 s ahead,
# still inside the agent's +-30 s window: an agent run on a loaded machine
# (or under emulation) can take well over 10 s before it checks the window.
function New-ActionAnswer {
    param([string]$Type = "restart_service", $Id = 41, $Ts = ((Now) + 15), [string]$Nonce = "n$(Get-Random)", [string]$Service = "wuauserv", [string]$Sig = "")
    if (-not $Sig) { $Sig = Get-Sig $Type ([string]$Ts) $Nonce }
    $act = [ordered]@{ action_id = $Id; action = $Type; timestamp = $Ts; nonce = $Nonce; signature = $Sig; service_name = $Service }
    return [ordered]@{ status = "ok"; pending_action = $act }
}

# The JSON a -DryRun prints between its log lines ("{" ... "}" on their own lines).
function Get-DryRunJson([string]$Out) {
    $lines = $Out -split "`r?`n"
    $s = [array]::IndexOf($lines, "{"); $e = [array]::LastIndexOf($lines, "}")
    if ($s -lt 0 -or $e -lt $s) { return $null }
    return (($lines[$s..$e] -join "`n") | ConvertFrom-Json)
}

# An update candidate made from the agent under test: another version, and
# optionally a transformation of the text before the sentinel is appended.
function New-UpdateFile {
    param([string]$Name, [string]$Version, [string]$SentinelVersion = $Version, [scriptblock]$Transform = $null, [switch]$NoSentinel, [switch]$Crlf)
    # '$$': a lone '$' followed by a name could be read as a substitution.
    $body = [regex]::Replace($SrcText, '(?m)^\$AGENT_VERSION = "[^"]+"', ('$$AGENT_VERSION = "' + $Version + '"'))
    $body = [regex]::Replace($body, '(?m)^# bk-agent-end .*\n?\z', "")
    if ($Transform) { $body = & $Transform $body }
    if (-not $NoSentinel) { $body = $body.TrimEnd("`n") + "`n# bk-agent-end $SentinelVersion`n" }
    if ($Crlf) { $body = $body -replace "`r?`n", "`r`n" }
    $path = Join-Path (Join-Path $MockDir "files") $Name
    [System.IO.File]::WriteAllText($path, $body, [System.Text.UTF8Encoding]::new($true))
    return $path
}

function New-UpdateAnswer([string]$FileName, [string]$Version, [string]$Sha = "") {
    if (-not $Sha) { $Sha = Get-Sha (Join-Path (Join-Path $MockDir "files") $FileName) }
    return [ordered]@{ status = "ok"; update_available = $true; latest_version = $Version; update_url = "$MockUrl/files/$FileName"; update_sha256 = $Sha }
}

# The refusal invariant: the script byte-identical, no .prev, no probation
# marker, no download left behind.
function Check-Untouched([string]$Name, [string]$Sb, [string]$OrigSha) {
    Check "$Name - agent.ps1 byte-identical" ((Get-Sha (Join-Path $Sb "agent.ps1")) -eq $OrigSha)
    Check "$Name - no .prev, no probation marker" (-not (Test-Path (Join-Path $Sb "agent.ps1.prev")) -and -not (Test-Path (Join-Path $Sb "agent.ps1.probation")))
    Check "$Name - no download left" (-not (Test-Path (Join-Path $Sb "agent-update.ps1")))
}

$okAnswer = [ordered]@{ status = "ok" }
$srcSha = Get-Sha $AgentSrc

# ------------------------------------------------------ dry run, self-check ---
$sb = New-Sandbox "dryrun"
$r = Invoke-Agent $sb @("-DryRun")
$j = Get-DryRunJson $r.Out
$expectedKeys = "agent_key,agent_type,auto_update,boot_time,cloud_provider,cpu,cpu_steal,discovered_services,disk_io_read,disk_io_write,dns_latency_ms,fork_rate,hdd,heavy_op_interval_hours,hostname,inode_usage,iowait,kernel,load1,load15,load5,net,net_errors,os,ports,processes,ram,ram_available_mb,ram_free_mb,ram_total_mb,ram_used_mb,reboot_required,smart,swap,tailscale_peers,tailscale_up,temperature,timezone,top_cpu_processes,top_ram_processes,ts3_process,ups_battery_pct,ups_status,uptime,usb_devices,version,virtualization,zerotier_networks,zombie_count"
Check "dry run: exit 0 and JSON" ($r.Code -eq 0 -and $null -ne $j) "exit $($r.Code)"
if ($j) {
    Check "dry run: agent_type powershell, version $SrcVersion" ($j.agent_type -eq "powershell" -and $j.version -eq $SrcVersion)
    Check "dry run: payload keys unchanged" ((($j.PSObject.Properties.Name | Sort-Object) -join ",") -eq $expectedKeys)
}

Reset-MockLogs
$sb = New-Sandbox "selfcheck"
$r = Invoke-Agent $sb @("-SelfCheck") @{ BK_UPDATE_SELFCHECK = "1" }
$sc = $null
try { $sc = $r.Out.Trim() | ConvertFrom-Json } catch {}
Check "self-check: exit 0, one JSON line" ($r.Code -eq 0 -and $null -ne $sc -and @($r.Out.Trim() -split "`n").Count -eq 1) "exit $($r.Code) out '$($r.Out)'"
Check "self-check: agent_type + agent_version" ($sc.agent_type -eq "powershell" -and $sc.agent_version -eq $SrcVersion)
Check "self-check: payload_keys 49" ($sc.payload_keys -eq 49)
Check "self-check: key never printed" ($r.Out -notmatch [regex]::Escape($Key))
Check "self-check: nothing sent" ((Get-Posts).Count -eq 0)
Check "self-check: no file written next to the agent" (@(Get-ChildItem $sb -File | Where-Object { $_.Name -notin @("agent.ps1", "agent.cfg") }).Count -eq 0) ((Get-ChildItem $sb -File).Name -join ",")
Check "self-check: no state in TEMP" (@(Get-ChildItem (Join-Path $sb "tmp")).Count -eq 0)

$r = Invoke-Agent $sb @("-SelfCheck")
Check "self-check without BK_UPDATE_SELFCHECK: exit 2, no JSON" ($r.Code -eq 2 -and $r.Out.Trim() -eq "") "exit $($r.Code) out '$($r.Out)'"
Check "self-check without BK_UPDATE_SELFCHECK: nothing sent, no log" ((Get-Posts).Count -eq 0 -and -not (Test-Path (Join-Path $sb "agent.log")))

# ------------------------------------------------------------ plain report ---
Reset-MockLogs
Set-Response 200 $okAnswer
$sb = New-Sandbox "report"
$r = Invoke-Agent $sb
$posts = Get-Posts
Check "report: exit 0, one POST" ($r.Code -eq 0 -and $posts.Count -eq 1) "exit $($r.Code) posts $($posts.Count)"
Check "report: posted payload keys unchanged" ((($posts[0].PSObject.Properties.Name | Sort-Object) -join ",") -eq $expectedKeys)
$lastOk = (Get-Content -Raw (Join-Path $sb "agent.ps1.last-ok") -ErrorAction SilentlyContinue)
Check "report: last-ok stamp '<version> <ts>'" ($lastOk -match "^$([regex]::Escape($SrcVersion)) [0-9]+\n\z") "'$lastOk'"

# --------------------------------------------------------- remote actions ---
function Invoke-ActionCase {
    param([string]$Name, $Answer, [string]$Allowed = "restart_service", [scriptblock]$Prepare = $null, [string]$Sandbox = "")
    Reset-MockLogs
    Set-Response 200 $Answer
    $s = if ($Sandbox) { $Sandbox } else { New-Sandbox "act-$Name" -Actions "1" -Allowed $Allowed }
    if ($Prepare) { & $Prepare $s }
    $res = Invoke-Agent $s
    $restarted = @()
    if (Test-Path (Join-Path $s "restarted.log")) { $restarted = @(Get-Content (Join-Path $s "restarted.log")) }
    return [pscustomobject]@{ Sb = $s; Run = $res; Results = @(Get-ActionResults); Restarted = $restarted }
}

# The digits-only gate: nothing is executed or even answered, the run goes on.
foreach ($c in @(
        @{ n = "ts with a command"; id = 41; ts = '1700000000$(touch /tmp/pwned)' },
        @{ n = "ts hex"; id = 41; ts = "0x6553F100" },
        @{ n = "ts exponent"; id = 41; ts = "1.7e9" },
        @{ n = "ts trailing newline"; id = 41; ts = "$(Now)`n" },
        @{ n = "id letters"; id = "41a"; ts = (Now) },
        @{ n = "id negative"; id = -41; ts = (Now) })) {
    $x = Invoke-ActionCase "digits" (New-ActionAnswer -Id $c.id -Ts $c.ts)
    Check "action gate, $($c.n): no result, no execution" ($x.Results.Count -eq 0 -and $x.Restarted.Count -eq 0) "results: $($x.Results | ConvertTo-Json -Compress)"
    Check "action gate, $($c.n): logged and run completed" ($x.Run.Code -eq 0 -and $x.Run.Out -match "nečíselné action_id nebo timestamp" -and $x.Run.Out -match "Hotovo")
}
Check "action gate: the command in the timestamp never ran" (-not (Test-Path "/tmp/pwned"))

# Service names: refused after the signature, before anything runs.
foreach ($n in @("*", "a b", "-rf", "..", "svc`n")) {
    $x = Invoke-ActionCase "svcbad" (New-ActionAnswer -Service $n)
    Check "restart_service '$($n -replace "`n", '\n')': refused, nothing restarted" ($x.Results.Count -eq 1 -and $x.Results[0].status -eq "failed" -and $x.Results[0].message -eq "Odmítnuto: neplatný název služby" -and $x.Restarted.Count -eq 0) "results: $($x.Results | ConvertTo-Json -Compress)"
}
foreach ($n in @("wuauserv", "MSSQL`$SQLEXPRESS", "getty@tty1")) {
    $x = Invoke-ActionCase "svcgood" (New-ActionAnswer -Service $n)
    Check "restart_service '$n': restarted" ($x.Results.Count -eq 1 -and $x.Results[0].status -eq "executed" -and $x.Results[0].message -eq "Služba '$n' restartována" -and ($x.Restarted -join "|") -ceq $n) "results: $($x.Results | ConvertTo-Json -Compress) restarted: $($x.Restarted -join '|')"
}

# Replay: the same signed answer twice executes once. 25 s ahead: both runs
# must check it inside its window, or the second is refused as expired and
# the test would pass without the nonce store.
$answer = New-ActionAnswer -Nonce "replay$(Get-Random)" -Ts ((Now) + 25)
$x1 = Invoke-ActionCase "replay" $answer
$x2 = Invoke-ActionCase "replay" $answer -Sandbox $x1.Sb
Check "replay: first answer executed" ($x1.Results.Count -eq 1 -and $x1.Results[0].status -eq "executed") "results: $($x1.Results | ConvertTo-Json -Compress)"
Check "replay: second answer refused" ($x2.Results.Count -eq 1 -and $x2.Results[0].message -eq "Odmítnuto: nonce už byl použit (opakovaná odpověď)") "results: $($x2.Results | ConvertTo-Json -Compress)"
Check "replay: the service restarted exactly once" ($x2.Restarted.Count -eq 1) "restarted: $($x2.Restarted -join '|')"
$nonces = @(Get-Content (Join-Path $x1.Sb "agent.ps1.nonces"))
Check "replay: nonce stored once" ($nonces.Count -eq 1 -and $nonces[0] -match "^[0-9]+ $($answer.pending_action.nonce)$") ($nonces -join "|")

$x = Invoke-ActionCase "noncedir" (New-ActionAnswer) -Prepare { param($s) New-Item -ItemType Directory -Path (Join-Path $s "agent.ps1.nonces.tmp") | Out-Null }
Check "nonce store not writable: refused, nothing restarted" ($x.Results.Count -eq 1 -and $x.Results[0].message -like "Odmítnuto: nonce nejde uložit*" -and $x.Restarted.Count -eq 0) "results: $($x.Results | ConvertTo-Json -Compress)"

$x = Invoke-ActionCase "nononce" (New-ActionAnswer -Nonce "")
Check "missing nonce: refused" ($x.Results.Count -eq 1 -and $x.Results[0].message -eq "Odmítnuto: nonce chybí nebo má nepovolené znaky") "results: $($x.Results | ConvertTo-Json -Compress)"

$x = Invoke-ActionCase "badsig" (New-ActionAnswer -Sig ("0" * 64))
Check "bad signature: refused, no nonce burnt" ($x.Results.Count -eq 1 -and $x.Results[0].message -eq "Neplatný HMAC podpis" -and -not (Test-Path (Join-Path $x.Sb "agent.ps1.nonces")) -and $x.Restarted.Count -eq 0) "results: $($x.Results | ConvertTo-Json -Compress)"

$x = Invoke-ActionCase "expired" (New-ActionAnswer -Ts ((Now) - 120))
Check "expired timestamp: refused" ($x.Results.Count -eq 1 -and $x.Results[0].message -eq "Vypršela platnost podpisu (>30s)" -and $x.Restarted.Count -eq 0) "results: $($x.Results | ConvertTo-Json -Compress)"

# restart_wan is signed but not on this agent's list. (reboot_server is never
# used here: Restart-Computer exists on Linux pwsh.)
$x = Invoke-ActionCase "notallowed" (New-ActionAnswer -Type "restart_wan")
Check "action not in ALLOWED_ACTIONS: refused" ($x.Results.Count -eq 1 -and $x.Results[0].message -eq "Odmítnuto: akce 'restart_wan' není v ALLOWED_ACTIONS") "results: $($x.Results | ConvertTo-Json -Compress)"
$x = Invoke-ActionCase "unknown" (New-ActionAnswer -Type "restart_wan") -Allowed "restart_service,restart_wan"
Check "allowed but unknown action: answered, not left 'sent'" ($x.Results.Count -eq 1 -and $x.Results[0].message -eq "Tato verze agenta akci 'restart_wan' nezná") "results: $($x.Results | ConvertTo-Json -Compress)"

Reset-MockLogs
Set-Response 200 (New-ActionAnswer)
$sb = New-Sandbox "actions-off"
$r = Invoke-Agent $sb
Check "remote actions off: nothing answered" ($r.Code -eq 0 -and (Get-ActionResults).Count -eq 0)

# ------------------------------------------------------------ self-update ---
function Invoke-UpdateCase {
    param([string]$Name, $Answer, [scriptblock]$Prepare = $null)
    Reset-MockLogs
    Set-Response 200 $Answer
    $s = New-Sandbox "upd-$Name" -AutoUpdate "1"
    if ($Prepare) { & $Prepare $s }
    $res = Invoke-Agent $s
    return [pscustomobject]@{ Sb = $s; Run = $res; Downloads = @(Get-Downloads) }
}

# Refusals first; each leaves the script exactly as it was.
New-UpdateFile "sha.ps1" "9.9.9" | Out-Null
$x = Invoke-UpdateCase "sha" (New-UpdateAnswer "sha.ps1" "9.9.9" ("ab" * 32))
Check "update, sha mismatch: refused" ($x.Run.Out -match "Checksum nesouhlasí")
Check-Untouched "update, sha mismatch" $x.Sb $srcSha
# The transport's fault, not the file's: fetched again on the next run.
Reset-MockLogs
$r = Invoke-Agent $x.Sb
Check "update, sha mismatch: tried again next run" ((Get-Downloads).Count -eq 1 -and -not (Test-Path (Join-Path $x.Sb "agent.ps1.rejected")))

New-UpdateFile "nosent.ps1" "9.9.9" -NoSentinel | Out-Null
$x = Invoke-UpdateCase "nosent" (New-UpdateAnswer "nosent.ps1" "9.9.9")
Check "update, no sentinel: refused" ($x.Run.Out -match "nekončí řádkem '# bk-agent-end 9.9.9'")
Check-Untouched "update, no sentinel" $x.Sb $srcSha
# A property of these bytes: not downloaded again for a day.
Reset-MockLogs
$r = Invoke-Agent $x.Sb
Check "update, no sentinel: the same file is not fetched again" ($r.Code -eq 0 -and (Get-Downloads).Count -eq 0 -and (Get-Sha (Join-Path $x.Sb "agent.ps1")) -eq $srcSha)

# Cut in half: still parses (the cut lands between statements), no end line.
$full = New-UpdateFile "cut-src.ps1" "9.9.9"
$lines = [System.IO.File]::ReadAllLines($full)
$cutAt = [int]($lines.Count / 2)
while ($lines[$cutAt] -ne "") { $cutAt++ }
[System.IO.File]::WriteAllLines((Join-Path (Join-Path $MockDir "files") "cut.ps1"), $lines[0..$cutAt])
$cutErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Join-Path $MockDir "files") "cut.ps1"), [ref]$null, [ref]$cutErrors)
$x = Invoke-UpdateCase "cut" (New-UpdateAnswer "cut.ps1" "9.9.9")
Check "update, truncated file (parses: $($cutErrors.Count -eq 0)): refused" ($x.Run.Out -match "nekončí řádkem")
Check-Untouched "update, truncated file" $x.Sb $srcSha

New-UpdateFile "sentver.ps1" "9.9.9" -SentinelVersion "9.9.8" | Out-Null
$x = Invoke-UpdateCase "sentver" (New-UpdateAnswer "sentver.ps1" "9.9.9")
Check "update, sentinel of another version: refused" ($x.Run.Out -match "nekončí řádkem '# bk-agent-end 9.9.9'")
Check-Untouched "update, sentinel of another version" $x.Sb $srcSha

New-UpdateFile "throw.ps1" "9.9.9" -Transform { param($t) $t -replace '(?m)^\$payload = @\{', ('throw "injected failure"' + "`n" + '$$payload = @{') } | Out-Null
$x = Invoke-UpdateCase "throw" (New-UpdateAnswer "throw.ps1" "9.9.9")
Check "update, self-check fails at run time: refused" ($x.Run.Out -match "self-check skončil kódem")
Check-Untouched "update, self-check fails at run time" $x.Sb $srcSha

New-UpdateFile "noise.ps1" "9.9.9" -Transform { param($t) $t -replace '(?m)^\$SelfCheckMode = \$false', ('$$SelfCheckMode = $$false' + "`n" + "[Console]::Out.WriteLine('noise')") } | Out-Null
$x = Invoke-UpdateCase "noise" (New-UpdateAnswer "noise.ps1" "9.9.9")
Check "update, self-check prints more than one object: refused" ($x.Run.Out -match "self-check nevypsal jeden JSON objekt")
Check-Untouched "update, self-check prints more than one object" $x.Sb $srcSha

# The file says 9.9.8 inside but is offered (and ends) as 9.9.9.
New-UpdateFile "innerver.ps1" "9.9.8" -SentinelVersion "9.9.9" | Out-Null
$x = Invoke-UpdateCase "innerver" (New-UpdateAnswer "innerver.ps1" "9.9.9")
Check "update, self-check reports another version: refused" ($x.Run.Out -match "self-check hlásí verzi '9.9.8'")
Check-Untouched "update, self-check reports another version" $x.Sb $srcSha

# Today's release has no -SelfCheck: a file like it is refused, not run.
$legacy = New-UpdateFile "legacy.ps1" "9.9.9" -Transform { param($t) $t -replace '(?m)^\s*\[switch\]\$SelfCheck\r?\n', '' -replace '(?m)^    \[alias\("Print"\)\]\[switch\]\$DryRun,', '    [alias("Print")][switch]$DryRun' }
$x = Invoke-UpdateCase "legacy" (New-UpdateAnswer "legacy.ps1" "9.9.9")
Check "update, file without -SelfCheck: refused" ($x.Run.Out -match "self-check skončil kódem")
Check-Untouched "update, file without -SelfCheck" $x.Sb $srcSha

foreach ($v in @("0.0.9", $SrcVersion, "1.0-beta")) {
    New-UpdateFile "old.ps1" $v | Out-Null
    $x = Invoke-UpdateCase "old" (New-UpdateAnswer "old.ps1" $v)
    Check "update, offered '$v' (not newer than $SrcVersion): refused before download" ($x.Downloads.Count -eq 0 -and $x.Run.Code -eq 0)
    Check-Untouched "update, offered '$v'" $x.Sb $srcSha
}

# Hangs in its self-check: killed at the limit, refused.
New-UpdateFile "hang.ps1" "9.9.9" -Transform { param($t) $t -replace '(?m)^(\s*)\$SelfCheckMode = \$true', ('$1$$SelfCheckMode = $$true' + "`n" + '$1Start-Sleep -Seconds 900') } | Out-Null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$x = Invoke-UpdateCase "hang" (New-UpdateAnswer "hang.ps1" "9.9.9")
Check "update, self-check hangs: refused at the time limit ($([int]$sw.Elapsed.TotalSeconds) s)" ($x.Run.Out -match "self-check nedoběhl do 60 s")
Check-Untouched "update, self-check hangs" $x.Sb $srcSha
$left = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "agent-update\.ps1" })
Check "update, self-check hangs: child killed" ($left.Count -eq 0)

# Exits 0 at once, but leaves a process holding its stdout: the reads of that
# pipe are bounded too, or this run (and every later one, IgnoreNew) would
# wait for as long as that process lives - 151 s here.
New-UpdateFile "orphan.ps1" "9.9.9" -Transform { param($t) $t -replace '(?m)^(\s*)\$SelfCheckMode = \$true', ('$1$$SelfCheckMode = $$true' + "`n" + '$1Start-Process -FilePath /bin/sleep -ArgumentList 151 -NoNewWindow') } | Out-Null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$x = Invoke-UpdateCase "orphan" (New-UpdateAnswer "orphan.ps1" "9.9.9")
$secs = [int]$sw.Elapsed.TotalSeconds
Check "update, self-check leaves a process on its stdout: refused without waiting for it ($secs s)" ($x.Run.Out -match "nechal běžet proces" -and $secs -lt 45) $x.Run.Out
Check-Untouched "update, self-check leaves a process on its stdout" $x.Sb $srcSha
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "sleep 151" } | Stop-Process -Force -ErrorAction SilentlyContinue

# The good update, LF and CRLF.
foreach ($variant in @("lf", "crlf")) {
    $good = New-UpdateFile "good-$variant.ps1" "9.9.9" -Crlf:($variant -eq "crlf")
    $x = Invoke-UpdateCase "good-$variant" (New-UpdateAnswer "good-$variant.ps1" "9.9.9")
    $sb = $x.Sb
    Check "update ($variant): applied" ($x.Run.Out -match "OK: Agent aktualizován na verzi 9.9.9" -and (Get-Sha (Join-Path $sb "agent.ps1")) -eq (Get-Sha $good)) $x.Run.Out
    Check "update ($variant): old version kept as .prev" ((Get-Sha (Join-Path $sb "agent.ps1.prev")) -eq $srcSha)
    $m = Get-Content -Raw (Join-Path $sb "agent.ps1.probation") -ErrorAction SilentlyContinue | ConvertFrom-Json
    Check "update ($variant): probation marker" ($m.version -eq "9.9.9" -and $m.from -eq $SrcVersion -and $m.sha256 -eq (Get-Sha $good) -and $m.runs -eq 0 -and $m.refused -eq 0)
    Check "update ($variant): no download left" (-not (Test-Path (Join-Path $sb "agent-update.ps1")))
}

# The new version's first accepted report ends the probation.
Reset-MockLogs
Set-Response 200 $okAnswer
$r = Invoke-Agent $sb
$posts = @(Get-Posts)
Check "probation: new version reports 9.9.9" ($r.Code -eq 0 -and $posts.Count -eq 1 -and $posts[0].version -eq "9.9.9")
Check "probation: last-ok stamped, marker gone, new version stays" ((Get-Content -Raw (Join-Path $sb "agent.ps1.last-ok")) -match "^9\.9\.9 [0-9]+" -and -not (Test-Path (Join-Path $sb "agent.ps1.probation")) -and (Get-Sha (Join-Path $sb "agent.ps1")) -eq (Get-Sha $good))

# Rollback after 3 reports the server refused.
$x = Invoke-UpdateCase "rb" (New-UpdateAnswer "good-lf.ps1" "9.9.9")
$sb = $x.Sb
$goodSha = Get-Sha (Join-Path (Join-Path $MockDir "files") "good-lf.ps1")
Set-Response 400 '{"error":"invalid payload"}'
foreach ($i in 1..3) { $r = Invoke-Agent $sb }
$m = Get-Content -Raw (Join-Path $sb "agent.ps1.probation") | ConvertFrom-Json
Check "rollback: 3 refused reports counted, still 9.9.9" ($m.refused -eq 3 -and $m.runs -eq 3 -and (Get-Sha (Join-Path $sb "agent.ps1")) -eq $goodSha) ($m | ConvertTo-Json -Compress)
Reset-MockLogs
$r = Invoke-Agent $sb
Check "rollback: 4th run restores the previous version" ($r.Code -eq 1 -and (Get-Sha (Join-Path $sb "agent.ps1")) -eq $srcSha -and $r.Out -match "Vrácena předchozí verze $([regex]::Escape($SrcVersion))") $r.Out
Check "rollback: nothing sent by the rolled-back run" ((Get-Posts).Count -eq 0)
Check "rollback: marker gone, sha remembered" (-not (Test-Path (Join-Path $sb "agent.ps1.probation")) -and (Get-Content -Raw (Join-Path $sb "agent.ps1.rejected")) -match "^$goodSha 9\.9\.9 [0-9]+")
# The restored version is offered the same file again: not taken.
Reset-MockLogs
Set-Response 200 (New-UpdateAnswer "good-lf.ps1" "9.9.9")
$r = Invoke-Agent $sb
Check "rollback: the same file is not taken again" ($r.Code -eq 0 -and (Get-Downloads).Count -eq 0 -and (Get-Sha (Join-Path $sb "agent.ps1")) -eq $srcSha)
# A fixed file under the same version (another sha) is taken.
New-UpdateFile "fixed.ps1" "9.9.9" -Transform { param($t) $t + "`n# fixed`n" } | Out-Null
Reset-MockLogs
Set-Response 200 (New-UpdateAnswer "fixed.ps1" "9.9.9")
$r = Invoke-Agent $sb
Check "rollback: a fixed file of the same version is taken" ((Get-Sha (Join-Path $sb "agent.ps1")) -eq (Get-Sha (Join-Path (Join-Path $MockDir "files") "fixed.ps1")))

# Rollback after 30 runs without an accepted report (the network, a crash).
$x = Invoke-UpdateCase "rbruns" (New-UpdateAnswer "good-lf.ps1" "9.9.9")
$sb = $x.Sb
$mp = Join-Path $sb "agent.ps1.probation"
$m = Get-Content -Raw $mp | ConvertFrom-Json
$m.runs = 29
[System.IO.File]::WriteAllText($mp, ($m | ConvertTo-Json -Compress))
Set-Response 200 $okAnswer
# Run 30 has no answer (nothing listens on port 9): counted, not rolled back.
# agent.cfg wins over the environment, so the cfg is pointed there for one run.
$cfgPath = Join-Path $sb "agent.cfg"
$cfgGood = Get-Content $cfgPath
Set-Content $cfgPath ($cfgGood -replace '^API_URL=.*', 'API_URL=http://127.0.0.1:9/agent_api.php')
$r = Invoke-Agent $sb
Set-Content $cfgPath $cfgGood
Check "rollback: run 30 without a report still on probation" ((Get-Sha (Join-Path $sb "agent.ps1")) -eq $goodSha -and (Get-Content -Raw $mp | ConvertFrom-Json).runs -eq 30)
Reset-MockLogs
$r = Invoke-Agent $sb
Check "rollback: run 31 restores the previous version" ($r.Code -eq 1 -and (Get-Sha (Join-Path $sb "agent.ps1")) -eq $srcSha -and (Get-Posts).Count -eq 0)

# A marker for another version (a swap undone by hand) is dropped, nothing rolls back.
$sb = New-Sandbox "stale" -AutoUpdate "0"
Copy-Item $AgentSrc (Join-Path $sb "agent.ps1.prev")
[System.IO.File]::WriteAllText((Join-Path $sb "agent.ps1.probation"), '{"version":"7.7.7","from":"0.0.1","sha256":"","since":0,"runs":99,"refused":9}')
Set-Response 200 $okAnswer
$r = Invoke-Agent $sb
Check "stale marker: dropped, agent untouched, report sent" ($r.Code -eq 0 -and -not (Test-Path (Join-Path $sb "agent.ps1.probation")) -and (Get-Sha (Join-Path $sb "agent.ps1")) -eq $srcSha)

# ------------------------------------------------------------------ result ---
Write-Host ""
Write-Host "agent.ps1 tests: $($script:Passed) passed, $($script:Failed.Count) failed"
if ($script:Failed.Count -gt 0) {
    $script:Failed | ForEach-Object { Write-Host "  failed: $_" }
    exit 1
}
exit 0
