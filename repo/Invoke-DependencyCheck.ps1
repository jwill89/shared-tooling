#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Lists the dependency updates Dependabot would open for this repo, and with -Update takes
    the ones inside their ranges.

.DESCRIPTION
    What `task shared:deps` and `task shared:push` run, so updates are taken before a push
    rather than arriving as Dependabot's pull requests after it. For each ecosystem the repo
    tracks (the shared/ submodule left out), it finds the available updates:

      npm             npm outdated, in each folder with a package-lock.json
      Go              go list -m -u, the direct requirements of each go.mod
      Composer        composer outdated --direct, beside each composer.lock
      NuGet           dotnet list package --outdated, for each restored .csproj
      GitHub Actions  each workflow's `uses:` pins against the action's latest release

    It leaves out what .github/dependabot.yml holds: an `ignore` entry's dependency-name
    (with * patterns), limited to its update-types or versions when it names them. It reads
    the file in the shape of repo/dependabot.example.yml, line by line, since PowerShell has
    no YAML parser.

    An update inside its range (npm's "wanted", a Composer "semver-safe-update", any Go or
    NuGet minor or patch) is one Dependabot would fold into the ecosystem's grouped pull
    request; -Update takes those. A major is one Dependabot opens alone, after its breaking
    changes are read, so it is listed and never taken. GitHub Actions pins name a major tag
    (v7), so their updates are majors too.

    modernc.org/libc is never raised by name: modernc.org/sqlite is released against one
    exact libc and brings it along (standards/packages.md).

.PARAMETER Path
    The repo. Defaults to the current folder.

.PARAMETER Update
    Take the in-range updates: for npm, each package's range raised to the new version and
    its family's lockfile entries dropped (npm-take-updates.mjs), then npm install, so
    packages that pin each other move together; go get each module at its version then go
    mod tidy; composer update then composer bump for those packages; and dotnet add package.
    Majors and held versions are left alone.

.PARAMETER PassThru
    Return the updates as objects (Ecosystem, Directory, Name, Current, Target, Kind,
    InRange) instead of printing them, for task push.

.EXAMPLE
    pwsh shared/repo/Invoke-DependencyCheck.ps1

.EXAMPLE
    pwsh shared/repo/Invoke-DependencyCheck.ps1 -Update
#>
[CmdletBinding()]
param(
    [string] $Path = '.',
    [switch] $Update,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Get-VersionPart {
    # The numbers of a version: 'v0.58.1-0.2026' and '1.2.3' alike give major, minor, patch.
    param([string] $Value)
    $match = [regex]::Match($Value, '(\d+)(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $match.Success) { return $null }
    , @(1..3 | ForEach-Object { if ($match.Groups[$_].Success) { [int]$match.Groups[$_].Value } else { 0 } })
}

function Get-UpdateKind {
    param([string] $From, [string] $To)
    # A branch such as roave/security-advisories' dev-latest has no version to compare.
    if ($From -like 'dev-*' -or $To -like 'dev-*') { return 'dev' }
    $a = Get-VersionPart $From
    $b = Get-VersionPart $To
    if (-not $a -or -not $b) { return 'major' }
    if ($a[0] -ne $b[0]) { return 'major' }
    if ($a[1] -ne $b[1]) { return 'minor' }
    'patch'
}

function Read-DependabotHold {
    # The ignore entries of .github/dependabot.yml, with the ecosystem and folder they sit under.
    param([string] $File)
    if (-not (Test-Path -LiteralPath $File)) { return @() }
    $holds = [System.Collections.Generic.List[object]]::new()
    $ecosystem = $null
    $directory = $null
    $ignoreIndent = -1
    $hold = $null
    foreach ($line in Get-Content -LiteralPath $File) {
        if ($line -match '^\s*(#|$)') { continue }
        $indent = $line.Length - $line.TrimStart().Length
        if ($ignoreIndent -ge 0 -and $indent -le $ignoreIndent) { $ignoreIndent = -1; $hold = $null }
        if ($line -match '^\s*-\s*package-ecosystem:\s*["'']?([\w-]+)') {
            $ecosystem = $Matches[1]; $directory = '.'; $ignoreIndent = -1; $hold = $null
        } elseif ($line -match '^\s*directory:\s*["'']?([^"''\s]+)') {
            $directory = ($Matches[1].Trim('/') -replace '^$', '.')
        } elseif ($line -match '^\s*ignore:\s*$') {
            $ignoreIndent = $indent
        } elseif ($ignoreIndent -ge 0 -and $line -match '^\s*-\s*dependency-name:\s*["'']?([^"''\s]+)') {
            $hold = [pscustomobject]@{ Ecosystem = $ecosystem; Directory = $directory; Name = $Matches[1]; UpdateTypes = @(); Versions = @() }
            $holds.Add($hold)
        } elseif ($hold -and $line -match '^\s*(update-types|versions):\s*\[(.*)\]') {
            $items = @($Matches[2] -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
            if ($Matches[1] -eq 'versions') { $hold.Versions = $items } else { $hold.UpdateTypes = $items }
        }
    }
    $holds.ToArray()
}

function Add-Update {
    # Records an available update, unless .github/dependabot.yml holds it (then it is counted).
    param(
        [string] $Ecosystem, [string] $Directory, [string] $Name, [string] $Current, [string] $Target,
        [string] $Kind, [bool] $InRange, [string] $Project
    )
    # Forward slashes, as dependabot.yml writes its folders; a hold covers the folders under it.
    $Directory = $Directory -replace '\\', '/'
    foreach ($hold in $script:holds) {
        if ($hold.Ecosystem -ne $Ecosystem -or $Name -notlike $hold.Name) { continue }
        if ($hold.Directory -ne '.' -and $Directory -ne $hold.Directory -and -not $Directory.StartsWith("$($hold.Directory)/")) { continue }
        if ((-not $hold.UpdateTypes -and -not $hold.Versions) -or
            $hold.UpdateTypes -contains "version-update:semver-$Kind" -or
            $hold.Versions -contains $Target) {
            $script:held++
            return
        }
    }
    $script:entries.Add([pscustomobject]@{
            Ecosystem = $Ecosystem; Directory = $Directory; Name = $Name; Current = $Current
            Target = $Target; Kind = $Kind; InRange = $InRange; Project = $Project
        })
}

$root = (Resolve-Path -LiteralPath $Path).Path
Push-Location -LiteralPath $root
try {
    $tracked = @(git ls-files | Where-Object { $_ -notmatch '^shared/' -and $_ -notmatch '(^|/)node_modules/' })
    $script:holds = Read-DependabotHold -File '.github/dependabot.yml'
    $script:entries = [System.Collections.Generic.List[object]]::new()
    $script:held = 0
    $skipped = [System.Collections.Generic.List[string]]::new()

    # npm
    foreach ($lock in $tracked | Where-Object { $_ -match '(^|/)package-lock\.json$' }) {
        $dir = Split-Path -Path $lock -Parent
        if (-not $dir) { $dir = '.' }
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'node_modules'))) { $skipped.Add("npm ($dir): not installed; run npm ci there first"); continue }
        $raw = npm outdated --json --prefix $dir 2>$null
        if (-not $raw) { continue }
        $outdated = ($raw | Out-String | ConvertFrom-Json -AsHashtable)
        foreach ($name in $outdated.Keys) {
            if ($name -like '@jwill89/*') { continue }
            $info = @($outdated[$name])[0]
            if (-not $info.current) { continue }
            if ($info.wanted -and $info.wanted -ne $info.current) {
                $kind = Get-UpdateKind $info.current $info.wanted
                Add-Update -Ecosystem npm -Directory $dir -Name $name -Current $info.current -Target $info.wanted -Kind $kind -InRange $true
            }
            if ($info.latest -and $info.latest -ne $info.wanted -and (Get-UpdateKind ($info.wanted ?? $info.current) $info.latest) -eq 'major') {
                Add-Update -Ecosystem npm -Directory $dir -Name $name -Current $info.current -Target $info.latest -Kind major -InRange $false
            }
        }
    }

    # Go
    foreach ($mod in $tracked | Where-Object { $_ -match '(^|/)go\.mod$' }) {
        $dir = Split-Path -Path $mod -Parent
        if (-not $dir) { $dir = '.' }
        $lines = go -C $dir list -m -u -f '{{if and (not .Main) (not .Indirect) .Update}}{{.Path}} {{.Version}} {{.Update.Version}}{{end}}' all 2>$null
        foreach ($line in @($lines | Where-Object { $_ })) {
            $name, $current, $target = $line -split ' '
            if ($name -eq 'modernc.org/libc') { continue }
            $kind = Get-UpdateKind $current $target
            Add-Update -Ecosystem gomod -Directory $dir -Name $name -Current $current -Target $target -Kind $kind -InRange ($kind -ne 'major')
        }
    }

    # Composer
    foreach ($lock in $tracked | Where-Object { $_ -match '(^|/)composer\.lock$' }) {
        $dir = Split-Path -Path $lock -Parent
        if (-not $dir) { $dir = '.' }
        if (-not (Get-Command composer -ErrorAction SilentlyContinue)) { $skipped.Add("composer ($dir): composer is not on PATH"); continue }
        $raw = composer outdated --direct --format=json --working-dir=$dir 2>$null
        if (-not $raw) { continue }
        # What an update would really do: composer outdated doesn't weigh the project's own
        # `conflict` holds, or a package another one holds back (Fantasy Dossier's phpstan, held
        # at 2.3.3, keeps rector at 2.8.2), so an in-range update counts only if the dry run takes it.
        $upgrades = @{}
        foreach ($line in composer update --dry-run --with-all-dependencies --no-interaction --working-dir=$dir 2>&1) {
            if ("$line" -match 'Upgrading (\S+) \((.+?) => (.+?)\)') { $upgrades[$Matches[1]] = $Matches[3] }
        }
        foreach ($package in @((($raw | Out-String) | ConvertFrom-Json).installed)) {
            if (-not $package.latest -or $package.latest -eq $package.version) { continue }
            $kind = Get-UpdateKind $package.version $package.latest
            if ($package.'latest-status' -ne 'semver-safe-update') {
                Add-Update -Ecosystem composer -Directory $dir -Name $package.name -Current $package.version -Target $package.latest -Kind $kind -InRange $false
            } elseif ($upgrades.ContainsKey($package.name)) {
                $target = $upgrades[$package.name]
                Add-Update -Ecosystem composer -Directory $dir -Name $package.name -Current $package.version -Target $target -Kind (Get-UpdateKind $package.version $target) -InRange $true
            } else {
                $script:held++
            }
        }
    }

    # NuGet
    foreach ($project in $tracked | Where-Object { $_ -match '\.csproj$' }) {
        $dir = Split-Path -Path $project -Parent
        if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { $skipped.Add('nuget: dotnet is not on PATH'); break }
        $raw = dotnet list $project package --outdated --format json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { $skipped.Add("nuget ($project): not restored; build it once first"); continue }
        $report = ($raw | Out-String) | ConvertFrom-Json
        foreach ($package in @($report.projects.frameworks.topLevelPackages | Where-Object { $_ })) {
            if (-not $package.latestVersion -or $package.latestVersion -eq $package.resolvedVersion) { continue }
            $kind = Get-UpdateKind $package.resolvedVersion $package.latestVersion
            if ($script:entries | Where-Object { $_.Ecosystem -eq 'nuget' -and $_.Name -eq $package.id -and $_.Project -eq $project }) { continue }
            Add-Update -Ecosystem nuget -Directory $dir -Name $package.id -Current $package.resolvedVersion -Target $package.latestVersion -Kind $kind -InRange ($kind -ne 'major') -Project $project
        }
    }

    # GitHub Actions: pins name a major tag, so an update is always a major.
    $pins = @{}
    foreach ($workflow in $tracked | Where-Object { $_ -match '^\.github/workflows/.+\.ya?ml$' }) {
        foreach ($match in [regex]::Matches((Get-Content -LiteralPath $workflow -Raw), 'uses:\s*([\w.-]+/[\w.-]+)(?:/[^@\s]*)?@(v\d+)\b')) {
            $action = $match.Groups[1].Value
            if ($action -like 'jwill89/shared-tooling') { continue }
            $pins[$action] = $match.Groups[2].Value
        }
    }
    if ($pins.Count -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
        $skipped.Add('github-actions: gh is not on PATH')
    } else {
        foreach ($action in $pins.Keys | Sort-Object) {
            $latest = gh api "repos/$action/releases/latest" --jq .tag_name 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $latest) { continue }
            $current = $pins[$action]
            if ((Get-VersionPart $latest)[0] -le (Get-VersionPart $current)[0]) { continue }
            $target = 'v{0}' -f (Get-VersionPart $latest)[0]
            Add-Update -Ecosystem github-actions -Directory '.' -Name $action -Current $current -Target $target -Kind major -InRange $false
        }
    }

    if ($Update) {
        $take = @($entries | Where-Object InRange)
        if (-not $take) { Write-Output 'Nothing in range to take.' }
        foreach ($group in $take | Group-Object Ecosystem, Directory) {
            $first = $group.Group[0]
            $names = @($group.Group | ForEach-Object Name)
            Write-Output "== $($first.Ecosystem) ($($first.Directory)): $($names -join ', ')"
            switch ($first.Ecosystem) {
                'npm' {
                    # The ranges rise and the families' lock entries go (npm-take-updates.mjs), so
                    # packages that pin each other move together; npm update left Tiptap split.
                    $specs = @($group.Group | ForEach-Object { "$($_.Name)@$($_.Target)" })
                    node (Join-Path $PSScriptRoot 'npm-take-updates.mjs') $first.Directory @specs
                    if ($LASTEXITCODE -ne 0) { throw "Raising the npm ranges failed in $($first.Directory)." }
                    npm install --prefer-offline --no-audit --prefix $first.Directory
                    if ($LASTEXITCODE -ne 0) { throw "npm install failed in $($first.Directory)." }
                }
                'gomod' {
                    foreach ($entry in $group.Group) {
                        go -C $first.Directory get "$($entry.Name)@$($entry.Target)"
                        if ($LASTEXITCODE -ne 0) { throw "go get $($entry.Name)@$($entry.Target) failed." }
                    }
                    go -C $first.Directory mod tidy
                    if ($LASTEXITCODE -ne 0) { throw "go mod tidy failed in $($first.Directory)." }
                }
                'composer' {
                    # All dependencies, so packages that require each other move together: rector
                    # needs a newer phpstan, a root requirement too, which --with-dependencies leaves.
                    composer update @names --with-all-dependencies --working-dir=$($first.Directory) --no-interaction
                    if ($LASTEXITCODE -ne 0) { throw "composer update failed in $($first.Directory)." }
                    # The floors rise to what is now installed (standards/packages.md), then the lock records them.
                    composer bump @names --working-dir=$($first.Directory) --no-interaction
                    composer update --lock --working-dir=$($first.Directory) --no-interaction
                    if ($LASTEXITCODE -ne 0) { throw "composer update --lock failed in $($first.Directory)." }
                }
                'nuget' {
                    foreach ($entry in $group.Group) {
                        dotnet add $entry.Project package $entry.Name --version $entry.Target
                        if ($LASTEXITCODE -ne 0) { throw "dotnet add package $($entry.Name) failed." }
                    }
                }
            }
        }
        return
    }

    if ($PassThru) {
        return $entries.ToArray()
    }

    $inRange = @($entries | Where-Object InRange)
    $majors = @($entries | Where-Object { -not $_.InRange })
    if ($inRange) {
        Write-Output 'In range, which Dependabot groups into one pull request per ecosystem (task shared:deps:update takes them):'
        foreach ($group in $inRange | Group-Object Ecosystem, Directory) {
            Write-Output "  $($group.Group[0].Ecosystem) ($($group.Group[0].Directory))"
            $group.Group | ForEach-Object { Write-Output ("    {0} {1} -> {2} ({3})" -f $_.Name, $_.Current, $_.Target, $_.Kind) }
        }
    }
    if ($majors) {
        Write-Output 'Majors and out-of-range, which Dependabot opens one by one; read their breaking changes first:'
        $majors | ForEach-Object { Write-Output ("  {0} ({1}) {2} {3} -> {4}" -f $_.Ecosystem, $_.Directory, $_.Name, $_.Current, $_.Target) }
    }
    if (-not $entries.Count) { Write-Output 'Up to date: Dependabot has nothing to open.' }
    if ($held) { Write-Output "$held more held back (by .github/dependabot.yml, a Composer conflict, or a package that depends on them), left out." }
    $skipped | ForEach-Object { Write-Warning $_ }
} finally {
    Pop-Location
}
