# Stand-ins for the Windows-only service cmdlets, for the agent.ps1 tests on
# Linux pwsh. They are found by module auto-loading (PSModulePath points
# here in the agent's test runs) only because Linux pwsh has no Get-Service
# of its own. Without them an action that passed every gate ended in a
# CommandNotFound and left no trace, so "executed once" could not be seen.

# The services that "exist": a comma list in BK_STUB_SERVICES.
function Get-Service {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string[]]$Name)
    $known = @(($env:BK_STUB_SERVICES -split ",") | Where-Object { $_ })
    foreach ($n in $Name) {
        if ($known -ccontains $n) { [pscustomobject]@{ Name = $n; Status = "Running" } }
    }
}

# Every restart is one line in BK_STUB_RESTART_LOG: the tests count them.
function Restart-Service {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string[]]$Name, [switch]$Force)
    foreach ($n in $Name) { Add-Content -Path $env:BK_STUB_RESTART_LOG -Value $n }
}

Export-ModuleMember -Function Get-Service, Restart-Service
