# Skynet foundation: the part both proposals share

Both plans in `proposal plans/` (coding assistant, Home Assistant voice AI) run on the same base: Ubuntu 24.04, the NVIDIA 580 driver, Docker with the NVIDIA Container Toolkit, vLLM serving `Qwen3.8-27B-AWQ-INT4` across both RTX 3090s, and a LiteLLM gateway in front of it. This folder builds that base and benchmarks it, so the direction-specific services can be added on top later without redoing anything.

```
foundation/
├── skynet.conf              host settings (IP, LAN, driver, power limit, paths) - no secrets
├── scripts/                 run these in order on Skynet
│   ├── 01-update-system.sh
│   ├── 02-install-nvidia-driver.sh
│   ├── 03-install-docker.sh
│   ├── 04-install-nvidia-container-toolkit.sh
│   ├── 05-install-tuning.sh
│   ├── 06-configure-firewall.sh
│   └── 07-download-model.sh
├── systemd/                 units installed by the scripts
├── inference/               the Docker Compose stack: vLLM + LiteLLM
│   ├── compose.yaml
│   ├── .env.example         copy to .env, add secrets
│   ├── litellm.yaml         gateway aliases
│   └── vllm-profiles/       mtp-off.yaml, mtp-on.yaml
└── bench/                   benchmark scripts and results
```

Every script stops on the first error, says what it's doing, and checks its result. The ones that change the system need `sudo`; `07-download-model.sh` and the benchmarks run as your normal user.

---

## Before you start (manual steps)

### BIOS (once)

These come from both plans (coding D8 / house D10):

- Update the Maximus VI Hero BIOS to the latest release.
- Set the **iGPU as the primary display** (or run headless). Then neither 3090 spends VRAM or attention on a desktop.
- Set both PCIe x16 slots to **Gen3** explicitly instead of Auto. Auto sometimes trains a link at a lower speed.
- Optional: the 4.2–4.4 GHz CPU overclock. vLLM's scheduler is Python and runs on the CPU, so a faster CPU directly helps tokens per second on this box. Leave it for later if you'd rather keep things stock while testing.

### Mount the 1 TB SSD at `/srv`

Models (about 21 GB) and Docker images (vLLM's alone is about 9 GB) go on the 1 TB SSD, not the 256 GB system disk.

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL    # find the 1 TB disk, e.g. sdb
```

If it already has a filesystem with data you want, skip the `mkfs` line. **`mkfs` erases the disk.**

```bash
sudo mkfs.ext4 -L skynet-data /dev/sdX1        # ONLY if it's empty / you want it wiped
sudo mkdir -p /srv
echo "UUID=$(sudo blkid -s UUID -o value /dev/sdX1) /srv ext4 defaults,noatime 0 2" | sudo tee -a /etc/fstab
sudo mount -a && df -h /srv
sudo install -d -o "$USER" /srv/models
```

### Get this repo onto Skynet

```bash
sudo apt-get install -y git
git clone https://github.com/d-costeira/skynet.git ~/skynet
cd ~/skynet/foundation
```

### Check `skynet.conf`

It has `SKYNET_IP=192.168.4.31` and **assumes** your LAN is `192.168.4.0/24` (`LAN_SUBNET`). The firewall step only allows SSH from that range. If your router hands out addresses outside it, change `LAN_SUBNET` first.

---

## Step by step

### 1. Update the system — `sudo scripts/01-update-system.sh`

Runs `apt full-upgrade` (a normal `upgrade` holds back updates that need to add or remove packages, such as new kernels), removes leftovers, installs a few tools (`nvtop` for a live view of both GPUs, `htop`, `jq`), and turns on **unattended-upgrades** so security patches install by themselves.

If it reports that a reboot is required, **reboot before step 2**. The NVIDIA driver builds its kernel modules against the running kernel, so installing it just before a kernel change is a common way to end up with no driver after the next boot.

### 2. NVIDIA driver — `sudo scripts/02-install-nvidia-driver.sh`, then reboot

Installs `nvidia-headless-580-server-open` and `nvidia-utils-580-server`:

- **580 branch:** the vLLM v0.30.0 image is built on CUDA 13.0, which needs driver 580 or newer. The host doesn't need the CUDA toolkit; CUDA ships inside the container, and only the driver lives on the host.
- **server:** the long-lived branch Ubuntu keeps patched for servers.
- **open:** NVIDIA's open-source kernel modules. These are NVIDIA's recommended modules for Ampere (30-series) and newer.
- **headless:** skips the X/desktop libraries, which a server doesn't need.

It also enables `nvidia-persistenced`, which keeps the driver loaded between jobs, so the first request after idle doesn't pay the GPU initialisation cost.

After the reboot, `nvidia-smi` should list two `NVIDIA GeForce RTX 3090` with driver `580.x`.

### 3. Docker — `sudo scripts/03-install-docker.sh`

Installs Docker Engine and the Compose plugin from **Docker's own apt repository**, following Docker's Ubuntu guide. Ubuntu's `docker.io` package lags behind and doesn't ship the Compose v2 plugin the same way. It then moves Docker's data directory to `/srv/docker` (on the 1 TB SSD) and switches container logs to the `local` driver, which rotates logs instead of growing them forever.

It adds you to the `docker` group, so you can run `docker` without `sudo` (log out and back in first). Be aware that anyone in that group is effectively root on Skynet.

### 4. NVIDIA Container Toolkit — `sudo scripts/04-install-nvidia-container-toolkit.sh`

This is the piece that lets a container see the GPUs. Docker on its own knows nothing about NVIDIA devices. The toolkit adds an `nvidia` runtime that, when a container asks for GPUs (`--gpus all` or the `deploy.resources.devices` block in `compose.yaml`), mounts the GPU device files and the matching driver libraries from the host into the container.

The script follows NVIDIA's install guide exactly:

1. Adds NVIDIA's signed apt repository (the `signed-by=` keyring means apt trusts that key only for that repository).
2. Installs the four packages pinned to `1.20.1-1`, the version the guide currently pins, and puts them on `apt-mark hold` so unattended-upgrades can't move them without you noticing.
3. Runs `nvidia-ctk runtime configure --runtime=docker`, which writes the runtime into `/etc/docker/daemon.json`, then restarts Docker.
4. Runs NVIDIA's sample workload: `docker run --rm --gpus all ubuntu nvidia-smi`. If you see both GPUs in that output, containers can use them.

The guide also mentions a known issue where containers can lose GPU access after `systemctl daemon-reload` on systems using the systemd cgroup driver. If vLLM ever starts failing with "no CUDA devices" after you installed or edited a unit, restart the container.

### 5. Power limit and CPU governor — `sudo scripts/05-install-tuning.sh`

- **GPU power limit, 275 W per card at every boot** (`gpu-power-limit.service`). The FTW3 Ultras can draw 420 W+ each, with short spikes well above that, on a 1000 W PSU. The plans' cited measurements show decode at 225 W is about 95% of the uncapped speed. The value lives in `/etc/default/gpu-power-limit`. The benchmark tries 275 / 250 / 225 W, so you can choose with real numbers.
- **CPU governor `performance`** (`cpu-governor-performance.service`). It keeps the 4670K at full clock instead of ramping up on demand, which helps vLLM's CPU-side scheduling. The cost is somewhat higher idle power. Disable it with `sudo systemctl disable --now cpu-governor-performance` if you'd rather save power.

The check at the end prints each card's PCIe link. **At idle the cards drop to a lower PCIe speed to save power**, so if it shows gen 1, check again while vLLM is busy. Under load, expect gen 3, width 8 on both.

### 6. Firewall and SSH hardening — `sudo scripts/06-configure-firewall.sh`

Before changing anything, it checks that you have an SSH key installed and that your current SSH session comes from inside `LAN_SUBNET`, and asks for confirmation. Then:

- **SSH:** password login and root login are turned off (keys only).
- **UFW:** all inbound traffic is denied except SSH from `LAN_SUBNET`. Nothing else on Skynet is reachable from the network yet: the inference stack is deliberately bound to `127.0.0.1`.
- **Container egress block** (`docker-egress-block.service`). Docker-published ports bypass UFW, because Docker writes its own iptables rules, and containers on a normal Docker network can reach the internet. This adds a rule to Docker's `DOCKER-USER` chain that drops any **new** outbound connection started by a container on the gateway network. Replies to connections made *to* the container still work. vLLM sits on an `internal` network and has no route out at all. Image pulls are done by the Docker daemon on the host, so they aren't affected.

**Keep your SSH session open and test a fresh login from a second terminal before you log out.**

### 7. Download the model — `scripts/07-download-model.sh` (no sudo)

Downloads `cyankiwi/Qwen3.8-27B-AWQ-INT4` (about 21 GB) to `/srv/models` from inside the pinned vLLM image, which already ships the Hugging Face library, so nothing gets installed on the host. Then it lists the files and warns if any could contain code (`.py`, `.so`, pickles). We never pass `--trust-remote-code`, so such files wouldn't run, but it's worth knowing what's there.

---

## The inference stack

```bash
cd ~/skynet/foundation/inference
cp .env.example .env && chmod 600 .env
# Fill in two secrets:
#   VLLM_API_KEY=<openssl rand -hex 32>
#   LITELLM_MASTER_KEY=sk-<openssl rand -hex 32>
docker compose up -d
docker compose logs -f vllm        # first start takes several minutes
```

**What runs:**

| Container | Network | Reachable from | Purpose |
|---|---|---|---|
| `vllm` | `inference` (internal) | LiteLLM only | Qwen3.8-27B on both GPUs, tensor-parallel (TP=2) |
| `litellm` | `inference` + `gateway` | `127.0.0.1:4000` on Skynet | Gateway with two aliases, `think` and `fast` |

**Why vLLM takes minutes to start:** it loads about 10.5 GB of weights onto each card over SATA and PCIe 3.0, then profiles memory and captures CUDA graphs (pre-recorded GPU work for common batch sizes, which makes each decode step cheaper). Compose waits for vLLM's `/health` before starting LiteLLM.

**Why the two aliases:** both plans use one model with different behaviour per client. Here, `think` has thinking on and priority 0 (served first). `fast` has thinking off, priority 10 and a 1,536-token reply cap. The coding plan would rename these `coder` and `guest-chat`, the house plan `house` and `sage`.

**Trying it from Skynet:**

```bash
source .env
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"fast","messages":[{"role":"user","content":"Say hello in five words."}]}' | jq .
```

**From your workstation**, through an SSH tunnel (no port is opened on the LAN):

```bash
ssh -L 4000:127.0.0.1:4000 <you>@192.168.4.31
# then use http://127.0.0.1:4000/v1 with the LiteLLM key, from any OpenAI-compatible client
```

**Settings you can change in `.env`** (then `docker compose up -d`):

| Variable | Default | Notes |
|---|---|---|
| `VLLM_PROFILE` | `mtp-off` | `mtp-off` or `mtp-on` (files in `vllm-profiles/`) |
| `GPU_MEMORY_UTILIZATION` | `0.92` | Coding plan 0.92; house plan 0.78, leaving about 5 GB per card for speech models |
| `MAX_MODEL_LEN` | `262144` | Coding plan 262144; house plan 65536 |

If vLLM runs out of memory at startup, lower `MAX_MODEL_LEN` first, then `GPU_MEMORY_UTILIZATION`.

---

## Benchmarks: MTP on vs off

**The question:** the two plans disagree. The coding plan turns on MTP (Qwen3.8's built-in multi-token prediction: a small head drafts 2 tokens ahead and the main model verifies them in one pass, which speeds up single-stream replies) *and* relies on prefix caching. The house plan turns MTP off, because its source says MTP disables prefix caching.

Prefix caching is what makes repeat requests fast: an agent resending its history, or Home Assistant resending its system prompt and entity list every time. If MTP silently turns it off, every request pays the full prompt cost again.

Reading the vLLM v0.30.0 source, I found no code that turns prefix caching off when MTP is on, and v0.30 has an option built specifically around MTP and prefix caching working together. That suggests the house plan's source (which used an older vLLM) is out of date, but only a measurement on Skynet settles it.

**Run the full matrix** (both profiles × 275 / 250 / 225 W; it restarts vLLM once per profile and asks for sudo to change the power limit):

```bash
cd ~/skynet/foundation/bench
./run-matrix.sh
```

Or benchmark only what's running now: `./run-benchmarks.sh`.

**What it measures**, saved under `bench/results/<time>-<profile>-<watts>W/`:

- `prefix-cache.json`: sends the same ~8K-token prompt twice and reports time to first token for both requests, plus vLLM's own prefix-cache counters for the second one. **A warm hit rate near 1.0 and a warm TTFT far below the cold one means prefix caching works with that profile.** With MTP on, it also reports how many drafted tokens were accepted.
- `serve-c1/2/4.json`: `vllm bench serve` with 8,000-token prompts and 512-token replies at 1, 2 and 4 concurrent requests. Key numbers are output tokens/s (throughput), TTFT (wait before the first token) and TPOT (time per output token after that).
- `meta.txt`: profile, power limit, PCIe link and driver, so results stay comparable.

`python3 summarize.py results/*/` prints everything as one table. **Commit and push the `results/` folder**, and I can analyse it for you.

**Gateway check:** `./check-gateway.sh` tests whether LiteLLM really applies the per-alias thinking setting, and whether a client can override it. Both plans list this as unverified, and it matters before any untrusted client (guests, or a voice agent) talks to the gateway.

---

## What was verified, and what wasn't

Checked while writing this (2026-10-16):

- vLLM v0.30.0 image tag and digest exist on Docker Hub; built on CUDA 13.0.3, so driver 580 is the right minimum.
- In the vLLM v0.30.0 source: every flag used in `vllm-profiles/` exists; `qwen3_xml` and `qwen3_coder` are the same tool parser; `--mamba-cache-mode align` is the default once prefix caching is on; MTP method name `mtp` is accepted; `VLLM_API_KEY` is read from the environment, and the API key option accepts several keys; `/health` and `/metrics` need no key.
- LiteLLM `main-v1.83.14-stable` digest from GHCR.
- NVIDIA Container Toolkit commands from NVIDIA's guide (version `1.20.1-1`).
- Ubuntu 24.04 package names for the 580 server/open driver (`580.178.04` at the time of writing).
- `compose.yaml` passes `docker compose config`; shell scripts pass `shellcheck`.

**Not yet run on real hardware.** Expect to adjust things when it meets Skynet: the VRAM settings, and whether LiteLLM passes `priority` / `chat_template_kwargs` through.

## Not in this folder yet

- Single-card vs TP=2 comparison (both plans want it; needs a reduced context to fit on one card).
- Direction-specific services: Caddy, Open WebUI and OpenCode (coding), or Whisper, Piper, Home Assistant wiring and the Wiki MCP (house).
- Monitoring and backups.
