# The self-hosted runners' settings, read by runner/CiRunner.psm1. Copy this file to
# %USERPROFILE%\.ci-runner\runners.psd1 (Install-CiRunner does on its first run) and list
# your repos there; it stays on this machine, outside every repo.
@{
    # The account that owns the repos.
    Owner = 'owner'

    # Each repo the runners serve. Each gets a scale set of its own, since a personal
    # account's runners serve one repo, and runs as many jobs at once as MaxJobs allows.
    Repos = @(
        'app'
        'other-app'
    )

    # The rest are optional; these are the defaults.

    # The scale sets' name: the label a repo's CI_RUNNER variable names, and the start of
    # each runner's name.
    # Name      = 'wsl'

    # How many jobs may run at once across every repo; the rest wait in GitHub's queue.
    # Defaults to as many as Memory holds at 1.5 GB each, and at most one per processor.
    # MaxJobs   = 7

    # The CPUs and memory the running jobs share, however many there are. Default to half
    # the distro's CPUs, and three quarters of its memory.
    # Cpus      = 16
    # Memory    = '12g'

    # The memory one job's container may use.
    # JobMemory = '8g'

    # The WSL distro the containers run in (Install-CiRunner -Distro).
    # Distro    = 'ci-runner'

    # Repos (of Repos) whose job containers may use the distro's Docker, such as one that
    # builds its packages in a container of its own. Such a job controls every container
    # in the distro, so list only repos you would build on this machine anyway.
    # DockerRepos = @('other-app')

    # Repos (of Repos) whose Windows jobs run here, as processes, as you, on the scale set
    # '<Name>-windows'; and how many may run at once. Building their scaler needs Go.
    # WindowsRepos   = @('other-app')
    # WindowsMaxJobs = 1
}
