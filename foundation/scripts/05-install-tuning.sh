#!/usr/bin/env bash
# Step 5: GPU power limit at every boot, and the CPU governor pinned to
# "performance".
source "$(dirname "$0")/common.sh"
require_root

nvidia-smi >/dev/null 2>&1 || die "nvidia-smi fails. Install the driver and reboot first."

log "Installing the GPU power-limit unit (${GPU_POWER_LIMIT} W per card)"
echo "GPU_POWER_LIMIT=${GPU_POWER_LIMIT}" > /etc/default/gpu-power-limit
install -m 0644 "${FOUNDATION_DIR}/systemd/gpu-power-limit.service" /etc/systemd/system/

log "Installing the CPU governor unit"
install -m 0644 "${FOUNDATION_DIR}/systemd/cpu-governor-performance.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now gpu-power-limit.service cpu-governor-performance.service

log "Checking"
nvidia-smi --query-gpu=index,name,power.limit,pcie.link.gen.current,pcie.link.width.current \
  --format=csv
echo "CPU governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
echo
echo "Note: PCIe gen/width can read lower at idle (power saving). Check it again"
echo "while vLLM is running; under load both cards should show gen 3, width 8."
