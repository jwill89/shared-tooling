#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Lists the dependency updates Dependabot would open for this repo, and with -Update takes
    the ones inside their ranges.

.DESCRIPTION
    What `task shared:deps` and `task shared:push` run, so updates are taken with a push
    rather than arriving as Dependabot's pull requests after it. For each ecosystem the repo
    tracks (the shared/ submodule left out), it finds the available updates:

      npm             npm outdated, in each folder with a package-lock.json
      Go              go list -m -u, the direct requirements of each go.mod
      Composer        composer outdated --direct, beside each composer.lock
      NuGet           dotnet list package --outdated, for each restored .csproj
      Python          each package a tracked .in file names, against PyPI's releases, where
                      uv pip compile wrote the .txt beside it (Dependabot's uv ecosystem)
      GitHub Actions  each workflow's `uses:` pins against the action's latest release

    It leaves out what .github/dependabot.yml holds: an `ignore` entry's dependency-name
    (with * patterns), limited to its update-types or versions when it names them. It reads
    the file in the shape of repo/dependabot.example.yml, line by line, since PowerShell has
    no YAML parser. It leaves out, too, a NuGet package no project file of the repo names:
    one an SDK adds by itself, such as Dalamud.NET.Sdk's DotNet.ReproducibleBuilds, which
    Dependabot never sees and which moves only with that SDK. The report counts those apart.

    An update short of a new major (for npm the newest release in the installed major, so a
    pinned version or a ~ range rises as Dependabot raises it; a Composer "semver-safe-update";
    any Go or NuGet minor or patch; for Python the newest release inside the .in file's range)
    is one Dependabot would fold into the ecosystem's grouped pull request; -Update takes
    those. A major is one Dependabot opens alone, after its breaking changes are read, so it is
    listed and never taken; so is a Python release outside its range, such as ruff 0.18 for
    <0.18. GitHub Actions pins name a major tag (v7), so their updates are majors too.

    For Python, a release counts once it is final (no pre-release or dev release), not yanked,
    and allows the Python the folder's .python-version names. A requirement pinned by URL,
    such as a model wheel, has no releases to compare, and is counted apart.

    modernc.org/libc is never raised by name: modernc.org/sqlite is released against one
    exact libc and brings it along (standards/packages.md).

.PARAMETER Path
    The repo. Defaults to the current folder.

.PARAMETER Update
    Take the in-range updates: for npm, each package's range raised to the new version and
    its family's lockfile entries dropped (npm-take-updates.mjs), then npm install, so
    packages that pin each other move together, and the lockfile held to npm ci's check
    (npm ci --dry-run): resolved again with npm install --package-lock-only when it fails
    it, and the update stopped when it still does; go get each module at its version then
    go mod tidy; composer update then composer bump for those packages; dotnet add package; and
    for Python, each package's floor in its .in file raised to the new version (>=, == or ~=),
    then every compiled file in that folder made again by the command its header records,
    with --upgrade-package for each, a file another one reads (-r, -c) first, and the
    folder's .venv given the result. Majors and held versions are left alone.

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

function Test-NewerVersion {
    # Whether $Candidate is a later version than $Than, prereleases ordered as semver orders them.
    param([string] $Candidate, [string] $Than)
    $a = $null
    $b = $null
    if ([System.Management.Automation.SemanticVersion]::TryParse($Candidate, [ref] $a) -and
        [System.Management.Automation.SemanticVersion]::TryParse($Than, [ref] $b)) {
        return $a -gt $b
    }
    $x = Get-VersionPart $Candidate
    $y = Get-VersionPart $Than
    if (-not $x -or -not $y) { return $Candidate -ne $Than }
    foreach ($i in 0..2) {
        if ($x[$i] -ne $y[$i]) { return $x[$i] -gt $y[$i] }
    }
    $false
}

function Get-NpmNewestInMajor {
    # The newest release in the installed version's major (0.x counted as one major, as
    # Get-UpdateKind counts it), prereleases left out; $null when the registry has none newer.
    # Asked only when "latest" is a major away, since npm outdated says nothing in between.
    param([string] $Directory, [string] $Name, [string] $Current)
    $parts = Get-VersionPart $Current
    if (-not $parts) { return $null }
    $raw = npm view "$Name@$($parts[0]).x" version --json --prefix $Directory 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    $newest = @($raw | Out-String | ConvertFrom-Json)[-1]
    if ($newest -and (Test-NewerVersion $newest $Current)) { $newest } else { $null }
}

function Get-NpmLockfileProblem {
    # What npm ci refuses in the folder's lockfile, as CI's install would meet it: npm's lines
    # naming each package the lockfile lacks or holds at a version package.json doesn't allow,
    # or its first error line when it names none; nothing when the lockfile passes. A dry run
    # leaves node_modules as it is.
    param([string] $Directory)
    $output = @(npm ci --dry-run --no-audit --no-fund --prefix $Directory 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    if ($code -eq 0) { return }
    $named = @($output | Where-Object { $_ -match '^npm error (Missing|Invalid): ' } | ForEach-Object { $_ -replace '^npm error ', '' })
    if ($named) { return $named }
    $line = $output | Where-Object { $_ -match '^npm error \S' } | Select-Object -First 1
    if ($line) { $line -replace '^npm error ', '' } else { "npm ci --dry-run exited $code" }
}

function ConvertTo-PythonVersion {
    # A PEP 440 version's parts, normalized (1.0RC1 and 1.0rc1 alike); $null when it isn't one.
    param([string] $Value)
    $pattern = '^v?(?:(?<epoch>\d+)!)?(?<release>\d+(?:\.\d+)*)' +
    '(?:[-_.]?(?<phase>a|b|c|rc|alpha|beta|pre|preview)[-_.]?(?<pre>\d*))?' +
    '(?:-(?<post1>\d+)|[-_.]?(?:post|rev|r)[-_.]?(?<post2>\d*))?' +
    '(?:[-_.]?(?<dev>dev)[-_.]?(?<devn>\d*))?(?:\+[a-z0-9]+(?:[-_.][a-z0-9]+)*)?$'
    $match = [regex]::Match("$Value".Trim().ToLowerInvariant(), $pattern)
    if (-not $match.Success) { return $null }
    $number = { param($group) if ($group.Success -and $group.Value) { [long]$group.Value } else { 0 } }
    $phase = switch ($match.Groups['phase'].Value) {
        { $_ -in 'a', 'alpha' } { 0 } { $_ -in 'b', 'beta' } { 1 } { $_ -in 'c', 'rc', 'pre', 'preview' } { 2 } default { -1 }
    }
    $hasPost = $match.Groups['post1'].Success -or $match.Groups['post2'].Success
    [pscustomobject]@{
        Epoch   = & $number $match.Groups['epoch']
        Release = [long[]]($match.Groups['release'].Value -split '\.')
        Phase   = $phase
        Pre     = & $number $match.Groups['pre']
        Post    = if ($hasPost) { [long]("0" + $match.Groups['post1'].Value + $match.Groups['post2'].Value) } else { -1 }
        Dev     = if ($match.Groups['dev'].Success) { & $number $match.Groups['devn'] } else { [long]::MaxValue }
        Final   = $phase -lt 0 -and -not $match.Groups['dev'].Success
    }
}

function Compare-PythonVersion {
    # -1, 0 or 1, as PEP 440 orders two parsed versions; a local label is not compared.
    param([object] $A, [object] $B)
    if ($A.Epoch -ne $B.Epoch) { return [Math]::Sign($A.Epoch - $B.Epoch) }
    $length = [Math]::Max($A.Release.Count, $B.Release.Count)
    for ($i = 0; $i -lt $length; $i++) {
        $x = if ($i -lt $A.Release.Count) { $A.Release[$i] } else { 0 }
        $y = if ($i -lt $B.Release.Count) { $B.Release[$i] } else { 0 }
        if ($x -ne $y) { return [Math]::Sign($x - $y) }
    }
    # A dev release with nothing else sorts before the pre-releases; a final one after them.
    $stage = { param($v) if ($v.Phase -ge 0) { $v.Phase } elseif ($v.Post -lt 0 -and $v.Dev -ne [long]::MaxValue) { -1 } else { 9 } }
    foreach ($pair in @((& $stage $A), (& $stage $B)), @($A.Pre, $B.Pre), @($A.Post, $B.Post), @($A.Dev, $B.Dev)) {
        if ($pair[0] -ne $pair[1]) { return [Math]::Sign($pair[0] - $pair[1]) }
    }
    0
}

function Test-PythonSpecifier {
    # Whether a version string meets a PEP 440 specifier set ('>=3.1.3,<4'); an empty set allows
    # anything. A clause this can't read counts as met, so nothing is hidden by a misreading.
    param([string] $Version, [string] $Specifier)
    $v = ConvertTo-PythonVersion $Version
    if (-not $v) { return $false }
    foreach ($clause in "$Specifier" -split ',') {
        $clause = $clause.Trim()
        if (-not $clause) { continue }
        if ($clause -notmatch '^(?<op>===|~=|==|!=|<=|>=|<|>)\s*(?<value>\S+)$') { continue }
        $op = $Matches['op']
        $value = $Matches['value']
        if ($op -eq '===') {
            if ($Version -ne $value) { return $false }
            continue
        }
        if ($op -in '==', '!=' -and $value.EndsWith('.*')) {
            $prefix = ConvertTo-PythonVersion $value.Substring(0, $value.Length - 2)
            if (-not $prefix) { continue }
            $same = $v.Epoch -eq $prefix.Epoch
            for ($i = 0; $same -and $i -lt $prefix.Release.Count; $i++) {
                $same = ($(if ($i -lt $v.Release.Count) { $v.Release[$i] } else { 0 })) -eq $prefix.Release[$i]
            }
            if ($same -ne ($op -eq '==')) { return $false }
            continue
        }
        $w = ConvertTo-PythonVersion $value
        if (-not $w) { continue }
        $order = Compare-PythonVersion $v $w
        $met = switch ($op) {
            '==' { $order -eq 0 }
            '!=' { $order -ne 0 }
            '<=' { $order -le 0 }
            '>=' { $order -ge 0 }
            '<' { $order -lt 0 }
            # >1.7 leaves out 1.7's post-releases, as PEP 440 says.
            '>' { $order -gt 0 -and -not ($v.Post -ge 0 -and $w.Post -lt 0 -and (Compare-PythonVersion ([pscustomobject]@{ Epoch = $v.Epoch; Release = $v.Release; Phase = $v.Phase; Pre = $v.Pre; Post = -1; Dev = $v.Dev }) $w) -eq 0) }
            '~=' {
                if ($w.Release.Count -lt 2) { $true } else {
                    $upper = [long[]]@($w.Release[0..($w.Release.Count - 2)])
                    $upper[-1]++
                    $order -ge 0 -and (Compare-PythonVersion $v ([pscustomobject]@{ Epoch = $w.Epoch; Release = $upper; Phase = 0; Pre = 0; Post = -1; Dev = 0 })) -lt 0
                }
            }
        }
        if (-not $met) { return $false }
    }
    $true
}

function Get-PythonName {
    # A package name as PEP 503 normalizes it, as uv writes it in a compiled file.
    param([string] $Name)
    ($Name -replace '[-_.]+', '-').ToLowerInvariant()
}

function Read-PythonRequirement {
    # The packages an .in file names directly: Name, Specifier and Line (its index in the file).
    # -r, -c and other options are skipped, and a requirement pinned by URL comes back with Url set.
    param([string] $File)
    $lines = @(Get-Content -LiteralPath $File)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $text = ($lines[$i] -replace '(^|\s)#.*$', '').Trim()
        if (-not $text -or $text.StartsWith('-')) { continue }
        if ($text -notmatch '^(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^\]]*\])?\s*(?<rest>[^;]*)') { continue }
        $rest = $Matches['rest'].Trim()
        [pscustomobject]@{
            Name      = $Matches['name']
            Specifier = if ($rest.StartsWith('@')) { '' } else { $rest }
            Url       = $rest.StartsWith('@')
            Line      = $i
        }
    }
}

function Get-PythonCompileCommand {
    # The uv pip compile arguments a compiled file's header records, or $null when uv didn't
    # write it or the header holds another command (--custom-compile-command).
    param([string] $File)
    $head = @(Get-Content -LiteralPath $File -TotalCount 2)
    if ($head.Count -lt 2 -or $head[0] -notmatch 'autogenerated by uv') { return $null }
    $command = ($head[1] -replace '^#\s*', '').Trim()
    if ($command -notmatch '^uv pip compile ' -or $command -match '[''"`$;&|<>\\]') { return $null }
    , @($command -split '\s+' | Select-Object -Skip 3)
}

function Get-PyPIRelease {
    # The final, unyanked releases of a package on PyPI that allow $Python (when given), oldest
    # first; $null when PyPI can't be read.
    param([string] $Name, [string] $Python)
    if ($script:pypi.ContainsKey($Name)) { return $script:pypi[$Name] }
    try {
        $data = Invoke-RestMethod -Uri "https://pypi.org/pypi/$([uri]::EscapeDataString($Name))/json" -TimeoutSec 30
    } catch {
        $script:pypi[$Name] = $null
        return $null
    }
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($property in $data.releases.PSObject.Properties) {
        $parsed = ConvertTo-PythonVersion $property.Name
        $files = @($property.Value)
        if (-not $parsed -or -not $parsed.Final -or -not $files) { continue }
        $live = @($files | Where-Object { -not $_.yanked })
        if (-not $live) { continue }
        if ($Python) {
            $allowed = @($live | Where-Object { -not $_.requires_python -or (Test-PythonSpecifier $Python $_.requires_python) })
            if (-not $allowed) { continue }
        }
        $found.Add([pscustomobject]@{ Version = $property.Name; Parsed = $parsed })
    }
    $sorted = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $found) {
        $at = 0
        while ($at -lt $sorted.Count -and (Compare-PythonVersion $sorted[$at].Parsed $item.Parsed) -lt 0) { $at++ }
        $sorted.Insert($at, $item)
    }
    $script:pypi[$Name] = $sorted.ToArray()
    $script:pypi[$Name]
}

function Invoke-PythonRequirementUpdate {
    # Raises each entry's floor in its .in file, compiles every uv-written file in the folder
    # again by its header's command (a file another .in reads first), then reinstalls .venv.
    param([string] $Directory, [object[]] $Entry, [string[]] $Tracked)
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { throw 'uv is not on PATH, so the Python requirements cannot be compiled again.' }
    foreach ($item in $Entry) {
        $lines = @(Get-Content -LiteralPath $item.Project)
        $requirement = Read-PythonRequirement -File $item.Project | Where-Object { (Get-PythonName $_.Name) -eq (Get-PythonName $item.Name) } | Select-Object -First 1
        if (-not $requirement) { continue }
        $target = $item.Target
        # >= and == take the new version; ~= keeps its number of parts (~=3.1 becomes ~=3.2).
        $lines[$requirement.Line] = $lines[$requirement.Line] -replace '(>=|==|~=)\s*(\d[^,;\s#]*)', {
            $op = $_.Groups[1].Value
            if ($op -ne '~=') { return "$op$target" }
            $parts = @($_.Groups[2].Value -split '\.').Count
            "$op$((@($target -split '\.') | Select-Object -First $parts) -join '.')"
        }
        [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $item.Project).Path, (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    }

    # The folder's uv-written files, in an order where a file comes after those it reads.
    $files = @($Tracked | Where-Object {
            $_ -match '\.in$' -and ((Split-Path -Path $_ -Parent) -replace '^$', '.') -eq $Directory -and
            $Tracked -contains ($_ -replace '\.in$', '.txt') -and (Get-PythonCompileCommand -File ($_ -replace '\.in$', '.txt'))
        })
    $reads = @{}
    foreach ($file in $files) {
        $reads[$file] = @(Get-Content -LiteralPath $file | ForEach-Object {
                if ($_ -match '^\s*-[rc]\s+(\S+)') { (Join-Path $Directory ($Matches[1] -replace '\.txt$', '.in')) -replace '\\', '/' -replace '^\./', '' }
            } | Where-Object { $files -contains $_ })
    }
    $order = [System.Collections.Generic.List[string]]::new()
    while ($order.Count -lt $files.Count) {
        $next = @($files | Where-Object { $order -notcontains $_ -and -not @($reads[$_] | Where-Object { $order -notcontains $_ }) })
        if (-not $next) { throw "The .in files in $Directory read each other in a circle." }
        $next | ForEach-Object { $order.Add($_) }
    }
    $upgrade = @($Entry | ForEach-Object { '--upgrade-package', $_.Name })
    Push-Location -LiteralPath $Directory
    try {
        foreach ($file in $order) {
            $compiled = Split-Path -Path ($file -replace '\.in$', '.txt') -Leaf
            $arguments = Get-PythonCompileCommand -File $compiled
            Write-Output "   uv pip compile $($arguments -join ' ')"
            uv pip compile --quiet @arguments @upgrade
            if ($LASTEXITCODE -ne 0) { throw "uv pip compile failed for $compiled." }
        }
        if (Test-Path -LiteralPath '.venv') {
            # The files no other .in reads hold everything the others do.
            foreach ($top in $order | Where-Object { $file = $_; -not @($reads.Values | Where-Object { $_ -contains $file }) }) {
                uv pip install --quiet --require-hashes -r (Split-Path -Path ($top -replace '\.in$', '.txt') -Leaf)
                if ($LASTEXITCODE -ne 0) { throw "Installing $($top -replace '\.in$', '.txt') into .venv failed." }
            }
        }
    } finally {
        Pop-Location
    }
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
    # NuGet packages an SDK adds, which no project file names.
    $script:implied = [System.Collections.Generic.List[string]]::new()
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
            # Dependabot's grouped pull request takes a package to its newest release short of a
            # new major, raising a pinned version or a ~ range as it raises a ^ one. npm's
            # "wanted" stays inside the range, so it never shows a pin's updates.
            $latestIsMajor = -not $info.latest -or (Get-UpdateKind $info.current $info.latest) -eq 'major'
            $target = if (-not $latestIsMajor) { $info.latest } else { (Get-NpmNewestInMajor -Directory $dir -Name $name -Current $info.current) ?? $info.wanted }
            if ($target -and (Test-NewerVersion $target $info.current)) {
                Add-Update -Ecosystem npm -Directory $dir -Name $name -Current $info.current -Target $target -Kind (Get-UpdateKind $info.current $target) -InRange $true
            }
            if ($info.latest -and $latestIsMajor -and (Test-NewerVersion $info.latest $info.current)) {
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
        # `conflict` holds, or a package another one holds back (a held phpstan keeps back the
        # rector that needs a newer one), so an in-range update counts only if the dry run takes it.
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

    # NuGet. Only the packages the repo's own MSBuild files name, as Dependabot reads them: dotnet
    # list package also reports what an SDK adds by itself (Dalamud.NET.Sdk's
    # DotNet.ReproducibleBuilds), as if a project had asked for it.
    $msbuild = @($tracked | Where-Object { $_ -match '\.(csproj|props|targets)$' -and (Test-Path -LiteralPath $_) } |
            ForEach-Object { Get-Content -LiteralPath $_ -Raw })
    foreach ($project in $tracked | Where-Object { $_ -match '\.csproj$' }) {
        $dir = Split-Path -Path $project -Parent
        if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { $skipped.Add('nuget: dotnet is not on PATH'); break }
        $raw = dotnet list $project package --outdated --format json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { $skipped.Add("nuget ($project): not restored; build it once first"); continue }
        $report = ($raw | Out-String) | ConvertFrom-Json
        foreach ($package in @($report.projects.frameworks.topLevelPackages | Where-Object { $_ })) {
            if (-not $package.latestVersion -or $package.latestVersion -eq $package.resolvedVersion) { continue }
            $named = "(?i)\b(Include|Update)\s*=\s*[`"']$([regex]::Escape($package.id))[`"']"
            if (-not @($msbuild | Where-Object { $_ -match $named })) {
                if ($package.id -notin $script:implied) { $script:implied.Add($package.id) }
                continue
            }
            $kind = Get-UpdateKind $package.resolvedVersion $package.latestVersion
            if ($script:entries | Where-Object { $_.Ecosystem -eq 'nuget' -and $_.Name -eq $package.id -and $_.Project -eq $project }) { continue }
            Add-Update -Ecosystem nuget -Directory $dir -Name $package.id -Current $package.resolvedVersion -Target $package.latestVersion -Kind $kind -InRange ($kind -ne 'major') -Project $project
        }
    }

    # Python: the packages each .in file names, where uv pip compile wrote the .txt beside it.
    # Held versions are read under Dependabot's uv ecosystem, which updates those files.
    $script:pypi = @{}
    $script:byUrl = 0
    foreach ($in in $tracked | Where-Object { $_ -match '\.in$' }) {
        $compiled = $in -replace '\.in$', '.txt'
        if ($tracked -notcontains $compiled) { continue }
        $header = @(Get-Content -LiteralPath $compiled -TotalCount 1)
        if ("$header" -notmatch 'autogenerated by uv') { $skipped.Add("python ($in): $compiled was not written by uv pip compile"); continue }
        $dir = Split-Path -Path $in -Parent
        if (-not $dir) { $dir = '.' }
        $versionFile = Join-Path $dir '.python-version'
        $python = if (Test-Path -LiteralPath $versionFile) { (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim() } else { '' }
        $pins = @{}
        foreach ($line in Get-Content -LiteralPath $compiled) {
            if ($line -match '^([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;\\]+)') { $pins[(Get-PythonName $Matches[1])] = $Matches[2] }
        }
        foreach ($requirement in Read-PythonRequirement -File $in) {
            if ($requirement.Url) { $script:byUrl++; continue }
            $current = $pins[(Get-PythonName $requirement.Name)]
            if (-not $current) { $skipped.Add("python ($in): $($requirement.Name) is not pinned in $compiled; compile it again"); continue }
            $releases = Get-PyPIRelease -Name $requirement.Name -Python $python
            if ($null -eq $releases) { $skipped.Add("python ($in): PyPI did not answer for $($requirement.Name)"); continue }
            $now = ConvertTo-PythonVersion $current
            $newer = @($releases | Where-Object { (Compare-PythonVersion $_.Parsed $now) -gt 0 })
            if (-not $newer) { continue }
            $inRange = @($newer | Where-Object { Test-PythonSpecifier $_.Version $requirement.Specifier })
            if ($inRange) {
                $target = $inRange[-1].Version
                Add-Update -Ecosystem uv -Directory $dir -Name $requirement.Name -Current $current -Target $target -Kind (Get-UpdateKind $current $target) -InRange $true -Project $in
            }
            $latest = $newer[-1].Version
            if (-not (Test-PythonSpecifier $latest $requirement.Specifier)) {
                $kind = Get-UpdateKind $current $latest
                Add-Update -Ecosystem uv -Directory $dir -Name $requirement.Name -Current $current -Target $latest -Kind $kind -InRange $false -Project $in
            }
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
                    # npm's own cache rules, not --prefer-offline: the new versions came from the
                    # registry, and --prefer-offline resolves them against the cached package lists,
                    # which can predate them and their new dependencies (a release out that day, and
                    # one it needs). A tarball the lockfile names
                    # with its integrity still comes from the cache, so Font Awesome isn't fetched again.
                    npm install --no-audit --prefix $first.Directory
                    if ($LASTEXITCODE -ne 0) { throw "npm install failed in $($first.Directory)." }
                    # npm install doesn't always resolve a dropped entry again when only a package it
                    # kept needs it, and npm ci then refuses the lockfile. So the lockfile is held to
                    # npm ci's check here, before anything is committed, and resolved again in full
                    # when it fails it, node_modules following.
                    $problem = @(Get-NpmLockfileProblem -Directory $first.Directory)
                    if ($problem) {
                        Write-Output "  npm ci would refuse the lockfile ($($problem -join '; ')); resolving it again with npm install --package-lock-only."
                        npm install --package-lock-only --no-audit --prefix $first.Directory
                        if ($LASTEXITCODE -ne 0) { throw "npm install --package-lock-only failed in $($first.Directory)." }
                        npm install --no-audit --prefix $first.Directory
                        if ($LASTEXITCODE -ne 0) { throw "npm install failed in $($first.Directory)." }
                        $problem = @(Get-NpmLockfileProblem -Directory $first.Directory)
                        if ($problem) { throw "npm ci still refuses the lockfile in $($first.Directory): $($problem -join '; ')." }
                    }
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
                'uv' {
                    Invoke-PythonRequirementUpdate -Directory $first.Directory -Entry $group.Group -Tracked $tracked
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
    if ($implied.Count) { Write-Output "$($implied.Count) more an SDK adds rather than a project file ($($implied -join ', ')), left out: Dependabot never sees them, and they move with that SDK." }
    if ($script:byUrl) { Write-Output "$($script:byUrl) Python requirement(s) pinned by URL, left out: they have no releases to compare, and move by hand." }
    $skipped | ForEach-Object { Write-Warning $_ }
} finally {
    Pop-Location
}
