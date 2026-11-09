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
- On the host: bash, systemd, GNU coreutils (`sha256sum`, `sort -V`, `stat`), `sqlite3` and `gzip` for database snapshots and backups, `runuser` (util-linux) for an `-Owner` on `Backup-RemoteDatabase` or `Copy-LiveDatabase`, `curl` for `-HealthUrl`, and `apachectl` for a vhost.

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
- `Get-DeployRelease`: fetches the tags and returns the newest release tagged on the branch the checkout tracks (`origin/main`), with its commit and how many commits follow it. What a deploy ships.
- `New-ReleaseTree`: checks a release out into a folder of its own under the temp folder (`git worktree`, detached), with its submodules and an `npm ci` in each folder named, to build from; `Remove-ReleaseTree` removes it, in a `finally`.
- `Get-DeployedRelease` and `Set-DeployedRelease`: read and write the record on the host of the release a deploy left running (`~/.shared-deploy/<name>` of the SSH user). A deploy reads it first and stops when the host already runs the release; it writes it once the site has passed its checks.
- `Assert-CleanWorkingTree`: throws if git has uncommitted changes, listing them.
- `Get-ReleaseTag`: the tag on HEAD, or a throw if there is none. For a deploy that has not moved to `Get-DeployRelease` yet.

The remote run:

- `Invoke-DeployBundle`: unpacks the uploaded archive, checks its SHA-256 and file count, then runs each step; resumes after a dropped connection.

Service binaries:

- `Install-ServiceBinary`: for one service or a set: checks first (the binary and units are in the upload, the health URL can be built, a changed vhost passes `apachectl configtest`), then stops them, keeps `<binary>.old`, snapshots the database with `sqlite3 .backup`, checked and compressed with gzip before anything is installed (newest three kept), installs the units that differ (compared with `cmp`) and the binary, restarts, checks (every service active, or `-HealthUrl` answers, with parts read from the env file), and rolls everything back together on failure.
- `Restore-ServiceBinary`: puts the previous binary, units, vhost and optionally the newest database snapshot back after a failed smoke check, compressed or, from before 2026-11-06, not.

Folder swaps:

- `Switch-RemoteDirectory`: swaps a folder from the upload into place by renames, keeping `<live>.old`, with hooks before and after the swap.
- `Restore-RemoteDirectory`: puts `<live>.old` back.
- `Switch-RemoteItemSet`: swaps several top-level entries of one folder (a PHP app's code) through a staging folder, and puts the old ones back if a later step fails.
- `Restore-RemoteItemSet`: puts that backup back.

Database snapshots:

- `Backup-RemoteDatabase`: returns a shell block for a step's hook that snapshots a site's SQLite database to `Install-ServiceBinary -Database`'s standard, with the same shell underneath, for a PHP site's migrations. The path is given (`-Database`) or read from a shell variable at run time (`-DatabaseVariable`, such as one set from the host's `.env`). With `-Owner` everything it writes beside the database is written as that user through `runuser`, under `-Umask` if given. Afterwards `$snapshot`, `$snapshot_db` and `$snapshot_restore` (the exact command that puts it back) are set for the step's failure message; the returned string carries the same as `.Snapshot`, `.Database` and `.Restore` for the deploy script's own messages when the path is given.

Plugins:

- `Export-PluginRepository`: lays out a Dalamud repository folder locally, refuses a built version that differs from the index's, and cache-busts the download links with `?v=<version>`.
- `Publish-PluginRepository`: on the host, refuses a version that is not higher than the published one, then swaps the repository folder in.

Scheduled backup:

- `Install-BackupTimer`: a daily systemd timer and its oneshot service, with Kindred Nights' hardening. It renders the units and the shared job, installs them only where they differ from the live copies (`cmp`), runs the service once to check them, and puts the previous copies back if that run fails. The shared job writes a `VACUUM INTO` copy of the live database, checks it with `PRAGMA integrity_check`, compresses it with gzip and checks that (`gzip -t`), names it `<prefix>YYYY-MM-DD<suffix>.gz` (UTC) and keeps 28 days, leaving every other file in its folder alone. `-Command` runs a project's own job instead (Kindred Nights' `kindred backup`). Call it after the smoke check.

Development database:

- `Copy-LiveDatabase`: an online `sqlite3 .backup` on the host, a checked download, three timestamped local copies kept, the host's copy removed; warns and skips if the local database is in use. The host's copy lives only for the pull, so it is not compressed. `-Owner` makes it as the database's user (`runuser`), so it can sit beside a database whose folder holds only that user's files.

Smoke check:

- `Invoke-SmokeCheck`: fetches each URL from this machine, checks its status (200 unless given) and optional text, tries each up to `-Attempts` times; on a failure runs `-Rollback` and throws. It needs `-Rollback`, or `-NoRollback` for a deploy with nothing to undo.

## Backups on the droplet

Every backup the module keeps on the droplet is compressed with gzip (decided 2026-11-06). Each is written to a `.partial` file, checked with `PRAGMA integrity_check`, compressed to another `.partial`, checked with `gzip -t`, and only then renamed into place, with no uncompressed copy left behind.

| What | Name before 2026-11-06 | Name now | Kept |
| --- | --- | --- | --- |
| `Install-ServiceBinary -Database`'s snapshot, taken after the stop | `<SnapshotPrefix><yyyyMMdd-HHmmss><SnapshotSuffix>` | the same, then `.gz` (UTC) | the newest three, across both forms |
| `Backup-RemoteDatabase`'s snapshot, taken where the step puts it (before the migrations) | a site's own copies of that form, such as `.backups/example-<yyyyMMdd-HHmmss>.db` | the same, then `.gz` (UTC) | the newest `-Keep` (three), across both forms |
| `Install-BackupTimer`'s shared job, daily | `<Prefix>YYYY-MM-DD<Suffix>` | the same, then `.gz` | 28 days, both forms pruned by date |

The prefix defaults are `<Database>.pre-` and `<Name>-`; `Backup-RemoteDatabase` takes a relative `-SnapshotPrefix` from the database's folder. Only names of exactly these forms are pruned, compressed or restored; nothing else in the folders is touched, apart from a run's own `.partial` files. So a site that kept uncompressed snapshots under such names before, like the Gallery's `gallery-<yyyyMMdd-HHmmss>.db` in `.backups/`, passes that prefix and suffix, and its old copies count among the kept and age out.

Older copies need nothing done by hand. The daily job's first run after the change, which the next deploy triggers since the job changed, compresses every uncompressed dated copy and keeps its time. Old snapshots stay as they are: a restore takes the newest snapshot of either form, and they age out over the next three deploys.

To put one back by hand, stop the service, remove the database's `-wal` and `-shm`, and decompress into the database file in place, which keeps its owner and mode:

```sh
systemctl stop example
rm -f /opt/example/data/example.sqlite-wal /opt/example/data/example.sqlite-shm
gunzip -c /opt/example/data/backups/example-2026-11-06.sqlite.gz > /opt/example/data/example.sqlite
systemctl start example
```

`Install-ServiceBinary` prints these commands, with its snapshot's paths, after a rollback in a project that has not opted into `-RestoreDatabaseOnRollback`, `Backup-RemoteDatabase` sets them as `$snapshot_restore` (with `systemctl stop` and `start` of its `-Service`) for the step's own message, and the shared job's script on the host carries them, with its paths, in its header. A project's own backup command (`-Command`) keeps its own copies, so compressing them is up to that command.

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

A PHP site's snapshot before its migrations, the path read from the host's `.env` (Simple Image Gallery's shape), five kept in a `.backups` folder beside the database. A failed migration prints the command that puts the snapshot back, and `Switch-RemoteItemSet`'s trap puts the previous code back:

```powershell
$afterSwap = Format-RemoteScript -Value @{
    SNAPSHOT = Backup-RemoteDatabase -DatabaseVariable 'DB' -SnapshotPrefix '.backups/example-' -SnapshotSuffix '.db' -Keep 5
} -Template @'
DB=$(grep -E '^DB_DATABASE=' .env | head -n 1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//')
__SNAPSHOT__
if ! php artisan migrate --force --no-interaction; then
  echo 'The migrations failed.' >&2
  if [ -n "$snapshot" ]; then echo "To put the database back, with the site's writes stopped: $snapshot_restore" >&2; fi
  exit 5
fi
'@
Switch-RemoteItemSet -Archive 'example-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
    -Root '/var/www/example.com' -Item 'app', 'config', 'public' -AfterSwap $afterSwap
```

A site whose database belongs to `www-data` (TarotGen.io's shape): the snapshot made as `www-data` under umask 077 before the swap, `<Database>.pre-<time>.gz` with three kept, and the same restore command in the deploy script's own message:

```powershell
$snapshot = Backup-RemoteDatabase -Database '/var/lib/example/db/example.db' -Owner 'www-data' -Umask '077'
$afterSwap = @'
if ! runuser -u www-data -- php vendor/bin/phinx migrate; then
  echo "The migrations failed. To put the database back, with the site's writes stopped: $snapshot_restore" >&2
  exit 6
fi
'@
Switch-RemoteItemSet -AsStep -Root '/var/www/example.com' -Item 'api', 'vendor' -Prepare $snapshot -AfterSwap $afterSwap
# ...after a failed smoke check:
throw "The database stays as the migrations left it. To put back $($snapshot.Snapshot), run on the host: $($snapshot.Restore)"
```

The block is plain shell, not a subshell, so its variables reach the lines after it in the same step (`-Prepare` and `-AfterSwap` are one step), but not a later step of `Invoke-DeployBundle`. A failure exits 3 (an empty path, a missing `sqlite3`, `gzip` or `runuser`) or 4 (a failed integrity check), so the step stops and its trap puts its changes back; the earlier snapshots stay as they are. A database that is not there yet is skipped, with `$snapshot` empty.

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
