#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs a Go module's tests with a coverage profile, then holds them to the module's floor,
    as go.yml does in CI.

.DESCRIPTION
    What `task shared:go:coverage` runs, so `task check` fails below the floor before CI
    does. The test run is CI's, without the race detector unless -Race is given, since
    that needs cgo and a C compiler; coverage counts the same either way:

        go test -shuffle=on -covermode=atomic [-coverpkg=...] -coverprofile=<temp> ./...

    Then Test-CoverageFloor.ps1 reads the profile with the same floor and exclusions the
    module's CI passes to go.yml, and the profile is removed.

.PARAMETER Path
    The Go module's folder; the current folder unless given.

.PARAMETER Floor
    The lowest statement coverage allowed, in percent: go.yml's coverage-floor.

.PARAMETER Exclude
    Regular expressions, as go.yml's coverage-exclude: each value may hold several, one
    per line.

.PARAMETER CoverPkg
    go test's -coverpkg, as go.yml's coverpkg; empty counts each package's own tests.

.PARAMETER Race
    Run the tests under the race detector, as CI does.

.EXAMPLE
    task shared:go:coverage DIR=backend FLOOR=62.5 EXCLUDE=/internal/db/

.EXAMPLE
    pwsh shared/test/go/Invoke-GoCoverage.ps1 -Path backend -Floor 62.5 -Exclude '/internal/db/' -CoverPkg './...'
#>
[CmdletBinding()]
param(
    [string] $Path = '.',

    [Parameter(Mandatory)]
    [double] $Floor,

    [string[]] $Exclude = @(),

    [string] $CoverPkg,

    [switch] $Race
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$patterns = @($Exclude | ForEach-Object { $_ -split "`n" } | ForEach-Object Trim | Where-Object { $_ })
$profilePath = Join-Path ([System.IO.Path]::GetTempPath()) ('coverage-{0}.out' -f [guid]::NewGuid())
$testArgs = @('test')
if ($Race) { $testArgs += '-race' }
$testArgs += '-shuffle=on', '-covermode=atomic'
if ($CoverPkg) { $testArgs += "-coverpkg=$CoverPkg" }
$testArgs += "-coverprofile=$profilePath", './...'

Push-Location -LiteralPath $Path
try {
    go @testArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error 'The tests failed.' -ErrorAction Continue
        exit 1
    }
    & (Join-Path $PSScriptRoot 'Test-CoverageFloor.ps1') -ProfilePath $profilePath -Floor $Floor -Exclude $patterns
    exit $LASTEXITCODE
} finally {
    Pop-Location
    Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
}
