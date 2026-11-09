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
    submodule's own files are left to its CI. A tracked file deleted in the working tree
    and not yet committed is skipped.

    PSScriptAnalyzer 1.25.0, the newest release, races with itself on a large file when
    it starts cold: it throws a NullReferenceException, or "more than one dynamic module
    in each dynamic assembly", and then passes once warm. The NullReferenceException is
    UseCorrectCasing reading a command's parameters while another rule, run beside it,
    builds them (CommandInfo.Parameters): SharedDeploy.psm1 crashed six tries in six once
    it grew (2026-11-09). So UseCorrectCasing runs on each script in a pass of its own and
    every other rule in a second; the two report what one pass did. A module (.psm1) races
    in more rules than that, those that read its Export-ModuleMember (AvoidReservedChar-
    InCmdlet among them), so a module is analyzed one rule at a time: SharedDeploy.psm1's
    74 rules in about 13 seconds, with no crash. A crash of either kind is still tried
    again, up to six times in all; a finding is never retried.

    Each new try is the whole lint in a fresh pwsh process, on the same PSScriptAnalyzer
    version, so the findings reported always come from a session that never crashed. A
    session that has crashed can report what isn't there: Home Library's CI, retrying in
    the same session (2026-11-07), flagged `Split-Path -Parent $PSScriptRoot` with
    PSUseCmdletCorrectly, where every clean run passes it.

.PARAMETER Path
    The repo to lint. Defaults to the current folder.

.PARAMETER Attempt
    Which try this is; the script passes it to the fresh process it starts after a crash.

.PARAMETER AnalyzerVersion
    The PSScriptAnalyzer version to import; the script passes the one it ran to the fresh
    process, so every try runs the same version.

.EXAMPLE
    pwsh shared/lint/pwsh/Invoke-ScriptLint.ps1
#>
[CmdletBinding()]
param(
    [string] $Path = '.',

    [ValidateRange(1, 6)]
    [int] $Attempt = 1,

    [string] $AnalyzerVersion
)

$ErrorActionPreference = 'Stop'
$settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    throw 'PSScriptAnalyzer is not installed: Install-PSResource PSScriptAnalyzer -Version 1.25.0 -Scope CurrentUser'
}
if ($AnalyzerVersion) {
    Import-Module PSScriptAnalyzer -RequiredVersion $AnalyzerVersion
}

# Every rule the settings run, for a module's one-at-a-time pass: all of PSScriptAnalyzer's,
# less those the settings exclude. A formatting rule they leave switched off reports nothing
# when asked for alone, as in one pass.
$excluded = @((Import-PowerShellDataFile -LiteralPath $settings).ExcludeRules)
$rules = @(Get-ScriptAnalyzerRule | Where-Object { $_.RuleName -notin $excluded } | ForEach-Object RuleName)

$crash = $null
Push-Location -LiteralPath $Path
try {
    # A tracked file deleted but not yet committed is still listed; there is nothing to lint.
    $files = @(git ls-files '*.ps1' '*.psm1' '*.psd1' | Where-Object { Test-Path -LiteralPath $_ })
    $findings = foreach ($file in $files) {
        $pass = 'UseCorrectCasing'
        try {
            if ($file -like '*.psm1') {
                # A module, one rule at a time (see above).
                foreach ($rule in $rules) {
                    $pass = $rule
                    Invoke-ScriptAnalyzer -Path $file -Settings $settings -IncludeRule $rule -ErrorAction Stop
                }
            } else {
                # UseCorrectCasing alone, then the rest: run together they race (see above).
                Invoke-ScriptAnalyzer -Path $file -Settings $settings -IncludeRule PSUseCorrectCasing -ErrorAction Stop
                $pass = 'the other rules'
                Invoke-ScriptAnalyzer -Path $file -Settings $settings -ExcludeRule PSUseCorrectCasing -ErrorAction Stop
            }
        } catch {
            $crash = "PSScriptAnalyzer crashed on ${file}, in $pass (attempt $Attempt of 6): $($_.Exception.Message)"
            break
        }
    }
} finally {
    Pop-Location
}

if ($crash) {
    if ($Attempt -ge 6) {
        throw $crash
    }
    # This session's analyzer may now report what isn't there, so nothing it found counts:
    # the whole lint runs again in a fresh process.
    Write-Warning "$crash Trying again in a fresh process."
    $version = (Get-Module PSScriptAnalyzer | Select-Object -First 1).Version
    $retry = @('-NoProfile', '-File', $PSCommandPath, '-Path', (Resolve-Path -LiteralPath $Path).Path, '-Attempt', ($Attempt + 1))
    if ($version) {
        $retry += @('-AnalyzerVersion', "$version")
    }
    & (Get-Process -Id $PID).Path @retry
    exit $LASTEXITCODE
}

$findings | Format-Table -AutoSize | Out-String | Write-Output
Write-Output "$($files.Count) files, $(@($findings).Count) findings"
if ($findings) {
    exit 1
}
