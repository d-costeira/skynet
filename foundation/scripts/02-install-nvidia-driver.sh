#!/usr/bin/env bash
# Step 2: install the NVIDIA 580 server driver with open kernel modules,
# headless (no X/desktop libraries), and turn on persistence mode.
source "$(dirname "$0")/common.sh"
require_root
require_ubuntu_2404

branch="${NVIDIA_DRIVER_BRANCH}"

log "GPUs on the PCI bus"
lspci -nn | grep -i nvidia || die "No NVIDIA devices found on the PCI bus."

if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
  current="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
  log "An NVIDIA driver is already loaded: ${current}"
  if [[ "${current%%.*}" == "${branch}" ]]; then
    log "Already on the ${branch} branch. Nothing to install."
    exit 0
  fi
  warn "Loaded driver is not the ${branch} branch. It will be replaced."
  confirm "Continue?" || exit 1
fi

log "Installing nvidia-headless-${branch}-server-open and nvidia-utils-${branch}-server"
# headless-*-open: kernel modules (open flavour) + compute libraries, no X.
# utils-*: nvidia-smi and nvidia-persistenced.
apt-get update
apt-get install -y \
  "nvidia-headless-${branch}-server-open" \
  "nvidia-utils-${branch}-server"

log "Enabling the persistence daemon (keeps the driver initialised between jobs)"
systemctl enable nvidia-persistenced

warn "Reboot now to load the new kernel modules: sudo reboot"
echo "After rebooting, check with: nvidia-smi"
echo "Expect two 'NVIDIA GeForce RTX 3090' rows and driver ${branch}.x."
