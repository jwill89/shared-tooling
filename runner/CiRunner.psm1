#Requires -Version 7.4

# Self-hosted GitHub Actions runners on this Windows machine: one ready runner per slot of
# each private repo in the config, each taking one job in a fresh container in a WSL
# distro of its own, then replaced. runner/README.md says how the parts fit.

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# Not under AppData: a packaged app's processes (a terminal inside one, say) read and write
# their own copy of AppData, so the sign-in task and such a terminal would each see files
# the other can't.
$script:StateDir = Join-Path $env:USERPROFILE '.ci-runner'
$script:DefaultConfigPath = Join-Path $script:StateDir 'runners.psd1'
$script:PidPath = Join-Path $script:StateDir 'supervisor.pid'
$script:LogDir = Join-Path $script:StateDir 'logs'
$script:ImageName = 'ci-runner'
$script:SlotLabel = 'ci-runner.slot'
$script:TaskName = 'CI runners'

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
    $defaults = @{
        Distro     = 'ci-runner'
        Labels     = @('self-hosted', 'linux', 'x64')
        NamePrefix = 'wsl'
        Memory     = '8g'
    }
    foreach ($key in $defaults.Keys) {
        if (-not $config.ContainsKey($key)) {
            $config[$key] = $defaults[$key]
        }
    }
    # Every value reaches a command line or an API path, so each is held to a plain shape.
    if ($config.Owner -notmatch '^[A-Za-z0-9-]+$') { throw "The config's Owner '$($config.Owner)' isn't an account name." }
    if ($config.Distro -notmatch '^[A-Za-z0-9._-]+$') { throw "The config's Distro '$($config.Distro)' isn't a distro name." }
    if ($config.NamePrefix -notmatch '^[a-z0-9-]+$') { throw "The config's NamePrefix '$($config.NamePrefix)' may hold only a-z, 0-9 and -." }
    if ($config.Memory -notmatch '^\d+[kmg]$') { throw "The config's Memory '$($config.Memory)' isn't a size such as 8g." }
    foreach ($label in $config.Labels) {
        if ($label -notmatch '^[A-Za-z0-9._-]+$') { throw "The config's label '$label' isn't a plain name." }
    }
    foreach ($repo in $config.Repos.Keys) {
        if ($repo -notmatch '^[A-Za-z0-9._-]+$') { throw "The config's repo '$repo' isn't a repo name." }
        if ([int] $config.Repos[$repo] -lt 1) { throw "The config gives $repo $($config.Repos[$repo]) slots; it needs at least 1." }
    }
    return $config
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
    param([Parameter(Mandatory)] [string] $Distro)
    # wsl.exe writes its lists in UTF-16, which reaches PowerShell with NULs between letters.
    $names = (wsl.exe --list --quiet) -replace "`0", '' | ForEach-Object { $_.Trim() }
    return $names -contains $Distro
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

function Get-CiRunnerRelease {
    # The runner's newest release and the checksum its notes give for the Linux x64 archive.
    # GitHub stops sending jobs to a runner that falls too far behind, so the image follows
    # the newest release rather than a pinned one.
    $json = gh api repos/actions/runner/releases/latest 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Couldn't read the runner's newest release: $json"
    }
    $release = ($json -join "`n") | ConvertFrom-Json
    if ($release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$') {
        throw "The runner's newest release has an unexpected tag, '$($release.tag_name)'."
    }
    $version = $Matches[1]
    if ($release.body -notmatch '<!-- BEGIN SHA linux-x64 -->([0-9a-f]{64})<!-- END SHA linux-x64 -->') {
        throw "The runner's release $version lists no checksum for linux-x64."
    }
    return [pscustomobject]@{ Version = $version; Sha256 = $Matches[1] }
}

function Update-CiImage {
    # Builds the job image for the runner's newest release and this Dockerfile, unless it is
    # already built, then removes the older ones no container uses. Returns the image's tag.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Distro)
    $release = Get-CiRunnerRelease
    $dockerfile = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'Dockerfile')).Replace("`r", '')
    $bytes = [Text.Encoding]::UTF8.GetBytes($dockerfile)
    $hash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).Substring(0, 12).ToLowerInvariant()
    $tag = '{0}:{1}-{2}' -f $script:ImageName, $release.Version, $hash

    Invoke-CiDistro -Distro $Distro -Command 'docker', 'image', 'inspect', '--format', '{{.Id}}', $tag -AllowFailure | Out-Null
    if ($LASTEXITCODE -ne 0 -and $PSCmdlet.ShouldProcess($tag, 'Build the job image')) {
        Write-CiLog "Building $tag (runner $($release.Version)); this takes a few minutes."
        # The Dockerfile arrives on standard input with an empty context, since the distro
        # can't read the Windows drive it lives on.
        Invoke-CiDistro -Distro $Distro -InputText $dockerfile -Command @(
            'sh', '-c', 'mkdir -p /tmp/ci-runner-context && tr -d "\r" > /tmp/ci-runner.Dockerfile && docker build --quiet --tag "$1" --build-arg RUNNER_VERSION="$2" --build-arg RUNNER_SHA256="$3" --file /tmp/ci-runner.Dockerfile /tmp/ci-runner-context',
            'sh', $tag, $release.Version, $release.Sha256
        ) | Out-Null
        Write-CiLog "Built $tag."
    }

    $older = Invoke-CiDistro -Distro $Distro -Command 'docker', 'image', 'ls', $script:ImageName, '--format', '{{.Repository}}:{{.Tag}}' |
        Where-Object { $_ -and $_ -ne $tag }
    foreach ($image in $older) {
        if ($PSCmdlet.ShouldProcess($image, 'Remove the older job image')) {
            # One a running job still uses stays until the next update.
            Invoke-CiDistro -Distro $Distro -Command 'docker', 'image', 'rm', $image -AllowFailure | Out-Null
        }
    }
    Invoke-CiDistro -Distro $Distro -Command 'docker', 'image', 'prune', '--force' -AllowFailure | Out-Null
    return $tag
}

function Get-CiGitHubRunner {
    # This machine's runners on one repo, found by their name's prefix.
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
        if ($name -like "$($Config.NamePrefix)-*") {
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
    foreach ($repo in $Config.Repos.Keys) {
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

function Remove-CiContainer {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] [string] $Distro)
    $ids = Invoke-CiDistro -Distro $Distro -Command 'docker', 'ps', '--all', '--quiet', '--filter', "label=$script:SlotLabel"
    if ($ids -and $PSCmdlet.ShouldProcess("$(@($ids).Count) runner containers", 'Remove')) {
        Invoke-CiDistro -Distro $Distro -Command (@('docker', 'rm', '--force') + @($ids)) | Out-Null
    }
}

# One slot: asks GitHub for a single-use runner, runs it in a fresh container until its one
# job is done, and starts over. It runs as a thread job, so it brings what it needs.
$script:SlotLoop = {
    param($Config, $Repo, $Slot, $State, $LogPath)
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    function Write-SlotLog([string] $Path, [string] $Message) {
        Add-Content -LiteralPath $Path -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message)
    }

    $container = "ci-$Repo-$Slot"
    $delay = 5
    while (-not $State.Stopping) {
        $started = Get-Date
        $code = 1
        try {
            $name = '{0}-{1}-{2}-{3:yyyyMMddHHmmss}' -f $Config.NamePrefix, $Repo, $Slot, $started
            $ghArgs = @(
                'api', '-X', 'POST', "repos/$($Config.Owner)/$Repo/actions/runners/generate-jitconfig",
                '-f', "name=$name", '-F', 'runner_group_id=1', '-f', 'work_folder=_work'
            )
            foreach ($label in $Config.Labels) {
                $ghArgs += '-f', "labels[]=$label"
            }
            $jitconfig = gh @ghArgs --jq '.encoded_jit_config' 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "GitHub refused a runner: $jitconfig"
            }
            wsl.exe -d $Config.Distro -u root --exec docker rm --force $container 2>&1 | Out-Null
            Write-SlotLog $LogPath "$name waiting for a job in $($State.Image)"
            $jitconfig | wsl.exe -d $Config.Distro -u root --exec docker run --interactive --rm --init `
                --name $container --label "$($State.SlotLabel)=$Repo-$Slot" `
                --shm-size 2g --memory $Config.Memory $State.Image 2>&1 |
                ForEach-Object { Write-SlotLog $LogPath "  $_" }
            $code = $LASTEXITCODE
            Write-SlotLog $LogPath "$name finished (exit $code)"
        } catch {
            Write-SlotLog $LogPath "error: $_"
        }
        # A runner that ran its job starts over at once; one that failed fast waits longer
        # each time, up to five minutes, so a fault doesn't spin.
        if ($code -eq 0 -and ((Get-Date) - $started).TotalSeconds -ge 30) {
            $delay = 5
            continue
        }
        if (-not $State.Stopping) {
            Write-SlotLog $LogPath "trying again in $delay s"
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 300)
        }
    }
}

#endregion

#region Public functions

<#
.SYNOPSIS
    Sets up this machine for the self-hosted runners: the WSL distro with Docker, the config
    file, and a task that starts them at sign-in.

.DESCRIPTION
    In order, each step skipped where it's already done:
    1. Installs Ubuntu 24.04 as a WSL distro of its own (-Distro), apart from any other.
    2. Runs setup-host.sh in it as root: systemd, no Windows drives or programs reachable
       from it, Docker Engine.
    3. Restarts the distro so its wsl.conf takes effect.
    4. Copies runners.example.psd1 to %USERPROFILE%\.ci-runner\runners.psd1 if no config
       is there yet; list the private repos in it before starting.
    5. Registers the "CI runners" scheduled task, which runs Start-CiRunner, hidden, each
       time you sign in (skipped with -NoTask).
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
        throw 'The GitHub CLI (gh) is not on PATH; the runners ask GitHub for their registrations through it.'
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
        Write-Host "List your private repos in $script:DefaultConfigPath before starting the runners."
    }

    if (-not $NoTask -and $PSCmdlet.ShouldProcess($script:TaskName, 'Register the scheduled task')) {
        $module = Join-Path $PSScriptRoot 'CiRunner.psm1'
        if ($module -match "['`"]") {
            throw "The module's path, $module, holds a quote, which the task's command can't carry."
        }
        $pwsh = (Get-Command pwsh).Source
        $user = "$env:USERDOMAIN\$env:USERNAME"
        # conhost --headless keeps the console window from opening at every sign-in.
        $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
            -Argument "--headless `"$pwsh`" -NoProfile -NonInteractive -Command `"Import-Module '$module'; Start-CiRunner`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force | Out-Null
        Write-Host "The '$script:TaskName' task starts the runners at each sign-in; Start-ScheduledTask '$script:TaskName' starts them now."
    }
}

<#
.SYNOPSIS
    Runs the self-hosted runners until stopped: a ready runner for every slot in the config,
    each job in a fresh container.

.DESCRIPTION
    What the "CI runners" task runs at sign-in. In order:
    1. Refuses to start while another copy runs (its process id is in
       %USERPROFILE%\.ci-runner\supervisor.pid).
    2. Waits for Docker in the distro, removes containers and deregisters offline runners
       an earlier run left.
    3. Builds the job image for the runner's newest release if it isn't built yet.
    4. Starts a loop for each slot: a single-use runner from GitHub's just-in-time API, run
       in a container until its one job is done, then the next.
    5. Every six hours, rebuilds the image when the runner has a new release (the slots take
       it at their next job) and deregisters runners left offline.
    Ctrl+C, or Stop-CiRunner, ends it. Logs go to %USERPROFILE%\.ci-runner\logs, one file
    for this loop and one per slot.

.PARAMETER ConfigPath
    The config; defaults to %USERPROFILE%\.ci-runner\runners.psd1.

.EXAMPLE
    Import-Module ./runner/CiRunner.psm1; Start-CiRunner
#>
function Start-CiRunner {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $ConfigPath = $script:DefaultConfigPath)
    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    # Run hidden at sign-in, an error has nowhere to show but the log.
    try {
        $config = Read-CiConfig -Path $ConfigPath

        if (Test-Path -LiteralPath $script:PidPath) {
            $previous = Get-Content -LiteralPath $script:PidPath -Raw
            if ($previous -match '^\d+' -and (Get-Process -Id ([int] $Matches[0]) -ErrorAction SilentlyContinue)) {
                throw "The runners are already running, as process $($Matches[0]). Stop them with Stop-CiRunner."
            }
        }
        if (-not $PSCmdlet.ShouldProcess("$($config.Repos.Count) repos", 'Start the runners')) {
            return
        }
        Set-Content -LiteralPath $script:PidPath -Value $PID
        Write-CiLog "The runner loop is starting, as process $PID."
        # The runner writes UTF-8, which the slots' logs keep as it is.
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

        $slots = foreach ($repo in $config.Repos.Keys) { 1..[int] $config.Repos[$repo] | ForEach-Object { [pscustomobject]@{ Repo = $repo; Slot = $_ } } }
        $state = [hashtable]::Synchronized(@{ Image = $null; Stopping = $false; SlotLabel = $script:SlotLabel })
        $jobs = @{}
        try {
            # At sign-in the network can come up after this starts, so the steps that reach
            # GitHub get ten minutes before the start counts as failed.
            foreach ($attempt in 1..20) {
                try {
                    Wait-CiDocker -Distro $config.Distro
                    Remove-CiContainer -Distro $config.Distro
                    Remove-CiGitHubRunner -Config $config
                    $state.Image = Update-CiImage -Distro $config.Distro
                    break
                } catch {
                    if ($attempt -eq 20) {
                        throw
                    }
                    Write-CiLog "Not ready to start (attempt $attempt), trying again in 30 s: $_"
                    Start-Sleep -Seconds 30
                }
            }
            $lastUpkeep = Get-Date
            Write-CiLog "Starting $(@($slots).Count) runner slots for $($config.Repos.Count) repos on $($state.Image)."

            while ($true) {
                foreach ($slot in $slots) {
                    $key = "$($slot.Repo)-$($slot.Slot)"
                    $job = $jobs[$key]
                    if (-not $job -or $job.State -notin 'Running', 'NotStarted') {
                        if ($job) {
                            Write-CiLog "The $key slot stopped ($($job.State)); starting it again. $($job | Receive-Job 2>&1 | Out-String)"
                            $job | Remove-Job -Force
                        }
                        $logPath = Join-Path $script:LogDir "$key.log"
                        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 5MB) {
                            Move-Item -LiteralPath $logPath -Destination "$logPath.old" -Force
                        }
                        $jobs[$key] = Start-ThreadJob -Name $key -ThrottleLimit (@($slots).Count + 1) -ScriptBlock $script:SlotLoop `
                            -ArgumentList $config, $slot.Repo, $slot.Slot, $state, $logPath
                    }
                }
                if (((Get-Date) - $lastUpkeep).TotalHours -ge 6) {
                    $lastUpkeep = Get-Date
                    try {
                        $state.Image = Update-CiImage -Distro $config.Distro
                        Remove-CiGitHubRunner -Config $config
                    } catch {
                        Write-CiLog "Upkeep failed, trying again in six hours: $_"
                    }
                }
                Start-Sleep -Seconds 30
            }
        } finally {
            $state.Stopping = $true
            Write-CiLog 'Stopping the runners.'
            try {
                Remove-CiContainer -Distro $config.Distro
            } catch {
                Write-CiLog "Couldn't remove the containers: $_"
            }
            $jobs.Values | Remove-Job -Force -ErrorAction SilentlyContinue
            try {
                Remove-CiGitHubRunner -Config $config -All
            } catch {
                Write-CiLog "Couldn't deregister the runners: $_"
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
    Stops the self-hosted runners: the loop, every runner container, and their registrations.

.DESCRIPTION
    Ends the Start-CiRunner process named in %USERPROFILE%\.ci-runner\supervisor.pid,
    removes every runner container (a job running in one fails, as on a lost runner), and
    deregisters this machine's runners from each repo in the config. A repo whose CI_RUNNER
    variable names their label then waits for them; delete the variable to send its jobs to
    GitHub's runners instead. The scheduled task starts them again at the next sign-in.

.PARAMETER ConfigPath
    The config; defaults to %USERPROFILE%\.ci-runner\runners.psd1.

.EXAMPLE
    Import-Module ./runner/CiRunner.psm1; Stop-CiRunner
#>
function Stop-CiRunner {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $ConfigPath = $script:DefaultConfigPath)
    $config = Read-CiConfig -Path $ConfigPath
    if (Test-Path -LiteralPath $script:PidPath) {
        $previous = Get-Content -LiteralPath $script:PidPath -Raw
        if ($previous -match '^\d+') {
            $process = Get-Process -Id ([int] $Matches[0]) -ErrorAction SilentlyContinue
            if ($process -and $PSCmdlet.ShouldProcess("process $($process.Id)", 'Stop the runner loop')) {
                $process | Stop-Process -Force
            }
        }
        Remove-Item -LiteralPath $script:PidPath -ErrorAction SilentlyContinue
    }
    if (Test-CiDistro -Distro $config.Distro) {
        Remove-CiContainer -Distro $config.Distro
    }
    Remove-CiGitHubRunner -Config $config -All
}

<#
.SYNOPSIS
    Shows the runners: whether the loop is running, the containers in the distro, and each
    repo's runners as GitHub sees them.

.PARAMETER ConfigPath
    The config; defaults to %USERPROFILE%\.ci-runner\runners.psd1.

.EXAMPLE
    Import-Module ./runner/CiRunner.psm1; Get-CiRunnerStatus
#>
function Get-CiRunnerStatus {
    [CmdletBinding()]
    param([string] $ConfigPath = $script:DefaultConfigPath)
    $config = Read-CiConfig -Path $ConfigPath
    $loop = 'not running'
    if (Test-Path -LiteralPath $script:PidPath) {
        $previous = Get-Content -LiteralPath $script:PidPath -Raw
        if ($previous -match '^\d+' -and (Get-Process -Id ([int] $Matches[0]) -ErrorAction SilentlyContinue)) {
            $loop = "running as process $($Matches[0])"
        }
    }
    Write-Host "Runner loop: $loop. Logs: $script:LogDir"
    if (Test-CiDistro -Distro $config.Distro) {
        Invoke-CiDistro -Distro $config.Distro -AllowFailure -Command @(
            'docker', 'ps', '--filter', "label=$script:SlotLabel", '--format', '{{.Names}}  {{.Status}}  {{.Image}}'
        ) | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "  The $($config.Distro) distro isn't installed; run Install-CiRunner."
    }
    foreach ($repo in $config.Repos.Keys | Sort-Object) {
        Get-CiGitHubRunner -Config $config -Repo $repo
    }
}

#endregion

Export-ModuleMember -Function Install-CiRunner, Start-CiRunner, Stop-CiRunner, Get-CiRunnerStatus
