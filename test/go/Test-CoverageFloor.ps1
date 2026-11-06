#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Fails when a Go coverage profile falls below the module's floor.

.DESCRIPTION
    Reads the profile `go test -coverprofile` writes and counts statements covered out
    of statements in all, leaving out files that match -Exclude (generated code such as
    sqlc's output, and startup wiring). The floor starts a little under what the tests
    reach today; raise it as tests land, never lower it.

    The test run CI makes, which this reads:

        go test -race -shuffle=on -covermode=atomic -coverprofile=coverage.out ./...

.PARAMETER ProfilePath
    The coverage profile.

.PARAMETER Floor
    The lowest statement coverage allowed, as a percentage.

.PARAMETER Exclude
    Regular expressions; a file whose path matches any of them is left out.

.EXAMPLE
    pwsh shared/test/go/Test-CoverageFloor.ps1 -ProfilePath coverage.out -Floor 62.5 -Exclude '/internal/db/'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ProfilePath,

    [Parameter(Mandatory)]
    [double] $Floor,

    [string[]] $Exclude = @()
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ProfilePath)) {
    Write-Error "No coverage profile at '$ProfilePath'."
    exit 1
}

# One line per block: file:startLine.startCol,endLine.endCol statements count. A block
# can appear more than once when several test binaries cover the same package; it is
# covered if any of them ran it.
$blocks = @{}
foreach ($line in Get-Content -LiteralPath $ProfilePath | Select-Object -Skip 1) {
    if ($line -notmatch '^(?<block>(?<file>.+):\d+\.\d+,\d+\.\d+) (?<statements>\d+) (?<count>\d+)$') {
        continue
    }
    $file = $Matches.file
    if ($Exclude | Where-Object { $file -match $_ }) {
        continue
    }
    $covered = [int64] $Matches.count -gt 0
    $existing = $blocks[$Matches.block]
    if ($existing) {
        $existing.Covered = $existing.Covered -or $covered
    } else {
        $blocks[$Matches.block] = [pscustomobject]@{ Statements = [int64] $Matches.statements; Covered = $covered }
    }
}

$total = ($blocks.Values | Measure-Object -Property Statements -Sum).Sum
$reached = ($blocks.Values | Where-Object Covered | Measure-Object -Property Statements -Sum).Sum
$percent = if ($total) { 100 * $reached / $total } else { 100 }

$verdict = if ($percent -ge $Floor) { '' } else { '  BELOW THE FLOOR' }
Write-Host ('statements {0,5:N1}% (floor {1,4:N1}%){2}' -f $percent, $Floor, $verdict)
if ($verdict) {
    exit 1
}
