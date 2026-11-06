#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Fails when a project's shared workflow refs don't name the release its submodule
    holds.

.DESCRIPTION
    Every `uses: jwill89/shared-tooling/.github/workflows/...@<ref>` in the project's
    workflows must be v<VERSION>, where VERSION is the submodule's own file. Otherwise CI
    would run one release's workflow against another's scripts. The shared docs.yml
    workflow runs this; `task shared:update` keeps the two together.

.PARAMETER Path
    The project. Defaults to the current folder.

.PARAMETER Shared
    Where the submodule sits in the project.

.EXAMPLE
    pwsh shared/repo/Test-SharedVersion.ps1
#>
[CmdletBinding()]
param(
    [string] $Path = '.',
    [string] $Shared = 'shared'
)

$ErrorActionPreference = 'Stop'

$versionFile = Join-Path -Path $Path -ChildPath $Shared -AdditionalChildPath 'VERSION'
if (-not (Test-Path -LiteralPath $versionFile)) {
    throw "No shared-tooling VERSION at $versionFile."
}
$tag = 'v' + (Get-Content -Raw -LiteralPath $versionFile).Trim()

$workflows = Join-Path $Path '.github/workflows'
$refs = if (Test-Path -LiteralPath $workflows) {
    Get-ChildItem -LiteralPath $workflows -File -Include '*.yml', '*.yaml' -Recurse |
        Select-String -Pattern '^\s*uses:\s*jwill89/shared-tooling/\.github/workflows/([\w.-]+\.ya?ml)@([\w./-]+)' |
        ForEach-Object {
            [pscustomobject]@{
                File     = $_.Filename
                Line     = $_.LineNumber
                Workflow = $_.Matches[0].Groups[1].Value
                Ref      = $_.Matches[0].Groups[2].Value
            }
        }
}

if (-not $refs) {
    Write-Output "No shared workflows called; the submodule is at $tag."
    exit 0
}

$wrong = @($refs | Where-Object Ref -NE $tag)
foreach ($ref in $wrong) {
    Write-Output "$($ref.File):$($ref.Line) calls $($ref.Workflow)@$($ref.Ref), but $Shared is at $tag."
}
if ($wrong) {
    Write-Output "Run ``task shared:update -- $tag`` (or the release you mean), and commit the result."
    exit 1
}
Write-Output "$(@($refs).Count) shared workflow refs match $Shared at $tag."
