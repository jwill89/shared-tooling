#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Audits the npm packages a front end ships and fails on an advisory of high severity or
    above, passing over the ones the osv-scanner.toml beside its lockfile names: what
    web.yml's audit step and `task shared:web:audit` run.

.DESCRIPTION
    Runs `npm audit --omit=dev --json` in the folder and reads the report against the
    folder's osv-scanner.toml, the file OSV-Scanner reads beside the same lockfile
    (repo/osv-scanner.example.toml, standards/packages.md), so the one file records each
    advisory passed over for both.

    An [[IgnoredVulns]] entry passes an advisory over when its id is the advisory's GHSA id,
    exactly as written, and its ignoreUntil is unset or still ahead. As in OSV-Scanner, a
    date with no time runs out at the start of that day, local time, and an entry that has
    run out passes nothing over. Each advisory passed over is printed with the entry's
    reason, as OSV-Scanner prints each one it filters out. Only [[IgnoredVulns]] entries
    pass anything over: a [[PackageOverrides]] table, which would pass over a whole package,
    isn't read.

    npm flags a package for its own advisories and for each vulnerable package it depends
    on, naming that package in its `via` list. A package flagged only through advisories
    that are passed over, however many packages lie between, is passed over with them.

    Any other advisory of high or critical severity fails the audit, the bar
    `npm audit --audit-level=high` sets; one below that is listed and fails nothing. With no
    osv-scanner.toml nothing is passed over, so the audit passes and fails as
    `npm audit --audit-level=high --omit=dev` does.

    Exits 0 when nothing fails and 1 when an advisory does; a report npm couldn't make (no
    lockfile, no registry) stops the script with npm's message.

.PARAMETER Path
    The front end's folder, holding its package-lock.json and any osv-scanner.toml.
    Defaults to the current folder.

.PARAMETER ReportFile
    An `npm audit --omit=dev --json` report to read in place of running npm audit, such as
    one saved from an earlier run.

.EXAMPLE
    pwsh shared/repo/Invoke-NpmAudit.ps1 -Path web

.EXAMPLE
    pwsh shared/repo/Invoke-NpmAudit.ps1 -Path web -ReportFile audit.json
#>
[CmdletBinding()]
param(
    [string] $Path = '.',

    [string] $ReportFile
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# npm's severities, lowest first. An advisory at the bar or above fails the audit.
$severities = @('info', 'low', 'moderate', 'high', 'critical')
$bar = [array]::IndexOf($severities, 'high')

function ConvertFrom-TomlValue {
    <#
    .SYNOPSIS
        The value of a one-line TOML key: a basic or literal string, or a date or date-time
        as a DateTimeOffset, a date alone taken at midnight local time. Anything else comes
        back as its text, any trailing comment dropped.
    #>
    param([string] $Text)

    if ($Text -match '^"(?<value>(?:[^"\\]|\\.)*)"') {
        return [regex]::Unescape($Matches.value)
    }
    if ($Text -match "^'(?<value>[^']*)'") {
        return $Matches.value
    }
    if ($Text -match '^(?<value>\d{4}-\d{2}-\d{2}(?:[Tt ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:[Zz]|[+-]\d{2}:\d{2})?)?)\s*(?:#.*)?$') {
        return [datetimeoffset]::Parse($Matches.value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal)
    }
    return ($Text -replace '\s*#.*$', '')
}

function Read-IgnoredVuln {
    <#
    .SYNOPSIS
        The [[IgnoredVulns]] entries of an osv-scanner.toml, in the file's order: each one's
        id, ignoreUntil and reason.
    #>
    param([string] $File)

    $entry = $null
    foreach ($line in Get-Content -LiteralPath $File) {
        $text = $line.Trim()
        # Each table header ends the entry before it; only [[IgnoredVulns]] starts one.
        if ($text.StartsWith('[')) {
            $entry = $null
            if ($text -match '^\[\[\s*IgnoredVulns\s*\]\]') {
                $entry = [pscustomobject]@{ Id = $null; Until = $null; Reason = '' }
                $entry
            }
            continue
        }
        if (-not $entry -or $text -notmatch '^(?<key>[A-Za-z]+)\s*=\s*(?<value>.+)$') {
            continue
        }
        $value = ConvertFrom-TomlValue $Matches.value
        switch -CaseSensitive ($Matches.key) {
            'id' { $entry.Id = [string]$value }
            'reason' { $entry.Reason = [string]$value }
            'ignoreUntil' {
                if ($value -isnot [datetimeoffset]) {
                    throw "$File`: the ignoreUntil of $($entry.Id) isn't a TOML date ($value); write it as 2027-02-17, unquoted."
                }
                $entry.Until = $value
            }
        }
    }
}

# npm's report.
if ($ReportFile) {
    $raw = Get-Content -Raw -LiteralPath $ReportFile
    $code = $null
} else {
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw 'npm is not on PATH. Install Node (its version is in the front end''s .nvmrc) and try again.'
    }
    Push-Location -LiteralPath $Path
    try {
        # With --json npm writes its errors into the report as well, so stderr adds nothing.
        $raw = npm audit --omit=dev --json 2>$null | Out-String
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
}
$report = $null
try {
    $report = $raw | ConvertFrom-Json -AsHashtable
} catch {
    $report = $null
}
if ($report -isnot [System.Collections.IDictionary] -or $report['vulnerabilities'] -isnot [System.Collections.IDictionary]) {
    $why = if ($report -is [System.Collections.IDictionary] -and $report['error']) {
        "$($report.error.summary) $($report.error.detail)".Trim()
    } else {
        "$raw".Trim()
    }
    $exit = if ($null -ne $code) { " (exit code $code)" } else { '' }
    throw "npm audit made no report$exit`: $why"
}
$vulnerabilities = $report.vulnerabilities

# The file's entries by id, matched exactly and the first of an id kept, as OSV-Scanner
# matches them.
$entries = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$configFile = Join-Path $Path 'osv-scanner.toml'
if (Test-Path -LiteralPath $configFile -PathType Leaf) {
    foreach ($entry in Read-IgnoredVuln $configFile) {
        if ($entry.Id -and -not $entries.ContainsKey($entry.Id)) {
            $entries[$entry.Id] = $entry
        }
    }
}
$now = [datetimeoffset]::Now

# Every advisory in the report, once for each package it names, with what the file says.
$advisories = [System.Collections.Generic.List[object]]::new()
$own = @{}
foreach ($name in $vulnerabilities.Keys) {
    $own[$name] = [System.Collections.Generic.List[object]]::new()
    foreach ($via in @($vulnerabilities[$name].via)) {
        if ($via -isnot [System.Collections.IDictionary]) {
            continue
        }
        $url = [string]$via.url
        $ghsa = [regex]::Match($url, 'GHSA(?:-[0-9a-z]{4}){3}')
        $id = if ($ghsa.Success) { $ghsa.Value } elseif ($url) { $url } else { "npm advisory $($via.source)" }
        $severity = [string]$via.severity
        $entry = $null
        $null = $entries.TryGetValue($id, [ref]$entry)
        $advisory = [pscustomobject]@{
            Id         = $id
            Package    = $name
            Title      = [string]$via.title
            Url        = $url
            Severity   = $severity
            # An unknown severity counts as critical, so it fails rather than slips through.
            AtBar      = [array]::IndexOf($severities, $severity) -lt 0 -or [array]::IndexOf($severities, $severity) -ge $bar
            Entry      = $entry
            PassedOver = $null -ne $entry -and ($null -eq $entry.Until -or $entry.Until -gt $now)
        }
        $advisories.Add($advisory)
        $own[$name].Add($advisory)
    }
}

# The advisories each package is flagged for: its own, and those of every package its via
# list names, followed to the end.
$reached = @{}
foreach ($name in $vulnerabilities.Keys) {
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $null = $seen.Add($name)
    $queue.Enqueue($name)
    $found = [System.Collections.Generic.List[object]]::new()
    while ($queue.Count) {
        $current = $queue.Dequeue()
        if ($own.ContainsKey($current)) {
            $found.AddRange($own[$current])
        }
        if (-not $vulnerabilities.Contains($current)) {
            continue
        }
        foreach ($via in @($vulnerabilities[$current].via)) {
            if ($via -is [string] -and $seen.Add($via)) {
                $queue.Enqueue($via)
            }
        }
    }
    $reached[$name] = $found
}

$failing = @($advisories | Where-Object { $_.AtBar -and -not $_.PassedOver })
$passed = @($advisories | Where-Object PassedOver)
$below = @($advisories | Where-Object { -not $_.AtBar -and -not $_.PassedOver })
[string[]] $names = @($vulnerabilities.Keys)
[array]::Sort($names, [StringComparer]::Ordinal)
$failingNames = @($names | Where-Object { @($reached[$_] | Where-Object { $_.AtBar -and -not $_.PassedOver }).Count })
# The packages that fail nothing but reach an advisory passed over, other than its own.
$passedOwners = @($passed | ForEach-Object Package)
$passedNames = @($names | Where-Object {
        $_ -notin $failingNames -and $_ -notin $passedOwners -and @($reached[$_] | Where-Object PassedOver).Count
    })

if (-not $advisories.Count) {
    Write-Output 'npm audit found no advisory in the packages that ship.'
    exit 0
}

foreach ($advisory in $passed) {
    $reason = if ($advisory.Entry.Reason) { $advisory.Entry.Reason } else { '(no reason given)' }
    $until = if ($advisory.Entry.Until) { ", until $($advisory.Entry.Until.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture))" } else { '' }
    Write-Output "$($advisory.Id) ($($advisory.Package), $($advisory.Severity)$until) has been passed over because: $reason"
}
if ($passedNames.Count) {
    Write-Output "Flagged only through what is passed over, so passed over too: $($passedNames -join ', ')"
}

if ($below.Count) {
    Write-Output ''
    Write-Output 'Below high severity, so failing nothing:'
    foreach ($advisory in $below) {
        Write-Output "  $($advisory.Id) ($($advisory.Package), $($advisory.Severity)): $($advisory.Title)"
    }
}

if (-not $failing.Count) {
    Write-Output ''
    Write-Output 'No advisory of high severity or above fails the audit.'
    exit 0
}

Write-Output ''
Write-Output 'Failing the audit:'
foreach ($advisory in $failing) {
    Write-Output "  $($advisory.Id) ($($advisory.Package), $($advisory.Severity)): $($advisory.Title)"
    if ($advisory.Url -and $advisory.Url -ne $advisory.Id) {
        Write-Output "    $($advisory.Url)"
    }
    if ($advisory.Entry) {
        Write-Output "    Its osv-scanner.toml entry ran out on $($advisory.Entry.Until.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture))."
    }
    $through = @($names | Where-Object { $_ -ne $advisory.Package -and $reached[$_].Contains($advisory) })
    if ($through.Count) {
        Write-Output "    Reaching it: $($through -join ', ')"
    }
}
Write-Output ''
Write-Output "$($failing.Count) advisor$(if ($failing.Count -eq 1) { 'y' } else { 'ies' }) of high severity or above, in $($failingNames -join ', ')."
Write-Output 'Raise each package to its fixed version. Only one that reaches nothing that ships, with no fix inside its dependents'' ranges, may be passed over in the osv-scanner.toml beside the lockfile (standards/packages.md).'
exit 1
