#Requires -Version 7.4
<#
.SYNOPSIS
Which of a repo's areas changed, so CI runs only the jobs those areas need.

.DESCRIPTION
An area is a name and the globs of the files it covers; a job runs when its area changed.
The files are compared with a base:
  - a push: the newest commit of the branch whose CI passed, found through GitHub's API, so
    a run that failed or was cancelled leaves its changes to be checked by the next one;
  - a pull request: its base;
  - any other event, or a base that can't be found or isn't an ancestor of the commit, or
    the commit itself (a run done again): no base, and every area runs.

Every area runs, too, when a changed file matches -Always (CI's own files, the shared
submodule, the Taskfile), or when a changed file matches no area and isn't one -Ignore
passes over (Markdown, the licence, editor settings): a file nothing claims is checked by
everything rather than by nothing.

Two areas come with every repo, unless its own list names them: scripts (PowerShell
files) and lockfiles (each lockfile OSV-Scanner reads, and osv-scanner.toml).

In a runner it writes areas (a JSON object of each area's name and whether it runs), all
and base to the step's outputs, and what changed to the job's summary. Run locally with
-WorkflowFile, it reads the areas from that workflow's changes job, compares the working
tree (untracked files included) with the branch's last passing commit (gh), or with its
remote branch when gh can't say, and prints which areas the next push would run.

.PARAMETER Areas
The areas, one a line: a name, a colon, and its globs separated by spaces. A glob is a
repo path where ** is any number of folders and * or ? match within one name; one that
starts with ! takes files out of the area.

.PARAMETER Always
Globs of the files that make every area run.

.PARAMETER Ignore
Globs of the files that need no area when none claims them.

.PARAMETER Base
The commit to compare with, instead of the one the event gives.

.PARAMETER WorkflowFile
A workflow whose changes job's areas, always and ignore inputs are read, for a local run.

.EXAMPLE
task shared:ci:changes
#>
[CmdletBinding()]
param(
    [string]$Areas = '',

    [string]$Always = '.github/** shared Taskfile.yml .editorconfig .gitattributes',

    [string]$Ignore = '**/*.md LICENSE LICENSE.* .gitignore .vscode/** .claude/**',

    [string]$Base,

    [string]$WorkflowFile
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'CiReport.psm1') -Force

$builtIn = [ordered]@{
    scripts   = '**/*.ps1 **/*.psm1 **/*.psd1'
    lockfiles = '**/package-lock.json **/npm-shrinkwrap.json **/yarn.lock **/pnpm-lock.yaml **/go.mod **/go.sum **/composer.lock **/packages.lock.json **/poetry.lock **/Pipfile.lock **/uv.lock **/requirements*.txt **/osv-scanner.toml'
}

function Read-ChangesInput {
    # The areas, always and ignore inputs of the workflow's call to changes.yml.
    param([string]$File)
    $lines = @(Get-Content -LiteralPath $File)
    $use = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'uses:\s*\S*changes\.yml') {
            $use = $i
            break
        }
    }
    if ($use -lt 0) {
        throw "$File calls no changes.yml."
    }
    $jobIndent = 0
    for ($i = $use; $i -ge 0; $i--) {
        if ($lines[$i] -match '^(?<indent>\s*)[\w-]+:\s*$' -and $Matches.indent.Length -le 2) {
            $jobIndent = $Matches.indent.Length
            break
        }
    }
    $found = @{}
    for ($i = $use + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^(?<indent>\s*)\S' -and $Matches.indent.Length -le $jobIndent) {
            break
        }
        if ($line -match '^(?<indent>\s+)(?<key>areas|always|ignore):\s*(?<rest>.*)$') {
            $keyIndent = $Matches.indent.Length
            $key = $Matches.key
            $rest = $Matches.rest.Trim()
            if ($rest -match '^[|>][-+]?$') {
                $block = [System.Collections.Generic.List[string]]::new()
                while ($i + 1 -lt $lines.Count -and ($lines[$i + 1] -notmatch '\S' -or ($lines[$i + 1] -match '^(?<indent>\s*)' -and $Matches.indent.Length -gt $keyIndent))) {
                    $i++
                    $block.Add($lines[$i].Trim())
                }
                $found[$key] = $block -join "`n"
            } else {
                $found[$key] = $rest.Trim("'", '"')
            }
        }
    }
    $found
}

function Get-PassingCommit {
    # The newest commit of the branch whose CI passed on a push, or nothing.
    param([string]$Branch, [string]$WorkflowName)
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $api = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }
        $uri = "$api/repos/$env:GITHUB_REPOSITORY/actions/workflows/$WorkflowName/runs?branch=$([uri]::EscapeDataString($Branch))&event=push&status=success&per_page=1"
        $headers = @{
            Authorization          = "Bearer $env:GITHUB_TOKEN"
            Accept                 = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
        try {
            return @((Invoke-RestMethod -Uri $uri -Headers $headers).workflow_runs)[0].head_sha
        } catch {
            Write-Warning "GitHub's API didn't say which commit last passed ($($_.Exception.Message))."
            return $null
        }
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        return $null
    }
    $sha = gh api "repos/{owner}/{repo}/actions/workflows/$WorkflowName/runs?branch=$([uri]::EscapeDataString($Branch))&event=push&status=success&per_page=1" --jq '.workflow_runs[0].head_sha' 2>$null
    if ($LASTEXITCODE -or -not $sha -or $sha -eq 'null') {
        return $null
    }
    "$sha".Trim()
}

function Test-Commit {
    # Whether the commit is here and an ancestor of HEAD.
    param([string]$Commit)
    $null = git cat-file -e "$Commit^{commit}" 2>$null
    if ($LASTEXITCODE) {
        return $false
    }
    $null = git merge-base --is-ancestor $Commit HEAD 2>$null
    $LASTEXITCODE -eq 0
}

$local = [bool]$WorkflowFile
if ($local) {
    $read = Read-ChangesInput -File $WorkflowFile
    if ($read.areas) { $Areas = $read.areas }
    if ($read.always) { $Always = $read.always }
    if ($read.ignore) { $Ignore = $read.ignore }
}

# The areas in order: the repo's own, then the built-in ones it doesn't name.
$area = [ordered]@{}
foreach ($line in ($Areas -split "`n")) {
    $text = $line.Trim()
    if (-not $text -or $text.StartsWith('#')) {
        continue
    }
    if ($text -notmatch '^(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?<globs>.*)$') {
        throw "An area is a name of letters, digits and underscores, a colon, then its globs: '$text'"
    }
    $area[$Matches.name] = Split-GlobList -Text $Matches.globs
}
foreach ($name in $builtIn.Keys) {
    if (-not $area.Contains($name)) {
        $area[$name] = Split-GlobList -Text $builtIn[$name]
    }
}
$alwaysGlob = Split-GlobList -Text $Always
$ignoreGlob = Split-GlobList -Text $Ignore

# The base, and why every area runs when there is none.
$all = $null
$why = $null
$eventName = $env:GITHUB_EVENT_NAME
$workflowName = 'ci.yml'
if ($env:GITHUB_WORKFLOW_REF) {
    $workflowName = ($env:GITHUB_WORKFLOW_REF -replace '@.*$', '') -replace '^.*/', ''
} elseif ($local) {
    $workflowName = Split-Path -Leaf $WorkflowFile
}
if ($Base) {
    $why = 'the base given'
} elseif ($local) {
    $branch = git branch --show-current
    $Base = Get-PassingCommit -Branch $branch -WorkflowName $workflowName
    $why = 'the last commit whose CI passed'
    if (-not $Base -or -not (Test-Commit -Commit $Base)) {
        $Base = "origin/$branch"
        $why = $Base
    }
} elseif ($eventName -in 'pull_request', 'pull_request_target') {
    $Base = $env:PR_BASE_SHA
    $why = "the pull request's base"
} elseif ($eventName -eq 'push') {
    $Base = Get-PassingCommit -Branch $env:GITHUB_REF_NAME -WorkflowName $workflowName
    $why = 'the last commit whose CI passed'
    if (-not $Base) {
        $all = 'no earlier commit of the branch passed CI'
    }
} else {
    $all = "a $eventName run checks everything"
}

$changed = @()
if (-not $all) {
    if (-not (Test-Commit -Commit $Base)) {
        $all = "the base, $Base, isn't an ancestor of this commit here"
    } elseif (-not $local -and (git rev-parse "$Base^{commit}") -eq (git rev-parse 'HEAD^{commit}')) {
        $all = 'this commit already passed, so this run is a deliberate re-run'
    } else {
        if ($local) {
            $changed = @(git diff --name-only --no-renames $Base) + @(git ls-files --others --exclude-standard)
        } else {
            $changed = @(git diff --name-only --no-renames $Base HEAD)
        }
        if ($LASTEXITCODE) {
            $all = "git couldn't list the files changed since $Base"
            $changed = @()
        }
        $changed = @($changed | Where-Object { $_ } | Sort-Object -Unique)
    }
}

# Each changed file: the areas it reaches, or every area, or none.
$reached = [ordered]@{}
foreach ($name in $area.Keys) {
    $reached[$name] = [System.Collections.Generic.List[string]]::new()
}
$passedOver = [System.Collections.Generic.List[string]]::new()
foreach ($file in $changed) {
    if (Test-GlobMatch -Path $file -Glob $alwaysGlob) {
        $all = "$file changed, which every job depends on"
        break
    }
    $claimed = $false
    foreach ($name in $area.Keys) {
        if (Test-GlobMatch -Path $file -Glob $area[$name]) {
            $reached[$name].Add($file)
            $claimed = $true
        }
    }
    if (-not $claimed) {
        if (Test-GlobMatch -Path $file -Glob $ignoreGlob) {
            $passedOver.Add($file)
        } else {
            $all = "$file changed, and no area claims it"
            break
        }
    }
}

$result = [ordered]@{}
foreach ($name in $area.Keys) {
    $result[$name] = [bool]$all -or $reached[$name].Count -gt 0
}

$summary = [System.Text.StringBuilder]::new()
[void]$summary.AppendLine('### What changed')
[void]$summary.AppendLine()
if ($all) {
    [void]$summary.AppendLine("Every job runs: $all.")
} else {
    [void]$summary.AppendLine("Compared with $why ($($Base.Substring(0, [Math]::Min(12, $Base.Length)))): $($changed.Count) changed file$(if ($changed.Count -ne 1) { 's' }).")
    [void]$summary.AppendLine()
    [void]$summary.AppendLine('| Area | Runs | Because of |')
    [void]$summary.AppendLine('| --- | --- | --- |')
    foreach ($name in $area.Keys) {
        $files = $reached[$name]
        $because = if ($files.Count -gt 3) { (($files | Select-Object -First 3) -join ', ') + ", and $($files.Count - 3) more" } else { $files -join ', ' }
        [void]$summary.AppendLine("| $name | $(if ($result[$name]) { 'yes' } else { 'no' }) | $(ConvertTo-MarkdownCell -Text $because) |")
    }
    if ($passedOver.Count) {
        [void]$summary.AppendLine()
        [void]$summary.AppendLine("Changed, and needing no job but docs: $(ConvertTo-MarkdownCell -Text (($passedOver | Select-Object -First 10) -join ', ') -Length 600)$(if ($passedOver.Count -gt 10) { ", and $($passedOver.Count - 10) more" }).")
    }
}

if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8NoBOM -Value @(
        "areas=$($result | ConvertTo-Json -Compress)"
        "all=$(([bool]$all).ToString().ToLowerInvariant())"
        "base=$(if ($all) { '' } else { $Base })"
    )
}
if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary.ToString() -Encoding utf8NoBOM
}
Write-Output $summary.ToString()
