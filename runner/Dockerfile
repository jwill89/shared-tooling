# syntax=docker/dockerfile:1
# The image a self-hosted CI job runs in: Ubuntu 24.04, as GitHub's ubuntu-24.04 image,
# with what the shared workflows expect to find rather than set up (PowerShell, Google
# Chrome, PHP from the PPA setup-php uses, zstd for actions/cache's format, sudo for apt),
# and the Actions runner. Each container takes one job and is removed, so every job
# starts from this image as it was built.
#
# Start-CiRunners.ps1 builds it, passing the runner's newest release and its checksum.

FROM ubuntu:24.04

ARG RUNNER_VERSION
ARG RUNNER_SHA256
ARG POWERSHELL_VERSION=7.6.10
ARG POWERSHELL_SHA256=81a5a944702b116ea74c88b01ba5f1f46b1cd7c42c36d85e1bae90de1230b4d1
ARG PHP_VERSION=8.5

# The tool cache where the hosted image keeps it, so the setup actions share one layout;
# `runner` tells setup-php it is on a self-hosted machine.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    ImageOS=ubuntu24 \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    runner=self-hosted

# Build tools for cgo and the race detector, git, archives, and zstd, without which
# actions/cache writes another format and misses every cache a hosted run saved.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl file git gnupg jq lsb-release pkg-config \
      python3 python3-venv software-properties-common sudo tzdata unzip wget xz-utils zip zstd \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/pwsh.deb \
      "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell_${POWERSHELL_VERSION}-1.deb_amd64.deb" \
 && echo "${POWERSHELL_SHA256}  /tmp/pwsh.deb" | sha256sum -c - \
 && apt-get update \
 && apt-get install -y --no-install-recommends /tmp/pwsh.deb \
 && rm -rf /tmp/pwsh.deb /var/lib/apt/lists/*

# Chrome for the end-to-end suites, which run in the machine's own Chrome. Its package
# adds an apt source of its own, removed so a job's apt-get update reads only Ubuntu's.
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends google-chrome-stable \
 && rm -rf /etc/apt/sources.list.d/google-chrome.list* /var/lib/apt/lists/*

# PHP and the extensions callers ask for, so setup-php finds them in place instead of
# installing them on every job.
RUN add-apt-repository -y ppa:ondrej/php \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "php${PHP_VERSION}-cli" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-gd" "php${PHP_VERSION}-gmp" \
      "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-sqlite3" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-zip" \
 && rm -rf /var/lib/apt/lists/*

# The job's user, as on the hosted image: uid 1001 and sudo without a password, which
# setup-php and the workflows' apt steps need.
RUN groupadd --gid 1001 runner \
 && useradd --uid 1001 --gid runner --shell /bin/bash --create-home runner \
 && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner \
 && chmod 0440 /etc/sudoers.d/runner \
 && install -d -o runner -g runner /opt/hostedtoolcache /usr/share/dotnet

WORKDIR /home/runner/actions-runner
RUN test -n "$RUNNER_VERSION" && test -n "$RUNNER_SHA256" \
 && curl -fsSL -o /tmp/runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
 && echo "${RUNNER_SHA256}  /tmp/runner.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/runner.tar.gz \
 && rm /tmp/runner.tar.gz \
 && ./bin/installdependencies.sh \
 && rm -rf /var/lib/apt/lists/* \
 && chown -R runner:runner /home/runner

# The just-in-time configuration arrives on standard input, so it is never on a command
# line, and from Windows with a CR after it; the runner takes one job with it and exits.
COPY --chmod=0755 <<'EOF' /usr/local/bin/run-one-job
#!/usr/bin/env bash
set -euo pipefail
IFS= read -r jitconfig
jitconfig="${jitconfig%$'\r'}"
exec /home/runner/actions-runner/run.sh --jitconfig "$jitconfig"
EOF

USER runner
ENTRYPOINT ["/usr/local/bin/run-one-job"]
