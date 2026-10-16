#!/usr/bin/env bash
# Benchmark whatever vLLM profile is running right now.
#
#   cd foundation/inference && docker compose up -d   # wait until healthy
#   ../bench/run-benchmarks.sh
#
# Writes results to foundation/bench/results/<timestamp>-<profile>-<watts>W/:
#   - serve-c{1,2,4}.json   vllm bench serve, 8K-token prompt, 512-token reply
#   - prefix-cache.json     cold vs warm TTFT and prefix-cache hit rate
#   - meta.txt              profile, power limit, GPU state
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${BENCH_DIR}/../inference"
[[ -f .env ]] || { echo "No .env in foundation/inference. Copy .env.example first." >&2; exit 1; }
set -a; source .env; set +a

CONCURRENCY="${CONCURRENCY:-1 2 4}"
INPUT_LEN="${INPUT_LEN:-8000}"
OUTPUT_LEN="${OUTPUT_LEN:-512}"

profile="$(docker compose exec -T vllm sh -c 'tr "\0" " " < /proc/1/cmdline' | grep -o '/profiles/[a-z-]*' | sed 's#/profiles/##')"
watts="$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits | head -1 | cut -d. -f1)"
out="${BENCH_DIR}/results/$(date +%Y%m%d-%H%M%S)-${profile}-${watts}W"
mkdir -p "${out}"
echo "Results -> ${out}"

{
  echo "profile: ${profile}"
  echo "gpu_memory_utilization: ${GPU_MEMORY_UTILIZATION}"
  echo "max_model_len: ${MAX_MODEL_LEN}"
  echo "vllm_image: ${VLLM_IMAGE}"
  echo "date: $(date -Is)"
  nvidia-smi --query-gpu=index,name,driver_version,power.limit,pcie.link.gen.max,pcie.link.width.current,memory.used,memory.total --format=csv
  echo "cpu_governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
} > "${out}/meta.txt"

echo "== Prefix cache check (same ~8K-token prompt sent twice)"
docker compose exec -T vllm python3 - < "${BENCH_DIR}/prefix_cache_check.py" | tee "${out}/prefix-cache.json"

for c in ${CONCURRENCY}; do
  n=$(( c * 8 ))
  echo "== vllm bench serve: concurrency ${c}, ${n} prompts, ${INPUT_LEN} in / ${OUTPUT_LEN} out"
  # vllm bench reads the API key from OPENAI_API_KEY.
  docker compose exec -T -e OPENAI_API_KEY="${VLLM_API_KEY}" vllm \
    vllm bench serve \
      --backend openai \
      --base-url http://127.0.0.1:8000 \
      --model qwen3.8-27b \
      --tokenizer "/models/${MODEL_DIR_NAME}" \
      --dataset-name random \
      --random-input-len "${INPUT_LEN}" \
      --random-output-len "${OUTPUT_LEN}" \
      --ignore-eos \
      --num-prompts "${n}" \
      --max-concurrency "${c}" \
      --percentile-metrics ttft,tpot,itl,e2el \
      --save-result --result-dir /tmp/bench --result-filename "serve-c${c}.json"
  docker compose cp "vllm:/tmp/bench/serve-c${c}.json" "${out}/serve-c${c}.json"
done

echo
echo "Done. Summary:"
python3 "${BENCH_DIR}/summarize.py" "${out}"
