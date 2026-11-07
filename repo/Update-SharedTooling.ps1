#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Moves a project to a shared-tooling release: the submodule, the workflow refs, and
    what's built from them, in one step.

.DESCRIPTION
    A project uses shared-tooling twice: the submodule at shared/ (the configs and
    scripts) and the `uses: jwill89/shared-tooling/...@<tag>` lines in its workflows
    (what GitHub runs). They must name the same release, or CI would run one version's
    workflow against another's scripts, so this moves both:

      - checks out the release's tag in the submodule;
      - points every shared workflow ref in .github/workflows at that tag;
      - re-syncs .editorconfig and .gitattributes, when they carry the project marker;
      - rewrites each .golangci.yml the shared template made;
      - where a package.json uses @jwill89/lint-web or @jwill89/test-a11y, first raises
        the project's own copy of any of their peers (lint/web's ESLint, Prettier,
        Stylelint and TypeScript, test/a11y's Playwright) that falls outside the range
        the release declares, with `npm install -D <tool>@<range>`;
      - then re-installs the packages, so npm takes the new copy.

    A release that raises a peer, such as v2.0.0's Stylelint 18, would otherwise leave
    the project uninstallable: npm refuses the new package beside the old tool. Raised
    first, the tool only overrides the old package's peer, with a warning, until the
    next install replaces that package. Only a peer the project lists in its own
    devDependencies is raised, and only when the version its lockfile holds is outside
    the range; one pinned to an exact version stays pinned.

    It commits nothing: review `git diff`, then commit it as one change.

.PARAMETER Version
    The release to move to, such as v1.1.0 (the v is optional).

.PARAMETER SkipInstall
    Leave npm and the Go configs alone, peers included; move only the submodule, the
    refs and the repo files.

.EXAMPLE
    task shared:update -- v1.1.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Version,

    [switch] $SkipInstall,

    # Set when this script hands over to the copy in the release it just checked out.
    [Parameter(DontShow)]
    [switch] $CheckedOut
)

$ErrorActionPreference = 'Stop'

# Whether a version, such as 17.16.0, is in an npm range, such as ^18.0.0, ~6.0.3,
# >=1.2 <2, 1.x or `a || b`. A prerelease is ordered as SemVer orders it, without npm's
# extra rule that keeps prereleases out of most ranges.
function Test-VersionRange {
    param([string] $Version, [string] $Range)

    $have = [semver] ($Version -replace '^[v=]')
    foreach ($set in $Range -split '\|\|') {
        # `1.2 - 2` is `>=1.2 <=2`, and `>= 1.2` is `>=1.2`.
        $set = $set.Trim() -replace '^(\S+)\s+-\s+(\S+)$', '>=$1 <=$2' -replace '(<=|>=|<|>|=|\^|~>?)\s+', '$1'
        $unmet = @($set -split '\s+' | Where-Object { $_ -and -not (Test-VersionComparator -Have $have -Comparator $_) })
        if ($unmet.Count -eq 0) {
            return $true
        }
    }
    $false
}

# One comparator of a range: ^1.2.3, ~1.2, >1, <=2.0, 1.x, 1.2.3 or *.
function Test-VersionComparator {
    param([semver] $Have, [string] $Comparator)

    if ($Comparator -notmatch '^(?<op><=|>=|<|>|=|\^|~>?)?v?(?<ver>(?:\d+|[xX*])(?:\.(?:\d+|[xX*])){0,2}(?<pre>[-+][\w.+-]+)?)?$') {
        throw "Can't read '$Comparator' as a version range."
    }
    $op = [string] $Matches.op
    $pre = [string] $Matches.pre
    # The numbers given, up to the first x or the end: 1.2.x gives 1 and 2.
    $parts = @()
    foreach ($part in ([string] $Matches.ver -replace '[-+].*') -split '\.') {
        if ($part -notmatch '^\d+$') {
            break
        }
        $parts += [int] $part
    }
    if ($parts.Count -eq 0) {
        # *, x or a bare operator.
        return $op -notin '<', '>'
    }
    $major = $parts[0]
    $minor = $parts.Count -gt 1 ? $parts[1] : 0
    $patch = $parts.Count -gt 2 ? $parts[2] : 0
    $low = [semver] ("$major.$minor.$patch" + ($parts.Count -eq 3 ? $pre : ''))
    # Where a partial version ends: 1.2 before 1.3.0, 1 before 2.0.0.
    $past = switch ($parts.Count) {
        1 { [semver] "$($major + 1).0.0" }
        2 { [semver] "$major.$($minor + 1).0" }
    }
    switch -Regex ($op) {
        '^>$' { return $past ? $Have -ge $past : $Have -gt $low }
        '^>=$' { return $Have -ge $low }
        '^<$' { return $Have -lt $low }
        '^<=$' { return $past ? $Have -lt $past : $Have -le $low }
        '^\^$' {
            $past = if ($major -gt 0 -or $parts.Count -eq 1) {
                "$($major + 1).0.0"
            } elseif ($minor -gt 0 -or $parts.Count -eq 2) {
                "0.$($minor + 1).0"
            } else {
                "0.0.$($patch + 1)"
            }
        }
        '^~' { $past = $parts.Count -eq 1 ? "$($major + 1).0.0" : "$major.$($minor + 1).0" }
        '^=?$' {
            if (-not $past) {
                return $Have -eq $low
            }
        }
    }
    $Have -ge $low -and $Have -lt [semver] $past
}

# The `<tool>@<range>` specs that bring a project's own copies of the shared packages'
# peers into the ranges this release declares: a peer the project lists in its
# devDependencies, at a version outside the range. The version is the lockfile's, else
# the installed copy's, else the lowest the project's package.json allows. Exact says
# the project pins the tool to one version (Kindred Nights does), so it stays pinned.
function Get-PeerSpec {
    param([string] $Directory, [string[]] $Package)

    $own = (Get-Content -Raw -LiteralPath (Join-Path $Directory 'package.json') | ConvertFrom-Json -AsHashtable).devDependencies
    if (-not $own) {
        return
    }
    $lockFile = Join-Path $Directory 'package-lock.json'
    $locked = if (Test-Path -LiteralPath $lockFile) {
        (Get-Content -Raw -LiteralPath $lockFile | ConvertFrom-Json -AsHashtable).packages
    }
    foreach ($folder in $Package) {
        $shipped = Get-Content -Raw -LiteralPath (Join-Path $folder 'package.json') | ConvertFrom-Json -AsHashtable
        $peers = $shipped.peerDependencies
        if (-not $peers) {
            continue
        }
        foreach ($tool in $peers.Keys) {
            if (-not $own.Contains($tool)) {
                continue
            }
            $installed = Join-Path -Path $Directory -ChildPath 'node_modules' -AdditionalChildPath $tool, 'package.json'
            $version = if ($locked -and $locked["node_modules/$tool"]) {
                $locked["node_modules/$tool"].version
            } elseif (Test-Path -LiteralPath $installed) {
                (Get-Content -Raw -LiteralPath $installed | ConvertFrom-Json).version
            } elseif ($own[$tool] -match '^\s*[\^~>=v]*\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?') {
                '{0}.{1}.{2}' -f $Matches[1], [int] $Matches[2], [int] $Matches[3]
            }
            if ($version -and -not (Test-VersionRange -Version $version -Range $peers[$tool])) {
                Write-Host "    $tool $version is outside $($shipped.name)'s peer range $($peers[$tool]): raising it"
                [pscustomobject]@{
                    Spec  = "$tool@$($peers[$tool])"
                    Exact = $own[$tool] -match '^\d+\.\d+\.\d+$'
                }
            }
        }
    }
}

$tag = 'v' + $Version.TrimStart('v')
if ($tag -notmatch '^v\d+\.\d+\.\d+$') {
    throw "'$Version' isn't a release like v1.1.0."
}

$shared = Split-Path -Parent $PSScriptRoot
$root = git -C $shared rev-parse --show-superproject-working-tree
if (-not $root) {
    throw 'This copy of shared-tooling is not a submodule of a project.'
}
$sharedRel = [IO.Path]::GetRelativePath($root, $shared) -replace '\\', '/'

if (-not $CheckedOut) {
    Write-Host "Moving $sharedRel to $tag"
    git -C $shared fetch --quiet --tags origin
    if (-not (git -C $shared tag --list $tag)) {
        throw "shared-tooling has no release $tag."
    }
    git -C $shared checkout --quiet $tag
    if ($LASTEXITCODE) {
        throw "Couldn't check out $tag in $sharedRel."
    }

    # The rest is the new release's to do: this copy is the old one, so hand over to the
    # copy just checked out, which knows that release's files.
    & (Join-Path $shared 'repo/Update-SharedTooling.ps1') -Version $tag -SkipInstall:$SkipInstall -CheckedOut
    exit $LASTEXITCODE
}

# The workflow refs.
$workflows = Join-Path $root '.github/workflows'
if (Test-Path -LiteralPath $workflows) {
    foreach ($file in Get-ChildItem -LiteralPath $workflows -File -Include '*.yml', '*.yaml' -Recurse) {
        $text = Get-Content -Raw -LiteralPath $file.FullName
        # Only real `uses:` lines, not a commented example.
        $updated = [regex]::Replace($text, '(?m)^(\s*uses:\s*jwill89/shared-tooling/\.github/workflows/[\w.-]+\.ya?ml)@[\w./-]+', "`${1}@$tag")
        if ($updated -ne $text) {
            [IO.File]::WriteAllText($file.FullName, $updated)
            Write-Host "  $($file.Name): shared workflows now @$tag"
        }
    }
}

# The repo files, if the project has adopted them.
$marker = '# ---- project:'
$adopted = foreach ($name in '.editorconfig', '.gitattributes') {
    $path = Join-Path $root $name
    (Test-Path -LiteralPath $path) -and (Select-String -LiteralPath $path -SimpleMatch $marker -Quiet)
}
if ($adopted -notcontains $false) {
    & (Join-Path $shared 'repo/Sync-RepoFiles.ps1') -Path $root
}

if (-not $SkipInstall) {
    Push-Location -LiteralPath $root
    try {
        $tracked = git ls-files

        # The Go configs the template made, wherever their modules sit.
        foreach ($config in $tracked | Where-Object { $_ -match '(^|/)\.golangci\.yml$' }) {
            if (Select-String -LiteralPath $config -SimpleMatch 'shared-tooling/lint/go' -Quiet) {
                $dir = Split-Path -Parent $config
                if (-not $dir) {
                    $dir = '.'
                }
                Write-Host "  Rewriting $config"
                go run -C (Join-Path $shared 'lint/go') . -dir $dir
                if ($LASTEXITCODE) {
                    throw "golangci-sync failed for $config."
                }
            }
        }

        # The front-end packages, re-installed so npm copies the new release in. The
        # project's own copies of their peers go first, raised into the release's ranges
        # where they fall outside them: npm refuses the new package beside the old tool,
        # and installing both at once can fail the same way (Stylelint 18 did).
        $packages = @{ '@jwill89/lint-web' = 'lint/web'; '@jwill89/test-a11y' = 'test/a11y' }
        foreach ($manifest in $tracked | Where-Object { $_ -match '(^|/)package\.json$' -and $_ -notmatch "^$([regex]::Escape($sharedRel))/" }) {
            $dir = Split-Path -Parent (Join-Path $root $manifest)
            $text = Get-Content -Raw -LiteralPath (Join-Path $root $manifest)
            # Always arrays: splatting a lone string hands npm one character per argument.
            $folders = @(foreach ($name in $packages.Keys) {
                    if ($text.Contains("`"$name`"")) {
                        Join-Path $shared $packages[$name]
                    }
                })
            if ($folders) {
                $paths = @(foreach ($folder in $folders) {
                        [IO.Path]::GetRelativePath($dir, $folder) -replace '\\', '/'
                    })
                Write-Host "  npm install in $(Split-Path -Parent $manifest): $($paths -join ', ')"
                $peers = @(Get-PeerSpec -Directory $dir -Package $folders)
                # npm.cmd runs through cmd.exe, which drops a ^ and reads < and > as
                # redirects unless the argument is quoted; npm.exe, npm.ps1 and npm on
                # Linux and macOS take the range as it is.
                $viaCmd = (Get-Command npm | Select-Object -First 1).Source -match '\.(cmd|bat)$'
                Push-Location -LiteralPath $dir
                try {
                    # A pinned tool is raised pinned, the rest as the range.
                    foreach ($group in $peers | Group-Object -Property Exact) {
                        $specs = @($group.Group.Spec | ForEach-Object { $viaCmd ? "`"$_`"" : $_ })
                        $exact = @(if ($group.Name -eq 'True') { '--save-exact' })
                        npm install --save-dev --no-audit --no-fund @exact @specs
                        if ($LASTEXITCODE) {
                            throw "npm couldn't raise $($group.Group.Spec -join ', ') in $dir."
                        }
                    }
                    npm install --save-dev --no-audit --no-fund @paths
                    if ($LASTEXITCODE) {
                        $raised = $peers ? " after raising $($peers.Spec -join ', '); a package of the project's own may still need the old version (npm names it above)" : ''
                        throw "npm install failed in $dir$raised."
                    }
                } finally {
                    Pop-Location
                }
            }
        }
    } finally {
        Pop-Location
    }
}

Write-Host "Done. Review the changes, then commit them together:" -ForegroundColor Green
Write-Host "  git add -A && git commit -m `"Take shared-tooling $tag`""
git -C $root status --short
