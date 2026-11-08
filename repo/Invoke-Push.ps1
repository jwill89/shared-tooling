#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Pushes the branch after taking the dependency updates Dependabot would open, scanning
    for advisories and running task check: what `task push` runs.

.DESCRIPTION
    The order a push takes, so Dependabot has less to open and CI less to catch:

      1. The tree must be clean, the branch must track a remote, and it must not be behind
         it. With nothing to push, it stops there.
      2. The dependency updates Dependabot would open (Invoke-DependencyCheck.ps1, which
         leaves out what .github/dependabot.yml holds). The ones inside their ranges are
         listed and, once you agree (or with -Yes), taken: then task check runs, and they
         are committed as one chore(deps) commit. A failing check stops the push and leaves
         them uncommitted to look at.
      3. OSV-Scanner over every lockfile (Invoke-VulnerabilityScan.ps1). An advisory stops
         the push.
      4. task check, unless step 2 just ran it.
      5. git push.

    Majors are only listed at the end: Dependabot opens each alone, to be read first.

.PARAMETER Path
    The repo. Defaults to the current folder.

.PARAMETER Yes
    Take the in-range updates without asking.

.PARAMETER SkipUpdates
    Leave the in-range updates for now; they are still listed.

.PARAMETER SkipCheck
    Skip task check (step 4). The scan still runs.

.EXAMPLE
    task push

.EXAMPLE
    task push -- -Yes
#>
[CmdletBinding()]
param(
    [string] $Path = '.',
    [switch] $Yes,
    [switch] $SkipUpdates,
    [switch] $SkipCheck
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Write-Step { param([string] $Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Exit-Push { param([string] $Text) Write-Host "`n$Text" -ForegroundColor Red; exit 1 }

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
    $checked = $false
    if ($inRange) {
        Write-Output 'In range, which Dependabot would group into one pull request per ecosystem:'
        $inRange | ForEach-Object { Write-Output ("  {0} ({1}) {2} {3} -> {4}" -f $_.Ecosystem, $_.Directory, $_.Name, $_.Current, $_.Target) }
        $take = if ($SkipUpdates) { $false } elseif ($Yes) { $true } else {
            (Read-Host 'Take these before pushing? [Y/n]') -notmatch '^\s*n'
        }
        if ($take) {
            & (Join-Path $PSScriptRoot 'Invoke-DependencyCheck.ps1') -Path . -Update
            Write-Step 'Running task check on the updates...'
            task check
            if ($LASTEXITCODE -ne 0) {
                Exit-Push 'task check fails with the updates. They are left uncommitted to look at; git checkout -- . puts the tree back.'
            }
            $checked = $true
            git add -A
            git commit --quiet -m "chore(deps): take the in-range updates before pushing" -m ($inRange | ForEach-Object { '- {0}: {1} {2} -> {3}' -f $_.Ecosystem, $_.Name, $_.Current, $_.Target } | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) { Exit-Push 'Committing the updates failed.' }
            Write-Step 'Committed the updates as one chore(deps) commit.'
        } else {
            Write-Output 'Left for now; Dependabot will open them on its next run.'
        }
    } else {
        Write-Output 'Nothing in range for Dependabot to open.'
    }

    # 3. Known advisories.
    Write-Step 'Scanning the lockfiles with OSV-Scanner...'
    & (Join-Path $PSScriptRoot 'Invoke-VulnerabilityScan.ps1') -Path .
    if ($LASTEXITCODE -ne 0) { Exit-Push 'An advisory stops the push; see above.' }

    # 4. The gate CI runs.
    if (-not $checked -and -not $SkipCheck) {
        Write-Step 'Running task check...'
        task check
        if ($LASTEXITCODE -ne 0) { Exit-Push 'task check fails; nothing was pushed.' }
    }

    # 5. Push.
    Write-Step "Pushing to $upstream..."
    git push
    if ($LASTEXITCODE -ne 0) { Exit-Push 'git push failed.' }

    if ($majors) {
        Write-Output ''
        Write-Output 'Majors Dependabot will open one by one (read their breaking changes before taking one):'
        $majors | ForEach-Object { Write-Output ("  {0} ({1}) {2} {3} -> {4}" -f $_.Ecosystem, $_.Directory, $_.Name, $_.Current, $_.Target) }
    }
} finally {
    Pop-Location
}
