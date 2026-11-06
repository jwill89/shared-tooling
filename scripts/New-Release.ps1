#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Makes a shared-tooling release: one version everywhere, a CHANGELOG entry, a commit
    and a tag.

.DESCRIPTION
    The whole repo carries one version. This sets it in VERSION (which projects' CI reads
    to check their workflow refs), in lint/web's and test/a11y's package.json (so a
    project's `npm install` always takes the new copy) and in the deploy module's
    manifest. It turns CHANGELOG.md's Unreleased section into the release's, commits
    those files and tags the commit v<version>. It doesn't push: it prints the command.

    It refuses when the working tree isn't clean, the branch isn't main, the tag exists,
    the version isn't higher than the last one, or Unreleased lists nothing.

.PARAMETER Version
    The new version, such as 1.1.0 (a leading v is fine).

.EXAMPLE
    task release -- 1.1.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Version
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $root
try {
    $Version = $Version.TrimStart('v')
    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "'$Version' isn't a version like 1.1.0."
    }
    $tag = "v$Version"

    $current = (Get-Content -Raw -LiteralPath VERSION).Trim()
    if ([version] $Version -le [version] $current) {
        throw "$Version isn't higher than the current $current."
    }
    if (git status --porcelain) {
        throw 'The working tree has changes; commit or stash them first.'
    }
    if ((git branch --show-current) -ne 'main') {
        throw 'Releases are made from main.'
    }
    if (git tag --list $tag) {
        throw "$tag already exists."
    }

    # The Unreleased section becomes the release's, and a new empty one goes above it.
    $changelog = (Get-Content -Raw -LiteralPath CHANGELOG.md) -replace "`r`n", "`n"
    $match = [regex]::Match($changelog, '(?ms)^## \[Unreleased\]\n(.*?)(?=^## \[|\z)')
    if (-not $match.Success) {
        throw 'CHANGELOG.md has no "## [Unreleased]" section.'
    }
    if ($match.Groups[1].Value -notmatch '(?m)^- ') {
        throw 'CHANGELOG.md lists nothing under Unreleased; say what the release changes first.'
    }
    $date = Get-Date -Format 'yyyy-MM-dd'
    $changelog = $changelog.Remove($match.Index, '## [Unreleased]'.Length).Insert($match.Index, "## [Unreleased]`n`n## [$Version] - $date")
    [IO.File]::WriteAllText((Join-Path $root 'CHANGELOG.md'), $changelog)

    [IO.File]::WriteAllText((Join-Path $root 'VERSION'), "$Version`n")

    # npm writes both package.json and its lockfile, as it formats them.
    foreach ($package in 'lint/web', 'test/a11y') {
        npm version $Version --no-git-tag-version --allow-same-version --prefix $package | Out-Null
        if ($LASTEXITCODE) {
            throw "npm couldn't set the version in $package."
        }
    }

    $manifest = Join-Path $root 'deploy/pwsh/SharedDeploy.psd1'
    $text = Get-Content -Raw -LiteralPath $manifest
    $updated = [regex]::Replace($text, "(ModuleVersion\s*=\s*')[^']*(')", "`${1}$Version`${2}")
    if ($updated -eq $text -and $text -notmatch "ModuleVersion\s*=\s*'$([regex]::Escape($Version))'") {
        throw "No ModuleVersion line in $manifest."
    }
    [IO.File]::WriteAllText($manifest, $updated)

    git add -- VERSION CHANGELOG.md lint/web/package.json lint/web/package-lock.json test/a11y/package.json test/a11y/package-lock.json deploy/pwsh/SharedDeploy.psd1
    git commit --quiet -m "Release $tag"
    git tag --annotate $tag -m "shared-tooling $tag"
    if ($LASTEXITCODE) {
        throw "Couldn't tag $tag."
    }

    Write-Host "Released $tag. Push it with:" -ForegroundColor Green
    Write-Host "  git push origin main $tag"
} finally {
    Pop-Location
}
