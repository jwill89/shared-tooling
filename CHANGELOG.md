# Changelog

Every change to shared-tooling, by release. A project takes a release with `task shared:update -- v<version>`; see README.md. The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/):

- **Major:** a project has to change its own files to take it (a renamed export, a removed input, a moved file).
- **Minor:** new rules, tasks or features. A new lint rule can raise findings in a project when it takes the release.
- **Patch:** fixes that change nothing a project relies on.

## [Unreleased]

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
