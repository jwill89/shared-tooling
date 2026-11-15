# The self-hosted runners' settings, read by runner/CiRunner.psm1. Copy this file to
# %USERPROFILE%\.ci-runner\runners.psd1 (Install-CiRunner does on its first run) and list
# your private repos there; it stays on this machine, outside every repo.
@{
    # The account that owns the repos.
    Owner = 'owner'

    # Each private repo the runners serve, with how many of its jobs may run at once. A
    # personal account's runner serves one repo, so every repo gets its own. A public repo
    # stays on GitHub's own runners, free and out of reach of other people's pull requests.
    Repos = @{
        'app'       = 1
        'other-app' = 2
    }

    # The rest are optional; these are the defaults.

    # The WSL distro the containers run in (Install-CiRunner -Distro).
    # Distro     = 'ci-runner'

    # The labels each runner carries; a repo's CI_RUNNER variable names one of them.
    # Labels     = @('self-hosted', 'linux', 'x64')

    # The start of each runner's name, which Stop-CiRunner uses to find its own.
    # NamePrefix = 'wsl'

    # The memory one job's container may use.
    # Memory     = '8g'
}
