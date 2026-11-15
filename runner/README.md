# Self-hosted runners

Runs the repos' CI on a Windows machine instead of GitHub's runners, so it costs no Actions minutes. Each job runs in a fresh container, like a GitHub-hosted job, inside a WSL distro kept for the runners alone. A container starts when GitHub assigns a job and is removed when the job ends, so the jobs of a run go side by side and nothing waits between runs but one small process.

## How it fits together

- **The distro** (`ci-runner`, Ubuntu 24.04) runs Docker Engine and nothing else. `setup-host.sh` turns off its Windows drives and Windows programs, so a job's packages can't reach either.
- **The job image** (`Dockerfile`) is Ubuntu 24.04 like GitHub's `ubuntu-24.04`, with what the shared workflows expect to find (PowerShell, Chrome, the GitHub CLI, Docker's command line, PHP, zstd, passwordless sudo) and the Actions runner. The other tools come from the setup actions, as on GitHub.
- **The scaler** (`scaler/`, a Go program on GitHub's [runner scale set client](https://github.com/actions/scaleset)) gives each repo a runner scale set named by the config's `Name`, which is the label a job's `runs-on` names. It holds a long poll open on each set; when GitHub assigns a set jobs, it starts a single-use runner per job in a container of the job image, and removes the container once the runner has taken its job and exited. It runs in a container of its own, talking to Docker through its socket.
- **The limits.** At most `MaxJobs` jobs run at once across all the repos, and the rest wait in GitHub's queue. Every job's container runs in one systemd slice, `ci.slice`, which caps the CPU and memory the running jobs share, however many there are. Each poll tells GitHub how many more jobs the machine takes, so it assigns no more than that.
- **The loop** (`Start-CiRunner`, run hidden by the "CI runners" task) sets the limits, builds both images, runs the scaler with `gh`'s token, and starts it again if it stops. Every six hours it rebuilds the job image when the runner has a new release, since GitHub stops sending jobs to a runner that falls too far behind. The scaler names the image `ci-runner:current`, which each build moves to the newest, so new jobs take it at once; a change to `scaler/` restarts the scaler.
- **On demand.** Nothing starts the runners on its own. `task shared:runner:start`, in any repo, starts them, and `task shared:runner:stop` stops them and shuts the distro down, so WSL's VM gives its memory back while you aren't working. Both go through the module the task was installed from (`Invoke-CiRunner.ps1`), so every repo drives the same runners whatever release it is on.
- **A personal account's runners serve one repo,** so each repo has a scale set of its own.
- **Docker for a job, by repo.** A job container has no Docker, unless its repo is one of the config's `DockerRepos`: then it gets the distro's Docker socket, and a work folder under `/var/lib/ci-work` at the same path in the distro, so a path the job hands `docker run -v` means the same to Docker. That lets the job control every container in the distro, and through WSL's VM reach your other distros, so it is for repos whose code you would build on this machine anyway.
- **Windows jobs.** A repo in the config's `WindowsRepos` also gets a scale set named `<Name>-windows`, served by a second copy of the scaler built for Windows (with this machine's Go). For each job it copies the runner's Windows release (kept in `%USERPROFILE%\.ci-runner\windows`) to a folder of its own and runs it as a process, as you, with Go's caches and the tool cache of its own; up to `WindowsMaxJobs` (1) at once. The job uses what is installed on this machine (Go's C compiler, Inno Setup), and can reach whatever you can, so it too is for your own repos. A workflow sends a job there with `runs-on: ${{ !github.event.pull_request.head.repo.fork && vars.CI_RUNNER && format('{0}-windows', vars.CI_RUNNER) || 'windows-2025' }}`.

The token reaches the scalers on standard input, never a command line or a container's environment, and the jobs never see it. A runner's single-use configuration is in its environment, which the runner clears before any step runs.

## Setting it up

You need WSL 2, PowerShell 7.4 or later, and `gh` signed in with the `repo` scope, as an admin of the repos.

1. `task runner:install`, in shared-tooling's own checkout, which the runners then run from. It installs the distro and Docker, copies `runners.example.psd1` to `%USERPROFILE%\.ci-runner\runners.psd1`, and registers the "CI runners" task. Running it again redoes only what's missing.
2. List the repos in `%USERPROFILE%\.ci-runner\runners.psd1`. The limits are optional, and the example says what each defaults to.
3. `task shared:runner:start`. The first start builds the images, which takes a few minutes, and creates each repo's scale set; it returns once the scaler is up.
4. In each repo, send the jobs to the runners, naming the config's `Name`:

   ```bash
   gh variable set CI_RUNNER --body wsl --repo owner/app
   ```

   The shared workflows read the variable. A job of the project's own takes the same line, `runs-on: ${{ github.event.pull_request.head.repo.fork && 'ubuntu-24.04' || vars.CI_RUNNER || 'ubuntu-24.04' }}`, and a Windows one the line under Windows jobs above.

5. In a public repo, first require approval for every outside contributor's workflow runs, under Settings → Actions → General, or:

   ```bash
   gh api -X PUT repos/owner/app/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors
   ```

   A pull request from a fork runs its own copy of the workflows, which could name the runners' label and run anything on this machine. The shared workflows send a fork's pull request to GitHub's runners, and the approval stops a changed workflow until you have read it.

The state lives in `%USERPROFILE%\.ci-runner`, not AppData: a packaged app's processes (a terminal inside one, say) read and write their own copy of AppData, so the task wouldn't see a config written from one.

## Day to day

In any repo on a release that has them:

| To | Do |
| --- | --- |
| Start them, before pushing | `task shared:runner:start`. Jobs queued while they were stopped start then. |
| Stop them, and give WSL's memory back | `task shared:runner:stop`. A job running then fails, and new jobs queue until the next start. |
| See what's running | `task shared:runner:status`: the scaler, the limits and what the jobs use now, its last lines, and a row per running job |
| Read a job's output | GitHub's run page, as with any job; `%USERPROFILE%\.ci-runner\logs` has `supervisor.log` for the loop, and `scaler.log` and `scaler-windows.log` for each job's start and end |
| Add a repo, or change a limit | Edit the config, then stop and start them |
| Send a repo back to GitHub's runners | `gh variable delete CI_RUNNER --repo owner/app` |
| Take a change to `Dockerfile` or `scaler/` | Stop and start them, which builds the new image |

While the runners are stopped, or the machine is off or asleep, a repo's jobs wait in the queue, and GitHub cancels a job that has waited 24 hours. Dependabot's pull requests are the usual case, since nobody pushes them: start the runners within the day, re-run the cancelled ones from GitHub, or delete the variable first to run them on GitHub's runners.

## What it costs the machine

- **Started, between jobs:** the scaler, about 15 MB and no CPU to speak of, and Docker's daemons, about 150 MB, inside WSL's VM, which with its kernel and file cache holds 1.5 to 2 GB of Windows' memory.
- **Stopped:** nothing. With no other distro running, WSL stops its VM a minute after `task shared:runner:stop`.
- **Running jobs** use at most `Cpus` CPUs and `Memory` together (by default half the distro's CPUs and three quarters of its memory), and `MaxJobs` defaults to as many jobs as `Memory` holds at 1.5 GB each, about what a front end's build and tests peak at. A burst of jobs, such as Dependabot's pull requests across every repo, then waits its turn rather than taking the whole machine. Lower `Cpus` for a quieter machine while jobs run, or raise it for faster runs.
- WSL hands memory back to Windows slowly once the jobs end, so the VM can stay larger than the jobs need for a while afterwards.

## When a job differs from GitHub's

- **Only the caches carry over between jobs.** Each job starts from the image, but every Linux job mounts the `ci-cache` volume at `/ci-cache`, where the image points Go's module and build caches, golangci-lint's, npm's and Composer's; the Windows jobs keep theirs in `%USERPROFILE%\.ci-runner\windows`. Each tool locks or writes its cache atomically, so jobs side by side share it, and a job after the first starts warm. They are on disk, the volume on the distro's virtual disk, so they outlive `task shared:runner:stop`, a shut-down VM and a reboot. Once one grows past the config's `CacheSize` (30 GB), the next start or six-hourly check empties it.
- **GitHub's cache is for what a run's jobs hand each other.** On these runners the shared workflows skip it for Go, npm's downloads and Composer, which upload slowly from a home connection; `node_modules` still goes through it, since a run's later jobs restore the web job's. A project's own job does the same with `cache: ${{ runner.environment == 'github-hosted' }}` on `setup-go`, and `skip-cache: ${{ runner.environment != 'github-hosted' }}` on golangci-lint's action. zstd is in the image, so the runners and GitHub's share what does go there.
- **The jobs share their caches,** a repo's with every other's, as they share the machine: a job could leave something there that another reads, which is why only your own repos, never a fork's pull request, run here.
- **The tools baked into the image** are PowerShell at the `Dockerfile`'s pinned version, Chrome's and the GitHub CLI's current releases when the image was built, and PHP 8.5 with its common extensions. Raise a version there and restart the runners.
- **A job may use up to the config's `JobMemory`** (8 GB by default), and `/dev/shm` is 2 GB, which Chrome needs.
- **A job with Docker access** leaves its images, build cache and named volumes in the distro's Docker, so its next run starts warm; `task shared:runner:stop` doesn't clear them.
- **A Windows job** keeps its Go caches and tool cache between jobs, unlike a container, and doesn't share yours.
