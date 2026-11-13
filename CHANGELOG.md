# Changelog

The changes a project would notice in shared-tooling, by release. A project takes a release with `task shared:update -- v<version>`; see README.md. The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/):

- **Major:** a project has to change its own files to take it (a renamed export, a removed input, a moved file).
- **Minor:** new rules, tasks or features. A new lint rule can raise findings in a project when it takes the release.
- **Patch:** fixes that change nothing a project relies on.

## [Unreleased]

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

[Unreleased]: https://github.com/jwill89/shared-tooling/compare/v2.9.0...HEAD
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
