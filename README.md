# gpu-server-setup

An agent skill that prepares a **Linux server with NVIDIA or Intel Arc GPUs**
for neural-network and LLM workloads — from a bare Debian/Ubuntu install to a
verified Docker + GPU inference stack. It is a portable skill: install it in
Claude Code, Cursor, or OpenAI Codex, or drop the folder into any agent that
reads `SKILL.md`.

Based on two field-tested sources by the author: the Dzen article
["Как подготовить Linux к запуску и обучению нейросетей? (+ Docker)"](https://dzen.ru/a/ZVt9kRBCTCGlQqyP)
and a production setup runbook for multi-GPU inference servers. The Intel Arc
part comes from bringing up a dual Arc A770 server on Debian 13 in 2026.

## What it does

- **NVIDIA driver + CUDA** — from the official CUDA apt repo (cuda-keyring),
  with the open-vs-proprietary kernel-module choice, driver-only vs toolkit
  decision, multi-CUDA via `update-alternatives`, and version pinning.
- **Mandatory kernel headers** — exact running-kernel headers plus the tracking
  metapackage (`linux-headers-amd64` on standard Debian; match the kernel flavour
  elsewhere), with headers and NVIDIA modules verified for installed kernels
  before a reboot. A kernel upgrade must not silently disable GPUs on the next boot.
- **Intel Arc (Alchemist and Battlemage)** — the in-tree i915/xe driver with
  distro firmware, Resizable BAR and real PCIe link checks, the
  trixie-backports kernel when the host must see GPU temperatures, Docker
  access through `/dev/dri` render nodes with no toolkit, and a field-tested
  map of what serves on Arc today: llama.cpp SYCL/Vulkan, Ollama, OpenVINO
  Model Server, vLLM on Battlemage and a no-build vLLM recipe for the A770,
  plus measured i915 against xe on a pair of A770: what the force-probed xe
  driver gives (up to 5x for vLLM, 2x for llama.cpp) and what it costs (a card
  that can wedge until a reboot, runtime PM to switch off).
- **Docker + NVIDIA Container Toolkit** — official Docker Engine install,
  `nvidia-ctk runtime configure`, and explicit GPU passthrough (`--gpus`,
  compose `deploy` blocks, per-service `device_ids` pinning).
- **Staged verification** — hard gates between layers (`lspci` →
  `nvidia-smi` or i915/xe + render nodes + GuC → GPU-in-Docker → service
  health); the skill never proceeds past a failing gate. `scripts/check.sh`
  detects the vendor and runs the gates automatically, then fails any running
  vLLM, Infinity or OpenWebUI container that still reports to its vendor.
- **Inference presets (optional)** — the mandatory deliverable is the verified
  Docker + GPU base; serving stacks go on top only when asked for. Ready
  docker-compose files for **vLLM** (per-GPU model services), **Infinity**
  (embeddings), **OpenWebUI** (web UI) and **Ollama** (llama.cpp runs the same
  way via its official image), with the flags that matter explained and vendor
  telemetry switched off in every one of them.
- **GPU power limit** — on request: query the card's allowed range, cap with
  `nvidia-smi -pl` or Intel hwmon `power1_max`, verify the limit took effect,
  persist it across reboots with a systemd unit (`scripts/arc-power-cap.sh`
  for Intel).
- **Cooling and idle power (Intel Arc)** — the honest answer that Arc fan
  curves cannot be changed from Linux, and what works instead: case fans via
  `fancontrol` from the hottest GPU temperature (including an out-of-tree
  `it87` for Gigabyte boards), and ASPM L1 on the Arc chains only
  (`scripts/arc-aspm.sh`, set after the GPU driver has probed the cards), which
  takes an idle A770 from 50-56 C to about 40-45 C.
- **Troubleshooting** — symptom → cause → fix table for the classic failures:
  Secure Boot vs DKMS, "Driver/library version mismatch",
  `could not select device driver "nvidia"`, CUDA OOM, silent CPU fallback.

Scope: **Debian 10–13 and Ubuntu 20.04–24.04 (26.04 for Intel), x86_64,
NVIDIA and Intel discrete GPUs.** No AMD/ROCm.

## Layout

```
gpu-server-setup/
├─ SKILL.md                 # the skill: workflow, vendor routing, hard rules
├─ references/
│  ├─ docker-engine.md      # Docker CE, daemon defaults, /opt/containers layout (both vendors)
│  ├─ telemetry.md          # vendor telemetry switches of the stacks and how to check them
│  ├─ nvidia/
│  │  ├─ driver-cuda.md     # CUDA repo, driver choice, headers, pinning, Secure Boot
│  │  ├─ container-toolkit.md  # nvidia-ctk, runtime, GPU passthrough
│  │  ├─ monitoring.md      # nvitop, power limit (set/verify/persist)
│  │  └─ troubleshooting.md # 3-layer checklist + symptom/cause/fix table
│  └─ intel/
│     ├─ driver.md          # i915/xe, firmware, ReBAR, PCIe links, kernel choice, host tools
│     ├─ docker.md          # /dev/dri passthrough, render group, card pinning, gates
│     ├─ stacks.md          # llama.cpp SYCL/Vulkan, Ollama, OpenVINO, vLLM on Arc
│     ├─ power-cooling.md   # power/clock cap, fans from GPU temperature, ASPM
│     └─ troubleshooting.md # 3-layer checklist + symptom/cause/fix table
├─ presets/                 # NVIDIA compose stacks: vllm, infinity, openwebui, ollama
├─ scripts/
│  ├─ check.sh              # staged verification: host → docker → services, both vendors
│  ├─ arc-power-cap.sh      # persistent power/clock cap for Intel Arc (systemd)
│  └─ arc-aspm.sh           # ASPM L1 on Intel Arc chains only (systemd)
├─ tests/                   # fixture tests for the scripts (no GPU or Docker needed)
├─ .claude-plugin/ .cursor-plugin/ .codex-plugin/   # agent manifests
├─ AGENTS.md  README.md  LICENSE
```

## Install

The skill is distributed through the [rpa-skills](https://github.com/EvilFreelancer/rpa-skills) catalog
and also installs as a plain skill folder.

**As a plugin (Claude Code)**: add the catalog once, then install this skill from it:

```text
/plugin marketplace add EvilFreelancer/rpa-skills
/plugin install gpu-server-setup@rpa-skills
```

**Codex**: `codex plugin marketplace add EvilFreelancer/rpa-skills`, then install `gpu-server-setup` from `/plugins`.

**In Coddy**: the rpa-skills catalog is built into [Coddy](https://coddy.dev) as a system source,
so there is nothing to connect. One sync installs this skill together with the rest of the collection
into `~/.coddy/skills/gpu-server-setup/` and keeps it up to date (or press **Sync all** in Settings → Skills):

```bash
coddy skills sync
```

**As a plain skill folder**: copy or symlink this repository into a skill root (its `SKILL.md` lives at
the repo root):

| Tool          | Path |
|---------------|------|
| Coddy         | `~/.coddy/skills/gpu-server-setup/` |
| Claude Code   | `~/.claude/skills/gpu-server-setup/` |
| Cursor        | `~/.cursor/skills/gpu-server-setup/` |
| OpenAI Codex  | `~/.codex/skills/gpu-server-setup/` |
| Kimi Code CLI | `~/.kimi/skills/gpu-server-setup/` |

The directory name must match the `name` field in `SKILL.md`.

## Usage

Ask your agent, for example:

- "Prepare this clean Ubuntu 24.04 server with two RTX 4090s for vLLM with
  Qwen3.5-27B and OpenWebUI on top."
- "Install the NVIDIA driver and CUDA on Debian 12 and wire Docker to the GPU."
- "nvidia-smi works on the host but containers don't see the GPU — fix it."
- "Cap every GPU at 250 W and make the limit survive reboots."
- "Set up this Debian 13 box with two Arc A770 for containers, the cards sit
  in a tight case, make the cooling more aggressive."
- "My Arc cards idle at 40 W and 55 C doing nothing, fix it."
- "Audit this GPU server: what is installed, what is broken?"

Verify a server at any moment:

```bash
sudo bash scripts/check.sh
sudo bash scripts/check.sh http://<SERVER_IP>:8081/health
bash scripts/check.sh --vendor intel --no-docker-run
```

The checker also fails when a headers metapackage, headers for an installed kernel,
or its NVIDIA module (Intel: i915/xe and every DKMS module) is missing, even if the
running kernel works. On Intel it also fails on a card the driver declared wedged and
warns when an Alchemist card on xe still has runtime PM on.
`--no-docker-run` skips only the container probe, not these checks. It does not install
headers, build DKMS modules or reboot the machine.

Run the isolated command-fixture regression tests locally (no GPU or Docker needed):

```bash
python3 -m unittest discover -s tests -v
bash -n scripts/check.sh
```

## Safety

- The skill separates **plan** from **execution**: on live servers it shows
  what will run before running it, asks before reboots, and never proceeds
  past a failing verification gate.
- Secrets and site-specific values are `<PLACEHOLDERS>` — the skill never
  invents IPs, tokens, or passwords.
- `WEBUI_AUTH: False` and similar open-by-default settings are always called
  out as closed-network-only.

## License

MIT © Pavel Rykov. Not affiliated with NVIDIA, Intel, Docker Inc., or the vLLM,
Infinity, OpenWebUI, Ollama, llama.cpp, OpenVINO projects.
