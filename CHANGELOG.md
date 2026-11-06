# Changelog

Every change to shared-tooling, by release. A project takes a release with `task shared:update -- v<version>`; see README.md. The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/):

- **Major:** a project has to change its own files to take it (a renamed export, a removed input, a moved file).
- **Minor:** new rules, tasks or features. A new lint rule can raise findings in a project when it takes the release.
- **Patch:** fixes that change nothing a project relies on.

## [Unreleased]

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
