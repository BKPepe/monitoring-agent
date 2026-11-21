@{
    RootModule = 'BkWindowsStubs.psm1'
    ModuleVersion = '1.0.0'
    GUID = '5b0f3c0e-3f4c-4d7e-9a57-2f1f2b9c6a11'
    Description = 'Get-Service / Restart-Service stand-ins for the agent.ps1 tests on Linux.'
    FunctionsToExport = @('Get-Service', 'Restart-Service')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
