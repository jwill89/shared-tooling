# Changelog

Every change to shared-tooling, by release. A project takes a release with `task shared:update -- v<version>`; see README.md. The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/):

- **Major:** a project has to change its own files to take it (a renamed export, a removed input, a moved file).
- **Minor:** new rules, tasks or features. A new lint rule can raise findings in a project when it takes the release.
- **Patch:** fixes that change nothing a project relies on.

## [Unreleased]

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
