#Requires -Version 7.4

# Self-hosted GitHub Actions runners on this Windows machine: each job of each repo in the
# config runs in a fresh container in a WSL distro of its own, started when GitHub assigns
# the job and removed when it ends. runner/README.md says how the parts fit.

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

Add-Type -AssemblyName System.Formats.Tar

# Not under AppData: a packaged app's processes (a terminal inside one, say) read and write
# their own copy of AppData, so the sign-in task and such a terminal would each see files
# the other can't.
$script:StateDir = Join-Path $env:USERPROFILE '.ci-runner'
$script:DefaultConfigPath = Join-Path $script:StateDir 'runners.psd1'
$script:PidPath = Join-Path $script:StateDir 'supervisor.pid'
$script:LogDir = Join-Path $script:StateDir 'logs'
$script:TaskName = 'CI runners'
$script:JobImage = 'ci-runner'
$script:ScalerImage = 'ci-scaler'
$script:ScalerContainer = 'ci-scaler'
# The label the scaler puts on every job container (scaler/repo.go).
$script:JobLabel = 'ci-runner.job'
# The systemd slice every job's container runs in, whose limits the jobs share.
$script:Slice = 'ci.slice'
# Where a job with Docker access keeps its work folder in the distro, at the same path in
# its container, so a path it hands `docker run -v` means the same to Docker.
$script:WorkRoot = '/var/lib/ci-work'
# The Docker volume of download and build caches every Linux job shares (/ci-cache).
$script:CacheVolume = 'ci-cache'
# The Windows runners: the runner release they copy for each job, each job's copy, their
# own Go and tool caches, the scaler's build, and the file that stops it.
$script:WindowsDir = Join-Path $script:StateDir 'windows'
$script:WindowsStop = Join-Path $script:StateDir 'windows.stop'

#region Private helpers

function Write-CiLog {
    param([Parameter(Mandatory)] [string] $Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath (Join-Path $script:LogDir 'supervisor.log') -Value $line
    Write-Information $line -InformationAction Continue
}

function Read-CiConfig {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No runner config at $Path. Copy runner/runners.example.psd1 there and list the repos."
    }
    $config = Import-PowerShellDataFile -LiteralPath $Path
    foreach ($key in 'Owner', 'Repos') {
        if (-not $config[$key]) {
            throw "The runner config at $Path has no $key."
        }
    }
    if ($config.Repos -is [System.Collections.IDictionary]) {
        throw "The runner config at $Path gives Repos as a table of slots. It is a list of names now, such as @('app', 'site'): a repo runs as many jobs at once as MaxJobs allows."
    }
    $defaults = @{
        Distro         = 'ci-runner'
        Name           = 'wsl'
        JobMemory      = '8g'
        DockerRepos    = @()
        WindowsRepos   = @()
        WindowsMaxJobs = 1
        CacheSize      = '30g'
    }
    foreach ($key in $defaults.Keys) {
        if (-not $config.ContainsKey($key)) {
            $config[$key] = $defaults[$key]
        }
    }
    $config.Repos = @($config.Repos)
    $config.DockerRepos = @($config.DockerRepos)
    $config.WindowsRepos = @($config.WindowsRepos)
    foreach ($key in 'DockerRepos', 'WindowsRepos') {
        foreach ($repo in $config[$key]) {
            if ($repo -notin $config.Repos) { throw "The config's $key names '$repo', which isn't in its Repos." }
        }
    }
    if ($config.WindowsMaxJobs -isnot [int] -or $config.WindowsMaxJobs -lt 1) { throw "The config's WindowsMaxJobs '$($config.WindowsMaxJobs)' isn't a whole number of 1 or more." }
    # Every value reaches a command line, an API path or a limit, so each is held to a plain shape.
    if ($config.Owner -notmatch '^[A-Za-z0-9-]+$') { throw "The config's Owner '$($config.Owner)' isn't an account name." }
    if ($config.Distro -notmatch '^[A-Za-z0-9._-]+$') { throw "The config's Distro '$($config.Distro)' isn't a distro name." }
    if ($config.Name -notmatch '^[a-z0-9][a-z0-9-]{0,39}$') { throw "The config's Name '$($config.Name)' may hold only a-z, 0-9 and -." }
    if ($config.JobMemory -notmatch '^\d+[mg]$') { throw "The config's JobMemory '$($config.JobMemory)' isn't a size such as 8g." }
    if ($config.CacheSize -notmatch '^\d+[mg]$') { throw "The config's CacheSize '$($config.CacheSize)' isn't a size such as 30g." }
    if ($config.ContainsKey('Memory') -and $config.Memory -notmatch '^\d+[mg]$') { throw "The config's Memory '$($config.Memory)' isn't a size such as 12g." }
    if ($config.ContainsKey('MaxJobs') -and ($config.MaxJobs -isnot [int] -or $config.MaxJobs -lt 1)) { throw "The config's MaxJobs '$($config.MaxJobs)' isn't a whole number of 1 or more." }
    if ($config.ContainsKey('Cpus') -and (($config.Cpus -isnot [int] -and $config.Cpus -isnot [double]) -or $config.Cpus -le 0)) {
        throw "The config's Cpus '$($config.Cpus)' isn't a number above 0."
    }
    foreach ($repo in $config.Repos) {
        if ($repo -notmatch '^[A-Za-z0-9._-]+$') { throw "The config's repo '$repo' isn't a repo name." }
    }
    if (@($config.Repos | Sort-Object -Unique).Count -ne $config.Repos.Count) {
        throw 'The config lists a repo twice.'
    }
    return $config
}

function ConvertTo-CiByte {
    param([Parameter(Mandatory)] [string] $Size)
    $number = [long] $Size.Substring(0, $Size.Length - 1)
    if ($Size.EndsWith('g')) {
        return $number * 1GB
    }
    return $number * 1MB
}

function Invoke-CiDistro {
    # Runs a command as root in the distro, with no shell between, and returns its output;
    # throws with that output when it fails. -InputText goes to its standard input.
    param(
        [Parameter(Mandatory)] [string] $Distro,
        [Parameter(Mandatory)] [string[]] $Command,
        [string] $InputText,
        [switch] $AllowFailure
    )
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $output = $InputText | wsl.exe -d $Distro -u root --exec @Command 2>&1
    } else {
        $output = wsl.exe -d $Distro -u root --exec @Command 2>&1
    }
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "'$($Command -join ' ')' failed in the $Distro distro (exit $LASTEXITCODE):`n$($output -join "`n")"
    }
    return $output
}

function Test-CiDistro {
    # Whether the distro is installed, or with -Running, running: asking it anything else
    # through wsl.exe would start it.
    param(
        [Parameter(Mandatory)] [string] $Distro,
        [switch] $Running
    )
    $list = if ($Running) { wsl.exe --list --running --quiet } else { wsl.exe --list --quiet }
    # wsl.exe writes its lists in UTF-16, which reaches PowerShell with NULs between letters.
    $names = $list -replace "`0", '' | ForEach-Object { $_.Trim() }
    return $names -contains $Distro
}

function Get-CiLoop {
    # The running Start-CiRunner process that supervisor.pid names, or nothing. The file
    # outlives a reboot, after which its number may belong to another process, so the
    # process must be PowerShell and older than the file.
    if (-not (Test-Path -LiteralPath $script:PidPath)) {
        return
    }
    $file = Get-Item -LiteralPath $script:PidPath
    if ((Get-Content -LiteralPath $file.FullName -Raw) -notmatch '^\d+') {
        return
    }
    $process = Get-Process -Id ([int] $Matches[0]) -ErrorAction SilentlyContinue
    if ($process -and $process.Name -eq 'pwsh' -and $process.StartTime -le $file.LastWriteTime) {
        return $process
    }
}

function Wait-CiDocker {
    param([Parameter(Mandatory)] [string] $Distro)
    foreach ($attempt in 1..30) {
        Invoke-CiDistro -Distro $Distro -Command 'docker', 'info', '--format', '{{.ServerVersion}}' -AllowFailure | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return
        }
        Write-Verbose "Docker isn't answering yet (attempt $attempt)."
        Start-Sleep -Seconds 2
    }
    throw "Docker isn't answering in the $Distro distro. Look at: wsl -d $Distro -u root -- systemctl status docker"
}

function Set-CiLimit {
    # Writes the systemd slice every job's container runs in, so the jobs together use at
    # most the config's Cpus and Memory, and returns the limits. Cpus defaults to half the
    # distro's processors, leaving the rest to whatever else the machine is doing; Memory
    # to three quarters of the distro's; and MaxJobs to as many jobs as Memory holds at
    # 1.5 GB each, about what a front end's build and tests peak at with their file cache,
    # and no more than one per processor.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $size = @(Invoke-CiDistro -Distro $Config.Distro -Command 'sh', '-c', 'nproc && sed -n "s/^MemTotal: *\([0-9]*\) kB$/\1/p" /proc/meminfo')
    $processors = [int] $size[0]
    $cpus = if ($Config.ContainsKey('Cpus')) { [double] $Config.Cpus } else { [Math]::Max(1, [Math]::Floor($processors / 2)) }
    $memory = if ($Config.ContainsKey('Memory')) { ConvertTo-CiByte $Config.Memory } else { [long] ([long] $size[1] * 1KB * 0.75) }
    $maxJobs = if ($Config.ContainsKey('MaxJobs')) { $Config.MaxJobs } else { [int] [Math]::Max(1, [Math]::Min($processors, [Math]::Floor($memory / 1.5GB))) }
    $unit = "[Unit]`nDescription=CI jobs, which share these limits`n`n[Slice]`nCPUQuota=$([int] ($cpus * 100))%`nMemoryMax=$memory`n"
    if ($PSCmdlet.ShouldProcess($script:Slice, 'Set the jobs'' limits')) {
        Invoke-CiDistro -Distro $Config.Distro -InputText $unit -Command @(
            'sh', '-c', 'tr -d "\r" > "/etc/systemd/system/$0" && systemctl daemon-reload', $script:Slice
        ) | Out-Null
    }
    return [pscustomobject]@{
        Cpus    = $cpus
        Memory  = $memory
        MaxJobs = $maxJobs
    }
}

function Get-CiRunnerRelease {
    # The runner's newest release and the checksums its notes give for the Linux and Windows
    # x64 archives. GitHub stops sending jobs to a runner that falls too far behind, so the
    # runners follow the newest release rather than a pinned one.
    $json = gh api repos/actions/runner/releases/latest 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Couldn't read the runner's newest release: $json"
    }
    $release = ($json -join "`n") | ConvertFrom-Json
    if ($release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$') {
        throw "The runner's newest release has an unexpected tag, '$($release.tag_name)'."
    }
    $version = $Matches[1]
    $sums = @{}
    foreach ($platform in 'linux-x64', 'win-x64') {
        if ($release.body -notmatch "<!-- BEGIN SHA $platform -->([0-9a-f]{64})<!-- END SHA $platform -->") {
            throw "The runner's release $version lists no checksum for $platform."
        }
        $sums[$platform] = $Matches[1]
    }
    return [pscustomobject]@{ Version = $version; Sha256 = $sums['linux-x64']; WindowsSha256 = $sums['win-x64'] }
}

function Build-CiImage {
    # Builds an image in the distro from the given files (name to text), unless one of the
    # same files and build arguments is built already, then removes the older ones of that
    # name no container uses. Returns the image's tag. The files reach the distro on
    # standard input, as a tar in base64: the distro can't read the Windows drive, and a
    # PowerShell pipe carries only text.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Distro,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Files,
        [string[]] $BuildArgument = @(),
        [string] $TagPrefix = ''
    )
    $texts = [ordered]@{}
    foreach ($path in $Files.Keys | Sort-Object) {
        $texts[$path] = ([string] $Files[$path]).Replace("`r", '')
    }
    $identity = (@($texts.Keys | ForEach-Object { "$_`n$($texts[$_])" }) + $BuildArgument) -join "`0"
    $digest = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))
    $tag = '{0}:{1}{2}' -f $Name, $TagPrefix, ([Convert]::ToHexString($digest).Substring(0, 12).ToLowerInvariant())

    Invoke-CiDistro -Distro $Distro -Command 'docker', 'image', 'inspect', '--format', '{{.Id}}', $tag -AllowFailure | Out-Null
    if ($LASTEXITCODE -ne 0 -and $PSCmdlet.ShouldProcess($tag, 'Build the image')) {
        Write-CiLog "Building $tag; this takes a few minutes."
        $buffer = [IO.MemoryStream]::new()
        # Ustar, not pax: docker build tells a tar on standard input from a Dockerfile by its
        # first 1 KB, which a pax tar fills with an extended header before the first file's.
        $writer = [Formats.Tar.TarWriter]::new($buffer, [Formats.Tar.TarEntryFormat]::Ustar, $true)
        try {
            foreach ($path in $texts.Keys) {
                $entry = [Formats.Tar.UstarTarEntry]::new([Formats.Tar.TarEntryType]::RegularFile, $path)
                $entry.Mode = [IO.UnixFileMode] 'UserRead, UserWrite, GroupRead, OtherRead'
                $entry.DataStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($texts[$path]))
                $writer.WriteEntry($entry)
            }
        } finally {
            $writer.Dispose()
        }
        $context = [Convert]::ToBase64String($buffer.ToArray(), [Base64FormattingOptions]::InsertLineBreaks)
        $arguments = foreach ($argument in $BuildArgument) { '--build-arg'; $argument }
        Invoke-CiDistro -Distro $Distro -InputText $context -Command (@(
                'sh', '-c', 'tr -d "\r" | base64 -d | docker build --quiet --tag "$0" "$@" -', $tag
            ) + @($arguments)) | Out-Null
        Write-CiLog "Built $tag."
    }

    $older = Invoke-CiDistro -Distro $Distro -Command 'docker', 'image', 'ls', $Name, '--format', '{{.Repository}}:{{.Tag}}' |
        Where-Object { $_ -and $_ -ne $tag }
    foreach ($image in $older) {
        if ($PSCmdlet.ShouldProcess($image, 'Remove the older image')) {
            # One a running job still uses stays until the next update.
            Invoke-CiDistro -Distro $Distro -Command 'docker', 'image', 'rm', $image -AllowFailure | Out-Null
        }
    }
    return $tag
}

function Update-CiImage {
    # Builds the job image for the runner's release (Get-CiRunnerRelease), and the scaler's
    # image from scaler/, each unless it is built already. Returns both tags.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Distro,
        [Parameter(Mandatory)] [pscustomobject] $Release
    )
    $release = $Release
    $job = Build-CiImage -Distro $Distro -Name $script:JobImage -TagPrefix "$($release.Version)-" `
        -Files @{ Dockerfile = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Dockerfile') } `
        -BuildArgument "RUNNER_VERSION=$($release.Version)", "RUNNER_SHA256=$($release.Sha256)"

    $source = @{}
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'scaler') -File |
        Where-Object { $_.Name -in 'Dockerfile', 'go.mod', 'go.sum' -or ($_.Extension -eq '.go' -and $_.Name -notlike '*_test.go') } |
        ForEach-Object { $source[$_.Name] = Get-Content -Raw -LiteralPath $_.FullName }
    $scaler = Build-CiImage -Distro $Distro -Name $script:ScalerImage -Files $source

    Invoke-CiDistro -Distro $Distro -Command 'docker', 'image', 'prune', '--force' -AllowFailure | Out-Null
    return [pscustomobject]@{ Job = $job; Scaler = $scaler }
}

function Get-CiToken {
    # The token gh holds now, so a sign-in again reaches a scaler at its next start.
    $token = gh auth token 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gh has no token to give the scaler; sign in with gh auth login. $token"
    }
    return "$token".Trim()
}

function Get-CiScalerSetting {
    # The Linux scaler's settings, as the one line of JSON it reads on standard input.
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [pscustomobject] $Limits,
        [Parameter(Mandatory)] [string] $Image
    )
    return [ordered]@{
        token        = Get-CiToken
        owner        = $Config.Owner
        repos        = @($Config.Repos)
        name         = $Config.Name
        maxJobs      = $Limits.MaxJobs
        image        = $Image
        jobMemory    = ConvertTo-CiByte $Config.JobMemory
        # Chrome needs more /dev/shm than Docker's 64 MB.
        shmSize      = 2GB
        cgroupParent = $script:Slice
        dockerRepos  = @($Config.DockerRepos)
        workRoot     = $script:WorkRoot
        cacheVolume  = $script:CacheVolume
    } | ConvertTo-Json -Compress
}

function Get-CiWindowsScalerSetting {
    # The Windows scaler's settings: a process for each job, from a copy of RunnerDir, with
    # Go's caches and the tool cache of the runners' own, so a job neither writes to yours
    # nor downloads its tools afresh.
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $RunnerDir
    )
    return [ordered]@{
        token     = Get-CiToken
        owner     = $Config.Owner
        repos     = @($Config.WindowsRepos)
        name      = "$($Config.Name)-windows"
        maxJobs   = $Config.WindowsMaxJobs
        backend   = 'process'
        stopFile  = $script:WindowsStop
        runnerDir = $RunnerDir
        jobsDir   = Join-Path $script:WindowsDir 'jobs'
        env       = [ordered]@{
            GOPATH               = Join-Path $script:WindowsDir 'go'
            GOCACHE              = Join-Path $script:WindowsDir 'go-build'
            GOLANGCI_LINT_CACHE  = Join-Path $script:WindowsDir 'golangci-lint'
            RUNNER_TOOL_CACHE    = Join-Path $script:WindowsDir 'toolcache'
            AGENT_TOOLSDIRECTORY = Join-Path $script:WindowsDir 'toolcache'
        }
    } | ConvertTo-Json -Compress
}

function Update-CiWindowsRunner {
    # Makes ready what the Windows runners run, each only where it isn't already: the
    # runner's newest release, extracted once and copied for each job, and the scaler,
    # built from scaler/ with this machine's Go. Removes the older ones nothing runs.
    # Returns both paths.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [pscustomobject] $Release)
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
        throw 'The Windows runners need Go on PATH, which builds their scaler.'
    }
    New-Item -ItemType Directory -Force -Path $script:WindowsDir | Out-Null

    $runnerDir = Join-Path $script:WindowsDir "runner-$($Release.Version)"
    if (-not (Test-Path -LiteralPath (Join-Path $runnerDir '.complete')) -and $PSCmdlet.ShouldProcess($runnerDir, 'Extract the Windows runner')) {
        Write-CiLog "Fetching the Windows runner $($Release.Version)."
        $zip = Join-Path $script:WindowsDir "actions-runner-win-x64-$($Release.Version).zip"
        $url = "https://github.com/actions/runner/releases/download/v$($Release.Version)/actions-runner-win-x64-$($Release.Version).zip"
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        $sum = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sum -ne $Release.WindowsSha256) {
            Remove-Item -LiteralPath $zip
            throw "The Windows runner's archive has the checksum $sum, not the $($Release.WindowsSha256) its release notes give."
        }
        Remove-Item -LiteralPath $runnerDir -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -LiteralPath $zip -DestinationPath $runnerDir
        Remove-Item -LiteralPath $zip
        Set-Content -LiteralPath (Join-Path $runnerDir '.complete') -Value $Release.Version
    }

    $source = Join-Path $PSScriptRoot 'scaler'
    $files = Get-ChildItem -LiteralPath $source -File |
        Where-Object { $_.Name -in 'go.mod', 'go.sum' -or ($_.Extension -eq '.go' -and $_.Name -notlike '*_test.go') } |
        Sort-Object Name
    $identity = ($files | ForEach-Object { "$($_.Name)`n$((Get-Content -Raw -LiteralPath $_.FullName).Replace("`r", ''))" }) -join "`0"
    $digest = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))
    $bin = Join-Path $script:WindowsDir 'bin'
    $exe = Join-Path $bin ('scaler-{0}.exe' -f [Convert]::ToHexString($digest).Substring(0, 12).ToLowerInvariant())
    if (-not (Test-Path -LiteralPath $exe) -and $PSCmdlet.ShouldProcess($exe, 'Build the Windows scaler')) {
        Write-CiLog "Building $exe."
        New-Item -ItemType Directory -Force -Path $bin | Out-Null
        $env:CGO_ENABLED = '0'
        try {
            $output = go build -C $source -trimpath -o $exe . 2>&1
        } finally {
            Remove-Item Env:\CGO_ENABLED
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Couldn't build the Windows scaler: $($output -join "`n")"
        }
    }

    # Older ones go once nothing runs them; a scaler still running one keeps it for now.
    Get-ChildItem -LiteralPath $script:WindowsDir -Directory -Filter 'runner-*' |
        Where-Object { $_.FullName -ne $runnerDir } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $bin -File -Filter 'scaler-*.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $exe } | Remove-Item -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ RunnerDir = $runnerDir; Scaler = $exe }
}

function Limit-CiCache {
    # Empties the jobs' caches once one has grown past the config's CacheSize, while no job
    # is using it: the Linux jobs' volume, and the Windows jobs' Go caches and tool cache.
    # Go trims its own build cache; the module and npm caches only grow, and a job after
    # this fetches what it needs again.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [hashtable] $Config)
    $limit = ConvertTo-CiByte $Config.CacheSize
    if (Test-CiDistro -Distro $Config.Distro -Running) {
        $size = Invoke-CiDistro -Distro $Config.Distro -AllowFailure -Command @(
            'sh', '-c', 'du -sb "/var/lib/docker/volumes/$0/_data" 2>/dev/null | cut -f1', $script:CacheVolume
        )
        $busy = Invoke-CiDistro -Distro $Config.Distro -Command 'docker', 'ps', '--quiet', '--filter', "label=$script:JobLabel"
        if ([long] "0$size" -gt $limit -and -not $busy -and $PSCmdlet.ShouldProcess($script:CacheVolume, 'Empty the Linux jobs'' cache')) {
            Invoke-CiDistro -Distro $Config.Distro -Command 'docker', 'volume', 'rm', $script:CacheVolume | Out-Null
            Write-CiLog ('Emptied the Linux jobs'' cache, which had grown to {0:N1} GB.' -f ([long] $size / 1GB))
        }
    }
    $folders = 'go', 'go-build', 'golangci-lint', 'toolcache' | ForEach-Object { Join-Path $script:WindowsDir $_ } | Where-Object { Test-Path -LiteralPath $_ }
    if ($folders) {
        $size = (Get-ChildItem -LiteralPath $folders -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        $busy = Get-ChildItem -LiteralPath (Join-Path $script:WindowsDir 'jobs') -Directory -ErrorAction SilentlyContinue
        if ($size -gt $limit -and -not $busy -and $PSCmdlet.ShouldProcess('the Windows jobs'' caches', 'Empty')) {
            $folders | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-CiLog ('Emptied the Windows jobs'' caches, which had grown to {0:N1} GB.' -f ($size / 1GB))
        }
    }
}

function Stop-CiWindowsScaler {
    # Stops the Windows scaler through its stop file, which ends its runners: a job running
    # on one fails. Whatever outlives it, a scaler or a runner a crash left, is ended here.
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (Test-Path -LiteralPath $script:WindowsDir) -or -not $PSCmdlet.ShouldProcess('the Windows scaler', 'Stop')) {
        return
    }
    $mine = { param($p) $p.ExecutablePath -and $p.ExecutablePath.StartsWith($script:WindowsDir, [StringComparison]::OrdinalIgnoreCase) }
    $scalers = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'scaler-%.exe'" | Where-Object { & $mine $_ })
    if ($scalers) {
        Set-Content -LiteralPath $script:WindowsStop -Value 'stop'
        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline -and ($scalers | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })) {
            Start-Sleep -Seconds 1
        }
    }
    foreach ($process in Get-CimInstance Win32_Process | Where-Object { & $mine $_ }) {
        taskkill.exe /T /F /PID $process.ProcessId 2>&1 | Out-Null
    }
    Remove-Item -LiteralPath $script:WindowsStop -ErrorAction SilentlyContinue
}

function Get-CiGitHubRunner {
    # This machine's runners on one repo, found by their name's start, the config's Name.
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $Repo
    )
    $lines = gh api "repos/$($Config.Owner)/$Repo/actions/runners" --paginate --jq '.runners[] | [.id, .name, .status, .busy] | @tsv' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Couldn't list $Repo's runners: $lines"
    }
    foreach ($line in $lines) {
        $id, $name, $status, $busy = $line -split "`t"
        if ($name -like "$($Config.Name)-*") {
            [pscustomobject]@{ Repo = $Repo; Id = [long] $id; Name = $name; Status = $status; Busy = $busy -eq 'true' }
        }
    }
}

function Remove-CiGitHubRunner {
    # Deregisters this machine's offline runners (with -All, every one of them), the ones a
    # stop or a crash left behind.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [switch] $All
    )
    foreach ($repo in $Config.Repos) {
        $runners = @(Get-CiGitHubRunner -Config $Config -Repo $repo | Where-Object { $All -or $_.Status -eq 'offline' })
        foreach ($runner in $runners) {
            if ($PSCmdlet.ShouldProcess("$repo/$($runner.Name)", 'Deregister the runner')) {
                $result = gh api -X DELETE "repos/$($Config.Owner)/$repo/actions/runners/$($runner.Id)" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Couldn't deregister $repo/$($runner.Name): $result"
                }
            }
        }
    }
}

function Stop-CiScaler {
    # Stops the scaler, which closes its sessions with GitHub first; the job containers
    # keep running.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Distro)
    if ($PSCmdlet.ShouldProcess($script:ScalerContainer, 'Stop the scaler')) {
        Invoke-CiDistro -Distro $Distro -Command 'docker', 'stop', '--time', '30', $script:ScalerContainer -AllowFailure | Out-Null
    }
}

function Remove-CiContainer {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Distro)
    $ids = Invoke-CiDistro -Distro $Distro -Command 'docker', 'ps', '--all', '--quiet', '--filter', "label=$script:JobLabel"
    if ($ids -and $PSCmdlet.ShouldProcess("$(@($ids).Count) job containers", 'Remove')) {
        Invoke-CiDistro -Distro $Distro -Command (@('docker', 'rm', '--force') + @($ids)) | Out-Null
    }
}

function Move-CiLog {
    # Keeps one older copy of a log that has grown past 10 MB.
    param([Parameter(Mandatory)] [string] $Path)
    try {
        if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 10MB) {
            Move-Item -LiteralPath $Path -Destination "$Path.old" -Force
        }
    } catch {
        Write-Verbose "The log at $Path is busy; moving it next time. $_"
    }
}

# The scaler, run in the foreground in a thread job so its output reaches the log as it
# comes. Its settings, the token among them, go to it on standard input.
$script:ScalerRun = {
    param($Distro, $Container, $Image, $Setting, $LogPath, $WorkRoot)
    $PSNativeCommandUseErrorActionPreference = $false
    wsl.exe -d $Distro -u root --exec docker rm --force $Container 2>&1 | Out-Null
    $Setting | wsl.exe -d $Distro -u root --exec docker run --interactive --rm --init --name $Container `
        --volume /var/run/docker.sock:/var/run/docker.sock --volume "${WorkRoot}:${WorkRoot}" $Image 2>&1 |
        ForEach-Object { Add-Content -LiteralPath $LogPath -Value $_ }
    $LASTEXITCODE
}

# The Windows scaler, run the same way.
$script:WindowsScalerRun = {
    param($Exe, $Setting, $LogPath)
    $PSNativeCommandUseErrorActionPreference = $false
    $Setting | & $Exe 2>&1 | ForEach-Object { Add-Content -LiteralPath $LogPath -Value $_ }
    $LASTEXITCODE
}

#endregion

#region Public functions

<#
.SYNOPSIS
    Sets up this machine for the self-hosted runners: the WSL distro with Docker, the config
    file, and the task that runs them.

.DESCRIPTION
    In order, each step skipped where it's already done:
    1. Installs Ubuntu 24.04 as a WSL distro of its own (-Distro), apart from any other.
    2. Runs setup-host.sh in it as root: systemd, no Windows drives or programs reachable
       from it, Docker Engine.
    3. Restarts the distro so its wsl.conf takes effect.
    4. Copies runners.example.psd1 to %USERPROFILE%\.ci-runner\runners.psd1 if no config
       is there yet; list the repos in it before starting.
    5. Registers the "CI runners" scheduled task, which runs Start-CiRunner, hidden and apart
       from any terminal, when `task shared:runner:start` starts it (skipped with -NoTask).
       Nothing starts it on its own: the runners run only between a start and a stop.
    A failed step throws and leaves the earlier ones done; running it again picks up there.

.PARAMETER Distro
    The WSL distro's name; the config's Distro must match it.

.PARAMETER NoTask
    Leaves out the scheduled task, for runners started by hand with Start-CiRunner.

.EXAMPLE
    Import-Module ./runner/CiRunner.psm1; Install-CiRunner
#>
function Install-CiRunner {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidatePattern('^[A-Za-z0-9._-]+$')]
        [string] $Distro = 'ci-runner',
        [switch] $NoTask
    )
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'The GitHub CLI (gh) is not on PATH; the scaler signs in to GitHub with its token.'
    }

    if (-not (Test-CiDistro -Distro $Distro) -and $PSCmdlet.ShouldProcess($Distro, 'Install Ubuntu 24.04 as a WSL distro')) {
        $output = wsl.exe --install Ubuntu-24.04 --name $Distro --no-launch 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Couldn't install the $Distro distro: $(($output -join "`n") -replace "`0", '')"
        }
    }

    if ($PSCmdlet.ShouldProcess($Distro, 'Set up systemd and Docker Engine')) {
        $setup = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'setup-host.sh')
        Invoke-CiDistro -Distro $Distro -InputText $setup -Command 'bash', '-c', 'tr -d "\r" | bash -s' | Out-Null
        wsl.exe --terminate $Distro | Out-Null
        Wait-CiDocker -Distro $Distro
    }

    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    if (-not (Test-Path -LiteralPath $script:DefaultConfigPath)) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'runners.example.psd1') -Destination $script:DefaultConfigPath
        Write-Host "List your repos in $script:DefaultConfigPath before starting the runners."
    }

    if (-not $NoTask -and $PSCmdlet.ShouldProcess($script:TaskName, 'Register the scheduled task')) {
        $module = Join-Path $PSScriptRoot 'CiRunner.psm1'
        if ($module -match "['`"]") {
            throw "The module's path, $module, holds a quote, which the task's command can't carry."
        }
        $pwsh = (Get-Command pwsh).Source
        $user = "$env:USERDOMAIN\$env:USERNAME"
        # conhost --headless keeps a console window from opening. The task has no trigger:
        # Invoke-CiRunner.ps1 starts it, and Stop-CiRunner ends it.
        $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
            -Argument "--headless `"$pwsh`" -NoProfile -NonInteractive -Command `"Import-Module '$module'; Start-CiRunner`""
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $script:TaskName -Action $action `
            -Settings $settings -Principal $principal -Force | Out-Null
        Write-Host "Registered the '$script:TaskName' task; task shared:runner:start, in any repo, starts the runners."
    }
}

<#
.SYNOPSIS
    Runs the self-hosted runners until stopped: the scaler, which starts a fresh container
    for each job GitHub assigns the repos in the config.

.DESCRIPTION
    What the "CI runners" task runs, which `task shared:runner:start` starts. In order:
    1. Refuses to start while another copy runs (its process id is in
       %USERPROFILE%\.ci-runner\supervisor.pid).
    2. Waits for Docker in the distro, sets the limits the jobs share (Set-CiLimit's
       slice), empties a cache grown past CacheSize (Limit-CiCache), and deregisters the
       offline runners an earlier run left.
    3. Builds the job image for the runner's newest release, and the scaler's image, where
       either isn't built yet; with WindowsRepos, readies the Windows runner and builds
       the Windows scaler too.
    4. Runs the scaler (scaler/) in a container with gh's token, and starts it again if it
       stops. It holds a long poll open on each repo's scale set and starts a runner's
       container for each job GitHub assigns it, up to MaxJobs at once across the repos.
       With WindowsRepos, runs the Windows scaler beside it the same way.
    5. Every six hours, empties a cache grown past CacheSize, rebuilds what the runner's
       new release or a change to scaler/ needs, and restarts a scaler on it; running
       Linux jobs finish on the image they started on.
    Ctrl+C, or Stop-CiRunner, ends it. Logs go to %USERPROFILE%\.ci-runner\logs:
    supervisor.log for this loop, scaler.log and scaler-windows.log for the scalers.

.PARAMETER ConfigPath
    The config; defaults to %USERPROFILE%\.ci-runner\runners.psd1.

.EXAMPLE
    Import-Module ./runner/CiRunner.psm1; Start-CiRunner
#>
function Start-CiRunner {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $ConfigPath = $script:DefaultConfigPath)
    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    # Run hidden by the task, an error has nowhere to show but the log.
    try {
        $config = Read-CiConfig -Path $ConfigPath

        $running = Get-CiLoop
        if ($running) {
            throw "The runners are already running, as process $($running.Id). Stop them with Stop-CiRunner."
        }
        if (-not $PSCmdlet.ShouldProcess("$($config.Repos.Count) repos", 'Start the runners')) {
            return
        }
        Set-Content -LiteralPath $script:PidPath -Value $PID
        Write-CiLog "The runner loop is starting, as process $PID."
        # The scaler writes UTF-8, which its log keeps as it is.
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

        # A scaler for the Linux containers, and one for the Windows processes when the
        # config names Windows repos; each runs in a thread job and starts again if it stops.
        $scalers = [ordered]@{
            linux = [pscustomobject]@{ Log = Join-Path $script:LogDir 'scaler.log'; Job = $null; Delay = 5; NextStart = Get-Date }
        }
        if ($config.WindowsRepos) {
            $scalers.windows = [pscustomobject]@{ Log = Join-Path $script:LogDir 'scaler-windows.log'; Job = $null; Delay = 5; NextStart = Get-Date }
        }
        $windows = $null
        try {
            # Just after a reboot or a sleep the network can come up after this starts, so the
            # steps that reach GitHub get ten minutes before the start counts as failed.
            foreach ($attempt in 1..20) {
                try {
                    Wait-CiDocker -Distro $config.Distro
                    $limits = Set-CiLimit -Config $config
                    Limit-CiCache -Config $config
                    $release = Get-CiRunnerRelease
                    $images = Update-CiImage -Distro $config.Distro -Release $release
                    if ($config.WindowsRepos) {
                        $windows = Update-CiWindowsRunner -Release $release
                    }
                    Remove-CiGitHubRunner -Config $config
                    break
                } catch {
                    if ($attempt -eq 20) {
                        throw
                    }
                    Write-CiLog "Not ready to start (attempt $attempt), trying again in 30 s: $_"
                    Start-Sleep -Seconds 30
                }
            }
            Write-CiLog ("Serving {0} repos as '{1}': up to {2} jobs at once, sharing {3} CPUs and {4:N1} GB." -f
                $config.Repos.Count, $config.Name, $limits.MaxJobs, $limits.Cpus, ($limits.Memory / 1GB))
            if ($config.WindowsRepos) {
                Write-CiLog ("Serving {0} repos' Windows jobs as '{1}-windows': up to {2} at once." -f
                    $config.WindowsRepos.Count, $config.Name, $config.WindowsMaxJobs)
            }

            $lastUpkeep = Get-Date
            while ($true) {
                foreach ($name in @($scalers.Keys)) {
                    $scaler = $scalers[$name]
                    Move-CiLog -Path $scaler.Log
                    if ($scaler.Job -and $scaler.Job.State -in 'Running', 'NotStarted') {
                        continue
                    }
                    if ($scaler.Job) {
                        $ran = (Get-Date) - $scaler.Job.PSBeginTime
                        Write-CiLog "The $name scaler stopped ($($scaler.Job.State), exit $($scaler.Job | Receive-Job 2>&1 | Select-Object -Last 1)) after $([int] $ran.TotalSeconds) s; the end of $(Split-Path -Leaf $scaler.Log) says why."
                        $scaler.Job | Remove-Job -Force
                        $scaler.Job = $null
                        # One that fails at once waits longer each time, up to five minutes.
                        $scaler.Delay = if ($ran.TotalSeconds -ge 60) { 5 } else { [Math]::Min($scaler.Delay * 2, 300) }
                        $scaler.NextStart = (Get-Date).AddSeconds($scaler.Delay)
                    }
                    if ((Get-Date) -lt $scaler.NextStart) {
                        continue
                    }
                    try {
                        if ($name -eq 'linux') {
                            $setting = Get-CiScalerSetting -Config $config -Limits $limits -Image $images.Job
                            $scaler.Job = Start-ThreadJob -Name 'scaler' -ScriptBlock $script:ScalerRun -ArgumentList @(
                                $config.Distro, $script:ScalerContainer, $images.Scaler, $setting, $scaler.Log, $script:WorkRoot
                            )
                            Write-CiLog "Started the linux scaler on $($images.Scaler), with jobs on $($images.Job)."
                        } else {
                            $setting = Get-CiWindowsScalerSetting -Config $config -RunnerDir $windows.RunnerDir
                            $scaler.Job = Start-ThreadJob -Name 'scaler-windows' -ScriptBlock $script:WindowsScalerRun -ArgumentList @(
                                $windows.Scaler, $setting, $scaler.Log
                            )
                            Write-CiLog "Started the windows scaler, $($windows.Scaler), with jobs on $($windows.RunnerDir)."
                        }
                    } catch {
                        Write-CiLog "Couldn't start the $name scaler, trying again in $($scaler.Delay) s: $_"
                        $scaler.NextStart = (Get-Date).AddSeconds($scaler.Delay)
                    }
                }
                if (((Get-Date) - $lastUpkeep).TotalHours -ge 6) {
                    $lastUpkeep = Get-Date
                    try {
                        Limit-CiCache -Config $config
                        $release = Get-CiRunnerRelease
                        $newer = Update-CiImage -Distro $config.Distro -Release $release
                        if ($newer.Job -ne $images.Job -or $newer.Scaler -ne $images.Scaler) {
                            $images = $newer
                            Write-CiLog 'Restarting the linux scaler on the new images.'
                            Stop-CiScaler -Distro $config.Distro
                        }
                        if ($config.WindowsRepos) {
                            $newer = Update-CiWindowsRunner -Release $release
                            if ($newer.RunnerDir -ne $windows.RunnerDir -or $newer.Scaler -ne $windows.Scaler) {
                                $windows = $newer
                                Write-CiLog 'Restarting the windows scaler on the new runner or build.'
                                Stop-CiWindowsScaler
                            }
                        }
                    } catch {
                        Write-CiLog "Upkeep failed, trying again in six hours: $_"
                    }
                }
                Start-Sleep -Seconds 30
            }
        } finally {
            Write-CiLog 'Stopping the scalers; running Linux jobs finish, Windows ones end.'
            try {
                Stop-CiScaler -Distro $config.Distro
                if ($config.WindowsRepos) {
                    Stop-CiWindowsScaler
                }
            } catch {
                Write-CiLog "Couldn't stop the scalers: $_"
            }
            foreach ($scaler in $scalers.Values) {
                if ($scaler.Job) {
                    $scaler.Job | Remove-Job -Force
                }
            }
            Remove-Item -LiteralPath $script:PidPath -ErrorAction SilentlyContinue
        }
    } catch {
        Write-CiLog "The runner loop stopped on an error: $_`n$($_.ScriptStackTrace)"
        throw
    }
}

<#
.SYNOPSIS
    Stops the self-hosted runners: the loop, the scaler, every job container, their
    registrations, and the WSL distro.

.DESCRIPTION
    Ends the "CI runners" task and the Start-CiRunner process named in
    %USERPROFILE%\.ci-runner\supervisor.pid, stops the scaler (which closes its sessions
    with GitHub), removes every job container (a job running in one fails, as on a lost
    runner), deregisters this machine's runners from each repo in the config, and shuts
    the distro down. With no other distro running, WSL then stops its VM and gives its
    memory back to Windows. The scale sets stay, so a repo whose CI_RUNNER variable names
    them queues its jobs until the next start, and GitHub cancels a job that has waited 24
    hours; delete the variable to send a repo's jobs to GitHub's runners instead.

.PARAMETER ConfigPath
    The config; defaults to %USERPROFILE%\.ci-runner\runners.psd1.

.EXAMPLE
    Import-Module ./runner/CiRunner.psm1; Stop-CiRunner
#>
function Stop-CiRunner {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $ConfigPath = $script:DefaultConfigPath)
    $config = Read-CiConfig -Path $ConfigPath
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($task.State -eq 'Running' -and $PSCmdlet.ShouldProcess($script:TaskName, 'End the task')) {
        $task | Stop-ScheduledTask
    }
    $loop = Get-CiLoop
    if ($loop -and $PSCmdlet.ShouldProcess("process $($loop.Id)", 'Stop the runner loop')) {
        $loop | Stop-Process -Force
    }
    Remove-Item -LiteralPath $script:PidPath -ErrorAction SilentlyContinue
    Stop-CiWindowsScaler
    if (Test-CiDistro -Distro $config.Distro -Running) {
        Stop-CiScaler -Distro $config.Distro
        Remove-CiContainer -Distro $config.Distro
    }
    Remove-CiGitHubRunner -Config $config -All
    if ((Test-CiDistro -Distro $config.Distro -Running) -and $PSCmdlet.ShouldProcess($config.Distro, 'Shut the distro down')) {
        wsl.exe --terminate $config.Distro | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Couldn't shut the $($config.Distro) distro down (exit $LASTEXITCODE)."
        }
    }
}

<#
.SYNOPSIS
    Waits until the runner loop has the scaler running, after the "CI runners" task starts.

.DESCRIPTION
    Returns once the scaler's container runs, which is when the repos' jobs start reaching
    this machine. Throws if the loop isn't running after its first 30 seconds, with the end
    of its log, or if the scaler isn't up within -TimeoutSeconds: a first start builds the
    images, which takes a few minutes.

.PARAMETER ConfigPath
    The config; defaults to %USERPROFILE%\.ci-runner\runners.psd1.

.PARAMETER TimeoutSeconds
    How long to wait; ten minutes by default.

.EXAMPLE
    Start-ScheduledTask -TaskName 'CI runners'; Wait-CiRunner
#>
function Wait-CiRunner {
    [CmdletBinding()]
    param(
        [string] $ConfigPath = $script:DefaultConfigPath,
        [int] $TimeoutSeconds = 600
    )
    $config = Read-CiConfig -Path $ConfigPath
    $began = Get-Date
    while (((Get-Date) - $began).TotalSeconds -lt $TimeoutSeconds) {
        if (Get-CiLoop) {
            $scaler = Invoke-CiDistro -Distro $config.Distro -AllowFailure -Command @(
                'docker', 'ps', '--quiet', '--filter', "name=^$script:ScalerContainer$"
            )
            if ($LASTEXITCODE -eq 0 -and $scaler) {
                return
            }
        } elseif (((Get-Date) - $began).TotalSeconds -gt 30) {
            $log = Get-Content -LiteralPath (Join-Path $script:LogDir 'supervisor.log') -Tail 5 -ErrorAction SilentlyContinue
            throw "The runner loop isn't running. The end of supervisor.log:`n$($log -join "`n")"
        }
        Start-Sleep -Seconds 3
    }
    throw "The scaler wasn't up after $TimeoutSeconds s; supervisor.log and scaler.log in $script:LogDir say why."
}

<#
.SYNOPSIS
    Shows the runners: whether the loop and the scaler are running, the limits the jobs
    share, the scaler's last lines, and a row for each job running now.

.PARAMETER ConfigPath
    The config; defaults to %USERPROFILE%\.ci-runner\runners.psd1.

.EXAMPLE
    Import-Module ./runner/CiRunner.psm1; Get-CiRunnerStatus
#>
function Get-CiRunnerStatus {
    [CmdletBinding()]
    param([string] $ConfigPath = $script:DefaultConfigPath)
    $config = Read-CiConfig -Path $ConfigPath
    $loop = Get-CiLoop
    Write-Host "Runner loop: $(if ($loop) { "running as process $($loop.Id)" } else { 'not running' }). Logs: $script:LogDir"
    if ($config.WindowsRepos) {
        $windows = @(Get-Process -Name 'scaler-*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($script:WindowsDir, [StringComparison]::OrdinalIgnoreCase) })
        $jobs = @(Get-ChildItem -LiteralPath (Join-Path $script:WindowsDir 'jobs') -Directory -ErrorAction SilentlyContinue)
        Write-Host ("Windows scaler: {0}, serving {1} repos as '{2}-windows'; {3} runner(s) up." -f
            $(if ($windows) { "running as process $($windows[0].Id)" } else { 'not running' }), $config.WindowsRepos.Count, $config.Name, $jobs.Count)
        $log = Join-Path $script:LogDir 'scaler-windows.log'
        if (Test-Path -LiteralPath $log) {
            Get-Content -LiteralPath $log -Tail 3 | ForEach-Object { Write-Host "  $_" }
        }
    }
    if (-not (Test-CiDistro -Distro $config.Distro)) {
        Write-Host "The $($config.Distro) distro isn't installed; run Install-CiRunner."
        return
    }
    if (-not (Test-CiDistro -Distro $config.Distro -Running)) {
        Write-Host "The $($config.Distro) distro is shut down; task shared:runner:start starts it."
        return
    }
    $scaler = Invoke-CiDistro -Distro $config.Distro -AllowFailure -Command @(
        'docker', 'ps', '--filter', "name=^$script:ScalerContainer$", '--format', '{{.Status}}'
    )
    Write-Host "Scaler: $(if ($scaler) { $scaler } else { 'not running' }), serving $($config.Repos.Count) repos as '$($config.Name)'."
    $limits = Invoke-CiDistro -Distro $config.Distro -AllowFailure -Command @(
        'systemctl', 'show', $script:Slice, '--property', 'CPUQuotaPerSecUSec,MemoryMax,MemoryCurrent'
    )
    Write-Host "Jobs' limits and use: $($limits -join ', ')"
    $log = Join-Path $script:LogDir 'scaler.log'
    if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log -Tail 5 | ForEach-Object { Write-Host "  $_" }
    }
    Invoke-CiDistro -Distro $config.Distro -AllowFailure -Command @(
        'docker', 'ps', '--filter', "label=$script:JobLabel",
        '--format', '{{.Label "ci-runner.repo"}}|{{.Label "ci-runner.runner"}}|{{.RunningFor}}|{{.Image}}'
    ) | Where-Object { $_ } | ForEach-Object {
        $repo, $runner, $running, $image = $_ -split '\|'
        [pscustomobject]@{ Repo = $repo; Runner = $runner; Started = $running; Image = $image }
    }
}

#endregion

Export-ModuleMember -Function Install-CiRunner, Start-CiRunner, Stop-CiRunner, Wait-CiRunner, Get-CiRunnerStatus
