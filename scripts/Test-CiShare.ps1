#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests ci/Invoke-CiShare.ps1: what `task test:scripts` and CI's script-tests job run.

.DESCRIPTION
    Runs the script in a pwsh of its own for each case, with USERPROFILE and HOME in a
    scratch folder that holds a limits.json or none, and a pwsh child as the command, which
    prints the processors its affinity allows and the three variables it was given. Checks
    the share each case should give: CI_CPUS's, else the runners' JobCpus, else 2, and no
    more than the processors there are; that the command's exit code comes back; and that
    an argument starting with a dash reaches the command. Prints ok or FAIL for each case,
    and exits 1 when any fails.

.EXAMPLE
    pwsh scripts/Test-CiShare.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$share = Join-Path $PSScriptRoot '../ci/Invoke-CiShare.ps1'
$pwsh = (Get-Process -Id $PID).Path
$allowed = [long] [Diagnostics.Process]::GetCurrentProcess().ProcessorAffinity
$available = @(0..63 | Where-Object { $allowed -band (1L -shl $_) }).Count
# What the command prints: the processors it may use, then the three variables.
$report = '$a = [long] [Diagnostics.Process]::GetCurrentProcess().ProcessorAffinity; ' +
'"$(@(0..63 | Where-Object { $a -band (1L -shl $_) }).Count) $env:CI_CPUS $env:GOMAXPROCS $env:DOTNET_PROCESSOR_COUNT"'

$cases = @(
    @{ Name = 'CI_CPUS gives the share'; CiCpus = '2'; Limits = 3; Want = 2 }
    @{ Name = 'without CI_CPUS, the runners'' JobCpus'; CiCpus = ''; Limits = 3; Want = 3 }
    @{ Name = 'without either, 2'; CiCpus = ''; Limits = 0; Want = 2 }
    @{ Name = 'a CI_CPUS that isn''t a number is passed over'; CiCpus = 'two'; Limits = 0; Want = 2 }
    @{ Name = 'no more than the processors there are'; CiCpus = '999'; Limits = 0; Want = $available }
)

$failed = 0
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ci-share-test-{0}' -f [guid]::NewGuid())
$saved = @{ USERPROFILE = $env:USERPROFILE; HOME = $env:HOME; CI_CPUS = $env:CI_CPUS }
try {
    New-Item -ItemType Directory -Path (Join-Path $scratch '.ci-runner') | Out-Null
    $env:USERPROFILE = $scratch
    $env:HOME = $scratch
    foreach ($case in $cases) {
        $limits = Join-Path $scratch '.ci-runner/limits.json'
        Remove-Item -LiteralPath $limits -ErrorAction SilentlyContinue
        if ($case.Limits) {
            @{ JobCpus = $case.Limits } | ConvertTo-Json | Set-Content -LiteralPath $limits
        }
        $env:CI_CPUS = $case.CiCpus
        $want = [Math]::Min($case.Want, $available)
        $out = & $pwsh -NoProfile -File $share $pwsh -NoProfile -Command $report 2>&1 | Select-Object -Last 1
        if ($LASTEXITCODE -eq 0 -and "$out" -eq "$want $want $want $want") {
            Write-Host "ok    $($case.Name)"
        } else {
            $failed++
            Write-Host "FAIL  $($case.Name): exit $LASTEXITCODE, printed '$out', want '$want $want $want $want'"
        }
    }

    $env:CI_CPUS = '1'
    & $pwsh -NoProfile -File $share $pwsh -NoProfile -Command 'exit 7' | Out-Null
    if ($LASTEXITCODE -eq 7) {
        Write-Host 'ok    the command''s exit code comes back'
    } else {
        $failed++
        Write-Host "FAIL  the command's exit code comes back: exit $LASTEXITCODE, want 7"
    }
} finally {
    foreach ($name in $saved.Keys) {
        Set-Item -Path "Env:$name" -Value $saved[$name]
    }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
exit $(if ($failed) { 1 } else { 0 })
