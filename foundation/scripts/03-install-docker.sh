#!/usr/bin/env bash
# Step 3: install Docker Engine from Docker's official apt repository and put
# Docker's data (images, volumes) on the 1 TB SSD.
# Follows https://docs.docker.com/engine/install/ubuntu/
source "$(dirname "$0")/common.sh"
require_root
require_ubuntu_2404

mountpoint -q "${DATA_ROOT}" \
  || die "${DATA_ROOT} is not a mount point. Mount the 1 TB SSD there first (see foundation/README.md)."

log "Removing distro Docker packages that conflict with Docker CE (if any)"
for pkg in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
  if dpkg -s "${pkg}" >/dev/null 2>&1; then apt-get remove -y "${pkg}"; fi
done

log "Adding Docker's apt repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
# shellcheck source=/dev/null
source /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

log "Installing Docker Engine and the Compose plugin"
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "Moving Docker's data-root to ${DOCKER_DATA_ROOT}"
systemctl stop docker docker.socket
mkdir -p "${DOCKER_DATA_ROOT}" /etc/docker
daemon_json=/etc/docker/daemon.json
[[ -s "${daemon_json}" ]] || echo '{}' > "${daemon_json}"
tmp="$(mktemp)"
jq --arg root "${DOCKER_DATA_ROOT}" '. + {"data-root": $root, "log-driver": "local"}' \
  "${daemon_json}" > "${tmp}"
mv "${tmp}" "${daemon_json}"
systemctl start docker

if [[ -n "${SUDO_USER:-}" ]]; then
  log "Adding ${SUDO_USER} to the docker group (log out and back in to take effect)"
  usermod -aG docker "${SUDO_USER}"
  warn "Members of the docker group are effectively root on this machine."
fi

log "Checking"
docker info --format 'Docker {{.ServerVersion}}, data-root {{.DockerRootDir}}'
docker run --rm hello-world >/dev/null && echo "hello-world container ran OK."
