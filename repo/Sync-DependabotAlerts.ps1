#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Dismisses each Dependabot alert that the repo's osv-scanner.toml files pass over, with
    the entry's reason, and opens one again once its entry has gone or run out: what
    `task shared:deps:alerts` runs, and `task push` before it pushes.

.DESCRIPTION
    An osv-scanner.toml beside a lockfile passes over an advisory that reaches only lint,
    test or build tooling and whose fix no dependent's range takes (standards/packages.md).
    OSV-Scanner reads it; Dependabot doesn't, so the advisory's alert stays open, and
    Dependabot's security update job, finding no update it may make, fails on every run.
    This holds the alerts to the files:

      - an open alert on a lockfile whose osv-scanner.toml names its advisory (by GHSA or
        CVE id), with an ignoreUntil still ahead or none, is dismissed as a tolerable risk,
        with the entry's reason as its comment;
      - an alert dismissed that way (its comment starts "osv-scanner.toml") whose entry has
        gone, or whose ignoreUntil has passed, is opened again, to be looked at with the
        scan.

    An alert dismissed by hand, or for any other reason, is left as it is. A repo with
    Dependabot alerts turned off has none to hold, and says so.

.PARAMETER Path
    The repo. Defaults to the current folder.

.EXAMPLE
    task shared:deps:alerts

.EXAMPLE
    task shared:deps:alerts -- -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Path = '.'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# The start of every comment this writes, by which it knows the alerts it dismissed.
$prefix = 'osv-scanner.toml'
# GitHub's limit on a dismissal's comment.
$commentLimit = 280

Push-Location -LiteralPath $Path
try {
    $repo = gh repo view --json nameWithOwner --jq .nameWithOwner 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gh can't find this folder's repo on GitHub: $repo"
    }

    # Each entry, keyed by the folder of the lockfile its file sits beside ('' for the
    # repo's root) and the advisory's id.
    $today = (Get-Date).Date
    $entries = @{}
    foreach ($file in git ls-files -- '*osv-scanner.toml') {
        $folder = (Split-Path -Parent $file) -replace '\\', '/'
        $text = Get-Content -Raw -LiteralPath $file
        foreach ($block in ($text -split '\[\[IgnoredVulns\]\]' | Select-Object -Skip 1)) {
            if ($block -notmatch '(?m)^\s*id\s*=\s*"([^"]+)"') {
                continue
            }
            $id = $Matches[1]
            $until = $null
            if ($block -match '(?m)^\s*ignoreUntil\s*=\s*(\d{4}-\d{2}-\d{2})') {
                $until = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            }
            $reason = 'Passed over in osv-scanner.toml.'
            if ($block -match '(?m)^\s*reason\s*=\s*"((?:[^"\\]|\\.)*)"') {
                $reason = $Matches[1] -replace '\\"', '"'
            }
            $entries["$folder|$id"] = [pscustomobject]@{
                Until  = $until
                Reason = $reason
                Active = -not $until -or $until -ge $today
            }
        }
    }

    $lines = gh api "repos/$repo/dependabot/alerts?per_page=100" --paginate --jq '.[] | {number, state, comment: .dismissed_comment, manifest: .dependency.manifest_path, ghsa: .security_advisory.ghsa_id, cve: .security_advisory.cve_id, package: .dependency.package.name}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ("$lines" -match 'disabled') {
            Write-Output "Dependabot alerts are off for $repo; there are none to hold to osv-scanner.toml."
            return
        }
        throw "Couldn't list $repo's Dependabot alerts: $lines"
    }

    $mismatched = 0
    foreach ($alert in @($lines | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })) {
        $folder = $alert.manifest -replace '/?[^/]+$', ''
        $entry = $entries["$folder|$($alert.ghsa)"]
        if (-not $entry -and $alert.cve) {
            $entry = $entries["$folder|$($alert.cve)"]
        }
        $what = "alert #$($alert.number) ($($alert.package), $($alert.ghsa), $($alert.manifest))"
        if ($alert.state -eq 'open' -and $entry.Active) {
            $tail = if ($entry.Until) { " Looked at again by $($entry.Until.ToString('yyyy-MM-dd'))." } else { '' }
            $room = $commentLimit - "${prefix}: ".Length - $tail.Length
            $reason = if ($entry.Reason.Length -gt $room) { $entry.Reason.Substring(0, $room - 3) + '...' } else { $entry.Reason }
            $mismatched++
            if ($PSCmdlet.ShouldProcess($what, 'Dismiss as a tolerable risk, as osv-scanner.toml passes it over')) {
                $out = gh api -X PATCH "repos/$repo/dependabot/alerts/$($alert.number)" -f state=dismissed -f dismissed_reason=tolerable_risk -f "dismissed_comment=${prefix}: $reason$tail" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Couldn't dismiss $what`: $out"
                }
                Write-Output "Dismissed $what, which osv-scanner.toml passes over."
            }
        } elseif ($alert.state -eq 'dismissed' -and "$($alert.comment)".StartsWith($prefix) -and -not $entry.Active) {
            $mismatched++
            if ($PSCmdlet.ShouldProcess($what, 'Open again, as osv-scanner.toml no longer passes it over')) {
                $out = gh api -X PATCH "repos/$repo/dependabot/alerts/$($alert.number)" -f state=open 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Couldn't open $what again: $out"
                }
                Write-Output "Opened $what again: its osv-scanner.toml entry has gone or run out."
            }
        }
    }
    if (-not $mismatched) {
        Write-Output "$repo's Dependabot alerts already match its osv-scanner.toml files."
    }
} finally {
    Pop-Location
}
