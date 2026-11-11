# Deploy and operations

How a project ships to the droplet and runs there: the deploy, smoke checks and rollback, host setup, systemd services, Apache and PHP hosting, logs, caching, backups, restores and the database pull.

The shared deploy module (SharedDeploy, in `deploy/pwsh`) does most of a deploy. A rule marked [module] is one the module already does; its [README](../deploy/pwsh/README.md) has the mechanics, and a project's deploy script calls it rather than doing that step its own way. SQLite settings, migrations and schema are in [database.md](database.md).

## Running a deploy

- A deploy runs from the owner's PC as `task deploy`, through the project's `scripts/deploy.ps1` on the module. [review]
- `task deploy` deploys everything the project has, in order: the backend, then the front end (a new front end may call API the old backend lacks), then the plugin. Where the parts ship separately, each also deploys alone as `task deploy:backend`, `task deploy:frontend` and `task deploy:plugin`; there is no `deploy:both` or `deploy:all`. A project whose parts ship in one archive, or whose front end is inside its binary, has no `deploy:frontend`. [review]
- The plugin step of `task deploy` publishes only a new version: one already published is skipped with a note (the script's `-IfNewer`), so a deploy that didn't raise the plugin's version still succeeds. `task deploy:plugin` refuses a version that isn't higher, since Dalamud updates to nothing else. [review]
- CI builds and checks, but never deploys. [review]
- The deploy machine has what the module's README lists under Requirements: PowerShell 7.4 or later, Windows' `tar.exe`, PuTTY's `plink` 0.85 or later, and a passphrase-protected key loaded in Pageant. [module]
- Every host-specific setting (host, SSH user, key, paths, service name) comes from a parameter, then `$env:DEPLOY_*`, then the git-ignored `scripts/deploy.config.ps1`, copied from a tracked `deploy.config.example.ps1` (`Resolve-DeploySetting`). [module]
- Every deploy config names its SSH user; nothing defaults to root. [module]
- Missing settings fail the deploy before it builds or connects, all listed in one error. [module]
- Nothing tracked reveals the server's layout: the example config holds placeholders only (see [security.md](security.md)). [review]
- A deploy ships the newest release: the newest tag CI made on main, with the tags fetched first (`Get-DeployRelease`). HEAD need not carry it, and commits after it (a shared-tooling update, work not yet released) are not part of it. [module]
- The release is checked out into a folder of its own, with its submodules and an `npm ci` from its lockfiles, and built and packed from there (`New-ReleaseTree`, then `Remove-ReleaseTree` in a `finally`). Nothing uncommitted and no package installed for HEAD reaches it. npm takes the packages from its cache by the lockfile's integrity, so nothing already downloaded, a Font Awesome kit included, is fetched again. Untracked files a deploy needs (a bot's unit, a local `.env`) are read from the checkout. [module]
- The host records the release each deploy leaves running, in `~/.shared-deploy/<name>` of the SSH user, once the site has passed its checks (`Set-DeployedRelease`); a rolled-back deploy leaves the record as it was. A deploy reads it first (`Get-DeployedRelease`) and does nothing when the host already runs the release; `-Force` deploys it again. [review]
- An untagged tree ships only as a preview, behind the deploy script's `-Preview` switch, which builds the working tree and stamps the build `preview-<date-time>` in place of a tag. The host records the stamp, so the next release deploy goes out. `-SkipBuild`, where a script has it, goes with `-Preview` alone: a release is always built from its tag. [review]
- The switch that skips the database pull is `-NoDbPull`. [review]
- A local copy never runs with production credentials (a bot's token) while production is running, since both would handle every event. [review]

## The shape of a deploy

- A deploy builds and packs everything into one archive before anything on the host changes, so a broken build changes nothing. It may connect first, to read which release the host runs. [module]
- It holds one SSH connection for the whole run, and one remote run checks the archive's SHA-256 and file count before anything live changes. [module]
- A deploy ships code and config only, never `.env`, the data, the backups or user uploads. [review]
- Live files never change in place: the new tree is built whole beside the live one, swapped in by renames, and the previous copy is kept for rollback (`Switch-RemoteDirectory`, `Switch-RemoteItemSet`). A release folder behind a `current` link follows the same rule. [module]
- Upload folders sit beside the swapped folder (siblings of `dist/`), so a swap never wipes them. [review]
- When one run deploys several parts, the API goes first, then the SPA, then the plugin, since a new backend still serves the old SPA while a new SPA may call endpoints an old backend lacks. [review]
- A release that needs steps beyond the deploy (a new host setting, a manual backup, a backfill) lists them in order in the project's `docs/ops.md`, under an `Upgrading to x.y.z` heading, and they run in that order. Its CHANGELOG entry says only that it needs a step at deploy, and where the steps are ([docs-and-agents.md](docs-and-agents.md)). [review]

## Builds

- Production runs no Node server: a front end ships as built static files. [review]
- A Go service ships as one static `linux/amd64` binary (`CGO_ENABLED=0`, `-ldflags="-s -w"`), built the same way in CI (`Invoke-GoBuild`). [module]
- A Go app embeds its built front end in the binary with `embed.FS`, so Apache serves none of the app's content. The front end therefore builds before any Go build, test or lint. [review]
- A service reports its version and commit (through ldflags or `debug.ReadBuildInfo`) on its version or health endpoint and in its first log line, so the smoke check can tell the new build is the one answering. [module]
- A plugin release deletes `bin/` and `obj/`, builds in Release, refuses a built version that differs from its manifest or isn't above the published one, adds `?v=<version>` to its download links, swaps the repository folder whole, and puts it back if the published index lacks the new version (`Invoke-PluginBuild`, `Export-PluginRepository`, `Publish-PluginRepository`). [module]
- CI builds a plugin on Linux whenever its files change, against Dalamud's dev distribution with `EnableWindowsTargeting`, and runs `dotnet format --verify-no-changes`. [CI]

## Smoke checks and rollback

- A service deploy uploads everything before it stops anything. It then stops the service, keeps `<binary>.old`, snapshots the database, installs, starts, and waits up to 30 seconds for every service to be active or its health URL to answer, putting the old binary back if not (`Install-ServiceBinary`). [module]
- Every web service has `GET /healthz`, which answers 200 with its version when it and its database work, and 503 when the database doesn't. [review]
- The deploy's start check waits for `/healthz`. [module]
- `/healthz` answers publicly, through Cloudflare, so an uptime check can poll it and the smoke check can fetch it; it returns nothing private. [review]
- A service with no health URL (a bot) is `Type=notify` and reports ready only once it is (logged in), so a start that can't connect fails the deploy and rolls back. [module]
- After the swap the deploy smoke-checks the public site from the dev machine, through Cloudflare, trying each URL several times: the API answers with data or names the new version, `/` names this build's entry script, and a plugin index carries this release's `?v=` (`Invoke-SmokeCheck`). [module]
- Each smoke-check URL carries a fresh `?deploy=` token, so no edge-cached answer can pass. [review]
- A failed smoke check rolls back on its own. [module]
- A rollback undoes the run in reverse order: the plugin and front end first, then the backend. [review]
- A failed start or smoke check puts the pre-deploy database snapshot back only where the project opts in with `-RestoreDatabaseOnRollback`. [module]
- A project that takes uploads during a deploy doesn't opt in: its database stays as the migrations left it, and the module prints the snapshot's restore command. [module]
- Each project lists what can only be checked on production, and checks it right after each deploy in a fresh browser tab with the console open. [review]

## Host setup and server config

- One-time host setup (the service user, folders, env file, certificate, DNS) is an idempotent script, run once as root and written in the project's `docs/ops.md`. [review]
- A later deploy appends a host-only env line only when the env file lacks it. [review]
- A service's systemd units and its Apache vhost live in the repo as templates, and every deploy ships them, so the host always runs what the repo says. Host-specific values (server names, the certificate, ports, paths, the service user) are placeholders in the template, filled from the git-ignored deploy config when the deploy script packs the archive (`Format-RemoteScript`). [review]
- The deploy installs a unit or the vhost only where it differs from the live copy, checks the vhost with `apachectl configtest` before anything stops, and puts every previous copy back if the start or a check fails (`Install-ServiceBinary -Unit`, `-Vhost`). The backup timer's units are installed the same way, by `Install-BackupTimer`. [module]
- Nobody edits a unit or a vhost on the host: a change goes into its template and ships with the next deploy. [review]
- A unit holds no secret, so it can be tracked: secrets go in the service's `EnvironmentFile` ([security.md](security.md)). [review]
- `.htaccess` files, cron files and every script a timer or cron runs live in the repo and ship with the deploy; nobody edits them on the host or copies them there by hand. [review]
- A config file the deploy ships is installed only where it differs, checked after (the expected paths, then status and header checks), and put back from its previous copy if a check fails. [review]
- Scheduled jobs other than the backup timer go in the site's own file in `/etc/cron.d` (`root:root`, mode 644, LF line endings, a trailing newline), and no other site's crontab is touched. [review]
- System libraries come from the distro, never self-built into `/usr/local/lib`, where they would shadow the distro's copy for every program and miss its security updates. [review]

## Services and systemd

- Each service runs as its own locked system account, named in `User=` and `Group=`, with no home and a `nologin` shell: never root, never `DynamicUser=`. [review]
- The code a service runs, its binary and `/opt/<app>`, is owned by that service's own unprivileged user. `ProtectSystem=strict` keeps it read-only to the running service. [review]
- Units carry the shared hardening block: `NoNewPrivileges`, `ProtectSystem=strict` with every folder the service writes in `ReadWritePaths`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, the kernel, control-group and namespace protections, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `LockPersonality`, `SystemCallFilter=@system-service` and `SystemCallArchitectures=native`. The module's backup units use the same block. [review]
- A pure-Go binary also gets `MemoryDenyWriteExecute=yes`, dropped only if it ever adopts a run-time code generator. [review]
- A service that writes log files gets `LogsDirectory=`, never a writable `/var/log`. [review]
- Units restart on failure: `Restart=on-failure` with a `RestartSec=` pause. [review]
- A service that can grow gets a memory cap (`MemoryMax=`), since the droplet's memory is tight. [review]
- Heavy or long work (backfills, maintenance scripts, a worker's external tools) runs outside the request path, never in a web request, at the lowest CPU and I/O priority (`nice -n 19`, `chrt --idle`, `ionice -c3`). [review]
- A Go worker is the same binary run as a subcommand under its own unit, capped in CPU and memory, with no network. [review]

## Apache and Cloudflare

- A web app listens on the loopback address only, on its own port from the droplet's one port list. [review]
- Cloudflare fronts every name. [review]
- Apache terminates TLS with the droplet's shared certificate and proxies with `ProxyPreserveHost` and `X-Forwarded-Proto`. [review]
- Apache takes the visitor's address from `CF-Connecting-IP`, trusted only from Cloudflare's published ranges ([security.md](security.md) has the detail). [review]
- An event stream gets a long proxy timeout, and `text/event-stream` is never compressed, since compressing it holds events back in a buffer. [review]

## PHP sites

- A PHP site's document root is its `public/` folder, so code, `vendor/`, scripts, `.env`, the data and the backups are never under it. [review]
- A PHP deploy runs `composer install --no-dev` on the host every time, starting from a copy of the live `vendor/`. [review]
- Production's dependencies are checked with `composer audit --no-dev`. [review]
- Under PHP-FPM, PHP settings and env go in the pool, the vhost (`SetEnv`) or `public/.user.ini`, never in `.htaccess` `php_value` lines, which FPM ignores. [review]
- A `php_value` line that must stay sits inside `<IfModule php_module>`, since without mod_php a bare one makes Apache answer 500. [review]
- Production PHP runs with `display_errors = Off` and `log_errors = On`. [review]

## Logs

- A Go service logs structured JSON with `log/slog` to stdout, which journald keeps. [review]
- Its level sits in a `slog.LevelVar`, so Debug can be turned on at run time. [review]
- Each scheduled job logs to the journal under its own tag (`journalctl -t <name>`). [review]
- Each log line is weighed at its event's real frequency: a high-frequency event stays at Debug or goes. [review]
- A failure is logged once, by the caller that decides to retry or return. [review]
- A request dropped because its client left logs at Debug, so it never reads as an outage. [review]

## Caching

The cache headers a site sends; [performance.md](performance.md) has the rest of caching.

- Only content-hashed build output (`-[hash].js`, `-[hash].css`) is cached `immutable`. [review]
- `index.html`, the service worker (`sw.js`, `registerSW.js`) and `*.webmanifest` are `no-cache`, so Cloudflare revalidates them and a new version installs on the next visit. [review]
- Other unhashed files get a short lifetime, from a day to a month. [review]
- A file replaced under the same name is purged from Cloudflare after the deploy; a new name needs no purge. [review]
- A file a client must never get stale (a plugin package and its index) is sent `no-store`. [review]
- Its download link carries the version, `?v=<version>`, which the module adds. [module]

## Backups

- Every backup kept on the droplet, daily copy or deploy snapshot, is checked with `PRAGMA integrity_check`, compressed with gzip and checked with `gzip -t` before it takes its place. [module]
- Every project with a database has a daily backup timer, which the deploy installs and checks after the smoke check (`Install-BackupTimer`). [module]
- The daily job writes a dated `VACUUM INTO` copy beside the database, as the database's own user, and keeps 28 days. [module]
- A new or changed timer runs once before it is kept; if that run fails, the deploy fails, saying the site is live but its backup isn't. [module]
- A project whose app has its own backup command runs it from the same timer (`-Command`), and that command checks and compresses its copies the same way. [review]
- A deploy that touches a database snapshots it first with `sqlite3 .backup`: after the service stops, or before a PHP site's migrations (`Install-ServiceBinary -Database`, `Backup-RemoteDatabase`). [module]
- A deploy keeps the newest three snapshots; a site's own count goes in `Backup-RemoteDatabase -Keep`. [module]
- If the snapshot fails, the deploy stops before it migrates. [module]
- A live database is copied only with an online backup (`sqlite3 .backup` or `VACUUM INTO`), never `cp`, which misses what is still in the `-wal`. [module]
- Backups and snapshots sit outside the web root, in a folder closed to all but their owner (mode 0700), each file mode 0600. [module]
- A deploy never chowns the data or the backups. [review]
- A destructive scheduled job (retention) runs only after that day's backup succeeded, chained with `&&` or ordered after the timer, and logs a skip when today's copy is missing. [review]
- Such a job has a `--dry-run` that runs the same DELETE in a rolled-back transaction, tried on production, also under cron's bare environment (`env -i`), before its schedule is installed. [review]

## Restores

- A restore stops the site's writes first (the service, or `php artisan down`), removes the `-wal` and `-shm` files, and decompresses the backup over the database in place as the database's user (`gunzip -c <backup> > <db>`), which keeps its owner and mode. The module prints the exact command. [review]
- Each project restore-drills its backup for real before launch, from steps in its `docs/ops.md`: restore into a scratch file, check `PRAGMA integrity_check`, and match row counts or known figures against live. [review]
- A change to a production database outside the app's migrations follows the rules in [database.md](database.md). [review]

## The database pull

- Each backend deploy pulls the live database to the dev machine unless run with `-NoDbPull`: an online backup, a checked download, three timestamped local copies kept, the host's copy removed, and a warning and a skip while a local server holds the file (`Copy-LiveDatabase`). [module]
- That pull is the one copy that leaves the droplet; adding an off-box store is the owner's call. [review]
- Development runs against that local copy at an absolute path, never against a database another app is using. [review]
