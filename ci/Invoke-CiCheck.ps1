#Requires -Version 7.4
<#
.SYNOPSIS
Runs one CI check and records it for the run's report.

.DESCRIPTION
Runs the command in bash from the current folder, printing its output as it comes. Then
it records the check in the job's report folder: its name, command, folder, result and
time, and on a failure the problems its output names (CiReport.psm1's Get-CiFinding), its
last lines and its whole output. A failure is also written to the job's summary, and each
problem it names (ten at most, the limit a step has) is marked on its line as an
annotation; one the tool marked itself is left to the tool's mark. A failure that names no
file is marked once, on the check.

The script exits with the command's exit code, so the step passes or fails as the command
did. A fault in the recording prints a warning and changes nothing else.

With no report folder (outside a runner, where neither CI_REPORT_DIR nor RUNNER_TEMP is
set) the command just runs.

.PARAMETER Name
The check's name in the report and the log.

.PARAMETER Command
The command, as bash reads it: environment variables are bash's to expand, so a value
the step sets in env: stays out of the command's text.

.PARAMETER Group
Fold the command's output into a group in the log.

.PARAMETER Shell
The bash that runs the command.

.PARAMETER ReportDirectory
The job's report folder: CI_REPORT_DIR, else ci-report in the runner's temp folder.

.EXAMPLE
& "$env:CI_TOOLS/Invoke-CiCheck.ps1" -Name 'go vet' -Command 'go vet ./...'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [string]$Command,

    [switch]$Group,

    [string]$Shell = 'bash',

    [string]$ReportDirectory = $(if ($env:CI_REPORT_DIR) { $env:CI_REPORT_DIR } elseif ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'ci-report' } else { '' })
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'CiReport.psm1') -Force

$directory = (Get-Location).Path
$output = [System.Collections.Generic.List[string]]::new()
$clock = [System.Diagnostics.Stopwatch]::StartNew()
if ($Group) {
    Write-Host "::group::$Name"
}
try {
    # A line the command writes to stderr arrives as an error record; it is output here,
    # not an error of this script's.
    $ErrorActionPreference = 'Continue'
    & $Shell -o pipefail -c $Command 2>&1 | ForEach-Object {
        $text = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
        Write-Host $text
        $output.Add($text)
    }
    $code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = 'Stop'
    if ($Group) {
        Write-Host '::endgroup::'
    }
}
$clock.Stop()
if ($null -eq $code) {
    $code = 1
}

function Write-CheckRecord {
    $checks = Join-Path $ReportDirectory 'checks'
    $logs = Join-Path $ReportDirectory 'logs'
    $null = New-Item -ItemType Directory -Force -Path $checks, $logs
    $index = @(Get-ChildItem -LiteralPath $checks -Filter '*.json').Count + 1
    $slug = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 40) {
        $slug = $slug.Substring(0, 40).TrimEnd('-')
    }
    $stem = '{0:000}-{1}' -f $index, $slug

    $root = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (git rev-parse --show-toplevel 2>$null) }
    if (-not $root) {
        $root = $directory
    }
    $relative = [IO.Path]::GetRelativePath($root, $directory) -replace '\\', '/'
    # The values of the environment variables the command names, so the report says what
    # ran; one whose name suggests a secret is left out, since an artifact isn't masked.
    $variables = [ordered]@{}
    foreach ($match in [regex]::Matches($Command, '\$\{?(?<name>[A-Za-z_][A-Za-z0-9_]*)')) {
        $variable = $match.Groups['name'].Value
        if ($variables.Contains($variable) -or $variable -match '(?i)token|secret|passw|key|auth|credential') {
            continue
        }
        $value = [Environment]::GetEnvironmentVariable($variable)
        if ($null -ne $value) {
            $variables[$variable] = $value
        }
    }
    $check = [ordered]@{
        name      = $Name
        command   = $Command
        variables = $variables
        directory = $relative
        passed    = $code -eq 0
        exitCode  = $code
        seconds   = [math]::Round($clock.Elapsed.TotalSeconds, 1)
        findings  = @()
        excerpt   = @()
        log       = $null
    }

    if ($code -ne 0) {
        $tracked = @(git -C $root ls-files 2>$null)
        $findings = @(Get-CiFinding -Line $output.ToArray() -Directory $directory -Root $root -TrackedFile $tracked | Select-Object -First 200)
        $check.findings = @($findings | Select-Object -Property file, line, column, severity, rule, message)
        $check.excerpt = Get-CiExcerpt -Line $output.ToArray() -Count $(if ($findings.Count) { 20 } else { 60 })
        $log = @($output | ForEach-Object { ConvertTo-PlainText -Text $_ })
        if ($log.Count -gt 20000) {
            $log = $log[-20000..-1]
        }
        Set-Content -LiteralPath (Join-Path $logs "$stem.log") -Value $log -Encoding utf8NoBOM
        $check.log = "logs/$stem.log"

        if ($env:GITHUB_ACTIONS -eq 'true') {
            $title = ConvertTo-CommandValue -Value $Name -Property
            $marked = 0
            foreach ($finding in $findings) {
                if ($finding.annotated -or $finding.severity -eq 'notice') {
                    continue
                }
                if ($marked -ge 10) {
                    break
                }
                $property = "file=$(ConvertTo-CommandValue -Value $finding.file -Property)"
                if ($finding.line) {
                    $property += ",line=$($finding.line)"
                    if ($finding.column) {
                        $property += ",col=$($finding.column)"
                    }
                }
                $property += ",title=$title"
                $message = if ($finding.rule) { "$($finding.rule): $($finding.message)" } else { $finding.message }
                Write-Host "::$($finding.severity) $($property)::$(ConvertTo-CommandValue -Value $message)"
                $marked++
            }
            if (-not $findings.Count) {
                Write-Host "::error title=$($title)::$(ConvertTo-CommandValue -Value "$Name failed with exit code $code; the job's summary and the CI report have its last lines of output.")"
            }
        }
        if ($env:GITHUB_STEP_SUMMARY) {
            Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value (ConvertTo-CiCheckMarkdown -Check $check) -Encoding utf8NoBOM
        }
    }

    $check | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $checks "$stem.json") -Encoding utf8NoBOM
}

if ($ReportDirectory) {
    try {
        Write-CheckRecord
    } catch {
        Write-Warning "The CI report missed this check: $($_.Exception.Message)"
    }
}
exit $code
