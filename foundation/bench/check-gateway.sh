#!/usr/bin/env bash
# Does LiteLLM really apply the per-alias settings, and can a client undo them?
# (Open question in both proposals: coding U6, house U17.)
#
# Run on Skynet with the stack up:  ./check-gateway.sh
# Thinking is the observable signal: with it on, vLLM returns a non-empty
# reasoning_content; with it off, there is none.
set -euo pipefail

cd "$(dirname "$0")/../inference"
set -a; source .env; set +a
URL="http://127.0.0.1:4000/v1/chat/completions"

ask() {  # ask <alias> [extra JSON fields]
  local extra="${2:-}"
  curl -fsS "${URL}" \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" -H "Content-Type: application/json" \
    -d "{\"model\":\"$1\",\"max_tokens\":400,\"messages\":[{\"role\":\"user\",\"content\":\"What is 17 * 23? Answer with just the number.\"}]${extra}}" \
  | jq -r '.choices[0].message | "reasoning=\(if (.reasoning_content // .reasoning // "") == "" then "none" else "present" end)  answer=\((.content // "") | gsub("\\s+"; " ") | .[0:60])"'
}

echo "1. 'think' alias (expect reasoning=present):"
echo "   $(ask think)"
echo "2. 'fast' alias (expect reasoning=none):"
echo "   $(ask fast)"
echo "3. 'fast' alias, client tries to switch thinking ON:"
echo "   $(ask fast ',"chat_template_kwargs":{"enable_thinking":true}')"
echo
echo "If 3 shows reasoning=present, clients can override alias settings."
echo "That matters for any untrusted client (guests, or HA's voice agent), and"
echo "would need a fix before either direction exposes the gateway."
echo
echo "Priority can't be seen in a response. To check it reaches vLLM, run a"
echo "long 'think' request and a 'fast' request at the same time and compare"
echo "queueing in: docker compose logs vllm"
