#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs a command, `task test` by default, with the CPUs a job on the self-hosted runners
    has: what `task shared:ci:share` runs.

.DESCRIPTION
    A job on the runners gets a share of the machine's CPUs and is told it in CI_CPUS,
    GOMAXPROCS and DOTNET_PROCESSOR_COUNT (runner/README.md), and its tools size their
    workers to it: the shared Vitest preset runs one worker for each of those CPUs but one,
    go test that many packages at once. This sets the same three and holds the command,
    and everything it starts, to that many of this machine's logical processors (the last
    of those this process may use; through the affinity it inherits on Windows, through
    taskset on Linux), so a test that passes only with a desk's spare CPUs fails here as
    it would in CI.

    The share is CI_CPUS when it is set already (the task's CPUS=), else the runners'
    JobCpus from the limits.json each start of the runners writes to
    %USERPROFILE%\.ci-runner, else 2. Nothing else about CI changes: CI stays unset, so
    the tools keep their local settings (the browser an end-to-end suite runs, say).

    Every argument is the command's, so one that starts with a dash reaches it as it is;
    the script takes no parameters of its own.

.EXAMPLE
    task shared:ci:share

.EXAMPLE
    task shared:ci:share CPUS=4 -- task test:coverage

.EXAMPLE
    pwsh shared/ci/Invoke-CiShare.ps1 npm --prefix web run test
#>

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# The @() outside the if: a statement's output unrolls, so a command of one word would be
# a string, and its [0] the word's first letter.
$command = @(if ($args.Count) { $args } else { 'task', 'test' })

$cpus = 0
if (-not [int]::TryParse("$env:CI_CPUS", [ref] $cpus) -or $cpus -lt 1) {
    $stateRoot = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $limits = Join-Path $stateRoot '.ci-runner/limits.json'
    if (Test-Path -LiteralPath $limits) {
        $cpus = [int] (Get-Content -LiteralPath $limits -Raw | ConvertFrom-Json).JobCpus
    } else {
        Write-Warning "No limits.json in $(Split-Path -Parent $limits), which each start of the runners writes. Running with 2 CPUs; CPUS= gives another."
        $cpus = 2
    }
}

# The last of the processors this process may use, as the runners' jobs have the last of
# the distro's.
$self = [Diagnostics.Process]::GetCurrentProcess()
$allowed = [long] $self.ProcessorAffinity
$processors = @(0..63 | Where-Object { $allowed -band (1L -shl $_) })
if ($cpus -gt $processors.Count) {
    Write-Warning "This process may use $($processors.Count) processors, fewer than $cpus; running with them all."
    $cpus = $processors.Count
}
$chosen = @($processors | Select-Object -Last $cpus)

$env:CI_CPUS = "$cpus"
$env:GOMAXPROCS = "$cpus"
$env:DOTNET_PROCESSOR_COUNT = "$cpus"
Write-Information ("Running '{0}' with a CI job's {1} CPUs: processors {2}, and CI_CPUS, GOMAXPROCS and DOTNET_PROCESSOR_COUNT {1}." -f
    ($command -join ' '), $cpus, ($chosen -join ',')) -InformationAction Continue

# Always an array: `$program, $arguments = $command` would leave a lone argument a string,
# which splatting hands over a character at a time (`task test` as `task t e s t`).
$program = $command[0]
$arguments = @($command | Select-Object -Skip 1)
if ($IsWindows) {
    # A process Windows starts takes its parent's affinity.
    $mask = 0L
    foreach ($processor in $chosen) {
        $mask = $mask -bor (1L -shl $processor)
    }
    $self.ProcessorAffinity = [IntPtr] $mask
    & $program @arguments
} elseif (Get-Command taskset -CommandType Application -ErrorAction SilentlyContinue) {
    # On Linux .NET sets the affinity of one thread alone, which a child needn't start from.
    & taskset --cpu-list ($chosen -join ',') $program @arguments
} else {
    Write-Warning 'Nothing here holds a process to some processors (no taskset); only the variables are set.'
    & $program @arguments
}
exit $LASTEXITCODE
