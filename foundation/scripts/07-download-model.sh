#!/usr/bin/env bash
# Step 7: download the model to the 1 TB SSD and check it contains no code.
#
# Runs the download inside the (pinned) vLLM image, which already ships the
# huggingface_hub library, so nothing extra is installed on the host.
# Run as your normal user (in the docker group), not with sudo.
source "$(dirname "$0")/common.sh"

target="${MODELS_DIR}/${MODEL_DIR_NAME}"

[[ -w "${MODELS_DIR}" ]] || die "${MODELS_DIR} is not writable. Create it first: sudo install -d -o \$USER ${MODELS_DIR}"

log "Downloading ${MODEL_REPO} to ${target} (about 21 GB; slow over SATA/Wi-Fi is normal)"
# HF_TOKEN is optional; pass it through if set (needed only for gated repos).
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HF_HOME=/tmp/hf \
  -e HF_TOKEN="${HF_TOKEN:-}" \
  -v "${MODELS_DIR}:/models" \
  --entrypoint python3 \
  "${VLLM_IMAGE}" \
  -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='${MODEL_REPO}', local_dir='/models/${MODEL_DIR_NAME}')"

log "Inspecting the download"
du -sh "${target}"
ls -la "${target}"

# Executable code in a model repo only runs with --trust-remote-code, which we
# never pass. Flag it anyway, so you know what's there.
code_files="$(find "${target}" -type f \( -name '*.py' -o -name '*.sh' -o -name '*.so' -o -name '*.pkl' -o -name '*.bin' \) -not -path '*/.cache/*')"
if [[ -n "${code_files}" ]]; then
  warn "Found files that could contain code or pickled objects:"
  echo "${code_files}"
  warn "Review them before starting vLLM. Expected contents: *.safetensors, *.json, tokenizer files."
else
  log "OK: only weights, configs and tokenizer files (no .py/.sh/.so/.pkl/.bin)."
fi
