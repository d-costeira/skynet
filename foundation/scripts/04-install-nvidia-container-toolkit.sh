#!/usr/bin/env bash
# Step 4: install the NVIDIA Container Toolkit so Docker containers can use
# the GPUs, then register the NVIDIA runtime with Docker.
# Follows https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
source "$(dirname "$0")/common.sh"
require_root
require_ubuntu_2404

nvidia-smi >/dev/null 2>&1 || die "nvidia-smi fails. Install the driver and reboot first (02-install-nvidia-driver.sh)."
command -v docker >/dev/null || die "Docker is not installed. Run 03-install-docker.sh first."

log "Installing prerequisites"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg2

log "Adding NVIDIA's container toolkit repository"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list

log "Installing nvidia-container-toolkit ${NVIDIA_CONTAINER_TOOLKIT_VERSION}"
apt-get update
v="${NVIDIA_CONTAINER_TOOLKIT_VERSION}"
apt-get install -y \
  "nvidia-container-toolkit=${v}" \
  "nvidia-container-toolkit-base=${v}" \
  "libnvidia-container-tools=${v}" \
  "libnvidia-container1=${v}"
# Stop unattended-upgrades from silently moving the toolkit off the pinned version.
apt-mark hold nvidia-container-toolkit nvidia-container-toolkit-base \
  libnvidia-container-tools libnvidia-container1

log "Registering the NVIDIA runtime with Docker (edits /etc/docker/daemon.json)"
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

log "Checking that a container can see both GPUs"
# NVIDIA's sample workload: an ordinary Ubuntu image, GPUs injected by the toolkit.
docker run --rm --gpus all ubuntu nvidia-smi
