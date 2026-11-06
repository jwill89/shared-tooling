#Requires -Version 7.4
<#
SharedDeploy: the helpers and flow pieces the deploy scripts under C:\Web Projects copied
into each other, gathered in one module. Each function's help names the scripts it came
from. Nothing here names a host, user, key or address: those stay in each project's
git-ignored deploy.config.ps1.

The shape of every deploy (decided 2026-11-05): everything it needs packed into ONE
archive, one upload, then one remote run that unpacks it to a staging folder, checks its
SHA-256 and file count, and only then runs the steps. All of it rides ONE SSH connection,
held open by a background plink with PuTTY's connection sharing (-share), and reopened if
it drops, so the droplet's `ufw limit ssh` (six in 30 seconds) sees one connection a deploy.
pscp is not used: uploads and downloads stream through plink.
#>

$ErrorActionPreference = 'Stop'
# Every native call here checks $LASTEXITCODE itself, with its own message. A profile that
# turns this on would make the call throw first, before the message.
$PSNativeCommandUseErrorActionPreference = $false

# The droplet runs `ufw limit ssh`, which refuses an address after six connections in 30
# seconds. A retry waits this long first, so the window has passed.
$script:RetryDelaySeconds = 35
# What plink prints when the connection failed, as opposed to the remote command.
$script:ConnectionFailurePattern = 'Network error|Connection (timed out|refused|reset|abandoned)|Unable to (open connection|authenticate)|Server unexpectedly closed'
# The connection the remote functions use when they are not handed one.
$script:DefaultConnection = $null
# Database snapshots kept on the host, and pulled copies kept here (decided 2026-11-05).
$script:SnapshotKeep = 3
# Every plink holding a shared connection open, so none outlives the session.
$script:Holders = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

# Two Windows calls the connection holder needs. While it starts, PowerShell's own standard
# handles are made non-inheritable, so the long-lived holder does not keep the deploy
# script's output pipe open (anything reading that output would wait for it). And it joins
# a job object that ends it when this PowerShell process ends, however that happens.
if ($IsWindows -and -not ('SharedDeploy.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace SharedDeploy
{
    public static class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimit
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimit
        {
            public BasicLimit BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetHandleInformation(IntPtr hObject, out uint lpdwFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, ref ExtendedLimit info, int length);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        const uint HandleFlagInherit = 1;
        const int JobObjectExtendedLimitInformation = 9;
        const uint KillOnJobClose = 0x2000;
        static readonly int[] Std = { -10, -11, -12 };
        static IntPtr job = IntPtr.Zero;

        // Clears the inherit flag on stdin, stdout and stderr; returns which had it.
        public static bool[] HideStandardHandles()
        {
            bool[] had = new bool[Std.Length];
            for (int i = 0; i < Std.Length; i++)
            {
                IntPtr handle = GetStdHandle(Std[i]);
                uint flags;
                if (handle != IntPtr.Zero && handle != new IntPtr(-1) && GetHandleInformation(handle, out flags) && (flags & HandleFlagInherit) != 0)
                {
                    had[i] = SetHandleInformation(handle, HandleFlagInherit, 0);
                }
            }
            return had;
        }

        public static void RestoreStandardHandles(bool[] had)
        {
            for (int i = 0; i < Std.Length && i < had.Length; i++)
            {
                if (had[i]) { SetHandleInformation(GetStdHandle(Std[i]), HandleFlagInherit, HandleFlagInherit); }
            }
        }

        // Puts a process in a job that ends it when this process ends.
        public static bool EndWithThisProcess(IntPtr process)
        {
            if (job == IntPtr.Zero)
            {
                IntPtr created = CreateJobObject(IntPtr.Zero, null);
                if (created == IntPtr.Zero) { return false; }
                ExtendedLimit info = new ExtendedLimit();
                info.BasicLimitInformation.LimitFlags = KillOnJobClose;
                if (!SetInformationJobObject(created, JobObjectExtendedLimitInformation, ref info, Marshal.SizeOf(typeof(ExtendedLimit)))) { return false; }
                job = created;
            }
            return AssignProcessToJobObject(job, process);
        }
    }
}
'@
}

function Stop-AllHolder {
    <#
    .SYNOPSIS
    Ends every connection holder this module started (the fallback when a script did not close its connection).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    foreach ($holder in @($script:Holders)) {
        try {
            if (-not $holder.HasExited -and $PSCmdlet.ShouldProcess("plink $($holder.Id)", 'Stop the shared SSH connection')) { $holder.Kill() }
        } catch [System.InvalidOperationException] {
            Write-Verbose 'A connection holder had already exited.'
        }
    }
    $script:Holders.Clear()
}

# If a script ends without Close-DeployConnection, PowerShell's exit still ends the holder.
$script:ExitingJob = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action { Stop-AllHolder -Confirm:$false }
$ExecutionContext.SessionState.Module.OnRemove = {
    Stop-AllHolder -Confirm:$false
    $subscriber = Get-EventSubscriber -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -ErrorAction SilentlyContinue |
        Where-Object { $_.Action -eq $script:ExitingJob }
    if ($subscriber) { Unregister-Event -SubscriptionId $subscriber.SubscriptionId -ErrorAction SilentlyContinue }
}

#region Private helpers

function Get-ActiveConnection {
    <#
    .SYNOPSIS
    Returns the connection to use: the one passed, else the one Open-DeployConnection or Resolve-DeployConnection stored.
    #>
    param([object]$Connection)
    if ($Connection) { return $Connection }
    if ($script:DefaultConnection) { return $script:DefaultConnection }
    throw 'No deploy connection. Call Open-DeployConnection first, or pass -Connection.'
}

function ConvertTo-ShellLiteral {
    <#
    .SYNOPSIS
    Quotes a value for a POSIX shell: single quotes, with any single quote inside escaped.
    #>
    param([AllowNull()] [AllowEmptyString()] [string]$Value)
    "'" + ([string]$Value).Replace("'", "'\''") + "'"
}

function Join-ShellScript {
    <#
    .SYNOPSIS
    Builds a shell block: set -e, name='value' lines, then the body parts; a ( ... ) subshell unless -Outer.
    #>
    param(
        [System.Collections.Specialized.OrderedDictionary]$Variable,
        [string[]]$Body,
        [switch]$Outer
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not $Outer) { $lines.Add('(') }
    $lines.Add('set -e')
    foreach ($name in $Variable.Keys) {
        $lines.Add("$name=$(ConvertTo-ShellLiteral -Value $Variable[$name])")
    }
    foreach ($part in $Body) {
        if ($part) { $lines.Add($part) }
    }
    if (-not $Outer) { $lines.Add(')') }
    ($lines -join "`n") -replace "`r", ''
}

function Get-PathKey {
    <#
    .SYNOPSIS
    A short, stable name for a remote path, used to name its staging folder and marker files.
    #>
    param([string]$Value)
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Value))
    ([System.Convert]::ToHexString($bytes)).Substring(0, 16).ToLowerInvariant()
}

function Assert-SafeRemoteName {
    <#
    .SYNOPSIS
    Throws unless a name is one the remote steps can remove, rename and list safely.
    #>
    param([string]$Value, [string]$What, [switch]$AllowSlash)
    $pattern = if ($AllowSlash) { '^[A-Za-z0-9._/@-]+$' } else { '^[A-Za-z0-9._@-]+$' }
    $parts = $Value -split '/'
    if (-not $Value -or $Value -notmatch $pattern -or $Value.StartsWith('/') -or ($parts | Where-Object { $_ -in '', '.', '..' })) {
        throw "$What '$Value' must be a plain relative name (letters, digits, . _ - @$(if ($AllowSlash) { ' and /' })), not empty, '.' or '..'."
    }
}

function Assert-RemotePath {
    <#
    .SYNOPSIS
    Throws unless a remote path is non-empty, on one line, and not the filesystem root.
    #>
    param([string]$Value, [string]$What)
    if (-not $Value -or $Value -match '[\r\n]' -or $Value.TrimEnd('/') -eq '') {
        throw "$What '$Value' must be a path on one line, and not the filesystem root."
    }
}

function Split-Owner {
    <#
    .SYNOPSIS
    Splits 'user' or 'user:group' into the two; a bare user also names the group.
    #>
    param([string]$Owner)
    if (-not $Owner) { return @('', '') }
    $user, $group = $Owner -split ':', 2
    if (-not $group) { $group = $user }
    foreach ($name in $user, $group) {
        if ($name -notmatch '^[A-Za-z0-9_.][A-Za-z0-9_.-]*$') { throw "Owner '$Owner' is not a user or user:group." }
    }
    @($user, $group)
}

function Get-AssemblyVersion {
    <#
    .SYNOPSIS
    The first "AssemblyVersion" value in a Dalamud manifest or repo index, or empty.
    #>
    param([string]$Text)
    $match = [regex]::Match([string]$Text, '"AssemblyVersion"\s*:\s*"([^"]+)"')
    if ($match.Success) { $match.Groups[1].Value } else { '' }
}

function Test-FileInUse {
    <#
    .SYNOPSIS
    True when a local file exists and another process holds it open (a running dev server).
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $stream.Dispose()
        $false
    } catch {
        $true
    }
}

function Join-ProcessArgument {
    <#
    .SYNOPSIS
    Joins arguments into one command line for Start-Process, quoting those that need it.
    #>
    param([string[]]$Argument)
    $quoted = foreach ($item in $Argument) {
        if ($item -eq '') {
            '""'
        } elseif ($item -notmatch '[\s"]') {
            $item
        } else {
            '"' + (($item -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
        }
    }
    $quoted -join ' '
}

function Write-RemoteLine {
    <#
    .SYNOPSIS
    Prints a remote command's output lines, indented, skipping blank ones.
    #>
    param([string[]]$Line)
    foreach ($item in $Line) {
        if ("$item".Trim()) { Write-Host "    $item" }
    }
}

function Invoke-PlinkOnce {
    <#
    .SYNOPSIS
    Runs one remote command through plink -share, riding the held connection, and returns its exit code and output lines.
    #>
    param([object]$Connection, [string]$Script)
    $plinkArgs = @('-batch', '-share') + $Connection.HostKeyArgs + @('-i', $Connection.KeyPath, $Connection.Target, $Script)
    $lines = @(& $Connection.Plink @plinkArgs 2>&1 | ForEach-Object { "$_" })
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
}

function Test-UpstreamExist {
    <#
    .SYNOPSIS
    True when a shared connection to the target is up (plink -shareexists, which opens no connection of its own).
    #>
    param([object]$Connection)
    $null = & $Connection.Plink -batch -share -shareexists $Connection.Target 2>&1
    $LASTEXITCODE -eq 0
}

function Test-SharedUpstream {
    <#
    .SYNOPSIS
    True while this connection's holder process is still running.
    #>
    param([object]$Connection)
    [bool]($Connection.Holder -and -not $Connection.Holder.HasExited)
}

function Disconnect-SharedUpstream {
    <#
    .SYNOPSIS
    Ends this connection's holder, if any, and removes its log files.
    #>
    param([object]$Connection)
    $holder = $Connection.Holder
    if ($holder) {
        try {
            if (-not $holder.HasExited) {
                $holder.Kill()
                $null = $holder.WaitForExit(5000)
            }
        } catch [System.InvalidOperationException] {
            Write-Verbose 'The connection holder had already exited.'
        }
        $null = $script:Holders.Remove($holder)
    }
    foreach ($file in @($Connection.HolderLog)) {
        if ($file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
    $Connection.Holder = $null
    $Connection.HolderLog = @()
}

function Connect-UpstreamOnce {
    <#
    .SYNOPSIS
    Starts one hidden plink -share -N holder and waits until its shared connection is up, or it exits, or the time runs out.
    #>
    param([object]$Connection)
    $temp = [System.IO.Path]::GetTempPath()
    $errFile = Join-Path -Path $temp -ChildPath ('plink-holder-err-{0}.log' -f [guid]::NewGuid())
    $outFile = Join-Path -Path $temp -ChildPath ('plink-holder-out-{0}.log' -f [guid]::NewGuid())
    $inFile = Join-Path -Path $temp -ChildPath ('plink-holder-in-{0}' -f [guid]::NewGuid())
    [System.IO.File]::WriteAllBytes($inFile, [byte[]]::new(0))
    $logs = @($errFile, $outFile, $inFile)
    $holderArgs = @('-batch', '-share', '-N') + $Connection.HostKeyArgs + @('-i', $Connection.KeyPath, $Connection.Target)
    $hidden = if ($IsWindows) { [SharedDeploy.NativeMethods]::HideStandardHandles() } else { $null }
    try {
        $holder = Start-Process -FilePath $Connection.Plink -ArgumentList (Join-ProcessArgument -Argument $holderArgs) -WindowStyle Hidden -PassThru `
            -RedirectStandardInput $inFile -RedirectStandardError $errFile -RedirectStandardOutput $outFile
    } finally {
        if ($hidden) { [SharedDeploy.NativeMethods]::RestoreStandardHandles($hidden) }
    }
    if ($IsWindows -and -not $holder.HasExited) { $null = [SharedDeploy.NativeMethods]::EndWithThisProcess($holder.Handle) }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $Connection.OpenTimeoutSeconds) {
        if ($holder.HasExited) {
            $message = "$(Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)".Trim()
            if (-not $message) { $message = "plink exited with code $($holder.ExitCode)." }
            Remove-Item -LiteralPath $logs -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Ok = $false; Refused = ($message -match $script:ConnectionFailurePattern); Message = $message }
        }
        if (Test-UpstreamExist -Connection $Connection) {
            $Connection.Holder = $holder
            $Connection.HolderLog = $logs
            $script:Holders.Add($holder)
            return [pscustomobject]@{ Ok = $true; Refused = $false; Message = '' }
        }
        Start-Sleep -Milliseconds 250
    }
    try { $holder.Kill() } catch [System.InvalidOperationException] { Write-Verbose 'The connection holder had already exited.' }
    Remove-Item -LiteralPath $logs -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ Ok = $false; Refused = $false; Message = "No shared connection after $($Connection.OpenTimeoutSeconds)s." }
}

function Connect-SharedUpstream {
    <#
    .SYNOPSIS
    Opens (or reopens) the held connection: at once, and only if that is refused (the ufw window) once more after 35 seconds.
    #>
    param([object]$Connection, [switch]$Reconnect)
    Disconnect-SharedUpstream -Connection $Connection
    $result = Connect-UpstreamOnce -Connection $Connection
    if (-not $result.Ok -and $result.Refused) {
        Write-Host "    The connection was refused - likely the SSH rate limit (ufw limit ssh). Waiting $($script:RetryDelaySeconds)s, then trying once more..." -ForegroundColor Yellow
        Start-Sleep -Seconds $script:RetryDelaySeconds
        $result = Connect-UpstreamOnce -Connection $Connection
    }
    if (-not $result.Ok) {
        $Connection.Opened = $false
        throw @"
Could not open the SSH connection to $($Connection.Target): $($result.Message)
  - A key with a passphrase must be loaded into Pageant first: pageant.exe "$($Connection.KeyPath)"
  - The first connection from PuTTY needs the host key cached once: plink -i "$($Connection.KeyPath)" $($Connection.Target)
"@
    }
    $Connection.Opened = $true
    if ($Reconnect) { Write-Host "    Reconnected to $($Connection.Target) (one new SSH connection)." -ForegroundColor Yellow }
}

function Confirm-SharedUpstream {
    <#
    .SYNOPSIS
    Before a remote step: if the held connection has closed, open a new one and say so.
    #>
    param([object]$Connection)
    if ($Connection.Opened -and -not (Test-SharedUpstream -Connection $Connection)) {
        Write-Host '    The shared SSH connection had closed.' -ForegroundColor Yellow
        Connect-SharedUpstream -Connection $Connection -Reconnect
    }
}

function Test-ConnectionDropped {
    <#
    .SYNOPSIS
    True when a failed remote step looks like a lost connection rather than a failing command.
    #>
    param([object]$Connection, [string[]]$Output)
    (($Output -join "`n") -match $script:ConnectionFailurePattern) -or ($Connection.Opened -and -not (Test-SharedUpstream -Connection $Connection))
}

function Resume-DeployConnection {
    <#
    .SYNOPSIS
    After a dropped step: reconnect at once when the connection is held, else wait out the rate-limit window.
    #>
    param([object]$Connection)
    if ($Connection.Opened) {
        Write-Host '    The connection dropped; reconnecting, then retrying the step once...' -ForegroundColor Yellow
        Connect-SharedUpstream -Connection $Connection -Reconnect
    } else {
        Write-Host "    Connection failed - likely the SSH rate limit (ufw limit ssh). Waiting $($script:RetryDelaySeconds)s, then retrying once..." -ForegroundColor Yellow
        Start-Sleep -Seconds $script:RetryDelaySeconds
    }
}

function Invoke-RemoteCore {
    <#
    .SYNOPSIS
    Runs a remote command on the held connection; if the connection dropped, reconnects and runs it once more.
    #>
    param([object]$Connection, [string]$Script, [switch]$NoRetry, [switch]$Echo)
    $Script = $Script -replace "`r", ''
    Confirm-SharedUpstream -Connection $Connection
    $result = Invoke-PlinkOnce -Connection $Connection -Script $Script
    if ($Echo) { Write-RemoteLine -Line $result.Lines }
    if ($result.ExitCode -ne 0 -and -not $NoRetry -and (Test-ConnectionDropped -Connection $Connection -Output $result.Lines)) {
        Resume-DeployConnection -Connection $Connection
        $result = Invoke-PlinkOnce -Connection $Connection -Script $Script
        if ($Echo) { Write-RemoteLine -Line $result.Lines }
    }
    $result
}

function Invoke-RemoteFlow {
    <#
    .SYNOPSIS
    Runs one of the flow scripts below: its output printed, a throw with the given message on failure.
    #>
    param([object]$Connection, [string]$Script, [switch]$NoRetry, [string]$FailureMessage)
    $result = Invoke-RemoteCore -Connection (Get-ActiveConnection -Connection $Connection) -Script $Script -NoRetry:$NoRetry -Echo
    if ($result.ExitCode -ne 0) { throw "$FailureMessage (exit $($result.ExitCode))" }
}

function Invoke-PlinkStream {
    <#
    .SYNOPSIS
    One remote command through plink -share with a local file as its stdin (an upload) or its stdout (a download), byte for byte, with an elapsed-time indicator and a time limit.
    #>
    param(
        [object]$Connection,
        [string]$Command,
        [string]$InputFile,
        [string]$OutputFile,
        [string]$Activity,
        [string]$Status,
        [int]$TimeoutSeconds
    )
    $temp = [System.IO.Path]::GetTempPath()
    $errFile = Join-Path -Path $temp -ChildPath ('plink-err-{0}.log' -f [guid]::NewGuid())
    $scratch = [System.Collections.Generic.List[string]]::new()
    $scratch.Add($errFile)
    if (-not $InputFile) {
        # Never the console: plink would read keystrokes and send them to the host.
        $InputFile = Join-Path -Path $temp -ChildPath ('plink-in-{0}' -f [guid]::NewGuid())
        [System.IO.File]::WriteAllBytes($InputFile, [byte[]]::new(0))
        $scratch.Add($InputFile)
    }
    if (-not $OutputFile) {
        $OutputFile = Join-Path -Path $temp -ChildPath ('plink-out-{0}.log' -f [guid]::NewGuid())
        $scratch.Add($OutputFile)
    }
    $plinkArgs = @('-batch', '-share') + $Connection.HostKeyArgs + @('-i', $Connection.KeyPath, $Connection.Target, $Command)
    $process = Start-Process -FilePath $Connection.Plink -NoNewWindow -PassThru -ArgumentList (Join-ProcessArgument -Argument $plinkArgs) `
        -RedirectStandardInput $InputFile -RedirectStandardOutput $OutputFile -RedirectStandardError $errFile
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $killed = $false
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 250
        Write-Progress -Activity $Activity -Status ("{0} - {1:mm\:ss} elapsed" -f $Status, $watch.Elapsed)
        if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
            # plink may finish between the check and the kill; that race is harmless.
            try { $process.Kill() } catch [System.InvalidOperationException] { Write-Verbose 'plink had already exited.' }
            $killed = $true
            break
        }
    }
    $process.WaitForExit()
    $watch.Stop()
    Write-Progress -Activity $Activity -Completed
    $code = $process.ExitCode
    $err = if ($killed) {
        "The transfer exceeded ${TimeoutSeconds}s and was stopped."
    } elseif ($code -ne 0) {
        "$(Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)".Trim()
    } else {
        ''
    }
    Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ Ok = ($code -eq 0 -and -not $killed); Err = $err; Elapsed = $watch.Elapsed }
}

function Invoke-StreamWithRetry {
    <#
    .SYNOPSIS
    Invoke-PlinkStream on the held connection; if the connection dropped, reconnects and runs it once more.
    #>
    param([hashtable]$Stream, [switch]$NoRetry)
    $connection = $Stream.Connection
    Confirm-SharedUpstream -Connection $connection
    $result = Invoke-PlinkStream @Stream
    if (-not $result.Ok -and -not $NoRetry -and (Test-ConnectionDropped -Connection $connection -Output $result.Err)) {
        Resume-DeployConnection -Connection $connection
        $result = Invoke-PlinkStream @Stream
    }
    $result
}

function ConvertTo-HealthScript {
    <#
    .SYNOPSIS
    Shell lines that set $health from a URL template whose {NAME} parts are read from the env file on the host.
    #>
    param([string]$Template, [System.Collections.IDictionary]$Default, [string]$EnvFile)
    if (-not $Template) { return "health=''" }
    $parts = [regex]::Split($Template, '\{([A-Za-z_][A-Za-z0-9_]*)\}')
    if ($parts.Count -gt 1 -and -not $EnvFile) { throw "-HealthUrl '$Template' names settings in braces, so -EnvFile must say where they are." }
    $lines = [System.Collections.Generic.List[string]]::new()
    $expression = ''
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i % 2 -eq 0) {
            if ($parts[$i]) { $expression += ConvertTo-ShellLiteral -Value $parts[$i] }
            continue
        }
        $name = $parts[$i]
        $var = "health_part$i"
        $lines.Add(('{0}=$(sed -n ''s/^{1}=//p'' "$env_file" 2>/dev/null | tail -n 1 | sed -e ''s/^"//'' -e ''s/"$//'')' -f $var, $name))
        if ($Default -and $Default.Contains($name)) {
            $lines.Add(('[ -n "${0}" ] || {0}={1}' -f $var, (ConvertTo-ShellLiteral -Value ([string]$Default[$name]))))
        } else {
            $lines.Add(('if [ -z "${0}" ]; then echo "{1} is not set in $env_file, so the health URL cannot be built; nothing was changed." >&2; exit 3; fi' -f $var, $name))
        }
        $expression += '"$' + $var + '"'
    }
    $lines.Add("health=$expression")
    $lines -join "`n"
}

function Get-DirectorySwapStep {
    <#
    .SYNOPSIS
    The bundle step that swaps a folder from the unpacked upload into place; shared by Switch-RemoteDirectory and Publish-PluginRepository.
    #>
    param(
        [string]$Live,
        [string]$Item,
        [System.Collections.IDictionary]$File,
        [string]$Owner,
        [string]$BeforeSwap,
        [string]$AfterSwap,
        [switch]$NoBackup,
        [System.Collections.Specialized.OrderedDictionary]$ExtraVariable,
        [string]$Check
    )
    $Live = $Live.TrimEnd('/')
    Assert-RemotePath -Value $Live -What 'Live'
    if (-not $Item) { $Item = Split-Path -Path $Live -Leaf }
    Assert-SafeRemoteName -Value $Item -What 'Item' -AllowSlash
    $user, $group = Split-Owner -Owner $Owner
    $variable = [ordered]@{
        live      = $Live
        item      = $Item
        owner     = $user
        group     = $group
        no_backup = if ($NoBackup) { '1' } else { '' }
    }
    if ($ExtraVariable) {
        foreach ($name in $ExtraVariable.Keys) { $variable[$name] = $ExtraVariable[$name] }
    }
    $begin = @'
old="$live.old"
new="$live.new"
src="$bundle/$item"
if [ ! -d "$src" ]; then echo "The upload has no folder $item." >&2; exit 3; fi
# A run cut off between the two renames below left the live folder aside; put it back first.
if [ ! -e "$live" ] && [ -d "$old" ]; then mv "$old" "$live"; fi
'@
    $stage = @'
mkdir -p "$(dirname "$live")"
rm -rf "$new"
mv "$src" "$new"
if [ -n "$owner" ]; then chown -R "$owner:$group" "$new"; fi
'@
    $swap = @'
rm -rf "$old"
if [ -d "$live" ]; then mv "$live" "$old"; fi
mv "$new" "$live" || { if [ -d "$old" ]; then mv "$old" "$live"; fi; exit 4; }
undo() {
  rc=$?
  echo "A step after the swap failed (exit $rc); putting the previous folder back." >&2
  rm -rf "$live.failed"
  mv "$live" "$live.failed"
  if [ -d "$old" ]; then mv "$old" "$live"; fi
  rm -rf "$live.failed"
'@
    $undoEnd = @'
  exit "$rc"
}
trap undo EXIT
'@
    $end = @'
trap - EXIT
if [ -n "$no_backup" ]; then rm -rf "$old"; fi
echo "Swapped the new folder into $live."
'@
    $undoFiles = [System.Collections.Generic.List[string]]::new()
    $moveFiles = [System.Collections.Generic.List[string]]::new()
    $dropOld = [System.Collections.Generic.List[string]]::new()
    foreach ($from in $File.Keys) {
        Assert-SafeRemoteName -Value $from -What 'File' -AllowSlash
        Assert-RemotePath -Value ([string]$File[$from]) -What 'File destination'
        $source = '"$bundle"/' + (ConvertTo-ShellLiteral -Value $from)
        $to = ConvertTo-ShellLiteral -Value ([string]$File[$from])
        $undoFiles.Add(('  if [ -f {0}.old ]; then mv -f {0}.old {0}; fi' -f $to))
        $moveFiles.Add(('if [ -f {0} ]; then if [ -f {1} ]; then cp -p {1} {1}.old; else rm -f {1}.old; fi; cp {0} {1}.next; if [ -n "$owner" ]; then chown "$owner:$group" {1}.next; fi; mv -f {1}.next {1}; fi' -f $source, $to))
        $dropOld.Add(('if [ -n "$no_backup" ]; then rm -f {0}.old; fi' -f $to))
    }
    Join-ShellScript -Variable $variable -Body (@($begin, $Check, $stage, $BeforeSwap, $swap) + @($undoFiles) + @($undoEnd) + @($moveFiles) + @($AfterSwap) + @($end) + @($dropOld))
}

#endregion

#region Output

function Write-Step {
    <#
    .SYNOPSIS
    Prints a step heading: a blank line, then "==> <message>" in cyan.

    .DESCRIPTION
    The heading each deploy script prints before a step. Copied unchanged from Family Card
    Game, Fantasy Dossier, Fingerprint Generator, IDE Resume Site, Marxbot, Nophica, Senpan,
    Simple Image Gallery, TarotGen.io, Venue Tools and What Do I Know.

    .PARAMETER Message
    What the step does.

    .EXAMPLE
    Write-Step 'Uploading the archive...'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message
    )
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    <#
    .SYNOPSIS
    Prints an indented line in green, for a step that went well.

    .DESCRIPTION
    Copied unchanged from the same eleven scripts as Write-Step.

    .PARAMETER Message
    What went well.

    .EXAMPLE
    Write-Ok 'Upload finished.'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message
    )
    Write-Host "    $Message" -ForegroundColor Green
}

function Exit-Deploy {
    <#
    .SYNOPSIS
    Prints "ERROR: <message>" in red and ends the deploy script with exit code 1.

    .DESCRIPTION
    The scripts' Fail helper under an approved verb. The alias Fail keeps their call sites
    as they are. Like the original it ends the whole script, not just the function, so use
    it in the script itself; the module's own functions throw instead, so the caller can
    roll back first. It closes any held SSH connection before it exits. Copied from the
    same eleven scripts as Write-Step.

    .PARAMETER Message
    Why the deploy stopped, and what to do about it.

    .PARAMETER ExitCode
    The script's exit code. Every script uses 1.

    .EXAMPLE
    Fail 'Upload failed. Live site untouched.'
    #>
    [CmdletBinding()]
    [Alias('Fail')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [int]$ExitCode = 1
    )
    Write-Host "`nERROR: $Message" -ForegroundColor Red
    if ($script:DefaultConnection) { Disconnect-SharedUpstream -Connection $script:DefaultConnection }
    Stop-AllHolder -Confirm:$false
    exit $ExitCode
}

#endregion

#region Settings and tools

function Resolve-DeploySetting {
    <#
    .SYNOPSIS
    Resolves each deploy setting from its parameter, then $env:DEPLOY_*, then the git-ignored config file.

    .DESCRIPTION
    All fourteen scripts resolve their settings in this order; this is the one copy. For a
    setting named VpsHost it takes, first non-empty wins:
      1. the value passed in -Value (the script's own -VpsHost),
      2. $env:DEPLOY_VPS_HOST,
      3. $DeployVpsHost from the config file, which is dot-sourced in a scope of its own,
      4. the -Default value, if any.
    Every missing -Required setting is listed in one error, with the three places it can be
    set (Senpan's message, the most complete). The result has one property per setting.

    The SSH user is required in every config (decided 2026-11-05): VpsUser is always
    treated as required when it is asked for, and a -Default for it is refused. Fantasy
    Dossier, Fingerprint Generator, IDE Resume Site and TarotGen.io used to default it to root.

    .PARAMETER ConfigPath
    The git-ignored config file, usually (Join-Path $PSScriptRoot 'deploy.config.ps1'). It
    need not exist.

    .PARAMETER Value
    Each setting's name and the value the script was given, which may be empty.

    .PARAMETER Required
    The settings that must end up with a value.

    .PARAMETER Default
    Values for settings left empty everywhere else. Not allowed for VpsUser.

    .EXAMPLE
    $settings = Resolve-DeploySetting -ConfigPath (Join-Path $PSScriptRoot 'deploy.config.ps1') `
        -Value @{ VpsHost = $VpsHost; VpsUser = $VpsUser; KeyPath = $KeyPath; WebRoot = $WebRoot } `
        -Required VpsHost, VpsUser, KeyPath, WebRoot
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [hashtable]$Value,

        [string[]]$Required = @(),

        [hashtable]$Default = @{}
    )
    if ($Default.ContainsKey('VpsUser')) {
        throw 'VpsUser has no default: the SSH user is set in each project''s deploy.config.ps1 (decided 2026-11-05).'
    }
    $fromConfig = @{}
    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
        $found = & {
            param([string]$Path)
            . $Path
            Get-Variable -Name 'Deploy*' -Scope Local
        } $ConfigPath
        foreach ($variable in $found | Where-Object { $_ -is [psvariable] }) { $fromConfig[$variable.Name] = $variable.Value }
    }

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($Required) + @($Value.Keys | Sort-Object) + @($Default.Keys | Sort-Object)) {
        if ($name -and -not $names.Contains($name)) { $names.Add($name) }
    }
    $mustHave = @($Required) + @(if ($names.Contains('VpsUser')) { 'VpsUser' })

    $resolved = [ordered]@{}
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        $envName = 'DEPLOY_' + ($name -creplace '(?<=[a-z0-9])([A-Z])', '_$1').ToUpperInvariant()
        $candidates = @(
            $Value[$name]
            [System.Environment]::GetEnvironmentVariable($envName)
            $fromConfig["Deploy$name"]
            $Default[$name]
        )
        $resolved[$name] = $candidates | Where-Object { $_ } | Select-Object -First 1
        if ($name -in $mustHave -and -not $resolved[$name]) {
            $missing.Add("$name (-$name / `$env:$envName / `$Deploy$name)")
        }
    }

    if ($missing.Count -gt 0) {
        $leaf = if ($ConfigPath) { Split-Path -Path $ConfigPath -Leaf } else { 'deploy.config.ps1' }
        $example = $leaf -replace '\.ps1$', '.example.ps1'
        throw "Missing deploy settings:`n  - $($missing -join "`n  - ")`nSet these via -params, `$env:DEPLOY_* variables, or $leaf (copy $example)."
    }
    [pscustomobject]$resolved
}

function Resolve-PuttyTool {
    <#
    .SYNOPSIS
    Finds a PuTTY tool (plink): on PATH first, then in C:\Program Files\PuTTY.

    .DESCRIPTION
    Copied from the eleven scripts that define it (all but Kindred Nights, Home Library and
    Conlang Translator, which call plink and pscp from PATH). It throws, rather than
    exiting, when the tool is in neither place. The module itself needs only plink now.

    .PARAMETER Name
    The tool's name without .exe, such as plink.

    .EXAMPLE
    $plink = Resolve-PuttyTool 'plink'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )
    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = Join-Path -Path 'C:\Program Files\PuTTY' -ChildPath "$Name.exe"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    throw "$Name not found. Install PuTTY (winget install PuTTY.PuTTY) or add it to PATH."
}

function Resolve-TarTool {
    <#
    .SYNOPSIS
    Returns Windows' own tar (bsdtar), by its full path.

    .DESCRIPTION
    TarotGen.io's and Home Library's choice: Git's GNU tar can come first on PATH, and it
    reads "C:\..." as a remote host. Senpan and Simple Image Gallery took tar from PATH
    instead, and Conlang Translator called it bare. On a system other than Windows it falls
    back to the tar on PATH.

    .EXAMPLE
    $tar = Resolve-TarTool
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $IsWindows) {
        $command = Get-Command -Name 'tar' -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
        throw 'tar not found on PATH.'
    }
    $tar = Join-Path -Path $env:SystemRoot -ChildPath 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar)) { throw "tar.exe not found at $tar (it ships with Windows 10 1803 and later)." }
    $tar
}

function Resolve-DeployConnection {
    <#
    .SYNOPSIS
    Checks the key, finds plink, and stores the connection the remote functions use, without opening it.

    .DESCRIPTION
    Gathers what every script sets up before its first SSH call: the key file must exist
    (the eleven scripts with Resolve-PuttyTool check this), plink is found with
    Resolve-PuttyTool, the target is user@host, and What Do I Know's optional -hostkey
    pin is passed along. The result is stored as the module's default connection, so the
    remote functions need no -Connection, and returned for scripts that print
    $connection.Target or keep more than one. pscp is no longer needed: uploads and
    downloads stream through plink.

    A deploy opens the connection with Open-DeployConnection instead, which does all this
    and then holds one shared SSH connection open. Without that, each remote call still
    works but opens a connection of its own.

    Settings can be piped in from Resolve-DeploySetting.

    .PARAMETER VpsHost
    The droplet's address or host name, from the project's config.

    .PARAMETER VpsUser
    The SSH user, from the project's config.

    .PARAMETER KeyPath
    The PuTTY .ppk key. A key with a passphrase must be loaded into Pageant first, since
    plink runs with -batch.

    .PARAMETER HostKey
    Optional host key fingerprint (SHA256:...) passed as -hostkey; when empty, PuTTY's
    cached host key is used.

    .PARAMETER NoDefault
    Return the connection without storing it as the default.

    .EXAMPLE
    $connection = $settings | Resolve-DeployConnection
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$VpsHost,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$VpsUser,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$KeyPath,

        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowEmptyString()]
        [string]$HostKey,

        [switch]$NoDefault
    )
    process {
        if (-not (Test-Path -LiteralPath $KeyPath)) { throw "SSH key not found: $KeyPath" }
        $connection = [pscustomobject]@{
            PSTypeName         = 'SharedDeploy.Connection'
            VpsHost            = $VpsHost
            VpsUser            = $VpsUser
            KeyPath            = $KeyPath
            Target             = "$VpsUser@$VpsHost"
            HostKeyArgs        = [string[]]@(if ($HostKey) { '-hostkey'; $HostKey })
            Plink              = Resolve-PuttyTool -Name 'plink'
            Opened             = $false
            Holder             = $null
            HolderLog          = @()
            OpenTimeoutSeconds = 30
        }
        if (-not $NoDefault) { $script:DefaultConnection = $connection }
        $connection
    }
}

function Open-DeployConnection {
    <#
    .SYNOPSIS
    Opens the deploy's one SSH connection and holds it, as WinSCP does, so every remote step rides it.

    .DESCRIPTION
    Every deploy keeps one SSH connection open for the whole run (decided 2026-11-05). This
    resolves the connection as Resolve-DeployConnection does, then starts a hidden
    background plink -batch -share -N, which logs in and holds the connection, and waits
    until plink -share -shareexists reports it is up. Every remote command, upload and
    download then runs as plink -share, multiplexed over that connection with no new
    connection of its own, so `ufw limit ssh` sees one connection a deploy.

    Before each remote step the holder is checked; if it has exited, a new one starts (one
    new connection) and a line says it reconnected. A step that failed because the
    connection dropped is retried once after reconnecting. A reconnect is tried at once;
    only if it is refused (the ufw window) does it wait 35 seconds and try once more.

    Close it with Close-DeployConnection in a finally block or the script's trap.
    Exit-Deploy (Fail) closes it too, and PowerShell's exit is the last fallback, so no
    plink is left holding a connection.

    .PARAMETER VpsHost
    The droplet's address or host name, from the project's config.

    .PARAMETER VpsUser
    The SSH user, from the project's config.

    .PARAMETER KeyPath
    The PuTTY .ppk key. A key with a passphrase must be loaded into Pageant first.

    .PARAMETER HostKey
    Optional host key fingerprint (SHA256:...) passed as -hostkey.

    .PARAMETER TimeoutSeconds
    How long the connection may take to come up.

    .EXAMPLE
    $connection = $settings | Open-DeployConnection
    try { Write-Step "Deploying to $($connection.Target)" } finally { Close-DeployConnection }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$VpsHost,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$VpsUser,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$KeyPath,

        [Parameter(ValueFromPipelineByPropertyName)]
        [AllowEmptyString()]
        [string]$HostKey,

        [ValidateRange(1, 600)]
        [int]$TimeoutSeconds = 30
    )
    process {
        $connection = Resolve-DeployConnection -VpsHost $VpsHost -VpsUser $VpsUser -KeyPath $KeyPath -HostKey $HostKey
        $connection.OpenTimeoutSeconds = $TimeoutSeconds
        Write-Step "Opening the SSH connection to $($connection.Target)..."
        Connect-SharedUpstream -Connection $connection
        Write-Ok 'Connected; every step of this deploy shares this one connection.'
        $connection
    }
}

function Close-DeployConnection {
    <#
    .SYNOPSIS
    Ends the held SSH connection Open-DeployConnection started.

    .DESCRIPTION
    Stops the background plink holding the connection and removes its log files. Safe to
    call twice, or when nothing was opened. Call it in a finally block (or the script's
    trap); Exit-Deploy calls it, and PowerShell's exit stops any holder left over.

    .PARAMETER Connection
    The connection to close; by default the one Open-DeployConnection stored.

    .EXAMPLE
    Close-DeployConnection
    #>
    [CmdletBinding()]
    param(
        [object]$Connection
    )
    $target = if ($Connection) { $Connection } else { $script:DefaultConnection }
    if (-not $target) { return }
    Disconnect-SharedUpstream -Connection $target
    $target.Opened = $false
}

#endregion

#region Remote commands

function Invoke-RemoteWithRetry {
    <#
    .SYNOPSIS
    Runs a command on the host through plink, prints its output, and returns whether it succeeded.

    .DESCRIPTION
    The scripts' Invoke-RemoteWithRetry, in its most complete form: carriage returns are
    stripped (IDE Resume Site), output lines are printed indented, and when the failure
    looks like a dropped connection it reconnects and runs the command once more, printing
    that output too (Fantasy Dossier, IDE Resume Site). It rides the connection
    Open-DeployConnection holds; a reconnect waits 35 seconds only if it is refused. A
    genuine command failure is not retried. From Family Card Game, Fantasy Dossier,
    Fingerprint Generator, IDE Resume Site (as Invoke-Remote), Marxbot, Nophica, Senpan,
    TarotGen.io and Venue Tools.

    .PARAMETER Script
    The shell command or script to run on the host.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    if (-not (Invoke-RemoteWithRetry "systemctl is-active --quiet example")) { Fail 'The service is not running.' }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Script,

        [object]$Connection,

        [switch]$NoRetry
    )
    $result = Invoke-RemoteCore -Connection (Get-ActiveConnection -Connection $Connection) -Script $Script -NoRetry:$NoRetry -Echo
    $result.ExitCode -eq 0
}

function Invoke-Remote {
    <#
    .SYNOPSIS
    Runs a command on the host through plink and returns its output lines; throws if it fails.

    .DESCRIPTION
    Kindred Nights' and Home Library's Invoke-Remote: carriage returns stripped, stderr
    merged into the output, and on failure the output printed before the throw, so the
    reason shows. Like every remote call here it rides the held connection and, after a
    dropped one, reconnects and retries once (decided 2026-11-05); -NoRetry turns that off.

    .PARAMETER Script
    The shell command or script to run on the host.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    $output = Invoke-Remote "systemctl is-active example"
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Script,

        [object]$Connection,

        [switch]$NoRetry
    )
    $result = Invoke-RemoteCore -Connection (Get-ActiveConnection -Connection $Connection) -Script $Script -NoRetry:$NoRetry
    if ($result.ExitCode -ne 0) {
        $result.Lines | Write-Host
        throw "Remote command failed ($($result.ExitCode))"
    }
    $result.Lines
}

function Invoke-RemoteStep {
    <#
    .SYNOPSIS
    Runs several self-contained shell blocks (such as the Restore- functions' -AsScript output) in one connection; throws if any fails.

    .DESCRIPTION
    For a rollback that spans targets, such as Senpan's backend and frontend after a failed
    smoke check: one connection, set -e first, the blocks joined by newlines so the first
    failure stops the rest.

    .PARAMETER Script
    The blocks to run, in order.

    .PARAMETER FailureMessage
    What the throw says when a block fails.

    .PARAMETER AsScript
    Return the joined script instead of running it.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    Invoke-RemoteStep -Script (Restore-ServiceBinary -ServiceName 'example' -Binary '/opt/example/example' -AsScript), (Restore-RemoteDirectory -Live '/var/www/example.com/dist' -AsScript)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Script,

        [string]$FailureMessage = 'A remote step failed on the host',

        [switch]$AsScript,

        [object]$Connection,

        [switch]$NoRetry
    )
    $text = ((@('set -e') + @($Script | Where-Object { $_ })) -join "`n") -replace "`r", ''
    if ($AsScript) { return $text }
    Invoke-RemoteFlow -Connection $Connection -Script $text -NoRetry:$NoRetry -FailureMessage $FailureMessage
}

function Format-RemoteScript {
    <#
    .SYNOPSIS
    Fills a shell template's placeholders literally, so a $ in a value stays a $.

    .DESCRIPTION
    IDE Resume Site's Format-Remote, which fills __NAME__ placeholders, also filling
    Simple Image Gallery's {{NAME}} ones, so both scripts' templates work unchanged.
    Carriage returns are stripped. Values are inserted as they are, not quoted.

    .PARAMETER Template
    The shell script, usually a single-quoted here-string.

    .PARAMETER Value
    Each placeholder's name (without the underscores or braces) and its value.

    .EXAMPLE
    Format-RemoteScript -Template 'cd "__WEB__"' -Value @{ WEB = $webRoot }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Template,

        [Parameter(Mandatory, Position = 1)]
        [hashtable]$Value
    )
    $text = $Template -replace "`r", ''
    foreach ($key in $Value.Keys) {
        $replacement = [string]$Value[$key]
        $text = $text.Replace("__${key}__", $replacement).Replace("{{$key}}", $replacement)
    }
    $text
}

#endregion

#region Transfers

function Compress-DeployArchive {
    <#
    .SYNOPSIS
    Packs everything a deploy needs into ONE .tar.gz, and returns its path, file count and SHA-256.

    .DESCRIPTION
    Every deploy ships one archive (decided 2026-11-05): the binary, systemd units, env
    templates, .htaccess, plugin files and static dist all go in it, and the host unpacks
    it once and checks it before anything changes (Invoke-DeployBundle). SCP negotiates each
    file separately, so loose files spend most of an upload on round trips, and a truncated
    archive refuses to unpack where a half-copied folder can look whole (Senpan's reasoning).

    -Content maps each path inside the archive to a local file or folder, so pieces from
    different places (server/, web/dist, deploy/) can be laid out as the steps want them;
    they are copied to a temporary folder, packed, and the folder removed. -Root and -Item
    pack a folder that is already laid out.

    It uses Windows' own tar (Resolve-TarTool) in ustar format, since the default pax
    format carries Windows file flags that GNU tar on the host warns about for every entry
    (TarotGen.io). From Senpan, TarotGen.io, Simple Image Gallery and Conlang Translator.

    .PARAMETER Content
    An ordered dictionary: each key a path inside the archive ('dist', '.htaccess',
    'plugin/repo.json'), each value the local file or folder that goes there.

    .PARAMETER Root
    A local folder already laid out as the archive should be (tar -C).

    .PARAMETER Item
    The files and folders inside Root to pack.

    .PARAMETER Destination
    The local .tar.gz to write; by default a new file in the temp folder.

    .PARAMETER Exclude
    tar --exclude patterns, such as '__pycache__' (Conlang Translator).

    .EXAMPLE
    $archive = Compress-DeployArchive -Content ([ordered]@{ 'example' = $binary; 'example.service' = $unit; 'dist' = $dist })
    #>
    [CmdletBinding(DefaultParameterSetName = 'Content')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Content')]
        [System.Collections.IDictionary]$Content,

        [Parameter(Mandatory, ParameterSetName = 'Root')]
        [string]$Root,

        [Parameter(Mandatory, ParameterSetName = 'Root')]
        [string[]]$Item,

        [string]$Destination,

        [string[]]$Exclude = @()
    )
    if (-not $Destination) {
        $Destination = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('deploy-{0}.tgz' -f [guid]::NewGuid())
    }
    $tar = Resolve-TarTool
    $stage = $null
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Content') {
            if ($Content.Count -eq 0) { throw 'Nothing to pack: -Content is empty.' }
            $stage = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('deploy-stage-{0}' -f [guid]::NewGuid())
            $null = New-Item -ItemType Directory -Path $stage
            foreach ($name in $Content.Keys) {
                Assert-SafeRemoteName -Value $name -What 'Archive path' -AllowSlash
                $from = [string]$Content[$name]
                if (-not (Test-Path -LiteralPath $from)) { throw "Not found: $from (for $name in the archive)." }
                $to = Join-Path -Path $stage -ChildPath $name
                if (Test-Path -LiteralPath $to) { throw "$name is in the archive twice." }
                $parent = Split-Path -Path $to -Parent
                if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
                Copy-Item -LiteralPath $from -Destination $to -Recurse -Force
            }
            $Root = $stage
            $Item = @($Content.Keys | ForEach-Object { ($_ -split '/')[0] } | Select-Object -Unique)
        }
        $tarArgs = @('--format', 'ustar') + @($Exclude | ForEach-Object { "--exclude=$_" }) + @('-czf', $Destination, '-C', $Root) + $Item
        & $tar @tarArgs
        if ($LASTEXITCODE -ne 0) { throw "Could not pack $Root into $Destination (tar exit $LASTEXITCODE)." }
    } finally {
        if ($stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $count = @(& $tar -tzf $Destination | Where-Object { $_ -notmatch '/$' }).Count
    if ($LASTEXITCODE -ne 0) { throw "Could not read back $Destination (tar exit $LASTEXITCODE)." }
    $file = Get-Item -LiteralPath $Destination
    [pscustomobject]@{
        Path      = $file.FullName
        FileCount = $count
        Size      = $file.Length
        Sha256    = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Invoke-Upload {
    <#
    .SYNOPSIS
    Uploads the deploy archive over the held connection, byte for byte, with an elapsed-time indicator and a time limit.

    .DESCRIPTION
    The scripts' Invoke-Upload, and the one upload of every deploy. pscp cannot share a
    connection from its command line, so the archive streams through plink instead
    (decided 2026-11-05): plink -share runs `cat > <Destination>` on the host with the
    archive as its standard input, through Start-Process redirection, which passes the
    bytes untouched. The SHA-256 check in Invoke-DeployBundle then confirms what arrived.
    The console shows an elapsed-time bar, and the upload is stopped after 15 minutes. If
    the connection drops, it reconnects and uploads once more. Returns Ok, Err and Elapsed.
    From Senpan, TarotGen.io, Fantasy Dossier and Fingerprint Generator.

    Upload into the SSH user's home (a relative -Destination), which always exists.

    .PARAMETER Path
    The local archive.

    .PARAMETER Destination
    The remote file; relative paths are relative to the SSH user's home.

    .PARAMETER Activity
    The progress bar's title.

    .PARAMETER Status
    What the progress bar says before the elapsed time; by default the file names, or the
    file count when -FileCount is given.

    .PARAMETER FileCount
    The number of files in the archive, for the progress bar.

    .PARAMETER TimeoutSeconds
    How long the upload may take before it is stopped. Every script uses 900.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    $upload = Invoke-Upload -Path $archive.Path -Destination 'example-deploy.tgz' -Activity 'Uploading example' -FileCount $archive.FileCount
    if (-not $upload.Ok) { Fail "Upload failed. Nothing on the host changed.`n$($upload.Err)" }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [Alias('ArchivePath')]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [Alias('RemotePath')]
        [string]$Destination,

        [Alias('Label')]
        [string]$Activity = 'Uploading',

        [string]$Status,

        [int]$FileCount = 0,

        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 900,

        [object]$Connection,

        [switch]$NoRetry
    )
    $active = Get-ActiveConnection -Connection $Connection
    Assert-RemotePath -Value $Destination -What 'Destination'
    $local = (Resolve-Path -LiteralPath $Path).ProviderPath
    if (-not $Status) {
        $size = (Get-Item -LiteralPath $local).Length / 1KB
        $Status = if ($FileCount -gt 0) { '{0} files, {1:N0} KB' -f $FileCount, $size } else { '{0}, {1:N0} KB' -f (Split-Path -Path $local -Leaf), $size }
    }
    $target = ConvertTo-ShellLiteral -Value $Destination
    $stream = @{
        Connection     = $active
        Command        = "umask 077; mkdir -p `"`$(dirname $target)`" && cat > $target"
        InputFile      = $local
        Activity       = $Activity
        Status         = $Status
        TimeoutSeconds = $TimeoutSeconds
    }
    Invoke-StreamWithRetry -Stream $stream -NoRetry:$NoRetry
}

function Send-File {
    <#
    .SYNOPSIS
    Uploads single files over the held connection; returns whether it worked. For the rare case outside a deploy's one archive.

    .DESCRIPTION
    The scripts' Send-File, now streamed through plink -share (`cat > <path>` with the file
    as standard input) rather than pscp. Deploys ship one archive through Invoke-Upload and
    Invoke-DeployBundle instead (decided 2026-11-05); this stays for the rare case that
    truly cannot. Folders are not sent: put them in an archive. If the connection drops,
    it reconnects and sends once more. From Family Card Game, Marxbot, Nophica, Senpan,
    Simple Image Gallery and Venue Tools.

    .PARAMETER Path
    The local file or files.

    .PARAMETER Destination
    The remote file, or with several files (or a path ending in /) the remote folder they
    go into. Relative paths are relative to the SSH user's home.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    if (-not (Send-File $notes 'notes.txt')) { Write-Warning 'The notes were not uploaded.' }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Path,

        [Parameter(Mandatory, Position = 1)]
        [string]$Destination,

        [object]$Connection,

        [switch]$NoRetry
    )
    $active = Get-ActiveConnection -Connection $Connection
    Assert-RemotePath -Value $Destination -What 'Destination'
    $intoFolder = $Path.Count -gt 1 -or $Destination.EndsWith('/')
    foreach ($item in $Path) {
        if (-not (Test-Path -LiteralPath $item -PathType Leaf)) { throw "Not a file: $item (folders go in a deploy archive)." }
        $local = (Resolve-Path -LiteralPath $item).ProviderPath
        $remote = if ($intoFolder) { $Destination.TrimEnd('/') + '/' + (Split-Path -Path $local -Leaf) } else { $Destination }
        $target = ConvertTo-ShellLiteral -Value $remote
        $stream = @{
            Connection     = $active
            Command        = "mkdir -p `"`$(dirname $target)`" && cat > $target"
            InputFile      = $local
            Activity       = 'Uploading'
            Status         = Split-Path -Path $local -Leaf
            TimeoutSeconds = 900
        }
        $result = Invoke-StreamWithRetry -Stream $stream -NoRetry:$NoRetry
        if (-not $result.Ok) {
            Write-Host "    Upload of $local failed: $($result.Err)" -ForegroundColor Yellow
            return $false
        }
    }
    $true
}

function Get-File {
    <#
    .SYNOPSIS
    Downloads a file over the held connection and checks it against the host's SHA-256; returns whether it worked.

    .DESCRIPTION
    Senpan's Get-File, the mirror of Send-File, now streamed through plink -share: `cat` on
    the host with its standard output going to a local file through Start-Process
    redirection, which passes the bytes untouched. The download goes to <Destination>.part,
    the host's sha256sum of the file is compared with the local one, and only a match is
    moved into place; otherwise the partial file is removed. If the connection drops, it
    reconnects and downloads once more. Copy-LiveDatabase uses it; Kindred Nights and Home
    Library downloaded the same way inline, with pscp and no check.

    .PARAMETER Source
    The remote file. Relative paths are relative to the SSH user's home.

    .PARAMETER Destination
    The local file.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    if (-not (Get-File 'pull/files.tgz' (Join-Path $devData 'files.tgz'))) { Fail 'Download failed.' }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Source,

        [Parameter(Mandatory, Position = 1)]
        [string]$Destination,

        [object]$Connection,

        [switch]$NoRetry
    )
    $active = Get-ActiveConnection -Connection $Connection
    Assert-RemotePath -Value $Source -What 'Source'
    $folder = Split-Path -Path $Destination -Parent
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    $part = "$Destination.part"
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    $quoted = ConvertTo-ShellLiteral -Value $Source
    $stream = @{
        Connection     = $active
        Command        = "cat $quoted"
        OutputFile     = $part
        Activity       = 'Downloading'
        Status         = Split-Path -Path $Source -Leaf
        TimeoutSeconds = 900
    }
    $result = Invoke-StreamWithRetry -Stream $stream -NoRetry:$NoRetry
    if (-not $result.Ok) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Write-Host "    Download of $Source failed: $($result.Err)" -ForegroundColor Yellow
        return $false
    }
    $hashCheck = Invoke-RemoteCore -Connection $active -Script "sha256sum $quoted" -NoRetry:$NoRetry
    $remoteHash = if ($hashCheck.ExitCode -eq 0) { ("$($hashCheck.Lines | Select-Object -First 1)" -split '\s+')[0].ToLowerInvariant() } else { '' }
    $localHash = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($remoteHash -ne $localHash) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Write-Host "    The download of $Source does not match the host's SHA-256; it was discarded." -ForegroundColor Yellow
        return $false
    }
    Move-Item -LiteralPath $part -Destination $Destination -Force
    $true
}

function Send-FileVerified {
    <#
    .SYNOPSIS
    Uploads one file beside its place, checks its SHA-256 on the host, and only then renames it in. For the rare case outside a deploy archive.

    .DESCRIPTION
    Senpan's Send-FileVerified: the file goes to <Destination>.new, the host checks the hash
    computed here, and a rename puts it in place, so a reader sees the old file or the new
    one. The remote step is safe to retry: if the staged file is gone, the rename already
    ran, and the final check confirms what is in place. On failure the live file is
    untouched and the staged copy removed. Two remote calls, both on the held connection. Files that ship with a deploy
    go in its one archive instead (decided 2026-11-05), including the .htaccess files and
    plugin files Senpan and Venue Tools uploaded one by one.

    .PARAMETER Path
    The local file.

    .PARAMETER Destination
    The live remote path.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .EXAMPLE
    if (-not (Send-FileVerified $file "$webRoot/robots.txt")) { Write-Warning 'robots.txt was not updated.' }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [string]$Destination,

        [object]$Connection
    )
    $active = Get-ActiveConnection -Connection $Connection
    $staged = "$Destination.new"
    if (-not (Send-File -Path $Path -Destination $staged -Connection $active)) { return $false }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    $quotedStaged = ConvertTo-ShellLiteral -Value $staged
    $quotedLive = ConvertTo-ShellLiteral -Value $Destination
    $check = @"
set -e
if [ -f $quotedStaged ]; then
  printf '%s  %s\n' '$hash' $quotedStaged | sha256sum -c - >/dev/null
  mv -f $quotedStaged $quotedLive
fi
printf '%s  %s\n' '$hash' $quotedLive | sha256sum -c - >/dev/null
"@
    if (Invoke-RemoteWithRetry -Script $check -Connection $active) { return $true }
    # Leave the live file untouched and clear the staged copy.
    $null = Invoke-PlinkOnce -Connection $active -Script "rm -f $quotedStaged"
    $false
}

#endregion

#region Builds and checks before a deploy

function Restore-Env {
    <#
    .SYNOPSIS
    Puts an environment variable back to a value saved earlier; $null removes it.

    .DESCRIPTION
    Copied unchanged from Family Card Game, Marxbot, Nophica and Senpan, which save GOOS,
    GOARCH and CGO_ENABLED around their Go build. Invoke-GoBuild uses it.

    .PARAMETER Name
    The variable's name, without Env:.

    .PARAMETER Value
    The saved value, or $null if it was not set.

    .EXAMPLE
    Restore-Env 'GOOS' $savedGoos
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [Parameter(Position = 1)]
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value
    )
    if ($null -eq $Value) {
        Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    } else {
        Set-Item -Path "Env:$Name" -Value $Value
    }
}

function Invoke-GoBuild {
    <#
    .SYNOPSIS
    Cross-compiles a static, stripped linux/amd64 binary and returns its path.

    .DESCRIPTION
    The build Family Card Game, Marxbot, Nophica and Senpan each copy: check that go is on
    PATH, set GOOS=linux GOARCH=amd64 CGO_ENABLED=0 for the build only (the previous
    values come back afterwards, even on failure), and run go build "-ldflags=-s -w" in the
    module's folder. -ForceRebuild adds -a, which Family Card Game needs so the embedded
    front end is never stale. Throws if the build fails or leaves no binary.

    .PARAMETER Path
    The folder holding the Go main package.

    .PARAMETER Output
    The binary's file name (go build -o), written into Path.

    .PARAMETER ForceRebuild
    Rebuild every package (go build -a).

    .EXAMPLE
    $binary = Invoke-GoBuild -Path $repoRoot -Output 'example'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Output,

        [switch]$ForceRebuild
    )
    if (-not (Get-Command -Name 'go' -ErrorAction SilentlyContinue)) {
        throw 'Go toolchain not found (go). Install Go or add it to PATH.'
    }
    Write-Step "Building $Output (GOOS=linux GOARCH=amd64 CGO_ENABLED=0, stripped$(if ($ForceRebuild) { ', every package' }))..."
    $saved = @{ GOOS = $env:GOOS; GOARCH = $env:GOARCH; CGO_ENABLED = $env:CGO_ENABLED }
    Push-Location -LiteralPath $Path
    try {
        $env:GOOS = 'linux'
        $env:GOARCH = 'amd64'
        $env:CGO_ENABLED = '0'
        $goArgs = @('build')
        if ($ForceRebuild) { $goArgs += '-a' }
        $goArgs += @('-ldflags=-s -w', '-o', $Output, '.')
        & go @goArgs
        if ($LASTEXITCODE -ne 0) { throw "go build failed (exit $LASTEXITCODE). Nothing was deployed." }
    } finally {
        Pop-Location
        foreach ($name in $saved.Keys) { Restore-Env -Name $name -Value $saved[$name] }
    }
    $binary = Join-Path -Path $Path -ChildPath $Output
    if (-not (Test-Path -LiteralPath $binary)) { throw "Binary not found at $binary after the build." }
    Write-Ok ("Binary built: $binary ({0:N1} MB)" -f ((Get-Item -LiteralPath $binary).Length / 1MB))
    $binary
}

function Invoke-NpmBuild {
    <#
    .SYNOPSIS
    Runs npm run build in a folder and checks the build left its index.html.

    .DESCRIPTION
    The front-end build Family Card Game, Fantasy Dossier, Fingerprint Generator, Senpan,
    Simple Image Gallery and TarotGen.io each copy. Throws if npm fails or the expected
    output is missing, so nothing is deployed.

    .PARAMETER Path
    The folder with package.json.

    .PARAMETER Output
    A file the build must leave, usually dist/index.html.

    .EXAMPLE
    Invoke-NpmBuild -Path $frontend -Output (Join-Path $frontend 'dist/index.html')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Output
    )
    Write-Step "Building $(Split-Path -Path $Path -Leaf) (npm run build)..."
    Push-Location -LiteralPath $Path
    try {
        npm run build
        if ($LASTEXITCODE -ne 0) { throw "npm run build failed (exit $LASTEXITCODE). Nothing was deployed." }
    } finally {
        Pop-Location
    }
    if ($Output) {
        if (-not (Test-Path -LiteralPath $Output)) { throw "$Output is missing after the build - nothing to deploy." }
        Write-Ok "Build present: $(Split-Path -Path $Output -Parent)"
    }
}

function Invoke-PluginBuild {
    <#
    .SYNOPSIS
    Builds a Dalamud plugin in Release after deleting its bin/ and obj/ folders.

    .DESCRIPTION
    The plugin build Kindred Nights, Senpan, Venue Tools and TarotGen.io each copy, with
    TarotGen.io's clean start for all four (decided 2026-11-05): DalamudPackager's
    incremental packaging can leave a stale latest.zip whose embedded version lags the
    freshly built manifest, and Dalamud then offers an update it can never reconcile.
    Throws if dotnet is missing or the build fails.

    .PARAMETER Project
    The plugin's .csproj, or the folder holding it.

    .EXAMPLE
    Invoke-PluginBuild -Project (Join-Path $repoRoot 'plugins\Example\Example.csproj')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Project
    )
    if (-not (Get-Command -Name 'dotnet' -ErrorAction SilentlyContinue)) {
        throw '.NET SDK not found (dotnet). Install it or add it to PATH.'
    }
    if (-not (Test-Path -LiteralPath $Project)) { throw "Plugin project not found: $Project" }
    $folder = if (Test-Path -LiteralPath $Project -PathType Container) { $Project } else { Split-Path -Path $Project -Parent }
    Write-Step 'Building the plugin (dotnet build -c Release, from clean bin/ and obj/)...'
    foreach ($leaf in 'bin', 'obj') {
        Remove-Item -LiteralPath (Join-Path -Path $folder -ChildPath $leaf) -Recurse -Force -ErrorAction SilentlyContinue
    }
    & dotnet build $Project -c Release --nologo -v minimal
    if ($LASTEXITCODE -ne 0) { throw "Plugin build failed (exit $LASTEXITCODE). Nothing was published." }
}

function Assert-CleanWorkingTree {
    <#
    .SYNOPSIS
    Throws unless the git working tree has no uncommitted changes, listing them if it does.

    .DESCRIPTION
    For deploys that ship a commit. IDE Resume Site's form, which also catches git itself
    failing and lists the changed files; Kindred Nights and Home Library make the same
    check in one line.

    .PARAMETER Path
    The repository; by default the current location.

    .EXAMPLE
    Assert-CleanWorkingTree -Path $repoRoot
    #>
    [CmdletBinding()]
    param(
        [string]$Path = (Get-Location).Path
    )
    $dirty = git -C $Path status --porcelain
    if ($LASTEXITCODE -ne 0) { throw "git status failed in $Path; is this the repository?" }
    if ($dirty) { throw "Working tree is not clean. Commit or stash first:`n$($dirty -join "`n")" }
}

function Get-ReleaseTag {
    <#
    .SYNOPSIS
    Returns the tag on HEAD, or throws if HEAD is not tagged.

    .DESCRIPTION
    Kindred Nights and Home Library ship tagged commits only; this is their check.

    .PARAMETER Path
    The repository; by default the current location.

    .EXAMPLE
    $version = Get-ReleaseTag -Path $repoRoot
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Path = (Get-Location).Path
    )
    $tag = git -C $Path describe --tags --exact-match 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $tag) { throw 'HEAD is not tagged. Deploys ship tagged commits only.' }
    "$tag".Trim()
}

#endregion

#region The deploy bundle

function Invoke-DeployBundle {
    <#
    .SYNOPSIS
    The one remote run of a deploy: unpack the uploaded archive to a staging folder, check its SHA-256 and file count, then run each step in order.

    .DESCRIPTION
    Every deploy's shape (decided 2026-11-05): one archive, one upload, one remote run. This
    is the run. Nothing on the host changes until the archive's SHA-256 and file count both
    match; then the steps run under set -e, each a block from a flow function's -AsStep
    (Install-ServiceBinary, Switch-RemoteDirectory, Switch-RemoteItemSet,
    Publish-PluginRepository) or the project's own shell. A deploy with several targets
    (Senpan, TarotGen.io) passes one step for each, so it still rides the deploy's one
    connection, and needs none of the 35-second pauses Senpan used between targets.

    Steps find the unpacked upload in the shell variable $bundle. Files are unpacked with
    the server's usual owner, modes (644 files, 755 folders) and times rather than the
    archive's, since Windows tar records 0666 files (TarotGen.io).

    The run rides the connection Open-DeployConnection holds. If that connection drops,
    it reconnects and runs once more (decided 2026-11-05), and the retry resumes rather
    than starting again: marker files in the SSH user's
    ~/.shared-deploy record that this run's upload was checked and which steps finished,
    so finished steps are skipped, and a run that already completed says so and succeeds.
    The staging folder is removed when every step has succeeded; after a failure it stays
    until the next deploy of the same archive path, which replaces it.

    .PARAMETER Archive
    The uploaded archive on the host. Relative paths are relative to the SSH user's home.

    .PARAMETER Sha256
    The archive's SHA-256 (Compress-DeployArchive returns it).

    .PARAMETER ExpectedFileCount
    How many files the archive holds (Compress-DeployArchive returns it).

    .PARAMETER Step
    The steps to run, in order: blocks from the flow functions' -AsStep, or shell of the
    project's own that reads files from "$bundle".

    .PARAMETER AsScript
    Return the remote script instead of running it.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    Invoke-DeployBundle -Archive 'example-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount -Step @(
        Install-ServiceBinary -AsStep -ServiceName 'example' -Binary '/opt/example/example'
        Switch-RemoteDirectory -AsStep -Live '/var/www/example.com/dist'
    )
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Archive,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{64}$')]
        [string]$Sha256,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$ExpectedFileCount,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$Step,

        [switch]$AsScript,

        [object]$Connection,

        [switch]$NoRetry
    )
    Assert-RemotePath -Value $Archive -What 'Archive'
    $steps = @($Step | Where-Object { $_ })
    if ($steps.Count -eq 0) { throw 'Nothing to run: every -Step is empty.' }
    $variable = [ordered]@{
        archive = $Archive
        sha     = $Sha256.ToLowerInvariant()
        expect  = "$ExpectedFileCount"
        key     = Get-PathKey -Value $Archive
        token   = [guid]::NewGuid().ToString()
    }
    $open = @'
case "$archive" in /*) ;; *) archive="$HOME/$archive" ;; esac
base="$HOME/.shared-deploy"
bundle="$base/$key.bundle"
mkdir -p "$base"
chmod 700 "$base"
if [ -f "$archive" ]; then
  if ! printf '%s  %s\n' "$sha" "$archive" | sha256sum -c --quiet - >/dev/null 2>&1; then
    echo "The upload does not match its SHA-256; nothing was changed." >&2
    exit 3
  fi
  rm -rf "$bundle"
  rm -f "$base/$key".step* "$base/$key.verified"
  mkdir -p "$bundle"
  tar --no-same-owner --no-same-permissions --touch -xzf "$archive" -C "$bundle"
  find "$bundle" -type d -exec chmod 755 {} +
  find "$bundle" -type f -exec chmod 644 {} +
  count=$(find "$bundle" -type f | wc -l)
  if [ "$count" -ne "$expect" ]; then
    rm -rf "$bundle"
    echo "Incomplete upload: $count of $expect files; nothing was changed." >&2
    exit 3
  fi
  printf '%s' "$token" > "$base/$key.verified"
  rm -f "$archive"
  echo "Upload checked: $count files, SHA-256 matches."
elif [ -d "$bundle" ] && [ "$(cat "$base/$key.verified" 2>/dev/null)" = "$token" ]; then
  echo 'Resuming from the checked upload (a retried connection).'
elif [ "$(cat "$base/$key.deployed" 2>/dev/null)" = "$token" ]; then
  echo 'Already deployed (a retried connection).'
  exit 0
else
  echo "The upload is missing on the host: $archive" >&2
  exit 3
fi
'@
    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add($open)
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $body.Add(('if [ "$(cat "$base/$key.step{0}" 2>/dev/null)" != "$token" ]; then' -f $i))
        $body.Add($steps[$i])
        $body.Add(('printf ''%s'' "$token" > "$base/$key.step{0}"' -f $i))
        $body.Add('fi')
    }
    $body.Add(@'
rm -rf "$bundle"
rm -f "$base/$key".step* "$base/$key.verified"
printf '%s' "$token" > "$base/$key.deployed"
echo 'Deploy finished on the host.'
'@)
    $script = Join-ShellScript -Variable $variable -Body $body -Outer
    if ($AsScript) { return $script }
    Invoke-RemoteFlow -Connection $Connection -Script $script -NoRetry:$NoRetry -FailureMessage 'The deploy failed on the host; the lines above say how far it got and what was rolled back'
}

#endregion

#region Service binaries

function Install-ServiceBinary {
    <#
    .SYNOPSIS
    From the checked upload, in one remote run: stop the services, keep the old binary, snapshot the database, install the binary, units and vhost, start, check, and roll back everything together if anything fails.

    .DESCRIPTION
    The binary swap Family Card Game, Marxbot, Nophica, Senpan (backend), Kindred Nights
    and Home Library each write, with the most careful step of each, for one service or a
    set of them. The binary, units and vhost travel in the deploy's one archive, uploaded
    before anything stops (decided 2026-11-05). In order:
      - checks before anything stops: the binary and units are in the upload; the health
        URL can be built; the vhost, where it differs, is installed and must pass
        apachectl configtest, or it is put back and the deploy stops with nothing else changed;
      - every listed service stops (a missing one is tolerated), and from here to the start
        a trap brings them back up on what is in place if a step fails;
      - <Binary>.old keeps the current binary; with -Database, sqlite3 .backup takes a
        snapshot and the newest three are kept (decided 2026-11-05);
      - each unit that differs from the live one (compared with cmp) is installed, the
        previous kept as <name>.old (mode kept, so 600 stays 600), and systemd reloaded;
        a new unit's service is enabled, and the first service whenever its own unit changed;
      - the binary is installed with its mode and owner, then each service restarts: the
        first always, the others if they are enabled (Home Library's text service);
      - the check: every started service active after -SettleSeconds, or, with -HealthUrl,
        the first service answering it within -HealthTimeoutSeconds;
      - on failure, everything goes back together: the journal's last 30 lines of each
        failed service, the old binary, units (a unit new in this deploy is removed) and
        vhost, the database snapshot if -RestoreDatabaseOnRollback (or the command to do
        it), then the services restart and the step fails;
      - on success, Apache reloads if the vhost changed, changed units that are not services
        (timers) get try-restart, and -NoBackup removes the .old copies.

    Hooks run under set -e with these shell variables set: services, main, bin, old, bundle,
    db, snap, health. A hook may set health.

    .PARAMETER ServiceName
    The systemd services, restarted and rolled back together. The first is the binary's
    own; -HealthUrl checks it.

    .PARAMETER Binary
    The live binary's path on the host.

    .PARAMETER Source
    The binary's path inside the upload; by default Binary's file name.

    .PARAMETER Mode
    The installed binary's mode; 755 in every script.

    .PARAMETER Owner
    user or user:group for the binary (a bare user also names the group): Kindred Nights
    and Family Card Game use the service's own user, Home Library root. When empty the
    binary is owned by the SSH user, as in Marxbot, Nophica and Senpan.

    .PARAMETER Unit
    Systemd unit files inside the upload, each installed as /etc/systemd/system/<its name>
    when it differs from the live one.

    .PARAMETER UnitMode
    The units' mode. Marxbot and Nophica use 600, since their units hold the bot token.

    .PARAMETER UnitBackupDirectory
    Where the previous units are kept as <name>.old; by default the binary's folder.

    .PARAMETER Vhost
    An Apache vhost inside the upload, installed as -VhostPath when it differs and checked
    with apachectl configtest before anything stops (Home Library).

    .PARAMETER VhostPath
    The live vhost file, such as /etc/apache2/sites-available/example.conf.

    .PARAMETER ReloadService
    What reloads once the new vhost is in: apache2.

    .PARAMETER HealthUrl
    A URL fetched on the host (curl -fs, two seconds each) once a second until it answers,
    instead of the first service's is-active check (Home Library's /healthz). Parts in
    braces, such as http://{EXAMPLE_ADDR}/healthz, are read from -EnvFile on the host.

    .PARAMETER EnvFile
    The service's env file on the host, for -HealthUrl's {NAME} parts.

    .PARAMETER HealthDefault
    Values for -HealthUrl's {NAME} parts the env file does not set.

    .PARAMETER HealthTimeoutSeconds
    How long -HealthUrl may take to answer; Home Library allows 30.

    .PARAMETER SettleSeconds
    How long to wait before the is-active check; every script waits 2.

    .PARAMETER Umask
    The umask for the whole step, so snapshots and copies are for root alone (Home Library: 077).

    .PARAMETER Database
    The live SQLite database on the host, snapshotted with sqlite3 .backup after the stop.

    .PARAMETER SnapshotPrefix
    The snapshot's path up to its time stamp, such as /opt/example/backups/example-pre-.
    By default <Database>.pre- (Senpan).

    .PARAMETER SnapshotSuffix
    What follows the time stamp, such as .sqlite.

    .PARAMETER RestoreDatabaseOnRollback
    Put the snapshot back on a rollback, since the new binary may have migrated the schema
    before it fell over (Kindred Nights, Home Library). Opt-in per project (decided
    2026-11-05); without it, the command to do so is printed (Senpan).

    .PARAMETER AfterStop
    Shell run just after the stop, before the backup and snapshot.

    .PARAMETER BeforeStart
    Shell run after the install, just before the start (Nophica retires its old service here).

    .PARAMETER OnRollback
    Shell run on a rollback, after everything is back and before the services start.

    .PARAMETER AfterSuccess
    Shell run once the services are up.

    .PARAMETER NoBackup
    Remove the .old copies once the services are up. Restore-ServiceBinary then has
    nothing to go back to.

    .PARAMETER Archive
    The uploaded archive, when this runs on its own rather than as one step of Invoke-DeployBundle.

    .PARAMETER Sha256
    The archive's SHA-256.

    .PARAMETER ExpectedFileCount
    How many files the archive holds.

    .PARAMETER AsStep
    Return the step for Invoke-DeployBundle instead of running it.

    .PARAMETER AsScript
    Return the whole remote script instead of running it.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    Install-ServiceBinary -Archive 'example-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
        -ServiceName 'example' -Binary '/opt/example/example' -Owner 'example' -Unit 'example.service'

    .EXAMPLE
    Install-ServiceBinary -AsStep -ServiceName 'example', 'example-worker' -Binary '/opt/example/example' `
        -Unit 'units/example.service', 'units/example-worker.service', 'units/example-backup.timer' `
        -Vhost 'example.conf' -VhostPath '/etc/apache2/sites-available/example.conf' `
        -EnvFile '/etc/example/example.env' -HealthUrl 'http://{EXAMPLE_ADDR}/healthz' -Umask '077' `
        -Database '/opt/example/data/example.sqlite' -SnapshotPrefix '/opt/example/backups/example-pre-' -SnapshotSuffix '.sqlite' -RestoreDatabaseOnRollback
    #>
    [CmdletBinding(DefaultParameterSetName = 'Archive')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_.@-]+$')]
        [string[]]$ServiceName,

        [Parameter(Mandatory)]
        [string]$Binary,

        [string]$Source,

        [ValidatePattern('^[0-7]{3,4}$')]
        [string]$Mode = '755',

        [string]$Owner,

        [string[]]$Unit = @(),

        [ValidatePattern('^[0-7]{3,4}$')]
        [string]$UnitMode = '644',

        [string]$UnitBackupDirectory,

        [string]$Vhost,

        [string]$VhostPath,

        [ValidatePattern('^[A-Za-z0-9_.@-]+$')]
        [string]$ReloadService = 'apache2',

        [string]$HealthUrl,

        [string]$EnvFile,

        [System.Collections.IDictionary]$HealthDefault = @{},

        [ValidateRange(1, 3600)]
        [int]$HealthTimeoutSeconds = 30,

        [ValidateRange(0, 3600)]
        [int]$SettleSeconds = 2,

        [ValidatePattern('^[0-7]{3,4}$')]
        [string]$Umask,

        [string]$Database,

        [string]$SnapshotPrefix,

        [string]$SnapshotSuffix = '',

        [switch]$RestoreDatabaseOnRollback,

        [string]$AfterStop,

        [string]$BeforeStart,

        [string]$OnRollback,

        [string]$AfterSuccess,

        [switch]$NoBackup,

        [Parameter(Mandatory, ParameterSetName = 'Archive')]
        [string]$Archive,

        [Parameter(Mandatory, ParameterSetName = 'Archive')]
        [ValidatePattern('^[0-9a-fA-F]{64}$')]
        [string]$Sha256,

        [Parameter(Mandatory, ParameterSetName = 'Archive')]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$ExpectedFileCount,

        [Parameter(ParameterSetName = 'Step')]
        [switch]$AsStep,

        [Parameter(ParameterSetName = 'Archive')]
        [switch]$AsScript,

        [Parameter(ParameterSetName = 'Archive')]
        [object]$Connection,

        [Parameter(ParameterSetName = 'Archive')]
        [switch]$NoRetry
    )
    Assert-RemotePath -Value $Binary -What 'Binary'
    if (-not $Source) { $Source = Split-Path -Path $Binary -Leaf }
    Assert-SafeRemoteName -Value $Source -What 'Source' -AllowSlash
    foreach ($path in $Unit) {
        Assert-SafeRemoteName -Value $path -What 'Unit' -AllowSlash
    }
    $unitNames = @($Unit | ForEach-Object { ($_ -split '/')[-1] })
    if (@($unitNames | Select-Object -Unique).Count -ne $unitNames.Count) { throw 'Two -Unit files have the same name.' }
    if ([bool]$Vhost -ne [bool]$VhostPath) { throw 'Pass -Vhost and -VhostPath together.' }
    if ($Vhost) {
        Assert-SafeRemoteName -Value $Vhost -What 'Vhost' -AllowSlash
        Assert-RemotePath -Value $VhostPath -What 'VhostPath'
    }
    if ($EnvFile) { Assert-RemotePath -Value $EnvFile -What 'EnvFile' }
    if (-not $UnitBackupDirectory) { $UnitBackupDirectory = ($Binary -replace '/[^/]*$', '') }
    if (-not $UnitBackupDirectory) { $UnitBackupDirectory = '/' }
    $user, $group = Split-Owner -Owner $Owner
    if ($Database) {
        Assert-RemotePath -Value $Database -What 'Database'
        if (-not $SnapshotPrefix) { $SnapshotPrefix = "$Database.pre-" }
        if ("$SnapshotPrefix$SnapshotSuffix" -match "'") { throw 'The snapshot path cannot hold a single quote (it goes into sqlite3 .backup).' }
    }
    $snapshot = if ($Database) { $SnapshotPrefix + (Get-Date -Format 'yyyyMMdd-HHmmss') + $SnapshotSuffix } else { '' }

    $variable = [ordered]@{
        services    = $ServiceName -join ' '
        main        = $ServiceName[0]
        bin         = $Binary
        src         = $Source
        mode        = $Mode
        owner       = $user
        group       = $group
        units       = $Unit -join ' '
        unit_mode   = $UnitMode
        unit_dir    = $UnitBackupDirectory
        vhost       = $Vhost
        vhost_live  = $VhostPath
        reload_svc  = $ReloadService
        env_file    = $EnvFile
        health_wait = "$HealthTimeoutSeconds"
        settle      = "$SettleSeconds"
        umask_value = $Umask
        db          = $Database
        snap        = $snapshot
        snap_prefix = $SnapshotPrefix
        snap_suffix = $SnapshotSuffix
        restore_db  = if ($RestoreDatabaseOnRollback) { '1' } else { '' }
        no_backup   = if ($NoBackup) { '1' } else { '' }
    }
    $health = ConvertTo-HealthScript -Template $HealthUrl -Default $HealthDefault -EnvFile $EnvFile

    $check = @'
if [ -n "$umask_value" ]; then umask "$umask_value"; fi
old="$bin.old"
if [ ! -f "$bundle/$src" ]; then echo "The upload has no $src." >&2; exit 3; fi
for u in $units; do
  if [ ! -f "$bundle/$u" ]; then echo "The upload has no $u." >&2; exit 3; fi
done
rev=
service_units=
for s in $services; do rev="$s $rev"; service_units="$service_units $s.service"; done
vhost_changed=
if [ -n "$vhost" ]; then
  if [ ! -f "$bundle/$vhost" ]; then echo "The upload has no $vhost." >&2; exit 3; fi
  if cmp -s "$bundle/$vhost" "$vhost_live"; then
    rm -f "$vhost_live.old"
  else
    if [ -f "$vhost_live" ]; then cp -p "$vhost_live" "$vhost_live.old"; else rm -f "$vhost_live.old"; fi
    install -m 644 -o root -g root "$bundle/$vhost" "$vhost_live"
    if ! verdict=$(apachectl configtest 2>&1); then
      if [ -f "$vhost_live.old" ]; then mv -f "$vhost_live.old" "$vhost_live"; else rm -f "$vhost_live"; fi
      echo "Apache refused the new vhost, so the previous one is back and nothing else was changed:" >&2
      echo "$verdict" >&2
      exit 5
    fi
    vhost_changed=1
  fi
fi
for s in $rev; do systemctl stop "$s" 2>/dev/null || true; done
# Whatever fails from here to the start, the services come back up on what is in place,
# and a vhost Apache has not loaded yet goes back.
abort_restart() {
  if [ -n "$vhost_changed" ]; then
    if [ -f "$vhost_live.old" ]; then cp -p "$vhost_live.old" "$vhost_live"; else rm -f "$vhost_live"; fi
  fi
  for s in $services; do
    if [ "$s" = "$main" ] || systemctl is-enabled --quiet "$s" 2>/dev/null; then systemctl start "$s" >/dev/null 2>&1 || true; fi
  done
}
trap abort_restart EXIT
'@
    $install = @'
if [ -f "$bin" ]; then cp -p "$bin" "$old"; fi
if [ -n "$db" ] && [ -f "$db" ]; then
  mkdir -p "$(dirname "$snap")"
  sqlite3 "$db" ".backup '$snap'"
  ls -1t "$snap_prefix"*"$snap_suffix" 2>/dev/null | tail -n +4 | xargs -r -d '\n' rm -f --
  echo "Database snapshot: $snap"
fi
mkdir -p "$(dirname "$bin")" "$unit_dir"
changed_units=
new_units=
for u in $units; do
  name=$(basename "$u")
  live_unit="/etc/systemd/system/$name"
  saved="$unit_dir/$name.old"
  if cmp -s "$bundle/$u" "$live_unit"; then rm -f "$saved"; continue; fi
  if [ -f "$live_unit" ]; then cp -p "$live_unit" "$saved"; else rm -f "$saved"; new_units="$new_units $name"; fi
  install -m "$unit_mode" -o root -g root "$bundle/$u" "$live_unit"
  changed_units="$changed_units $name"
done
if [ -n "$changed_units" ]; then
  systemctl daemon-reload
  for s in $services; do
    case " $new_units " in *" $s.service "*) systemctl enable "$s" >/dev/null 2>&1 || true; continue ;; esac
    if [ "$s" = "$main" ]; then
      case " $changed_units " in *" $s.service "*) systemctl enable "$s" >/dev/null 2>&1 || true ;; esac
    fi
  done
fi
install -m "$mode" ${owner:+-o "$owner"} ${group:+-g "$group"} "$bundle/$src" "$bin"
'@
    $start = @'
started=
for s in $services; do
  if [ "$s" = "$main" ] || systemctl is-enabled --quiet "$s" 2>/dev/null; then started="$started $s"; fi
done
# A start that fails outright is left for the check below, which rolls back.
for s in $started; do systemctl restart "$s" || true; done
trap - EXIT
failed=
if [ -n "$health" ]; then
  up=
  i=0
  while [ "$i" -lt "$health_wait" ]; do
    if curl -fs -m 2 -o /dev/null "$health"; then up=1; break; fi
    i=$((i + 1))
    sleep 1
  done
  if [ -z "$up" ]; then failed="$main"; echo "$main did not answer $health within ${health_wait}s." >&2; fi
else
  sleep "$settle"
fi
for s in $started; do
  if [ -n "$health" ] && [ "$s" = "$main" ]; then continue; fi
  if ! systemctl is-active --quiet "$s"; then failed="$failed $s"; echo "$s did not stay active." >&2; fi
done
if [ -n "$failed" ]; then
  echo "Rolling back:$started" >&2
  for s in $failed; do journalctl -u "$s" -n 30 --no-pager >&2 || true; done
  for s in $rev; do systemctl stop "$s" || true; done
  if [ -f "$old" ]; then install -m "$mode" ${owner:+-o "$owner"} ${group:+-g "$group"} "$old" "$bin"; fi
  for name in $changed_units; do
    saved="$unit_dir/$name.old"
    if [ -f "$saved" ]; then cp -p "$saved" "/etc/systemd/system/$name"; else rm -f "/etc/systemd/system/$name"; fi
  done
  if [ -n "$changed_units" ]; then systemctl daemon-reload; fi
  if [ -n "$vhost_changed" ]; then
    if [ -f "$vhost_live.old" ]; then cp -p "$vhost_live.old" "$vhost_live"; else rm -f "$vhost_live"; fi
  fi
  if [ -n "$snap" ] && [ -f "$snap" ]; then
    if [ -n "$restore_db" ]; then
      rm -f "$db-wal" "$db-shm"
      cat "$snap" > "$db"
      echo 'The database is back as the snapshot before the deploy left it.' >&2
    else
      echo "If the previous binary refuses the database the new one migrated, put the snapshot back: systemctl stop $main && rm -f $db-wal $db-shm && cat $snap > $db && systemctl start $main" >&2
    fi
  fi
'@
    $restart = @'
  if [ -f "$old" ]; then for s in $started; do systemctl restart "$s" || true; done; fi
  exit 1
fi
if [ -n "$vhost_changed" ]; then
  if systemctl reload "$reload_svc"; then echo 'Apache took the new vhost.'; else echo "$reload_svc did not reload; the new vhost is in place but not live." >&2; fi
fi
for name in $changed_units; do
  case " $service_units " in *" $name "*) ;; *) systemctl try-restart "$name" || true ;; esac
done
'@
    $finish = @'
if [ -n "$no_backup" ]; then
  rm -f "$old"
  for name in $changed_units; do rm -f "$unit_dir/$name.old"; done
  if [ -n "$vhost_changed" ]; then rm -f "$vhost_live.old"; fi
fi
echo "Active:$started"
'@
    $step = Join-ShellScript -Variable $variable -Body @($health, $check, $AfterStop, $install, $BeforeStart, $start, $OnRollback, $restart, $AfterSuccess, $finish)
    if ($AsStep) { return $step }
    Invoke-DeployBundle -Archive $Archive -Sha256 $Sha256 -ExpectedFileCount $ExpectedFileCount -Step $step -AsScript:$AsScript -Connection $Connection -NoRetry:$NoRetry
}

function Restore-ServiceBinary {
    <#
    .SYNOPSIS
    Puts the previous binary, units, vhost and optionally database back after a deploy that came up but failed its smoke check.

    .DESCRIPTION
    The rollback Install-ServiceBinary does on its own when a service fails to start, as a
    step of its own for when the services start but the site is wrong. It stops the
    services, puts <Binary>.old back, puts back each listed unit and the vhost that have a
    .old copy from the last deploy, optionally the newest database snapshot, then starts
    the services and checks they are active. The scripts that kept a .old binary printed
    this as the manual rollback (Family Card Game, Marxbot, Nophica, Senpan). Needs the .old
    file, so it does nothing useful after Install-ServiceBinary -NoBackup. One connection.

    .PARAMETER ServiceName
    The systemd services, as given to Install-ServiceBinary.

    .PARAMETER Binary
    The live binary's path on the host.

    .PARAMETER Mode
    The restored binary's mode.

    .PARAMETER Owner
    user or user:group for the restored binary, as for Install-ServiceBinary.

    .PARAMETER Unit
    The units given to Install-ServiceBinary (paths in the upload, or names); each with a
    .old copy goes back.

    .PARAMETER UnitBackupDirectory
    Where the previous units are kept; by default the binary's folder.

    .PARAMETER VhostPath
    The live vhost; its .old copy, if any, goes back and Apache reloads.

    .PARAMETER ReloadService
    What reloads after the vhost goes back: apache2.

    .PARAMETER Database
    The live database to put back from the newest snapshot. Leave empty to keep the
    database as it is.

    .PARAMETER SnapshotPrefix
    The snapshots' path up to the time stamp; by default <Database>.pre-.

    .PARAMETER SnapshotSuffix
    What follows the time stamp.

    .PARAMETER SettleSeconds
    How long to wait before the is-active check.

    .PARAMETER OnRollback
    Shell run after everything is back, before the start.

    .PARAMETER AsScript
    Return the shell block instead of running it, to join with others in Invoke-RemoteStep.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    Invoke-SmokeCheck -Url 'https://example.com/' -Rollback { Restore-ServiceBinary -ServiceName 'example' -Binary '/opt/example/example' }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_.@-]+$')]
        [string[]]$ServiceName,

        [Parameter(Mandatory)]
        [string]$Binary,

        [ValidatePattern('^[0-7]{3,4}$')]
        [string]$Mode = '755',

        [string]$Owner,

        [string[]]$Unit = @(),

        [string]$UnitBackupDirectory,

        [string]$VhostPath,

        [ValidatePattern('^[A-Za-z0-9_.@-]+$')]
        [string]$ReloadService = 'apache2',

        [string]$Database,

        [string]$SnapshotPrefix,

        [string]$SnapshotSuffix = '',

        [ValidateRange(0, 3600)]
        [int]$SettleSeconds = 2,

        [string]$OnRollback,

        [switch]$AsScript,

        [object]$Connection,

        [switch]$NoRetry
    )
    Assert-RemotePath -Value $Binary -What 'Binary'
    foreach ($path in $Unit) { Assert-SafeRemoteName -Value $path -What 'Unit' -AllowSlash }
    if ($VhostPath) { Assert-RemotePath -Value $VhostPath -What 'VhostPath' }
    if (-not $UnitBackupDirectory) { $UnitBackupDirectory = ($Binary -replace '/[^/]*$', '') }
    if (-not $UnitBackupDirectory) { $UnitBackupDirectory = '/' }
    $user, $group = Split-Owner -Owner $Owner
    if ($Database -and -not $SnapshotPrefix) { $SnapshotPrefix = "$Database.pre-" }
    $variable = [ordered]@{
        services    = $ServiceName -join ' '
        main        = $ServiceName[0]
        bin         = $Binary
        mode        = $Mode
        owner       = $user
        group       = $group
        unit_names  = ($Unit | ForEach-Object { ($_ -split '/')[-1] }) -join ' '
        unit_dir    = $UnitBackupDirectory
        vhost_live  = $VhostPath
        reload_svc  = $ReloadService
        db          = $Database
        snap_prefix = $SnapshotPrefix
        snap_suffix = $SnapshotSuffix
        settle      = "$SettleSeconds"
    }
    $restore = @'
old="$bin.old"
if [ ! -f "$old" ]; then echo "No previous binary at $old; nothing to roll back to." >&2; exit 3; fi
rev=
for s in $services; do rev="$s $rev"; done
for s in $rev; do systemctl stop "$s" || true; done
install -m "$mode" ${owner:+-o "$owner"} ${group:+-g "$group"} "$old" "$bin"
reload=
for name in $unit_names; do
  saved="$unit_dir/$name.old"
  if [ -f "$saved" ]; then cp -p "$saved" "/etc/systemd/system/$name"; reload=1; fi
done
if [ -n "$reload" ]; then systemctl daemon-reload; fi
if [ -n "$vhost_live" ] && [ -f "$vhost_live.old" ]; then
  cp -p "$vhost_live.old" "$vhost_live"
  systemctl reload "$reload_svc" || echo "$reload_svc did not reload after the vhost went back." >&2
fi
if [ -n "$db" ]; then
  snap=$(ls -1t "$snap_prefix"*"$snap_suffix" 2>/dev/null | head -n 1)
  if [ -n "$snap" ]; then
    rm -f "$db-wal" "$db-shm"
    cat "$snap" > "$db"
    echo "Database restored from $snap"
  else
    echo "No snapshot matches $snap_prefix*$snap_suffix; the database is left as it is." >&2
  fi
fi
'@
    $start = @'
started=
for s in $services; do
  if [ "$s" = "$main" ] || systemctl is-enabled --quiet "$s" 2>/dev/null; then started="$started $s"; fi
done
for s in $started; do systemctl restart "$s" || true; done
sleep "$settle"
down=
for s in $started; do
  if ! systemctl is-active --quiet "$s"; then down="$down $s"; journalctl -u "$s" -n 30 --no-pager >&2 || true; fi
done
if [ -n "$down" ]; then echo "Did not come back up on the previous binary:$down" >&2; exit 1; fi
echo "Back on the previous binary:$started"
'@
    $script = Join-ShellScript -Variable $variable -Body @($restore, $OnRollback, $start)
    if ($AsScript) { return $script }
    Invoke-RemoteFlow -Connection $Connection -Script $script -NoRetry:$NoRetry -FailureMessage "Rolling $($ServiceName -join ', ') back failed on the host"
}

#endregion

#region Folder swaps

function Switch-RemoteDirectory {
    <#
    .SYNOPSIS
    From the checked upload: swap a folder into place by renames, keeping the previous one as <Live>.old, and put it back if a later step fails.

    .DESCRIPTION
    The swap Fantasy Dossier, Fingerprint Generator, Senpan (frontend) and TarotGen.io
    (frontend and plugin) each write, and the one What Do I Know (its plugin or theme
    folder) and IDE Resume Site (its files, moved into a folder of their own) move to
    (decided 2026-11-05). The folder always arrives in the deploy's one archive, checked by
    SHA-256 and file count before anything changes (decided 2026-11-05); the folder
    upload with pscp -r is gone. Then:
      - the new folder moves beside the live one as <Live>.new (so the swap itself is two
        renames on one filesystem) and, with -Owner, is given to that owner;
      - -BeforeSwap runs on it; a failure leaves the live folder untouched;
      - <Live> becomes <Live>.old and the new folder becomes <Live>; if that last rename
        fails, the old folder is put back (Fantasy Dossier);
      - each -File moves into place too, its previous copy kept as .old (Fantasy Dossier's .htaccess);
      - -AfterSwap runs; if it fails, the previous folder and files go back.
    A run cut off between the two renames is noticed by the next and the live folder put back first.

    Hooks run under set -e with these shell variables set: live, new, old, bundle.

    .PARAMETER Live
    The live folder on the host, such as /var/www/example.com/dist.

    .PARAMETER Item
    The folder inside the upload that becomes <Live>; by default Live's own name.

    .PARAMETER File
    Single files to move into place in the same step: each key is the file's path inside
    the upload, each value its live path. A file missing from the upload is skipped.

    .PARAMETER Owner
    user or user:group given the new folder and files before the swap (What Do I Know: www-data).

    .PARAMETER BeforeSwap
    Shell run on the new folder ($new) before the swap, such as IDE Resume Site's php -l.

    .PARAMETER AfterSwap
    Shell run after the swap, such as What Do I Know's grav clearcache; a failure swaps back.

    .PARAMETER NoBackup
    Remove <Live>.old and the files' .old copies once the swap is done. Restore-RemoteDirectory
    then has nothing to go back to.

    .PARAMETER Archive
    The uploaded archive, when this runs on its own rather than as one step of Invoke-DeployBundle.

    .PARAMETER Sha256
    The archive's SHA-256.

    .PARAMETER ExpectedFileCount
    How many files the archive holds.

    .PARAMETER AsStep
    Return the step for Invoke-DeployBundle instead of running it.

    .PARAMETER AsScript
    Return the whole remote script instead of running it.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    Switch-RemoteDirectory -Archive 'example-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
        -Live '/var/www/example.com/dist' -File @{ '.htaccess' = '/var/www/example.com/.htaccess' }
    #>
    [CmdletBinding(DefaultParameterSetName = 'Archive')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Live,

        [string]$Item,

        [System.Collections.IDictionary]$File = @{},

        [string]$Owner,

        [string]$BeforeSwap,

        [string]$AfterSwap,

        [switch]$NoBackup,

        [Parameter(Mandatory, ParameterSetName = 'Archive')]
        [string]$Archive,

        [Parameter(Mandatory, ParameterSetName = 'Archive')]
        [ValidatePattern('^[0-9a-fA-F]{64}$')]
        [string]$Sha256,

        [Parameter(Mandatory, ParameterSetName = 'Archive')]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$ExpectedFileCount,

        [Parameter(ParameterSetName = 'Step')]
        [switch]$AsStep,

        [Parameter(ParameterSetName = 'Archive')]
        [switch]$AsScript,

        [Parameter(ParameterSetName = 'Archive')]
        [object]$Connection,

        [Parameter(ParameterSetName = 'Archive')]
        [switch]$NoRetry
    )
    $swap = @{
        Live       = $Live
        Item       = $Item
        File       = $File
        Owner      = $Owner
        BeforeSwap = $BeforeSwap
        AfterSwap  = $AfterSwap
        NoBackup   = $NoBackup
    }
    $step = Get-DirectorySwapStep @swap
    if ($AsStep) { return $step }
    Invoke-DeployBundle -Archive $Archive -Sha256 $Sha256 -ExpectedFileCount $ExpectedFileCount -Step $step -AsScript:$AsScript -Connection $Connection -NoRetry:$NoRetry
}

function Restore-RemoteDirectory {
    <#
    .SYNOPSIS
    Puts <Live>.old back as <Live>, after a swap that went in but failed its smoke check.

    .DESCRIPTION
    The rollback Fantasy Dossier, Fingerprint Generator, Senpan and TarotGen.io printed for
    the owner to run by hand, done by renames: the failed folder is moved aside and removed
    only once the old one is back. (Their printed mv '<Live>.old' '<Live>' moved the old
    folder inside the live one while that existed.) Each -File gets its .old copy back too.
    One connection.

    .PARAMETER Live
    The live folder on the host.

    .PARAMETER File
    Live files whose .old copies go back, such as an .htaccess swapped with the folder.

    .PARAMETER AsScript
    Return the shell block instead of running it, to join with others in Invoke-RemoteStep.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    Restore-RemoteDirectory -Live '/var/www/example.com/dist' -File '/var/www/example.com/.htaccess'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Live,

        [string[]]$File = @(),

        [switch]$AsScript,

        [object]$Connection,

        [switch]$NoRetry
    )
    $Live = $Live.TrimEnd('/')
    Assert-RemotePath -Value $Live -What 'Live'
    foreach ($path in $File) { Assert-RemotePath -Value $path -What 'File' }
    $variable = [ordered]@{ live = $Live }
    $restore = @'
old="$live.old"
failed="$live.failed"
if [ ! -d "$old" ]; then echo "No previous copy at $old; nothing to roll back to." >&2; exit 3; fi
rm -rf "$failed"
if [ -d "$live" ]; then mv "$live" "$failed"; fi
mv "$old" "$live"
rm -rf "$failed"
'@
    $files = foreach ($path in $File) {
        $q = ConvertTo-ShellLiteral -Value $path
        "if [ -f $q.old ]; then mv -f $q.old $q; fi"
    }
    $script = Join-ShellScript -Variable $variable -Body (@($restore) + @($files) + @('echo "Rolled $live back to the previous copy."'))
    if ($AsScript) { return $script }
    Invoke-RemoteFlow -Connection $Connection -Script $script -NoRetry:$NoRetry -FailureMessage "Rolling $Live back failed on the host"
}

function Switch-RemoteItemSet {
    <#
    .SYNOPSIS
    From the checked upload: swap a set of top-level files and folders into place by renames, and put the old ones back if a later step fails.

    .DESCRIPTION
    For sites whose code is several entries in one folder rather than one folder of its
    own. Simple Image Gallery's swap with TarotGen.io's refusal of a missing entry
    (confirmed 2026-11-05):
      - the listed entries move from the upload into a staging folder inside Root, so the
        swap is renames on one filesystem;
      - -Prepare runs on the staging folder, still beside the live site (copy vendor/,
        run composer);
      - every listed entry must then be in the staging folder, or the deploy stops with the
        live site untouched;
      - each live entry moves into the backup folder and its new one takes its place;
      - -AfterSwap runs (migrate, optimize); if it or anything after the swap fails, a trap
        moves the previous entries back and runs -OnRestore.

    Hooks run from Root under set -e with these shell variables set: root, stage, backup, bundle.

    .PARAMETER Root
    The folder on the host holding the entries, such as the Laravel app's folder.

    .PARAMETER Item
    The top-level entries that make up the code, such as app, config, public, composer.json.

    .PARAMETER Source
    The folder inside the upload that holds the entries; by default the upload's top.

    .PARAMETER Staging
    The staging folder, relative to Root; the Gallery's .deploy-next by default.

    .PARAMETER Backup
    The backup folder, relative to Root; the Gallery's .deploy-backup by default.

    .PARAMETER Prepare
    Shell run on the staging folder before the swap.

    .PARAMETER AfterSwap
    Shell run after the swap; a failure here puts the previous entries back.

    .PARAMETER OnRestore
    Shell run after the previous entries are put back (the Gallery restarts its queue).

    .PARAMETER NoBackup
    Remove the backup folder once everything has succeeded.

    .PARAMETER Archive
    The uploaded archive, when this runs on its own rather than as one step of Invoke-DeployBundle.

    .PARAMETER Sha256
    The archive's SHA-256.

    .PARAMETER ExpectedFileCount
    How many files the archive holds.

    .PARAMETER AsStep
    Return the step for Invoke-DeployBundle instead of running it.

    .PARAMETER AsScript
    Return the whole remote script instead of running it.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    Switch-RemoteItemSet -Archive 'example-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
        -Root '/var/www/example.com' -Item 'app', 'config', 'public', 'composer.json' -AfterSwap 'php artisan migrate --force'
    #>
    [CmdletBinding(DefaultParameterSetName = 'Archive')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string[]]$Item,

        [string]$Source,

        [string]$Staging = '.deploy-next',

        [string]$Backup = '.deploy-backup',

        [string]$Prepare,

        [string]$AfterSwap,

        [string]$OnRestore,

        [switch]$NoBackup,

        [Parameter(Mandatory, ParameterSetName = 'Archive')]
        [string]$Archive,

        [Parameter(Mandatory, ParameterSetName = 'Archive')]
        [ValidatePattern('^[0-9a-fA-F]{64}$')]
        [string]$Sha256,

        [Parameter(Mandatory, ParameterSetName = 'Archive')]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$ExpectedFileCount,

        [Parameter(ParameterSetName = 'Step')]
        [switch]$AsStep,

        [Parameter(ParameterSetName = 'Archive')]
        [switch]$AsScript,

        [Parameter(ParameterSetName = 'Archive')]
        [object]$Connection,

        [Parameter(ParameterSetName = 'Archive')]
        [switch]$NoRetry
    )
    Assert-RemotePath -Value $Root -What 'Root'
    foreach ($name in $Item) { Assert-SafeRemoteName -Value $name -What 'Item' }
    if ($Source) { Assert-SafeRemoteName -Value $Source -What 'Source' -AllowSlash }
    Assert-SafeRemoteName -Value $Staging -What 'Staging' -AllowSlash
    Assert-SafeRemoteName -Value $Backup -What 'Backup' -AllowSlash

    $variable = [ordered]@{
        root      = $Root
        source    = if ($Source) { $Source } else { '.' }
        stage     = $Staging
        backup    = $Backup
        items     = $Item -join ' '
        no_backup = if ($NoBackup) { '1' } else { '' }
    }
    $begin = @'
src="$bundle/$source"
cd "$root" || { echo "Cannot enter $root." >&2; exit 2; }
swapped=
success=
finish() {
  rc=$?
  rm -rf "$stage"
  if [ -n "$success" ]; then exit 0; fi
  if [ -n "$swapped" ]; then
    echo "The deploy failed (exit $rc); putting the previous items back from $backup." >&2
    for p in $items; do
      if [ -e "$backup/$p" ] || [ -L "$backup/$p" ]; then rm -rf "$p"; mv "$backup/$p" "$p"; fi
    done
'@
    $restoreEnd = @'
  else
    echo "The deploy failed (exit $rc) before the swap; the live items were not touched." >&2
  fi
  exit "$rc"
}
trap finish EXIT
rm -rf "$stage"
mkdir -p "$stage"
for p in $items; do
  if [ -e "$src/$p" ] || [ -L "$src/$p" ]; then mv "$src/$p" "$stage/$p"; fi
done
'@
    $swap = @'
for p in $items; do
  if [ ! -e "$stage/$p" ] && [ ! -L "$stage/$p" ]; then echo "Missing from the new set: $p" >&2; exit 3; fi
done
rm -rf "$backup"
mkdir -p "$backup"
swapped=1
for p in $items; do
  if [ -e "$p" ] || [ -L "$p" ]; then mv "$p" "$backup/$p"; fi
  mv "$stage/$p" "$p"
done
'@
    $finish = @'
success=1
if [ -n "$no_backup" ]; then rm -rf "$backup"; fi
echo "Swapped the new items into $root."
'@
    $step = Join-ShellScript -Variable $variable -Body @($begin, $OnRestore, $restoreEnd, $Prepare, $swap, $AfterSwap, $finish)
    if ($AsStep) { return $step }
    Invoke-DeployBundle -Archive $Archive -Sha256 $Sha256 -ExpectedFileCount $ExpectedFileCount -Step $step -AsScript:$AsScript -Connection $Connection -NoRetry:$NoRetry
}

function Restore-RemoteItemSet {
    <#
    .SYNOPSIS
    Puts the items Switch-RemoteItemSet moved into its backup folder back, after a deploy that failed its smoke check.

    .DESCRIPTION
    The rollback Simple Image Gallery's trap does, as a step of its own. Each item found
    in the backup folder replaces the live one; items not in the backup stay as they are.
    Simple Image Gallery and TarotGen.io printed their rollback for the owner to run
    instead. One connection.

    .PARAMETER Root
    The folder on the host holding the items.

    .PARAMETER Item
    The top-level entries to put back.

    .PARAMETER Backup
    The backup folder, relative to Root.

    .PARAMETER OnRestore
    Shell run, from Root, after the items are back.

    .PARAMETER AsScript
    Return the shell block instead of running it, to join with others in Invoke-RemoteStep.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    Restore-RemoteItemSet -Root '/var/www/example.com' -Item 'app', 'config', 'public' -OnRestore 'php artisan queue:restart'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string[]]$Item,

        [string]$Backup = '.deploy-backup',

        [string]$OnRestore,

        [switch]$AsScript,

        [object]$Connection,

        [switch]$NoRetry
    )
    Assert-RemotePath -Value $Root -What 'Root'
    foreach ($name in $Item) { Assert-SafeRemoteName -Value $name -What 'Item' }
    Assert-SafeRemoteName -Value $Backup -What 'Backup' -AllowSlash
    $variable = [ordered]@{
        root   = $Root
        backup = $Backup
        items  = $Item -join ' '
    }
    $restore = @'
cd "$root" || { echo "Cannot enter $root." >&2; exit 2; }
if [ ! -d "$backup" ]; then echo "No previous items at $root/$backup; nothing to roll back to." >&2; exit 3; fi
for p in $items; do
  if [ -e "$backup/$p" ] || [ -L "$backup/$p" ]; then rm -rf "$p"; mv "$backup/$p" "$p"; fi
done
'@
    $script = Join-ShellScript -Variable $variable -Body @($restore, $OnRestore, 'echo "Put the previous items back in $root."')
    if ($AsScript) { return $script }
    Invoke-RemoteFlow -Connection $Connection -Script $script -NoRetry:$NoRetry -FailureMessage "Rolling the items in $Root back failed on the host"
}

#endregion

#region Plugin publishing

function Export-PluginRepository {
    <#
    .SYNOPSIS
    Lays out a Dalamud plugin repository folder locally: the package, its files and the repo index, with the versions checked and the download links cache-busted.

    .DESCRIPTION
    The local half of plugin publishing, for all four plugins (decided 2026-11-05). It reads
    the version DalamudPackager built into the manifest, and refuses to go on unless the
    repo index carries the same version, since Dalamud refuses an update whose package does
    not match its index. The index is either the project's own file (Senpan's and Venue
    Tools' pluginmaster.json; Kindred Nights publishes the built manifest itself, which its
    server reads) or written from the built manifest with download and icon links
    (TarotGen.io's repo.json). Download links to the package get ?v=<version>, so an edge
    cache serves each release under a new address (Senpan, Venue Tools, TarotGen.io).

    The result's Path goes into the deploy archive (Compress-DeployArchive), and its Version
    to Publish-PluginRepository, which also checks it is higher than the one published.

    .PARAMETER Manifest
    The built manifest DalamudPackager wrote beside latest.zip, such as bin/Release/Example/Example.json.

    .PARAMETER File
    An ordered dictionary of the repository's files: each key its path in the repository
    (such as Example/latest.zip, icon.png, .htaccess), each value the local file.

    .PARAMETER IndexPath
    The index's path in the repository: pluginmaster.json, repo.json, or (Kindred Nights)
    the manifest's own name.

    .PARAMETER IndexSource
    The project's own index file to publish. Its AssemblyVersion must equal the built one.

    .PARAMETER BaseUrl
    With no -IndexSource: the public address of the repository folder, for the index's
    download and icon links. It comes from the project, never from this module.

    .PARAMETER PackagePath
    The package's path in the repository; by default the .zip in -File.

    .PARAMETER IconPath
    With -BaseUrl: the icon's path in the repository, for IconUrl.

    .PARAMETER Destination
    The local folder to lay out; by default a new one in the temp folder.

    .EXAMPLE
    $repo = Export-PluginRepository -Manifest $built -IndexPath 'pluginmaster.json' -IndexSource (Join-Path $repoRoot 'pluginmaster.json') `
        -File ([ordered]@{ 'Example/latest.zip' = $zip; '.htaccess' = $htaccess })
    #>
    [CmdletBinding(DefaultParameterSetName = 'Index')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Manifest,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$File,

        [Parameter(Mandatory)]
        [string]$IndexPath,

        [Parameter(Mandatory, ParameterSetName = 'Index')]
        [string]$IndexSource,

        [Parameter(Mandatory, ParameterSetName = 'Generate')]
        [string]$BaseUrl,

        [string]$PackagePath,

        [Parameter(ParameterSetName = 'Generate')]
        [string]$IconPath,

        [string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Manifest)) { throw "Not built: $Manifest" }
    $manifestText = Get-Content -LiteralPath $Manifest -Raw
    $version = Get-AssemblyVersion -Text $manifestText
    if ($version -notmatch '^\d+(\.\d+){1,3}$') { throw "The built manifest has no usable AssemblyVersion: '$version' ($Manifest)." }
    Assert-SafeRemoteName -Value $IndexPath -What 'IndexPath' -AllowSlash
    foreach ($name in $File.Keys) {
        Assert-SafeRemoteName -Value $name -What 'Repository path' -AllowSlash
        if (-not (Test-Path -LiteralPath ([string]$File[$name]))) { throw "Not found: $($File[$name]) (for $name)." }
    }
    if ($File.Contains($IndexPath)) { throw "$IndexPath is written from the index; leave it out of -File." }
    if (-not $PackagePath) { $PackagePath = @($File.Keys | Where-Object { $_ -like '*.zip' })[0] }
    if (-not $PackagePath -or -not $File.Contains($PackagePath)) { throw 'Name the plugin package (.zip) in -File, or pass -PackagePath.' }
    $packageLeaf = ($PackagePath -split '/')[-1]

    if ($PSCmdlet.ParameterSetName -eq 'Index') {
        if (-not (Test-Path -LiteralPath $IndexSource)) { throw "Index not found: $IndexSource" }
        $index = Get-Content -LiteralPath $IndexSource -Raw
        $indexVersion = Get-AssemblyVersion -Text $index
        if ($indexVersion -ne $version) {
            throw "Version mismatch: the built package is $version but $(Split-Path -Path $IndexSource -Leaf) says '$indexVersion'. Set its AssemblyVersion (and LastUpdate) to $version, then re-run."
        }
        $index = [regex]::Replace($index, ([regex]::Escape($packageLeaf) + '(\?v=[^"\s]*)?'), "${packageLeaf}?v=$version")
    } else {
        if ($IconPath -and -not $File.Contains($IconPath)) { throw "-IconPath $IconPath is not in -File." }
        $entry = $manifestText | ConvertFrom-Json
        $base = $BaseUrl.TrimEnd('/')
        $packageUrl = "$base/$PackagePath`?v=$version"
        foreach ($link in 'DownloadLinkInstall', 'DownloadLinkUpdate', 'DownloadLinkTesting') {
            $entry | Add-Member -NotePropertyName $link -NotePropertyValue $packageUrl -Force
        }
        if ($IconPath) { $entry | Add-Member -NotePropertyName 'IconUrl' -NotePropertyValue "$base/$IconPath" -Force }
        $index = ConvertTo-Json -InputObject @($entry) -Depth 12
    }

    if (-not $Destination) {
        $Destination = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('plugin-repo-{0}' -f [guid]::NewGuid())
    }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $Destination
    foreach ($name in @($File.Keys) + @($IndexPath)) {
        $to = Join-Path -Path $Destination -ChildPath $name
        $parent = Split-Path -Path $to -Parent
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        if ($name -eq $IndexPath) {
            [System.IO.File]::WriteAllText($to, $index)
        } else {
            Copy-Item -LiteralPath ([string]$File[$name]) -Destination $to
        }
    }
    Write-Ok "Plugin repository laid out: v$version, $($File.Count + 1) files"
    [pscustomobject]@{
        Path      = $Destination
        Version   = $version
        IndexPath = $IndexPath
    }
}

function Publish-PluginRepository {
    <#
    .SYNOPSIS
    From the checked upload: refuse a plugin version that is not higher than the published one, then swap the repository folder into place.

    .DESCRIPTION
    The host half of plugin publishing, for all four plugins (decided 2026-11-05). Before
    anything changes it reads the version in the uploaded index, which must equal -Version,
    and the version in the live index, which -Version must be higher than (Kindred Nights'
    check; Dalamud updates to nothing else). A first publish, with nothing live yet,
    passes. Then the whole repository folder swaps in as Switch-RemoteDirectory does,
    keeping the previous as <Live>.old, so no file is ever written straight onto a live one
    (Venue Tools wrote onto them; Senpan renamed each file in after a hash check).

    Swapping the whole folder replaces everything in it: check before the first run that
    the live folder holds only this plugin's files.

    .PARAMETER Live
    The live repository folder, such as /var/www/example.com/plugin.

    .PARAMETER Version
    The version being published (Export-PluginRepository returns it).

    .PARAMETER IndexPath
    The index's path in the repository, read in both the upload and the live folder.

    .PARAMETER Item
    The repository folder inside the upload; by default Live's own name.

    .PARAMETER Owner
    user or user:group given the new folder (Kindred Nights: the service's user, whose
    server reads it).

    .PARAMETER AfterSwap
    Shell run after the swap, such as a check that the server now lists the version; a failure swaps back.

    .PARAMETER NoBackup
    Remove <Live>.old once the swap is done (TarotGen.io keeps no previous plugin folder).

    .PARAMETER Archive
    The uploaded archive, when this runs on its own rather than as one step of Invoke-DeployBundle.

    .PARAMETER Sha256
    The archive's SHA-256.

    .PARAMETER ExpectedFileCount
    How many files the archive holds.

    .PARAMETER AsStep
    Return the step for Invoke-DeployBundle instead of running it.

    .PARAMETER AsScript
    Return the whole remote script instead of running it.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    Publish-PluginRepository -Archive 'plugin-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
        -Live '/var/www/example.com/plugins' -Version $repo.Version -IndexPath 'pluginmaster.json'
    #>
    [CmdletBinding(DefaultParameterSetName = 'Archive')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Live,

        [Parameter(Mandatory)]
        [ValidatePattern('^\d+(\.\d+){1,3}$')]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$IndexPath,

        [string]$Item,

        [string]$Owner,

        [string]$AfterSwap,

        [switch]$NoBackup,

        [Parameter(Mandatory, ParameterSetName = 'Archive')]
        [string]$Archive,

        [Parameter(Mandatory, ParameterSetName = 'Archive')]
        [ValidatePattern('^[0-9a-fA-F]{64}$')]
        [string]$Sha256,

        [Parameter(Mandatory, ParameterSetName = 'Archive')]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$ExpectedFileCount,

        [Parameter(ParameterSetName = 'Step')]
        [switch]$AsStep,

        [Parameter(ParameterSetName = 'Archive')]
        [switch]$AsScript,

        [Parameter(ParameterSetName = 'Archive')]
        [object]$Connection,

        [Parameter(ParameterSetName = 'Archive')]
        [switch]$NoRetry
    )
    Assert-SafeRemoteName -Value $IndexPath -What 'IndexPath' -AllowSlash
    $check = @'
read_version() { sed -n 's/.*"AssemblyVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n 1; }
uploaded=$(read_version "$src/$index")
if [ "$uploaded" != "$version" ]; then echo "The uploaded $index says '$uploaded', not $version; nothing was changed." >&2; exit 3; fi
published=$(read_version "$live/$index")
if [ -n "$published" ] && [ "$(printf '%s\n%s\n' "$published" "$version" | sort -V | tail -n 1)" = "$published" ]; then
  echo "Version $version is not higher than the published $published, and Dalamud updates to nothing else. Raise the plugin's version; nothing was changed." >&2
  exit 3
fi
echo "Publishing $version (published now: ${published:-none})."
'@
    $swap = @{
        Live          = $Live
        Item          = $Item
        File          = @{}
        Owner         = $Owner
        AfterSwap     = $AfterSwap
        NoBackup      = $NoBackup
        ExtraVariable = [ordered]@{ index = $IndexPath; version = $Version }
        Check         = $check
    }
    $step = Get-DirectorySwapStep @swap
    if ($AsStep) { return $step }
    Invoke-DeployBundle -Archive $Archive -Sha256 $Sha256 -ExpectedFileCount $ExpectedFileCount -Step $step -AsScript:$AsScript -Connection $Connection -NoRetry:$NoRetry
}

#endregion

#region Development database

function Copy-LiveDatabase {
    <#
    .SYNOPSIS
    Pulls a copy of the live SQLite database for development: an online snapshot on the host, a download, three timestamped local copies kept, the host's copy removed.

    .DESCRIPTION
    The dev-database pull Kindred Nights, Home Library and Senpan each write, settled
    (decided 2026-11-05):
      - if the local database is open (a dev server is running), it warns and skips, before
        any connection;
      - sqlite3 .backup takes a consistent snapshot on the host while the service keeps
        running (Kindred Nights, Home Library; Senpan stopped the service for a cp), under
        umask 077, since it holds live accounts and secrets;
      - the snapshot is downloaded beside the local database, then the current local copy is
        moved to <Destination>.bak-<time> and the download takes its place, with any stale
        -wal and -shm removed; the newest three .bak copies are kept (Senpan);
      - the host's snapshot is removed whether or not the download worked.
    Returns $true when the local database was refreshed. Every call rides the connection
    Open-DeployConnection holds, so the pull opens no connection of its own.

    .PARAMETER Database
    The live database on the host.

    .PARAMETER Destination
    The local development database, such as devdata/example.sqlite.

    .PARAMETER Snapshot
    Where the snapshot is made on the host; by default <Database>.pull.

    .PARAMETER Connection
    The connection to use; by default the one Open-DeployConnection stored.

    .PARAMETER NoRetry
    Never retry, even after a dropped connection.

    .EXAMPLE
    if (-not $NoDbPull) { $null = Copy-LiveDatabase -Database '/opt/example/data/example.sqlite' -Destination (Join-Path $repoRoot 'devdata/example.sqlite') }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Database,

        [Parameter(Mandatory)]
        [string]$Destination,

        [string]$Snapshot,

        [object]$Connection,

        [switch]$NoRetry
    )
    Assert-RemotePath -Value $Database -What 'Database'
    if (-not $Snapshot) { $Snapshot = "$Database.pull" }
    Assert-RemotePath -Value $Snapshot -What 'Snapshot'
    if ($Snapshot -match "'") { throw 'The snapshot path cannot hold a single quote (it goes into sqlite3 .backup).' }
    if (Test-FileInUse -Path $Destination) {
        Write-Warning "The local database is in use (stop the dev server to refresh it): $Destination. The pull was skipped."
        return $false
    }
    $active = Get-ActiveConnection -Connection $Connection
    $db = ConvertTo-ShellLiteral -Value $Database
    $snap = ConvertTo-ShellLiteral -Value $Snapshot
    Write-Step 'Taking an online snapshot of the live database...'
    $take = @"
set -e
umask 077
if [ ! -f $db ]; then echo no-database; exit 0; fi
mkdir -p "`$(dirname $snap)"
rm -f $snap
sqlite3 $db ".backup '$Snapshot'"
echo snapshot-ok
"@
    $lines = Invoke-Remote -Script $take -Connection $active -NoRetry:$NoRetry
    if ($lines -notcontains 'snapshot-ok') {
        Write-Host '    No database on the host yet; skipping the pull.'
        return $false
    }
    $download = "$Destination.download"
    try {
        $folder = Split-Path -Path $Destination -Parent
        if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
        Write-Step "Downloading the snapshot -> $Destination ..."
        if (-not (Get-File -Source $Snapshot -Destination $download -Connection $active -NoRetry:$NoRetry)) {
            Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
            throw 'The snapshot could not be downloaded; the local database was not changed.'
        }
        if (Test-Path -LiteralPath $Destination) {
            try {
                Move-Item -LiteralPath $Destination -Destination ('{0}.bak-{1}' -f $Destination, (Get-Date -Format 'yyyyMMdd-HHmmss'))
            } catch {
                Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
                Write-Warning "The local database is in use (stop the dev server to refresh it): $Destination. The pull was skipped."
                return $false
            }
        }
        Remove-Item -LiteralPath "$Destination-wal", "$Destination-shm" -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $download -Destination $Destination
        $leaf = Split-Path -Path $Destination -Leaf
        $stale = @(Get-ChildItem -LiteralPath $folder -Filter "$leaf.bak-*" -File | Sort-Object -Property Name -Descending | Select-Object -Skip $script:SnapshotKeep)
        $stale | Remove-Item -Force
        Write-Ok "Local database refreshed: $Destination (previous copies kept as $leaf.bak-<time>, newest $($script:SnapshotKeep); they hold live data, keep them local)."
        $true
    } finally {
        $cleanup = Invoke-RemoteCore -Connection $active -Script "rm -f $snap" -NoRetry:$NoRetry
        if ($cleanup.ExitCode -ne 0) { Write-Warning "The snapshot on the host could not be removed: $Snapshot" }
    }
}

#endregion

#region Smoke check

function Invoke-SmokeCheck {
    <#
    .SYNOPSIS
    Fetches each listed URL from this machine, checks its status and optional text, and rolls back and throws if any fails.

    .DESCRIPTION
    The shared smoke step, built from the checks the scripts already make after a deploy:
      - IDE Resume Site fetches its page and contact.php from here (Invoke-WebRequest, 20
        seconds, status not treated as an error), expects 200 and 405, and expects the
        page to contain the Vue version it ships;
      - Home Library asks /healthz on the host once a second for up to 30 seconds;
      - Conlang Translator posts a test translation on the host and looks for the
        expected words, also for up to 30 seconds;
      - Kindred Nights' plugin publish looks for the new version in repo.json;
      - Simple Image Gallery prints its health URL's status without acting on it.
    Each check is a URL with an expected status (200 unless given) and, optionally, text
    the body must contain (case-sensitive, as grep). A check is tried up to -Attempts
    times, -DelaySeconds apart. A line is printed for each.

    A failed smoke check rolls back automatically (decided 2026-11-05): pass -Rollback with
    what puts the previous release back, or -NoRollback for a deploy with nothing to undo;
    it throws if given neither or both. When a check fails, -Rollback runs and the function
    throws, so the caller stops; with -PassThru it returns each result (Url, Method,
    Status, Ok, Reason) instead of throwing, after the rollback.

    .PARAMETER Url
    URLs that must answer 200.

    .PARAMETER Check
    One hashtable per check: Url (required), Status (a code or a list, default 200),
    Contains (text the body must hold), Method (default GET), Body and ContentType (for a
    POST like Conlang Translator's).

    .PARAMETER Attempts
    How many times to try each URL before it counts as failed.

    .PARAMETER DelaySeconds
    The wait between attempts.

    .PARAMETER TimeoutSec
    The limit for each request; IDE Resume Site uses 20.

    .PARAMETER Rollback
    What puts the previous release back, run when a check fails, such as
    { Restore-RemoteDirectory -Live $live }.

    .PARAMETER NoRollback
    Say there is nothing to undo; a failure only throws.

    .PARAMETER PassThru
    Return the results, and do not throw on a failure.

    .EXAMPLE
    Invoke-SmokeCheck -Url 'https://example.com/' -Rollback { Restore-RemoteDirectory -Live '/var/www/example.com/dist' }

    .EXAMPLE
    Invoke-SmokeCheck -Check @(
        @{ Url = 'https://example.com/'; Contains = 'vue@3.5.0/' }
        @{ Url = 'https://example.com/contact.php'; Status = 405 }
    ) -NoRollback
    #>
    [CmdletBinding(DefaultParameterSetName = 'Url')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Url')]
        [string[]]$Url,

        [Parameter(Mandatory, ParameterSetName = 'Check')]
        [hashtable[]]$Check,

        [ValidateRange(1, 600)]
        [int]$Attempts = 1,

        [ValidateRange(0, 600)]
        [int]$DelaySeconds = 1,

        [ValidateRange(1, 600)]
        [int]$TimeoutSec = 20,

        [scriptblock]$Rollback,

        [switch]$NoRollback,

        [switch]$PassThru
    )
    if ($Rollback -and $NoRollback) { throw 'Pass -Rollback or -NoRollback, not both.' }
    if (-not $Rollback -and -not $NoRollback) {
        throw 'A failed smoke check rolls back (decided 2026-11-05): pass -Rollback with what puts the previous release back, or -NoRollback for a deploy with nothing to undo.'
    }
    $ProgressPreference = 'SilentlyContinue'
    $checks = if ($PSCmdlet.ParameterSetName -eq 'Url') { $Url | ForEach-Object { @{ Url = $_ } } } else { $Check }

    $results = foreach ($entry in $checks) {
        if (-not $entry['Url']) { throw 'Every smoke check needs a Url.' }
        $method = if ($entry['Method']) { [string]$entry['Method'] } else { 'GET' }
        $expected = if ($entry.ContainsKey('Status')) { @($entry['Status'] | ForEach-Object { [int]$_ }) } else { @(200) }
        $text = [string]$entry['Contains']
        $request = @{
            Uri                = [string]$entry['Url']
            Method             = $method
            TimeoutSec         = $TimeoutSec
            SkipHttpErrorCheck = $true
        }
        if ($entry.ContainsKey('Body')) { $request.Body = $entry['Body'] }
        if ($entry.ContainsKey('ContentType')) { $request.ContentType = $entry['ContentType'] }

        $status = $null
        $reason = $null
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            try {
                $response = Invoke-WebRequest @request
                $status = [int]$response.StatusCode
                $content = if ($response.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
                $reason = if ($status -notin $expected) {
                    "answered $status, expected $($expected -join ' or ')"
                } elseif ($text -and -not $content.Contains($text)) {
                    "answered $status but does not contain '$text'"
                } else {
                    $null
                }
            } catch {
                $status = $null
                $reason = "could not be fetched: $($_.Exception.Message)"
            }
            if (-not $reason) { break }
            if ($attempt -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
        }

        if ($reason) {
            Write-Host "    FAILED: $method $($request.Uri) $reason" -ForegroundColor Red
        } else {
            Write-Ok "$method $($request.Uri) -> $status$(if ($text) { ", contains '$text'" })"
        }
        [pscustomobject]@{
            Url    = $request.Uri
            Method = $method
            Status = $status
            Ok     = -not $reason
            Reason = $reason
        }
    }

    $failed = @($results | Where-Object { -not $_.Ok })
    if ($failed.Count -gt 0 -and $Rollback) {
        Write-Host '    The smoke check failed; rolling back...' -ForegroundColor Yellow
        & $Rollback | Out-Host
    }
    if ($PassThru) { return $results }
    if ($failed.Count -gt 0) {
        $list = ($failed | ForEach-Object { "$($_.Method) $($_.Url) $($_.Reason)" }) -join "`n  - "
        $after = if ($Rollback) { 'It was rolled back.' } else { 'Nothing was rolled back (-NoRollback).' }
        throw "Smoke check failed:`n  - $list`n$after"
    }
}

#endregion

Export-ModuleMember -Alias 'Fail' -Function @(
    'Write-Step'
    'Write-Ok'
    'Exit-Deploy'
    'Resolve-DeploySetting'
    'Resolve-PuttyTool'
    'Resolve-TarTool'
    'Resolve-DeployConnection'
    'Open-DeployConnection'
    'Close-DeployConnection'
    'Invoke-RemoteWithRetry'
    'Invoke-Remote'
    'Invoke-RemoteStep'
    'Format-RemoteScript'
    'Compress-DeployArchive'
    'Invoke-Upload'
    'Send-File'
    'Get-File'
    'Send-FileVerified'
    'Restore-Env'
    'Invoke-GoBuild'
    'Invoke-NpmBuild'
    'Invoke-PluginBuild'
    'Assert-CleanWorkingTree'
    'Get-ReleaseTag'
    'Invoke-DeployBundle'
    'Install-ServiceBinary'
    'Restore-ServiceBinary'
    'Switch-RemoteDirectory'
    'Restore-RemoteDirectory'
    'Switch-RemoteItemSet'
    'Restore-RemoteItemSet'
    'Export-PluginRepository'
    'Publish-PluginRepository'
    'Copy-LiveDatabase'
    'Invoke-SmokeCheck'
)
