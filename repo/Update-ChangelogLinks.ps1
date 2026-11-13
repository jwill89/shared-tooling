#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Writes the compare links at the foot of a CHANGELOG.md, one for each version heading
    and one for Unreleased, or checks that every heading has one.

.DESCRIPTION
    Keep a Changelog gives each `## [x.y.z]` heading, and `## [Unreleased]`, a link
    reference at the foot of the file, which turns the heading into a link to the diff:

        [Unreleased]: https://github.com/owner/repo/compare/v1.2.0...HEAD
        [1.2.0]: https://github.com/owner/repo/compare/v1.1.0...v1.2.0
        [1.0.0]: https://github.com/owner/repo/releases/tag/v1.0.0

    Each version compares with the version below it; the oldest links to its own tag.
    The links are built from the headings, the tag prefix and the repo's address (its
    origin remote unless -RepoUrl names it), so a version CI has not tagged yet gets the
    link its tag will answer. Every link reference for a version or Unreleased is
    rewritten, newest first, in one block at the foot; any other link reference stays
    where it is. Tags already made are read only to warn about a version below the
    newest that has none, which usually means the wrong -TagPrefix.

    With -Check it changes nothing, and fails when a heading has no link reference or a
    version link reference has no heading: what the shared docs.yml workflow runs.

.PARAMETER Path
    The changelogs, CHANGELOG.md unless given; a value that isn't itself a file may name
    several, separated by spaces or commas. A repo with two parts versioned apart writes each part's own with
    its own -TagPrefix.

.PARAMETER TagPrefix
    What comes before the version in a tag: v unless given, or plugin-v for a part tagged
    plugin-v1.4.0.

.PARAMETER RepoUrl
    The repo's address on GitHub, such as https://github.com/owner/repo; by default read
    from the origin remote.

.PARAMETER Check
    Change nothing; fail if a heading lacks its link reference.

.EXAMPLE
    task shared:changelog:links

.EXAMPLE
    task shared:changelog:links -- -Path plugin/CHANGELOG.md -TagPrefix plugin-v

.EXAMPLE
    task shared:changelog:check -- -Path 'CHANGELOG.md plugin/CHANGELOG.md'
#>
[CmdletBinding()]
param(
    [string[]] $Path = @('CHANGELOG.md'),

    [ValidatePattern('^[A-Za-z0-9._/-]*$')]
    [string] $TagPrefix = 'v',

    [string] $RepoUrl,

    [switch] $Check
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# A value that names a file is taken whole, spaces and all; any other is a list.
$Path = @($Path | ForEach-Object { if (Test-Path -LiteralPath $_ -PathType Leaf) { $_ } else { $_ -split '[,\s]+' } } | Where-Object { $_ })
$headingPattern = '(?m)^## \[(?<name>Unreleased|\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\]'
$referencePattern = '(?m)^\[(?<name>Unreleased|\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\]:[ \t]*\S.*$'

# https://github.com/owner/repo from the forms git keeps a GitHub remote in.
function ConvertTo-RepoUrl {
    param([string] $Remote)
    $Remote = $Remote.Trim()
    if ($Remote -match '^(?:https?://|ssh://)?(?:[^@/]+@)?(?<host>[^/:]+)[:/](?<path>[^/]+/[^/]+?)(?:\.git)?/?$') {
        return "https://$($Matches.host)/$($Matches.path)"
    }
    throw "Can't read a repo address from the remote '$Remote'; pass -RepoUrl."
}

$problems = [System.Collections.Generic.List[string]]::new()
foreach ($file in $Path) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $problems.Add("${file}: no such file.")
        continue
    }
    $text = (Get-Content -Raw -LiteralPath $file) -replace "`r`n", "`n"
    $names = @([regex]::Matches($text, $headingPattern) | ForEach-Object { $_.Groups['name'].Value })
    $versions = @($names | Where-Object { $_ -ne 'Unreleased' })

    if ($Check) {
        $referenced = @([regex]::Matches($text, $referencePattern) | ForEach-Object { $_.Groups['name'].Value })
        foreach ($name in $names | Where-Object { $referenced -notcontains $_ }) {
            $problems.Add("${file}: ## [$name] has no link reference at the foot of the file.")
        }
        foreach ($name in $referenced | Where-Object { $names -notcontains $_ }) {
            $problems.Add("${file}: [$name] has a link reference but no heading.")
        }
        continue
    }

    $folder = Split-Path -Parent (Resolve-Path -LiteralPath $file).Path
    $url = $RepoUrl
    if (-not $url) {
        $remote = git -C $folder remote get-url origin 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $remote) { throw "$file is in no repo with an origin remote; pass -RepoUrl." }
        $url = ConvertTo-RepoUrl -Remote $remote
    }
    $url = $url.TrimEnd('/')

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($names -contains 'Unreleased') {
        $lines.Add($(if ($versions) { "[Unreleased]: $url/compare/$TagPrefix$($versions[0])...HEAD" } else { "[Unreleased]: $url/commits/HEAD" }))
    }
    for ($i = 0; $i -lt $versions.Count; $i++) {
        $tag = "$TagPrefix$($versions[$i])"
        $lines.Add($(if ($i + 1 -lt $versions.Count) { "[$($versions[$i])]: $url/compare/$TagPrefix$($versions[$i + 1])...$tag" } else { "[$($versions[$i])]: $url/releases/tag/$tag" }))
    }

    $body = [regex]::Replace($text, "$referencePattern\n?", '').TrimEnd("`n")
    $updated = if ($lines.Count) { "$body`n`n$($lines -join "`n")`n" } else { "$body`n" }
    if ($updated -ne $text) {
        [IO.File]::WriteAllText((Resolve-Path -LiteralPath $file).Path, $updated)
        Write-Output "${file}: $($lines.Count) compare links written."
    } else {
        Write-Output "${file}: compare links already current."
    }

    $tags = @(git -C $folder tag --list "$TagPrefix*" 2>$null)
    $untagged = @($versions | Select-Object -Skip 1 | Where-Object { $tags -notcontains "$TagPrefix$_" })
    if ($tags -and $untagged) {
        Write-Warning "${file}: no tag for $(($untagged | ForEach-Object { "$TagPrefix$_" }) -join ', '); check -TagPrefix."
    }
}

if ($problems.Count) {
    $problems | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host 'Write the links with task shared:changelog:links (standards/docs-and-agents.md).' -ForegroundColor Red
    exit 1
}
