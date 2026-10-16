"""Does prefix caching actually hit, with the current vLLM profile?

Sends the same long prompt twice and compares:
  - time to first token (TTFT), cold vs warm
  - vLLM's own prefix-cache counters before/after the second request
  - MTP draft acceptance, if speculative decoding is on

Runs inside the vllm container (stdlib only), talking to vLLM directly:
  docker compose exec -T vllm python3 - < ../bench/prefix_cache_check.py
Prints one JSON object.
"""

import json
import os
import random
import re
import time
import urllib.request

BASE = "http://127.0.0.1:8000"
KEY = os.environ["VLLM_API_KEY"]
MODEL = "qwen3.8-27b"
PROMPT_WORDS = int(os.environ.get("PREFIX_WORDS", "6000"))  # roughly 8K tokens

WORDS = (
    "light kitchen garage sensor door window thermostat garden music speaker "
    "camera hallway bedroom office lamp switch schedule morning evening night "
    "weather forecast list grocery timer alarm battery power server network"
).split()


def metrics():
    with urllib.request.urlopen(f"{BASE}/metrics", timeout=10) as r:
        text = r.read().decode()
    totals = {}
    for line in text.splitlines():
        m = re.match(r"^(vllm:[a-z_]+?)(_total)?(\{.*\})? ([0-9.eE+-]+)$", line)
        if m:
            totals[m.group(1)] = totals.get(m.group(1), 0.0) + float(m.group(4))
    return totals


def ttft(prompt):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 16,
        "stream": True,
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    req = urllib.request.Request(
        f"{BASE}/v1/chat/completions", data=body,
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"},
    )
    start = time.perf_counter()
    first = None
    with urllib.request.urlopen(req, timeout=600) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            delta = json.loads(line[6:])["choices"][0]["delta"]
            if first is None and (delta.get("content") or delta.get("reasoning_content")):
                first = time.perf_counter() - start
    return first


def main():
    rng = random.Random(time.time_ns())  # new prefix every run, so run 1 is truly cold
    context = " ".join(rng.choice(WORDS) for _ in range(PROMPT_WORDS))
    prompt = f"Here are some notes:\n{context}\n\nReply with the single word OK."

    m0 = metrics()
    cold = ttft(prompt)
    m1 = metrics()
    warm = ttft(prompt)
    m2 = metrics()

    def delta(a, b, name):
        return b.get(name, 0.0) - a.get(name, 0.0)

    q = delta(m1, m2, "vllm:prefix_cache_queries")
    h = delta(m1, m2, "vllm:prefix_cache_hits")
    result = {
        "prompt_words": PROMPT_WORDS,
        "ttft_cold_s": round(cold, 3) if cold else None,
        "ttft_warm_s": round(warm, 3) if warm else None,
        "warm_request_prefix_cache_queries": q,
        "warm_request_prefix_cache_hits": h,
        "warm_request_hit_rate": round(h / q, 3) if q else None,
        "cold_request_hit_rate": (
            round(delta(m0, m1, "vllm:prefix_cache_hits") / delta(m0, m1, "vllm:prefix_cache_queries"), 3)
            if delta(m0, m1, "vllm:prefix_cache_queries") else None
        ),
    }
    drafts = m2.get("vllm:spec_decode_num_draft_tokens", 0.0)
    if drafts:
        result["mtp_lifetime_acceptance_rate"] = round(
            m2.get("vllm:spec_decode_num_accepted_tokens", 0.0) / drafts, 3)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
