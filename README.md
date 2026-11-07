# shared-tooling

The lint, test, CI and deploy pieces every jwill89 project shares, held by each project as a git submodule at `shared/`. `PLAN.md` says why it exists and what is decided; this file says what is here and how a project uses it.

Folders are named `<purpose>/<target>`. A project uses only the folders for the stacks it has; the rest sit unused.

| Folder | What it holds | Used by |
| --- | --- | --- |
| [`lint/web`](lint/web/README.md) | `@jwill89/lint-web`: ESLint (Vue, with template accessibility, and a React variant), Prettier, Stylelint, base tsconfigs. Replaces the `eslint-config` submodule. | Every front end |
| [`lint/go`](lint/go/README.md) | The golangci-lint template and `golangci-sync`, which writes each module's `.golangci.yml` from it | Every Go module |
| `lint/php` | `phpstan.neon` (level 8), `php-cs-fixer-rules.php` (PER-CS 3.0), `rector-set.php` (dead code) | The PHP projects |
| `lint/dotnet` | `analyzers.props` and `.globalconfig`: the .NET analyzers and the C# code style, checked in the build | The Dalamud plugins |
| `lint/pwsh` | `PSScriptAnalyzerSettings.psd1`, and `Invoke-ScriptLint.ps1`, which runs it on every tracked script for `task` and CI alike | Every repo with scripts |
| `lint/markdown` | `markdownlint.jsonc` | Every repo |
| [`deploy/pwsh`](deploy/pwsh/README.md) | `SharedDeploy`, the PowerShell module the deploy scripts share: every deploy as one archive and two SSH connections | Every deploy script |
| `test/web` | `vitest.js`: the Vitest settings, on jsdom, with a coverage floor | Every Vue front end |
| `test/a11y` | `@jwill89/test-a11y`: axe checks for Playwright at WCAG 2.2 AA | Every site with a UI |
| `test/e2e` | `playwright.js`: the Playwright settings, run in CI by `e2e.yml` | Every site with a UI: each rollout adds a basic suite |
| `test/go` | `Test-CoverageFloor.ps1`, the floor for a Go coverage profile | Every Go module |
| `test/php` | `coverage-check.php` (the floor for a clover report) and a base `phpunit.xml.dist` | The PHP projects |
| `repo` | `editorconfig` and `gitattributes`, copied in by `Sync-RepoFiles.ps1`; `Taskfile.yml`, the tasks every repo includes; `Update-SharedTooling.ps1` and `Test-SharedVersion.ps1`, which move a project to a release and check it stayed there; `dependabot.example.yml` | Every repo |
| `.github/workflows` | Reusable workflows: `web.yml`, `e2e.yml`, `go.yml`, `php.yml`, `dotnet.yml`, `pwsh.yml`, `docs.yml`, `osv.yml` | Every repo's CI |
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
    desc: Build and deploy to the droplet (pass flags after --)
    cmds:
      - task: shared:deploy
```

And per stack (each folder's README has the detail):

- **Front end:** add `install-links=true` to its tracked `.npmrc`, `npm install -D ../shared/lint/web`, and point `eslint.config.ts`, `prettier.config.js`, `stylelint.config.js` and `tsconfig.app.json` at the package.
- **Go:** `go run -C shared/lint/go . -dir <module>` writes `.golangci.yml`; the module's own rules go in `.golangci.local.yml`.
- **PHP:** `includes: [../shared/lint/php/phpstan.neon]` in `phpstan.neon`; `...require` the php-cs-fixer rules; `->withSets([.../rector-set.php])` in `rector.php`.
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
  ```

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

The release task sets the version in `VERSION`, in `lint/web`'s and `test/a11y`'s `package.json` (so a project's npm always takes the new copy) and in the deploy module's manifest, turns Unreleased into the release's section, commits, and tags. It pushes nothing.

### Taking a release in a project

```bash
task shared:update -- v1.2.0
```

It checks out the tag in `shared/`, then hands over to that release's own copy of the script, which:

- points every shared workflow ref at the tag;
- re-syncs `.editorconfig` and `.gitattributes`, if the project has adopted them;
- rewrites each `.golangci.yml` the template made;
- wherever `@jwill89/lint-web` or `@jwill89/test-a11y` is used, first raises the project's own copy of any of their peers (ESLint, Prettier, Stylelint and TypeScript for `lint/web`, Playwright for `test/a11y`) that falls outside the range the release declares, with `npm install -D <tool>@<range>`;
- then re-installs the packages.

A release that raises a peer's range, as v2.0.0 raises Stylelint to 18, would otherwise leave the project uninstallable: npm refuses the new package beside the old tool. Raised first, the tool only overrides the old package's peer, with an `ERESOLVE overriding peer dependency` warning, until the next install replaces that package. Only a tool the project lists in its own `devDependencies` is raised, and only when the version its lockfile holds is outside the range; one pinned to an exact version stays pinned (`--save-exact`), and the script names each one it raises. A project's own plugin that still needs the old tool (TarotGen.io's `stylelint-config-recommended-scss`, on Stylelint 17) fails that first install until the project drops or replaces it; the CHANGELOG says so for that release.

Review the diff and commit it as one change. `-- v1.2.0 -SkipInstall` leaves npm, the peers included, and the Go configs alone. `task shared:version:check` runs the same check CI does.

A release for one stack moves the submodule for every project that takes it, but a project that doesn't use that folder sees nothing different.

## This repo's own checks

`.github/workflows/ci.yml` runs the same tools on this repo: PSScriptAnalyzer on its scripts, markdownlint on its docs, the sync tool linted by its own template, actionlint on the workflows, and the front-end package's configs loading from its own install.

## License

MIT; see `LICENSE`. It covers this repo only: each project that holds it as a submodule keeps its own license.
