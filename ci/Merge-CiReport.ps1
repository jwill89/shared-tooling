#Requires -Version 7.4
<#
.SYNOPSIS
Merges a run's job reports into one CI report: ci-report.json, ci-report.md and the failed
checks' logs.

.DESCRIPTION
report.yml runs it once the run's other jobs have ended. It reads the run's jobs and their
steps from GitHub's API, and the job reports the failed jobs uploaded (each a job.json from
Complete-CiReport.ps1, with its checks' logs), downloaded under -Path. A report is matched
to its job by the runner that ran it.

The report lists every finished job with its result, then each failed one: the step it
failed at, a link to its log, and each failed check as Invoke-CiCheck.ps1 recorded it. A
job that failed outside its checks, or before it could report, still shows with its failed
step and log. The Markdown also goes to the job's summary, so it heads the run's page.

.PARAMETER Path
The folder the job reports were downloaded into, one folder each.

.PARAMETER OutDirectory
Where ci-report.json, ci-report.md and logs/ are written.

.PARAMETER JobsFile
The run's jobs as the API lists them ({ "jobs": [...] }), read from this file rather than
the API.

.EXAMPLE
& "$env:CI_TOOLS/Merge-CiReport.ps1" -Path "$env:RUNNER_TEMP/job-reports" -OutDirectory "$env:RUNNER_TEMP/ci-report"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory)]
    [string]$OutDirectory,

    [string]$JobsFile
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'CiReport.psm1') -Force

$repository = $env:GITHUB_REPOSITORY
$runId = $env:GITHUB_RUN_ID
$server = if ($env:GITHUB_SERVER_URL) { $env:GITHUB_SERVER_URL } else { 'https://github.com' }
$runUrl = "$server/$repository/actions/runs/$runId"

if ($JobsFile) {
    $jobs = @((Get-Content -LiteralPath $JobsFile -Raw | ConvertFrom-Json).jobs)
} else {
    $api = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }
    $headers = @{
        Authorization          = "Bearer $env:GITHUB_TOKEN"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $attempt = if ($env:GITHUB_RUN_ATTEMPT) { $env:GITHUB_RUN_ATTEMPT } else { '1' }
    $jobs = [System.Collections.Generic.List[object]]::new()
    for ($page = 1; $page -le 5; $page++) {
        $uri = "$api/repos/$repository/actions/runs/$runId/attempts/$attempt/jobs?per_page=100&page=$page"
        try {
            $response = Invoke-RestMethod -Uri $uri -Headers $headers
        } catch {
            throw "GitHub's API didn't list run $runId's jobs ($uri): $($_.Exception.Message)"
        }
        foreach ($item in $response.jobs) {
            $jobs.Add($item)
        }
        if ($jobs.Count -ge $response.total_count -or -not $response.jobs) {
            break
        }
    }
}

# A run done again downloads its earlier attempts' reports too; only this attempt's count.
$reports = @()
if (Test-Path -LiteralPath $Path) {
    $reports = @(Get-ChildItem -LiteralPath $Path -Filter 'job.json' -Recurse | ForEach-Object {
            [pscustomobject]@{ Folder = $_.DirectoryName; Report = (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json); Used = $false }
        } | Where-Object { -not $env:GITHUB_RUN_ATTEMPT -or -not $_.Report.runAttempt -or "$($_.Report.runAttempt)" -eq $env:GITHUB_RUN_ATTEMPT })
}

$null = New-Item -ItemType Directory -Force -Path (Join-Path $OutDirectory 'logs')

function Copy-CheckLog {
    # Brings a failed check's log into the report's own logs folder, under its job's name.
    param([object]$Check, [string]$Folder, [string]$JobSlug)
    if (-not $Check.log) {
        return $null
    }
    $source = Join-Path $Folder $Check.log
    if (-not (Test-Path -LiteralPath $source)) {
        return $null
    }
    $target = "logs/$JobSlug/$(Split-Path -Leaf $Check.log)"
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $OutDirectory "logs/$JobSlug")
    Copy-Item -LiteralPath $source -Destination (Join-Path $OutDirectory $target) -Force
    $target
}

function ConvertTo-JobEntry {
    # One job of the report: its result, where it failed, and its failed checks.
    param([string]$Name, [string]$Conclusion, [string]$Url, [string]$FailedStep, [object]$Found)
    $slug = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    $failedChecks = @()
    $passedChecks = 0
    if ($Found) {
        $Found.Used = $true
        foreach ($check in @($Found.Report.checks)) {
            if ($check.passed) {
                $passedChecks++
                continue
            }
            $check.log = Copy-CheckLog -Check $check -Folder $Found.Folder -JobSlug $slug
            $failedChecks += $check
        }
    }
    [ordered]@{
        name         = $Name
        conclusion   = $Conclusion
        url          = $Url
        failedStep   = $FailedStep
        reported     = [bool]$Found
        checksPassed = $passedChecks
        checks       = $failedChecks
    }
}

$entries = [System.Collections.Generic.List[object]]::new()
foreach ($job in $jobs) {
    if ($job.status -ne 'completed') {
        continue
    }
    $failedStep = @($job.steps | Where-Object { $_.conclusion -eq 'failure' } | Select-Object -First 1).name
    $found = $null
    if ($job.runner_name) {
        $found = $reports | Where-Object { -not $_.Used -and $_.Report.runner -eq $job.runner_name } | Select-Object -First 1
    }
    $entries.Add((ConvertTo-JobEntry -Name $job.name -Conclusion $job.conclusion -Url $job.html_url -FailedStep $failedStep -Found $found))
}
foreach ($left in @($reports | Where-Object { -not $_.Used })) {
    $label = "$($left.Report.job) (runner $($left.Report.runner))"
    $entries.Add((ConvertTo-JobEntry -Name $label -Conclusion 'failure' -Url $runUrl -FailedStep $null -Found $left))
}

$order = @{ failure = 0; cancelled = 1; timed_out = 1; success = 2; skipped = 3 }
$sorted = @($entries | Sort-Object { if ($order.ContainsKey([string]$_.conclusion)) { $order[[string]$_.conclusion] } else { 1 } }, { $_.name })
$failed = @($sorted | Where-Object { $_.conclusion -ne 'success' -and $_.conclusion -ne 'skipped' })

$report = [ordered]@{
    schema     = 1
    repository = $repository
    sha        = $env:GITHUB_SHA
    ref        = $env:GITHUB_REF_NAME
    event      = $env:GITHUB_EVENT_NAME
    runId      = $runId
    runAttempt = $env:GITHUB_RUN_ATTEMPT
    runUrl     = $runUrl
    created    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    jobs       = $sorted
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutDirectory 'ci-report.json') -Encoding utf8NoBOM

$short = if ($env:GITHUB_SHA) { $env:GITHUB_SHA.Substring(0, [Math]::Min(7, $env:GITHUB_SHA.Length)) } else { 'unknown' }
$md = [System.Text.StringBuilder]::new()
[void]$md.AppendLine('# CI report')
[void]$md.AppendLine()
[void]$md.AppendLine("``$short`` on ``$env:GITHUB_REF_NAME`` ($env:GITHUB_EVENT_NAME), [run $runId]($runUrl), $($report.created).")
[void]$md.AppendLine()
[void]$md.AppendLine("$($failed.Count) of $($sorted.Count) jobs did not pass. Each failed check's whole output is in ``logs/`` beside this file.")
[void]$md.AppendLine()
[void]$md.AppendLine('| Job | Result | Failed at |')
[void]$md.AppendLine('| --- | --- | --- |')
foreach ($entry in $sorted) {
    [void]$md.AppendLine("| $(ConvertTo-MarkdownCell -Text $entry.name) | $($entry.conclusion) | $(ConvertTo-MarkdownCell -Text ([string]$entry.failedStep)) |")
}
[void]$md.AppendLine()
foreach ($entry in $failed) {
    [void]$md.AppendLine("## $($entry.name)")
    [void]$md.AppendLine()
    $where = if ($entry.failedStep) { "It failed at the step ""$($entry.failedStep)""." } else { "It ended $($entry.conclusion)." }
    [void]$md.AppendLine("$where [Its log]($($entry.url)).")
    [void]$md.AppendLine()
    if ($entry.checks.Count) {
        foreach ($check in $entry.checks) {
            [void]$md.Append((ConvertTo-CiCheckMarkdown -Check $check -Heading '###'))
            if ($check.log) {
                [void]$md.AppendLine("Its whole output: ``$($check.log)``.")
                [void]$md.AppendLine()
            }
        }
    } elseif ($entry.conclusion -eq 'failure') {
        $why = if ($entry.reported) { 'No check of this job failed, so a step around them did (a checkout, a setup action or an install): its log has the reason.' } else { 'This job sent no report of its checks (its workflow predates the report, or it failed before it could write one): its log has the reason.' }
        [void]$md.AppendLine($why)
        [void]$md.AppendLine()
    }
}
$markdown = $md.ToString()
Set-Content -LiteralPath (Join-Path $OutDirectory 'ci-report.md') -Value $markdown -Encoding utf8NoBOM -NoNewline
if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $markdown -Encoding utf8NoBOM
}
Write-Output $markdown
