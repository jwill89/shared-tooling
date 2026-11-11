@{
    RootModule           = 'SharedDeploy.psm1'
    ModuleVersion        = '2.7.0'
    GUID                 = 'b0ff08a1-40b7-4d93-9ce6-4b21fc3f3eb1'
    Author               = 'James Will'
    Copyright            = '(c) 2026 James Will'
    Description          = 'One archive, one held SSH connection, atomic swaps, service restarts, plugin publishing, smoke checks and rollback, for PowerShell deploy scripts.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Write-Step'
        'Write-Ok'
        'Exit-Deploy'
        'Resolve-DeploySetting'
        'Resolve-PuttyTool'
        'Resolve-TarTool'
        'Resolve-DeployConnection'
        'Open-DeployConnection'
        'Close-DeployConnection'
        'Invoke-RemoteWithRetry'
        'Invoke-Remote'
        'Invoke-RemoteStep'
        'Format-RemoteScript'
        'Compress-DeployArchive'
        'Invoke-Upload'
        'Send-File'
        'Get-File'
        'Send-FileVerified'
        'Restore-Env'
        'Invoke-GoBuild'
        'Invoke-NpmBuild'
        'Invoke-PluginBuild'
        'Assert-CleanWorkingTree'
        'Get-ReleaseTag'
        'Get-DeployRelease'
        'Get-DeployedRelease'
        'Set-DeployedRelease'
        'New-ReleaseTree'
        'Remove-ReleaseTree'
        'Invoke-DeployBundle'
        'Install-ServiceBinary'
        'Restore-ServiceBinary'
        'Switch-RemoteDirectory'
        'Restore-RemoteDirectory'
        'Switch-RemoteItemSet'
        'Restore-RemoteItemSet'
        'Backup-RemoteDatabase'
        'Export-PluginRepository'
        'Publish-PluginRepository'
        'Install-BackupTimer'
        'Copy-LiveDatabase'
        'Invoke-SmokeCheck'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('Fail')
    PrivateData          = @{
        PSData = @{
            Tags         = @('deploy', 'putty', 'systemd', 'rollback', 'smoke-test', 'dalamud')
            ProjectUri   = 'https://github.com/jwill89/shared-tooling'
            ReleaseNotes = 'https://github.com/jwill89/shared-tooling/blob/main/CHANGELOG.md'
        }
    }
}
