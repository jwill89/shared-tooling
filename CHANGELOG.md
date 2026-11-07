# Changelog

Every change to shared-tooling, by release. A project takes a release with `task shared:update -- v<version>`; see README.md. The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/):

- **Major:** a project has to change its own files to take it (a renamed export, a removed input, a moved file).
- **Minor:** new rules, tasks or features. A new lint rule can raise findings in a project when it takes the release.
- **Patch:** fixes that change nothing a project relies on.

## [Unreleased]

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
