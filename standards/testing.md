# Testing

What every project tests, how it tests it, and where each stack keeps and runs its tests.

## Layout

| Stack | Tests live in | Runner and shared setup | CI |
| --- | --- | --- | --- |
| Vue or React, and TypeScript | `src/__tests__/`, named `*.spec.ts` (`*.spec.tsx` for a React component) | Vitest, configured inside `vite.config.ts` with `test/web`'s `vitestDefaults` | `web.yml` |
| Go | Beside the code, named `*_test.go` | `go test` | `go.yml` |
| PHP | `tests/`, in the suites the project's `phpunit.xml` names | PHPUnit or Pest, on a copy of `test/php/phpunit.xml.dist` | `php.yml` |
| End-to-end | `e2e/` | Playwright, with `test/e2e`'s `playwrightDefaults` and axe from `test/a11y` | `e2e.yml` |
| C# (Dalamud plugins) | A test project beside the plugin | xUnit v3 | `dotnet.yml` |

- `task test` runs every suite in the repo, and `task check` runs them with the rest of what CI runs (see [docs-and-agents.md](docs-and-agents.md)). [CI]
- `task check` starts the steps that don't depend on each other at once, with `task --parallel --output prefixed` (lint, the vulnerability checks and the unit tests, typically), so each line names its step; the steps that need them (the build, the end-to-end suite, a generated-code diff) follow in order. CI runs the same steps as separate jobs already. [review]
- A task that two of those parallel steps depend on and that writes files (a frontend build both lint and the tests need, say) has `run: once`, so the second step waits for the first's run instead of starting its own over the same output folder. [review]
- An end-to-end suite that starts its own server first checks that nothing already answers on its port, and stops with that message if something does: a server left from another run would otherwise answer the tests with its own data and sessions. It also fails setup when its server doesn't come up, and keeps the server's output in a log file. [review]

## Every stack

- Every change ships with its tests, small features included. [review]
- Every bug fix lands with a test that fails without it: write the test first and watch it fail. [review]
- Each project's coverage floor sits a little under its current numbers, and CI fails below it: `test/web` sets Vitest's thresholds, `test/php/coverage-check.php` reads PHPUnit's report (pcov in CI), and `go.yml` runs `test/go/Test-CoverageFloor.ps1`. [CI]
- `task check` holds the same floors locally, with the same numbers CI passes: Vitest's run with coverage, PHPUnit with coverage and `coverage-check.php`, and `task shared:go:coverage` for each Go module (`DIR=backend FLOOR=62.5 EXCLUDE=... COVERPKG=...`, as its `go.yml` call has them). [review]
- A floor only rises: when a change drops coverage under it, add tests, never lower the floor. [review]
- Sign-in and passkeys, permissions, migrations, imports, and deploy and rollback hold a higher bar than the floor, since mistakes there cost most. [review]
- Generated code (sqlc, OpenAPI types) and startup wiring stay out of the coverage count. [review]
- Tests run through real HTTP handlers on a real SQLite database built from the committed schema or the real migrations, in memory or in a scratch file, not through mocks. [review]
- Status codes, error bodies, auth and anything that crosses layers are tested over HTTP. [review]
- Tests exercise the real code, never a copy of it written inside the spec. [review]
- Failure paths use real errors: a real SQLite UNIQUE violation, not a hand-built one. [review]
- Whatever the code relies on the driver for (pragmas, `BEGIN IMMEDIATE`, cancellation, a `DATETIME` timestamp reading back into a `time.Time` in the stored form, a `DATE` round-tripping through the `Date` type) is tested against the real driver. [test]
- Fake only what leaves the app (outside APIs, mail, identity providers, subprocesses such as ffmpeg), and swap the fake in before the first request. [review]
- A crypto flow such as WebAuthn runs as a full ceremony through the real verifier, answered by a fake authenticator that holds a real key. [test]
- Each HTTP test starts clean: a fresh database, a blank environment, an empty session store, and its own client address so rate limiters don't collide. [test]
- Sign-in tests use a test browser that keeps only the cookies the server set. [test]
- Every new or changed endpoint gets HTTP tests for its success path, its 400s, 401, 403 and 404, ownership (one user can't read, change or delete another's data), and what lands in the database. [review]
- HTTP tests check each response against the committed OpenAPI spec, and a front-end spec checks that every API path it calls exists there (see [api-and-realtime.md](api-and-realtime.md)). [test]
- A list of values kept in more than one place (an enum copied into a plugin, setting names, the front end's option lists) is held together by a test that fails when the copies differ. [test]
- Tests give the same result in any time zone and across a clock change: Vitest pins `TZ=UTC`, a helper pins a fixed-offset zone when a test's window crosses a DST change, and backend suites that handle dates also run under a non-UTC zone. [test]
- Every new setting gets a default, a validation check, and a test that a bad value is refused. [test]
- A cached response gets a test that writes, then reads, and expects the fresh data. [test]
- A new gate is proven by planting a violation and watching it fail. [review]
- Passing checks are necessary, not sufficient: run the app on a throwaway database and use the changed behaviour, reading the result from the page, not the console. [review]
- A mechanical refactor is done by script and checked by script: method bodies byte-identical, spec paths and schemas unchanged. [review]
- A CSS refactor is checked with a computed-style walk over every route, signed in and out, before and after. [review]

## Vitest (Vue, React and TypeScript)

- Specs live in `src/__tests__/`, named `*.spec.ts`. [review]
- The Vitest config lives inside `vite.config.ts`, as `test: vitestDefaults({ ... })` from the shared `test/web` preset, and adds only the include, the floor and a setup file. [review]
- The preset sets jsdom, puts mocks and stubbed globals back after each test, and measures v8 coverage over all of `src`, so a project doesn't restate any of that. [CI]
- Tests that need a DOM run on jsdom, the preset's default; a suite with no DOM test passes `environment: 'node'`. [review]
- The setup file stands in only for browser APIs jsdom lacks. [review]
- A React app's specs use the same preset and the same rules; only the mounting library differs. [review]
- Specs import `describe`, `it`, `expect` and `vi` from `vitest` (`globals: false`) and type-check under their own `tsconfig.vitest.json`, so app code stays free of Node types. [CI]
- That file lists the app's own config first and `lint/web`'s base after it, which adds Node's types and takes in the specs the app config leaves out: `"extends": ["./tsconfig.app.json", "@jwill89/lint-web/tsconfig.vitest.json"]`. `web.yml` fails an app with Vitest specs that has no such file, or one that leaves a spec out, then type-checks the specs with it (vue-tsc where the app has it, else tsc); `task shared:web:specs` runs the same locally. [CI]
- Component and view specs mount with `@vue/test-utils` and fake the server at one seam: a stubbed `fetch`, a mocked `useApi`, or a `stubApi` that fails the test on any call it didn't declare. [review]
- Module-level state is reset in `beforeEach`. [review]
- Every new composable, component and view gets a spec that covers the states and error paths a user can reach, not only the happy path. [review]
- An interactive component is driven the way a user drives it. [review]
- A component spec runs axe on what the component renders (see [accessibility.md](accessibility.md)). [axe]
- Where jsdom can't compute a CSS behaviour, such as container-query units, the spec asserts the stylesheet source instead. [test]

## Go

- CI runs `go test -race -shuffle=on ./...` with a coverage profile and the floor, through `go.yml`. [CI]
- Locally `go test ./...` is enough, since the race detector needs gcc. [review]
- Decisions ("what should happen") live in pure functions, apart from the code that carries them out, so they test without the outside service; test them table-driven. [review]
- Tests that need a migrated database copy one that a shared test package migrates once per test binary; only the database package's own tests migrate step by step. [review]

## PHP

- PHPUnit, and Pest, which reads the same file, fail on any warning, deprecation or notice, PHPUnit's own included, as `test/php/phpunit.xml.dist` sets. [CI]
- A project copies that file to its `phpunit.xml` and sets only its suites and `<source>`, since PHPUnit can't extend another config. [review]
- `#[CoversClass]` lists every class a test really checks, since coverage is credited only to listed classes; a trait is listed with `#[CoversTrait]`. [review]

## End-to-end (Playwright)

- Each site's basic suite opens every main page by its address and checks that it shows its data. [test]
- Every main page passes axe at WCAG 2.2 AA, the floor under the AAA target (`axeViolations` from `test/a11y`), with no page error and no CSP refusal; [accessibility.md](accessibility.md) says how AAA is checked. [axe]
- One more spec runs the key user flow. [review]
- CI runs the suite through `e2e.yml`, after the backend and front-end jobs pass (the caller's `needs:`). [CI]
- Specs find elements by role and label (`getByRole`, `getByLabel`), never by a Bulma, PrimeVue or Tailwind class, so they still pass when an app swaps in the component kit. [review]
- The suite runs the real built app (the real binary, or PHP served through the production routing so pages get the real CSP) on a throwaway database in the OS temp folder, built by the migrations and seeded. [CI]
- The prepare script refuses any database path inside the checkout. [test]
- Anything that leaves the app, such as mail or an outside API, is dry-run. [review]
- The Playwright config spreads `test/e2e`'s `playwrightDefaults`: tests in `e2e/`, one worker in order, one retry in CI, a trace kept on failure, and the browser already installed (Edge locally on Windows, the runner's Chrome in CI). The one worker is because a suite's steps share one server and one database, so it holds locally too. [CI]
- A suite is checked for flakiness with `--repeat-each=5`, and every step tolerates the extra data a retry leaves behind. [review]
- A change to the key user flow updates its end-to-end spec in the same change. [review]

## C# (Dalamud plugins)

- Everything that doesn't touch the game lives in `Core/`, compiled into a test project with no Dalamud. [CI]
- The plugin's windows are drawn to pictures without the game, by a preview project that renders each one with stand-in data, and looked at before handover; CI builds that preview. [CI]
- CI builds the Windows-targeted plugin on Linux, through `dotnet.yml`. [CI]

## After a deploy

- The shared deploy module's smoke step fetches each listed URL after a deploy and rolls back on failure (see [deploy-and-ops.md](deploy-and-ops.md)). [module]
