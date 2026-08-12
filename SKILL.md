---
name: gpu-server-setup
version: 0.2.1
description: >
  Prepare a Linux server with NVIDIA GPUs for neural-network and LLM workloads,
  or diagnose one that misbehaves. Use when the user asks to set up or prepare a
  GPU server, install NVIDIA drivers or CUDA on Debian/Ubuntu, wire Docker to
  GPUs (NVIDIA Container Toolkit), deploy vLLM / Infinity / OpenWebUI / Ollama /
  llama.cpp, set or persist a GPU power limit / power cap (nvidia-smi -pl), or
  fix "container does not see GPU", "Driver/library version mismatch", "could
  not select device driver nvidia". Installs everything from one package source
  (the official CUDA apt repo) and verifies every layer with a hard gate before
  the next; the mandatory deliverable is Docker with a working NVIDIA runtime,
  serving stacks are optional presets on top.
metadata:
  author: Pavel Rykov <paul@drteam.rocks>
  homepage: https://github.com/EvilFreelancer/gpu-server-setup
  triggers: >
    gpu server, nvidia driver, cuda, cuda-keyring, nvidia-smi, docker gpu,
    nvidia-container-toolkit, nvidia-ctk, gpus all, vllm, ollama, llama.cpp,
    openwebui, infinity embeddings, power limit, power cap, nvidia-smi -pl,
    ограничить мощность GPU, энергопотребление видеокарты, настроить GPU сервер,
    driver library version mismatch, could not select device driver
---

# GPU server setup

Turn a bare **Debian/Ubuntu** server with NVIDIA GPUs into a verified inference
box: driver → Docker → GPU runtime, plus an optional serving stack on top. The
skill encodes one field-tested path and the discipline around it, so you
assemble a working server instead of improvising package sources.

Scope: **Debian 10–13, Ubuntu 20.04–24.04, x86_64, NVIDIA only.** No Windows/
WSL, no RHEL-family, no AMD/ROCm, no Kubernetes. If the user is outside this
scope, say so instead of adapting on the fly.

## Core principle

**One package source, and a hard gate after every layer.** Each layer is proven
working before the next one starts; a failing gate stops the flow — fix it via
`references/troubleshooting.md`, re-run the gate, only then continue. Most
"GPU server is broken" situations are a skipped gate or a second package source.

**The mandatory deliverable is the verified Docker + NVIDIA base** — the stage-2
gate (`docker run … nvidia-smi` sees every GPU). Serving stacks — vLLM, Ollama,
llama.cpp, Infinity, OpenWebUI — are optional add-ons: deploy one only when the
user asked for it. A pass that ends at a proven stage-2 gate with no stack is a
complete, successful Prepare, not an unfinished one.

## Three modes

| Mode | Trigger | What you produce |
|------|---------|------------------|
| **Prepare** | clean/fresh server to set up | stages 0→2 always; 3 only if a stack was requested; 4 always |
| **Deploy** | driver/Docker already fine, add a stack | stages 3→4 on top of a verified base |
| **Diagnose** | "X does not work / does not see GPU" | layer-by-layer audit, fix, re-gate |

Standalone requests on an already-working server (cap the power limit, add
monitoring) are valid tasks of their own — no full pass, just the live-server
rules plus the matching reference (see "On-request extras").

With shell access to the server, **detect facts instead of asking**. Without
access, produce the full instruction with `<PLACEHOLDERS>` and a fill-in list.

## Workflow

1. **Gather facts (gap checklist).** OS and version (`cat /etc/os-release`),
   GPUs (`lspci | grep -E "VGA|3D|NVIDIA"`), disk (`df -h /`), Secure Boot
   (`mokutil --sb-state`), whether a serving stack is wanted at all and which
   ("none" is a valid answer — the base alone is a complete result), which
   models, single- or multi-GPU, network exposure (open network or closed).
   Ask only what you cannot detect.
2. **Pick the mode.** For Diagnose jump straight to the 3-layer checklist in
   `references/troubleshooting.md` and fix the **lowest** failing layer first.
3. **Stage 0 — base system.**
   ```bash
   sudo apt update && sudo apt -y upgrade
   sudo apt -y install mc ca-certificates curl gnupg lsb-release wget jq
   sudo reboot   # matters when the upgrade touched kernel/libc; skip on an already-current box
   ```
4. **Stage 1 — NVIDIA driver (+ CUDA toolkit only if the host compiles).**
   Follow `references/nvidia-cuda.md`: add the CUDA repo via `cuda-keyring`
   for the exact `$distro/$arch`, install kernel headers, then the driver —
   open kernel modules for Turing and newer (`nvidia-open` /
   `nvidia-driver-XXX-open`; mandatory for the newest generations),
   proprietary for Pascal and older. Docker-only hosts need **no** CUDA toolkit.
   Reboot. **GATE: `nvidia-smi` lists every physical GPU.**
5. **Stage 2 — Docker + NVIDIA Container Toolkit.**
   Follow `references/docker-nvidia.md`: remove legacy docker packages, install
   Docker CE from the official repo, install `nvidia-container-toolkit`, then
   `sudo nvidia-ctk runtime configure --runtime=docker` and
   `sudo systemctl restart docker` (both mandatory).
   **GATE: `docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi`
   shows the same GPUs as the host.**
6. **Stage 3 — serving stack (optional, only when requested).** Skip straight
   to stage 4 when the user wants just the base. One service per folder under
   `/srv`, one GPU pin per service (`device_ids`). Start from `presets/` —
   `vllm.md`, `infinity.md`, `openwebui.md`, `ollama.md` — and adapt: model,
   GPU ids, ports, memory budget. For a stack without a preset (e.g. llama.cpp
   via its official `ghcr.io/ggml-org/llama.cpp:server-cuda` image) apply the
   same rules: pinned tag, explicit GPU grant, one service per folder. Presets
   are working configs, not copy-paste blanks: fill every `<PLACEHOLDER>`,
   keep image tags pinned, telemetry off, logs capped. **GATE: health endpoint
   answers AND a real request returns a sane response** (`/v1/models`, then
   one chat/embedding call).
7. **Stage 4 — verify and hand over.** Run the full check — base form for a
   docker-only pass, health URLs appended when stacks were deployed:
   ```bash
   bash scripts/check.sh                                  # base: host + docker
   bash scripts/check.sh http://<SERVER_IP>:8081/health   # + each service
   ```
   Deliver: what was installed (versions), the service map (service → GPU →
   port → URL; only when stacks exist), remaining `<PLACEHOLDERS>`, and the
   warnings that apply (auth off, ports exposed, driver hold). Optional
   niceties: `nvitop`, power limit — `references/monitoring.md`.

## On-request extras

- **GPU power limit** (PSU or cooling cannot take all cards at full TGP, or
  efficiency tuning): follow the procedure in `references/monitoring.md` —
  query the allowed range first, set with `nvidia-smi -pl`, verify the new
  limit is in force. When the user asks for a **permanent** cap (survive
  reboots), a bare `nvidia-smi -pl` is not enough: install the systemd unit
  from the reference, enabled so it re-applies the limit at every system
  start. Never invent the wattage: the user names the target, or you propose
  one from the queried range and confirm before applying.
- **Monitoring** (`nvitop`, `watch nvidia-smi`): `references/monitoring.md`.

## Iron rules

- **One package source.** Driver and CUDA come from the official CUDA apt repo
  (`cuda-keyring`) — never `ubuntu-drivers`, never distro `nvidia-*` packages,
  never `.run` installers, never a mix. Toolkit for Docker comes from NVIDIA's
  repos the same way. On a machine that already mixed sources: purge the
  foreign one first (`references/troubleshooting.md`).
- **Never skip a gate, never continue past a failing one.** Also never declare
  success without the gate output actually shown.
- **Reboot after driver install** and after any kernel/driver upgrade, before
  judging anything broken.
- **Containers see zero GPUs by default.** Every service gets an explicit
  grant; on multi-GPU hosts pin with `device_ids`, don't spray `count: all`.
- **Executing on a live server:** show the commands of the current stage before
  running them, ask before every reboot, reconnect and continue after. Never
  run stage N+1 while the stage-N gate is unproven.
- **No invented values.** IPs, tokens, model choices the user didn't make are
  `<PLACEHOLDERS>` collected into a fill-in list. Flag every open-by-default
  setting (`WEBUI_AUTH: False`, ports on 0.0.0.0) as closed-network-only.
- **First model start is slow** (weights download). Watch logs; do not restart
  "hung" services that are downloading.

## Quick reference

| Layer | Proven by | Broken? |
|-------|-----------|---------|
| hardware | `lspci \| grep -E "VGA\|3D\|NVIDIA"` | BIOS / passthrough, not software |
| driver | `nvidia-smi` (all GPUs, sane driver ver) | Secure Boot, headers/DKMS, reboot |
| docker+GPU | `docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi` | toolkit, `nvidia-ctk`, restart docker |
| service | `curl /health`, `/v1/models`, real request | logs, VRAM budget, GPU pin |

`scripts/check.sh` runs the whole column top-to-bottom (`--no-docker-run` to
skip the container pull; extra args = health URLs).

## Common mistakes

- Installing via `ubuntu-drivers autoinstall` or distro packages "because it's
  quicker" — the exact mixed-sources knot this skill exists to prevent.
- Skipping `nvidia-ctk runtime configure` or the `systemctl restart docker`
  after it — toolkit installed, runtime still absent.
- No reboot after driver install, then debugging a "broken" driver.
- Forgetting kernel headers on minimal installs — DKMS quietly builds nothing.
- `image: :latest` in production compose files instead of a pinned tag.
- `deploy:` block missing → silent CPU fallback that "works" at 1 token/min.
- Two services on one GPU without lowering `--gpu-memory-utilization`.
- Leaving telemetry on and logs uncapped (json logs eat the disk in weeks).

## Files

- `references/nvidia-cuda.md` — repo setup, driver choice, pinning, Secure Boot
- `references/docker-nvidia.md` — Docker CE, toolkit, GPU passthrough, `/srv` layout
- `references/monitoring.md` — nvitop, watch, power limit (set / verify / persist)
- `references/troubleshooting.md` — 3-layer checklist, symptom→cause→fix table
- `presets/vllm.md`, `presets/infinity.md`, `presets/openwebui.md`, `presets/ollama.md`
- `scripts/check.sh` — staged verification (host → docker → services)
