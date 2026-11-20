# Changelog

The changes a project would notice in shared-tooling, by release. A project takes a release with `task shared:update -- v<version>`; see README.md. The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/):

- **Major:** a project has to change its own files to take it (a renamed export, a removed input, a moved file).
- **Minor:** new rules, tasks or features. A new lint rule can raise findings in a project when it takes the release.
- **Patch:** fixes that change nothing a project relies on.

## [Unreleased]

## [2.19.2] - 2026-11-20

### Fixed

- `task shared:ci:share` runs the command it was given: a command with one argument, its default `task test` among them, reached the program a character at a time (`task t e s t`).

## [2.19.1] - 2026-11-20

### Changed

- The self-hosted runners hold the running jobs to `Cpus` of the distro's processors as a cpuset, where a CPU quota froze every running job at once whenever the jobs together had spent it, and `Cpus` is now a whole number. Each job is told its share of those CPUs, the config's new `JobCpus` (by default `Cpus` shared evenly between `MaxJobs`), in `CI_CPUS`, `GOMAXPROCS` and `DOTNET_PROCESSOR_COUNT`, so its tests run as many workers as it has CPUs; `MaxJobs` defaults to no more jobs than give each two CPUs; and `task shared:runner:status` shows the processors and the share. The runners take it when they next start from shared-tooling's own checkout (runner/README.md).

## [2.19.0] - 2026-11-20

### Added

- `task shared:ci:share` (`ci/Invoke-CiShare.ps1`) runs `task test`, or the command after `--`, with the CPUs a job on the self-hosted runners has: its share of them (the runners' `JobCpus`, or `CPUS=4`), given in `CI_CPUS`, `GOMAXPROCS` and `DOTNET_PROCESSOR_COUNT`, and the command held to that many processors. A test that passes only with a desk's spare CPUs fails there before it fails in CI; `standards/testing.md` asks for it of tests that wait or time something.
- `soon()` in `test/web/wait.js` waits for what a spec checks for up to `waitTimeout`, five seconds, exported from `test/web/vitest.js`, where `vi.waitFor` waits one second. A spec imports it by path, as `vite.config.ts` imports the preset.
- `@jwill89/lint-web` and `@jwill89/lint-web/react` refuse, in specs, a `vi.waitFor` or `vi.waitUntil` that names no timeout (`no-restricted-syntax`): wait with `soon()`, or pass one. A project whose specs set `no-restricted-syntax` themselves puts the shared entry first in theirs, from `specWaitRules`, a named export of both. `standards/testing.md` (Every stack, Vitest) has the rule.

### Changed

- `vitestDefaults` runs one worker for each CPU of `CI_CPUS` but one when it is set, so a CI job runs as many spec files at once as its share of the CPUs allows rather than one for every processor of the machine, and makes `waitTimeout` `expect.poll`'s default timeout in place of one second.

## [2.18.0] - 2026-11-17

### Added

- `task shared:web:audit` (`repo/Invoke-NpmAudit.ps1`) runs the npm audit `web.yml` runs, on a front end's folder (`DIR=web` by default), so a project's `task check` and CI pass over the same advisories. A project task that runs `npm audit --audit-level=high --omit=dev` itself swaps to it.

### Changed

- `web.yml`'s audit step honours the `osv-scanner.toml` beside the front end's lockfile, the file OSV-Scanner reads. It passes over each advisory an `[[IgnoredVulns]]` entry names by its GHSA id until the entry's `ignoreUntil`, printing each with its reason, and passes over with them each package npm flags only through those, such as `vue-router` through `picomatch`. Any other advisory of high severity or above in the packages that ship still fails it, and with no `osv-scanner.toml` it passes and fails as `npm audit --audit-level=high --omit=dev` did. `standards/packages.md` (Audits) says so.
- `repo/osv-scanner.example.toml` holds an entry for picomatch's ReDoS advisory (GHSA-fc5q-39xc-vjpf, through 4.0.7, no fixed release yet), which comes with Vite, Vitest, Stylelint, vue-tsc, ESLint's fast-glob and vue-router 5's build plugin. A project copies it beside each lockfile that has picomatch once it has checked its built app holds none of picomatch's code.

## [2.17.0] - 2026-11-17

### Added

- `changes.yml` runs only the CI jobs a change needs. A project's `ci.yml` names its areas in a `changes` job, and each job's `if:` reads whether its area changed (`fromJSON(needs.changes.outputs.areas).<area>`).
  - A push is compared with the newest commit of the branch whose CI passed, so a failed or cancelled run's changes are checked by the next one; a pull request is compared with its base.
  - Every job runs when `.github/`, `shared`, the Taskfile, `.editorconfig` or `.gitattributes` change; when a changed file matches no area and isn't Markdown, the licence or editor settings; and on any event other than a push or pull request.
  - `scripts` (PowerShell files) and `lockfiles` come with every repo.
  - A job that needs one that may be skipped, such as the release job, starts its `if:` with `!failure() && !cancelled()`.
  - `task shared:ci:changes` prints which jobs a push of the working tree would run.
- `report.yml` gives a failed run one report: every job's result, the step each failed job stopped at, and each failed check with the files and lines it names, the values of the variables its command used and its last lines of output. It heads the run's page and goes up as the `ci-report` artifact with each failed check's whole log. `task shared:ci:report` prints the branch's latest report, and `standards/docs-and-agents.md` has agents read it before a raw log. A project calls it last, `needs:` every other job, `if: failure()`.
- Every shared workflow runs its checks through `ci/Invoke-CiCheck.ps1`, so a failing check marks the lines it names on the commit and in a pull request's diff, and writes its failure to the job's summary. A project's own job can run its checks the same way (README, Adding it to a project).

### Changed

- `go.yml` and shared-tooling's own CI run golangci-lint with `go run` at the `golangci-lint-version` input, in place of `golangci/golangci-lint-action`: still built from source with the module's own Go, now through the report.
- `task shared:lint:scripts` and `pwsh.yml` print each PSScriptAnalyzer finding as one line, `path:line:col: severity rule: message`, which an editor's terminal links to the line, in place of a table.

## [2.16.1] - 2026-11-16

### Fixed

- `task shared:push` commits a Python update's `.in` file and the `.txt` compiled beside it as dependency files, where it stopped the push saying they changed while updating.

## [2.16.0] - 2026-11-16

### Fixed

- The deploy module's large transfers no longer crawl over the held connection: an upload or download of 1 MB or more (`Invoke-Upload`, `Send-File`, `Get-File`, and so `Copy-LiveDatabase`, `Copy-LiveFolder` and each `Sync-LiveFolder` batch) runs on an SSH connection of its own, about 8 MB/s where a channel of the shared one moved about 0.5 MB/s. A smaller one, and every remote command, still rides the held connection, and the module opens no more than four connections in any 30 seconds, waiting when it must, so `ufw limit ssh` never refuses one. `Get-File` reads the file's size and SHA-256 before the download rather than after.
- `Install-ServiceBinary -Database` takes its pre-deploy snapshot as the database file's own user, under umask 077, so the snapshot is that user's and 0600, as `Backup-RemoteDatabase` and the daily backups already were, where it was root's and 0644 without `-Umask 077`. Before anything stops it checks that user can write the snapshot's folder, and stops the deploy saying so when not: a project that keeps its snapshots in a folder only root can write gives that folder to the database's user first. The older root-owned snapshots age out over the next three deploys.

## [2.15.2] - 2026-11-16

### Added

- `task shared:deps:alerts` (`repo/Sync-DependabotAlerts.ps1`) holds Dependabot's alerts to the repo's `osv-scanner.toml` files: an open alert whose advisory one passes over, for the lockfile beside it, is dismissed as a tolerable risk with the entry's reason, and one it dismissed is opened again once the entry goes or its `ignoreUntil` passes. Dependabot's security update job then stops failing on an advisory with no fix in range. `-WhatIf` shows what it would do. `standards/packages.md` has the rule.

### Changed

- `task shared:push` runs `shared:deps:alerts` before it pushes; a failure there is a warning, and the push goes on.
- `task shared:web:specs -- --fix`, which `task shared:update` runs, writes a new `tsconfig.vitest.json` with the app config's `include` and `exclude` (the specs added where it misses them, and any pattern that would leave one out dropped) in place of `src/**` alone, so the specs' check sees the app's declaration files outside `src/` and leaves out what the app does, such as a service worker typed with a worker's globals.
- `typecheck-specs.mjs` (`web.yml`'s specs' check and `task shared:web:specs`) fails, naming the files, when `tsconfig.vitest.json` leaves out a declaration file the app's config takes in, in place of the type errors that followed.

### Fixed

- `task shared:changelog:links` and `shared:changelog:check` (and so `docs.yml`) take a version of four numbers, such as a Dalamud plugin's `## [4.0.0.0]`, which they passed over before, so its heading got no link and the check never saw it.

## [2.15.1] - 2026-11-15

### Fixed

- `runner/`: building the job image, at a start, at the six-hourly check or by hand, no longer removes the image a running scaler names, which left every job it was given queued. The scaler names `ci-runner:current`, which each build moves to the newest image, so new jobs take a rebuilt image at once; only a change to `scaler/` restarts the scaler.

## [2.15.0] - 2026-11-15

### Added

- `runner/`'s image has yq (mikefarah's, as on GitHub's image), which a project's release script may read YAML with.
- `runner/` keeps the jobs' download and build caches between jobs: every Linux job mounts the `ci-cache` volume at `/ci-cache`, where the image points Go's module and build caches, golangci-lint's, npm's and Composer's, and the Windows jobs keep theirs, golangci-lint's now among them, under `%USERPROFILE%\.ci-runner\windows`. `runners.psd1`'s `CacheSize` (30 GB) caps each; a start or the six-hourly check empties one grown past it.

### Changed

- On a self-hosted runner, `go.yml`, `osv.yml`, `web.yml`, `e2e.yml` and `php.yml` skip GitHub's cache for Go's caches, golangci-lint's, npm's download cache and Composer's `vendor`, which the runner keeps itself; `node_modules` still goes through it, for a run's later jobs. On GitHub's runners nothing changes. A project's own job takes `cache: ${{ runner.environment == 'github-hosted' }}` on `setup-go` and `skip-cache: ${{ runner.environment != 'github-hosted' }}` on golangci-lint's action (runner/README.md).

### Removed

- `codeql.yml`, and `standards/security.md`'s rule that a public repo runs CodeQL: the owner decided it isn't worth running, and no project calls the workflow.

## [2.14.0] - 2026-11-15

### Added

- `runner/` can give a repo's job containers the distro's Docker: list it in `runners.psd1`'s `DockerRepos`, and its jobs get the socket and a work folder under `/var/lib/ci-work` at the same path in the distro, so `docker run -v` on the job's own files works. The job image has Docker's command line and buildx.
- `runner/` can run a repo's Windows jobs on this machine: list it in `WindowsRepos`, and a second scaler, built for Windows from `runner/scaler/` with this machine's Go, serves the scale set `<Name>-windows`, running each job from a fresh copy of the runner's Windows release as a process, as you, up to `WindowsMaxJobs` (1) at once. A job goes there with `runs-on: ${{ !github.event.pull_request.head.repo.fork && vars.CI_RUNNER && format('{0}-windows', vars.CI_RUNNER) || 'windows-2025' }}`. `task shared:runner:stop` ends its runners, and `shared:runner:status` shows them.

## [2.13.0] - 2026-11-15

### Added

- `task shared:runner:start`, `shared:runner:stop` and `shared:runner:status`, in every repo, start, stop and show this machine's self-hosted runners through `runner/Invoke-CiRunner.ps1`, which works through the module the runners were installed from. Start waits until the scaler takes jobs; stop also shuts the runners' WSL distro down, so WSL can give its memory back. They replace shared-tooling's own `task runner:start`, `runner:stop` and `runner:status`.

### Changed

- `osv.yml` runs `repo/Invoke-VulnerabilityScan.ps1`, the scan `task shared:vuln` runs, in place of Google's OSV-Scanner workflow, so CI scans with the same OSV-Scanner release as a local check and runs on the calling repo's `CI_RUNNER` like the other workflows. It takes a `shared-path` input (`shared` by default), no longer needs the `actions: read` and `security-events: write` permissions a call gave it, and ignores `upload-sarif`: nothing goes to code scanning.
- `runner/`'s image has the GitHub CLI, which the projects' release jobs call.
- `runner/` starts each job's container when GitHub assigns the job, through a scaler on GitHub's runner scale set client (`runner/scaler/`), in place of a ready runner per slot. A run's jobs go side by side, up to `MaxJobs` across all the repos, and nothing but the scaler runs between jobs. Every job's container runs in the `ci.slice` systemd slice, whose `Cpus` and `Memory` cap what the running jobs share. In `runners.psd1`, `Repos` is a list of names; `Name` (`wsl` by default) names each repo's scale set and is the label `CI_RUNNER` takes in place of `self-hosted`; `Memory` is all the jobs' memory and `JobMemory` one job's; `Labels` and `NamePrefix` are gone. By default the jobs share half the distro's CPUs and three quarters of its memory, and `MaxJobs` is as many jobs as that memory holds at 1.5 GB each. The runners no longer start at sign-in: the "CI runners" task runs only when `task shared:runner:start` starts it (run `task runner:install` again to drop the old trigger).
- `task shared:push` no longer runs the OSV scan and `task check` before pushing, which CI runs a minute later on the same machine. It takes the in-range updates as before and commits them without a check, starts the self-hosted runners when the repo's `CI_RUNNER` variable names them, pushes, then follows the commit's CI runs, printing each job as it ends, and fails with the failed steps' log when a run fails. `-SkipCheck` is gone; `-NoWait` pushes without following CI, and `-WaitMinutes` (30) bounds the wait.
- Every shared workflow sends a pull request from a fork to GitHub's `ubuntu-24.04`, whatever the repo's `CI_RUNNER` names, so a public repo can use the self-hosted runners once it requires approval for outside contributors' runs (runner/README.md).

## [2.12.0] - 2026-11-15

### Added

- `runner/`: self-hosted Actions runners for a Windows machine. `Install-CiRunner` (in `CiRunner.psm1`) sets up a WSL distro of their own with Docker, which can't reach the Windows drives, and a sign-in task; `Start-CiRunner` keeps a ready runner for each private repo listed in `%USERPROFILE%\.ci-runner\runners.psd1`, each job in a fresh container from the `Dockerfile`'s image; `Stop-CiRunner` and `Get-CiRunnerStatus` stop and show them. `task runner:install`, `runner:start`, `runner:stop` and `runner:status` run them from this repo.

### Changed

- Every shared workflow but `osv.yml` runs its job on `runs-on: ${{ vars.CI_RUNNER || 'ubuntu-24.04' }}`: on the runner the calling repo's `CI_RUNNER` variable names, and on GitHub's `ubuntu-24.04` as before while the variable is unset.

## [2.11.0] - 2026-11-14

### Added

- `Sync-LiveFolder` keeps a copy on the dev machine of a host-only folder too large to archive on the host: only new and changed files are fetched, each checked against the host's SHA-256, nothing is written on the host, and no local file is deleted without `-Delete`.
- `Install-BackupTimer -Exclude` leaves files and folders out of a folder's daily archive, by name or by path from the folder's top.
- `Expand-DeployTemplate` fills a cron file, unit or vhost template with the deploy's values for `Compress-DeployArchive`, and stops the deploy while a placeholder is left unfilled.
- `Get-ServiceMemory` reports a service's memory on the host, now and at its peak since it started, with its cap and twice the peak; it changes nothing.
- `task shared:docs:check` runs everything `docs.yml` checks, with `CHANGELOGS=` for a second CHANGELOG, for a project's `task check`.
- `task shared:web:specs -- --fix` writes a front end's `tsconfig.vitest.json`, or adds the shared base to its `extends`.
- `@jwill89/lint-web/js` exports `tseslint`, for a plain-JavaScript site under `checkJs` that adds typescript-eslint's type-checked rules.
- The shared `.editorconfig` indents Python by four spaces.
- `README.md`: a `check` task to start from, covering the coverage floors, the specs' type-check, the generated files and `shared:docs:check`.
- `standards/README.md`: one line each of a departure, a gap and a gap waiting on the owner, and how an older "Where this project departs" section splits into the two lists, with Since dates.
- `standards/docs-and-agents.md`: a worked example of an app and a plugin with a CHANGELOG and tag prefix each, and a `Rollout complete, YYYY-MM-DD.` line that closes a finished rollout plan.
- `standards/deploy-and-ops.md`: what makes a folder host-only, the size `docs/ops.md` names above which a folder is copied to the dev machine instead of archived on the host, and `MemoryMax=` set at about twice the service's measured peak, recorded with the date.
- `standards/deploy-and-ops.md`: a static, PHP or Grav site with nothing on the host to back up may write one "Backups and restore" section in `docs/ops.md` in place of three, from a template.

### Changed

- `task shared:repo:check` and `docs.yml` fail unless `CLAUDE.md` is exactly the standard form and `AGENTS.md` exists; `task shared:repo:sync` writes a missing `CLAUDE.md`.
- `task shared:update` writes each front end's missing `tsconfig.vitest.json`, adds the shared base to one that lacks it, and names what it leaves to fix by hand.
- `task shared:changelog:links` names each version that was never tagged, to be tagged or have its heading dropped.
- `task shared:version:check` reads the release from the shared-tooling copy its tasks run from, wherever the submodule sits.
- `standards/README.md` and `standards/docs-and-agents.md`: a departure waiting on the owner's decision has no reason yet and is listed as not yet meeting the standards; departures go under "Departures from the standards".
- `standards/docs-and-agents.md`: `PLAN.md` is kept only by an app with product decisions, and `docs/decisions.md` only once there is a dated line to write; a plugin or a static site may have neither.
- `standards/deploy-and-ops.md`: in a public repo the app's port lives only in the deploy config, and `docs/ops.md` names the `AppPort` setting; `www-data` and the distro's other accounts may be written out, and so may local development ports.
- `standards/code-style.md` and `standards/api-and-realtime.md`: a 4xx response is logged at info, never as an error, and without a stack trace.
- `standards/packages.md` and `standards/testing.md`: Python scripts in a project that isn't a Python project get Dependabot and OSV-Scanner over their requirements, and no ruff, mypy or pytest.
- `standards/testing.md` and `@jwill89/lint-web/tsconfig.vitest.json`: how an app with one `tsconfig.json` and its specs beside the code takes the specs' config.
- `lint/web/README.md`: a static site's install, and the type-checked rules a `checkJs` site may add.

### Fixed

- `task shared:changelog:links` linked the version above one that was never tagged to a compare that found nothing; it now links that version to its own tag page.

## [2.10.2] - 2026-11-14

### Added

- `codeql.yml` analyses Python, and Go, which CodeQL builds: `go-version-file` sets up the module's Go, and `download-artifact` with `download-path` brings in the front end's build for a binary that embeds it.

### Changed

- `standards/security.md`: a public repo's CodeQL run covers its Python and Go too; a private repo runs none, since it would need GitHub's paid Code Security.

## [2.10.1] - 2026-11-14

### Fixed

- `python.yml`, `e2e.yml`: uv's setup action is pinned to `astral-sh/setup-uv@v10.3.3`. That action publishes no major-version tag, so `@v10` resolved to nothing and every Python run stopped before its first step.

## [2.10.0] - 2026-11-14

### Added

- `lint/python/ruff.toml`: the shared ruff rules and formatter settings a Python project's `pyproject.toml` extends.
- `python.yml`: uv at a pinned version, the Python `.python-version` names, the hashed dev requirements, ruff, ruff format, `mypy --strict`, and pytest held to the coverage floor in `pyproject.toml`, with a step before the checks that can be cached and an artifact uploaded after them.
- `e2e.yml`: `python-version-file`, `python-requirements` and `uv-version`, to start a Python server, and `download-artifact` with `download-path`.
- `task shared:python:setup`, `shared:python:lint` and `shared:python:test`, which run what `python.yml` runs.
- `test/python/coverage_floor.py`: a Python run fails when `pyproject.toml` sets no coverage floor or package.
- `task shared:deps` and `shared:deps:update` take Python's compiled requirements: the direct packages against PyPI, floors raised and the files compiled again by the command in their headers.
- `Install-PythonEnvironment` builds a Python service's environment on the host before its folder swaps in, reusing one already built for the same Python and requirements.
- `Switch-RemoteDirectory` and `Restore-RemoteDirectory` take `-OnRestore`, and `-ServiceName` to name the vhost after a service shipped as a folder.
- `Install-HostConfig -HealthUrl`, with `-EnvFile`, `-HealthDefault` and `-HealthTimeoutSeconds` (60 by default), waits for a code-run service's `/healthz` after its restart.
- `deploy/pwsh/README.md`: the shape of a Python web service's deploy.
- Python in the standards: `code-style.md`, `testing.md` and `packages.md` gain Python sections, `api-and-realtime.md` gives a Python service `/api/v1` and a spec generated from its pydantic models, and `deploy-and-ops.md` covers its environment, its health check and its gunicorn unit.

### Changed

- `repo/dependabot.example.yml`: Python's compiled requirements go under the `uv` ecosystem, whose updates keep `--universal` and `--python-version`, with an example hold for a package whose data must match its minor.
- `task shared:vuln` scans every `requirements*.txt`, `requirements-dev.txt` included.
- `standards/deploy-and-ops.md`: every restart in a rollback clears systemd's start limit first.

## [2.9.0] - 2026-11-13

### Added

- `standards/naming.md`: a project's repo is named for its type and then the project, such as `discord-bot-quizbot` or `site-harbour-books`.
- `standards/README.md`: an `AGENTS.md` keeps a "Not yet meeting the standards" list, each item saying what falls short of which rule and since when. A departure counts only when it states its reason, and a project meets the standards once that list is empty and holds every gap.
- `standards/deploy-and-ops.md`: one list of what `docs/ops.md` holds: host setup (a script, or the commands a static or PHP site on the shared host needs), backups, restore steps, the restore drill and the date it last ran, production-only checks, `Upgrading to x.y.z`, rolling back and logs.
- `codeql.yml`: CodeQL for a public repo, over its JavaScript and TypeScript, C# and workflows.
- `task shared:changelog:links` writes the compare link of every CHANGELOG heading, and `task shared:changelog:check` checks them as `docs.yml` does.
- `task shared:go:coverage` runs a Go module's tests and holds the coverage floor `go.yml` holds, and `task shared:web:specs` type-checks a front end's Vitest specs as `web.yml` does.
- `@jwill89/lint-web/js`: ESLint for plain JavaScript, for a static site with no framework or TypeScript.
- `@jwill89/lint-web/tsconfig.vitest.json`: the base a front end's `tsconfig.vitest.json` extends, adding Node's types and taking in the specs.
- `web.yml`: `php-version` and `php-extensions`, for a script that runs PHP.
- `Install-BackupTimer -Folder` backs up a folder, such as a site's uploads, as a daily compressed archive, and `Copy-LiveFolder` pulls a fresh archive of it to the dev machine.
- `Install-HostConfig` installs a site's cron file and the units of a worker that isn't a binary, restarts the workers and puts everything back if they don't stay up; `Restore-HostConfig` puts them back after a failed smoke check.
- `Invoke-SmokeCheck -SiteUrl` with `-Version` checks the version `/healthz` reports, and with `-EntryScript` the entry script `/` names.
- `deploy/pwsh/README.md`: a project may add a deploy setting beyond the shared names once its `AGENTS.md` names it, and the vhost template shows HSTS and the Cloudflare visitor-address lines.

### Changed

- `web.yml` fails an app with Vitest specs unless its `tsconfig.vitest.json` extends `@jwill89/lint-web/tsconfig.vitest.json` and takes in every spec, then type-checks the specs with it.
- `docs.yml` fails when a CHANGELOG heading has no compare link; its `changelogs` input names a second part's CHANGELOG.
- `Invoke-SmokeCheck` sends every request with a fresh `?deploy=` token, so no cached copy can pass; a check with `CacheBust = $false` goes out as written.
- `standards/deploy-and-ops.md`: in a public repo the certificate name, server paths, service users, ports and admin addresses are placeholders everywhere, docs, cron files and `.env.example` included, while public hostnames may stay. `-Preview` is optional, `/healthz` is required only of an app run as a systemd service, each project's `docs/ops.md` records its port, a project already live owes one restore drill on the host, and a folder only the host holds is backed up daily.
- `standards/security.md` and `standards/deploy-and-ops.md`: HSTS and the Cloudflare visitor-address lines go in each site's own vhost, and a public repo calls the shared `codeql.yml`.
- `standards/testing.md`: a React app's specs use `test/web`'s preset too, and `task check` holds every coverage floor CI holds.
- `standards/docs-and-agents.md`: `task check` runs every coverage floor and generated-file check CI runs, compare links are written by tooling, and a repo with two parts versioned apart keeps one CHANGELOG per part, each tagged with its own prefix.
- `standards/naming.md`: app-wide front-end pieces may sit in `src/app/`.
- `standards/performance.md`: served images may be AVIF as well as WebP.

### Removed

- `lint/go/go.exe`, a 4 MB Windows build shipped by mistake since 2.7.1.

### Fixed

- `@jwill89/lint-web/prettier` had no type declarations, so a `prettier.config.ts` importing it had no types.
- `test/e2e`'s `playwrightDefaults` looked for `@playwright/test`'s types outside the front end's own install, so a Playwright config could check against another copy or none.

## [2.8.0] - 2026-11-11

### Added

- `deploy/pwsh/README.md`: one name for each deploy setting every project reads (`CertName`, `WebRoot`, `AppPort`, `ServiceUser`, `ServerName` and `ServerAlias`, and the rest), and what is deliberately not a setting.
- `Switch-RemoteDirectory` and `Switch-RemoteItemSet` ship a site's vhost (`-Vhost`, `-ServerName`) as `Install-ServiceBinary` does, and `Restore-RemoteDirectory` and `Restore-RemoteItemSet` put it back (`-ServerName`).

### Changed

- A site's vhost is one file holding both ports, `/etc/apache2/sites-available/<name>.conf`, named after the service or, for a site served from a folder, its `ServerName`. `Install-ServiceBinary -VhostPath` is optional and defaults to that name, and `VhostPath` is not a deploy setting.
- A deploy that ships a vhost disables every other enabled site serving its names, such as certbot's `-le-ssl` file, in the same configtest and reload, and a rollback enables them again. It refuses, changing nothing, when one of those sites serves another name or the new file drops a port. When nothing else serves the names, Apache is left as it was.
- `Restore-ServiceBinary` puts back a vhost the last deploy changed without being given `-VhostPath`.
- `standards/deploy-and-ops.md`: one vhost file per site, shipped by the deploy and never edited by certbot, and what to do if certbot writes a `-le-ssl` file beside it.

## [2.7.1] - 2026-11-10

### Changed

- `standards/packages.md`: a Go module's version is the `go` line of `go.mod`, the release it requires, raised when a Go security release lands; no separate `toolchain` line.
- `lint/go` requires Go 1.27.4, which fixes a crash in Go's HTTP server (GO-2026-6859).

## [2.7.0] - 2026-11-10

### Added

- `standards/docs-and-agents.md`: what a changelog entry says. A CHANGELOG lists changes a user could notice, a sentence or two each; it is project-agnostic like a comment, gives no instructions, leaves out internal work, and released entries are held to the same rules.
- `standards/security.md`: in Go, a path from a request is checked with `path`, never `path/filepath`.
- `standards/api-and-realtime.md`: signing in and out, sign-up and every other credential ceremony are API operations under `auth/`, in the spec. An operation a browser navigates to, such as an OAuth start or callback, answers 302 with `Location` whatever happens, a 401 from a sign-in operation stays with its page, and with huma a sign-in operation reaches the session through its context.

### Changed

- `standards/deploy-and-ops.md`: a release's steps beyond the deploy go in the project's `docs/ops.md` under `Upgrading to x.y.z`; the CHANGELOG entry only points there.
- `standards/deploy-and-ops.md`: every deploy ships the service's units and its vhost from templates in the repo, with host-specific values filled from the git-ignored deploy config, and nobody edits them on the host.
- `standards/api-and-realtime.md`: a Go service's API sits under `/api/v1`; a PHP site's stays under `/api`.
- `Install-BackupTimer`'s service unit and shared job differ in their comments only, so each project's next deploy installs them again and runs the backup once to check them.

### Removed

- `PLAN.md` and `plans/`: shared-tooling holds no project's plan. A project's link to either no longer resolves.

### Fixed

- A deploy whose remote run was long, over about 16 KB of script, failed with `FATAL ERROR: Error 109: The pipe has been ended` and "The deploy failed on the host", though the host ran none of it. Such runs now go through; a script over 128 KB is refused before anything is sent, and a step that never reached the host says none of it ran.

## [2.6.0] - 2026-11-10

### Added

- `go.yml`: a `coverpkg` input, passed to `go test -coverpkg`. With `./...`, code is credited with the tests of every package that runs it, not only its own package's; empty, the default, keeps each package's own.

## [2.5.0] - 2026-11-10

### Added

- `standards/comments.md`: what a comment is for, and each language's doc-comment convention. A comment describes the code as it is, gives its reason itself rather than pointing elsewhere, and keeps history out; the same holds for text that becomes documentation, such as OpenAPI descriptions. The comment rules in `code-style.md` move there.

## [2.4.0] - 2026-11-09

### Added

- `task deploy` ships the newest release CI tagged on main, built in a checkout of its own with clean installs from its lockfiles (`Get-DeployRelease`, `New-ReleaseTree`, `Remove-ReleaseTree`). Commits after a release no longer stop a deploy with "HEAD is not tagged", and nothing uncommitted reaches it.
- `Get-DeployedRelease` and `Set-DeployedRelease`: the host records the release each deploy left running, once it passes its checks, and a deploy of the release already running does nothing unless run with `-Force`.

### Fixed

- `task shared:deps` and `task shared:push` listed a NuGet package an SDK adds by itself as a major update, though Dependabot never opens it.
- `task shared:lint:scripts` crashed on every try on a large PowerShell module.

## [2.3.2] - 2026-11-09

### Fixed

- `test/web`'s `vitestDefaults`: a test file's first test could time out under `task check`'s load and fail a check that passed on its own. Each test now gets 15 seconds instead of Vitest's 5.

## [2.3.1] - 2026-11-09

### Fixed

- `task shared:deps:update` and `task shared:push` failed with `ETARGET` ("No matching version found") on an npm release made that day.

## [2.3.0] - 2026-11-08

### Changed

- `standards/testing.md`: a task that two of `check`'s parallel steps depend on and that writes files runs once (`run: once`). An end-to-end suite that starts its own server stops with a message when its port is taken, fails setup when its server doesn't come up, and keeps the server's output in a log file.

### Fixed

- `task shared:deps` and `task shared:push` missed the minor and patch updates of an exactly pinned npm package or a `~` range, which Dependabot then opened as a pull request.

## [2.2.3] - 2026-11-07

### Changed

- `standards/testing.md`: `task check` starts its independent steps at once (`task --parallel --output prefixed`), then runs the build, the end-to-end suite and any generated-code diff in order.

## [2.2.2] - 2026-11-07

### Fixed

- `task shared:deps:update` raised only some packages of a family that pin each other, leaving two copies of one and a failing type check.

## [2.2.1] - 2026-11-07

### Fixed

- `task shared:deps` offered Composer updates that the project's own `conflict` rules or a held package keep back, and named them in the commit though they were never taken.
- `task shared:push` put every change in the working tree into its `chore(deps)` commit. It commits only manifests and lockfiles, and stops if anything else changed.

## [2.2.0] - 2026-11-07

### Added

- `task shared:push`, for a project's `task push`: on a clean tree, it lists the in-range updates Dependabot would open, takes them once you agree as one `chore(deps)` commit, scans for advisories, runs `task check` and pushes. Majors are listed for Dependabot to open one by one.
- `task shared:deps` and `task shared:deps:update`: the updates Dependabot would open for npm, Go, Composer, NuGet and GitHub Actions; `deps:update` takes the in-range ones.
- `task shared:vuln`: OSV-Scanner over every lockfile the repo tracks, as CI's OSV job scans them, honouring each `osv-scanner.toml`.
- `repo/osv-scanner.example.toml`: the advisories in lint, test and build tooling that OSV-Scanner may pass over, for a project to copy beside a lockfile. `standards/packages.md` says when an advisory may be passed over.

### Fixed

- `task shared:lint:scripts` could report a finding that wasn't there after PSScriptAnalyzer crashed and was retried.

## [2.1.7] - 2026-11-07

### Changed

- `standards/deploy-and-ops.md`: `task deploy` deploys everything a project has, in order: the backend, the front end, then a Dalamud plugin, published only when its version is new. Parts that ship separately deploy alone as `deploy:backend`, `deploy:frontend` and `deploy:plugin`; there is no `deploy:both` or `deploy:all`.

## [2.1.6] - 2026-11-07

### Changed

- `standards/components.md`: every icon is a `<font-awesome-icon>`, never an `<i class="fa-…">` element, a kit script or `dom.watch()`, and an app's one icon register is checked by a test.
- `standards/packages.md`: a Font Awesome kit holds only the styles its sites import from, since every style adds to each download, and several sites may share one kit.

## [2.1.5] - 2026-11-07

### Fixed

- `web.yml` and `e2e.yml` downloaded every Font Awesome package again whenever the lockfile changed, and kept nothing from a job that failed after installing. A package is downloaded again only when its own version changes.

## [2.1.4] - 2026-11-07

### Changed

- The Font Awesome secret is named `FONTAWESOME_NPM_TOKEN` in every repo's Actions and Dependabot secrets; `web.yml` and `e2e.yml` take it as their `FONTAWESOME_TOKEN` input.

## [2.1.3] - 2026-11-07

### Changed

- `standards/performance.md` and `components.md`: a service worker never caches an API answer or anything per viewer, may cache content-hashed files and thumbnails, and precaches the app shell only in an installable app.
- `standards/packages.md`: Font Awesome comes from the free packages where they cover a site's icons, otherwise from the site's own Pro kit package.

## [2.1.2] - 2026-11-07

### Changed

- `lint/web`'s README covers a template-only component, on which `tsStylistic`'s type-aware rules fail to load.
- `standards/README.md`'s `CLAUDE.md` example passes markdownlint.

## [2.1.1] - 2026-11-07

### Fixed

- `standards/accessibility.md` named WCAG 2.2 AA as the target. The target is AAA, with AA as the floor where AAA can't be met; axe in `test/a11y` still enforces AA.

## [2.1.0] - 2026-11-07

### Added

- `standards/`: the rules every project follows, in 13 files by area with `standards/README.md` as the index, each rule marked with how it is checked. A project's `CLAUDE.md` imports `@shared/standards/README.md`. Where a current, accepted RFC covers something, the projects follow it, so timestamps are stored as RFC 3339 text in UTC.

### Changed

- `repo/dependabot.example.yml` skips vue-tsc 3.3.14, which reports false errors in a template with `//` in a static attribute.
- `repo/dependabot.example.yml` gives the Font Awesome registry no `scope:`, with which Dependabot's npm pull requests failed `npm ci`.

## [2.0.0] - 2026-11-06

A major: a project's own Stylelint moves to 18.

### Added

- `LICENSE`: the MIT license, for this repo only.
- `Backup-RemoteDatabase`: the compressed, checked snapshot a site that isn't a service takes before its migrations, with the command that puts it back ready for the step's failure message.
- `Copy-LiveDatabase -Owner`: the host's copy is made as the database's user.

### Changed

- **Breaking:** `lint/web` moves to Stylelint 18, with `stylelint-config-standard` 41 and `stylelint-config-recommended` 19, five more recommended rules, and Node ^24.15.0 or >=26. `stylelint-config-recommended-scss` has no release for it.
- `task shared:update` raises a project's own copy of a `lint/web` or `test/a11y` peer that falls outside the release's range before it reinstalls, since npm refuses the new package beside the old tool.
- `Install-ServiceBinary -Database` names its snapshots by the time in UTC, not the deploying machine's local time.
- `repo/dependabot.example.yml` ignores the majors of ESLint, Prettier, Stylelint and their plugins and configs, which move in `lint/web` first.

## [1.3.0] - 2026-11-06

### Changed

- The README adds an end-to-end suite's `test-results/**` to a project's markdownlint ignores, since a failed run leaves Markdown there.
- `deploy/pwsh`: every database backup kept on the host is compressed with gzip and checked (`PRAGMA integrity_check`, then `gzip -t`) before it takes its place, and every restore decompresses. Each project's next deploy runs the changed backup job once, which compresses the existing daily copies.

### Fixed

- `task shared:lint:scripts` failed on a tracked script deleted in the working tree and not yet committed.

## [1.2.0] - 2026-11-06

### Added

- `Install-BackupTimer`: a project's daily database backup as a systemd timer, installed and checked by its deploy and keeping 28 days; `-Command` runs the project's own backup instead.
- `e2e.yml`: the reusable end-to-end job, running the caller's Playwright suite in the runner's Chrome, with Go or PHP when asked, and keeping the traces of a failed run.

### Fixed

- Node could read `test/e2e/playwright.js` as CommonJS.

## [1.1.2] - 2026-11-06

### Fixed

- Every Vite build that imported `test/web/vitest.js` warned that a future Vite would refuse it as CommonJS.

## [1.1.1] - 2026-11-05

### Fixed

- `go.yml`'s govulncheck panicked (`unexpected expr: *ast.KeyValueExpr`) under Go 1.27.

## [1.1.0] - 2026-11-05

### Added

- `lint/web`'s `tsconfig.app.json` turns on `noUncheckedIndexedAccess`, so an index into an array or a record may find nothing, which raises type errors where code assumes it can't.

### Fixed

- `dotnet.yml`'s tests failed for a test project on Microsoft.Testing.Platform.
- `lint/web`'s README covers the older plugin copy a lockfile can keep nested, which makes ESLint warn.

## [1.0.1] - 2026-11-05

### Fixed

- `task shared:lint:scripts` failed CI when PSScriptAnalyzer crashed several times in a row on a cold start.

## [1.0.0] - 2026-11-05

### Added

- `lint/web`: `@jwill89/lint-web`, replacing the `jwill89/eslint-config` submodule: ESLint for Vue 3 and TypeScript with template accessibility, a React variant with JSX accessibility, Prettier, Stylelint and base tsconfigs.
- `lint/go`: the golangci-lint template, and `golangci-sync`, which writes each module's `.golangci.yml`.
- `lint/php`: the PHPStan base (level 8), the PHP CS Fixer rules (PER-CS 3.0) and the Rector set.
- `lint/dotnet`: the .NET analyzers and the C# code style, checked in the build.
- `lint/pwsh`: the PSScriptAnalyzer settings and the script that runs them.
- `lint/markdown`: the markdownlint config.
- `deploy/pwsh`: `SharedDeploy`, the deploy module: one archive and one shared SSH connection per deploy, smoke checks with rollback, plugin publishing and the live database pull.
- `test/`: the Vitest settings, axe checks for Playwright, the Playwright settings, and coverage floors for Go and PHP.
- `repo/`: the shared `.editorconfig` and `.gitattributes`, the Taskfile include, the Dependabot example, and `task shared:update` with its version check.
- `.github/workflows`: reusable workflows for each stack (`web`, `go`, `php`, `dotnet`, `pwsh`, `docs`, `osv`).

[Unreleased]: https://github.com/jwill89/shared-tooling/compare/v2.19.2...HEAD
[2.19.2]: https://github.com/jwill89/shared-tooling/compare/v2.19.1...v2.19.2
[2.19.1]: https://github.com/jwill89/shared-tooling/compare/v2.19.0...v2.19.1
[2.19.0]: https://github.com/jwill89/shared-tooling/compare/v2.18.0...v2.19.0
[2.18.0]: https://github.com/jwill89/shared-tooling/compare/v2.17.0...v2.18.0
[2.17.0]: https://github.com/jwill89/shared-tooling/compare/v2.16.1...v2.17.0
[2.16.1]: https://github.com/jwill89/shared-tooling/compare/v2.16.0...v2.16.1
[2.16.0]: https://github.com/jwill89/shared-tooling/compare/v2.15.2...v2.16.0
[2.15.2]: https://github.com/jwill89/shared-tooling/compare/v2.15.1...v2.15.2
[2.15.1]: https://github.com/jwill89/shared-tooling/compare/v2.15.0...v2.15.1
[2.15.0]: https://github.com/jwill89/shared-tooling/compare/v2.14.0...v2.15.0
[2.14.0]: https://github.com/jwill89/shared-tooling/compare/v2.13.0...v2.14.0
[2.13.0]: https://github.com/jwill89/shared-tooling/compare/v2.12.0...v2.13.0
[2.12.0]: https://github.com/jwill89/shared-tooling/compare/v2.11.0...v2.12.0
[2.11.0]: https://github.com/jwill89/shared-tooling/compare/v2.10.2...v2.11.0
[2.10.2]: https://github.com/jwill89/shared-tooling/compare/v2.10.1...v2.10.2
[2.10.1]: https://github.com/jwill89/shared-tooling/compare/v2.10.0...v2.10.1
[2.10.0]: https://github.com/jwill89/shared-tooling/compare/v2.9.0...v2.10.0
[2.9.0]: https://github.com/jwill89/shared-tooling/compare/v2.8.0...v2.9.0
[2.8.0]: https://github.com/jwill89/shared-tooling/compare/v2.7.1...v2.8.0
[2.7.1]: https://github.com/jwill89/shared-tooling/compare/v2.7.0...v2.7.1
[2.7.0]: https://github.com/jwill89/shared-tooling/compare/v2.6.0...v2.7.0
[2.6.0]: https://github.com/jwill89/shared-tooling/compare/v2.5.0...v2.6.0
[2.5.0]: https://github.com/jwill89/shared-tooling/compare/v2.4.0...v2.5.0
[2.4.0]: https://github.com/jwill89/shared-tooling/compare/v2.3.2...v2.4.0
[2.3.2]: https://github.com/jwill89/shared-tooling/compare/v2.3.1...v2.3.2
[2.3.1]: https://github.com/jwill89/shared-tooling/compare/v2.3.0...v2.3.1
[2.3.0]: https://github.com/jwill89/shared-tooling/compare/v2.2.3...v2.3.0
[2.2.3]: https://github.com/jwill89/shared-tooling/compare/v2.2.2...v2.2.3
[2.2.2]: https://github.com/jwill89/shared-tooling/compare/v2.2.1...v2.2.2
[2.2.1]: https://github.com/jwill89/shared-tooling/compare/v2.2.0...v2.2.1
[2.2.0]: https://github.com/jwill89/shared-tooling/compare/v2.1.7...v2.2.0
[2.1.7]: https://github.com/jwill89/shared-tooling/compare/v2.1.6...v2.1.7
[2.1.6]: https://github.com/jwill89/shared-tooling/compare/v2.1.5...v2.1.6
[2.1.5]: https://github.com/jwill89/shared-tooling/compare/v2.1.4...v2.1.5
[2.1.4]: https://github.com/jwill89/shared-tooling/compare/v2.1.3...v2.1.4
[2.1.3]: https://github.com/jwill89/shared-tooling/compare/v2.1.2...v2.1.3
[2.1.2]: https://github.com/jwill89/shared-tooling/compare/v2.1.1...v2.1.2
[2.1.1]: https://github.com/jwill89/shared-tooling/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/jwill89/shared-tooling/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/jwill89/shared-tooling/compare/v1.3.0...v2.0.0
[1.3.0]: https://github.com/jwill89/shared-tooling/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/jwill89/shared-tooling/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/jwill89/shared-tooling/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/jwill89/shared-tooling/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/jwill89/shared-tooling/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/jwill89/shared-tooling/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/jwill89/shared-tooling/releases/tag/v1.0.0
