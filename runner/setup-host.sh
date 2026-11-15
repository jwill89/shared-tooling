#!/usr/bin/env bash
# Prepares the WSL distro the CI runners live in, run as root inside it: systemd, no
# Windows drives or programs reachable from it, and Docker Engine from Docker's own
# repository. Safe to run again; Install-CiRunner.ps1 runs it, then restarts the distro so
# wsl.conf takes effect.
set -euo pipefail

# A job runs its packages' install scripts and tests, so nothing in this distro can read
# the Windows drives or start a Windows program.
cat > /etc/wsl.conf <<'EOF'
[boot]
systemd=true

[automount]
enabled=false
mountFsTab=false

[interop]
enabled=false
appendWindowsPath=false

[user]
default=root
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends ca-certificates curl

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
# shellcheck source=/dev/null
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update -q
apt-get install -y -q --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin

# The local log driver rotates on its own, so an idle runner's output never fills the disk.
mkdir -p /etc/docker
printf '{ "log-driver": "local" }\n' > /etc/docker/daemon.json
systemctl enable --now docker
systemctl restart docker
docker version --format 'Docker Engine {{.Server.Version}}'
