#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Copies the shared .editorconfig and .gitattributes into a repo, keeping its own
    lines below the project marker, and checks that its CLAUDE.md is in the standard form.

.DESCRIPTION
    Neither file can include another, so each repo holds a copy. This writes the shared
    part from shared-tooling/repo and keeps everything the repo wrote below the marker
    line. With -Check it writes nothing and fails when a copy differs, which is how CI
    catches a hand edit above the marker or a shared change not yet taken.

    A file that has no marker yet is left alone and reported: put the marker at its end,
    move the lines only that repo needs below it, and sync again.

    It also checks CLAUDE.md, which every repo keeps in one form: a heading, one line, and
    the imports of the repo's AGENTS.md and of the shared standards' index, by its path
    from the repo (shared/standards/README.md, or standards/README.md in shared-tooling
    itself). A repo without one gets it written; one that differs is reported, with the
    form to write, and never rewritten, since anything else in it belongs in AGENTS.md. An
    AGENTS.md that is missing is reported too, since CLAUDE.md imports it.

.PARAMETER Path
    The repo to sync. Defaults to the repo that holds shared-tooling as a submodule.

.PARAMETER Check
    Report drift instead of writing.

.EXAMPLE
    pwsh shared/repo/Sync-RepoFiles.ps1

.EXAMPLE
    pwsh shared/repo/Sync-RepoFiles.ps1 -Check
#>
[CmdletBinding()]
param(
    [string] $Path,
    [switch] $Check
)

$ErrorActionPreference = 'Stop'

$marker = '# ---- project: lines below this one are this repo''s own ----'
$files = [ordered]@{
    'editorconfig'  = '.editorconfig'
    'gitattributes' = '.gitattributes'
}

if (-not $Path) {
    $Path = git -C $PSScriptRoot rev-parse --show-superproject-working-tree
    if (-not $Path) {
        throw 'Not inside a submodule; pass -Path with the repo to sync.'
    }
}

$problems = 0
foreach ($entry in $files.GetEnumerator()) {
    $shared = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot $entry.Key)) -replace "`r`n", "`n"
    $target = Join-Path $Path $entry.Value

    $own = ''
    if (Test-Path -LiteralPath $target) {
        $current = (Get-Content -Raw -LiteralPath $target) -replace "`r`n", "`n"
        $at = $current.IndexOf($marker, [StringComparison]::Ordinal)
        if ($at -lt 0) {
            Write-Warning "$target has no project marker. Add this line at its end, move the repo's own lines below it, and sync again:`n$marker"
            $problems++
            continue
        }
        $own = $current.Substring($at + $marker.Length).TrimStart("`n")
    } else {
        $current = $null
    }

    $wanted = $shared.TrimEnd("`n") + "`n`n" + $marker + "`n" + $own
    if (-not $wanted.EndsWith("`n")) {
        $wanted += "`n"
    }

    if ($current -eq $wanted) {
        Write-Host "$($entry.Value) is current"
    } elseif ($Check) {
        Write-Warning "$target differs from shared-tooling/repo/$($entry.Key); run Sync-RepoFiles.ps1 and commit the result."
        $problems++
    } else {
        [IO.File]::WriteAllText($target, $wanted)
        Write-Host "Wrote $($entry.Value)"
    }
}

# CLAUDE.md, with the standards' index imported by its path from the repo.
$repo = (Resolve-Path -LiteralPath $Path).ProviderPath
$standards = [IO.Path]::GetRelativePath($repo, (Join-Path (Split-Path -Parent $PSScriptRoot) 'standards/README.md')) -replace '\\', '/'
$claude = "# CLAUDE.md`n`nKeep this project's rules in AGENTS.md, not here.`n`n@AGENTS.md`n@$standards`n"
$claudePath = Join-Path $repo 'CLAUDE.md'
if (-not (Test-Path -LiteralPath $claudePath)) {
    if ($Check) {
        Write-Warning "$claudePath is missing; run Sync-RepoFiles.ps1, which writes it, and commit the result."
        $problems++
    } else {
        [IO.File]::WriteAllText($claudePath, $claude)
        Write-Host 'Wrote CLAUDE.md'
    }
} elseif (((Get-Content -Raw -LiteralPath $claudePath) -replace "`r`n", "`n").TrimEnd() + "`n" -ceq $claude) {
    Write-Host 'CLAUDE.md is current'
} else {
    Write-Warning "$claudePath isn't in the standard form. Move anything else it says into AGENTS.md, and make it exactly:`n$claude"
    $problems++
}
if (-not (Test-Path -LiteralPath (Join-Path $repo 'AGENTS.md'))) {
    Write-Warning "$(Join-Path $repo 'AGENTS.md') is missing, and CLAUDE.md imports it: write the repo's guide there (shared/standards/docs-and-agents.md)."
    $problems++
}

if ($problems) {
    exit 1
}
