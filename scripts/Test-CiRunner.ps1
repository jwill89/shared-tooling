#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests runner/CiRunner.psm1's limits: what `task test:scripts` and CI's script-tests job
    run.

.DESCRIPTION
    Imports the module with its state folder in a scratch folder, then checks, inside the
    module's scope:

      Get-CiLimit    the limits the jobs share and each job's share of the CPUs, from a
                     config and a distro's processors and memory: the defaults, and each
                     setting given, too large or too small for the distro
      Read-CiConfig  the CPU settings it refuses: Cpus, MaxJobs and JobCpus must each be
                     a whole number of 1 or more
      Remove-CiGitHubRunner
                     with gh swapped for a function in the module's scope: it deregisters
                     only this machine's runners, lists the ones GitHub keeps as running a
                     job in one warning, and warns apart for any other refusal

    Prints ok or FAIL for each case, and exits 1 when any fails. Nothing here starts WSL,
    Docker or gh.

.EXAMPLE
    pwsh scripts/Test-CiRunner.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ci-runner-test-{0}' -f [guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
# The module keeps its state under USERPROFILE, which Linux doesn't set.
$userProfile = $env:USERPROFILE
$env:USERPROFILE = $scratch
$failed = 0
try {
    $module = Import-Module (Join-Path $PSScriptRoot '../runner/CiRunner.psm1') -PassThru -Force

    $limitCases = @(
        @{
            Name = 'by default, half the processors, two CPUs a job at least, and memory for 1.5 GB a job'
            Config = @{}; Processors = 32; MemoryTotal = 15GB
            Want = @{ Cpus = 16; AllowedCpus = '16-31'; MaxJobs = 7; JobCpus = 2 }
        }
        @{
            Name = 'by default with memory to spare, as many jobs as give each two CPUs'
            Config = @{}; Processors = 8; MemoryTotal = 64GB
            Want = @{ Cpus = 4; AllowedCpus = '4-7'; MaxJobs = 2; JobCpus = 2 }
        }
        @{
            Name = 'by default on two processors, one job on the last'
            Config = @{}; Processors = 2; MemoryTotal = 8GB
            Want = @{ Cpus = 1; AllowedCpus = '1-1'; MaxJobs = 1; JobCpus = 1 }
        }
        @{
            Name = 'Cpus above the processors is held to them'
            Config = @{ Cpus = 40 }; Processors = 32; MemoryTotal = 64GB
            Want = @{ Cpus = 32; AllowedCpus = '0-31'; MaxJobs = 16; JobCpus = 2 }
        }
        @{
            Name = 'Memory given sets MaxJobs'
            Config = @{ Memory = '6g' }; Processors = 32; MemoryTotal = 64GB
            Want = @{ Cpus = 16; MaxJobs = 4; JobCpus = 4 }
        }
        @{
            Name = 'more jobs than CPUs gives each one'
            Config = @{ Cpus = 16; MaxJobs = 20 }; Processors = 32; MemoryTotal = 64GB
            Want = @{ Cpus = 16; MaxJobs = 20; JobCpus = 1 }
        }
        @{
            Name = 'JobCpus given is each job''s share'
            Config = @{ JobCpus = 3 }; Processors = 32; MemoryTotal = 15GB
            Want = @{ Cpus = 16; MaxJobs = 7; JobCpus = 3 }
        }
        @{
            Name = 'JobCpus above Cpus is held to them'
            Config = @{ Cpus = 4; JobCpus = 8 }; Processors = 32; MemoryTotal = 64GB
            Want = @{ Cpus = 4; AllowedCpus = '28-31'; MaxJobs = 2; JobCpus = 4 }
        }
    )
    foreach ($case in $limitCases) {
        $limits = & $module { param($c, $p, $m) Get-CiLimit -Config $c -Processors $p -MemoryTotal $m } $case.Config $case.Processors $case.MemoryTotal
        $wrong = @($case.Want.Keys | Where-Object { "$($limits.$_)" -ne "$($case.Want[$_])" } |
                ForEach-Object { "$_ is $($limits.$_), not $($case.Want[$_])" })
        if ($wrong) {
            $failed++
            Write-Host "FAIL  Get-CiLimit: $($case.Name): $($wrong -join '; ')"
        } else {
            Write-Host "ok    Get-CiLimit: $($case.Name)"
        }
    }

    $configCases = @(
        @{ Name = 'a whole number of CPUs is taken'; Lines = 'Cpus = 8'; Error = '' }
        @{ Name = 'a share of the CPUs is taken'; Lines = 'JobCpus = 2'; Error = '' }
        @{ Name = 'a fraction of a CPU is refused'; Lines = 'Cpus = 2.5'; Error = "Cpus '2.5' isn't a whole number" }
        @{ Name = 'no CPUs is refused'; Lines = 'Cpus = 0'; Error = "Cpus '0' isn't a whole number" }
        @{ Name = 'a share of no CPUs is refused'; Lines = 'JobCpus = 0'; Error = "JobCpus '0' isn't a whole number" }
        @{ Name = 'a share in words is refused'; Lines = "JobCpus = 'two'"; Error = "JobCpus 'two' isn't a whole number" }
        @{ Name = 'no jobs is refused'; Lines = 'MaxJobs = 0'; Error = "MaxJobs '0' isn't a whole number" }
    )
    $path = Join-Path $scratch 'runners.psd1'
    foreach ($case in $configCases) {
        Set-Content -LiteralPath $path -Value "@{`n    Owner = 'owner'`n    Repos = @('app')`n    $($case.Lines)`n}"
        $got = try {
            & $module { param($p) Read-CiConfig -Path $p } $path | Out-Null
            ''
        } catch {
            "$_"
        }
        $pass = if ($case.Error) { $got.Contains($case.Error) } else { -not $got }
        if ($pass) {
            Write-Host "ok    Read-CiConfig: $($case.Name)"
        } else {
            $failed++
            Write-Host "FAIL  Read-CiConfig: $($case.Name): $(if ($got) { $got } else { 'no error' })"
        }
    }

    # GitHub's answers for one repo: runner 1 still running a job, 2 removed, 3 refused for
    # another reason, and 4 another machine's.
    $removal = & $module {
        param($config)
        $script:ghCalls = [System.Collections.Generic.List[string]]::new()
        function script:gh {
            $line = $args -join ' '
            $script:ghCalls.Add($line)
            $code = 0
            $output = @()
            if ($line -match '^api repos/owner/app/actions/runners ') {
                $output = "1`twsl-busy`toffline`ttrue", "2`twsl-idle`toffline`tfalse", "3`twsl-down`toffline`tfalse", "4`tother-1`toffline`tfalse"
            } elseif ($line -match 'DELETE repos/owner/app/actions/runners/1$') {
                $code = 1
                $output = 'gh: Bad request - Runner wsl-busy is currently running a job and cannot be deleted. (HTTP 422)'
            } elseif ($line -match 'DELETE repos/owner/app/actions/runners/3$') {
                $code = 1
                $output = 'gh: Server Error (HTTP 500)'
            }
            # A function sets no exit code of its own, so the caller's check reads this one.
            Set-Variable -Name LASTEXITCODE -Value $code -Scope Global
            $output
        }
        try {
            $warnings = $null
            Remove-CiGitHubRunner -Config $config -All -WarningVariable warnings -WarningAction SilentlyContinue
            [pscustomobject]@{ Warnings = @($warnings | ForEach-Object { "$_" }); Calls = @($script:ghCalls) }
        } finally {
            Remove-Item -LiteralPath Function:\gh
        }
    } @{ Owner = 'owner'; Repos = @('app'); Name = 'wsl' }
    $deletes = @($removal.Calls | Where-Object { $_ -match 'DELETE' } | ForEach-Object { ($_ -split '/')[-1] })
    $removalCases = @(
        @{ Name = "deletes this machine's runners only"; Pass = ($deletes -join ',') -eq '1,2,3' }
        @{ Name = 'lists the runners GitHub keeps in one warning'; Pass = @($removal.Warnings | Where-Object { $_ -match 'kept 1 runner\(s\).*app/wsl-busy' }).Count -eq 1 }
        @{ Name = 'warns apart for any other refusal'; Pass = @($removal.Warnings | Where-Object { $_ -match "Couldn't deregister app/wsl-down: .*HTTP 500" }).Count -eq 1 }
        @{ Name = 'warns nothing else'; Pass = $removal.Warnings.Count -eq 2 }
    )
    foreach ($case in $removalCases) {
        if ($case.Pass) {
            Write-Host "ok    Remove-CiGitHubRunner: $($case.Name)"
        } else {
            $failed++
            Write-Host "FAIL  Remove-CiGitHubRunner: $($case.Name): deleted $($deletes -join ','); warned $($removal.Warnings -join ' | ')"
        }
    }
} finally {
    $env:USERPROFILE = $userProfile
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
exit $(if ($failed) { 1 } else { 0 })
