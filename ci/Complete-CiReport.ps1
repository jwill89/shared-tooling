#Requires -Version 7.4
<#
.SYNOPSIS
Ends a failed job's CI report: its job.json, and the name its artifact goes up under.

.DESCRIPTION
Run as a failed job's last step. It gathers the checks Invoke-CiCheck.ps1 recorded into
job.json beside them, with the job's name, runner, workflow, repository, commit and run,
which report.yml's Merge-CiReport.ps1 reads to match the report to the job. A job that
failed with no failed check (a checkout, a toolchain's setup or an install failed) says so
in its summary. The artifact's name, ci-report- with the job's name and a random suffix
(a workflow called twice in one run has the same job name both times), goes to the step's
output as name.

.PARAMETER ReportDirectory
The job's report folder: CI_REPORT_DIR, else ci-report in the runner's temp folder.

.EXAMPLE
& "$env:CI_TOOLS/Complete-CiReport.ps1"
#>
[CmdletBinding()]
param(
    [string]$ReportDirectory = $(if ($env:CI_REPORT_DIR) { $env:CI_REPORT_DIR } else { Join-Path $env:RUNNER_TEMP 'ci-report' })
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$null = New-Item -ItemType Directory -Force -Path $ReportDirectory
$checks = @(Get-ChildItem -LiteralPath $ReportDirectory -Filter '*.json' -Recurse |
        Where-Object { $_.Directory.Name -eq 'checks' } |
        Sort-Object Name |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })

$job = [ordered]@{
    schema     = 1
    job        = $env:GITHUB_JOB
    workflow   = $env:GITHUB_WORKFLOW
    runner     = $env:RUNNER_NAME
    repository = $env:GITHUB_REPOSITORY
    sha        = $env:GITHUB_SHA
    runId      = $env:GITHUB_RUN_ID
    runAttempt = $env:GITHUB_RUN_ATTEMPT
    checks     = $checks
}
$job | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ReportDirectory 'job.json') -Encoding utf8NoBOM

if (-not @($checks | Where-Object { -not $_.passed }).Count -and $env:GITHUB_STEP_SUMMARY) {
    $note = "### Failed outside its checks`n`nNo check of this job failed: a step before them did (a checkout, a toolchain's setup or an install). The step marked failed in the job's log has the reason.`n"
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $note -Encoding utf8NoBOM
}

$slug = ("$env:GITHUB_JOB".ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
$name = "ci-report-$slug-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "name=$name" -Encoding utf8NoBOM
}
Write-Output "The job's CI report goes up as $name."
