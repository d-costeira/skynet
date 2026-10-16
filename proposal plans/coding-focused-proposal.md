# Local LLM Server Stack Proposal: Review Packet

| Field | Value |
|---|---|
| Document | Software stack proposal for a self-hosted LLM server (2× RTX 3090) |
| Version | 1.1 (restructured for independent review) |
| Status | **Draft, awaiting third-party review** |
| Prepared by | AI assistant (Claude), for the system owner |
| Research date | 2026-10-01 (all web sources accessed on this date) |
| Intended reader | An independent reviewing agent or human expert |

---

## 0. Instructions for the reviewing agent

### 0.1 Your task

Critically review this proposal and report what is **wrong, risky, missing, or suboptimal**. Focus on:

1. **Security (highest priority).** Does the design satisfy requirement **R3** (guests must not gain access to coding capabilities)? Look for attack paths the threat model (§4) misses.
2. **Factual accuracy.** Check the evidence items (`E#.#`), constraints (`C#`) and uncertainty items (`U#`). Items labelled `[K]` or `[E]` deserve the most scrutiny.
3. **Fitness for the hardware.** Are the engine, model, quantization and topology choices (D2–D4) right for *this* platform: Haswell 4C/4T, PCIe 3.0 x8/x8, no P2P, 32 GB DDR3?
4. **Config correctness.** Check flags, environment variable names and syntax in Appendices A–E.
5. **Omissions.** Look for missing requirements, risks, or better alternatives.

The open questions in §7 are the areas where the author most wants a second opinion.

### 0.2 Knowledge-cutoff warning

Much of the evidence is from **Aug–Sep 2026**. That includes Qwen3.8-27B (released 2026-08-14), vLLM v0.29/v0.30, Open WebUI v0.11.x, CVE-2026-45672, CVE-2026-87995, and the March 2026 LiteLLM supply-chain incident.

If an item is unfamiliar to you, **don't assume it is fabricated or wrong**. Verify it against the cited source (Appendix F) or current web sources. If you can't verify it, report "could not verify" instead of "false".

### 0.3 Out of scope

- Buying new hardware. You may flag a hardware *blocker*, but don't propose upgrades as the solution.
- Cloud or hosted alternatives.
- Cost.

### 0.4 Labels used in this document

| Label | Meaning |
|---|---|
| `[M]` | Measured by a third party; source cited |
| `[V]` | Vendor-reported claim (model creator or software author) |
| `[K]` | Author's general knowledge, **not re-verified** during this research |
| `[E]` | Author's estimate or inference |
| `[J]` | Judgment call or preference |
| `[S#]` | Source ID (see Appendix F) |
| `R#`, `C#`, `A#` | Requirement, hardware constraint, assumption |
| `D#` | Decision |
| `E#.#` | Evidence item within decision D# |
| `T#` | Threat |
| `U#` | Known uncertainty |
| `Q#` | Question for the reviewer |

### 0.5 Requested output format

Please return:

**1. A findings table:**

| Finding | Severity | Target | Type | Description | Evidence | Suggested change | Your confidence |
|---|---|---|---|---|---|---|---|
| F1 | Blocker / Major / Minor / Nit | e.g. `D3`, `E2.4`, `T2`, `App. A line "…"` | Factual error / Security gap / Design issue / Config error / Omission / Unclear | … | URL or reasoning | … | High / Med / Low |

Severity definitions:

| Severity | Meaning |
|---|---|
| **Blocker** | Violates R3 or will not work as written |
| **Major** | Significant risk, or a clearly better alternative exists |
| **Minor** | Worth fixing, but not decisive |
| **Nit** | Wording or clarity |

**2. A verdict for each decision D1–D8:** Agree / Agree with changes / Disagree, with one sentence of reasoning.

**3. Answers to the open questions Q1–Q10** in §7.

**4. A list of `U#` items you resolved,** with the answer and source.

---

## 1. Context

### 1.1 Original request (verbatim from owner)

> I have an old PC that I want to setup to host a LLM locally. […] I want this PC to serve two use-cases: primarily as an AI assistant to help me with personal projects (coding projects, personal homelab configuration, etc.), and secondarily as a chat AI accessible via a browser that will mostly serve as entertainment for guests. Security is a priority for this project, for example I would not want a house guest interacting with the browser chat AI to gain access to the coding capabilities.
>
> Propose a software stack that would make efficient use of this hardware. Include OS, inference engine, harness, UI, and model. Search online for successfully and performant setups using similar hardware (namely, dual RTX 3090s). Give a detailed explanation for each choice.

### 1.2 Hardware (as stated by owner)

| Component | Spec |
|---|---|
| CPU | Intel i5-4670K (Haswell, 4C/4T, 16 PCIe 3.0 lanes) |
| Motherboard | Asus Maximus VI Hero (Z87) |
| RAM | 32 GB DDR3-1600 (4×8 GB) |
| GPUs | 2× EVGA RTX 3090 FTW3 Ultra, 24 GB each (48 GB total). No NVLink. Each card runs at PCIe 3.0 x8. |
| PSU | EVGA SuperNOVA 1000W P2 (80+ Platinum) |
| Storage | 256 GB SATA SSD (system) + 1 TB SATA SSD |

### 1.3 Requirements

| ID | Requirement | Source |
|---|---|---|
| R1 | **Primary:** AI assistant for coding and homelab configuration. Implies agentic tool use, long context and reliable tool calling. | Owner |
| R2 | **Secondary:** browser-based chat for guest entertainment | Owner |
| R3 | **Security:** a guest using the chat UI must not gain access to coding capabilities. Security is a priority. | Owner |
| R4 | Make efficient use of the existing hardware | Owner |
| R5 | Specify the OS, inference engine, harness, UI and model, each with a detailed rationale | Owner |
| R6 | Ground choices in documented, performant dual-RTX-3090 setups | Owner |

### 1.4 Hardware-derived constraints

| ID | Constraint | Label |
|---|---|---|
| C1 | 48 GB VRAM split 24 + 24 GB. Ampere (sm_86) has no native FP8 compute (FP8 weights run weight-only via Marlin kernels) and no NVFP4. | [S3] [S7] [K] |
| C2 | PCIe 3.0 x8/x8 (~7.9 GB/s per direction per card) and no NVLink. GeForce drivers disable PCIe P2P, so NCCL traffic is staged through host memory. | [S9] [S12] |
| C3 | 4C/4T Haswell CPU. vLLM's scheduler, sampler and API server are Python processes, so per-step CPU overhead may bottleneck decoding. | [S9] [E] |
| C4 | 32 GB of DDR3-1600 (~25 GB/s theoretical) makes CPU or MoE expert offload impractically slow, so the whole model must fit in VRAM. | [K] [E] |
| C5 | The i5-4670K has **no VT-d**, so a hypervisor with GPU passthrough is impossible. | [K] — verify on Intel ARK (U1) |
| C6 | Z87 has **no official Resizable BAR** support, which the community P2P driver patch requires. | [K] for Z87; [S13] for the patch requirement (U2) |
| C7 | Two 3090s on a 1000 W PSU leave modest headroom for 3090 transient power spikes. | [K] |
| C8 | Storage is SATA only, so model loads run at ~0.5 GB/s. Fine for a model that stays resident 24/7. | [K] |

### 1.5 Assumptions (reviewer: challenge any that look unsafe)

| ID | Assumption |
|---|---|
| A1 | The owner's workstation is a separate machine on a trusted network. The coding harness runs there, not on the LLM server. |
| A2 | The owner's router or firewall supports VLANs and inter-VLAN rules (e.g. OPNsense, pfSense, UniFi, OpenWrt), or can be made to. |
| A3 | Guests are casual and may include children. Peak guest concurrency is about 5 users. |
| A4 | Coding is single-user, with 1–2 concurrent agent streams (occasionally more with sub-agents). |
| A5 | Nothing is exposed to the internet. Remote access, if any, goes over Tailscale or WireGuard. |
| A6 | The owner is comfortable with Linux administration and Docker Compose. |
| A7 | Guest use is occasional. The server runs 24/7, mainly for coding. |

---

## 2. Proposal summary

| ID | Layer | Choice | Confidence |
|---|---|---|---|
| D1 | OS | Ubuntu Server 24.04 LTS, headless; NVIDIA 580-series driver (open kernel modules); Docker + NVIDIA Container Toolkit | High |
| D2 | Inference engine | vLLM (official Docker image) | High |
| D3 | Model | Qwen3.8-27B, AWQ INT4 (`cyankiwi/Qwen3.8-27B-AWQ-INT4`), built-in MTP speculative decoding | High (model) / Medium (quant) |
| D4 | GPU topology | **One shared instance**, tensor-parallel across both GPUs (TP=2), serving both use cases | **Medium** (platform-dependent; see Q1) |
| D5 | Gateway / ingress | LiteLLM (policy: scoped keys, rate limits, per-alias defaults) behind Caddy (sole ingress, TLS, IP allow-lists) | Medium |
| D6 | Coding harness | OpenCode on the owner's workstation | Medium-High |
| D7 | Chat UI | Open WebUI ≥ v0.11.4, as **two isolated instances** (guest and personal) | Medium |
| D8 | Hardware tuning | Power-limit GPUs to 250–275 W, CPU governor `performance` (optional overclock), headless with iGPU display | High |

### 2.1 Architecture

```
 Guest Wi-Fi VLAN ──► :443 ─┐
                            │  ┌──────────────── LLM server (Ubuntu, headless, Docker) ────────────────┐
 Trusted LAN / Tailscale ─► │  │                                                                        │
                            └─►│ Caddy ── guest host ───► open-webui-guest ──(guest key)──┐               │
                               │   │  (remote_ip check)                                   ▼               │
                               │   ├─ chat host ────────► open-webui-personal ─(key)──► LiteLLM ──► vLLM  │
                               │   └─ api host ─────────────────────────────────(key)──►   │      TP=2   │
                               │                                                       Postgres  2×3090 │
                               └────────────────────────────────────────────────────────────────────────┘
 Workstation: OpenCode ──(coder key, TLS)──► Caddy api host ──► LiteLLM ──► vLLM
              (tools execute HERE, with per-command approval)
```

Docker networks:

| Network | Members | Internet egress |
|---|---|---|
| `edge` | Caddy only. Caddy is the only container that publishes host ports. | — |
| `inference` | vLLM, LiteLLM | No (`internal: true`) |
| `guest` | guest Open WebUI, LiteLLM, Caddy | No (`internal: true`) |
| `trusted` | personal Open WebUI, LiteLLM, Caddy | Yes |
| `db` | LiteLLM, Postgres | No (`internal: true`) |

---

## 3. Decisions

Each decision follows the same structure:

- **Decision**
- **Satisfies** (which requirements)
- **Rationale**
- **Evidence**
- **Alternatives rejected**
- **Risks**
- **Verify by** (how the owner confirms it after deployment)

### D1. OS: Ubuntu Server 24.04 LTS, headless

- **Decision:**
  - Ubuntu Server 24.04 LTS, minimal install, no desktop.
  - NVIDIA 580-series server driver with open kernel modules.
  - Docker CE + NVIDIA Container Toolkit.
  - OS on the 256 GB SSD. Docker `data-root` and `/srv/models` on the 1 TB SSD.
- **Satisfies:** R4, R5
- **Rationale:**
  - vLLM requires Linux. The CUDA runtime ships inside the vLLM container, so the host only needs the driver and the container runtime.
  - Running headless frees VRAM and CPU (see C3). If a display is ever needed, use the motherboard's iGPU output.
- **Evidence:**
  - E1.1 [K] vLLM has no native Windows support; WSL2 adds overhead and is fragile for multi-GPU NCCL.
  - E1.2 [K] The 580 driver branch is a long-term branch and is required by CUDA 13-based container images (U3).
  - E1.3 [S29] Ubuntu 26.04 LTS packages CUDA in its archive. This makes it a viable alternative now that 26.04.1 is out.
- **Alternatives rejected:**

  | Alternative | Why rejected |
  |---|---|
  | Proxmox or another hypervisor | No VT-d (C5); VM overhead on a 4-thread CPU |
  | Windows + WSL2 | See E1.1 |
  | Debian | Viable, but driver packaging is less turnkey [J] |
  | Ubuntu 26.04.1 | Viable; 24.04 chosen as the more-trodden path [J] (see Q10) |

- **Risks:**
  - The driver branch must be at least the version required by the chosen vLLM image's CUDA version.
- **Verify by:**
  - `nvidia-smi` shows both GPUs.
  - `docker run --rm --gpus all nvidia/cuda:<tag> nvidia-smi` works.

### D2. Inference engine: vLLM

- **Decision:** vLLM, using the official `vllm/vllm-openai` image pinned by digest (v0.30.0 was the latest at research time [S28]).
- **Satisfies:** R1, R2, R4, R6
- **Rationale:**
  - Tensor parallelism uses both GPUs' memory bandwidth on every token.
  - Continuous batching serves guests and the agent concurrently.
  - Automatic prefix caching is critical for agent loops, which resend a large shared prefix on every turn.
  - MTP speculative decoding.
  - Priority scheduling.
  - Maintained Qwen tool-call and reasoning parsers.
  - OpenAI-compatible and Anthropic `/v1/messages` endpoints.
  - API-key authentication.
  - Multiple published recipes exist for exactly 2× RTX 3090.
- **Evidence:**
  - E2.1 [M][S10] llama.cpp, 2× 3090, Qwen3.6-27B Q6_K_XL, layer split (on a Ryzen 9950X3D, PCIe 4.0 x16): **22.8 tok/s** decode.
  - E2.2 [M][S5] vLLM TP=2, 2× 3090, Qwen3.6-27B AWQ INT4 + MTP(2): **~100 tok/s**.
    - Note: the quants and model versions differ from E2.1. The comparison is directional, not apples-to-apples.
  - E2.3 [M][S1] vLLM TP=2, 2× 3090 on PCIe 3.0 x16, Qwen3.8-27B W4A16 + DFlash speculation: **167–180 tok/s** single-stream decode and **1,570 tok/s** cold prefill (8K prompt).
  - E2.4 [M][S1] Prefix caching on the same rig: a 100K-token prompt took **86.7 s cold and 1.07 s warm**. An OpenCode tool follow-up took 0.63 s with 15.7K cached tokens.
  - E2.5 [M][S2] vLLM TP=2, 2× 3090, Qwen3.8-27B AWQ INT4, MTP off: aggregate decode of **67 / 139 / 237 / 330 tok/s** at 1 / 2 / 4 / 6 concurrent streams.
  - E2.6 [S24] `--scheduling-policy priority` plus a per-request `priority` field (lower value = served first).
  - E2.7 [S21] vLLM implements the Anthropic Messages API, so Claude Code can use it as a backend.
  - E2.8 [K] Ollama's API has no built-in authentication.
- **Engine comparison** (cells not tied to a source are `[K]`/`[J]`):

  | Need | vLLM | llama.cpp / ik_llama | Ollama | SGLang | ExLlamaV3 / TabbyAPI |
  |---|---|---|---|---|---|
  | Both GPUs' bandwidth on one stream (TP) | Yes [S1][S2] | Layer split is sequential [S10] | Layer split | Yes | Yes |
  | Continuous batching | Yes | Limited | Limited | Yes | Yes |
  | Prefix caching | Yes [S1] | Partial | Partial | Yes (radix) | Partial |
  | Priority scheduling | Yes [S24] | No | No | Yes [K] | No [K] |
  | API auth | Yes | Yes | **No** [K] | Yes | Yes |
  | 2×3090 recipes found | Several [S1][S2][S5][S7] | Several [S7][S10] | Few | Some [S6] | Some [S6] |

- **Alternatives rejected:**

  | Alternative | Why rejected |
  |---|---|
  | llama.cpp | Its key advantage, CPU/MoE offload, is moot under C4. Layer split doesn't add decode speed. |
  | Ollama | No auth, weaker multi-GPU and concurrency support |
  | SGLang | Closest alternative; fewer 3090-specific recipes found [J] |
  | ExLlamaV3 | Smaller ecosystem; support for Qwen3.8's hybrid architecture unverified (U12) |

- **Risks:**
  - vLLM is CPU- and Python-heavy (C3).
  - Startup takes minutes (CUDA graph capture).
  - Frequent releases sometimes break features. club-3090 reports upstream bugs with Qwen 3.8 draft models under sustained multi-turn traffic [S7].
- **Verify by:**
  - Benchmark with the §5.3 command.
  - Check that `NCCL_DEBUG=INFO` logs show the expected transport.

### D3. Model: Qwen3.8-27B, AWQ INT4, with MTP

- **Decision:**
  - Model: `cyankiwi/Qwen3.8-27B-AWQ-INT4`, about 21.0 GB, with AWQ 4-bit weights and the Gated-DeltaNet layers kept in BF16 [S2].
  - Speculative decoding: built-in MTP with `num_speculative_tokens=2`.
  - KV cache: BF16 (`--kv-cache-dtype auto`).
  - One model serves both personas, distinguished by `enable_thinking`.
- **Satisfies:** R1, R2, R4, R6
- **Model facts:**
  - Dense, 27.8B parameters, released 2026-08-14 under Apache 2.0 [S4][S15].
  - 64 layers: 48 Gated-DeltaNet (linear attention) and 16 full attention [S4][S15].
  - Built-in MTP head [S15].
  - 262,144 tokens of native context, extendable to 1M [S4].
  - Image and video input [S15].
  - `enable_thinking` on/off and `reasoning_effort` levels xhigh / medium / low [S4].
- **Rationale:**
  - It's the strongest model that fits 48 GB entirely in VRAM with room for long context.
  - The hybrid attention gives a small KV cache, which makes long agent sessions feasible.
  - One shared model maximizes VRAM use (R4).
  - The stock (non-abliterated) model keeps its safety behaviour for guests.
- **Evidence:**
  - E3.1 [V][S14] Vendor scores:
    - SWE-bench Pro 61.7
    - Terminal-Bench 2.1 73.0
    - LiveCodeBench v6 90.3
    - GPQA Diamond 89.2
  - E3.2 [S14] The Qwen3.8 open-weight lineup jumps from 27B dense straight to a much larger MoE (Flash-Next), with no mid-size model.
    - Sources disagree on Flash-Next's size: 180B total per [S14] vs 125B total per [S26] (both 6B active). Either way it doesn't fit 48 GB.
  - E3.3 [E] KV cache per token, using 16 attention layers × 4 KV heads × 256 head dim (head geometry from [S11]) × 2 (K+V) × 2 bytes:
    - **64 KiB/token**, so ~8 GiB at 128K and ~16 GiB at 262K, plus a fixed per-sequence DeltaNet state.
    - For comparison, a conventional 32B model (64 layers × 8 KV heads × 128 dim [K]) needs ~256 KiB/token.
  - E3.4 [M][S8] Single-card vLLM running Qwen3.6-27B "hits a cliff at ~21–26K accumulated tokens" in agent use. club-3090 recommends two cards for extended sessions.
  - E3.5 [S2] This exact checkpoint was verified on 2× 3090 at TP=2 with 262K context.
  - E3.6 [M][S1] A comparable W4A16 quant (AutoRound) of Qwen3.8-27B showed perplexity **+0.29%** vs stock and GSM8K within noise.
    - Caveat: [S1] used an *abliterated* derivative.
  - E3.7 [E] Approximate VRAM budget at TP=2:
    - Weights take ~10.5 GB per card.
    - At `--gpu-memory-utilization 0.92`, ~22 GB per card is usable.
    - After weights and ~2–3 GB for CUDA graphs, activations, the MTP head and the vision encoder, ~8–9 GB per card remains for KV.
    - That's a ~17 GB pool in total: enough for one 262K session or several 32–64K sessions in BF16.
  - E3.8 [S7][S3] Formats that won't work on a 3090:
    - NVFP4 requires sm 9.0+.
    - The vLLM recipe states that MXFP4 checkpoints of this model don't load on NVIDIA devices.
  - E3.9 [S4] Recommended sampling:

    | Mode | Settings |
    |---|---|
    | Thinking | `temperature=1.0, top_p=0.95, top_k=20, presence_penalty=0` |
    | Non-thinking | `temperature=0.7, top_p=0.8, top_k=20, presence_penalty=1.5` |

- **Alternatives rejected:**

  | Alternative | Why rejected |
  |---|---|
  | `Qwen/Qwen3.8-27B-FP8` (~29 GB, weight-only FP8 via Marlin on Ampere) | **Fallback**: higher fidelity, but slower decode and about half the KV room (Q2) |
  | Qwen3.6-35B-A3B (MoE) | club-3090 reports its throughput "holds steady up to 16 streams, where the dense 27B's peaks at 2" [S7]. Weaker at agentic coding [J]. Kept as a "party mode" option. |
  | Gemma 4 31B | Ranked below Qwen3.8-27B for coding and agentic use in community guides [J] |
  | Any 100B+ model (Qwen3.5-122B-A10B, gpt-oss-120b, GLM, Devstral 2 123B) | Doesn't fit 48 GB at sane quantization; offload ruled out by C4 |
  | "Abliterated" variants | Refusals removed, which is unsuitable for guests (R2/R3 spirit) |

- **Risks:**
  - It's a community quant rather than an official one. Mitigations: inspect the repo for executable code and never pass `--trust-remote-code`.
  - 4-bit may increase tool-call or JSON errors on long agent runs, which is why FP8 is the fallback.
  - Vendor benchmarks may overstate real-world performance.
- **Verify by:**
  - Run a real multi-hour OpenCode session and track tool-call failure rate.
  - A/B against FP8 on the same tasks.

### D4. GPU topology: one shared TP=2 instance for both use cases

- **Decision:**
  - A single vLLM instance spans both GPUs (TP=2).
  - Coding and guest traffic share it, separated at the gateway (D5) and by priority scheduling (coding `priority=0`, guests `priority=10`).
- **Satisfies:** R1, R4. Its impact on R3 is argued in §4.
- **Rationale:**
  - The coding capability lives in the *harness*, not the inference server (SEC-1 in §4). Dedicating a GPU to guests therefore adds no protection for R3.
  - It would also idle half the VRAM most of the time (A7).
  - TP=2 gives the coding agent the KV headroom it needs (E3.4).
- **Evidence:** E2.3, E2.5, E3.4.
- **Counter-evidence (reviewer: weigh this carefully):**
  - E4.1 [M][S9] On older platforms, TP=2 takes a large penalty. A Xeon Gold 6138 on PCIe Gen 3 measured **32 / 41 TPS** against **89 / 117 TPS** for a Ryzen 5950X on Gen 4 with the same config. [S9] also estimates a 30–40% Gen 3 penalty for TP. The owner's Haswell plus x8 lanes may be worse still.
  - E4.2 [S7] "Single-stream generation barely uses the second card; one card is often the better deal."
  - E4.3 [M][S11] A single-3090 optimized vLLM fork reports ~127 tok/s single-user for Qwen3.8-27B with 150K–262K context. This relies on custom patches and requantization.
- **Alternatives:**

  | Alternative | Assessment |
  |---|---|
  | **Split:** coder on GPU 0, guest model on GPU 1 | Isolates load (guests can't slow coding), but halves the coder's KV room and wastes GPU 1 when there are no guests. Fallback #3. |
  | **Pipeline parallel:** `--pipeline-parallel-size 2` | Far less inter-GPU traffic than TP. No single-stream speedup, but keeps 48 GB for context. vLLM support for PP with this hybrid architecture is unverified (U9). Fallback #2. |

- **Risks:**
  - TP=2 may underperform on this platform; this is the biggest technical risk in the proposal.
  - A long prefill (e.g. a large file sent to the agent) can stall other streams [S7].
- **Verify by:**
  - Benchmark TP=2 against a single card on the actual hardware (§5.3) before committing.

### D5. Gateway: LiteLLM behind Caddy

- **Decision:**
  - **LiteLLM** (official Docker image, pinned by digest, with Postgres) is the policy layer between all clients and vLLM.
  - **Caddy** is the only ingress.
- **Satisfies:** R3 (defense in depth), R2 (guest rate limits), R1 (priority for coding)
- **Rationale:**
  - vLLM supports a single API key and has no per-client policy [K] (U4). LiteLLM adds:
    - **Separate, revocable virtual keys** for the guest UI, the personal UI and the workstation harness.
    - **Per-key model allow-lists**: the guest key can call only the `guest-chat` alias.
    - **Per-alias server-side defaults**: `guest-chat` gets thinking off, a `max_tokens` cap and `priority: 10`; `coder` gets `priority: 0`.
    - **Guest rate limits** (`rpm_limit`, `max_parallel_requests`).
    - Usage logs.
  - Caddy:
    - Publishes the only host ports, bound to the LAN IP.
    - Terminates TLS.
    - Applies a **`remote_ip` allow-list** to the API and personal hostnames. Without it, a guest could reach those virtual hosts on the same IP:443 by changing the Host header.
    - Returns 403 for `/api/v1/utils/code/*` on the guest host (CVE-2026-45672 mitigation [S16]).
- **Evidence:**
  - E5.1 [S19][S20] LiteLLM PyPI releases 1.82.7 and 1.82.8 were trojanized on 2026-03-24 (the TeamPCP campaign). The **official Docker image was not affected** because it pins dependencies.
- **Alternatives rejected:**

  | Alternative | Assessment |
  |---|---|
  | Clients connect directly to vLLM's single key | Leaner, but no key separation or enforced rate limits. Kept as the fallback if CPU is the bottleneck (Q3). |
  | nginx or Traefik instead of Caddy | Equivalent; Caddy chosen for simpler TLS [J] |

- **Risks:**
  - LiteLLM's admin API and UI listen on the same port the guest UI uses (see T7).
  - Parameter defaults are *soft*: a client that sends its own `priority` may override them (U6).
  - Postgres adds RAM and CPU load.
- **Verify by:**
  - The guest key gets 401/403 when it calls `coder`.
  - Requests to the API hostname from guest Wi-Fi get 403.

### D6. Coding harness: OpenCode on the owner's workstation

- **Decision:** OpenCode, configured with an OpenAI-compatible provider pointed at the LiteLLM `coder` alias, with restrictive permissions.
- **Satisfies:** R1, R3
- **Rationale:**
  - Open source and provider-agnostic.
  - Used in published dual-3090 vLLM + Qwen recipes [S5][S1].
  - Granular **allow / ask / deny** permissions per tool and per bash command pattern, with the last match winning [S23]. This is the main defense against prompt injection.
- **Evidence:**
  - E6.1 [S23] Permission keys:
    - `read`, `edit`, `glob`, `grep`, `bash`, `task`, `skill`, `lsp`, `question`
    - `webfetch`, `websearch`, `external_directory`, `doom_loop`
  - E6.2 [S5] A working OpenCode provider config against vLLM TP=2 on 2× 3090.
- **Alternatives:**

  | Alternative | Assessment |
  |---|---|
  | Qwen Code | Prompts aligned with Qwen's tool format. **Fallback** if OpenCode's tool calling is unreliable. |
  | Claude Code via `/v1/messages` [S21] | Polished, but tuned for Claude models. vLLM has an open RFC on hardening this endpoint for other model families [S22]. |
  | Aider | Better suited to pair-programming diffs than autonomous agent work |

- **Operating rules:**
  - Run it where the code lives (workstation, WSL2, a devcontainer or a VM), **never** on the LLM server.
  - Set `bash: ask` by default, allow read-only commands, deny destructive ones, and set `webfetch: ask`.
  - Keep homelab configs in git; the agent proposes changes and the owner applies them.
  - Give the agent a dedicated, least-privilege SSH key when needed.
- **Risks:**
  - Prompt injection from repo files, web pages or homelab outputs.
  - The approval fatigue that `ask` mode causes.
- **Verify by:**
  - Plant a prompt-injection string in a test repo and confirm the agent can't run unapproved commands.

### D7. Chat UI: Open WebUI, two isolated instances

- **Decision:**
  - **`webui-guest`**: hardened. It sits on the internal `guest` network with no egress, can reach only LiteLLM, and holds only a guest-scoped key.
  - **`webui-personal`** (optional): on the trusted network only.
- **Satisfies:** R2, R3
- **Rationale:**
  - Open WebUI is the most capable self-hosted chat UI: multi-user accounts, presets, image upload and temporary chats.
  - Its 2026 security record shows that **in-app permissions are not a security boundary**. A separate instance means a compromised guest UI exposes nothing of the owner's.
- **Evidence:**
  - E7.1 [S16] **CVE-2026-45672** (CVSS 8.8, fixed in 0.8.12): any verified user could run arbitrary Python via `/api/v1/utils/code/execute`, *even with `ENABLE_CODE_EXECUTION=false`*.
  - E7.2 [S17] **CVE-2026-87995** (CVSS 8.7, affects 0.8.11–0.11.0, fixed in 0.11.1): same-origin XSS leading to account takeover via the terminal PortPreview.
  - E7.3 [S18] **CVE-2025-64496** (fixed in 0.6.35): Direct Connections allowed token theft, escalating to RCE via Functions.
  - E7.4 [S25] v0.11.4 was released 2026-09-25.
- **Guest hardening:**
  - Settings and environment:
    - `ENABLE_PERSISTENT_CONFIG=false`, so env stays authoritative.
    - Signup off, or set to `pending`.
    - Disable: Ollama API, Direct Connections, code execution and interpreter, web search, image generation, community sharing, and API keys.
    - `OFFLINE_MODE=true`.
  - User permissions:
    - Disable tools/functions, file upload and chat controls.
    - **Enforce Temporary Chat**.
  - Accounts:
    - Use one shared guest account with the *user* role.
    - **Never `WEBUI_AUTH=False`**, which makes every visitor an admin [K].
  - Content: one preset ("House AI") with a family-friendly system prompt.
  - Operations: stop the container when not hosting guests.
- **Alternatives:** none evaluated in depth. Q4 asks whether a smaller-attack-surface guest UI would be better.
- **Risks:**
  - Environment-variable and permission names are from general knowledge and may differ in v0.11.x (U5).
  - The embedding model may fail to load offline (U11).
- **Verify by:**
  - Log in as the guest and attempt code execution, tool use and file upload; all should fail.
  - `curl` the code-execute endpoint through Caddy and confirm a 403.

### D8. Hardware tuning

- **Decision:**
  - GPU power limit of 275 W per card at boot (systemd), then step down to 250 W and 225 W while measuring.
  - CPU governor `performance`; optional overclock to 4.2–4.4 GHz.
  - Display on the iGPU, or headless.
  - PCIe slots set explicitly to Gen3 in BIOS.
  - Check whether P2P is reported, then run on the stock driver with `NCCL_P2P_DISABLE=1` and `--disable-custom-all-reduce`.
- **Satisfies:** R4; mitigates C3 and C7.
- **Evidence:**
  - E8.1 [M][S1] Decode power curve on 2× 3090, Qwen3.8-27B:

    | Power per card | Decode |
    |---|---|
    | 175 W | 154.9 tok/s (best energy efficiency) |
    | 225 W | 180.3 tok/s (~95% of ceiling) |
    | 350–400 W | 189.0 tok/s (ceiling) |

  - E8.2 [S12][S13] The P2P driver patch:
    - Gives 10–30%+ throughput.
    - Requires Resizable BAR with BAR1 covering all of VRAM, and IOMMU in passthrough mode.
    - Z87 lacks official ReBAR (C6), so it's not pursued.
  - E8.3 [S9] With P2P absent, the club-3090 default is `--disable-custom-all-reduce` and `NCCL_P2P_DISABLE=1`.
  - E8.4 [K] A 4670K on a Maximus VI Hero commonly overclocks to 4.2–4.4 GHz with adequate cooling.
- **Risks:**
  - Overclocking stability.
  - Prefill is more sensitive to the power cap than decode.
- **Verify by:**
  - `nvidia-smi -q` shows PCIe Gen3 x8 on both cards and the power limit applied.
  - `nvidia-smi topo -p2p r` shows the P2P status.

---

## 4. Security design

### 4.1 Central claim (reviewer: try to break this)

> **SEC-1.** An inference server with no tools configured only maps prompts to completions. It cannot read files, run commands or open connections on a user's behalf. "Coding capabilities" exist only in the harness (D6), which runs on the owner's workstation. Therefore R3 is satisfied if:
> - (a) guests cannot reach the workstation;
> - (b) guests cannot reach any endpoint other than the guest UI;
> - (c) a fully compromised guest UI yields nothing beyond a rate-limited, guest-scoped model key.

### 4.2 Trust zones

| Zone | Contents | Can reach |
|---|---|---|
| Guest VLAN | Guests' devices | Server :443, guest hostname only (router rule + Caddy) |
| `guest` Docker network | `webui-guest` | LiteLLM, Caddy. No internet. |
| `inference` network | vLLM | LiteLLM only. No internet. |
| Trusted VLAN / Tailscale | Owner's devices, workstation, harness | All Caddy hostnames, SSH |

### 4.3 Threat model

| ID | Threat | Vector | Mitigation | Residual risk |
|---|---|---|---|---|
| T1 | Guest reaches coding capabilities | Network path to the workstation or harness | Harness only on the workstation (D6). Guest VLAN blocked from the LAN (A2). | Depends on correct router rules |
| T2 | Guest compromises the guest UI | An Open WebUI vulnerability (E7.1–E7.3 show this happens) | Separate instance; no egress; guest-scoped key only; no Docker socket or host mounts; Caddy blocks the code-exec path; patch promptly; stop when unused | Attacker gets code execution in a container that can only reach LiteLLM and Caddy |
| T3 | Guest reaches the API or personal UI on the same IP:443 | Host-header switching | Caddy `remote_ip` allow-list. Docker subnets must **not** be in the allow-list. | Low |
| T4 | Guests starve coding performance | Many or long guest requests | vLLM priority scheduling, LiteLLM `max_parallel_requests` and `rpm_limit`, `max_tokens` cap | Long guest prefills can still briefly stall streams [S7] |
| T5 | Prompt injection into the coding agent | Malicious repo content, web pages, command outputs | OpenCode `ask` / `deny` rules; least-privilege SSH key; git-reviewed changes | Approval fatigue |
| T6 | Supply-chain compromise | Images, PyPI packages, model repos | Pin images by digest; official LiteLLM image (E5.1); no `--trust-remote-code`; `HF_HUB_OFFLINE=1`; inspect model repos | Compromise of upstream official images |
| T7 | Compromised guest container attacks LiteLLM's admin API | LiteLLM admin endpoints and UI on port 4000, reachable from the `guest` network | Strong master key; patch LiteLLM. **Consider** disabling the admin UI (U7), or a dedicated LiteLLM listener per network. | **Medium.** Reviewer: suggest a better design. |
| T8 | Cross-tenant leak via the shared prefix cache | Timing side channel on cached prefixes | Guest requests always start with the guest system prompt, so they never share a prefix with coder requests. Optional: per-alias `cache_salt` [K] (U8). | Low |
| T9 | SSRF from the guest UI | URL-fetch features in Open WebUI | No egress on `guest`; Caddy refuses Docker-subnet sources on trusted hosts | Low |
| T10 | Docker bypasses the host firewall | Docker-published ports bypass UFW [K] | Only Caddy publishes ports, bound to the LAN IP; enforce in `DOCKER-USER` or at the router | Low if implemented |
| T11 | Exposure beyond the LAN | Port forwarding | None configured; Tailscale/WireGuard only (A5) | Low |

### 4.4 Security checklist (to execute)

- [ ] Guest Wi-Fi on its own VLAN. Router allows guest → server:443 only; everything else from guest → LAN is denied.
- [ ] Only Caddy publishes ports, bound to the server's LAN IP. Host rules enforced in `DOCKER-USER` or at the router, not by UFW alone.
- [ ] Caddy `remote_ip` allow-list on the trusted hostnames: trusted subnet plus Tailscale `100.64.0.0/10`, and no Docker subnets.
- [ ] vLLM and `webui-guest` on `internal: true` networks.
- [ ] vLLM runs with `HF_HUB_OFFLINE=1` and no `--trust-remote-code`.
- [ ] SSH is key-only, reachable from the trusted VLAN only, with no root login.
- [ ] unattended-upgrades enabled.
- [ ] All images pinned by digest. Subscribe to Open WebUI, LiteLLM and vLLM security advisories.
- [ ] Acceptance test from a phone on guest Wi-Fi:
  - The guest UI loads.
  - The API host and personal host return 403.
  - SSH times out.
  - In the UI, code execution, tools and file upload are unavailable.

---

## 5. Performance expectations

### 5.1 Reference measurements (other rigs)

| Ref | Setup | Result | Source | How it differs from the owner's box |
|---|---|---|---|---|
| P1 | 2× 3090, TP=2, Qwen3.8-27B AWQ INT4, MTP off | 67 tok/s at 1 stream; 330 aggregate at 6 | [S2] | Platform unknown; GPU 0 at 350 W |
| P2 | 2× 3090, TP=2, Qwen3.6-27B AWQ + MTP(2) | ~100 tok/s | [S5] | Platform unknown; older model |
| P3 | 2× 3090, PCIe 3.0 **x16**, TP=2, Qwen3.8-27B W4A16 + DFlash | 167–180 tok/s decode; 1,570 tok/s prefill (8K) | [S1] | x16 vs x8; CPU unknown; DFlash rather than MTP |
| P4 | 1× 3090, HyperQwen (patched vLLM) | ~127 tok/s single-user | [S11] | Single card; custom patches |
| P5 | Xeon Gold 6138 + Gen 3 vs Ryzen 5950X + Gen 4, same dual config | 32 / 41 vs 89 / 117 TPS | [S9] | Shows the size of the platform penalty |

### 5.2 Estimate for the owner's box `[E]`, low confidence

| Metric | Estimate |
|---|---|
| Single-stream decode with MTP | **~40–80 tok/s** |
| Prefill | **~500–1,200 tok/s** |

Reasoning:

- Start from P1–P3.
- Discount for the Haswell CPU, x8 lanes and no P2P, using P5 as the guide.
- MTP roughly doubles single-stream speed relative to P1.

### 5.3 Verification plan

```bash
vllm bench serve --model qwen3.8-27b --dataset-name random --random-input-len 8000 --random-output-len 512 --max-concurrency 1
```

Run the benchmark under each of these conditions:

1. Concurrency 1 / 2 / 4.
2. Power limits of 275 / 250 / 225 W.
3. TP=2 vs a single card, with the same model at a reduced context.
4. MTP on vs off.

Record decode tok/s, time to first token and prefill tok/s.

### 5.4 Fallbacks (in order)

1. Tune the CPU: governor, overclock, fewer co-located services. Drop LiteLLM if the CPU is saturated (Q3).
2. Try `--pipeline-parallel-size 2` (U9).
3. Split the cards: coder on GPU 0 using a single-card-optimized setup [S11] or llama.cpp; a guest model on GPU 1.
4. Swap to Qwen3.6-35B-A3B if guest concurrency is the problem [S7].

---

## 6. Known uncertainties and unverified items

| ID | Item | Why uncertain | How to resolve |
|---|---|---|---|
| U1 | The i5-4670K lacks VT-d | [K], not re-verified | Intel ARK |
| U2 | Z87 / Maximus VI Hero lacks Resizable BAR; BAR1 size on the FTW3 Ultra VBIOS | [K] | Board BIOS notes; `nvidia-smi -q -d MEMORY` (BAR1) |
| U3 | Minimum driver branch for the vLLM v0.30 image (CUDA 12.9 vs 13.x) | Not checked | Image tags and release notes |
| U4 | Whether vLLM `--api-key` accepts multiple keys | [K] | vLLM CLI docs |
| U5 | Open WebUI v0.11.x env-var and permission names (`ENABLE_DIRECT_CONNECTIONS`, `ENABLE_CODE_INTERPRETER`, `ENABLE_API_KEY`, `OFFLINE_MODE`, `ENABLE_PERSISTENT_CONFIG`, "Enforce Temporary Chat") | [K]; the product moves fast | Open WebUI env docs for v0.11 |
| U6 | Whether LiteLLM `litellm_params.extra_body` passes `priority` and `chat_template_kwargs` to `hosted_vllm`; whether client values override; whether `max_parallel_requests` and `rpm_limit` are valid key fields; the official image tag naming | [K] | LiteLLM docs, plus a test request with vLLM request logging |
| U7 | How to disable the LiteLLM admin UI or restrict admin routes per network | [K] | LiteLLM docs |
| U8 | Whether vLLM supports a per-request `cache_salt` for prefix-cache isolation | [K] | vLLM docs |
| U9 | vLLM pipeline-parallel support for Qwen3.8's hybrid (Gated-DeltaNet) architecture | Not checked | vLLM supported-models docs or a test |
| U10 | **Source conflicts:** (a) tool parser `qwen3_xml` [S3] vs `qwen3_coder` [S5]; (b) MTP method name `mtp` [S5] vs `qwen3_5_mtp` [S3]; (c) `--mm-encoder-tp-mode weights` [S2] vs `data` [S5]; (d) Flash-Next size 180B [S14] vs 125B [S26]; (e) one guide [S27] claims 3090 P2P works over PCIe on the same root complex, while [S9][S12] say stock drivers disable it | Sources disagree | Test on the vLLM version deployed; `nvidia-smi topo -p2p r` |
| U11 | Whether Open WebUI starts cleanly in `OFFLINE_MODE` without a pre-downloaded RAG embedding model | [K] | Startup logs; disable document upload/RAG for guests |
| U12 | ExLlamaV3 and SGLang support for Qwen3.8-27B on Ampere | Not checked | Project docs |
| U13 | Whether the vLLM image and its PyTorch build run on Haswell (AVX2, no AVX-512) | [K]; believed fine | Start the container |

---

## 7. Open questions for the reviewer

| ID | Question |
|---|---|
| Q1 | Given E4.1–E4.3, should the **default** topology on a Haswell + PCIe 3.0 x8 platform be TP=2 (current), pipeline parallel, or one model per card? |
| Q2 | Is AWQ INT4 adequate for long agentic tool-calling sessions, or should FP8 (weight-only on Ampere) be the default despite the lower KV headroom? |
| Q3 | Is LiteLLM worth its CPU, RAM, Postgres and supply-chain cost here, versus the lean option (clients talk directly to vLLM through Caddy, with presets enforcing parameters)? |
| Q4 | Is there a guest-facing chat UI with a materially smaller attack surface than Open WebUI that still offers accounts or an access code, presets and image upload? |
| Q5 | Is the T7 residual risk (guest container can reach LiteLLM's admin surface) acceptable? What is the cleanest fix: a separate LiteLLM instance or listener for guests, a reverse-proxy path allow-list in front of LiteLLM, or something else? |
| Q6 | Could priority scheduling with preemption cause instability or poor guest UX (e.g. known bugs such as `n>1` crashes)? Should guest isolation rely on rate limits alone? |
| Q7 | Are there attack paths that SEC-1 misses, e.g. guest-supplied content later reaching the owner's agent through any shared state? |
| Q8 | Is MTP with `num_speculative_tokens=2` the right default given reported Qwen 3.8 drafter bugs [S7], or should speculation start disabled? |
| Q9 | Is BF16 KV cache the right default, or is FP8 KV (used in [S5]) an acceptable trade for more concurrent context? |
| Q10 | Ubuntu Server 24.04 LTS or 26.04.1 LTS for a fresh install in Oct 2026? |

---

## 8. Implementation plan (with verification gates)

| Step | Action | Gate (must pass before the next step) |
|---|---|---|
| 1 | BIOS: update; iGPU as primary display; PCIe Gen3 explicit; optional CPU overclock | Stable under a stress test |
| 2 | Install Ubuntu Server (minimal + OpenSSH); SSH keys; unattended-upgrades; mount the 1 TB SSD at `/srv` | SSH key login works |
| 3 | NVIDIA 580 driver (open); persistence mode; power-limit unit (App. E) | `nvidia-smi` shows both GPUs, Gen3 x8 and 275 W |
| 4 | Docker CE + NVIDIA Container Toolkit; `data-root` on `/srv/docker` | GPU visible inside a test container |
| 5 | `hf download cyankiwi/Qwen3.8-27B-AWQ-INT4 --local-dir /srv/models/Qwen3.8-27B-AWQ-INT4`; inspect for `.py` files | Repo contains only weights and config |
| 6 | vLLM alone; benchmark per §5.3; tune | Meets §5.2 or triggers a §5.4 fallback |
| 7 | LiteLLM + Postgres; create scoped keys (App. B) | Guest key refused on `coder` |
| 8 | OpenCode on the workstation (App. D); real coding session | Tool calls succeed; permissions prompt as expected |
| 9 | Caddy + `webui-guest`; VLAN and firewall rules | §4.4 acceptance test passes |
| 10 | Optional `webui-personal` | Reachable from trusted networks only |

---

## Appendix A: `compose.yaml` (unverified starting point)

Comments marked `UNVERIFIED (U#)` point to §6.

```yaml
name: llm

networks:
  edge: {}
  inference: { internal: true }
  guest:     { internal: true }
  trusted:   {}
  db:        { internal: true }

volumes:
  webui-guest-data: {}
  webui-personal-data: {}
  litellm-pg: {}
  caddy-data: {}

services:
  vllm:
    image: vllm/vllm-openai:v0.30.0        # pin by digest; driver requirement UNVERIFIED (U3)
    restart: unless-stopped
    networks: [inference]
    shm_size: 16gb
    environment:
      HF_HUB_OFFLINE: "1"
      NCCL_P2P_DISABLE: "1"                # stock GeForce driver: no PCIe P2P (E8.3)
      VLLM_API_KEY: ${VLLM_API_KEY}        # env-var form of --api-key: UNVERIFIED (U4)
    volumes:
      - /srv/models:/models:ro
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    command: >
      /models/Qwen3.8-27B-AWQ-INT4
      --served-model-name qwen3.8-27b
      --tensor-parallel-size 2
      --disable-custom-all-reduce
      --max-model-len 262144
      --gpu-memory-utilization 0.92
      --max-num-seqs 6
      --max-num-batched-tokens 4096
      --enable-prefix-caching
      --scheduling-policy priority
      --reasoning-parser qwen3
      --enable-auto-tool-choice --tool-call-parser qwen3_xml
      --speculative-config '{"method":"mtp","num_speculative_tokens":2}'
    # UNVERIFIED (U10): tool parser qwen3_xml vs qwen3_coder; MTP method "mtp" vs "qwen3_5_mtp".
    # If startup OOMs: lower --gpu-memory-utilization or --max-model-len, or add --mm-encoder-tp-mode weights.

  litellm-db:
    image: postgres:17-alpine              # pin by digest
    restart: unless-stopped
    networks: [db]
    environment:
      POSTGRES_USER: litellm
      POSTGRES_DB: litellm
      POSTGRES_PASSWORD: ${PG_PASSWORD}
    volumes:
      - litellm-pg:/var/lib/postgresql/data

  litellm:
    image: ghcr.io/berriai/litellm:main-stable   # official image; tag naming UNVERIFIED (U6); pin by digest
    restart: unless-stopped
    networks: [inference, guest, trusted, db]    # reachable from guest network: see T7 / Q5
    environment:
      LITELLM_MASTER_KEY: ${LITELLM_MASTER_KEY}
      DATABASE_URL: postgresql://litellm:${PG_PASSWORD}@litellm-db:5432/litellm
      VLLM_API_KEY: ${VLLM_API_KEY}
    volumes:
      - ./litellm.yaml:/app/config.yaml:ro
    command: ["--config", "/app/config.yaml", "--port", "4000"]
    depends_on: [litellm-db, vllm]

  webui-guest:
    image: ghcr.io/open-webui/open-webui:v0.11.4   # pin by digest; keep patched
    restart: unless-stopped
    networks: [guest]
    security_opt: ["no-new-privileges:true"]
    environment:                                   # env names UNVERIFIED for v0.11 (U5)
      WEBUI_SECRET_KEY: ${GUEST_WEBUI_SECRET}
      ENABLE_PERSISTENT_CONFIG: "false"
      ENABLE_SIGNUP: "false"
      DEFAULT_USER_ROLE: "pending"
      ENABLE_OLLAMA_API: "false"
      OPENAI_API_BASE_URL: "http://litellm:4000/v1"
      OPENAI_API_KEY: ${LITELLM_GUEST_KEY}
      ENABLE_DIRECT_CONNECTIONS: "false"
      ENABLE_CODE_EXECUTION: "false"
      ENABLE_CODE_INTERPRETER: "false"
      ENABLE_WEB_SEARCH: "false"
      ENABLE_IMAGE_GENERATION: "false"
      ENABLE_COMMUNITY_SHARING: "false"
      ENABLE_API_KEY: "false"
      OFFLINE_MODE: "true"                         # see U11
    volumes:
      - webui-guest-data:/app/backend/data
    # Then in Admin > Users > default permissions: disable tools/functions, file upload,
    # chat controls; enable "Enforce Temporary Chat".

  webui-personal:                           # optional
    image: ghcr.io/open-webui/open-webui:v0.11.4
    restart: unless-stopped
    networks: [trusted]
    environment:
      WEBUI_SECRET_KEY: ${PERSONAL_WEBUI_SECRET}
      ENABLE_SIGNUP: "false"
      ENABLE_OLLAMA_API: "false"
      OPENAI_API_BASE_URL: "http://litellm:4000/v1"
      OPENAI_API_KEY: ${LITELLM_PERSONAL_KEY}
    volumes:
      - webui-personal-data:/app/backend/data

  caddy:
    image: caddy:2                          # pin by digest; custom build if a DNS plugin is needed
    restart: unless-stopped
    networks: [edge, guest, trusted]
    ports:
      - "192.168.10.5:443:443"              # example LAN IP; bind to the server's LAN IP only
      - "192.168.10.5:80:80"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
```

## Appendix B: `litellm.yaml` and key creation (unverified, see U6)

```yaml
model_list:
  - model_name: coder
    litellm_params:
      model: hosted_vllm/qwen3.8-27b
      api_base: http://vllm:8000/v1
      api_key: os.environ/VLLM_API_KEY
      extra_body:
        priority: 0

  - model_name: guest-chat
    litellm_params:
      model: hosted_vllm/qwen3.8-27b
      api_base: http://vllm:8000/v1
      api_key: os.environ/VLLM_API_KEY
      max_tokens: 1536
      temperature: 0.7
      top_p: 0.8
      presence_penalty: 1.5
      extra_body:
        priority: 10
        top_k: 20
        chat_template_kwargs: { enable_thinking: false }

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
```

```bash
curl -s -X POST http://localhost:4000/key/generate -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" -d '{"key_alias":"guest-webui","models":["guest-chat"],"rpm_limit":30,"max_parallel_requests":3}'
```

```bash
curl -s -X POST http://localhost:4000/key/generate -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" -d '{"key_alias":"workstation-opencode","models":["coder"]}'
```

## Appendix C: `Caddyfile` (sketch)

```caddyfile
# Guests: the only host intended for them.
chat.example.home {
    @codeexec path /api/v1/utils/code/*
    respond @codeexec 403
    reverse_proxy webui-guest:8080
}

# Trusted-only hosts. Do NOT add Docker subnets to this list (T3, T9).
ai.example.home {
    @untrusted not remote_ip 192.168.10.0/24 100.64.0.0/10
    respond @untrusted 403
    reverse_proxy webui-personal:8080
}

llm-api.example.home {
    @untrusted not remote_ip 192.168.10.0/24 100.64.0.0/10
    respond @untrusted 403
    reverse_proxy litellm:4000
}
```

TLS options:

- **For guests:** use a real domain with a DNS-01 challenge (Caddy built with the DNS provider's plugin), so guests don't see certificate warnings.
- **For the owner's own devices:** `tls internal` is acceptable once Caddy's root CA is installed on them.

## Appendix D: OpenCode config (`~/.config/opencode/opencode.json` on the workstation)

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "homelab": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Homelab LLM",
      "options": {
        "baseURL": "https://llm-api.example.home/v1",
        "apiKey": "{env:HOMELAB_LLM_KEY}"
      },
      "models": {
        "coder": {
          "name": "Qwen3.8-27B (local)",
          "tools": true,
          "reasoning": true,
          "limit": { "context": 262144, "output": 32768 },
          "options": {
            "temperature": 1.0,
            "top_p": 0.95,
            "extraBody": {
              "top_k": 20,
              "chat_template_kwargs": { "enable_thinking": true }
            }
          }
        }
      }
    }
  },
  "model": "homelab/coder",
  "permission": {
    "edit": "ask",
    "webfetch": "ask",
    "bash": {
      "*": "ask",
      "git status*": "allow",
      "git diff*": "allow",
      "git log*": "allow",
      "ls *": "allow",
      "rg *": "allow",
      "rm *": "deny",
      "git push*": "deny"
    }
  }
}
```

## Appendix E: GPU power limit at boot (`/etc/systemd/system/gpu-power-limit.service`)

```ini
[Unit]
Description=Set RTX 3090 power limits
After=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pm 1
ExecStart=/usr/bin/nvidia-smi -pl 275

[Install]
WantedBy=multi-user.target
```

---

## Appendix F: Sources (all accessed 2026-10-01)

| ID | Source | Supports |
|---|---|---|
| S1 | [AnnoyingTechnology/nvidia-dual-3090-llm-inference](https://github.com/AnnoyingTechnology/nvidia-dual-3090-llm-inference) | E2.3, E2.4, E3.6, E8.1: Qwen3.8-27B on 2× 3090 with vLLM; power curve; prefix-cache timings |
| S2 | [vLLM recipes PR #971](https://github.com/vllm-project/recipes/pull/971) | E2.5, E3.5: AWQ INT4 checkpoint verified on 2× 3090, TP=2, 262K |
| S3 | [vLLM recipe: Qwen3.8-27B](https://recipes.vllm.ai/Qwen/Qwen3.8-27B) | Official flags, parsers, checkpoints; NVFP4 and MXFP4 notes |
| S4 | [Qwen/Qwen3.8-27B model card](https://huggingface.co/Qwen/Qwen3.8-27B) | Architecture, sampling, thinking control |
| S5 | [Dzombak: vLLM compose recipe, dual 3090 + OpenCode](https://www.dzombak.com/blog/2026/04/a-vllm-docker-compose-recipe-for-running-qwen-3-6-27b-on-dual-rtx-3090s-opencode-configuration/) | E2.2, E6.2 |
| S6 | [club-3090 README](https://github.com/noonghunna/club-3090) | Engine and model coverage for 1× and 2× 3090 |
| S7 | [club-3090 DUAL_CARD.md](https://github.com/noonghunna/club-3090/blob/master/docs/DUAL_CARD.md) | E4.2, MoE concurrency, prefill stalls, drafter bugs, NVFP4 sm 9.0+ |
| S8 | [club-3090 SINGLE_CARD.md](https://github.com/noonghunna/club-3090/blob/master/docs/SINGLE_CARD.md) | E3.4 |
| S9 | [club-3090 HARDWARE.md](https://github.com/noonghunna/club-3090/blob/master/docs/HARDWARE.md) | E4.1, E8.3, Gen3 penalty, CPU/RAM guidance |
| S10 | [sanj.dev: dual 3090 llama.cpp tuning](https://sanj.dev/post/qwen-3-6-27b-dual-rtx-3090-llama-cpp-tuning/) | E2.1 |
| S11 | [syv-ai/HyperQwen](https://github.com/syv-ai/qwen38-27b-rtx3090) | E4.3; head geometry for E3.3 |
| S12 | [smcleod.net: P2P on consumer GPUs](https://smcleod.net/2026/02/patching-nvidias-driver-and-vllm-to-enable-p2p-on-consumer-gpus/) | E8.2 |
| S13 | [aikitoria/open-gpu-kernel-modules](https://github.com/aikitoria/open-gpu-kernel-modules), [dingiv fork README](https://github.com/dingiv/open-gpu-kernel-modules) | P2P patch requirements (ReBAR, BAR1 size) |
| S14 | [Codersera: Qwen 3.8 lineup](https://codersera.com/blog/qwen-3-8-model-lineup-2026/) | E3.1, E3.2 |
| S15 | [Context Studios: Qwen 3.8 27B hardware guide](https://www.contextstudios.ai/blog/qwen-3-8-27b-hardware-guide) | Model facts, single-3090 numbers |
| S16 | [SentinelOne: CVE-2026-45672](https://www.sentinelone.com/vulnerability-database/cve-2026-45672/) | E7.1 |
| S17 | [HOL: CVE-2026-87995](https://hol.org/guard/security/cves/CVE-2026-87995-open-webui-same-origin-xss-to-account-takeover) | E7.2 |
| S18 | [Infosecurity Magazine: CVE-2025-64496](https://www.infosecurity-magazine.com/news/flaw-open-webui-affects-ai/) | E7.3 |
| S19 | [Datadog Security Labs: LiteLLM compromise](https://securitylabs.datadoghq.com/articles/litellm-compromised-pypi-teampcp-supply-chain-campaign/) | E5.1 |
| S20 | [Tetrate: Is LiteLLM safe?](https://tetrate.io/learn/ai/is-litellm-safe) | E5.1 (Docker image unaffected) |
| S21 | [vLLM docs: Claude Code integration](https://docs.vllm.ai/en/stable/serving/integrations/claude_code/) | E2.7 |
| S22 | [vLLM issue #58647](https://github.com/vllm-project/vllm/issues/58647) | D6 alternative risk |
| S23 | [OpenCode permissions docs](https://opencode.ai/docs/permissions/) | E6.1 |
| S24 | [vLLM forum: priority scheduling](https://discuss.vllm.ai/t/priority-in-batch-api/2376) | E2.6 |
| S25 | [Open WebUI release tracker](https://releasealert.dev/github/open-webui/open-webui) | E7.4 |
| S26 | [vLLM on X: Qwen3.8-Flash-Next day-0 support](https://x.com/vllm_project/status/2092600887873286157) | E3.2 (size conflict) |
| S27 | [runaihome: dual 3090 PCIe/IOMMU/NCCL guide](https://runaihome.com/blog/dual-rtx-3090-pcie-iommu-acs-nccl-guide-2026/) | U10(e), conflicting P2P claim |
| S28 | [vLLM releases](https://github.com/vllm-project/vllm/releases) | D2 version (v0.30.0, 2026-09-22) |
| S29 | [Linuxize: CUDA on Ubuntu 26.04](https://linuxize.com/post/how-to-install-nvidia-cuda-toolkit-on-ubuntu-26-04/) | E1.3 |

## Appendix G: Change log

| Version | Date | Changes |
|---|---|---|
| 1.0 | 2026-10-01 | Initial proposal |
| 1.1 | 2026-10-01 | Restructured for third-party review. Added reviewer instructions, requirements, constraints, assumptions, decision records with evidence labels, threat model, uncertainty register, open questions, verification gates and source IDs. **Content corrections:** (1) removed an unsupported claim that Gemma 4 31B has a "much heavier KV cache"; (2) corrected the NVFP4/MXFP4 note (NVFP4 needs sm 9.0+; the MXFP4 checkpoint doesn't load on NVIDIA per [S3]); (3) surfaced source conflicts as U10; (4) added threats T7 (LiteLLM admin surface reachable from the guest network), T8 (prefix-cache side channel) and T9 (SSRF) |
