# Web Projects: Stack Review and Standardization Plan

Written November 5, 2026, from a review of every project in `C:\Web Projects`. This file is the living plan: change it here, and record each new decision with its date.

## Summary

No big migration is needed: the current stack is close to what I'd pick for these projects. Go backends, Vue 3 + Vite + TypeScript front ends, SQLite, and hardened systemd units behind Apache and Cloudflare already do well on performance, footprint, reliability and community.

The real gains are in making things consistent across projects, plus moving one backend (TarotGen.io) off Slim. This review covers all 20 folders in Web Projects.

Four follow-up questions are answered below. Vue's Vapor mode is still a release candidate and will help these sites only a little. Only Home Library gains from a real-time change, and it's a server-sent event stream, not WebSockets. Two shared repos are worth building: one tooling submodule for every stack's lint, tests, CI and deploys, and the component kit. Rust isn't a fit for any migration.

## Decisions so far

The standardization work starts from these, so it doesn't reopen them. All were decided on November 5, 2026.

- TarotGen.io's backend moves from Slim to Go.
- Two shared repos, both named with "shared": shared-tooling (public, one submodule per project, folders named `<purpose>/<target>`) and shared-components-vue.
- Stay on ESLint. Markdown lint, the test setup and a `standards/` guide all live in shared-tooling.
- The component kit's own decisions are in shared-components-vue's `PLAN.md`.
- modernc.org/sqlite is the one Go SQLite driver.
- jsdom for Vitest tests that need a DOM, Vitest's `node` environment for the rest, Playwright for end-to-end tests.
- The droplet's memory is tight, so its fixes come first.
- Stay on Vue 3; keep Laravel for the Gallery, Python for Conlang Translator and React for Family Card Game; no Rust.
- Home Library moves from polling to an SSE stream.
- Coverage floors that only rise, rather than a fixed target.
- huma for OpenAPI everywhere. It generates the spec from code with readable operation and schema names, so Senpan drops its hand-written spec and kin-openapi.
- No hard wrap in Markdown (MD013 off). Markdown sets no line length, and the Gallery's 100 columns came from no standard, so its override goes.
- Devkit Box is retired, since nothing used it. Its local folder is removed (every file matched GitHub); the `jwill89/devbox` repo still needs archiving.

Decided later the same day, while seeding shared-tooling:

- The React lint uses `eslint-plugin-jsx-a11y-x`, the eslint-community fork of `eslint-plugin-jsx-a11y`, which supports ESLint only up to 9.
- Every deploy ships one archive: tar on the PC, one upload, untar on the droplet, checked by SHA-256 and file count before anything live changes. Files go up one at a time only where a project can't do otherwise.
- That keeps a deploy to two SSH connections, under the droplet's `ufw limit ssh` (6 connections in 30 seconds), which is what the scripts' 35-second retry waits out. WinSCP never trips it because it keeps one connection open. If deploys still trip it, the fix belongs on the droplet.
- A service binary uploads before the service stops; then, in one connection, the service stops, the binary is backed up to `.old`, the database is snapshotted, and the new binary is installed, started, checked and rolled back on failure.
- A dropped connection is retried once, with a marker in `~/.shared-deploy` on the droplet so a re-run swap knows it already happened.
- A failed start restores the database snapshot only where a project opts in: Kindred Nights and Home Library do; the Gallery doesn't, since uploads made during the deploy would be lost.
- A failed smoke check rolls back on its own.
- What Do I Know, Venue Tools and the résumé site move from writing onto live files to atomic swaps; the résumé site's files move into a folder of their own.
- Every deploy config names its SSH user; nothing defaults to root.
- Database snapshots use `sqlite3 .backup` and keep 3; the Gallery keeps `VACUUM INTO` and 5.
- A plugin's built version must equal its manifest's and be higher than the published one, and `bin/` and `obj/` are deleted before the release build.
- Pulling the live database for development uses an online `.backup`, keeps 3 local copies, removes the droplet's copy, and skips if the local file is in use.
- Home Library adopts the shared deploy module fully, so the module handles several units and services and an Apache vhost.
- Every project gets a Taskfile, and every project that runs on the droplet gets a deploy, run as `task deploy`.
- Modem Monitor gets no deploy: it is a desktop app for Windows and Linux, so its counterpart is a build that makes each platform's program and installer (`task package:windows`, `task package:linux`), and CI drafts the release from a version tag.
- A deploy keeps one SSH connection open for the whole run, as WinSCP does: PuTTY's connection sharing (`plink -share`), with uploads streamed through it, and a reconnect if it drops. ufw then sees one connection per deploy.
- shared-tooling carries one version and releases as exact tags (`v1.0.0`), with no moving `v1`. A project's submodule and its workflow refs name the same tag, `task shared:update` moves them together, and CI fails if they differ. shared-tooling stays public, so CI, Dependabot and the submodule need no token.
- MirageGO stays outside shared-tooling. It is unlike the other projects in what it does and will need bespoke tooling, so it takes no submodule and no shared configs, and nothing is added to shared-tooling for it.

Decided 2026-11-06, after the Gallery's pilot:

- A rollout brings everything shared-tooling can do, in one pass: configs, CI, the deploy, the scheduled backup, the database pull and end-to-end tests.
- Scheduled backups are a timer that the deploy installs and checks, where Kindred's was installed by hand. It runs daily, writes a dated `VACUUM INTO` copy beside the database on the droplet, and keeps 28 days. Kindred's timer keeps running its own `kindred backup`, which is restore-drilled.
- The copy off the droplet is the live-database pull to the dev machine at each deploy, which every project with a database now does.
- Each rollout adds a basic end-to-end suite that CI runs: the main pages load, axe passes, and one key flow works. Deeper tests come later.

No questions are open.

## Project by project

Every project stays on its current stack except TarotGen.io's backend; the Gallery keeps Laravel but drops Bulma.

| Project | Stack now | Verdict |
| --- | --- | --- |
| TarotGen.io | Slim 4 + Vue / Bulma / Reka UI | Migrate the backend (see below) |
| Simple Image Gallery | Laravel 13 + Vue / Bulma / Reka UI | Keep Laravel, drop Bulma |
| Kindred Nights, Senpan, Home Library | Go + Vue / Vite / TS + SQLite | Keep |
| Marxbot, Nophica | Go Discord bots | Keep |
| Modem Monitor | Go + Fyne + AWS | Keep |
| MirageGO | Go + Vue + Phaser 4 | Keep; outside shared-tooling (bespoke) |
| Family Card Game | Go + React 19 / Mantine | Keep it as React |
| Conlang Translator | Flask + spaCy / NLTK | Keep Python |
| Fantasy Dossier, Fingerprint Generator | Vue SPA (Dossier has a small PHP endpoint) | Keep |
| IDE Résumé Site, Zealot Gaming, MathDad Landing Page | Static or light PHP | Keep |
| What Do I Know | Grav 2 | Keep |
| Venue Tools, Kindred/Senpan/TarotGen plugins | C# / .NET | Dalamud requires it |

## Where the real gains are

Five changes, in order of payoff. None of them is a framework switch.

### 1. Stay on Vue; Vapor is a small gain, later

Vue 3.6's Vapor mode drops the virtual DOM. You turn it on per component with `<script setup vapor>`, and Vapor and regular components can be mixed in one app. As of November 5, 2026, 3.6 is still a release candidate (rc.14, October 30); the stable line is 3.5.45, published that morning. Work on Vue 4 has started.

Switching frameworks wouldn't buy much:

- **Svelte or Solid** are faster in benchmarks. But the Gallery's own measurements show the trip through Cloudflare dominates request time, so users wouldn't notice.
- **React** wins on examples, community and jobs (83.6% usage in State of JS 2025). It also has React Aria, the strongest accessible component library. That's a reason to keep Family Card Game in React, not to convert the Vue apps.

**When to start.** Try it now on a branch with `npm install vue@rc`, and ship it once 3.6.0 is stable. Most of the work is checking your component libraries:

- Vapor needs `<script setup>`; it doesn't support the Options API.
- PrimeVue, Reka UI, TipTap's Vue editor and Font Awesome's Vue component are regular (virtual DOM) components. Mixing them in needs `vaporInteropPlugin`, which keeps the virtual DOM runtime in the bundle, and Vue's release notes advise against nesting the two kinds inside each other.
- So start with your own leaf components, and views that don't wrap library components. Fingerprint Generator depends on nothing but Vue, so it's the one app that could go fully Vapor.

**How much it helps.** Not much that visitors would notice:

- **Bundle size:** a hello-world build drops about 46% (32 KB to 18 KB gzipped), but only as a pure Vapor app. Apps that keep library components keep most of the runtime.
- **Rendering:** Vapor tops the major frameworks in js-framework-benchmark, and the Vue team cites 2–4× faster rendering on dynamic screens. Most of your pages wait on the network and images, not rendering.
- **Where you might feel it:** screens that redraw many items often, such as Home Library's list (thousands of books filtered and sorted in the browser), Senpan's live bingo boards and Kindred's staff consoles, mostly on older phones.

### 2. Consolidate the UI components

This is the biggest gain for WCAG and reuse. The Vue apps use three approaches today (PrimeVue, Bulma with Reka UI, and hand-written components), so the same dialog, toast and page header exist several times over. A shared library, shared-components-vue, replaces them. Its own `PLAN.md`, in that repo, covers why, what it builds, its design tokens and the order the apps adopt it.

### 3. Move TarotGen.io from Slim to Go

Slim has the smallest community of anything on the droplet. Slim 5 has been in development since 2024 with no release date as of the maintainer's last year-end post, and he reports the forum getting quieter.

- **Why Go:** TarotGen.io is built almost exactly like Kindred Nights (Vue SPA, API, Dalamud plugin, SQLite, passkeys), so the huma, scs, goose and go-webauthn patterns carry over.
- **The alternative:** Laravel, for a second Laravel portfolio project. On the criteria here, Go wins.
- **What it won't do:** save droplet memory. PHP-FPM stays as long as the Gallery and Grav need it. The gain is one less backend style to maintain, and more people to ask when something breaks.

### 4. Measure the droplet before migrating anything

Moving Go services won't save memory, since each binary is small. The likely big users are:

- **Conlang Translator:** about 300 MB, per the note in its own service file.
- **PHP-FPM:** a 12-process pool shared by every PHP site.

Run `systemd-cgtop -m` or `ps -eo rss,comm --sort=-rss | head -15` on the droplet to see which processes use the most. Since memory is tight, do these now:

- Set FPM to `pm = ondemand` if it isn't already.
- For Conlang, precompute the few WordNet lookups it uses (`noun_of`, `adjective_of`, `category`, `uncountable`, `related`) into SQLite at build time, so WordNet doesn't stay loaded.
- Add a 1–2 GB swap file if the droplet has none (DigitalOcean doesn't add one). It's a safety net against out-of-memory kills, not extra capacity.

### 5. Small inconsistencies

- **Two SQLite drivers:** modernc in four projects, ncruces in two. Senpan's ncruces choice is correctly documented against `MemoryDenyWriteExecute`, but neither project needs ncruces: both use it only for a per-connection pragma hook and one interrupt check, which modernc also covers. Standardize on modernc, which is equally safe under that setting.
- **Two OpenAPI approaches:** huma (code-first) in Kindred Nights and Home Library, kin-openapi with a hand-written spec in Senpan. Settled: huma, so Senpan moves to it.
- **Résumé site:** it loads Vue from unpkg on every page load. Hosting that file yourself removes an outside dependency that can go down.

## Real-time: WebSockets, streams or REST

The projects that need WebSockets already use them. Only Home Library would gain from a change, and the right change there is a server-sent event (SSE) stream, not WebSockets.

- **WebSockets:** frequent traffic both ways, such as games, chat or live collaboration.
- **SSE:** the server tells the browser something changed, and the browser still writes over REST. Kindred Nights' change feed already works this way.
- **REST:** everything else. It keeps HTTP caching, which WebSockets lose.

| Project | Today | Best fit | Why |
| --- | --- | --- | --- |
| Home Library | REST, polling every 2.5–10 s while background work runs | SSE (reuse Kindred's feed) | Scan, queue and text-reading progress only flows to the browser |
| Family Card Game | WebSockets | Keep | Moves go both ways many times a minute |
| MirageGO | WebSockets | Keep | Game state goes both ways constantly |
| Senpan App Suite | WebSockets | Keep | Live bingo calls and claims |
| Kindred Nights | SSE change feed + REST | Keep | Updates flow one way; writes are occasional |
| Simple Image Gallery | REST | Keep | No live data; Laravel WebSockets need Reverb, another always-on process |
| TarotGen.io | REST | Keep | Draw, save and share are request and response |
| Conlang Translator | REST | Keep | One request, one translation |
| Marxbot, Nophica | Discord's WebSocket gateway | Keep | Discord sets it |
| Fantasy Dossier, Fingerprint Generator, static sites | Static or REST | Keep | Nothing changes while a page is open |

For Home Library the switch is a nice-to-have: one owner, polling only while work runs, so the requests saved are few. The gain is progress that shows the moment it happens.

**WebSockets won't shrink Home Library's list.** It sends the whole library in one response (a decision from November 4). WebSockets change how bytes travel, not how many. If the list grows large:

- Add an ETag, so an unchanged list costs an empty 304 response. The Go server sets none today.
- Or keep a copy in the browser (IndexedDB) and fetch only rows changed since the last version, with the SSE feed saying when.
- Check the response is compressed in transit; JSON like this usually shrinks by most of its size.

Open streams cost little in Go, but each one holds an Apache worker thread while it's open. That only matters with many viewers at once.

## Shared packages

Yes, share them, and stay on ESLint. Two repos are enough: **shared-tooling**, one submodule holding every stack's lint, test, CI and deploy pieces, and **shared-components-vue**, kept apart because it ships code your apps run.

**Naming:** inside shared-tooling, folders follow `<purpose>/<target>`, such as `lint/go` or `deploy/pwsh`, so each piece says what it's for. Both repo names start with "shared" so they sort together. Leave "submodule" out: it says how a repo is delivered, not what it holds.

The copies have already drifted:

- Six `.golangci.yml` files, all different, though Kindred's and Home Library's differ only in comments, one path and the module name.
- Nine PSScriptAnalyzer settings files in six versions, four phpstan configs and eleven editorconfigs, each one different.
- Eleven separate CI workflows, from 46 to 254 lines.
- `@jwill89/eslint-config` is installed in 3 of the 9 Vue front ends (Gallery, TarotGen.io, Fantasy Dossier).

| Where | Purpose | Holds | Used by |
| --- | --- | --- | --- |
| shared-tooling `lint/web` | Lint JS, TS, Vue, CSS | ESLint with the accessibility rules, Prettier, Stylelint, base tsconfig, knip, the front-end package list | 8 Vue front ends (not MirageGO) |
| shared-tooling `lint/go` | Lint Go | A `.golangci.yml` template, govulncheck, the Go package list | 7 Go modules (not MirageGO) |
| shared-tooling `lint/php` | Lint PHP | phpstan base, php-cs-fixer ruleset, Rector set | Gallery, Fantasy Dossier, résumé site, TarotGen.io until it moves |
| shared-tooling `lint/dotnet` | Lint C# | Analyzer props and a shared `.globalconfig` | 4 Dalamud plugins |
| shared-tooling `lint/pwsh` | Lint PowerShell | PSScriptAnalyzer settings (9 copies in 6 versions today) | Every repo with scripts |
| shared-tooling `lint/markdown` | Lint Markdown | One markdownlint config | All repos |
| shared-tooling `deploy/pwsh` | Deploys | One PowerShell module for upload, atomic swap, health check and rollback | 14 deploy scripts |
| shared-tooling `test/a11y` | Accessibility tests | axe checks for Playwright on every route; a WCAG 2.2 AA checklist | Every site with a UI |
| shared-tooling `.github/workflows` | CI | Reusable workflows, one per stack, plus OSV-Scanner | All repos |
| shared-tooling `repo` | Repo files | editorconfig, gitattributes, Dependabot, copied in by a sync task | All repos |
| shared-components-vue (own repo) | UI components | Shared Vue components; see that repo's `PLAN.md` | Every Vue front end |

**C# and PowerShell both earn a folder.** The four plugins use three setups today: Kindred's `Directory.Build.props`, settings inside Senpan's and TarotGen.io's project files, and nothing in Venue Tools, though Senpan's file says it means to match Kindred. For PowerShell, a shared deploy module beats a shared lint file: the 14 deploy scripts total 4,321 lines, and helpers like `Resolve-PuttyTool`, `Write-Step` and `Fail` are copied into 11 of them.

**Markdown earns a folder too.** Under markdownlint's defaults your repos show 9,193 warnings, and 91% come from two rules: lines over 80 columns (6,031) and table pipes that don't line up (2,321). A shared config that turns both off, lets changelog headings repeat under different releases, and allows a few HTML tags cuts that to 428. Most of what's left (blank lines around lists and headings, list indents) `markdownlint-cli2 --fix` repairs on its own.

The VS Code markdownlint extension reads the same config files, so the IDE warnings drop with it. Turn on its fix-on-save (`source.fixAll.markdownlint` in `editor.codeActionsOnSave`). The Gallery's 100-column rule goes too: Markdown sets no line length, and 100 came from no standard.

**Why the component kit is its own repo.** It ships code your apps run, so an app should take a new version on purpose, not because a lint rule changed in the same submodule. Its plan is in that repo.

The one cost of a single tooling repo: a change for one stack moves the submodule for every project. Projects that don't use that folder just see nothing different.

**Why stay on ESLint.** oxlint, the fast Rust-based alternative, doesn't lint Vue `<template>` blocks yet, so it can't run the vuejs-accessibility rules your WCAG checks depend on.

**Write the package choices down, then enforce them.** standards/packages.md holds a Use / Don't use table per stack, and the linter fails the build where it can:

- **Go:** golangci-lint's `depguard` rule rejects a banned import, such as ncruces once Senpan and Modem Monitor move to modernc.
- **Front end:** ESLint's `no-restricted-imports` does the same, such as `bulma` once the kit replaces it.
- **Settled:** modernc.org/sqlite as the one SQLite driver (section 5), jsdom for Vitest, and Playwright for end-to-end tests.
- **Also settled:** huma for OpenAPI, so `depguard` can reject kin-openapi.

**How projects pull them in:**

- Each project adds shared-tooling once as a submodule (at `shared/`, say) and points at the folders it uses.
- Front ends install `lint/web` and `test/a11y` as local packages (`npm install ./shared/lint/web`), the way the eslint-config works today.
- phpstan `includes:` and php-cs-fixer's config `require` the files in `shared/lint/php`.
- The Go configs differ only by module name, comments and one path, so `lint/go` ships a template and a sync task that fills in the module name. CI fails when a project's copy drifts.
- PSScriptAnalyzer points `-Settings` at `shared/lint/pwsh`, and deploy scripts `Import-Module ./shared/deploy/pwsh`, keeping only their own steps and config.
- C# plugins import `shared/lint/dotnet` from their `Directory.Build.props`.
- Each repo's `.markdownlint-cli2.jsonc` `extends` `shared/lint/markdown`. Go-only repos need no Node locally: the VS Code extension lints in the editor, and the shared workflow runs it in CI.
- Keep shared-tooling public. CI then checks out the submodule and calls its workflows with no token, and it holds no secrets, since host details stay in each repo's ignored `deploy.config.ps1`.
- For vulnerability checks, one OSV-Scanner step reads every lockfile type you use (npm, Go, Composer, pip). Keep govulncheck alongside it for Go, since it checks whether the vulnerable code is actually called.

**Shared CI fits mixed stacks.** shared-tooling's `.github/workflows` folder holds one reusable workflow per stack (`go.yml`, `web.yml`, `php.yml`, `dotnet.yml`, `pwsh.yml`), each taking inputs such as the folder to run in. A repo's own `ci.yml` shrinks to the list of the ones it needs, plus its project-only jobs (TarotGen.io's CodeQL and plugin workflows, for example):

```yaml
jobs:
  go:
    uses: jwill89/shared-tooling/.github/workflows/go.yml@v1.0.0
  web:
    uses: jwill89/shared-tooling/.github/workflows/web.yml@v1.0.0
    with:
      dir: web
```

Call them by name rather than having CI detect what's there. Kindred already found a Go file shipped inside an npm package, which is exactly what fools detection. Pin the exact release (`@v1.0.0`), the same one the submodule holds, so one change can't break eleven repos at once (decided 2026-11-05; see "How the pieces connect").

## Testing standards

Yes: shared-tooling should hold the test setup and the standards, in `test/<target>` folders beside `test/a11y`. The tests themselves stay in each project, since they test that project's code. Shared Go test helpers wouldn't save much either: across six modules, only one helper name repeats.

| Stack | Today | Gap | shared-tooling adds |
| --- | --- | --- | --- |
| Go | `go test` in all 8 modules, 235 test files | No coverage floor anywhere | `test/go`: CI flags (`-race`, `-shuffle=on`, a coverage profile) and a floor check |
| Vue / TS | Vitest in 8 of 9 front ends, about 250 test files | A floor only in TarotGen.io; Fingerprint Generator has no tests; two DOM libraries (happy-dom, and jsdom in Senpan and TarotGen.io) | `test/web`: a Vitest preset on jsdom, with v8 coverage and a floor |
| PHP | PHPUnit in TarotGen.io, Pest in the Gallery; 154 test files | A floor only in TarotGen.io | `test/php`: a base `phpunit.xml` (Pest reads it too) and TarotGen.io's floor script, made general |
| End-to-end | Playwright in Home Library and TarotGen.io; Puppeteer in the résumé site | Two tools | `test/e2e`: a Playwright base config and conventions; move the résumé site to it |
| C# | xUnit v3 in Kindred's plugin, 13 files | The other three plugins have none | Conventions in the standards doc |
| Smoke | 4 deploy scripts fetch a page after deploying; 4 check only that the service runs | 6 check nothing | A smoke step in `deploy/pwsh`: fetch each listed URL, roll back on failure |

Conlang Translator's pytest suite stays as it is; one Python project doesn't need shared setup.

**Settled: jsdom and Playwright.** Both lead their fields: about 152 million weekly npm downloads for jsdom against 33 million for happy-dom, and 108 million for `@playwright/test` against 15 million for Puppeteer and 8 million for Cypress. jsdom runs slower, but it behaves more like a real browser: TarotGen.io already runs two specs on jsdom because DOMPurify strips scripts there and not under happy-dom.

No test relies on a happy-dom-only API, so the switch is one config line per project plus a test run. The Gallery, Home Library, TarotGen.io and Kindred's markdown test move over; Senpan already uses jsdom. Tests that touch no DOM, like Fantasy Dossier's, stay on Vitest's faster `node` environment.

**The testing standards, in `standards/testing.md`,** set what every project tests and how:

- Test through real SQLite and real HTTP handlers rather than mocks. TarotGen.io's HTTP tests on an in-memory database are the model.
- Every bug fix lands with a test that fails without the fix.
- Each stack's layout, naming and commands, so every repo reads the same.

**On maximum coverage: use a floor that only rises, not a 100% target.** A fixed high target pushes tests written for the number, such as checks of trivial getters and mocks of everything, and slows work without catching more bugs.

- Each project's floor starts at its current coverage, and CI fails when a change lowers it. Raise it as tests are added.
- Hold a higher bar where mistakes cost most: sign-in and passkeys, permissions, migrations, imports, and deploy and rollback.
- Leave generated code (sqlc, OpenAPI types) and startup wiring out of the count.

## Shared standards guide

Yes: a `standards/` folder in shared-tooling becomes the one place every repo, and every coding agent working in it, reads your rules from. It is gathered from what the projects already say, not written from scratch.

The material exists but is scattered: about 8,600 lines across 24 files, including AGENTS.md in six repos, CLAUDE.md in three, CONTRIBUTING.md in four, plus plans, decision logs, ops notes and TarotGen.io's 2,037-line audit. Some rules already repeat word for word, such as Home Library's and Kindred's rule that an agent never commits without your permission.

| File | Covers |
| --- | --- |
| `standards/README.md` | The index, and how each rule is checked: by a linter, by CI, or in review |
| `css.md` | Design tokens, units, class naming, responsive and reduced-motion rules |
| `naming.md` | Files, components, Go packages, tables and columns, API fields, branches |
| `components.md` | Reaching for shared-components-vue first, and when bespoke code is justified |
| `database.md` | SQLite settings, migrations, backups |
| `api-and-realtime.md` | REST and OpenAPI conventions, and when to use SSE or WebSockets |
| `security.md` | Headers and CSP, passkey sign-in, rate limits, client addresses behind Cloudflare, keeping secrets out of repos |
| `accessibility.md` | The WCAG 2.2 AA rules behind the lint rules and the checklist |
| `testing.md` | The testing standards described above |
| `packages.md` | The Use / Don't use list per stack |
| `deploy-and-ops.md` | Atomic swaps, smoke checks, systemd hardening, scheduled backups |
| `docs-and-agents.md` | What README, CHANGELOG, PLAN and the decision log hold, and the rules for coding agents |

**How each repo uses it.** Each repo's CLAUDE.md imports the guide with an `@shared/standards/README.md` line, which Claude Code reads at the start of every session, and AGENTS.md links to it for other agents. Repo files then keep only what's specific to that project. Nophica's CLAUDE.md already points to its AGENTS.md this way.

**How to gather it:**

- Have Claude Code read every AGENTS.md, CLAUDE.md, CONTRIBUTING.md, plan and decision log, and sort each rule as shared, project-only, or conflicting.
- Conflicts come to you as a list to decide; the agent doesn't pick. Three known ones are already settled: Markdown wrapping, OpenAPI, and the split between Bulma, PrimeVue and neither, which the component kit replaces.
- Mark each rule with how it's checked. A rule a tool can check goes into the lint configs too, which keeps the guide short.

## Rust

No migration. Rust is a strong language, but on these criteria Go already gets you most of what it would.

- **Footprint:** the Go services are already small. Rust has no garbage collector, so each would use a few MB less, which is little next to Conlang's \~300 MB or the PHP-FPM pool.
- **Speed:** the services mostly wait on SQLite, the network and Discord. Rust's edge shows on CPU-bound work.
- **Ease, examples, community:** Go is quicker to write and compile, and has more web-backend examples. Rust's ownership rules take a while to get comfortable with.
- **Reliability:** both are memory-safe. Rust also rules out data races at compile time; Go finds them only when tests run with `-race`.

Where it could fit, if a problem shows up:

- **Fingerprint Generator's engine** is pure CPU work in the browser. If a tenprint card ever feels slow to generate, compiling the engine from Rust to WebAssembly is a real option. Try a Web Worker first: it keeps the page responsive with no rewrite.
- **The Gallery's duplicate scan** is the heaviest job on the droplet. If it becomes a bottleneck, a small compiled helper would beat PHP, but a Go one would do nearly as well and match the rest of your code.

You already get Rust where it pays off most, in your tools: Vite 8's bundler (Rolldown) and Ruff are both written in Rust.

## Project gaps

Most gaps are missing CI, Dependabot and post-deploy checks. The riskiest are three SQLite apps with no scheduled backup: Senpan and the Gallery snapshot their database only when they deploy, and Marxbot not at all. No secrets are committed: the two tracked `.npmrc` files hold only the registry address, and every deploy config and `.env` file is ignored.

Every repo gets a CLAUDE.md that points at the standards during rollout, so that's left out of the table. So does a Taskfile with `task deploy`: twelve projects have one that isn't committed yet, and MathDad Landing Page, Zealot Gaming, shared-components-vue and shared-tooling have none.

| Project | Missing | Note |
| --- | --- | --- |
| Conlang Translator | Git repo, Dependabot, changelog, smoke check |  |
| Family Card Game | CI, Dependabot, changelog, accessibility lint, HTTP smoke check | React, so `lint/web` needs a React variant |
| Fantasy Dossier | Smoke check |  |
| Fingerprint Generator | CI, Dependabot, tests, accessibility lint, smoke check |  |
| Home Library | First commit and a remote, changelog | Nothing is committed until 1.0.0 by your choice, so its CI has never run |
| IDE Résumé Site | CI, Dependabot, changelog | Moves from Puppeteer to Playwright |
| Kindred Nights | End-to-end tests | The pilot |
| Marxbot Discord Bot | Changelog, scheduled database backup |  |
| MathDad Landing Page | CI, deploy script | Static page |
| MirageGO | Not tracked here | Outside shared-tooling: its tooling stays bespoke |
| Modem Monitor | Changelog | Desktop app: no deploy; it builds installers per platform instead |
| Nophica Discord Bot | CI, Dependabot |  |
| Senpan App Suite | Dependabot, HTTP smoke check, scheduled database backup, end-to-end tests | Its deploy checks only that the service runs |
| Simple Image Gallery | Scheduled database backup, end-to-end tests | The second pilot |
| TarotGen.io | Smoke check |  |
| Venue Tools Dalamud Plugin | CI, Dependabot, changelog, tests |  |
| What Do I Know | CI, changelog | Grav plugin and theme only |
| Zealot Gaming | CI, deploy script | Static page |

## Where to start

Do what's urgent first, settle the decisions, build the tooling, and only then migrate. Migrating first would mean writing TarotGen.io's Go backend to today's mixed conventions, then reworking it once the standards exist.

1. **Protect money and data first.**
   - Fix the droplet's memory: measure, set `pm = ondemand`, add swap (section 4).
   - Scheduled database backups for Senpan, the Gallery and Marxbot: they become a shared piece, from Kindred's backup timer, and land with each project's rollout in step 6, the Gallery's first (decided 2026-11-06).
2. **Get every project into a known state.**
   - Put Conlang Translator in git; its folder has no repo.
   - Archive `jwill89/devbox` on GitHub, which also stops its Monday image builds and its Dependabot updates. The local Devkit Box folder is already removed.
   - Move `SQL Backups` out of Web Projects. It holds old WordPress tables, users among them, which a Claude Code session opened there would read.
3. **Gather the standards into `standards/` in this repo** (github.com/jwill89/shared-tooling, public). Claude Code sorts each rule as shared, project-only or conflicting and brings you the conflicts.
4. **Seed shared-tooling from what you already have; no new rules yet.**
   - The eslint-config becomes `lint/web`, plus a React variant for Family Card Game.
   - Kindred's `.golangci.yml` becomes the `lint/go` template.
   - The PSScriptAnalyzer file that Home Library, Kindred and Marxbot already share becomes `lint/pwsh`.
   - Kindred's plugin `Directory.Build.props` becomes `lint/dotnet`.
   - The Markdown config above becomes `lint/markdown`.
   - The helpers copied into the deploy scripts become the `deploy/pwsh` module.
   - Kindred's backup timer becomes a shared scheduled backup that the deploy installs, where Kindred's was installed by hand.
   - TarotGen.io's coverage floors become the model for `test/web` and `test/php`, and the deploy scripts' existing health checks become the shared smoke step.
5. **Pilot on Kindred Nights, then the Gallery.** Kindred has Go, Vue, C#, PowerShell, Markdown and CI that runs; the Gallery adds PHP. Home Library has no commits or remote yet, so its CI has never run and it can't show whether the shared workflows work. Kindred's pilot is done (2026-11-05): v0.29.4 deployed on the shared module over one held connection. It found three shared bugs, fixed in v1.1.0 and v1.1.1; its plugin publish on the module is still to be run, at its next plugin release. The Gallery's pilot is done (2026-11-06): 7.0.1 deployed on the shared module, with the smoke check and its rollback, and it gained Dependabot. It found one shared bug, Vite's warning about `test/web/vitest.js`, fixed in v1.1.2. Both are on v1.1.2 with CI passing, the PHP workflow included. Both still take the pieces decided after them: the scheduled backup and a basic end-to-end suite, and the Gallery the database pull too.
6. **Roll out one repo at a time**, on `main`, with no separate branches. Everything shared-tooling can do lands in one pass: swap in the shared configs, move its deploy script onto the shared module, turn on its scheduled backup and database pull, and add its basic end-to-end suite, together (decided 2026-11-05, after Kindred's pilot did them on two branches; backups added 2026-11-06). Point its CLAUDE.md at the standards, trim what moved there, and close that project's gaps (see Project gaps). Small fixes ride along: the SQLite switch in Senpan and Modem Monitor, jsdom, and Playwright for the résumé site.
7. **Then the migrations, in this order:**
   1. TarotGen.io to Go, the first codebase built under the standards from its first commit.
   2. Senpan's API to huma, replacing its hand-written spec and kin-openapi.
   3. The component kit, following its own plan in shared-components-vue.
   4. Home Library's event stream, with its 1.0 work. It's small and touches nothing else.
   5. Vapor, once Vue 3.6 is stable.

**How the pieces connect.** You edit shared-tooling in its own folder, note the change in its CHANGELOG, and run `task release -- 1.2.0`, which sets one version across the repo, commits and tags `v1.2.0`; then push. Each project holds it as a submodule at `shared/`, at a release's tag, and calls the shared workflows at that same tag. To take a release, a project runs `task shared:update -- v1.2.0`, which moves both together and re-runs what's built from them, and commits the result. CI fails if the two ever name different releases. A fresh clone needs `git submodule update --init` once.

**Do the work in Claude Code on your PC, opened at `C:\Web Projects`.** From there it sees every repo and uses your own git sign-in, GitHub CLI and toolchains. Point Claude Code at this file and take one step per session, so each lands as reviewable commits.

## Ideas to skip

These came up and aren't worth doing:

- **Apache → Caddy:** with Cloudflare in front, Caddy's automatic HTTPS adds little, and memory use is about the same. The Family Card Game and MirageGO docs describe Caddy, but both actually run on Apache, so just fix the docs.
- **Laravel Octane or FrankenPHP:** the Gallery's own measurements show Laravel adds only 3–5 ms, which disappears in the trip through Cloudflare.
- **Conlang Translator to Go:** Go has nothing like spaCy.
- **Shared desktop packaging (for now):** Modem Monitor is the only desktop app, so its installers stay its own (decided 2026-11-05). If a second Go and Fyne desktop app comes along, its `packaging/` folder, Taskfile and CI are the seed: the Debian 12 builder, the glibc check and the CI shape carry over, while the Inno Setup script, the nfpm config and the desktop entry become templates.

## Sources

Project facts come from each repo's manifests, deploy files and docs in Web Projects. Outside sources:

- [Two RCs in One Week: Vue 3.6 and Vapor status](https://www.besthub.dev/articles/two-rcs-in-one-week-90-vapor-focused-is-vue-gearing-up-for-a-major-shift-588174d0e4be)
- [npm: vue versions](https://www.npmjs.com/package/vue?activeTab=versions)
- [Peerigon: Vue 3.6 Vapor Mode](https://www.peerigon.com/en/blog/vue-3-6-vapor-mode/)
- [Stackmaven: Vue 3.6 Vapor Mode](https://stackmaven.io/news/vue-vapor-mode/)
- [InfoQ: State of JS 2025 survey](https://www.infoq.com/news/2026/03/state-of-js-survey-2025)
- [odan: The year in review 2025 (Slim maintainer)](https://odan.github.io/2025/12/12/recap-2025.html)
- [Grav 2 stable released](https://getgrav.org/blog/grav-2-stable-released)
- [Oxc: framework compatibility](https://oxc.rs/compatibility.html)
- [Announcing Vite 8](https://vite.dev/blog/announcing-vite8.html)
- [npm download counts, week of Oct 29–Nov 4, 2026](https://api.npmjs.org/downloads/point/last-week/jsdom) (same endpoint for happy-dom, @playwright/test, puppeteer and cypress)
