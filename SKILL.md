---
name: gpu-server-setup
version: 0.1.0
description: >
  Prepare a Linux server with NVIDIA GPUs for neural-network and LLM workloads,
  or diagnose one that misbehaves. Use when the user asks to set up or prepare a
  GPU server, install NVIDIA drivers or CUDA on Debian/Ubuntu, wire Docker to
  GPUs (NVIDIA Container Toolkit), deploy vLLM / Infinity / OpenWebUI / Ollama,
  or fix "container does not see GPU", "Driver/library version mismatch",
  "could not select device driver nvidia". Installs everything from one package
  source (the official CUDA apt repo), verifies every layer with a hard gate
  before the next, and ships working docker-compose presets.
metadata:
  author: Pavel Rykov <paul@drteam.rocks>
  homepage: https://github.com/EvilFreelancer/gpu-server-setup
  triggers: >
    gpu server, nvidia driver, cuda, cuda-keyring, nvidia-smi, docker gpu,
    nvidia-container-toolkit, nvidia-ctk, gpus all, vllm, ollama, openwebui,
    infinity embeddings, driver library version mismatch, could not select
    device driver
---

# GPU server setup

Turn a bare **Debian/Ubuntu** server with NVIDIA GPUs into a verified inference
box: driver → Docker → GPU runtime → serving stack. The skill encodes one
field-tested path and the discipline around it, so you assemble a working
server instead of improvising package sources.

Scope: **Debian 10–13, Ubuntu 20.04–24.04, x86_64, NVIDIA only.** No Windows/
WSL, no RHEL-family, no AMD/ROCm, no Kubernetes. If the user is outside this
scope, say so instead of adapting on the fly.

## Core principle

**One package source, and a hard gate after every layer.** Each layer is proven
working before the next one starts; a failing gate stops the flow — fix it via
`references/troubleshooting.md`, re-run the gate, only then continue. Most
"GPU server is broken" situations are a skipped gate or a second package source.

## Three modes

| Mode | Trigger | What you produce |
|------|---------|------------------|
| **Prepare** | clean/fresh server to set up | full pass: stages 0→4 |
| **Deploy** | driver/Docker already fine, add a stack | stages 3→4 on top of a verified base |
| **Diagnose** | "X does not work / does not see GPU" | layer-by-layer audit, fix, re-gate |

With shell access to the server, **detect facts instead of asking**. Without
access, produce the full instruction with `<PLACEHOLDERS>` and a fill-in list.

## Workflow

1. **Gather facts (gap checklist).** OS and version (`cat /etc/os-release`),
   GPUs (`lspci | grep -E "VGA|3D|NVIDIA"`), disk (`df -h /`), Secure Boot
   (`mokutil --sb-state`), what stack and which models, single- or multi-GPU,
   network exposure (open network or closed). Ask only what you cannot detect.
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
6. **Stage 3 — serving stack.** One service per folder under `/srv`, one GPU
   pin per service (`device_ids`). Start from `presets/` — `vllm.md`,
   `infinity.md`, `openwebui.md`, `ollama.md` — and adapt: model, GPU ids,
   ports, memory budget. Presets are working configs, not copy-paste blanks:
   fill every `<PLACEHOLDER>`, keep image tags pinned, telemetry off, logs
   capped. **GATE: health endpoint answers AND a real request returns a sane
   response** (`/v1/models`, then one chat/embedding call).
7. **Stage 4 — verify and hand over.** Run the full check:
   ```bash
   bash scripts/check.sh http://<SERVER_IP>:8081/health
   ```
   Deliver: what was installed (versions), the service map (service → GPU →
   port → URL), remaining `<PLACEHOLDERS>`, and the warnings that apply
   (auth off, ports exposed, driver hold). Optional niceties: `nvitop`,
   power capping — `references/monitoring.md`.

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
- `references/monitoring.md` — nvitop, watch, power capping
- `references/troubleshooting.md` — 3-layer checklist, symptom→cause→fix table
- `presets/vllm.md`, `presets/infinity.md`, `presets/openwebui.md`, `presets/ollama.md`
- `scripts/check.sh` — staged verification (host → docker → services)
