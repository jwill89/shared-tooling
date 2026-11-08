# Packages

Which packages each stack uses and avoids, and how dependencies are added, pinned, updated and audited.

## How a choice is enforced

- Each table row is a rule: use what the Use column names, and add nothing the Don't use column names. [review]
- A banned import belongs in the shared lint config, so the build fails on it: golangci-lint's `depguard` in `lint/go` for Go, ESLint's `no-restricted-imports` in `lint/web` for the front end. A row stays [review] until its ban is there. [review]
- A new ban is a shared-tooling change, and reaches each project by a release. [review]

## Go

| Use | Don't use | Why | Checked |
| --- | --- | --- | --- |
| `modernc.org/sqlite` | `github.com/ncruces/go-sqlite3` | Pure Go, so CI's race build tests the driver production runs | [review] |
| huma v2: typed handlers, RFC 9457 errors, OpenAPI generated from code | kin-openapi; a hand-written spec | One source for the API and its spec | [review] |
| The standard library first (`net/http`'s ServeMux, `http.CrossOriginProtection`), then `golang.org/x/oauth2` and `golang.org/x/time/rate` | A dependency that adds more code than it replaces | Small pieces, such as an image cropper or Web Push, are written in-house | [review] |
| sqlc for queries; goose v3 with embedded SQL, run at startup | GORM, ent or any ORM | sqlc compiles every query against the schema | [review] |
| `github.com/coder/websocket` | `golang.org/x/net/websocket` | | [review] |
| alexedwards/scs with its SQLite store, for sessions | | | [review] |
| goldmark for Markdown, its HTML sanitized by bluemonday | | | [review] |

- Raise each direct Go requirement by name, never with `go get -u ./...`, because `modernc.org/sqlite` is released against one exact `modernc.org/libc`. [review]

## Front end

| Use | Don't use | Why | Checked |
| --- | --- | --- | --- |
| ESLint | oxlint | oxlint can't lint Vue `<template>` blocks, where the accessibility rules run | [review] |
| The shared `lint/web` package (ESLint, Prettier, Stylelint, the base tsconfig), installed from the submodule | Per-project lint configs; the old eslint-config submodule | One shared set, with only the project's own rules after it | [CI] |
| `eslint-plugin-jsx-a11y-x` for a React app, through `lint/web`'s React config | `eslint-plugin-jsx-a11y` | The original supports ESLint only up to 9 | [CI] |
| TypeScript `~6.0` | TypeScript 7, for now | vue-tsc can't run on 7 yet, and its peer range doesn't say so; the hold ends when vue-tsc and typescript-eslint support 7.1 | [review] |
| vue-tsc 3.3.13 | vue-tsc 3.3.14 | 3.3.14 misreads a `//` in a static attribute and stops checking that template; Dependabot skips only 3.3.14, so the fix still comes through | [review] |
| knip, listing only the entry points it can't infer | | It fails on unused files, exports and dependencies | [lint: knip] |
| Vitest on jsdom, with `@vue/test-utils` and `@vitest/coverage-v8` | happy-dom | jsdom behaves more like a real browser | [review] |
| Playwright, with axe through the shared `test/a11y` package | Puppeteer, Cypress | | [CI] |
| Reka UI for headless primitives (see [components.md](components.md)) | Bulma, once the component kit replaces it | | [review] |
| Tiptap 3 with its Markdown package, as the one editor, storing Markdown | Another rich-text editor | Every `@tiptap/*` package stays on one version | [review] |
| Font Awesome through `@fortawesome/fontawesome-svg-core` and the `<font-awesome-icon>` component (see [components.md](components.md#icons)): the free packages (`@fortawesome/free-*-svg-icons`) where they cover a site's icons, otherwise the Pro kit package (`@awesome.me/kit-…`) the owner assigns it, which several sites may share (Fantasy Dossier, the Gallery and Home Library share one) | The per-style Pro packages (`@fortawesome/pro-solid-svg-icons` and the like); a kit script or any icon CDN; icon CSS classes | Only the icons a project imports ship, and nothing is fetched or metered per page view; the free packages need no registry token | [review] |
| Every library bundled through npm; fonts self-hosted as WOFF2, with their licences checked | CDN scripts; Google Fonts | No outside dependency that can go down | [review] |
| openapi-typescript, run through `npx` at a pinned version, and openapi-fetch | TanStack Query | A small `useApi` composable covers loading state | [CI] |
| Plain form components over one submit wrapper | A form library; Nuxt or any SSR | | [review] |
| PrimeVue 4, where an app still uses it | PrimeVue 5 | It moved to a licence-key model, and the component kit replaces PrimeVue | [review] |

## PHP

| Use | Don't use | Why | Checked |
| --- | --- | --- | --- |
| `config.platform.php` set to the exact PHP production runs, raised only after the server is upgraded | | Composer then resolves for what production runs | [review] |
| Caret ranges floored at the installed versions | `"*"` constraints | | [CI] |
| composer-unused and composer-require-checker (`composer deps:check`), with every directly used package and `ext-*` declared and checked against production's `php -m` | Relying on a transitive package | | [CI] |
| ergebnis/composer-normalize, run in CI with `--dry-run` | | | [CI] |
| roave/security-advisories, with `composer audit` gating CI | | | [CI] |
| `require-dev` for anything only dev tooling uses, its symbols whitelisted by name for composer-require-checker | Loading dev tooling in production | | [CI] |

## C\#

| Use | Don't use | Why | Checked |
| --- | --- | --- | --- |
| The `Dalamud.NET.Sdk` MSBuild SDK, on the .NET 10 SDK | NuGet Dalamud packages | The SDK supplies the target framework and Dalamud's references | [CI] |
| xUnit v3 for plugin tests | | | [review] |

## Every stack

| Use | Don't use | Why | Checked |
| --- | --- | --- | --- |
| SQLite, and a database-backed queue (Laravel's `database` driver) | Redis or a message broker | Nothing more always-on on a server whose memory is tight | [review] |

## Adding a dependency

- Check the licence of every new dependency, transitive ones included, and of every font and data source. [review]
- A data source is adopted only after its terms allow keeping what it gives: no paid API, no scraping. [review]
- Install with `npm ci`, and use `npm install <pkg>` only to add a package. [CI]
- Shared packages install from the submodule as copies, `file:../shared/...` with `install-links=true` in a tracked `.npmrc`, since through a symlink ESLint can't find its plugins. [CI]
- The Font Awesome Pro registry token lives in each developer's own `~/.npmrc` and in the repo's `FONTAWESOME_NPM_TOKEN` Actions and Dependabot secrets, never in a tracked file (see [security.md](security.md)). [review]
- A Font Awesome kit holds only the styles its sites import from. Every style adds about 10 MB to each download of the kit, CI's included, and those downloads count against the account's monthly bandwidth: Senpan's kit of every style was a 201 MB download, and 42 MB once cut to the four it uses. A style goes into the kit when a site first imports from it, and comes out when the last import goes. [review]
- Font Awesome Pro files (a kit's icons, a downloaded package) are never committed, so a public repo may install a kit; a repo that has to hold them stays private. [review]

## Versions and holds

- Tool versions are pinned exactly, and the shared workflows' inputs hold the pins: golangci-lint, govulncheck, markdownlint-cli2 and PSScriptAnalyzer. [CI]
- golangci-lint is built with the project's own Go toolchain. [CI]
- A generator run through `npx` names a fixed version. [review]
- A runtime's version lives in one file that CI reads: Node's in `.nvmrc`, with `engines.node` matching, and Go's in the `toolchain` line of `go.mod`. [CI]
- A version held on purpose is held in config (a `~` pin, a Dependabot ignore or a Composer `conflict`), and AGENTS.md records why it is held and what ends the hold. [review]
- A hold stays until its reason is gone. [review]
- A major of a tool `lint/web` owns (ESLint and its plugins, Prettier, Stylelint and its configs) moves in shared-tooling first and reaches a project with `task shared:update`. [review]
- A project keeps its own `eslint`, `prettier`, `stylelint` and `typescript` ranges inside `lint/web`'s peer ranges. [CI]

## Updates

- Dependabot runs weekly on Monday for every ecosystem in the repo, from a `dependabot.yml` copied from `repo/dependabot.example.yml`. [review]
- A push goes through `task push`, so Dependabot finds little left to open: it takes the in-range updates Dependabot would open (`task shared:deps`, which leaves out what `dependabot.yml` holds) after asking, runs `task check` on them and commits them as one `chore(deps)` commit, then scans every lockfile with OSV-Scanner (`task shared:vuln`), runs `task check`, and pushes. Majors are only listed: Dependabot opens each alone, to be read first. [review]
- Every project's `task check` includes `task shared:vuln`, so a known advisory fails locally before CI's OSV job finds it. [review]
- Minors and patches are grouped per ecosystem, and majors come one by one. [review]
- Dependabot ignores held majors and the majors of tools `lint/web` owns, and leaves out the `shared/` submodule, since a shared-tooling release is taken on purpose. [review]
- A major is planned apart from in-range updates: check its breaking changes against the code and specs before taking it, and recheck the library's APIs after. [review]
- `npm audit fix` runs without `--force` and lands as its own commit. [review]
- A NuGet vulnerability advisory stays a warning under warnings-as-errors, so a new advisory can't block a release; Dependabot raises the update. [CI]

## Audits

- CI audits dependencies and gates the build: `npm audit --omit=dev` in `web.yml`, `composer audit` in `php.yml`, govulncheck in `go.yml`, and OSV-Scanner over every lockfile in `osv.yml`. [CI]
- Go keeps govulncheck beside OSV-Scanner, since govulncheck checks whether the vulnerable code is actually called. A Go module OSV-Scanner flags is still raised to its fixed version once a tagged release carries the fix, even when govulncheck finds the code unreached. [CI]
- An advisory OSV-Scanner reports is fixed by raising the package. Only one that reaches nothing that ships (lint, test or build tooling), and whose fix no dependent's range takes, may be passed over: in an `osv-scanner.toml` beside the lockfile, copied from `repo/osv-scanner.example.toml`, each entry with its reason and an `ignoreUntil` three months out, when it is looked at again. [CI]
