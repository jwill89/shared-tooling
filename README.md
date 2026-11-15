# shared-tooling

The lint, test, CI and deploy pieces a set of projects share, held by each project as a git submodule at `shared/`, and the standards they follow. This file says what is here and how a project uses it.

Folders are named `<purpose>/<target>`. A project uses only the folders for the stacks it has; the rest sit unused.

| Folder | What it holds | Used by |
| --- | --- | --- |
| [`lint/web`](lint/web/README.md) | `@jwill89/lint-web`: ESLint (Vue, with template accessibility, and React and plain-JavaScript variants), Prettier, Stylelint, base tsconfigs (the app, the Node side, the Vitest specs). Replaces the `eslint-config` submodule. | Every front end |
| [`lint/go`](lint/go/README.md) | The golangci-lint template and `golangci-sync`, which writes each module's `.golangci.yml` from it | Every Go module |
| `lint/php` | `phpstan.neon` (level 8), `php-cs-fixer-rules.php` (PER-CS 3.0), `rector-set.php` (dead code) | The PHP projects |
| `lint/python` | `ruff.toml`: the ruff rules and formatter settings a project's `pyproject.toml` extends | Every Python project |
| `lint/dotnet` | `analyzers.props` and `.globalconfig`: the .NET analyzers and the C# code style, checked in the build | Every C# project |
| `lint/pwsh` | `PSScriptAnalyzerSettings.psd1`, and `Invoke-ScriptLint.ps1`, which runs it on every tracked script for `task` and CI alike | Every repo with scripts |
| `lint/markdown` | `markdownlint.jsonc` | Every repo |
| [`deploy/pwsh`](deploy/pwsh/README.md) | `SharedDeploy`, the PowerShell module the deploy scripts share: every deploy as one archive and two SSH connections | Every deploy script |
| `test/web` | `vitest.js`: the Vitest settings, on jsdom, with a coverage floor; `typecheck-specs.mjs`, which checks the specs' `tsconfig.vitest.json` and type-checks them, for `web.yml` and `task shared:web:specs` alike, or with `--fix` writes the file or adds the base to it | Every Vue or React front end |
| `test/a11y` | `@jwill89/test-a11y`: axe checks for Playwright at WCAG 2.2 AA | Every site with a UI |
| `test/e2e` | `playwright.js`: the Playwright settings, run in CI by `e2e.yml` | Every site with a UI: each rollout adds a basic suite |
| `test/go` | `Test-CoverageFloor.ps1`, the floor for a Go coverage profile, and `Invoke-GoCoverage.ps1`, which runs the tests and holds that floor locally (`task shared:go:coverage`) | Every Go module |
| `test/php` | `coverage-check.php` (the floor for a clover report) and a base `phpunit.xml.dist` | The PHP projects |
| `test/python` | `coverage_floor.py`, which fails a run whose `pyproject.toml` sets no coverage floor or package, for `python.yml` and `task shared:python:test` alike | Every Python project |
| `repo` | `editorconfig` and `gitattributes`, copied in by `Sync-RepoFiles.ps1`, which also holds `CLAUDE.md` to its standard form; `Taskfile.yml`, the tasks every repo includes; `Update-SharedTooling.ps1` and `Test-SharedVersion.ps1`, which move a project to a release and check it stayed there; `Update-ChangelogLinks.ps1`, which writes and checks the CHANGELOG's compare links; `dependabot.example.yml` | Every repo |
| [`runner`](runner/README.md) | Self-hosted Actions runners on a Windows machine: `CiRunner.psm1` runs the scaler (`scaler/`), which starts a fresh container (`Dockerfile`) for each job GitHub assigns a repo, side by side up to a limit, in a WSL distro of its own (`setup-host.sh`) | The repos whose `CI_RUNNER` variable is set |
| `.github/workflows` | Reusable workflows: `web.yml`, `e2e.yml`, `go.yml`, `php.yml`, `python.yml`, `dotnet.yml`, `pwsh.yml`, `docs.yml`, `osv.yml`, and `codeql.yml` for a public repo | Every repo's CI |
| [`standards`](standards/README.md) | The rules every project follows, by area, each marked with how it is checked; `README.md` is the index | Every repo's `CLAUDE.md` imports `@shared/standards/README.md` |

## Adding it to a project

```bash
git submodule add https://github.com/jwill89/shared-tooling.git shared
git -C shared checkout v1.0.0
```

Then include the shared tasks from the project's `Taskfile.yml`, so every repo runs the same commands (`task shared:lint:scripts`, `task shared:repo:check`, and so on) and its own `deploy`, `lint`, `test` and `check` can call them:

```yaml
includes:
  shared: ./shared/repo/Taskfile.yml

tasks:
  deploy:
    desc: Build and deploy to the host (pass flags after --)
    cmds:
      - task: shared:deploy
```

`task deploy` always deploys everything the project has, in order: the backend, then the front end, then a Dalamud plugin, which it publishes only when its version is new. A project whose parts ship separately adds one task per part for deploying it alone, and no `deploy:both` or `deploy:all` (`standards/deploy-and-ops.md`):

```yaml
  deploy:
    desc: Deploy everything - the backend, then the frontend, then the plugin if its version is new
    cmds:
      - pwsh -NoProfile -File scripts/deploy.ps1 -Target main {{.CLI_ARGS}}
      - pwsh -NoProfile -File scripts/deploy.ps1 -Target plugin -IfNewer {{.CLI_ARGS}}
  deploy:backend:   # and deploy:frontend, deploy:plugin, each running one -Target
```

The project's `task check` runs everything CI runs, so a green check means a green CI. That includes every coverage floor CI holds and every generated-file check, with the same numbers its workflow calls pass. Start from this and keep the lines for the stacks the project has:

```yaml
  check:
    desc: Everything CI runs
    cmds:
      - task: lint                # the project's own: ESLint, vue-tsc, golangci-lint, PHPStan, ruff and the rest
      - task: shared:docs:check   # all docs.yml checks: Markdown, repo files and CLAUDE.md, workflow refs, CHANGELOG links
      - task: shared:web:specs    # the specs' tsconfig.vitest.json and type-check, as web.yml runs them
        vars: { DIR: web }
      - task: test:coverage       # the project's own: Vitest with its floor, PHPUnit with coverage-check.php
      - task: shared:go:coverage  # each Go module, with its go.yml call's coverage-floor and coverage-exclude
        vars: { DIR: backend, FLOOR: 62.5, EXCLUDE: /internal/db/ }
      - task: shared:python:test  # pytest, held to the floor in pyproject.toml
      - task: generate:check      # the project's own: the committed OpenAPI spec and API types match the code
      - task: shared:vuln
```

A Go-only bot keeps `lint`, `shared:docs:check`, its `shared:go:coverage` lines and `shared:vuln`; a PHP site keeps `lint`, `shared:docs:check`, `test:coverage` and `shared:vuln`. A repo with a second CHANGELOG passes it, as its `docs.yml` call does: `vars: { CHANGELOGS: CHANGELOG.md plugin/CHANGELOG.md }`.

It is a fragment to copy, with one shared task inside it, rather than a single `shared:check`, because only part of it is the same in every repo. That part is `shared:docs:check`, which runs what `docs.yml` runs, so a check `docs.yml` gains arrives with the release, with no edit to any Taskfile. The rest, each floor, front-end folder and generated file, is the project's own and already written in its workflow calls; a shared task would have to be handed all of them anyway, one step further from the numbers they must equal.

And per stack (each folder's README has the detail):

- **Front end:** add `install-links=true` to its tracked `.npmrc`, `npm install -D ../shared/lint/web`, and point `eslint.config.ts`, `prettier.config.js`, `stylelint.config.js` and `tsconfig.app.json` at the package. An app with Vitest specs adds a `tsconfig.vitest.json` that extends its `tsconfig.app.json` (or its lone `tsconfig.json`) and then `@jwill89/lint-web/tsconfig.vitest.json`, which `web.yml` checks; `task shared:web:specs -- --fix` writes it.
- **Static site:** add `install-links=true` to its tracked `.npmrc`, `npm install -D ../shared/lint/web eslint prettier`, point `eslint.config.js` at `@jwill89/lint-web/js` and `prettier.config.js` at `@jwill89/lint-web/prettier`. A site whose `jsconfig.json` sets `checkJs` may add typescript-eslint's type-checked rules from the package's `tseslint` export ([lint/web/README.md](lint/web/README.md#use-it-in-a-project)).
- **Go:** `go run -C shared/lint/go . -dir <module>` writes `.golangci.yml`; the module's own rules go in `.golangci.local.yml`.
- **PHP:** `includes: [../shared/lint/php/phpstan.neon]` in `phpstan.neon`; `...require` the php-cs-fixer rules; `->withSets([.../rector-set.php])` in `rector.php`.
- **Python:** `[tool.ruff] extend = "shared/lint/python/ruff.toml"` in `pyproject.toml`, with the project's own ignores after it (per-file ones under `extend-per-file-ignores`); `[tool.mypy]` naming the packages, tests included; `[tool.coverage.run] source` and `[tool.coverage.report] fail_under`. The exact Python goes in `.python-version`, and `requirements.txt` and `requirements-dev.txt` are compiled from `.in` files with `uv pip compile --universal --python-version <minor> --generate-hashes` (`standards/packages.md`). `task shared:python:setup` makes `.venv`, and the project's `lint`, `test` and `check` call `shared:python:lint` and `shared:python:test`; CI calls `python.yml`, and `dependabot.yml` takes the `uv` block. Python scripts in a project that isn't a Python project take only the Dependabot block (`uv`, or `pip` for a plain pinned file) and OSV's scan of their requirements: no ruff, mypy or pytest (`standards/packages.md`).
- **C#:** `<Import Project="$(MSBuildThisFileDirectory)..\shared\lint\dotnet\analyzers.props" />` in the plugins' `Directory.Build.props`.
- **PowerShell:** `-Settings shared/lint/pwsh/PSScriptAnalyzerSettings.psd1`; deploy scripts `Import-Module` `shared/deploy/pwsh/SharedDeploy.psd1`.
- **Markdown:** `.markdownlint-cli2.jsonc` with `"config": { "extends": "shared/lint/markdown/markdownlint.jsonc" }` and `shared/**` in its ignores, plus `<dir>/test-results/**` where an end-to-end suite runs, since a failed run leaves Playwright's notes there as Markdown.
- **Repo files:** put the project marker at the end of `.editorconfig` and `.gitattributes`, move the project's own lines below it, then `pwsh shared/repo/Sync-RepoFiles.ps1`.
- **CI:** call the workflows by name, pinned to the exact release the submodule holds, plus the project's own jobs:

  ```yaml
  jobs:
    web:
      uses: jwill89/shared-tooling/.github/workflows/web.yml@v1.0.0
      with:
        dir: web
        fontawesome: true
        artifact-path: web/dist
      secrets:
        FONTAWESOME_TOKEN: ${{ secrets.FONTAWESOME_NPM_TOKEN }}
    go:
      needs: web
      uses: jwill89/shared-tooling/.github/workflows/go.yml@v1.0.0
      with:
        download-artifact: web-dist
    scripts:
      uses: jwill89/shared-tooling/.github/workflows/pwsh.yml@v1.0.0
    docs:
      uses: jwill89/shared-tooling/.github/workflows/docs.yml@v1.0.0
    osv:
      uses: jwill89/shared-tooling/.github/workflows/osv.yml@v1.0.0
  ```

- **CodeQL, in a public repo:** call `codeql.yml` with the languages the repo has, and turn CodeQL's default setup off in the repo's settings (Code security), since code scanning refuses an advanced setup's results beside it. CodeQL is free on a public repo; a private one would need GitHub's paid Code Security. Every language but Go is read without a build; Go is built, so a binary that embeds the front end's build waits for `web` and downloads its artifact, as `go.yml` does:

  ```yaml
    codeql:
      needs: web
      uses: jwill89/shared-tooling/.github/workflows/codeql.yml@v1.0.0
      with:
        languages: '["javascript-typescript", "python", "go", "csharp", "actions"]'
        go-version-file: go.mod
        download-artifact: web-dist
      permissions:
        contents: read
        actions: read
        security-events: write
  ```

- **Self-hosted runners:** every shared workflow runs its jobs on the runners the repo's `CI_RUNNER` variable names, and on GitHub's `ubuntu-24.04` while it is unset or for a pull request from a fork. With a machine's runners set up ([runner/README.md](runner/README.md)) and started with `task shared:runner:start`, `gh variable set CI_RUNNER --body wsl` moves the repo's jobs there, and its own jobs take the same line, `runs-on: ${{ github.event.pull_request.head.repo.fork && 'ubuntu-24.04' || vars.CI_RUNNER || 'ubuntu-24.04' }}`; `gh variable delete CI_RUNNER` sends them back. A public repo first requires approval for outside contributors' workflow runs, since a fork's pull request runs its own copy of the workflows (runner/README.md, Setting it up).
- **CHANGELOG:** `task shared:changelog:links` writes the compare link under each version heading, in the change that adds the version's section; `docs.yml` fails on a heading without one. A repo with a second part versioned apart passes `docs.yml` both files (`changelogs: CHANGELOG.md plugin/CHANGELOG.md`) and writes the second's links with `-- -Path plugin/CHANGELOG.md -TagPrefix plugin-v` (`standards/docs-and-agents.md`).
- **Vulnerabilities:** copy `repo/osv-scanner.example.toml` beside each npm lockfile as `osv-scanner.toml`, keeping only the advisories that lockfile has, and add `task shared:vuln` to the project's `task check`.
- **Pushing:** add `push: { interactive: true, cmds: [task: shared:push] }`, so `task push` takes the in-range updates Dependabot would open (`task shared:deps` lists them, `task shared:deps:update` takes them), starts the self-hosted runners when the repo's CI uses them, pushes, and follows the CI run to its verdict; CI does the checking. Majors are only listed, for Dependabot to open one by one.

A fresh clone needs `git submodule update --init` once (or `git clone --recurse-submodules`). The repo is public, so CI fetches it with the default token.

## Versions

The whole repo carries one version, in `VERSION`, and every release is an exact tag (`v1.2.0`). A project points both of its uses of shared-tooling at the same tag: the submodule (the configs and scripts in `shared/`) and every `uses: jwill89/shared-tooling/...@v1.2.0` in its workflows (what GitHub runs). If the two named different releases, CI would run one release's workflow against another's scripts, so the shared `docs.yml` workflow fails when they differ. There is no moving `v1` tag: each project takes a release on purpose, when it's ready.

What the numbers mean (CHANGELOG.md says it too):

- **Major:** a project has to change its own files to take it.
- **Minor:** new rules, tasks or features; a new lint rule can raise findings when a project takes it.
- **Patch:** fixes that change nothing a project relies on.

### Making a release

Note the change under `## [Unreleased]` in CHANGELOG.md as you make it. Then, on a clean `main`:

```bash
task release -- 1.2.0
git push origin main v1.2.0
```

The release task sets the version in `VERSION`, in `lint/web`'s and `test/a11y`'s `package.json` (so a project's npm always takes the new copy) and in the deploy module's manifest, turns Unreleased into the release's section, writes its compare link, commits, and tags. It pushes nothing.

### Taking a release in a project

```bash
task shared:update -- v1.2.0
```

It checks out the tag in `shared/`, then hands over to that release's own copy of the script, which:

- points every shared workflow ref at the tag;
- re-syncs `.editorconfig` and `.gitattributes`, if the project has adopted them, writes `CLAUDE.md` where it is missing, and names one that isn't in the standard form;
- rewrites each `.golangci.yml` the template made;
- wherever `@jwill89/lint-web` or `@jwill89/test-a11y` is used, first raises the project's own copy of any of their peers (ESLint, Prettier, Stylelint and TypeScript for `lint/web`, Playwright for `test/a11y`) that falls outside the range the release declares, with `npm install -D <tool>@<range>`;
- then re-installs the packages;
- in each front end with Vitest specs, writes `tsconfig.vitest.json` where it is missing, or adds the shared base to an `extends` that lacks it, and names what it leaves for you, as `web.yml` would fail on it.

A release that raises a peer's range, as v2.0.0 raises Stylelint to 18, would otherwise leave the project uninstallable: npm refuses the new package beside the old tool. Raised first, the tool only overrides the old package's peer, with an `ERESOLVE overriding peer dependency` warning, until the next install replaces that package. Only a tool the project lists in its own `devDependencies` is raised, and only when the version its lockfile holds is outside the range; one pinned to an exact version stays pinned (`--save-exact`), and the script names each one it raises. A project's own plugin that still needs the old tool (a Stylelint plugin with no release for the new major) fails that first install until the project drops or replaces it.

Review the diff and commit it as one change. `-- v1.2.0 -SkipInstall` leaves npm, the peers included, and the Go configs alone. `task shared:version:check` runs the same check CI does.

A release for one stack moves the submodule for every project that takes it, but a project that doesn't use that folder sees nothing different.

## This repo's own checks

`AGENTS.md` is the guide to changing this repo: its conventions, the traps, and the steps for a new rule, workflow, deploy function or lint config, and for a release.

`.github/workflows/ci.yml` runs the same tools on this repo, and `task check` runs them all locally: PSScriptAnalyzer on its scripts, what `docs.yml` checks (markdownlint on its docs, the repo files and `CLAUDE.md`, the workflow refs with `-Shared .`, since this repo is its own shared folder, and the CHANGELOG's compare links), the sync tool linted by its own template and checked by govulncheck, the shared ruff config loading on `test/python`'s script (ruff and mypy at pinned versions through `uvx`, so uv must be installed), actionlint on the workflows, every `lint/web` config and `test/*` preset loading from its own install (`task presets`), and OSV-Scanner over its lockfiles. CI also runs CodeQL over its JavaScript, Python, Go and workflows through `codeql.yml`, which has no local counterpart, since it reports to GitHub's code scanning. `task setup` installs what those loads need, and `task push` takes the in-range dependency updates, pushes and follows CI, as it does in a project.

## License

MIT; see `LICENSE`. It covers this repo only: each project that holds it as a submodule keeps its own license.
