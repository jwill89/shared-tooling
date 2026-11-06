# deploy/pwsh: the SharedDeploy module

One PowerShell module for the pieces the 14 deploy scripts in Web Projects copied into each other: settings, the SSH connection, the one archive a deploy ships, the atomic swap of a folder, a code set, a binary or a plugin repository, the service restart and its check, rollback, the dev-database pull, and a smoke check after the deploy. Each function's help (`Get-Help <name> -Full`) names the scripts it came from.

It was seeded from what the scripts already do, not written fresh. The owner settled where they disagreed on November 5, 2026; those decisions are what the functions do now, and their help says so where it matters.

The module holds no host names, users, keys, tokens or addresses. Those stay in each project's git-ignored `scripts/deploy.config.ps1`, read through `Resolve-DeploySetting`.

## The shape of every deploy

Everything a deploy needs goes into ONE archive: the binary, systemd units, env templates, `.htaccess`, plugin files, the static `dist`. Then:

1. `Open-DeployConnection` opens one SSH connection and holds it for the whole run.
2. `Compress-DeployArchive` packs the archive and returns its SHA-256 and file count.
3. `Invoke-Upload` streams it to the host.
4. One remote run unpacks it to a staging folder, checks the SHA-256 and file count, and only then runs the steps: `Install-ServiceBinary`, `Switch-RemoteDirectory`, `Switch-RemoteItemSet` or `Publish-PluginRepository` on their own, or several of them as `-AsStep` blocks of one `Invoke-DeployBundle`.
5. `Invoke-SmokeCheck` fetches the site and, if it fails, runs the rollback.
6. For a project with a database: `Install-BackupTimer` keeps its daily backup installed and checked, and `Copy-LiveDatabase` pulls a copy to the dev machine, the one copy that leaves the droplet.
7. `Close-DeployConnection` in a `finally` block.

The droplet runs `ufw limit ssh`, which refuses an address after six connections in 30 seconds. This shape opens one: every command, upload and download rides the held connection, so a deploy with several targets (Senpan's backend, frontend and plugin) is one connection and one remote run, with no pauses between targets.

Single-file uploads (`Send-File`, `Send-FileVerified`) stay for the rare case that cannot ship one archive.

## Requirements

- PowerShell 7.4 or later (`CompatiblePSEditions = 'Core'`), on Windows.
- PuTTY's `plink` 0.85 or later (connection sharing), on PATH or in `C:\Program Files\PuTTY`, with the key loaded in Pageant if it has a passphrase. pscp is not used.
- Windows' own `tar.exe` for `Compress-DeployArchive`.
- On the host: bash, systemd, GNU coreutils (`sha256sum`, `sort -V`), `sqlite3` for database snapshots, `curl` for `-HealthUrl`, and `apachectl` for a vhost.

## The one connection

`Open-DeployConnection` starts a hidden `plink -batch -share -N` that logs in and holds the connection, and waits until `plink -share -shareexists` reports it is up. Every remote call then runs as `plink -batch -share`, which rides that connection and opens none of its own. Uploads and downloads stream through plink too: the archive is the standard input of `cat > <file>` on the host, and a download is the standard output of `cat <file>`, checked against the host's `sha256sum`.

Before each remote step the holder is checked; if it has exited, a new one starts (one new connection) and a line says it reconnected. A step that failed because the connection dropped is retried once after reconnecting. A reconnect is tried at once, and only if it is refused (the ufw window) does it wait 35 seconds and try once more. Marker files in the SSH user's `~/.shared-deploy` let a retried remote run resume: steps that already finished are skipped, and a run that already completed says so and succeeds.

Nothing leaves a plink holding the connection: `Close-DeployConnection` stops it, `Fail` closes it before it exits, PowerShell's exit stops it, and the holder runs in a Windows job object that ends it with the PowerShell process, even one that was killed.

Connection sharing works against the droplet: Kindred Nights' v0.29.4 deploy (2026-11-05, the pilot) ran on one held connection, from the upload through the smoke check and the dev-database pull. The reconnect paths are still tested only against a stand-in plink.

## Importing it

A project holds shared-tooling as a submodule at `shared/`. Its deploy script imports the module and keeps these lines of its own, since preference variables and a `trap` cannot reach a script from a module:

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot '..\shared\deploy\pwsh\SharedDeploy.psd1') -Force
trap { Close-DeployConnection; Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
```

The module's functions throw when something fails, so the caller can roll back first; the `trap` line closes the connection and prints the error as `ERROR: ...` in red, the same output `Fail` gives. `Fail` itself is still there, as an alias of `Exit-Deploy`, so existing `Fail "..."` lines keep working.

Remote paths are passed to the host in single quotes, so `$HOME` in a path is not expanded; relative paths are relative to the SSH user's home. Upload the archive there (a relative `-Destination`), which always exists.

## Functions

Output:

- `Write-Step`: a blank line, then `==> message` in cyan.
- `Write-Ok`: an indented line in green.
- `Exit-Deploy` (alias `Fail`): `ERROR: message` in red, closes the connection, then exits 1.

Settings, tools and the connection:

- `Resolve-DeploySetting`: each setting from its parameter, then `$env:DEPLOY_*`, then `$Deploy*` in the config file, then a default; lists every missing one in one error. The SSH user is always required and has no default.
- `Resolve-PuttyTool`: a PuTTY tool from PATH, else `C:\Program Files\PuTTY`.
- `Resolve-TarTool`: Windows' own `tar.exe` by its full path.
- `Resolve-DeployConnection`: checks the key, finds plink, builds `user@host`, adds an optional `-hostkey` pin, and stores it as the default connection, without opening it.
- `Open-DeployConnection`: all of that, then opens and holds the one shared connection.
- `Close-DeployConnection`: ends the held connection.

Remote commands:

- `Invoke-RemoteWithRetry`: runs a command, prints its output indented, returns `$true` or `$false`.
- `Invoke-Remote`: runs a command and returns its output lines; throws on failure.
- `Invoke-RemoteStep`: runs several self-contained blocks (the `Restore-` functions' `-AsScript`) in one call; throws on failure.
- `Format-RemoteScript`: fills `__NAME__` and `{{NAME}}` placeholders literally.

Transfers:

- `Compress-DeployArchive`: packs everything a deploy needs into one ustar `.tar.gz`, from wherever each piece lives, and returns its path, file count and SHA-256.
- `Invoke-Upload`: streams the archive to the host with an elapsed-time bar and a 15-minute limit; returns `Ok`, `Err` and `Elapsed`.
- `Send-File`: single files, for the rare case outside the archive.
- `Get-File`: downloads a file and checks it against the host's SHA-256.
- `Send-FileVerified`: one file beside its place, checked on the host, then renamed in.

Builds and checks before a deploy:

- `Restore-Env`: puts an environment variable back as it was.
- `Invoke-GoBuild`: a static, stripped linux/amd64 Go build, with `GOOS`, `GOARCH` and `CGO_ENABLED` restored afterwards.
- `Invoke-NpmBuild`: `npm run build`, then checks its `index.html` exists.
- `Invoke-PluginBuild`: deletes a Dalamud plugin's `bin/` and `obj/`, then builds it in Release.
- `Assert-CleanWorkingTree`: throws if git has uncommitted changes, listing them.
- `Get-ReleaseTag`: the tag on HEAD, or a throw if there is none.

The remote run:

- `Invoke-DeployBundle`: unpacks the uploaded archive, checks its SHA-256 and file count, then runs each step; resumes after a dropped connection.

Service binaries:

- `Install-ServiceBinary`: for one service or a set: checks first (the binary and units are in the upload, the health URL can be built, a changed vhost passes `apachectl configtest`), then stops them, keeps `<binary>.old`, snapshots the database with `sqlite3 .backup` (newest three kept), installs the units that differ (compared with `cmp`) and the binary, restarts, checks (every service active, or `-HealthUrl` answers, with parts read from the env file), and rolls everything back together on failure.
- `Restore-ServiceBinary`: puts the previous binary, units, vhost and optionally the newest database snapshot back after a failed smoke check.

Folder swaps:

- `Switch-RemoteDirectory`: swaps a folder from the upload into place by renames, keeping `<live>.old`, with hooks before and after the swap.
- `Restore-RemoteDirectory`: puts `<live>.old` back.
- `Switch-RemoteItemSet`: swaps several top-level entries of one folder (a PHP app's code) through a staging folder, and puts the old ones back if a later step fails.
- `Restore-RemoteItemSet`: puts that backup back.

Plugins:

- `Export-PluginRepository`: lays out a Dalamud repository folder locally, refuses a built version that differs from the index's, and cache-busts the download links with `?v=<version>`.
- `Publish-PluginRepository`: on the host, refuses a version that is not higher than the published one, then swaps the repository folder in.

Scheduled backup:

- `Install-BackupTimer`: a daily systemd timer and its oneshot service, with Kindred Nights' hardening. It renders the units and the shared job, installs them only where they differ from the live copies (`cmp`), runs the service once to check them, and puts the previous copies back if that run fails. The shared job writes a `VACUUM INTO` copy of the live database, checks it with `PRAGMA integrity_check`, names it `<prefix>YYYY-MM-DD<suffix>` (UTC) and keeps 28 days, leaving every other file in its folder alone. `-Command` runs a project's own job instead (Kindred Nights' `kindred backup`). Call it after the smoke check.

Development database:

- `Copy-LiveDatabase`: an online `sqlite3 .backup` on the host, a checked download, three timestamped local copies kept, the host's copy removed; warns and skips if the local database is in use.

Smoke check:

- `Invoke-SmokeCheck`: fetches each URL from this machine, checks its status (200 unless given) and optional text, tries each up to `-Attempts` times; on a failure runs `-Rollback` and throws. It needs `-Rollback`, or `-NoRollback` for a deploy with nothing to undo.

## Before and after

Fantasy Dossier's script is 238 lines, and about half is the code every script copies. A sample of it:

```powershell
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "`nERROR: $msg" -ForegroundColor Red; exit 1 }
trap { Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

$localConfig = Join-Path $PSScriptRoot 'deploy.config.ps1'
if (Test-Path $localConfig) { . $localConfig }
if (-not $VpsHost) { $VpsHost = if ($env:DEPLOY_VPS_HOST) { $env:DEPLOY_VPS_HOST } else { $DeployVpsHost } }
# ...three more settings, three more checks...

function Resolve-PuttyTool($name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # ...
}

function Invoke-RemoteWithRetry([string]$cmd) {
    $out = & $plink -batch -i $KeyPath $remoteTarget $cmd 2>&1
    # ...retry once after 35s if the connection was refused...
}

function Invoke-Upload([string]$WorkingDir, [string]$LocalItem, [string]$RemoteDest, [string]$Label, [int]$FileCount) {
    # ...27 lines: Start-Process pscp -r, progress bar, time limit...
}

# ...build, stage, prepare a folder, upload the files with their own retry, then an 18-line shell swap...
```

Three SSH connections, and an upload of every file one by one. The same deploy on the module, with the smoke step the plan adds (the site's address goes in `deploy.config.ps1` as `$DeploySiteUrl`):

```powershell
[CmdletBinding()]
param(
    [string]$VpsHost,
    [string]$VpsUser,
    [string]$KeyPath,
    [string]$WebRoot,
    [string]$SiteUrl,
    [switch]$SkipBuild,
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot '..\shared\deploy\pwsh\SharedDeploy.psd1') -Force
trap { Close-DeployConnection; Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

$settings = Resolve-DeploySetting -ConfigPath (Join-Path $PSScriptRoot 'deploy.config.ps1') `
    -Value @{ VpsHost = $VpsHost; VpsUser = $VpsUser; KeyPath = $KeyPath; WebRoot = $WebRoot; SiteUrl = $SiteUrl } `
    -Required VpsHost, VpsUser, KeyPath, WebRoot, SiteUrl
$webRoot = $settings.WebRoot
$live = "$webRoot/dist"

$repoRoot = Split-Path $PSScriptRoot -Parent
$frontend = Join-Path $repoRoot 'frontend'
$dist = Join-Path $frontend 'dist'
if ($SkipBuild) {
    Write-Step 'Skipping build (-SkipBuild); using existing dist/'
} else {
    Invoke-NpmBuild -Path $frontend -Output (Join-Path $dist 'index.html')
}

Write-Step 'Packing the deploy...'
$archive = Compress-DeployArchive -Content ([ordered]@{
        'dist'      = $dist
        '.htaccess' = Join-Path $repoRoot 'deploy\.htaccess'
    })
Write-Ok "$($archive.FileCount) files, one archive"

$connection = $settings | Open-DeployConnection
try {
    Write-Step 'Uploading...'
    $upload = Invoke-Upload -Path $archive.Path -Destination 'xivdossier-deploy.tgz' -Activity 'Uploading dossier' -FileCount $archive.FileCount
    if (-not $upload.Ok) { Fail "Upload failed. Live site untouched.`n$($upload.Err)" }

    Write-Step 'Checking the upload and swapping it in...'
    Switch-RemoteDirectory -Archive 'xivdossier-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
        -Live $live -File @{ '.htaccess' = "$webRoot/.htaccess" } -NoBackup:$NoBackup

    Write-Step "Checking $($settings.SiteUrl)..."
    Invoke-SmokeCheck -Url $settings.SiteUrl -Attempts 3 -Rollback {
        Restore-RemoteDirectory -Live $live -File "$webRoot/.htaccess"
    }
} finally {
    Close-DeployConnection
    Remove-Item -LiteralPath $archive.Path -ErrorAction SilentlyContinue
}
Write-Host "`n[OK] Deployed to $($connection.Target):$live" -ForegroundColor Green
```

One connection, one upload, one remote run, plus one more remote call only if the smoke check rolls back. A rollback needs the `.old` copies, so it cannot work after `-NoBackup`.

## More shapes

Each of these sits inside the same `Open-DeployConnection` / `try` / `finally { Close-DeployConnection }` and follows a `Compress-DeployArchive` and `Invoke-Upload` like the one above. The names and paths are examples, not any project's.

A service binary and its unit (Marxbot, Nophica, Family Card Game). Everything uploads first; nothing stops until the archive on the host has been checked:

```powershell
$archive = Compress-DeployArchive -Content ([ordered]@{
        'example'         = Invoke-GoBuild -Path $repoRoot -Output 'example'
        'example.service' = Join-Path $repoRoot 'deploy\example.service'
    })
# ...Invoke-Upload to 'example-deploy.tgz'...
Install-ServiceBinary -Archive 'example-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
    -ServiceName $settings.ServiceName -Binary "$($settings.RemoteOptDir)/example" -Unit 'example.service' -UnitMode '600'
```

Several targets in one archive and one remote run (Senpan's backend, frontend and plugin; TarotGen.io's frontend, backend and plugin), API first:

```powershell
Invoke-DeployBundle -Archive 'example-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount -Step @(
    Install-ServiceBinary -AsStep -ServiceName $settings.ServiceName -Binary "$($settings.RemoteOptDir)/example" -Database $settings.RemoteDbPath
    Switch-RemoteDirectory -AsStep -Live "$($settings.WebRoot)/dist" -File @{ '.htaccess' = "$($settings.WebRoot)/.htaccess" }
    Publish-PluginRepository -AsStep -Live "$($settings.WebRoot)/plugin" -Version $repo.Version -IndexPath 'pluginmaster.json'
)
```

A Grav plugin or theme folder swapped whole, then the cache cleared (What Do I Know):

```powershell
$archive = Compress-DeployArchive -Content @{ 'unlisted' = Join-Path $repoRoot 'user\plugins\unlisted' }
# ...Invoke-Upload to 'grav-deploy.tgz'...
Switch-RemoteDirectory -Archive 'grav-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
    -Live "$webRoot/user/plugins/unlisted" -Owner 'www-data' `
    -AfterSwap "sudo -u www-data php '$webRoot/bin/grav' clearcache --all >/dev/null"
```

A PHP site in a folder of its own, its PHP checked on the host's PHP before the swap (IDE Résumé Site, whose files move into their own folder, with Apache's DocumentRoot pointed at it, at its rollout):

```powershell
Switch-RemoteDirectory -Archive 'site-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
    -Live "$webRoot/site" -BeforeSwap 'for f in $(find "$new" -name "*.php" -type f); do php -l "$f" >/dev/null || exit 4; done'
```

A Dalamud plugin repository (Venue Tools; Senpan, Kindred Nights and TarotGen.io the same way):

```powershell
Invoke-PluginBuild -Project (Join-Path $repoRoot 'Example.csproj')
$built = Join-Path $repoRoot 'bin\Release\Example'
$repo = Export-PluginRepository -Manifest (Join-Path $built 'Example.json') `
    -IndexPath 'pluginmaster.json' -IndexSource (Join-Path $repoRoot 'pluginmaster.json') -File ([ordered]@{
        'Example/latest.zip' = Join-Path $built 'latest.zip'
        'Example/icon.png'   = Join-Path $repoRoot 'images\icon.png'
        '.htaccess'          = Join-Path $repoRoot 'deploy\plugin.htaccess'
    })
$archive = Compress-DeployArchive -Content @{ 'plugins' = $repo.Path }
# ...Invoke-Upload to 'plugin-deploy.tgz'...
Publish-PluginRepository -Archive 'plugin-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
    -Live "$webRoot/plugins" -Version $repo.Version -IndexPath 'pluginmaster.json'
```

Swapping the whole folder replaces everything in it, so check before the first run that the live folder holds only this plugin's files.

A set of services with their units, a vhost and a health URL read from the env file (Home Library):

```powershell
Install-ServiceBinary -Archive 'example-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
    -ServiceName 'example', 'example-worker' -Binary '/opt/example/example' -Owner 'root' -Umask '077' `
    -Unit 'deploy/example.service', 'deploy/example-worker.service', 'deploy/example-backup.service', 'deploy/example-backup.timer' `
    -Vhost 'deploy/apache-vhost.conf' -VhostPath '/etc/apache2/sites-available/example.conf' `
    -EnvFile '/etc/example/example.env' -HealthUrl 'http://{EXAMPLE_ADDR}/healthz' -HealthDefault @{ EXAMPLE_ADDR = 'localhost:8080' } `
    -Database '/opt/example/data/example.sqlite' -SnapshotPrefix '/opt/example/backups/example-pre-' -SnapshotSuffix '.sqlite' -RestoreDatabaseOnRollback
```

The dev-database pull after a deploy, on the same connection:

```powershell
if (-not $NoDbPull) { $null = Copy-LiveDatabase -Database '/opt/example/data/example.sqlite' -Destination (Join-Path $repoRoot 'devdata\example.sqlite') }
```

The daily backup and the dev-database pull, after the smoke check passes. The timer changes only when its settings do, so most deploys print "unchanged" and run nothing:

```powershell
Install-BackupTimer -Name 'example' -Database '/var/www/example.com/db/example.db' -Owner 'www-data'
# A project with a backup command of its own:
Install-BackupTimer -Name 'example' -Command '/opt/example/example backup' -Owner 'example' `
    -EnvironmentFile '/etc/example/example.env' -WorkingDirectory '/opt/example' -ReadWritePath '/opt/example'
if (-not $NoDbPull) { $null = Copy-LiveDatabase -Database '/var/www/example.com/db/example.db' -Destination (Join-Path $repoRoot 'devdata/example.db') }
```

## Checking the module

```powershell
Import-Module .\deploy\pwsh\SharedDeploy.psd1 -Force; Get-Command -Module SharedDeploy
Test-ModuleManifest .\deploy\pwsh\SharedDeploy.psd1
Invoke-ScriptAnalyzer -Path .\deploy\pwsh\SharedDeploy.psm1 -Settings .\lint\pwsh\PSScriptAnalyzerSettings.psd1
```

PSScriptAnalyzer 1.25.0 sometimes stops with a NullReferenceException inside its own `UseCorrectCasing` rule when run cold on this file. That is a race in the analyzer, not a finding; the next run passes, and every rule passes run on its own.
