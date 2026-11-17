#Requires -Version 7.4
<#
.SYNOPSIS
What the CI scripts share: reading a check's output for the problems it names, writing a
check as Markdown, and matching repo paths against globs.
#>

$ErrorActionPreference = 'Stop'

# Folders whose files are never a project's own, so a stack trace into them is no finding.
$script:ForeignPath = '(^|/)(node_modules|vendor|\.venv|shared)/'

function ConvertTo-PlainText {
    <#
    .SYNOPSIS
    The text without terminal colour and cursor codes.
    #>
    [OutputType([string])]
    param([AllowEmptyString()] [string]$Text)
    $Text -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', '' -replace '\x1b\][^\x07]*\x07', ''
}

function ConvertFrom-CommandValue {
    <#
    .SYNOPSIS
    A workflow command's property or message, its %-escapes decoded.
    #>
    [OutputType([string])]
    param([AllowEmptyString()] [string]$Value)
    $Value -replace '%0D', "`r" -replace '%0A', "`n" -replace '%3A', ':' -replace '%2C', ',' -replace '%25', '%'
}

function ConvertTo-CommandValue {
    <#
    .SYNOPSIS
    A value escaped for a workflow command: -Property also escapes the colon and comma that end a property.
    #>
    [OutputType([string])]
    param([AllowEmptyString()] [string]$Value, [switch]$Property)
    $escaped = $Value -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
    if ($Property) {
        $escaped = $escaped -replace ':', '%3A' -replace ',', '%2C'
    }
    $escaped
}

function Resolve-CiPath {
    <#
    .SYNOPSIS
    A path a tool printed, as a repo-relative path to a file of the repo's own, or nothing.

    .DESCRIPTION
    Tried against the folder the command ran in, then the repo's root. A bare file name no
    folder holds is looked up among the tracked files, and kept when exactly one has it (go
    test prints a test file's name alone). A file under node_modules, vendor, .venv or shared
    is not the project's own, so it gives nothing; so does a path to no file, unless -Trust
    says the tool named a repo path itself.
    #>
    [OutputType([string])]
    param(
        [string]$Path,
        [string]$Directory,
        [string]$Root,
        [string[]]$TrackedFile = @(),
        [switch]$Trust
    )
    $given = ($Path -replace '\\', '/') -replace '^file://', ''
    if (-not $given) {
        return $null
    }
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('/', '\')
    $candidates = if ([IO.Path]::IsPathRooted($given)) { @($given) } else { @((Join-Path $Directory $given), (Join-Path $Root $given)) }
    foreach ($candidate in $candidates) {
        $full = [IO.Path]::GetFullPath($candidate)
        if ($full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, $comparison) -and (Test-Path -LiteralPath $full -PathType Leaf)) {
            $relative = [IO.Path]::GetRelativePath($rootFull, $full) -replace '\\', '/'
            if ($relative -match $script:ForeignPath) {
                return $null
            }
            return $relative
        }
    }
    if ($given -notmatch '/' -and $TrackedFile) {
        $named = @($TrackedFile | Where-Object { $_ -eq $given -or $_.EndsWith("/$given", $comparison) })
        if ($named.Count -eq 1 -and $named[0] -notmatch $script:ForeignPath) {
            return $named[0]
        }
    }
    if ($Trust -and -not [IO.Path]::IsPathRooted($given)) {
        return ($given -replace '^\./', '')
    }
    $null
}

function Get-CiFinding {
    <#
    .SYNOPSIS
    The problems a check's output names, each with its file, line, column, severity, rule and message.

    .DESCRIPTION
    Reads the forms the shared stacks' tools print:
      - a workflow command a tool wrote itself (ruff's github format, PHPStan under Actions);
      - path:line:col: message, and path(line,col): message, with or without a severity
        (go vet, golangci-lint, tsc and vue-tsc, ruff, mypy, actionlint, markdownlint,
        dotnet, pytest, PSScriptAnalyzer through Invoke-ScriptLint.ps1);
      - a file's name on a line of its own, then line:col severity message rule beneath it
        (ESLint's and Stylelint's default formatters);
      - a numbered failure, its message, then path:line (PHPUnit), and a numbered file with
        its rules (PHP CS Fixer);
      - FAIL test, an Error: line, then the location (Vitest), and a test's location between
        arrows (Playwright);
      - [warn] path (Prettier --check), and name path:line:col under a heading (knip).
    Only paths to the repo's own files count, so a stack trace into a dependency is passed
    over. A finding read from a workflow command carries Annotated, since the runner has
    already marked its line.

    .PARAMETER Line
    The check's output, line by line.

    .PARAMETER Directory
    The folder the check ran in, which relative paths are read against first.

    .PARAMETER Root
    The repo's root.

    .PARAMETER TrackedFile
    The repo's tracked files, repo-relative, for a file the output names without its folder.
    #>
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()] [string[]]$Line = @(),
        [string]$Directory = (Get-Location).Path,
        [Parameter(Mandatory)] [string]$Root,
        [string[]]$TrackedFile = @()
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $file = $null
    $heading = $null
    $detail = $null
    $section = $null
    foreach ($raw in $Line) {
        $text = (ConvertTo-PlainText -Text $raw).TrimEnd()
        if (-not $text) {
            continue
        }
        $found = $null
        if ($text -match '^::(?<sev>error|warning|notice)\s*(?<props>.*?)::(?<msg>.*)$') {
            $property = @{}
            foreach ($pair in ($Matches.props -split ',')) {
                $key, $value = $pair -split '=', 2
                if ($key -and $null -ne $value) {
                    $property[$key.Trim()] = ConvertFrom-CommandValue -Value $value
                }
            }
            if ($property.file) {
                $found = @{ File = $property.file; Line = $property.line; Column = $property.col; Severity = $Matches.sev; Rule = $property.title; Message = (ConvertFrom-CommandValue -Value $Matches.msg); Annotated = $true }
            }
        } elseif ($text -match '\u203A\s+(?<file>[^\s\u203A]+?):(?<line>\d+):(?<col>\d+)\s+\u203A\s+(?<msg>.+?)[\s\u2500]*$') {
            $found = @{ File = $Matches.file; Line = $Matches.line; Column = $Matches.col; Message = $Matches.msg }
        } elseif ($text -match '^\s*\d+\)\s+(?<file>[^\s()]+\.[A-Za-z0-9]+)(?:\s+\((?<rule>[^)]*)\))?$') {
            $found = @{ File = $Matches.file; Rule = $Matches.rule; Message = 'The code style fixer would change this file.' }
        } elseif ($text -match '^\s*\d+\)\s+(?<head>\S.*)$') {
            $heading = $Matches.head
            $detail = ''
            continue
        } elseif ($text -match '^\s*FAIL\s+(?<head>\S.*)$') {
            $heading = $Matches.head
            $detail = ''
            continue
        } elseif ($text -match '^(?<head>(Unused|Unlisted|Unresolved|Duplicate)\b[^(]*?)\s*\(\d+\)$') {
            $section = $Matches.head
            continue
        } elseif ($text -match '^\s*\u276F\s+(?<file>\S+?):(?<line>\d+):(?<col>\d+)$') {
            $found = @{ File = $Matches.file; Line = $Matches.line; Column = $Matches.col; Message = (@($heading, $detail) | Where-Object { $_ }) -join ': ' }
        } elseif ($text -match '^\s*(?<file>(?:[A-Za-z]:)?[^\s:()]+\.[A-Za-z0-9]+):(?<line>\d+)$') {
            $found = @{ File = $Matches.file; Line = $Matches.line; Message = (@($heading, $detail) | Where-Object { $_ }) -join ': ' }
        } elseif ($text -match '^\[warn\]\s+(?<file>(?:[A-Za-z]:)?[^\s:]+\.[A-Za-z0-9]+)$') {
            $found = @{ File = $Matches.file; Message = 'Prettier would format this file differently.' }
        } elseif ($section -and $text -match '^(?<sym>\S+)\s+(?:\S+\s+)?(?<file>(?:[A-Za-z]:)?[^\s:]+\.[A-Za-z0-9]+):(?<line>\d+):(?<col>\d+)$') {
            $found = @{ File = $Matches.file; Line = $Matches.line; Column = $Matches.col; Message = "$($section): $($Matches.sym)" }
        } elseif ($text -cmatch '^\s*(?<file>(?:[A-Za-z]:)?[^\s:()''"]+\.[A-Za-z0-9]+)[:(](?<line>\d+)(?:[:,](?<col>\d+))?\)?\s*:?\s*(?:-\s+)?(?:(?<sev>error|warning|note|info|notice|Error|Warning|Information|ParseError)(?=:|\s+\S+:|\s+MD\d):?\s*)?(?<msg>\S.*)$') {
            $message = $Matches.msg -replace '\s+\[[^\]]+\.(cs|vb|fs)proj\]$', ''
            $found = @{ File = $Matches.file; Line = $Matches.line; Column = $Matches.col; Severity = $Matches.sev; Message = $message }
        } elseif ($text -match '^(?<file>(?:[A-Za-z]:/|/|\./|[\w.@-]+/)\S*\.[A-Za-z0-9]+)$') {
            $file = $Matches.file
            continue
        } elseif ($file -and $text -match '^\s+(?<line>\d+):(?<col>\d+)\s+(?<sev>error|warning|\u2716|\u26A0)\s+(?<msg>.+?)(?:\s{2,}(?<rule>[\w@/.-]+))?$') {
            $severity = if ($Matches.sev -in 'warning', [string][char]0x26A0) { 'warning' } else { 'error' }
            $found = @{ File = $file; Line = $Matches.line; Column = $Matches.col; Severity = $severity; Rule = $Matches.rule; Message = $Matches.msg }
        } elseif ($heading -and $detail -eq '' -and $text -match '^\s*(?<msg>\S.*)$') {
            $detail = $Matches.msg
            continue
        }
        if (-not $found) {
            continue
        }
        $path = Resolve-CiPath -Path $found.File -Directory $Directory -Root $Root -TrackedFile $TrackedFile -Trust:([bool]$found.Annotated)
        if (-not $path) {
            continue
        }
        $severity = switch -Regex ($found.Severity) {
            '^warn' { 'warning'; break }
            '^(note|info|notice)$' { 'notice'; break }
            default { 'error' }
        }
        $message = ([string]$found.Message).Trim()
        if (-not $message) {
            $message = 'Named in the output.'
        }
        if ($message.Length -gt 500) {
            $message = $message.Substring(0, 500) + '...'
        }
        $finding = [pscustomobject][ordered]@{
            file      = $path
            line      = if ($found.Line) { [int]$found.Line } else { $null }
            column    = if ($found.Column -and [int]$found.Column -gt 0) { [int]$found.Column } else { $null }
            severity  = $severity
            rule      = if ($found.Rule) { [string]$found.Rule } else { $null }
            message   = $message
            annotated = [bool]$found.Annotated
        }
        if ($seen.Add("$($finding.file)|$($finding.line)|$($finding.column)|$($finding.message)")) {
            $finding
        }
    }
}

function Get-CiExcerpt {
    <#
    .SYNOPSIS
    A check's last lines of output, without colour codes, log groups or trailing blank lines.
    #>
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()] [string[]]$Line = @(),
        [int]$Count = 60
    )
    $clean = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in $Line) {
        $text = (ConvertTo-PlainText -Text $raw).TrimEnd()
        if ($text -notmatch '^::(group|endgroup)') {
            $clean.Add($text)
        }
    }
    while ($clean.Count -and -not $clean[$clean.Count - 1]) {
        $clean.RemoveAt($clean.Count - 1)
    }
    if ($clean.Count -gt $Count) {
        return , $clean.GetRange($clean.Count - $Count, $Count).ToArray()
    }
    , $clean.ToArray()
}

function ConvertTo-MarkdownCell {
    <#
    .SYNOPSIS
    Text fit for one cell of a Markdown table: one line, its pipes escaped.
    #>
    [OutputType([string])]
    param([AllowEmptyString()] [string]$Text, [int]$Length = 300)
    $cell = ($Text -replace '\r?\n', ' ' -replace '\|', '\|').Trim()
    if ($cell.Length -gt $Length) {
        $cell = $cell.Substring(0, $Length) + '...'
    }
    $cell
}

function ConvertTo-CiCheckMarkdown {
    <#
    .SYNOPSIS
    A failed check as Markdown: what ran, where, its findings as a table, and its last lines.

    .PARAMETER Check
    The check as Invoke-CiCheck.ps1 records it.

    .PARAMETER Heading
    The heading's level, as a run of #.

    .PARAMETER MaxFinding
    How many findings the table lists; the rest are counted.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object]$Check,
        [string]$Heading = '###',
        [int]$MaxFinding = 50
    )
    $text = [System.Text.StringBuilder]::new()
    $where = if ($Check.directory -and $Check.directory -ne '.') { " in ``$($Check.directory)``" } else { '' }
    [void]$text.AppendLine("$Heading Failed: $($Check.name)")
    [void]$text.AppendLine()
    [void]$text.AppendLine("``$(ConvertTo-MarkdownCell -Text $Check.command -Length 400)``$where exited $($Check.exitCode) after $($Check.seconds) s.")
    [void]$text.AppendLine()
    if ($Check.variables) {
        $short = [System.Collections.Generic.List[string]]::new()
        $long = [System.Collections.Generic.List[object]]::new()
        # A hashtable from Invoke-CiCheck.ps1, an object once read back from JSON.
        $pairs = if ($Check.variables -is [System.Collections.IDictionary]) {
            $Check.variables.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = $_.Key; Value = $_.Value } }
        } else {
            $Check.variables.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } }
        }
        foreach ($property in $pairs) {
            if ("$($property.Value)" -match '\n') {
                $long.Add($property)
            } else {
                $short.Add("``$($property.Name)=$(ConvertTo-MarkdownCell -Text ([string]$property.Value) -Length 200)``")
            }
        }
        if ($short.Count) {
            [void]$text.AppendLine("With $($short -join ', ').")
            [void]$text.AppendLine()
        }
        foreach ($property in $long) {
            [void]$text.AppendLine("``$($property.Name)`` is:")
            [void]$text.AppendLine()
            [void]$text.AppendLine('````sh')
            [void]$text.AppendLine(([string]$property.Value).TrimEnd())
            [void]$text.AppendLine('````')
            [void]$text.AppendLine()
        }
    }
    $findings = @($Check.findings)
    if ($findings.Count) {
        [void]$text.AppendLine('| Where | Problem |')
        [void]$text.AppendLine('| --- | --- |')
        foreach ($finding in ($findings | Select-Object -First $MaxFinding)) {
            $at = $finding.file
            if ($finding.line) {
                $at += ":$($finding.line)"
                if ($finding.column) {
                    $at += ":$($finding.column)"
                }
            }
            $problem = if ($finding.rule) { "$($finding.rule): $($finding.message)" } else { $finding.message }
            if ($finding.severity -ne 'error') {
                $problem = "($($finding.severity)) $problem"
            }
            [void]$text.AppendLine("| ``$at`` | $(ConvertTo-MarkdownCell -Text $problem) |")
        }
        if ($findings.Count -gt $MaxFinding) {
            [void]$text.AppendLine()
            [void]$text.AppendLine("And $($findings.Count - $MaxFinding) more, in the report's JSON.")
        }
        [void]$text.AppendLine()
    }
    $excerpt = @($Check.excerpt)
    if ($excerpt.Count) {
        $label = if ($findings.Count) { 'Last lines of its output' } else { 'Its last lines of output, which name no file' }
        [void]$text.AppendLine("<details><summary>$label</summary>")
        [void]$text.AppendLine()
        [void]$text.AppendLine('````text')
        foreach ($line in $excerpt) {
            [void]$text.AppendLine($line)
        }
        [void]$text.AppendLine('````')
        [void]$text.AppendLine()
        [void]$text.AppendLine('</details>')
        [void]$text.AppendLine()
    }
    $text.ToString()
}

function ConvertTo-GlobRegex {
    <#
    .SYNOPSIS
    A regular expression for a glob over repo paths: ** any folders, * and ? within one name.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$Glob)
    $pattern = ($Glob.Trim().Trim("'", '"')) -replace '^\./', ''
    $regex = [System.Text.StringBuilder]::new('^')
    for ($i = 0; $i -lt $pattern.Length; $i++) {
        $char = $pattern[$i]
        if ($char -eq '*') {
            if ($i + 1 -lt $pattern.Length -and $pattern[$i + 1] -eq '*') {
                $i++
                if ($i + 1 -lt $pattern.Length -and $pattern[$i + 1] -eq '/') {
                    $i++
                    [void]$regex.Append('(?:.*/)?')
                } else {
                    [void]$regex.Append('.*')
                }
            } else {
                [void]$regex.Append('[^/]*')
            }
        } elseif ($char -eq '?') {
            [void]$regex.Append('[^/]')
        } else {
            [void]$regex.Append([regex]::Escape([string]$char))
        }
    }
    [void]$regex.Append('$')
    $regex.ToString()
}

function Test-GlobMatch {
    <#
    .SYNOPSIS
    Whether a repo path matches a list of globs: one plain glob matches it and no !glob does.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [AllowEmptyCollection()] [string[]]$Glob = @()
    )
    $hit = $false
    foreach ($item in $Glob) {
        if ($item.StartsWith('!')) {
            if ($Path -match (ConvertTo-GlobRegex -Glob $item.Substring(1))) {
                return $false
            }
        } elseif (-not $hit -and $Path -match (ConvertTo-GlobRegex -Glob $item)) {
            $hit = $true
        }
    }
    $hit
}

function Split-GlobList {
    <#
    .SYNOPSIS
    The globs in a space- or line-separated list, any quotes around each taken off.
    #>
    [OutputType([string[]])]
    param([AllowEmptyString()] [string]$Text)
    , @(($Text -split '\s+') | ForEach-Object { $_.Trim("'", '"') } | Where-Object { $_ })
}

Export-ModuleMember -Function ConvertTo-PlainText, ConvertTo-CommandValue, Resolve-CiPath, Get-CiFinding, Get-CiExcerpt, ConvertTo-MarkdownCell, ConvertTo-CiCheckMarkdown, ConvertTo-GlobRegex, Test-GlobMatch, Split-GlobList
