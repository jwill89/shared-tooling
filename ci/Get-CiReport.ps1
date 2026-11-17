#Requires -Version 7.4
<#
.SYNOPSIS
Prints the CI report of the branch's latest finished run: what failed, where, and why.

.DESCRIPTION
Asks GitHub, through gh, for the branch's latest finished run of the CI workflow. A run
that passed is reported in one line. For a failed run it downloads the run's ci-report
artifact (report.yml's) and prints ci-report.md, naming the folder that holds
ci-report.json and each failed check's whole log. A run with no report (one from before
the report, or one whose report job didn't run) falls back to the last lines of its failed
steps' logs.

This is the first thing to read when CI fails, before any raw log.

.PARAMETER Run
The run to report on, by its ID; by default the branch's latest finished run.

.PARAMETER Branch
The branch; by default the one checked out.

.PARAMETER Workflow
The CI workflow's file.

.PARAMETER OutDirectory
Where the report is downloaded; by default a folder named for the run under the temp folder.

.EXAMPLE
task shared:ci:report

.EXAMPLE
task shared:ci:report -- -Run 1234567890
#>
[CmdletBinding()]
param(
    [string]$Run,
    [string]$Branch,
    [string]$Workflow = 'ci.yml',
    [string]$OutDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'gh, the GitHub CLI, is needed to read CI runs; install it and sign in with gh auth login.'
}

if (-not $Run) {
    if (-not $Branch) {
        $Branch = git branch --show-current
        if ($LASTEXITCODE -or -not $Branch) {
            throw 'No branch is checked out here; pass -Branch or -Run.'
        }
    }
    $listed = gh run list --workflow $Workflow --branch $Branch --limit 20 --json 'databaseId,status,conclusion,headSha,displayTitle,url,createdAt'
    if ($LASTEXITCODE) {
        throw "gh couldn't list the $Workflow runs of $Branch."
    }
    $runs = @($listed | ConvertFrom-Json)
    $running = @($runs | Where-Object { $_.status -ne 'completed' } | Select-Object -First 1)
    $latest = @($runs | Where-Object { $_.status -eq 'completed' } | Select-Object -First 1)
    if (-not $latest) {
        throw "$Branch has no finished $Workflow run."
    }
    $latest = $latest[0]
    if ($running) {
        Write-Output "A newer run is still going: $($running[0].url)"
    }
    $sha = $latest.headSha.Substring(0, 7)
    if ($latest.conclusion -eq 'success') {
        Write-Output "The latest finished CI run on $Branch passed: $sha, $($latest.displayTitle) ($($latest.url))."
        exit 0
    }
    Write-Output "The latest finished CI run on $Branch ended $($latest.conclusion): $sha, $($latest.displayTitle) ($($latest.url))."
    $Run = "$($latest.databaseId)"
}

if (-not $OutDirectory) {
    $OutDirectory = Join-Path ([IO.Path]::GetTempPath()) "ci-report-$Run"
}
if (Test-Path -LiteralPath $OutDirectory) {
    Remove-Item -LiteralPath $OutDirectory -Recurse -Force
}
$null = gh run download $Run --name ci-report --dir $OutDirectory 2>&1
$markdown = Join-Path $OutDirectory 'ci-report.md'
if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $markdown)) {
    Write-Output "Run $Run has no CI report: it ran before the report existed, or its report job didn't run. The last lines of its failed steps' logs:"
    Write-Output ''
    $log = gh run view $Run --log-failed
    if ($LASTEXITCODE) {
        throw "gh couldn't read run $Run's failed steps."
    }
    $log | Select-Object -Last 200
    exit 0
}
Write-Output ''
Get-Content -LiteralPath $markdown
Write-Output ''
Write-Output "The report's JSON and each failed check's whole output: $OutDirectory"
