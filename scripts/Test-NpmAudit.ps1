#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests repo/Invoke-NpmAudit.ps1 on recorded npm audit reports: what `task test:scripts`
    and CI's script-tests job run.

.DESCRIPTION
    Each case writes an osv-scanner.toml, or none, into a scratch folder, its dates set from
    today, and runs the script there in a pwsh of its own on one of the reports in
    fixtures/npm-audit, each the `npm audit --omit=dev --json` output npm wrote:

      picomatch.json          picomatch's ReDoS advisory, high, and the packages flagged
                              only through it (vue-router through @vue-macros/common and
                              unplugin-utils, vite through tinyglobby and fdir)
      picomatch-lodash.json   the same, beside lodash's own high and moderate advisories
      postcss.json            one package's high and moderate advisories
      clean.json              nothing found
      no-lockfile.json        npm's error for a folder with no package-lock.json

    It checks each run's exit code and the lines it printed, prints ok or FAIL for each
    case, and exits 1 when any fails.

.EXAMPLE
    pwsh scripts/Test-NpmAudit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$audit = Join-Path $PSScriptRoot '../repo/Invoke-NpmAudit.ps1'
$fixtures = Join-Path $PSScriptRoot 'fixtures/npm-audit'
$culture = [Globalization.CultureInfo]::InvariantCulture
$today = (Get-Date).Date
$ahead = $today.AddDays(90).ToString('yyyy-MM-dd', $culture)
$yesterday = $today.AddDays(-1).ToString('yyyy-MM-dd', $culture)
$todayText = $today.ToString('yyyy-MM-dd', $culture)

$picomatch = 'GHSA-fc5q-39xc-vjpf'
$picomatchReason = 'Build tooling only; no picomatch release fixes it yet.'
$picomatchDependents = '@vue-macros/common, fdir, tinyglobby, unplugin, unplugin-utils, vite, vue-router'

function ConvertTo-IgnoredVuln {
    <#
    .SYNOPSIS
        One [[IgnoredVulns]] entry as an osv-scanner.toml writes it; no Until leaves out its
        ignoreUntil.
    #>
    param([string] $Id, [string] $Until, [string] $Reason = 'Build tooling only.')

    $lines = @('[[IgnoredVulns]]', "id = `"$Id`"")
    if ($Until) {
        $lines += "ignoreUntil = $Until"
    }
    $lines += "reason = `"$Reason`""
    ($lines + '') -join "`n"
}

$cases = @(
    @{
        Name   = 'an advisory the file lists, with its ignoreUntil ahead, is passed over with its reason'
        Report = 'picomatch.json'
        Toml   = ConvertTo-IgnoredVuln -Id $picomatch -Until $ahead -Reason $picomatchReason
        Exit   = 0
        Has    = @(
            "$picomatch (picomatch, high, until $ahead) has been passed over because: $picomatchReason"
            'No advisory of high severity or above fails the audit.'
        )
        Lacks  = @('Failing the audit')
    }
    @{
        Name   = 'a package flagged only through a passed-over advisory, however far down, is passed over with it'
        Report = 'picomatch.json'
        Toml   = ConvertTo-IgnoredVuln -Id $picomatch -Until $ahead -Reason $picomatchReason
        Exit   = 0
        Has    = @("Flagged only through what is passed over, so passed over too: $picomatchDependents")
    }
    @{
        Name   = 'an entry whose ignoreUntil has passed passes nothing over'
        Report = 'picomatch.json'
        Toml   = ConvertTo-IgnoredVuln -Id $picomatch -Until $yesterday -Reason $picomatchReason
        Exit   = 1
        Has    = @(
            "  $picomatch (picomatch, high): picomatch vulnerable to ReDoS through single-branch repeated extglobs"
            "    Its osv-scanner.toml entry ran out on $yesterday."
            "    Reaching it: $picomatchDependents"
        )
        Lacks  = @('has been passed over')
    }
    @{
        Name   = 'an entry runs out at the start of its ignoreUntil day, as OSV-Scanner''s does'
        Report = 'picomatch.json'
        Toml   = ConvertTo-IgnoredVuln -Id $picomatch -Until $todayText -Reason $picomatchReason
        Exit   = 1
        Has    = @("    Its osv-scanner.toml entry ran out on $todayText.")
    }
    @{
        Name   = 'an entry with no ignoreUntil never runs out'
        Report = 'picomatch.json'
        Toml   = ConvertTo-IgnoredVuln -Id $picomatch -Until '' -Reason $picomatchReason
        Exit   = 0
        Has    = @("$picomatch (picomatch, high) has been passed over because: $picomatchReason")
    }
    @{
        Name   = 'an advisory the file doesn''t list fails, while the one it lists is passed over'
        Report = 'picomatch-lodash.json'
        Toml   = ConvertTo-IgnoredVuln -Id $picomatch -Until $ahead -Reason $picomatchReason
        Exit   = 1
        Has    = @(
            "$picomatch (picomatch, high, until $ahead) has been passed over because: $picomatchReason"
            '  GHSA-35jh-r3h4-6jhm (lodash, high): Command Injection in lodash'
            '  GHSA-r5fr-rjxr-66jc (lodash, high): lodash vulnerable to Code Injection via `_.template` imports key names'
            '2 advisories of high severity or above, in lodash.'
        )
        Lacks  = @("  $picomatch (picomatch, high):")
    }
    @{
        Name   = 'an id is matched exactly, as OSV-Scanner matches it'
        Report = 'picomatch.json'
        Toml   = ConvertTo-IgnoredVuln -Id $picomatch.ToLowerInvariant() -Until $ahead -Reason $picomatchReason
        Exit   = 1
        Has    = @("  $picomatch (picomatch, high):")
    }
    @{
        Name   = 'an advisory below high fails nothing'
        Report = 'postcss.json'
        Toml   = (ConvertTo-IgnoredVuln -Id 'GHSA-6g55-p6wh-862q' -Until $ahead) + "`n" + (ConvertTo-IgnoredVuln -Id 'GHSA-r28c-9q8g-f849' -Until $ahead)
        Exit   = 0
        Has    = @(
            'Below high severity, so failing nothing:'
            '  GHSA-7fh5-64p2-3v2j (postcss, moderate): PostCSS line return parsing error'
            'No advisory of high severity or above fails the audit.'
        )
    }
    @{
        Name   = 'only [[IgnoredVulns]] entries pass anything over, and another table''s keys stay out of them'
        Report = 'picomatch-lodash.json'
        Toml   = "# A comment, then the entry.`n" + (ConvertTo-IgnoredVuln -Id $picomatch -Until $ahead -Reason $picomatchReason) + "`n[[PackageOverrides]]`nname = `"lodash`"`necosystem = `"npm`"`nignore = true`nreason = `"Another table's reason.`"`n"
        Exit   = 1
        Has    = @(
            "$picomatch (picomatch, high, until $ahead) has been passed over because: $picomatchReason"
            '  GHSA-35jh-r3h4-6jhm (lodash, high): Command Injection in lodash'
        )
        Lacks  = @("Another table's reason.")
    }
    @{
        Name   = 'with no osv-scanner.toml, a high advisory fails, as npm audit --audit-level=high does'
        Report = 'picomatch.json'
        Exit   = 1
        Has    = @(
            "  $picomatch (picomatch, high): picomatch vulnerable to ReDoS through single-branch repeated extglobs"
            '1 advisory of high severity or above, in @vue-macros/common, fdir, picomatch, tinyglobby, unplugin, unplugin-utils, vite, vue-router.'
        )
        Lacks  = @('has been passed over', 'ran out')
    }
    @{
        Name   = 'with no osv-scanner.toml, a report with no advisory passes'
        Report = 'clean.json'
        Exit   = 0
        Has    = @('npm audit found no advisory in the packages that ship.')
    }
    @{
        Name   = 'a report npm couldn''t make stops the script with npm''s message'
        Report = 'no-lockfile.json'
        Exit   = 1
        Has    = @('npm audit made no report: This command requires an existing lockfile. Try creating one first with: npm i --package-lock-only')
    }
)

$scratch = Join-Path ([IO.Path]::GetTempPath()) "npm-audit-test-$([guid]::NewGuid().ToString('N'))"
$failed = 0
try {
    foreach ($case in $cases) {
        $folder = New-Item -ItemType Directory -Path (Join-Path $scratch ([guid]::NewGuid().ToString('N')))
        if ($case.Toml) {
            Set-Content -LiteralPath (Join-Path $folder 'osv-scanner.toml') -Value $case.Toml -Encoding utf8NoBOM -NoNewline
        }

        # A thrown error arrives on stderr, coloured and wrapped to the console's width.
        $ErrorActionPreference = 'Continue'
        try {
            $lines = & pwsh -NoProfile -File $audit -Path $folder.FullName -ReportFile (Join-Path $fixtures $case.Report) 2>&1 |
                ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ } }
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = 'Stop'
        }
        $output = (@($lines) -join "`n") -replace '\x1b\[[0-9;]*m', ''
        # The error's lines joined again, each without the '|' pwsh starts it with, so a
        # message matches however wide the console wrapped it.
        $joined = ((($output -split "`n") -replace '^\s*\|?\s*', '') -join ' ') -replace '\s+', ' '

        $problems = @()
        if ($code -ne $case.Exit) {
            $problems += "exited $code, not $($case.Exit)"
        }
        foreach ($text in @($case.Has)) {
            if (-not $output.Contains($text) -and -not $joined.Contains($text)) {
                $problems += "didn't print: $text"
            }
        }
        foreach ($text in @($case.Lacks)) {
            if ($output.Contains($text) -or $joined.Contains($text)) {
                $problems += "printed: $text"
            }
        }

        if ($problems.Count) {
            $failed++
            Write-Output "FAIL  $($case.Name)"
            $problems | ForEach-Object { Write-Output "        $_" }
            Write-Output '        Its output:'
            $output -split "`n" | ForEach-Object { Write-Output "        | $_" }
        } else {
            Write-Output "ok    $($case.Name)"
        }
    }
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output "$($cases.Count - $failed) of $($cases.Count) passed."
exit $(if ($failed) { 1 } else { 0 })
