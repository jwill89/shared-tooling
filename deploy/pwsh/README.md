# deploy/pwsh: the SharedDeploy module

One PowerShell module for the pieces every deploy script needs: settings, the SSH connection, the one archive a deploy ships, the atomic swap of a folder, a code set, a binary or a plugin repository, the service restart and its check, rollback, the dev-database pull, and a smoke check after the deploy. Each function's help (`Get-Help <name> -Full`) gives the detail.

The module holds no host names, users, keys, tokens or addresses. Those stay in each project's git-ignored `scripts/deploy.config.ps1`, read through `Resolve-DeploySetting`.

## Setting names

Every project names the same thing the same way, as `$Deploy<Name>` in `deploy.config.ps1` and `$env:DEPLOY_<NAME>` in the environment. A project reads only the settings it needs, and its `scripts/deploy.config.example.ps1` lists them.

| Name | What it holds |
| --- | --- |
| `VpsHost`, `VpsUser`, `KeyPath` | The SSH connection: the host, the user, the PuTTY key. Always required. |
| `HostKey` | Optional: the host key plink checks, `SHA256:<fingerprint>`. Unset, PuTTY's cached key is used. |
| `SiteUrl` | The address the smoke check fetches, as visitors reach it. |
| `ServiceName` | The systemd service. |
| `ServiceUser` | The account the service or site runs as. |
| `RemoteOptDir` | The folder that holds a service's binary. |
| `AppPort` | The loopback port the service listens on, which its vhost proxies to. |
| `EnvFile` | The service's root-only env file; `/etc/<service>/<service>.env` if unset. |
| `WebRoot` | The folder a site or PHP app lives in on the host. |
| `ServerName`, `ServerAlias` | The vhost's names; `ServerAlias` may hold several, space-separated. |
| `ServerAdmin` | The vhost's admin address. |
| `CertName` | The certificate: its folder's name under `/etc/letsencrypt/live`, not a path. |
| `BackupDir` | Where a backup the deploy installs writes, outside the web root. |

Some things are deliberately not settings:

- **Fixed paths:** the Cloudflare ranges file `mod_remoteip` reads is `/etc/apache2/cloudflare-ips.txt` on every host.
- **The vhost's file:** it is named after the service or the site's `ServerName` (see [The vhost](#the-vhost)), and the sites it replaces are disabled by the deploy, not by hand.
- **One-time changes on the host,** such as moving an env file: these are written steps in the project's `docs/ops.md`, under `Upgrading to x.y.z`.

## The shape of every deploy

Everything a deploy needs goes into ONE archive: the binary, systemd units, env templates, `.htaccess`, plugin files, the static `dist`. Then:

1. `Open-DeployConnection` opens one SSH connection and holds it for the whole run.
2. `Compress-DeployArchive` packs the archive and returns its SHA-256 and file count.
3. `Invoke-Upload` streams it to the host.
4. One remote run unpacks it to a staging folder, checks the SHA-256 and file count, and only then runs the steps: `Install-ServiceBinary`, `Switch-RemoteDirectory`, `Switch-RemoteItemSet` or `Publish-PluginRepository` on their own, or several of them as `-AsStep` blocks of one `Invoke-DeployBundle`.
5. `Invoke-SmokeCheck` fetches the site and, if it fails, runs the rollback.
6. For a project with a database: `Install-BackupTimer` keeps its daily backup installed and checked, and `Copy-LiveDatabase` pulls a copy to the dev machine, the one copy that leaves the host.
7. `Close-DeployConnection` in a `finally` block.

A host that runs `ufw limit ssh` refuses an address after six connections in 30 seconds. This shape opens one: every command, upload and download rides the held connection, so a deploy with several targets (a backend, its frontend and a plugin) is one connection and one remote run, with no pauses between targets.

Single-file uploads (`Send-File`, `Send-FileVerified`) stay for the rare case that cannot ship one archive.

## Requirements

- PowerShell 7.4 or later (`CompatiblePSEditions = 'Core'`), on Windows.
- PuTTY's `plink` 0.85 or later (connection sharing), on PATH or in `C:\Program Files\PuTTY`, with the key loaded in Pageant if it has a passphrase. pscp is not used.
- Windows' own `tar.exe` for `Compress-DeployArchive`.
- On the host: bash as the SSH user's shell, systemd, GNU coreutils (`sha256sum`, `cat`, `sort -V`, `stat`), `sqlite3` and `gzip` for database snapshots and backups, `runuser` (util-linux) for an `-Owner` on `Backup-RemoteDatabase` or `Copy-LiveDatabase`, `curl` for `-HealthUrl`, and for a vhost, Apache in Debian's layout (`/etc/apache2` with `sites-available` and `sites-enabled`, and an `apachectl` that reads `APACHE_CONFDIR`).

## The one connection

`Open-DeployConnection` starts a hidden `plink -batch -share -N` that logs in and holds the connection, and waits until `plink -share -shareexists` reports it is up. Every remote call then runs as `plink -batch -share`, which rides that connection and opens none of its own.

A remote script goes to the host on plink's standard input, never as plink's command: the shared connection ends a command over about 16 KB (`FATAL ERROR: Error 109: The pipe has been ended`) before the host runs any of it, while the connection itself stays up. plink's command is a short, fixed one that reads the script, checks its SHA-256, prints a line saying it started, and runs it as sshd would have (`$SHELL -c`), with an empty standard input and its errors merged into its output in order. So a script runs whole or not at all, up to the 128 KB Linux takes in one argument; a longer one is refused before anything is sent. A step that never started (plink could not connect, or the script arrived incomplete) fails saying none of it ran, rather than as a failure on the host, and is not retried unless the connection dropped.

Uploads and downloads stream through plink too: the archive is the standard input of `cat > <file>` on the host, and a download is the standard output of `cat <file>`, checked against the host's `sha256sum`.

Before each remote step the holder is checked; if it has exited, a new one starts (one new connection) and a line says it reconnected. A step that failed because the connection dropped is retried once after reconnecting. A reconnect is tried at once, and only if it is refused (the ufw window) does it wait 35 seconds and try once more. Marker files in the SSH user's `~/.shared-deploy` let a retried remote run resume: steps that already finished are skipped, and a run that already completed says so and succeeds.

Nothing leaves a plink holding the connection: `Close-DeployConnection` stops it, `Fail` closes it before it exits, PowerShell's exit stops it, and the holder runs in a Windows job object that ends it with the PowerShell process, even one that was killed.

Connection sharing has run real deploys on one held connection, from the upload through the smoke check and the dev-database pull. The remote-script path above and the reconnect after the holder has exited are tested against a local OpenSSH server; a connection that drops in the middle of a step is still tested only against a stand-in plink.

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

- `Install-ServiceBinary`: for one service or a set: checks first (the binary and units are in the upload, the health URL can be built, the vhost goes in as [The vhost](#the-vhost) says), then stops them, keeps `<binary>.old`, snapshots the database with `sqlite3 .backup`, checked and compressed with gzip before anything is installed (newest three kept), installs the units that differ (compared with `cmp`) and the binary, restarts, checks (every service active, or `-HealthUrl` answers, with parts read from the env file), and rolls everything back together on failure.
- `Restore-ServiceBinary`: puts the previous binary, units, vhost (with the sites it replaced) and optionally the newest database snapshot back after a failed smoke check.

Folder swaps:

- `Switch-RemoteDirectory`: swaps a folder from the upload into place by renames, keeping `<live>.old`, with hooks before and after the swap; with `-Vhost` and `-ServerName`, the site's vhost goes in with it.
- `Restore-RemoteDirectory`: puts `<live>.old` back, and with `-ServerName` the vhost.
- `Switch-RemoteItemSet`: swaps several top-level entries of one folder (a PHP app's code) through a staging folder, and puts the old ones back if a later step fails; it takes `-Vhost` and `-ServerName` too.
- `Restore-RemoteItemSet`: puts that backup back, and with `-ServerName` the vhost.

Database snapshots:

- `Backup-RemoteDatabase`: returns a shell block for a step's hook that snapshots a site's SQLite database to `Install-ServiceBinary -Database`'s standard, with the same shell underneath, for a PHP site's migrations. The path is given (`-Database`) or read from a shell variable at run time (`-DatabaseVariable`, such as one set from the host's `.env`). With `-Owner` everything it writes beside the database is written as that user through `runuser`, under `-Umask` if given. Afterwards `$snapshot`, `$snapshot_db` and `$snapshot_restore` (the exact command that puts it back) are set for the step's failure message; the returned string carries the same as `.Snapshot`, `.Database` and `.Restore` for the deploy script's own messages when the path is given.

Plugins:

- `Export-PluginRepository`: lays out a Dalamud repository folder locally, refuses a built version that differs from the index's, and cache-busts the download links with `?v=<version>`.
- `Publish-PluginRepository`: on the host, refuses a version that is not higher than the published one, then swaps the repository folder in.

Scheduled backup:

- `Install-BackupTimer`: a daily systemd timer and its oneshot service, with the standard hardening. It renders the units and the shared job, installs them only where they differ from the live copies (`cmp`), runs the service once to check them, and puts the previous copies back if that run fails. The shared job writes a `VACUUM INTO` copy of the live database, checks it with `PRAGMA integrity_check`, compresses it with gzip and checks that (`gzip -t`), names it `<prefix>YYYY-MM-DD<suffix>.gz` (UTC) and keeps 28 days, leaving every other file in its folder alone. `-Command` runs a project's own job instead (`myapp backup`, say). Call it after the smoke check.

Development database:

- `Copy-LiveDatabase`: an online `sqlite3 .backup` on the host, a checked download, three timestamped local copies kept, the host's copy removed; warns and skips if the local database is in use. The host's copy lives only for the pull, so it is not compressed. `-Owner` makes it as the database's user (`runuser`), so it can sit beside a database whose folder holds only that user's files.

Smoke check:

- `Invoke-SmokeCheck`: fetches each URL from this machine, checks its status (200 unless given) and optional text, tries each up to `-Attempts` times; on a failure runs `-Rollback` and throws. It needs `-Rollback`, or `-NoRollback` for a deploy with nothing to undo.

## Backups on the host

Every backup the module keeps on the host is compressed with gzip. Each is written to a `.partial` file, checked with `PRAGMA integrity_check`, compressed to another `.partial`, checked with `gzip -t`, and only then renamed into place, with no uncompressed copy left behind.

| What | Name | Kept |
| --- | --- | --- |
| `Install-ServiceBinary -Database`'s snapshot, taken after the stop | `<SnapshotPrefix><yyyyMMdd-HHmmss><SnapshotSuffix>.gz` (UTC) | the newest three |
| `Backup-RemoteDatabase`'s snapshot, taken where the step puts it (before the migrations) | `<SnapshotPrefix><yyyyMMdd-HHmmss><SnapshotSuffix>.gz` (UTC), such as `.backups/example-<yyyyMMdd-HHmmss>.db.gz` | the newest `-Keep` (three) |
| `Install-BackupTimer`'s shared job, daily | `<Prefix>YYYY-MM-DD<Suffix>.gz` | 28 days |

The prefix defaults are `<Database>.pre-` and `<Name>-`; `Backup-RemoteDatabase` takes a relative `-SnapshotPrefix` from the database's folder. Only names of exactly these forms are pruned, compressed or restored; nothing else in the folders is touched, apart from a run's own `.partial` files.

An uncompressed copy under one of these names, without the `.gz`, counts among the kept, so a site whose own snapshots already took that form passes the same prefix and suffix and its old copies age out. The daily job compresses each uncompressed dated copy it finds, keeping its time, and a restore takes the newest snapshot of either form.

To put one back by hand, stop the service, remove the database's `-wal` and `-shm`, and decompress into the database file in place, which keeps its owner and mode:

```sh
systemctl stop example
rm -f /opt/example/data/example.sqlite-wal /opt/example/data/example.sqlite-shm
gunzip -c /opt/example/data/backups/example-2026-01-31.sqlite.gz > /opt/example/data/example.sqlite
systemctl start example
```

`Install-ServiceBinary` prints these commands, with its snapshot's paths, after a rollback in a project that has not opted into `-RestoreDatabaseOnRollback`, `Backup-RemoteDatabase` sets them as `$snapshot_restore` (with `systemctl stop` and `start` of its `-Service`) for the step's own message, and the shared job's script on the host carries them, with its paths, in its header. A project's own backup command (`-Command`) keeps its own copies, so compressing them is up to that command.

## The vhost

A site has one vhost file, holding its port-80 redirect to HTTPS and its port-443 site: `/etc/apache2/sites-available/<name>.conf`. `<name>` is the service's name (the first `-ServiceName`) for an app that runs a service, and the site's `ServerName` (`-ServerName`) for a site Apache serves from a folder, in lower case. The file is a template in the project's repo, filled from the deploy config when the deploy packs the archive (`Format-RemoteScript`); `-Vhost` names it inside the upload. `Install-ServiceBinary`, `Switch-RemoteDirectory` and `Switch-RemoteItemSet` all take it.

Every deploy that ships the file does this before anything else on the host changes:

1. It finds every other enabled site serving one of the file's `ServerName` and `ServerAlias` names, from `apachectl -S` with aliases included: certbot's `<name>-le-ssl.conf`, say, or an old pair under other names.
2. It refuses, changing nothing, when one of those sites is not a link in `sites-enabled` or serves a name the new file doesn't, or when the new file drops a port those names are served on now, by those sites or by the file it replaces (a template without its port-80 block would drop the redirect). A site file's names are read with its CRs dropped, since a file saved with Windows line endings would otherwise end each name with one. For a site served from a folder, the file must also declare `ServerName <name>`.
3. It tries Apache with the new file enabled and those sites gone, on a copy of `/etc/apache2` (`APACHE_CONFDIR`, `apachectl -t`), and refuses, changing nothing, if Apache would.
4. It installs the file where it differs (the previous kept as `<name>.conf.old`), enables it where it isn't, disables those sites, and runs `apachectl configtest`.

Apache reloads once the rest of the deploy has succeeded. Each change is written to `<name>.conf.rollback` before it is made, so a failure later in the run, a retry after a dropped connection, or the `Restore-` function after a failed smoke check puts the file and every site back as they were; the disabled sites stay in `sites-available` for that. `-NoBackup` removes both copies once the deploy succeeds.

When the file is already in place, enabled and alone on its names, the deploy runs `apachectl -S` and leaves Apache as it is. So a project that already ships one file sees nothing new, and a stray site (a `-le-ssl` file certbot wrote, a site enabled by hand) is retired by the next deploy.

`Install-ServiceBinary -VhostPath` is still taken from deploys written before the file was named after the service, for a `.conf` file in `sites-available`. Certbot never edits these files; [deploy-and-ops.md](../../standards/deploy-and-ops.md#apache-and-cloudflare) says what to do if it does.

## A deploy script on the module

A front end swapped whole, with its `.htaccess`, then a smoke check that rolls back on failure (the site's address goes in `deploy.config.ps1` as `$DeploySiteUrl`):

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
    $upload = Invoke-Upload -Path $archive.Path -Destination 'example-deploy.tgz' -Activity 'Uploading example' -FileCount $archive.FileCount
    if (-not $upload.Ok) { Fail "Upload failed. Live site untouched.`n$($upload.Err)" }

    Write-Step 'Checking the upload and swapping it in...'
    Switch-RemoteDirectory -Archive 'example-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
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

A service binary and its unit, such as a bot's. Everything uploads first; nothing stops until the archive on the host has been checked:

```powershell
$archive = Compress-DeployArchive -Content ([ordered]@{
        'example'         = Invoke-GoBuild -Path $repoRoot -Output 'example'
        'example.service' = Join-Path $repoRoot 'deploy\example.service'
    })
# ...Invoke-Upload to 'example-deploy.tgz'...
Install-ServiceBinary -Archive 'example-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
    -ServiceName $settings.ServiceName -Binary "$($settings.RemoteOptDir)/example" -Unit 'example.service' -UnitMode '600'
```

Several targets in one archive and one remote run (a backend, its frontend and a plugin), API first:

```powershell
Invoke-DeployBundle -Archive 'example-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount -Step @(
    Install-ServiceBinary -AsStep -ServiceName $settings.ServiceName -Binary "$($settings.RemoteOptDir)/example" -Database $settings.RemoteDbPath
    Switch-RemoteDirectory -AsStep -Live "$($settings.WebRoot)/dist" -File @{ '.htaccess' = "$($settings.WebRoot)/.htaccess" }
    Publish-PluginRepository -AsStep -Live "$($settings.WebRoot)/plugin" -Version $repo.Version -IndexPath 'pluginmaster.json'
)
```

A Grav plugin or theme folder swapped whole, then the cache cleared:

```powershell
$archive = Compress-DeployArchive -Content @{ 'unlisted' = Join-Path $repoRoot 'user\plugins\unlisted' }
# ...Invoke-Upload to 'grav-deploy.tgz'...
Switch-RemoteDirectory -Archive 'grav-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
    -Live "$webRoot/user/plugins/unlisted" -Owner 'www-data' `
    -AfterSwap "sudo -u www-data php '$webRoot/bin/grav' clearcache --all >/dev/null"
```

A PHP site in a folder of its own, with Apache's DocumentRoot pointed at it, its PHP checked on the host's PHP before the swap:

```powershell
Switch-RemoteDirectory -Archive 'site-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
    -Live "$webRoot/site" -BeforeSwap 'for f in $(find "$new" -name "*.php" -type f); do php -l "$f" >/dev/null || exit 4; done'
```

A Dalamud plugin repository:

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

A static site whose vhost ships with it, rendered from the template in the release's checkout, and its rollback. The vhost becomes `example.com.conf`:

```powershell
$template = Get-Content -Raw -LiteralPath (Join-Path $tree 'deploy\apache-vhost.conf')
$vhost = Join-Path $tree 'deploy\apache-vhost.rendered.conf'
Set-Content -LiteralPath $vhost -NoNewline -Value (Format-RemoteScript $template @{ SERVER_NAME = $settings.ServerName; CERT = $settings.CertName })
$archive = Compress-DeployArchive -Content ([ordered]@{ 'site' = Join-Path $tree 'dist'; 'apache-vhost.conf' = $vhost })
# ...Invoke-Upload to 'example-deploy.tgz'...
Switch-RemoteDirectory -Archive 'example-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
    -Live "$($settings.WebRoot)/site" -Vhost 'apache-vhost.conf' -ServerName $settings.ServerName
Invoke-SmokeCheck -Url $settings.SiteUrl -Rollback {
    Restore-RemoteDirectory -Live "$($settings.WebRoot)/site" -ServerName $settings.ServerName
}
```

A set of services with their units, a vhost and a health URL read from the env file. The vhost becomes `example.conf`:

```powershell
Install-ServiceBinary -Archive 'example-deploy.tgz' -Sha256 $archive.Sha256 -ExpectedFileCount $archive.FileCount `
    -ServiceName 'example', 'example-worker' -Binary '/opt/example/example' -Owner 'root' -Umask '077' `
    -Unit 'deploy/example.service', 'deploy/example-worker.service', 'deploy/example-backup.service', 'deploy/example-backup.timer' `
    -Vhost 'deploy/apache-vhost.conf' `
    -EnvFile '/etc/example/example.env' -HealthUrl 'http://{EXAMPLE_ADDR}/healthz' -HealthDefault @{ EXAMPLE_ADDR = 'localhost:8080' } `
    -Database '/opt/example/data/example.sqlite' -SnapshotPrefix '/opt/example/backups/example-pre-' -SnapshotSuffix '.sqlite' -RestoreDatabaseOnRollback
```

A PHP site's snapshot before its migrations, the path read from the host's `.env` (a Laravel site), five kept in a `.backups` folder beside the database. A failed migration prints the command that puts the snapshot back, and `Switch-RemoteItemSet`'s trap puts the previous code back:

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

A site whose database belongs to `www-data`: the snapshot made as `www-data` under umask 077 before the swap, `<Database>.pre-<time>.gz` with three kept, and the same restore command in the deploy script's own message:

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
