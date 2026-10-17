---
name: gpu-server-setup
description: >
  Prepare a Linux server with NVIDIA or Intel Arc GPUs for neural-network and
  LLM workloads, or diagnose one that misbehaves. Use when the user asks to set
  up or prepare a GPU server, install NVIDIA drivers or CUDA on Debian/Ubuntu,
  bring up Intel Arc (A770, A750, B580, Arc Pro B60/B70) with the i915/xe
  driver and firmware, wire Docker to GPUs (NVIDIA Container Toolkit, or
  /dev/dri passthrough for Intel), deploy vLLM / Infinity / OpenWebUI / Ollama /
  llama.cpp / OpenVINO, set or persist a GPU power limit (nvidia-smi -pl, i915
  hwmon power1_max), drive case fans from GPU temperature, cut Intel Arc idle
  power with ASPM, or fix "container does not see GPU", "Driver/library version
  mismatch", "could not select device driver nvidia". One package source per
  vendor and a hard gate after every layer; the mandatory deliverable is Docker
  with verified GPU access, serving stacks are optional presets on top.
metadata:
  version: 0.3.1
  author: Pavel Rykov <paul@drteam.rocks>
  homepage: https://github.com/EvilFreelancer/gpu-server-setup
  triggers: >
    gpu server, nvidia driver, cuda, cuda-keyring, nvidia-smi, docker gpu,
    nvidia-container-toolkit, nvidia-ctk, gpus all, vllm, ollama, llama.cpp,
    openwebui, infinity embeddings, power limit, power cap, nvidia-smi -pl,
    intel arc, a770, b580, b60, b70, i915, xe driver, level zero, sycl, oneapi,
    /dev/dri, intel_gpu_top, xpu-smi, openvino, aspm, idle power, fan curve,
    fancontrol, ограничить мощность GPU, энергопотребление видеокарты,
    настроить GPU сервер, вентиляторы видеокарты, driver library version
    mismatch, could not select device driver
---

# GPU server setup

Turn a bare **Debian/Ubuntu** server with NVIDIA or Intel Arc GPUs into a
verified inference box: driver → Docker → GPU access, plus an optional serving
stack on top. The skill encodes one field-tested path per vendor and the
discipline around it, so you assemble a working server instead of improvising
package sources.

Scope: **Debian 10–13, Ubuntu 20.04–24.04 (26.04 for Intel), x86_64, NVIDIA
and Intel discrete GPUs** (Arc Alchemist and Battlemage, Arc Pro). No
Windows/WSL, no RHEL-family, no AMD/ROCm, no Kubernetes. If the user is outside
this scope, say so instead of adapting on the fly.

## Core principle

**One package source per vendor, and a hard gate after every layer.** Each
layer is proven working before the next one starts; a failing gate stops the
flow — fix it via the vendor's `troubleshooting.md`, re-run the gate, only
then continue. Most "GPU server is broken" situations are a skipped gate or a
second package source.

**The mandatory deliverable is the verified Docker + GPU base** — the stage-2
gate (a container sees every GPU). Serving stacks are optional add-ons: deploy
one only when the user asked for it. A pass that ends at a proven stage-2 gate
with no stack is a complete, successful Prepare, not an unfinished one.

## Vendor routing

Detect the vendor first (`lspci -nn | grep -Ei 'vga|3d|display'`): `[10de:…]`
is NVIDIA, `[8086:56xx]` Alchemist, `[8086:e2xx]` Battlemage (an Intel id
outside these is usually the integrated GPU; leave it alone). Then every
stage reads the vendor's reference; mixed hosts run both columns.

| Stage | NVIDIA | Intel Arc |
|---|---|---|
| 1 driver | `references/nvidia/driver-cuda.md`: CUDA apt repo, DKMS module, headers metapackage | `references/intel/driver.md`: in-tree i915 (Alchemist) or xe (Battlemage), distro firmware, ReBAR, newer kernel from backports when needed |
| 1 gate | `nvidia-smi` lists every GPU | every card bound to i915/xe, a render node per card in `/dev/dri/by-path`, GuC running, ReBAR = VRAM size |
| 2 docker | `references/docker-engine.md` + `references/nvidia/container-toolkit.md` | `references/docker-engine.md` + `references/intel/docker.md` (no toolkit, `/dev/dri` devices) |
| 2 gate | `docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi` | `docker run --rm --device /dev/dri intel/compute-runtime:<tag> clinfo -l` |
| 3 stacks | `presets/` | `references/intel/stacks.md` (llama.cpp SYCL first; vLLM only on Battlemage, or via the A770 recipe) |
| power, fans | `references/nvidia/monitoring.md` | `references/intel/power-cooling.md` |
| broken? | `references/nvidia/troubleshooting.md` | `references/intel/troubleshooting.md` |

## Three modes

| Mode | Trigger | What you produce |
|------|---------|------------------|
| **Prepare** | clean/fresh server to set up | stages 0→2 always; 3 only if a stack was requested; 4 always |
| **Deploy** | driver/Docker already fine, add a stack | stages 3→4 on top of a verified base |
| **Diagnose** | "X does not work / does not see GPU" | layer-by-layer audit, fix, re-gate |

Standalone requests on an already-working server (cap the power limit, fan
control, idle power, monitoring) are valid tasks of their own — no full pass,
just the live-server rules plus the matching reference (see "On-request
extras").

With shell access to the server, **detect facts instead of asking**. Without
access, produce the full instruction with `<PLACEHOLDERS>` and a fill-in list.

## Workflow

1. **Gather facts (gap checklist).** OS and version (`cat /etc/os-release`),
   GPUs and vendor (`lspci -nn | grep -Ei 'vga|3d|display'`, `lspci -tv` for
   which slot hangs off the CPU or the chipset), disk (`df -h /`, `lsblk -d -o
   NAME,ROTA,SIZE`), Secure Boot (`mokutil --sb-state`), whether a serving
   stack is wanted at all and which ("none" is a valid answer), which models,
   single- or multi-GPU, network exposure (open network or closed). Intel
   Arc: Resizable BAR (`sudo lspci -vv -d 8086: | grep 'BAR 2: current size'`
   must equal the VRAM); when it shows 256MB, the user switches BIOS
   settings before anything else. Ask only what you cannot detect.
2. **Pick the mode.** For Diagnose jump straight to the 3-layer checklist in
   the vendor's `troubleshooting.md` and fix the **lowest** failing layer first.
3. **Stage 0 — base system.**
   ```bash
   sudo apt update && sudo apt -y upgrade
   sudo apt -y install mc ca-certificates curl gnupg lsb-release wget jq
   ```
   If the upgrade changes the kernel/libc, prepare stage 1 for that kernel
   before an approved reboot (NVIDIA: headers and the DKMS module; Intel:
   firmware and any DKMS module). A working old kernel is not that gate.
4. **Stage 1 — driver.**
   - **NVIDIA** (`references/nvidia/driver-cuda.md`): add the CUDA repo via
     `cuda-keyring` for the exact `$distro/$arch`. **Mandatory prerequisite:
     headers for the running kernel AND the matching tracking headers
     metapackage** (`linux-headers-amd64` on standard Debian amd64; match the
     kernel flavour on Ubuntu/cloud/RT). **GATE: every installed kernel image
     has usable headers.** Then the driver — open kernel modules for Turing
     and newer, proprietary for Pascal and older. Docker-only hosts need
     **no** CUDA toolkit. Before rebooting, build/check NVIDIA DKMS modules for
     every installed kernel. Reboot with approval, reconnect.
     **GATE: `nvidia-smi` lists every physical GPU.**
   - **Intel** (`references/intel/driver.md`): the driver is in the kernel;
     install the distro firmware package (`firmware-intel-graphics` on Debian
     13, non-free-firmware enabled), check ReBAR and the real PCIe link of
     every card. Alchemist on Debian 13 wants the trixie-backports kernel when
     the host must see GPU temperatures. No compute runtime on the host.
     **GATE: every card bound to i915/xe, one render node per card, GuC
     running, BAR2 = VRAM.**
5. **Stage 2 — Docker + GPU access.** Docker CE from the official repo
   (`references/docker-engine.md`), log caps in `daemon.json`.
   - **NVIDIA:** install `nvidia-container-toolkit`, then
     `sudo nvidia-ctk runtime configure --runtime=docker` and
     `sudo systemctl restart docker` (both mandatory).
     **GATE: `docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi`
     shows the same GPUs as the host.**
   - **Intel:** nothing to install; containers get cards through
     `--device /dev/dri/renderD*`. Add the operator to `render`.
     **GATE: `clinfo -l` in `intel/compute-runtime` lists every card.**
6. **Stage 3 — serving stack (optional, only when requested).** One service
   per folder under `/srv`, one GPU pin per service (NVIDIA `device_ids`;
   Intel `ONEAPI_DEVICE_SELECTOR` or a single render node). NVIDIA: start from
   `presets/`. Intel: `references/intel/stacks.md` (CUDA presets do not apply).
   Pinned image tags, telemetry off, logs capped, every `<PLACEHOLDER>` filled.
   **GATE: health endpoint answers AND a real request returns a sane
   response** (`/v1/models`, then one chat/embedding call), and the GPU is
   busy while it answers (`nvidia-smi` / `intel_gpu_top`).
7. **Stage 4 — verify and hand over.** Run the full check (vendor detected
   automatically; as root it also checks GuC on Intel):
   ```bash
   sudo bash scripts/check.sh                                  # base: host + docker
   sudo bash scripts/check.sh http://<SERVER_IP>:8081/health   # + each service
   ```
   Deliver: what was installed (versions), the service map (service → GPU →
   port → URL; only when stacks exist), remaining `<PLACEHOLDERS>`, and the
   warnings that apply (auth off, ports exposed, driver hold, out-of-tree
   modules).

## On-request extras

- **GPU power limit** (PSU or cooling cannot take all cards at full board
  power, or efficiency tuning): query the allowed range first, set, verify
  the readback, and for a **permanent** cap install the boot-time systemd
  unit. NVIDIA: `nvidia-smi -pl` + `nvidia-power-limit.service`
  (`references/nvidia/monitoring.md`). Intel: hwmon `power1_max` +
  `scripts/arc-power-cap.sh` as `arc-power-cap.service`
  (`references/intel/power-cooling.md`). Never invent the wattage: the user
  names the target, or you propose one and confirm before applying.
- **Cooling** ("fans more aggressive", "cards too hot"): NVIDIA fans follow the
  driver; Intel Arc fan curves **cannot** be changed from Linux at all — say
  so, then offer what works: power/clock cap, case fans from the hottest GPU
  temperature via `fancontrol`, and lower idle heat (Intel:
  `references/intel/power-cooling.md` sections 1-4).
- **Intel idle power** (an A770 idles at ~40 W): ASPM L1 on the Arc chains only,
  via `scripts/arc-aspm.sh`, tested with a revert timer first.
- **Monitoring**: NVIDIA `nvitop` (`references/nvidia/monitoring.md`); Intel
  `intel_gpu_top`, `nvtop`, `sensors` (`references/intel/driver.md`).

## Iron rules

- **One package source per vendor.** NVIDIA: driver and CUDA from the official
  CUDA apt repo (`cuda-keyring`) — never `ubuntu-drivers`, never distro
  `nvidia-*` packages, never `.run` installers, never a mix; toolkit from
  NVIDIA's repos the same way. Intel: kernel and firmware from the distro
  (same suite for both), the compute runtime inside the images — never a
  host-side mix of PPAs, GitHub `.deb`s and distro packages.
- **Never skip a gate, never continue past a failing one.** Also never declare
  success without the gate output actually shown.
- **Every installed kernel must be bootable with working GPUs.** NVIDIA:
  headers metapackage + DKMS module for every installed kernel, verified
  before every reboot. Intel: i915/xe for every installed kernel, and the same
  headers rule as soon as any DKMS module (e.g. a fan driver) is on the box.
  A green gate on the old kernel does not prove the next boot.
- **Intel Arc needs Resizable BAR.** Above 4G Decoding and Re-Size BAR on,
  CSM off, in the BIOS, before stage 1. Without it only 256 MiB of VRAM is
  CPU-visible: slow loads, failed allocations, unstable cards. No driver or
  kernel setting replaces it; it is a BIOS change for the user to make.
- **Reboot after driver install** and after any kernel/driver upgrade, before
  judging anything broken.
- **Containers see zero GPUs by default.** Every service gets an explicit
  grant; on multi-GPU hosts pin each service to its card.
- **Executing on a live server:** show the commands of the current stage
  before running them, ask before every reboot, reconnect and continue after.
  Never run stage N+1 while the stage-N gate is unproven. Risky runtime
  experiments (ASPM, PWM) get a revert timer before they start.
- **No invented values.** IPs, tokens, model choices, wattages the user didn't
  make are `<PLACEHOLDERS>` collected into a fill-in list. Flag every
  open-by-default setting (`WEBUI_AUTH: False`, ports on 0.0.0.0) as
  closed-network-only.
- **First model start is slow** (weights download, JIT compilation). Watch
  logs; do not restart "hung" services that are downloading.

## Quick reference

| Layer | NVIDIA proven by | Intel proven by | Broken? |
|-------|------------------|-----------------|---------|
| hardware | `lspci` | `lspci -nn`, BAR2 size, link on the card's `4fa0` bridge | BIOS (ReBAR) / slot / passthrough |
| kernel readiness | headers metapackage, headers and `modinfo -k <k> nvidia` per kernel | `modinfo -k <k> i915` (or xe) per kernel, DKMS modules per kernel | install headers / kernel package, build DKMS before reboot |
| driver | `nvidia-smi` | render node per card, GuC in dmesg | NVIDIA: Secure Boot, DKMS; Intel: firmware, force_probe, kernel version |
| docker+GPU | `docker run --gpus all ubuntu nvidia-smi` | `docker run --device /dev/dri intel/compute-runtime clinfo -l` | NVIDIA: toolkit, `nvidia-ctk`; Intel: device grant, render GID |
| service | `curl /health`, `/v1/models`, real request | same | logs, VRAM budget, GPU pin |

`scripts/check.sh` runs the whole column top-to-bottom for the detected
vendor (`--vendor nvidia|intel` to force, `--no-docker-run` to skip the
container probe, extra args = health URLs).

## Common mistakes

- Installing via `ubuntu-drivers autoinstall` or distro packages "because it's
  quicker" — the exact mixed-sources knot this skill exists to prevent.
- Skipping `nvidia-ctk runtime configure` or the `systemctl restart docker`
  after it — toolkit installed, runtime still absent.
- Installing the Intel compute runtime, oneAPI or xpu-smi on a Docker-only
  host "to be safe": nothing uses it, and on Debian it means a second source.
- Bringing up Intel Arc with Resizable BAR or Above 4G Decoding off in the
  BIOS, then debugging "slow" or "unstable" cards in software.
- Restarting llama.cpp SYCL containers without a compiler-cache volume: every
  start JIT-compiles the kernels again (about 80 s on a desktop CPU).
- No reboot after driver install, then debugging a "broken" driver.
- Installing only `linux-headers-$(uname -r)` without the headers metapackage —
  the next kernel upgrade can leave DKMS modules unbuilt until a power cut
  exposes it.
- Splitting one model across cards without looking at the links: a chipset
  slot at PCIe 3.0 x2 makes tensor parallel crawl.
- `image: :latest` in production compose files instead of a pinned tag.
- Missing GPU grant → silent CPU fallback that "works" at 1 token/min.
- Two services on one GPU without lowering their memory budget.
- Leaving telemetry on and logs uncapped (json logs eat the disk in weeks).

## Files

- `references/docker-engine.md` — Docker CE, daemon defaults, `/srv` layout (both vendors)
- `references/nvidia/driver-cuda.md` — CUDA repo, driver choice, headers, pinning, Secure Boot
- `references/nvidia/container-toolkit.md` — toolkit, runtime, GPU passthrough
- `references/nvidia/monitoring.md` — nvitop, power limit (set / verify / persist)
- `references/nvidia/troubleshooting.md` — 3-layer checklist, symptom→cause→fix
- `references/intel/driver.md` — i915/xe, firmware, ReBAR, PCIe links, kernel choice, host tools
- `references/intel/docker.md` — `/dev/dri` passthrough, render group, card pinning, gates
- `references/intel/stacks.md` — what runs on Arc: llama.cpp, Ollama, OpenVINO, vLLM
- `references/intel/power-cooling.md` — power/clock cap, fans from GPU temperature, ASPM idle power
- `references/intel/troubleshooting.md` — 3-layer checklist, symptom→cause→fix
- `presets/vllm.md`, `presets/infinity.md`, `presets/openwebui.md`, `presets/ollama.md` — NVIDIA stacks
- `scripts/check.sh` — staged verification (host → docker → services), NVIDIA and Intel
- `scripts/arc-power-cap.sh` — persistent power/clock cap for Intel Arc
- `scripts/arc-aspm.sh` — ASPM L1 on Intel Arc chains only
