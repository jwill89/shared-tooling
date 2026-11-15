# Self-hosted runners

Runs the private repos' CI on a Windows machine instead of GitHub's runners, so it costs no Actions minutes. Each job runs in a fresh container, like a GitHub-hosted job, inside a WSL distro kept for the runners alone. Public repos stay on GitHub's runners: they are free there, and a self-hosted runner would run other people's pull requests.

## How it fits together

- **The distro** (`ci-runner`, Ubuntu 24.04) runs Docker Engine and nothing else. `setup-host.sh` turns off its Windows drives and Windows programs, so a job's packages can't reach either.
- **The image** (`Dockerfile`) is Ubuntu 24.04 like GitHub's `ubuntu-24.04`, with what the shared workflows expect to find (PowerShell, Chrome, PHP, zstd, passwordless sudo) and the Actions runner. The other tools come from the setup actions, as on GitHub.
- **The loop** (`Start-CiRunner`, run hidden by the "CI runners" task at each sign-in) keeps a ready runner for each slot of each repo in the config. For each one it asks GitHub for a single-use runner, starts a container with it, and waits while the runner takes one job. When the job ends, the container is removed and a new runner takes its place. Every six hours it rebuilds the image when the runner has a new release, since GitHub stops sending jobs to a runner that falls too far behind.
- **A personal account's runner serves one repo**, so each repo gets its own slots. A slot runs one job at a time, so a run's jobs wait for each other unless the repo has more slots.

The GitHub token stays with `gh` on Windows. A runner's single-use configuration reaches its container on standard input, never on a command line.

## Setting it up

You need WSL 2, PowerShell 7.4 or later, and `gh` signed in with the `repo` scope, as an admin of the repos.

1. `task runner:install`. It installs the distro and Docker, copies `runners.example.psd1` to `%USERPROFILE%\.ci-runner\runners.psd1`, and registers the sign-in task. Running it again redoes only what's missing.
2. List the private repos in `%USERPROFILE%\.ci-runner\runners.psd1`, with the number of slots each needs.
3. `task runner:start`. The first start builds the image, which takes a few minutes. `task runner:status` then shows each repo's runner as `online`.
4. In each repo, send the jobs to the runners:

   ```bash
   gh variable set CI_RUNNER --body self-hosted --repo owner/app
   ```

   The shared workflows read the variable. A job of the project's own takes the same line, `runs-on: ${{ vars.CI_RUNNER || 'ubuntu-24.04' }}`. A Windows job stays on GitHub's runners.

The state lives in `%USERPROFILE%\.ci-runner`, not AppData: a packaged app's processes (a terminal inside one, say) read and write their own copy of AppData, so the sign-in task wouldn't see a config written from one.

## Day to day

| To | Do |
| --- | --- |
| See what's running | `task runner:status` |
| Read a job's output | GitHub's run page, as with any job; `%USERPROFILE%\.ci-runner\logs` has the loop's log and one log per slot |
| Stop them | `task runner:stop`. A job running then fails, and the repos' jobs wait until the runners are back. |
| Start them again | `task runner:start`, or sign in again |
| Add a repo or a slot | Edit the config, then `task runner:stop` and `task runner:start` |
| Send a repo back to GitHub's runners | `gh variable delete CI_RUNNER --repo owner/app` |
| Take a change to the `Dockerfile` | `task runner:stop`, then `task runner:start`, which builds the new image |

While the machine is off or asleep, a repo's jobs wait in the queue, and GitHub cancels a job that has waited 24 hours. Dependabot's pull requests are the usual case, since nobody pushes them. Re-run them from GitHub, or delete the variable first to run them on GitHub's runners.

## When a job differs from GitHub's

- **Nothing carries over between jobs.** Each job starts from the image, so the setup actions and the cache action fetch what they need each time, as on GitHub. zstd is in the image, so the runners and GitHub's share the cache.
- **The tools baked into the image** are PowerShell at the `Dockerfile`'s pinned version, Chrome's current release when the image was built, and PHP 8.5 with its common extensions. Raise a version there and restart the runners.
- **A job may use up to the config's `Memory`** (8 GB by default), and `/dev/shm` is 2 GB, which Chrome needs.
