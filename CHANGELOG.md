# Changelog

Every change to shared-tooling, by release. A project takes a release with `task shared:update -- v<version>`; see README.md. The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/):

- **Major:** a project has to change its own files to take it (a renamed export, a removed input, a moved file).
- **Minor:** new rules, tasks or features. A new lint rule can raise findings in a project when it takes the release.
- **Patch:** fixes that change nothing a project relies on.

## [Unreleased]

## [2.6.0] - 2026-11-10

### Added

- `go.yml`: a `coverpkg` input, passed to `go test -coverpkg`. With `./...`, code is credited with the tests of every package that runs it, so a module whose request tests sit in one package and exercise another counts that coverage. Empty, the default, keeps each package's own tests only. The floor script already merges a block that several test binaries report.

## [2.5.0] - 2026-11-10

### Added

- `standards/comments.md`: what a comment is for, and each language's doc-comment convention. A comment describes the code as it is now, giving the reason itself rather than pointing at a plan, a standards document, an audit or another project, and keeps history out (that belongs in the commit and the CHANGELOG); a project's own rules document, cited by rule number, is the one reference allowed. The same rules reach text that becomes documentation (OpenAPI descriptions, CLI help) and the source of generated code (sqlc query comments). Doc comments follow Go Doc Comments, TSDoc, PHPDoc with PSR-19's tags, C#'s XML documentation comments, and PowerShell's comment-based help. `code-style.md`'s comment rules move there.

## [2.4.0] - 2026-11-09

### Added

- Deploys ship the newest release, not the tag on HEAD. `Get-DeployRelease` fetches the tags and finds the newest one CI made on main, so a shared-tooling update or other commits after a release no longer stop `task deploy` with "HEAD is not tagged" (Home Library, after its v2.3.2 update followed v1.1.2). `New-ReleaseTree` checks the release out into a folder of its own, with its submodules and an `npm ci` from its lockfiles, and the deploy builds there, so nothing uncommitted and no package installed for HEAD reaches it; `Remove-ReleaseTree` removes it. npm takes the packages from its cache by the lockfile's integrity: a release build of Home Library made no network request at all. `Get-DeployedRelease` and `Set-DeployedRelease` keep a record on the host, `~/.shared-deploy/<name>`, of the release each deploy left running, written once the site passes its checks; a deploy whose release is already running does nothing, and `-Force` deploys it again. `standards/deploy-and-ops.md` says so; `Get-ReleaseTag` and `Assert-CleanWorkingTree` stay for Senpan until its overhaul.

### Fixed

- `task shared:deps` and `task shared:push` no longer list a NuGet package an SDK adds by itself as a major Dependabot would open. `dotnet list package` reports Dalamud.NET.Sdk's `DotNet.ReproducibleBuilds` (1.2.39, 2.0.5 out) like a package the plugin asked for, so every push in Kindred Nights, TarotGen.io and Senpan named it; but no project file names it, Dependabot never opened it, and it moves only with the SDK. A NuGet package now counts only where one of the repo's own `.csproj`, `.props` or `.targets` files names it, and the report counts the others apart.
- `task shared:lint:scripts` no longer crashes on a large file. PSScriptAnalyzer 1.25.0 runs its rules side by side, and two of them reading the same command's parameters at once throw a NullReferenceException: `UseCorrectCasing` against the rest, and in a module the rules that read its `Export-ModuleMember` (`AvoidReservedCharInCmdlet` among them). Once `SharedDeploy.psm1` grew, all six of the lint's tries crashed. A script is now analyzed in two passes, `UseCorrectCasing` alone and then every other rule, and a module one rule at a time (about 13 seconds for `SharedDeploy.psm1`); on a file seeded with ten kinds of finding, both report exactly what one pass did. A crash names the pass it came from, and is still retried in a fresh process.

## [2.3.2] - 2026-11-09

### Fixed

- `test/web`'s `vitestDefaults` gives each test 15 seconds instead of Vitest's 5. `task check` runs the unit tests beside lint and the scans, and a test file's first test imports the app cold, which under that load has run past 5 seconds and failed a check that passes on its own: TarotGen.io's router spec on 2026-11-07, its AdminListPage spec on 2026-11-09. A test that hangs still fails, after 15 seconds.

## [2.3.1] - 2026-11-09

### Fixed

- `task shared:deps:update` and `task shared:push` no longer fail with `ETARGET` ("No matching version found") on an npm release made that day. They installed with `--prefer-offline`, which resolves versions against npm's cached package lists, and those could predate the release `npm outdated` had just found, or a new dependency it brings: Kindred Nights' vite 8.3.7 and the rolldown 1.2.18 it needs. The install now follows npm's own cache rules, which recheck a cached list once it is a few minutes old. A tarball the lockfile already names still comes from the cache, so Font Awesome packages aren't downloaded again. CI's `npm ci --prefer-offline` is unchanged, since it installs the lockfile as written and resolves nothing.

## [2.3.0] - 2026-11-08

### Changed

- `standards/testing.md`: a task that two of `check`'s parallel steps depend on and that writes files (a frontend build lint and the tests both need) has `run: once`, so the second waits for the first's run instead of building over the same folder. An end-to-end suite that starts its own server stops with a message when something already answers on its port, fails setup when its server doesn't come up, and keeps the server's output in a log file. Home Library's suite failed 46 tests with no reason shown when another server answered on its port.

### Fixed

- `task shared:deps` and `task shared:push` see the minor and patch updates of an exactly pinned npm package (or a `~` range), which Dependabot raises in its grouped pull request: they took npm's "wanted", which stays inside the range, so Home Library's `@types/node` 26.6.5 went untaken and came back as a Dependabot pull request. The target is now the newest release in the installed major; when "latest" is a major away, the registry is asked for it.

## [2.2.3] - 2026-11-07

### Changed

- `standards/testing.md`: `task check` starts its independent steps at once with `task --parallel --output prefixed` (lint, the vulnerability checks and the unit tests, typically), each line prefixed with its step, and runs the build, the end-to-end suite and any generated-code diff after them, in order. The end-to-end suite keeps its one worker, since its steps share one server and one database; the standard now says why. Every project's `check` moved to it.

## [2.2.2] - 2026-11-07

### Fixed

- `task shared:deps:update` no longer takes npm updates with `npm update`, which moved only some of a family whose packages pin each other through peer dependencies: in Kindred Nights and TarotGen.io it raised `@tiptap/starter-kit` to 3.33.0 and left the other Tiptap packages on 3.32, so two copies of `@tiptap/core` broke the type check. `repo/npm-take-updates.mjs` now raises each range in `package.json`, keeping its `^`, `~` or exact form, and drops the lockfile entries of the package's family (its scope, or the package alone), and then `npm install` resolves the family afresh.

## [2.2.1] - 2026-11-07

### Fixed

- `task shared:deps` judges a Composer update by what `composer update --dry-run` would take, so one the project's own `conflict` rule holds, or that a held package keeps back, counts as held rather than in range. `composer outdated` weighs neither: Fantasy Dossier's phpstan, held at 2.3.3, and the rector 2.8.4 that needs a newer phpstan were offered, never taken, and still named in the commit. `deps:update` moves Composer packages with `--with-all-dependencies`.
- `task shared:push` scans again after taking the updates, so its `chore(deps)` commit names only what was taken and warns about any held back. It commits only the manifests and lockfiles, and stops, committing nothing, if anything else changed while updating or checking; it had staged every change with `git add -A`.

## [2.2.0] - 2026-11-07

### Added

- `task shared:push` (`repo/Invoke-Push.ps1`), for a project's `task push`: on a clean tree that isn't behind its remote, it lists the in-range updates Dependabot would open and, once you agree (`-- -Yes` skips the question), takes them, runs `task check` and commits them as one `chore(deps)` commit; then it scans the lockfiles for advisories, runs `task check`, and pushes. Majors are listed at the end, for Dependabot to open one by one. A failing check or an advisory stops it before anything is pushed.
- `task shared:deps` and `task shared:deps:update` (`repo/Invoke-DependencyCheck.ps1`): the updates Dependabot would open for npm, Go, Composer, NuGet and GitHub Actions, leaving out what `.github/dependabot.yml` holds; `deps:update` takes the in-range ones and never a major or `modernc.org/libc`.
- `task shared:vuln` (`repo/Invoke-VulnerabilityScan.ps1`): OSV-Scanner, pinned at v2.2.4 through `go run`, over every lockfile the repo tracks outside `shared/`, as CI's OSV job scans them, honouring each `osv-scanner.toml`. Projects add it to `task check`.
- `repo/osv-scanner.example.toml`: the advisories OSV-Scanner may pass over, for a project to copy beside a lockfile as `osv-scanner.toml`. It holds the three that reach only lint, test and build tooling with no fix inside their dependents' ranges: minimatch (GHSA-g3hv-75wg-m249, through ESLint), glob (GHSA-3g3m-2fjr-6pw4, through js-beautify and Workbox's build) and deepmerge (GHSA-gcqx-w48m-w2h4, through Workbox's build), each with its reason and a date in three months. `standards/packages.md` says when an advisory may be passed over, and that a Go module OSV-Scanner flags is raised even when govulncheck finds it unreached; `osv.yml` points to both.

### Fixed

- `lint/pwsh/Invoke-ScriptLint.ps1`: after PSScriptAnalyzer crashes, the lint starts again in a fresh `pwsh` process on the same analyzer version, rather than retrying in the session that crashed. That session could report findings that weren't there: Home Library's CI flagged `Split-Path -Parent $PSScriptRoot` with PSUseCmdletCorrectly on such a retry (2026-11-07). Findings now come only from a run that never crashed; the six attempts and their warnings are as before.

## [2.1.7] - 2026-11-07

### Changed

- `task deploy` deploys everything a project has, in order: the backend, then the front end, then a Dalamud plugin, which it publishes only when its version is new (the deploy script's `-IfNewer`, so a deploy that didn't raise the plugin's version still succeeds). Where the parts ship separately, `deploy:backend`, `deploy:frontend` and `deploy:plugin` deploy one each, and `deploy:both` and `deploy:all` are gone. `standards/deploy-and-ops.md` and `naming.md`, `repo/Taskfile.yml`'s header and README.md say so. Senpan, TarotGen.io and Kindred Nights moved to it; `task deploy` used to deploy only Senpan's and TarotGen.io's front end.

## [2.1.6] - 2026-11-07

### Changed

- `standards/components.md` has an Icons section: every icon is a `<font-awesome-icon>` (`icon="fa-solid fa-house"`, or `:icon` for one code holds), never an `<i class="fa-…">` element, a kit script or `dom.watch()`; only what Vue doesn't render draws an icon another way, as inline SVG; and an app's one icon register is checked by a test (the Gallery's `icons.spec.ts`, the Dossier's `integrity.spec.ts`).
- `standards/packages.md`: a Font Awesome kit holds only the styles its sites import from, since every style adds about 10 MB to each download and downloads count against the account's monthly bandwidth (Senpan's all-styles kit was 201 MB, 42 MB once cut to its four). The owner assigns each site its kit, and several sites may share one: Fantasy Dossier, the Gallery and Home Library share `kit-4f2bd9b614`. Pro files are never committed, so a public repo may install a kit.

## [2.1.5] - 2026-11-07

### Fixed

- `web.yml` and `e2e.yml` no longer fetch every Font Awesome package again whenever the lockfile changes. A changed lockfile (a bumped package, a shared-tooling release, a Dependabot branch) used to miss both caches, since setup-node's npm cache matches only its exact key, so each run downloaded the kit afresh: 50 Font Awesome installs across four repos in the first week of November. npm's download cache is now its own cache that falls back to the newest earlier copy, and `npm ci --prefer-offline` fetches only the packages that changed, so a Font Awesome package is downloaded again only when its own version changes.
- Both caches are saved as soon as the install is done, not when the job ends: a job that failed after installing used to keep nothing, so the next run downloaded everything again.

## [2.1.4] - 2026-11-07

### Changed

- The Font Awesome secret is named `FONTAWESOME_NPM_TOKEN` in every repo's Actions and Dependabot secrets. `web.yml` and `e2e.yml` keep their `FONTAWESOME_TOKEN` secret input, which callers fill from `secrets.FONTAWESOME_NPM_TOKEN`; their usage comments, input descriptions and missing-token error now say so, as do README.md, `repo/dependabot.example.yml` and `standards/packages.md`.

## [2.1.3] - 2026-11-07

### Changed

- `standards/performance.md` and `components.md`: a service worker never caches an API answer or anything per viewer, may cache content-hashed build files and media thumbnails (the Gallery's cache is the model), and leaves the app shell to the network, except an installable app that precaches it through Workbox's versioned precache with auto-update (Senpan's). The two files had disagreed: one said the worker caches nothing of the app.
- `standards/packages.md`: Font Awesome comes from the free packages where they cover a site's icons, otherwise from that site's own Pro kit package; a kit is made for one site, so no project uses another's.

## [2.1.2] - 2026-11-07

### Changed

- `lint/web`'s README says how a project with a template-only component (a `.vue` file with no `<script lang="ts">`) turns `tsStylistic` off for it: the set sits outside the base's Vue wrapper, so its type-aware rules fail to load on such a file. Found in Fantasy Dossier's rollout.
- `standards/README.md`'s `CLAUDE.md` example opens with a `# CLAUDE.md` heading and one line saying the project's rules live in `AGENTS.md`: two import lines alone fail markdownlint's first-line-heading rule (MD041).

## [2.1.1] - 2026-11-07

### Fixed

- `standards/accessibility.md` named WCAG 2.2 AA as the target; the target is AAA, as Kindred Nights, Home Library and Senpan's themes already state it, with AA as the floor wherever AAA can't be met, and each such place recorded in the project's decision log. Text contrast is 7:1 for body text and 4.5:1 for large text, held by each project's own contrast test, with AA's 4.5:1 and 3:1 as the floor; touch targets of 44 px are AAA's 2.5.5. axe in `test/a11y` still enforces AA, the floor, and a project that meets AAA throughout adds axe's `wcag2aaa` rules. The guide's README and testing.md say the same.

## [2.1.0] - 2026-11-07

### Added

- `standards/`: the rules every project follows, for the owner and for coding agents, in 13 files by area (code style, naming, API and realtime, security, performance, database, deploy and operations, testing, packages, CSS, components, accessibility, docs and agents), with `standards/README.md` as the index. They were gathered from every project's own AGENTS.md, CLAUDE.md, CONTRIBUTING.md, plans and decision logs, and the 55 places where those disagreed were decided by the owner (2026-11-07; PLAN.md lists them). Each rule says how it is checked: a linter, axe, a test, CI, the deploy module, or review. A project's `CLAUDE.md` imports `@shared/standards/README.md`, and its own docs keep only what is specific to it. Above every area sits one principle: where a current, accepted RFC (standards-track or a Best Current Practice, not obsoleted) covers something, the projects follow it, and a project that departs says why. So timestamps are stored as RFC 3339 text in UTC (`DATETIME` columns, a `strftime` default and a CHECK that refuses any other form; date-only columns are `DATE`, read in Go through a small `Date` type), which SQLite's date functions read, its indexes sort in time order, Go reads as a `time.Time`, and the API sends in the same form.

### Changed

- `lint/web`'s comments and README follow the standards: API fields are camelCase (older APIs keep snake_case until they move, which is why `naming-convention` still leaves properties alone), and a tint is written `color-mix()`; the palette rule still accepts the older `rgb(var(--x-rgb) / a)` form. No rule changed.
- `repo/dependabot.example.yml` skips vue-tsc 3.3.14, which writes a `//` in a static template attribute as broken virtual code and stops checking the rest of that template (vuejs/language-tools#6322): it reported four false errors in Kindred Nights and could hide real ones. Each Vue project pins vue-tsc at 3.3.13 until the fix ships (2026-11-07).
- `repo/dependabot.example.yml` says to give the Font Awesome registry no `scope:`. With one, Dependabot writes its own `.npmrc` in place of the project's, which loses `install-links=true`, so its lockfile records `lint/web` and `test/a11y` as links and `npm ci` fails: TarotGen.io's npm pull request #12.

## [2.0.0] - 2026-11-06

This is a major: every project's own Stylelint moves to 18 when it takes it.

### Added

- `LICENSE`: the MIT license, which `lint/web`'s and `test/a11y`'s `package.json` already declared. It covers this repo only; the projects that hold it as a submodule keep their own.
- Dependabot for this repo (`.github/dependabot.yml`): weekly updates for the GitHub Actions the reusable workflows pin, `lint/web`'s and `test/a11y`'s npm packages, and `lint/go`'s Go modules, which no project can update through its submodule. They reach the projects with the next release.
- `deploy/pwsh`'s `Backup-RemoteDatabase`: the snapshot a site that isn't a service (the Gallery, TarotGen.io) takes before its migrations, to `Install-ServiceBinary -Database`'s standard and with the same shell: `sqlite3 .backup`, `PRAGMA integrity_check`, gzip, `gzip -t`, then `<prefix><time><suffix>.gz`, the newest `-Keep` (3) kept across both forms. It returns a shell block to put in a step's hook.
  - The database path is given (`-Database`) or read from a shell variable when the block runs (`-DatabaseVariable`, for a path the host's `.env` names).
  - `-Owner` writes through `runuser`, under `-Umask`, so files beside the database keep its owner.
  - Afterwards `$snapshot`, `$snapshot_db` and `$snapshot_restore` (the exact `gunzip -c` restore command, wrapped in `systemctl stop`/`start` with `-Service`) are set for the hook's failure message; with `-Database`, the returned string also carries `.Snapshot`, `.Database` and `.Restore` for PowerShell's.
  - A site's existing uncompressed snapshots with the same names count among those kept and age out.
- `Copy-LiveDatabase -Owner`: the host's copy is made as the database's user, under umask 077, so it can sit beside the database.

### Changed

- **Breaking:** `lint/web`'s Stylelint configs move to Stylelint 18 (decided 2026-11-06). The peer range is `^18.0.0`, with `stylelint-config-standard` 41 and `stylelint-config-recommended` 19 (this repo's first two Dependabot pull requests, which failed alone). Each project raises its own `stylelint` to 18, which `task shared:update` now does, and needs Node ^24.15.0 or >=26 (`engines` says so).
  - Five rules join the recommended set: `value-no-invalid`, `selector-no-invalid`, `selector-no-unmatchable`, `selector-no-deprecated` and `at-charset-rule-no-invalid`. The Gallery, Kindred Nights and Senpan had no findings.
  - TarotGen.io drops `stylelint-config-recommended-scss`, which has no Stylelint 18 release and blocks the install. It reads `bulma.scss` with `customSyntax: 'postcss-scss'` and removes the stray `@charset`.
- `repo/Update-SharedTooling.ps1` first raises a project's own copy of any `lint/web` or `test/a11y` peer that its lockfile holds outside the release's range, with `npm install -D <tool>@<range>`, then re-installs the packages: npm refuses the new package beside the old tool. Only `devDependencies` are touched, exact pins stay exact, and `-SkipInstall` skips it.
- `Install-ServiceBinary -Database` names its snapshots by the time in UTC, as `Backup-RemoteDatabase` does, instead of the deploying machine's local time. Restores and pruning go by when each snapshot was written, not by its name, so the change moves nothing out of order.
- `repo/dependabot.example.yml` ignores the majors of ESLint, Prettier and Stylelint, and of `eslint-*` and `stylelint-*` packages, besides TypeScript's. A major of a tool `lint/web` owns moves once, in shared-tooling, with its plugins and configs; it failed in each project on its own: Stylelint 18 against `lint/web`'s Stylelint 17 configs, in TarotGen.io and Senpan.

## [1.3.0] - 2026-11-06

### Changed

- The README says to add `<dir>/test-results/**` to a project's markdownlint ignores where an end-to-end suite runs: a failed run leaves Playwright's notes there as Markdown, which failed the Gallery's `task lint` locally.
- PLAN.md: TarotGen.io stays on PHP and Slim (decided 2026-11-06), and the rollout order after the pilots is Senpan, Marxbot, TarotGen.io, then `standards/` and the rest.
- `deploy/pwsh`: every database backup the module keeps on the droplet is compressed with gzip (decided 2026-11-06). Each is checked with `PRAGMA integrity_check`, compressed to a `.partial`, checked with `gzip -t`, then renamed into place, with no uncompressed copy left.
  - `Install-BackupTimer`'s shared job writes `<prefix>YYYY-MM-DD<suffix>.gz`, and fails clearly if gzip is missing. Each run prunes both forms by date and compresses any dated copy still uncompressed, keeping its time; nothing else in the folder is touched. The log line gives the sizes compressed and not. The job's header on the host says how to put a copy back with `gunzip -c`. The units are unchanged, but the job is not, so each project's next deploy runs it once, which converts the old copies.
  - `Install-ServiceBinary -Database` writes `<SnapshotPrefix><time><SnapshotSuffix>.gz`, checked before anything is installed; a failed check brings the services back up with nothing installed. It also checks that `sqlite3` and `gzip` are on the host before anything stops. The newest three are kept across both forms, so the old uncompressed snapshots age out over three deploys.
  - Every restore (`-RestoreDatabaseOnRollback`, `Restore-ServiceBinary -Database`) takes the newest snapshot of either form, by when it was written, tests a `.gz` with `gzip -t`, then decompresses it into the database file in place. The command printed for a project without `-RestoreDatabaseOnRollback` uses `gunzip -c`. `Restore-ServiceBinary` now fails, after starting the services, if the snapshot could not be put back.
  - Snapshots are matched by their exact time-stamped name, so a `.partial`, or a `.gz` when the suffix is empty, is never taken for one.
  - No project needs to change its calls. `Copy-LiveDatabase` is unchanged: its host copy is removed after each pull.

### Fixed

- `lint/pwsh/Invoke-ScriptLint.ps1` skips a tracked script deleted in the working tree and not yet committed. It linted every file `git ls-files` named, so Senpan's removed `PSScriptAnalyzerSettings.psd1` failed the lint until the deletion was committed.
- A stray space in `lint/dotnet/.globalconfig`'s comment on doc comments.

## [1.2.0] - 2026-11-06

Everything a rollout brings, so a project takes it in one pass (decided 2026-11-06): the scheduled backup and end-to-end tests join the configs and the deploy.

### Added

- `deploy/pwsh`'s `Install-BackupTimer`: a project's daily database backup, installed and checked by its deploy, where Kindred Nights' was installed by hand. It renders a systemd timer and oneshot service with Kindred's hardening, installs them only where they differ from the live copies, runs the service once to check them, and puts the previous copies back if that run fails. The shared job writes a `VACUUM INTO` copy of the live SQLite database, checks it with `PRAGMA integrity_check`, names it `<prefix>YYYY-MM-DD<suffix>` and keeps 28 days. `-Command` runs a project's own job instead.
- `e2e.yml`: the reusable end-to-end job. It installs the front end (from web.yml's cache), Go or PHP when asked, then runs the caller's setup and its Playwright suite in the runner's Chrome, and keeps the traces of a failed run.

### Fixed

- `test/e2e/playwright.js` is marked as an ES module by a `package.json` of its own, as `test/web/vitest.js` was in 1.1.2, so Node never reads it as CommonJS.

## [1.1.2] - 2026-11-06

### Changed

- `deploy/pwsh`'s README: connection sharing works against the droplet, tested by Kindred Nights' v0.29.4 deploy, the pilot; the reconnect paths are still tested only against a stand-in plink.

### Fixed

- `test/web/vitest.js` is marked as an ES module by a `package.json` of its own (`"type": "module"`, private, never installed). With no `package.json` above it, Node treated it as CommonJS, and every Vite build that imported it warned that Vite's native config loader, planned as the default in a future major version, would refuse it (the Simple Image Gallery's and Kindred Nights'). The import path is unchanged.

## [1.1.1] - 2026-11-05

### Fixed

- `go.yml` runs govulncheck v1.9.0 by default instead of v1.1.4. The old release analyses code with `golang.org/x/tools` v0.29.0, which panicked (`unexpected expr: *ast.KeyValueExpr`) on Kindred Nights under Go 1.27, failing its first CI run on the shared workflows. shared-tooling's own CI now runs the same version on `lint/go`, so a release too old for current Go fails here first.

## [1.1.0] - 2026-11-05

Found while moving Kindred Nights, the pilot, onto shared-tooling.

### Added

- `lint/web`'s `tsconfig.app.json` turns on `noUncheckedIndexedAccess`, so an index into an array or a record says it may find nothing. Without it, the shared ESLint base's `no-unnecessary-condition` calls the guards for a missing row or key needless, and removing them would be bugs: 26 of Kindred Nights' 30 findings were guards like that. Expect a few type errors where code assumed an index exists.

### Fixed

- `dotnet.yml` runs the tests from the test project's folder, so a `global.json` beside it is read, and passes `--project` only when that file picks Microsoft.Testing.Platform. Run from the repo root, `dotnet test --project` failed for a project on that platform (Kindred Nights' plugin tests).
- `lint/web`'s README says to run `npm dedupe` once a project's own plugin copies are removed, since an older lockfile can keep a second copy nested.

## [1.0.1] - 2026-11-05

### Fixed

- `lint/pwsh/Invoke-ScriptLint.ps1` retries PSScriptAnalyzer's own crash up to six times instead of three. On a cold start it can crash on a large file several times in a row before it passes (GitHub's Linux runner did so three times on `SharedDeploy.psm1`, failing v1.0.0's own CI). A finding is still never retried.

## [1.0.0] - 2026-11-05

### Added

- `lint/web`: `@jwill89/lint-web`, replacing the `jwill89/eslint-config` submodule. ESLint for Vue 3 and TypeScript with template accessibility (`eslint-plugin-vuejs-accessibility`), the `vueConventions` and `tsStylistic` layers, a React variant with JSX accessibility (`eslint-plugin-jsx-a11y-x`), Prettier, Stylelint (with `paletteRules` and a Tailwind layer) and base tsconfigs. `curly` now runs: Prettier's conflict list used to switch it off.
- `lint/go`: the golangci-lint template and `golangci-sync`, which writes each module's `.golangci.yml` and merges its `.golangci.local.yml`.
- `lint/php`: the PHPStan base (level 8), the PHP CS Fixer rules (PER-CS 3.0) and the Rector set.
- `lint/dotnet`: `analyzers.props` and `.globalconfig`, with the naming rules reaching the build.
- `lint/pwsh`: the PSScriptAnalyzer settings, and `Invoke-ScriptLint.ps1`, which retries the analyzer's own crash.
- `lint/markdown`: the markdownlint config.
- `deploy/pwsh`: the `SharedDeploy` module: one archive and one shared SSH connection per deploy, smoke checks with rollback, plugin publishing and the live database pull.
- `test/`: the Vitest settings (`test/web`), axe checks for Playwright (`test/a11y`), the Playwright settings (`test/e2e`) and the coverage floors for Go and PHP.
- `repo/`: the shared `.editorconfig` and `.gitattributes` with `Sync-RepoFiles.ps1`, the Taskfile include, the Dependabot example, and `Update-SharedTooling.ps1` with its version check.
- `.github/workflows`: reusable workflows for each stack (`web`, `go`, `php`, `dotnet`, `pwsh`, `docs`, `osv`).
