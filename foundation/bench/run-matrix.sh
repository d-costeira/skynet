#!/usr/bin/env bash
# Full comparison: each vLLM profile (MTP off / on) at each GPU power limit.
#
#   ./run-matrix.sh                       # mtp-off mtp-on  x  275 250 225 W
#   PROFILES="mtp-on" WATTS="250" ./run-matrix.sh
#
# Restarts vLLM once per profile (several minutes each), changes the power
# limit with sudo, and restores the boot-time limit at the end.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILES="${PROFILES:-mtp-off mtp-on}"
WATTS="${WATTS:-275 250 225}"

cd "${BENCH_DIR}/../inference"

restore_power() { sudo systemctl restart gpu-power-limit.service || true; }
trap restore_power EXIT

wait_healthy() {
  echo -n "Waiting for vLLM to become healthy"
  for _ in $(seq 1 120); do
    state="$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q vllm)" 2>/dev/null || echo starting)"
    [[ "${state}" == "healthy" ]] && { echo " ok"; return 0; }
    [[ "${state}" == "unhealthy" ]] && { echo; docker compose logs --tail 50 vllm; return 1; }
    echo -n "."; sleep 10
  done
  echo; echo "Timed out." >&2; return 1
}

sudo -v   # ask for the sudo password once, up front

for profile in ${PROFILES}; do
  echo "######## Profile: ${profile}"
  # A shell variable overrides the value in .env for this one command.
  VLLM_PROFILE="${profile}" docker compose up -d --force-recreate vllm
  wait_healthy
  for w in ${WATTS}; do
    echo "######## ${profile} @ ${w} W"
    sudo nvidia-smi -pl "${w}" >/dev/null
    "${BENCH_DIR}/run-benchmarks.sh"
  done
done

echo
echo "All runs:"
python3 "${BENCH_DIR}/summarize.py" "${BENCH_DIR}"/results/*/
