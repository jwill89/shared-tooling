# Code style

How code is written in every project, stack by stack: the shared linters carry most of the detail, and this file holds what they leave to review.

Each rule ends with how it is checked. Names are in [naming.md](naming.md), CSS in [css.md](css.md), tests in [testing.md](testing.md), and which packages to use in [packages.md](packages.md); [README.md](README.md) indexes the guide.

## All

### Configs and formatting

- Every lint, format and type-check config extends shared-tooling's (`lint/web`, `lint/go`, `lint/php`, `lint/dotnet`, `lint/pwsh`, `lint/markdown`) and adds only the project's own rules, after the shared ones. [review]
- A rule every project should hold, or a change to a shared rule, is made in shared-tooling, not in one project. [review]
- What shared-tooling writes is never edited in the project: `shared/`, the generated `.golangci.yml`, and `.editorconfig` and `.gitattributes` above the project marker. [CI]
- A Go module's own lint rules go in `.golangci.local.yml`, each with its reason. `task shared:golangci:sync` regenerates `.golangci.yml`, and both files are committed. [CI]
- A project's own `.editorconfig` and `.gitattributes` lines, such as its C# exceptions, go below the project marker. [CI]
- A lint rule is turned off with its reason: in the project's config, or at the one line it doesn't fit (`// eslint-disable-next-line rule -- why`, `//nolint:linter // why`). Never silently. [review]
- A new linter is adopted only after a run over the code. It stays when its findings are worth fixing, and then every finding is fixed. [review]
- Each language has one formatter: Prettier, gofmt with goimports, PHP CS Fixer, `dotnet format`, and PSScriptAnalyzer's layout rules. No linter also polices formatting. [lint: eslint-config-prettier]
- Enforced by the synced `.editorconfig` and `.gitattributes`: UTF-8, LF, a final newline, no trailing whitespace, and no CRLF in a commit. [CI]

### Design

- Match the surrounding code: its naming, comment density, idioms and patterns. Don't bring in a new style. [review]
- Comments and doc comments follow [comments.md](comments.md). [review]
- There is one way to do each thing: one API client, one form pattern, one table component, one formatter for each kind of value. [review]
- Look for an existing helper or registry entry before writing a new one. A second way is a refactor of the first, never an addition beside it. [review]
- Don't abstract ahead of a second case. Build the first plainly, and let the second show what is truly common. [review]
- One function builds each derived value (a display label, a URL, a file path), so callers can't disagree. Views never build one inline. [test]
- A rule implemented in more than one place (the Go server, the TypeScript front end, a C# plugin) agrees in all of them. The server's copy is the authority, and changing one means changing every copy. [review]
- Dead code is deleted in the change that makes it dead, along with CSS for markup that no longer exists. Nothing is disabled, flagged off or kept for later. [lint: golangci-lint unused, Rector dead-code set]
- Domain rules (a game's rules engine, a card or print generator, a pay calculation) are pure code with no database, clock, network, WebSocket or DOM, so each can be tested alone. [test]
- Handlers and controllers are thin HTTP adapters: they read the request, call domain code or a service, and return the response. SQL and business rules never sit in them. [review]

### Settings, errors and background work

- Anything an owner might change is a setting or content, not code. [review]
- An external resource's ID (a Discord server, a channel, a role) is a setting, not an environment variable. [review]
- Settings are validated as they load: defaults first, then every value checked. [test]
- A setting that is invalid or can't be read is an error that names it, and the service refuses to start rather than fall back silently. [test]
- An unknown, empty or omitted enum value reads as the safe default, so an unknown value can never grant something. [review]
- An error is logged once, where it is handled, not returned past the handler to be logged again. [review]
- A 4xx the client caused isn't logged; 5xx and uncaught errors are. [review]
- Background and batch work can be stopped and run again: a restart stops it, the next run picks up what is left, and one failing item fails only itself. [review]
- A record of an outside item is removed only when the platform confirms the item is gone (Discord's Unknown Member, 10007). Any other error keeps it. [review]
- A 404 on a delete counts as done. [review]

## Go

- Enforced by the shared golangci config: the standard set plus bodyclose, errorlint, exhaustive, gocritic, gosec, noctx, revive, rowserrcheck and others, with gofmt and goimports as formatters. CI also runs `go vet` and a pinned govulncheck. [lint: golangci-lint]
- Packages are split by domain. Handlers stay thin, and the rules live in the domain packages. [review]
- No package-level variables hold state, config included. Dependencies and config are built in `main` and passed in, in structs. Constants and sentinel errors are not state and stay at package level. [review]
- Every error is handled, or discarded at its line with the reason beside it. errcheck excuses only response writes. [lint: golangci-lint errcheck]
- A rollback goes through one helper that ignores `sql.ErrTxDone` and logs anything else. [review]
- A `Close` error is dropped only for something opened to read. A command closes its database last and fails if that close fails. [review]
- Errors are wrapped with context as they are returned (`fmt.Errorf("load media: %w", err)`) and compared with `errors.Is` and `errors.As`. [lint: golangci-lint errorlint]
- Logs go through `log/slog`. [review]
- Every query and outbound request takes a context. [lint: golangci-lint noctx]
- Handlers pass `r.Context()`. Background loops pass the process context, which SIGINT and SIGTERM cancel. Work that must finish after the response runs under `context.WithoutCancel(r.Context())`. [review]
- Handlers and store methods return typed structs, never `map[string]any`. [review]
- A service never exits from inside. A listen failure goes through the normal graceful shutdown, not `os.Exit`. [review]
- A top-level recover in the HTTP handler logs a panic and returns 500, and every long-lived goroutine recovers, so one panic can't stop the process. [review]
- One goroutine owns each piece of shared state and takes its work off a channel or queue. Events only nudge it, so a burst is handled in one pass, nothing runs twice at once, and no locks are needed. [review]

## Vue and TypeScript

- Enforced by the shared `lint/web` package (the ESLint base with `vueConventions` and `tsStylistic`, Prettier, and the tsconfigs), run in CI by the lint, format-check and type-check scripts: `<script setup lang="ts">` and the Composition API only, typed refs and `useTemplateRef`, a `type` on every button, `curly`, `eqeqeq`, `import type` for type-only imports, `_` for an unused name, no `console.log`, no `any`, `catch` bound as `unknown`, no floating promise (`void` marks an intended fire-and-forget), and `strict` with no unused locals or parameters. Prettier writes no semicolons, single quotes, width 100 and trailing commas. [lint: ESLint, Prettier, vue-tsc]
- A template never uses a static `style=""`. The style goes in the component's CSS. [lint: ESLint vue/no-static-inline-styles]
- An index into an array or record may find nothing, and its type says so. Guard it. [lint: vue-tsc noUncheckedIndexedAccess]
- A guard the type asks for is never deleted just to quiet a lint warning. [review]
- A value checked before a callback is held in a `const`, not re-read with `!`. `!` belongs in tests, where the fixture guarantees the index. [lint: ESLint @typescript-eslint/no-non-null-assertion]
- The type-check script runs vue-tsc on the real projects (`tsconfig.app.json`, `tsconfig.node.json`), never on a solution-style root with `"files": []`, which checks nothing. [CI]
- The build script type-checks before Vite builds. [CI]
- A module augmentation (`declare module 'vue' { … }`) lives in a file that is itself a module, with a top-level import or export. In a script file such as `vite-env.d.ts` it replaces the module instead. [review]
- No `as` cast where a typed interface works, and no `Number()` or `String()` on a value already of that type. [review]
- Copy keyed by a backend enum is a `Record<Enum, …>`, so a new value fails the type-check until it has copy. [review]
- Front-end API types are generated from the OpenAPI spec with openapi-typescript, into a committed file that is never edited by hand. [CI]
- The generated types are the only API types. Code imports them through the aliases in `types/index.ts`, and only client-only shapes are written by hand. [review]
- All HTTP goes through one API client composable, and every backend path is a typed function in one endpoints module. Nothing else calls `fetch`, a service worker excepted. [review]
- The API client raises one structured error: status, code, the server's message and field errors. The UI shows the server's message rather than re-wording it at each call site. [test]
- A composable never swallows a failure: it returns a result or toasts what failed. It stays quiet only on a 401, which signs the user out. [test]
- A fire-and-forget call toasts on failure and never rejects, and `app.config.errorHandler` toasts anything uncaught. [test]
- App state lives in Pinia stores under `stores/`, one per domain. [review]
- Navigation is Vue Router in history mode, with real, linkable URLs, and routes lazy-load their views. [review]
- A page's title, and what the shared chrome shows for it, are typed route `meta`. They are never set in each view or worked out in the navbar. [review]
- Shared logic goes in composables, and shared values in one constants module, imported rather than hard-coded. [review]
- Code imports from `src/` through the `@/` alias. [review]
- Targets are evergreen browsers: no `browserslist`, no polyfills, TypeScript's `lib` and `target` matching the bundler's (ES2022), and newer APIs feature-detected. [review]

Components come from shared-components-vue first ([components.md](components.md)), and templates meet [accessibility.md](accessibility.md). The API's own conventions are in [api-and-realtime.md](api-and-realtime.md).

## PHP

- Enforced by the shared `lint/php` configs, run in CI: PHP CS Fixer on PER-CS 3.0 with no unused imports and a trailing comma on multi-line arrays and parameter lists (not on call arguments); PHPStan level 8 with the strict and deprecation rules over the app and its tests (no `empty()`, no short ternary, boolean conditions only, typed array generics); and Rector's dead-code set. There is no line-length limit. [lint: PHP CS Fixer, PHPStan, Rector]
- A project may raise PHPStan's level toward `max`, but never lowers it. [lint: PHPStan]
- Only findings that predate PHPStan's adoption sit in a baseline. New ones are fixed. [review]
- Every PHP tool targets the PHP version the server runs (the fixer's migration set, Rector's PHP set, PHPStan's PHP version), so none writes syntax production can't run. [lint: PHP CS Fixer, Rector, PHPStan]
- Time is UTC and comes from one clock helper, never `date()`. The entry point sets UTC as well. [review]
- The suite runs under a far-off zone (`-d date.timezone=Pacific/Kiritimati`, UTC+14) to prove nothing depends on the server's zone. [test]

## C\#

- Enforced by the shared `lint/dotnet` files, with `dotnet format --verify-no-changes` in CI: `analyzers.props` runs the .NET analyzers at `latest-recommended` and checks code style in the build, and `.globalconfig` sets `this.` on members, `var`, file-scoped namespaces with usings outside them, braces on multi-line bodies, readonly fields, the naming rules, and doc comments only where the name doesn't say it. [lint: .NET analyzers, dotnet format]
- A project's exceptions go below the marker in its `.editorconfig`, each with its reason. [review]
- C# builds have 0 warnings, in Debug and in Release. [CI]
- Every build, local, deploy and CI, treats warnings as errors. The shared `dotnet.yml` input `warnings-as-errors` defaults to off, so each project turns it on. [CI]

## PowerShell

- Enforced by PSScriptAnalyzer 1.25.0 with the shared `lint/pwsh` settings over every tracked script, where any finding fails CI: the default rules, one-true-brace layout, four-space indents, aligned assignments and correct casing, with `Write-Host` allowed. [lint: PSScriptAnalyzer]
- Scripts are plain ASCII, so Windows PowerShell 5.1 reads them correctly without a BOM. [lint: PSScriptAnalyzer PSUseBOMForUnicodeEncodedFile]
- A function takes its switches as parameters, never reading them from script scope. [review]

Function names are in [naming.md](naming.md); deploy scripts follow [deploy-and-ops.md](deploy-and-ops.md).
