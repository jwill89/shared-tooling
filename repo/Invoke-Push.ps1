#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Pushes the branch after taking the dependency updates Dependabot would open, then
    follows the CI run the push starts: what `task push` runs.

.DESCRIPTION
    CI runs the checks, once, after the push; this takes what CI can't, and shows its
    verdict:

      1. The tree must be clean, the branch must track a remote, and it must not be behind
         it. With nothing to push, it stops there.
      2. The dependency updates Dependabot would open (Invoke-DependencyCheck.ps1, which
         leaves out what .github/dependabot.yml holds). The ones inside their ranges are
         listed and, once you agree (or with -Yes), taken and committed as one chore(deps)
         commit that names them; CI checks them with the rest. One that something else
         holds back is named as not taken. A change to any file but the manifests and
         lockfiles (for Python, each .in file and the .txt compiled beside it) stops the
         push and leaves everything uncommitted to look at.
      3. Holds Dependabot's alerts to the osv-scanner.toml files
         (Sync-DependabotAlerts.ps1): an alert one passes over is dismissed with its
         reason, so Dependabot's security update job stops failing on it. A failure here
         is a warning; the push goes on.
      4. When the repo's CI_RUNNER variable sends its jobs to self-hosted runners and this
         machine has them (runner/README.md), starts them if they are stopped, so the jobs
         don't wait in the queue.
      5. git push.
      6. Follows each workflow run the pushed commit started, printing each job as it
         ends, and fails if a run fails, with the failed steps' log. A run still going
         after -WaitMinutes is left to finish on its own.

    Majors are only listed at the end: Dependabot opens each alone, to be read first.

.PARAMETER Path
    The repo. Defaults to the current folder.

.PARAMETER Yes
    Take the in-range updates without asking.

.PARAMETER SkipUpdates
    Leave the in-range updates for now; they are still listed.

.PARAMETER NoWait
    Push and return without following CI.

.PARAMETER WaitMinutes
    How long to follow CI before leaving it to finish; 30 minutes by default.

.EXAMPLE
    task push

.EXAMPLE
    task push -- -Yes -NoWait
#>
[CmdletBinding()]
param(
    [string] $Path = '.',
    [switch] $Yes,
    [switch] $SkipUpdates,
    [switch] $NoWait,
    [ValidateRange(1, 360)]
    [int] $WaitMinutes = 30
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Write-Step { param([string] $Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Exit-Push { param([string] $Text) Write-Host "`n$Text" -ForegroundColor Red; exit 1 }

function Start-CiRunnerIfUsed {
    # Starts this machine's self-hosted runners when the repo's CI_RUNNER variable sends its
    # jobs to them and they are stopped.
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $label = gh variable get CI_RUNNER 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $label) {
        return
    }
    if (-not (Get-ScheduledTask -TaskName 'CI runners' -ErrorAction SilentlyContinue)) {
        Write-Warning "CI_RUNNER sends this repo's jobs to the '$label' runners, which this machine doesn't have; they queue until those runners are started."
        return
    }
    if ($PSCmdlet.ShouldProcess("the '$label' runners", 'Start')) {
        Write-Step "Making sure the '$label' runners are up..."
        & (Join-Path $PSScriptRoot '../runner/Invoke-CiRunner.ps1') -Action Start
    }
}

function Wait-CiRun {
    # Follows the workflow runs commit $Sha started, printing each job as it ends to the
    # host; returns only whether every run passed, or $null when CI started none or was
    # still going at the end.
    param(
        [Parameter(Mandatory)] [string] $Sha,
        [Parameter(Mandatory)] [int] $Minutes
    )
    $deadline = (Get-Date).AddMinutes($Minutes)
    $runs = @()
    # A push's runs appear within seconds; a branch whose pushes start none shows none.
    $appear = (Get-Date).AddSeconds(90)
    while (-not $runs -and (Get-Date) -lt $appear) {
        Start-Sleep -Seconds 5
        $runs = @(gh run list --commit $Sha --json 'databaseId,workflowName,url' 2>$null | ConvertFrom-Json)
    }
    if (-not $runs) {
        Write-Host "No workflow run started for $($Sha.Substring(0, 7)); nothing to follow."
        return $null
    }
    # Another workflow of the same push can show up a moment after the first.
    Start-Sleep -Seconds 5
    $runs = @(gh run list --commit $Sha --json 'databaseId,workflowName,url' | ConvertFrom-Json)
    $runs | ForEach-Object { Write-Host "  $($_.workflowName): $($_.url)" }

    $reported = @{}
    $done = @{}
    while ($done.Count -lt $runs.Count -and (Get-Date) -lt $deadline) {
        foreach ($run in $runs | Where-Object { -not $done.ContainsKey($_.databaseId) }) {
            $view = gh run view $run.databaseId --json 'status,conclusion,jobs' 2>$null | ConvertFrom-Json
            if (-not $view) {
                continue
            }
            foreach ($job in $view.jobs | Where-Object { $_.status -eq 'completed' -and -not $reported.ContainsKey($_.databaseId) }) {
                $reported[$job.databaseId] = $true
                $took = if ($job.startedAt -and $job.completedAt) { ' ({0:N0} s)' -f ([datetime] $job.completedAt - [datetime] $job.startedAt).TotalSeconds } else { '' }
                Write-Host ('  {0,-9} {1}{2}' -f $job.conclusion, $job.name, $took)
            }
            if ($view.status -eq 'completed') {
                $done[$run.databaseId] = $view.conclusion
            }
        }
        if ($done.Count -lt $runs.Count) {
            Start-Sleep -Seconds 10
        }
    }
    if ($done.Count -lt $runs.Count) {
        Write-Host "CI is still going after $Minutes minutes; it finishes on its own."
        return $null
    }
    $failed = @($runs | Where-Object { $done[$_.databaseId] -notin 'success', 'skipped', 'neutral' })
    foreach ($run in $failed) {
        Write-Host "`n$($run.workflowName) failed ($($done[$run.databaseId])): $($run.url)"
        gh run view $run.databaseId --log-failed 2>$null | Select-Object -Last 60 | Out-Host
    }
    return -not $failed
}

Push-Location -LiteralPath $Path
try {
    # 1. Something to push, and nothing in the way.
    if (git status --porcelain) {
        Exit-Push 'The tree has uncommitted changes. task push pushes commits: commit or stash them first.'
    }
    $upstream = git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $upstream) {
        Exit-Push "$(git branch --show-current) tracks no remote branch. Push it once with git push -u."
    }
    git fetch --quiet
    $behind = [int](git rev-list --count 'HEAD..@{u}')
    if ($behind) { Exit-Push "The branch is $behind commit(s) behind $upstream. Pull first." }
    $ahead = [int](git rev-list --count '@{u}..HEAD')
    if (-not $ahead) {
        Write-Output "Nothing to push: $upstream already has every commit."
        return
    }
    Write-Step "$ahead commit(s) to push to $upstream"

    # 2. What Dependabot would open.
    Write-Step 'Checking the dependency updates Dependabot would open...'
    $updates = @(& (Join-Path $PSScriptRoot 'Invoke-DependencyCheck.ps1') -Path . -PassThru)
    $inRange = @($updates | Where-Object InRange)
    $majors = @($updates | Where-Object { -not $_.InRange })
    $committedUpdates = $false
    if ($inRange) {
        Write-Output 'In range, which Dependabot would group into one pull request per ecosystem:'
        $inRange | ForEach-Object { Write-Output ("  {0} ({1}) {2} {3} -> {4}" -f $_.Ecosystem, $_.Directory, $_.Name, $_.Current, $_.Target) }
        $take = if ($SkipUpdates) { $false } elseif ($Yes) { $true } else {
            (Read-Host 'Take these before pushing? [Y/n]') -notmatch '^\s*n'
        }
        if ($take) {
            & (Join-Path $PSScriptRoot 'Invoke-DependencyCheck.ps1') -Path . -Update
            # What was really taken: an update a dependent holds back is still on offer afterwards.
            $after = @(& (Join-Path $PSScriptRoot 'Invoke-DependencyCheck.ps1') -Path . -PassThru | Where-Object InRange)
            $taken = @($inRange | Where-Object {
                    $entry = $_
                    -not ($after | Where-Object { $_.Ecosystem -eq $entry.Ecosystem -and $_.Directory -eq $entry.Directory -and $_.Name -eq $entry.Name })
                })
            $left = @($inRange | Where-Object { $taken -notcontains $_ })
            if ($left) {
                Write-Warning ('Not taken, since something they depend on or that depends on them holds them back: ' + (($left | ForEach-Object { '{0} {1}' -f $_.Name, $_.Target }) -join ', '))
            }
            # Only the manifests and lockfiles the updates change are committed, Python's .in
            # files and the .txt compiled beside each among them; anything else changed stops
            # here to be looked at.
            $changed = @(git status --porcelain | ForEach-Object { $_.Substring(3).Trim('"') })
            $dependencyFile = '(^|/)(package(-lock)?\.json|npm-shrinkwrap\.json|go\.(mod|sum)|composer\.(json|lock)|packages\.lock\.json|[^/]+\.csproj)$'
            $other = @($changed | Where-Object {
                    $_ -notmatch $dependencyFile -and
                    -not ($_ -match '\.in$' -and (Test-Path -LiteralPath ($_ -replace '\.in$', '.txt'))) -and
                    -not ($_ -match '\.txt$' -and (Test-Path -LiteralPath ($_ -replace '\.txt$', '.in')))
                })
            if ($other) {
                Exit-Push ("Besides the dependency files, these changed while updating; look at them before pushing: $($other -join ', '). Nothing was committed.")
            }
            if (-not $changed) {
                Write-Output 'Nothing changed: no update could be taken.'
            } else {
                git add -- @changed
                git commit --quiet -m 'chore(deps): take the in-range updates before pushing' -m ($taken | ForEach-Object { '- {0}: {1} {2} -> {3}' -f $_.Ecosystem, $_.Name, $_.Current, $_.Target } | Out-String).Trim()
                if ($LASTEXITCODE -ne 0) { Exit-Push 'Committing the updates failed.' }
                $committedUpdates = $true
                Write-Step "Committed $($taken.Count) update(s) as one chore(deps) commit."
            }
        } else {
            Write-Output 'Left for now; Dependabot will open them on its next run.'
        }
    } else {
        Write-Output 'Nothing in range for Dependabot to open.'
    }

    # 3. The alerts the osv-scanner.toml files pass over.
    Write-Step "Holding Dependabot's alerts to the osv-scanner.toml files..."
    try {
        & (Join-Path $PSScriptRoot 'Sync-DependabotAlerts.ps1') -Path .
    } catch {
        Write-Warning "Dependabot's alerts weren't brought in line: $_"
    }

    # 4. Runners for CI to run on.
    Start-CiRunnerIfUsed

    # 5. Push.
    Write-Step "Pushing to $upstream..."
    $sha = git rev-parse HEAD
    git push
    if ($LASTEXITCODE -ne 0) { Exit-Push 'git push failed.' }

    if ($majors) {
        Write-Output ''
        Write-Output 'Majors Dependabot will open one by one (read their breaking changes before taking one):'
        $majors | ForEach-Object { Write-Output ("  {0} ({1}) {2} {3} -> {4}" -f $_.Ecosystem, $_.Directory, $_.Name, $_.Current, $_.Target) }
    }

    # 6. CI's verdict.
    if (-not $NoWait) {
        Write-Step 'Following CI...'
        $passed = Wait-CiRun -Sha $sha -Minutes $WaitMinutes
        if ($passed -eq $false) {
            $hint = if ($committedUpdates) { ' If the chore(deps) commit is the cause, git revert it and push.' } else { '' }
            Exit-Push "CI failed on the pushed commit.$hint"
        }
        if ($passed) {
            Write-Step 'CI passed.'
        }
    }
} finally {
    Pop-Location
}
