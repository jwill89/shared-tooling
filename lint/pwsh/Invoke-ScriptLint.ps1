#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs PSScriptAnalyzer, with the shared settings, on every PowerShell file the repo
    tracks.

.DESCRIPTION
    The one way every repo lints its scripts: `task shared:lint:scripts` locally and the
    shared pwsh.yml workflow in CI both run this, so the two can't drift. Tracked files
    only, so an ignored deploy.config.ps1 is never read, and the shared-tooling
    submodule's own files are left to its CI.

    PSScriptAnalyzer 1.25.0, the newest release, races with itself on a large file when
    it starts cold: it throws a NullReferenceException, or "more than one dynamic module
    in each dynamic assembly", and then passes once warm. Locally a process crashed at
    most twice before passing; GitHub's Linux runner crashed three times in a row. So a
    crash is tried again, up to six times in all; a finding is never retried.

.PARAMETER Path
    The repo to lint. Defaults to the current folder.

.EXAMPLE
    pwsh shared/lint/pwsh/Invoke-ScriptLint.ps1
#>
[CmdletBinding()]
param(
    [string] $Path = '.'
)

$ErrorActionPreference = 'Stop'
$settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    throw 'PSScriptAnalyzer is not installed: Install-PSResource PSScriptAnalyzer -Version 1.25.0 -Scope CurrentUser'
}

Push-Location -LiteralPath $Path
try {
    $files = @(git ls-files '*.ps1' '*.psm1' '*.psd1')
    $findings = foreach ($file in $files) {
        for ($try = 1; ; $try++) {
            try {
                Invoke-ScriptAnalyzer -Path $file -Settings $settings -ErrorAction Stop
                break
            } catch {
                if ($try -ge 6) {
                    throw
                }
                Write-Warning "PSScriptAnalyzer crashed on ${file} (attempt $try of 6): $($_.Exception.Message) Trying again."
            }
        }
    }
} finally {
    Pop-Location
}

$findings | Format-Table -AutoSize | Out-String | Write-Output
Write-Output "$($files.Count) files, $(@($findings).Count) findings"
if ($findings) {
    exit 1
}
