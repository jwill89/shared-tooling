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
      - re-installs @jwill89/lint-web and @jwill89/test-a11y where a package.json uses
        them, so npm takes the new copy.

    It commits nothing: review `git diff`, then commit it as one change.

.PARAMETER Version
    The release to move to, such as v1.1.0 (the v is optional).

.PARAMETER SkipInstall
    Leave npm and the Go configs alone; move only the submodule, the refs and the repo
    files.

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

        # The front-end packages, re-installed so npm copies the new release in.
        $packages = @{ '@jwill89/lint-web' = 'lint/web'; '@jwill89/test-a11y' = 'test/a11y' }
        foreach ($manifest in $tracked | Where-Object { $_ -match '(^|/)package\.json$' -and $_ -notmatch "^$([regex]::Escape($sharedRel))/" }) {
            $dir = Split-Path -Parent (Join-Path $root $manifest)
            $text = Get-Content -Raw -LiteralPath (Join-Path $root $manifest)
            # Always an array: splatting a lone string hands npm one character per argument.
            $paths = @(foreach ($name in $packages.Keys) {
                    if ($text.Contains("`"$name`"")) {
                        [IO.Path]::GetRelativePath($dir, (Join-Path $shared $packages[$name])) -replace '\\', '/'
                    }
                })
            if ($paths) {
                Write-Host "  npm install in $(Split-Path -Parent $manifest): $($paths -join ', ')"
                Push-Location -LiteralPath $dir
                try {
                    npm install --save-dev --no-audit --no-fund @paths
                    if ($LASTEXITCODE) {
                        throw "npm install failed in $dir."
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
