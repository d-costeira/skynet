#!/usr/bin/env bash
# Step 1: bring Ubuntu 24.04 fully up to date and turn on automatic security
# updates. Safe to re-run.
source "$(dirname "$0")/common.sh"
require_root
require_ubuntu_2404

log "Refreshing package lists"
apt-get update

log "Installing all pending updates (including ones that add or remove packages)"
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade

log "Removing packages that are no longer needed"
apt-get -y autoremove --purge

log "Installing base tools"
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg2 git jq htop nvtop pciutils lm-sensors \
  unattended-upgrades

log "Enabling automatic security updates"
# Writes /etc/apt/apt.conf.d/20auto-upgrades with daily list refresh and
# unattended security upgrades.
echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' \
  | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades

if [[ -f /var/run/reboot-required ]]; then
  warn "A reboot is required to finish updating (usually a new kernel)."
  warn "Reboot before installing the NVIDIA driver: sudo reboot"
else
  log "System is up to date. No reboot needed."
fi
