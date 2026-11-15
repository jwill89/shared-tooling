# AGENTS.md

The guide to changing shared-tooling, for agents and developers alike. Read it before any change. The rules every repo follows, this one included, are in [standards/README.md](standards/README.md); [README.md](README.md) says what each folder holds and how a project takes a release, and isn't repeated here.

## What this repo is

The lint, test, CI and deploy pieces a set of projects share, held by each as a submodule at `shared/`, and the standards they follow. Its users are those projects: a task, a workflow input or a module function is what they touch, so a change is weighed by what a project must do to take it. This repo is itself the shared folder, so where a project writes `shared/...`, this repo writes the path from its root (`standards/README.md`, `repo/Taskfile.yml`).

## Conventions

- **Nothing names a project.** The repo is public and every project reads it, so no file holds a project's name, host, IP address, domain or email: not code, examples, comments, tests or the CHANGELOG. Examples are made up (`example`, `example.com`, `/var/www/example.com`, `owner/app`). A project's own details and choices live in its own repo.
- **One version, exact tags.** The whole repo carries the version in `VERSION`, and a project points its submodule and every workflow ref at the same tag, so a release is one tag and there is no moving `v1`. The bump follows what a project must do to take it (CHANGELOG.md's header).
- **The CHANGELOG is written as you go.** Each change a project would notice gets its bullet under `## [Unreleased]` in the same change, written to [What a changelog entry says](standards/docs-and-agents.md#what-a-changelog-entry-says): what changed as the project meets it, naming the task, input, function or file it touches.
- **Comments describe the code.** No comment names a plan, a standards file, a project or a decision, so each still reads true after those move on.
- **One script behind each check.** A shared task and the workflow step that do the same check call the same script (`Invoke-ScriptLint.ps1`, `Sync-RepoFiles.ps1`, `Update-ChangelogLinks.ps1`, `Test-SharedVersion.ps1`, `typecheck-specs.mjs`, `coverage_floor.py`), so a project's `task check` and its CI can't drift apart.
- **Pinned tools.** Each workflow takes its tools' versions as inputs with exact defaults, and the matching task runs the same version, so a release is what moves a tool, on purpose.
- **A rule lives once.** A rule is one bullet in one file of `standards/`, ending with how it is checked, and other files link to it. A rule a tool can check goes into that tool's shared config in the same change.
- **The deploy module holds no host details.** Every host, user, path and port comes from a parameter, filled by the project from its git-ignored deploy config.
- **Remote shell is built, never interpolated.** A remote script is a single-quoted here-string whose values arrive as shell variables, set by `Join-ShellScript` and quoted by `ConvertTo-ShellLiteral`, and every value is validated first (`Assert-RemotePath`, `Assert-UnitPath`, `Assert-SafeRemoteName`, `ValidatePattern`). A path with a space or a quote then stays one value instead of changing the command.
- **Check first, record, then change.** A remote step checks everything it can before anything live changes, writes each change to its rollback record before making it, and puts it all back on failure, so a failed or cut-off deploy leaves the host as it was and a retry resumes cleanly.
- **Files on the host are LF, installed where they differ.** A unit, vhost, cron file or job is made LF-only, compared with the live copy (`cmp`) and installed only if it differs, the previous copy kept, so a deploy that changes nothing restarts nothing it needn't.
- **Scripts fail loudly.** Every script starts `#Requires -Version 7.4` and `$ErrorActionPreference = 'Stop'`, sets `$PSNativeCommandUseErrorActionPreference = $false`, and checks `$LASTEXITCODE` after each native call with a message of its own, which a profile's setting can't then pre-empt.
- **The owner commits.** Work happens on `main` and is left uncommitted; the owner commits, tags and releases.

## Known traps

- **A long command over a shared connection.** `plink -share` ends a command over about 16 KB (`FATAL ERROR: Error 109: The pipe has been ended`) before the host runs any of it. So a remote script travels on plink's standard input under a short fixed command that checks its SHA-256 before running it, `Get-PlinkArgument` refuses a command over 8 KB, and a script may be at most 128 KB, the one argument `$SHELL -c` takes. A streamed transfer's command (`Invoke-PlinkStream`, behind `Invoke-Upload`, `Get-File` and `Sync-LiveFolder`) is plink's command itself, so it stays a few lines, and anything longer is sent as a file first.
- **A remote script has no standard input.** It runs with stdin empty, so nothing in it can swallow the rest of the script; data it needs goes to the host as a file first.
- **CRLF reaching the host.** A file written on Windows carries CRs, and a CR in a cron line, a unit or a vhost name breaks it with no error. Every script is stripped of CRs before it is sent, each host file goes through `tr -d '\r'`, and a vhost's names are read with CRs dropped.
- **Testing droplet shell in Git Bash.** Git Bash drops CRs and has no systemd, so a CRLF bug or a unit that won't start passes there. Replay remote shell in WSL Ubuntu (`wsl.exe -d Ubuntu -u root`, from PowerShell): it has the real systemd, cron and Apache (installed, disabled). A test that touches `/etc/apache2` copies it first and puts it back after.
- **PSScriptAnalyzer crashing cold.** 1.25.0 races with itself on a file the size of `SharedDeploy.psm1` and throws a NullReferenceException in `UseCorrectCasing`. That is not a finding: `Invoke-ScriptLint.ps1` runs the rules apart and retries a crash in a fresh process, so lint through `task shared:lint:scripts`, not a bare `Invoke-ScriptAnalyzer`.
- **A module can't set a script's preferences.** Preference variables and a `trap` don't reach a deploy script from the module, so the script keeps its own `$ErrorActionPreference`, `$PSNativeCommandUseErrorActionPreference` and `trap` lines (deploy/pwsh/README.md, Importing it).
- **The wrong tar.** Git's GNU tar can come first on PATH and reads `C:\...` as a remote host, so local tar is always Windows' own (`Resolve-TarTool`). GNU tar's default format mangles a UTF-8 name when Windows' tar unpacks it, so the host writes pax (`--format=pax`) for anything Windows unpacks. GNU tar's `--exclude`, `--anchored` and the like are positional and go before the files they apply to.
- **npm through cmd.exe.** `npm.cmd` runs through cmd.exe, which drops a `^` and reads `<` and `>` as redirects, so a version range is quoted there; and splatting a lone string hands npm one character per argument, so arguments are always arrays.
- **`ufw limit ssh`.** The host refuses an address after six connections in 30 seconds, so every remote call rides the one held connection: nothing calls plink without `-share`, and nothing starts a second holder.
- **An action with no major tag.** An action that publishes no `vN` tag (uv's setup action) resolves to nothing at `@vN` and stops every run, so it is pinned to an exact release.
- **A package version that doesn't move.** npm refreshes a project's copy of `lint/web` or `test/a11y` only when its `version` changes, so the release task sets both to the release's number; nothing else edits them.
- **A binary in the repo.** `*.exe` and build output are ignored, since a Windows build once shipped inside `lint/go`; the sync tool runs with `go run`.
- **systemd's start limit.** Failed restarts can use it up, and systemd then refuses the rollback's restart and leaves the service down, so every restart in a rollback runs `systemctl reset-failed` first.
- **CodeQL's default setup.** Code scanning refuses an advanced setup's results beside the default one, so a repo calling `codeql.yml` turns the default setup off.
- **A packaged app's AppData.** A process started from a packaged Windows app (a terminal inside one, an agent's shell) writes to its own copy of AppData, which a scheduled task never sees, so `runner/` keeps its state in `%USERPROFILE%\.ci-runner`.
- **A pipe from PowerShell into `wsl.exe`.** Each line arrives with a CR after it, so whatever reads it in the distro drops CRs first (`tr -d '\r'`, or the runner image's `${jitconfig%$'\r'}`).
- **A tar on `docker build`'s standard input.** It tells a tar from a Dockerfile by the first 1 KB, which a pax tar, .NET's default, fills with an extended header, so the tar is read as a Dockerfile; `runner/` writes ustar.
- **`wsl.exe --` goes through a shell.** It hands the rest of the line to the distro's shell, which re-splits and expands it; `--exec` passes each argument as it is, so `runner/` always uses `--exec`.
- **`task shared:update` hands over.** The script checks out the new tag, then runs that release's own copy for the rest, so a change to what the update does reaches a project when it moves to the release that has the change, run by that release's code.
- **A file a project's Prettier checks.** A JSON or JSONC file the tooling writes into a project (`tsconfig.vitest.json`) is written as Prettier writes it, short arrays on one line, or the project's format check fails.

## Recipes

### A rule

1. Find the area's file in `standards/` (the table in [standards/README.md](standards/README.md)), and write the rule as one bullet there: plain, specific, and ending with how it is checked (`[lint: tool rule]`, `[CI]`, `[module]`, `[test]`, `[axe]` or `[review]`).
2. Link to it from anywhere else that needs it rather than repeating it.
3. If a tool can check it, add it to the tool's shared config in this change, and mark the rule with the tool.
4. A new file in `standards/` gets its row in the README's table.
5. Note it under Unreleased (Added, or Changed for a rule that moves), then run `task check`.

### A workflow

1. Add `.github/workflows/<name>.yml` with `on: workflow_call`, each input described and defaulted, and its tools' versions as inputs.
2. Head it with a comment saying what it runs and the call, `uses: jwill89/shared-tooling/.github/workflows/<name>.yml@v1.0.0`.
3. Give it `permissions: contents: read`, and more only on the job that needs it; check out with `persist-credentials: false`.
4. Pin each action to a tag that exists (`actions/checkout@v7`), or to an exact release where the action has no major tag.
5. Run each check through the script a shared task runs, adding that task to `repo/Taskfile.yml` in the same change.
6. Where this repo can run it on itself, call it from `ci.yml` by its local path.
7. Add it to the README's list of workflows and the CI example where projects call it, note it under Unreleased, and run `task check` (actionlint).

### A deploy-module function

1. Write it in `deploy/pwsh/SharedDeploy.psm1`, in the region it belongs to, with an approved verb; a helper it alone needs goes under Private helpers and is not exported.
2. Give it full comment-based help: a one-line synopsis, a description of what happens in order and what is left as it was when it fails, every parameter, and an example with made-up paths.
3. Validate every value bound for the host, and pass each as a variable through `Join-ShellScript`, never inside the shell text.
4. A remote step offers `-AsScript` (and `-AsStep` for a step of `Invoke-DeployBundle` or a swap's hook), `-Connection` and `-NoRetry`, prints its host output indented, and throws saying what was left.
5. Export it twice: `FunctionsToExport` in `SharedDeploy.psd1` and `Export-ModuleMember` at the foot of the `.psm1`.
6. Add its line under Functions in [deploy/pwsh/README.md](deploy/pwsh/README.md), and an example under More shapes for a new shape; a rule it carries out goes in `standards/deploy-and-ops.md`, marked `[module]`.
7. Test it: write its `-AsScript` output to files and replay them as root in WSL, failure and retry paths included; drive the PowerShell side with the module's remote calls swapped, inside the module's scope, for ones that run the same shell in WSL; then PSScriptAnalyzer.
8. Note it under Unreleased.

### A lint config

1. Put the file under `lint/<target>/`.
2. For `lint/web`: add it to `package.json`'s `exports` and `files`, with type declarations where a TypeScript config imports it; a new dependency goes under `dependencies` unless the project must hold its own copy (a peer); run `npm install` in `lint/web` so the lockfile follows; add a load check to `scripts/test-presets.mjs` and a row to [lint/web/README.md](lint/web/README.md).
3. For another stack: say how a project points at it under "Adding it to a project" in the README, and load it in this repo's `task lint`, as `lint:python` loads `ruff.toml`.
4. Note it under Unreleased: a new rule is a minor release, since it can raise findings in a project.

### Testing a change

- A script under `repo/` runs on a scratch copy, never on a real project: a throwaway git repo with a made-up origin and tags for `Update-ChangelogLinks.ps1`, a scratch front end with its own `npm install` for `typecheck-specs.mjs`, a scratch folder for `Sync-RepoFiles.ps1`.
- Changed remote shell is replayed in WSL, as above.
- Then one full `task check`, logged to a file, and the failures read from it.

### A release

1. Everything the release changes is noted under Unreleased, `task check` passes, and changed remote shell has been replayed in WSL.
2. The owner commits on a clean `main`, then runs `task release -- X.Y.Z`. It refuses a dirty tree, another branch, a tag that exists, a version not above the current one, or an empty Unreleased; otherwise it sets the version in `VERSION`, in `lint/web`'s and `test/a11y`'s `package.json` and lockfiles and in the module's manifest, turns Unreleased into the release's dated section with its compare links, commits, and tags.
3. The owner pushes both by name: `git push origin main vX.Y.Z`.
4. Each project takes it when it's ready, with `task shared:update -- vX.Y.Z`.

## Departures from the standards

- `ci.yml` calls the shared workflows by their local path, not by a release's tag: it checks the workflows as they are on `main`, before any release carries them to a project (docs-and-agents.md, Working in a repo).

## Not yet meeting the standards

- Since 2026-11-14: the PowerShell scripts and the deploy module have no automated tests; each release replays its changed remote shell in WSL by hand (testing.md, Every stack).
- Since 2026-11-14: the root Taskfile has no `task test` (docs-and-agents.md, Working in a repo).
