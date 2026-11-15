#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Starts, stops or shows this machine's self-hosted runners, from any repo: what
    `task shared:runner:start`, `shared:runner:stop` and `shared:runner:status` run.

.DESCRIPTION
    Works through the copy of CiRunner.psm1 that the "CI runners" task was installed from
    (Install-CiRunner), not the repo's own copy of shared-tooling, so every repo drives the
    one set of runners with the same code, whatever release the repo is on.

    Start runs the task, which starts the WSL distro, Docker and the scaler, and waits until
    the scaler is up; with the runners running already, it only says so. Stop stops the
    scaler, removes every job container and shuts the distro down, which gives its memory
    back to Windows. Status shows them.

.PARAMETER Action
    Start, Stop or Status.

.EXAMPLE
    task shared:runner:start

.EXAMPLE
    pwsh -File shared/runner/Invoke-CiRunner.ps1 -Action Stop
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Start', 'Stop', 'Status')]
    [string] $Action
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$task = Get-ScheduledTask -TaskName 'CI runners' -ErrorAction SilentlyContinue
if (-not $task) {
    throw 'This machine has no self-hosted runners. Set them up from shared-tooling with task runner:install (runner/README.md).'
}
if ($task.Actions[0].Arguments -notmatch "Import-Module '([^']+)'") {
    throw "The 'CI runners' task doesn't name the module it runs; run task runner:install in shared-tooling again."
}
Import-Module -Name $Matches[1]

switch ($Action) {
    'Start' {
        if ($task.State -eq 'Running') {
            Write-Host 'The runners are running already.'
            return
        }
        Start-ScheduledTask -TaskName 'CI runners'
        Write-Host 'Starting the runners; a first start builds the images, which takes a few minutes.'
        Wait-CiRunner
        Get-CiRunnerStatus | Format-Table
    }
    'Stop' {
        Stop-CiRunner
        Write-Host 'The runners are stopped; jobs queue on GitHub until the next start.'
    }
    'Status' {
        Get-CiRunnerStatus | Format-Table
    }
}
