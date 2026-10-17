# gpu-server-setup

An agent skill that prepares a **Linux server with NVIDIA GPUs** for
neural-network and LLM workloads — from a bare Debian/Ubuntu install to a
verified Docker + GPU inference stack. It is a portable skill: install it in
Claude Code, Cursor, or OpenAI Codex, or drop the folder into any agent that
reads `SKILL.md`.

Based on two field-tested sources by the author: the Dzen article
["Как подготовить Linux к запуску и обучению нейросетей? (+ Docker)"](https://dzen.ru/a/ZVt9kRBCTCGlQqyP)
and a production setup runbook for multi-GPU inference servers.

## What it does

- **NVIDIA driver + CUDA** — from the official CUDA apt repo (cuda-keyring),
  with the open-vs-proprietary kernel-module choice, driver-only vs toolkit
  decision, multi-CUDA via `update-alternatives`, and version pinning.
- **Mandatory kernel headers** — exact running-kernel headers plus the tracking
  metapackage (`linux-headers-amd64` on standard Debian; match the kernel flavour
  elsewhere), with headers and NVIDIA modules verified for installed kernels
  before a reboot. A kernel upgrade must not silently disable GPUs on the next boot.
- **Docker + NVIDIA Container Toolkit** — official Docker Engine install,
  `nvidia-ctk runtime configure`, and explicit GPU passthrough (`--gpus`,
  compose `deploy` blocks, per-service `device_ids` pinning).
- **Staged verification** — hard gates between layers (`lspci` →
  `nvidia-smi` → GPU-in-Docker → service health); the skill never proceeds
  past a failing gate. `scripts/check.sh` runs the gates automatically.
- **Inference presets (optional)** — the mandatory deliverable is the verified
  Docker + GPU base; serving stacks go on top only when asked for. Ready
  docker-compose files for **vLLM** (per-GPU model services), **Infinity**
  (embeddings), **OpenWebUI** (web UI) and **Ollama** (llama.cpp runs the same
  way via its official image), with the flags that matter explained.
- **GPU power limit** — on request: query the card's allowed range, cap with
  `nvidia-smi -pl`, verify the limit took effect, persist it across reboots
  with a systemd unit.
- **Troubleshooting** — symptom → cause → fix table for the classic failures:
  Secure Boot vs DKMS, "Driver/library version mismatch",
  `could not select device driver "nvidia"`, CUDA OOM, silent CPU fallback.

Scope: **Debian 10–13 and Ubuntu 20.04–24.04, x86_64, NVIDIA GPUs only.**

## Layout

```
gpu-server-setup/
├─ SKILL.md                 # the skill: workflow + hard rules the agent follows
├─ references/
│  ├─ nvidia-cuda.md        # driver + CUDA repo, versions, pinning, Secure Boot
│  ├─ docker-nvidia.md      # Docker Engine, nvidia-ctk, GPU passthrough, /srv layout
│  ├─ monitoring.md         # nvitop, watch nvidia-smi, power limit (set/verify/persist)
│  └─ troubleshooting.md    # 3-layer checklist + symptom/cause/fix table
├─ presets/
│  ├─ vllm.md               # OpenAI-compatible LLM server, one service per GPU
│  ├─ infinity.md           # embedding server (+ pinned-deps Dockerfile)
│  ├─ openwebui.md          # web interface over vLLM/Ollama
│  └─ ollama.md             # simplest GGUF serving, GPU vs CPU-only
├─ scripts/
│  └─ check.sh              # staged verification: host → docker → services
├─ tests/
│  └─ test_check.py         # isolated kernel-readiness regression tests
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
- "Audit this GPU server: what is installed, what is broken?"

Verify a server at any moment:

```bash
bash scripts/check.sh
bash scripts/check.sh http://<SERVER_IP>:8081/health
```

The checker also fails when a headers metapackage, headers for an installed kernel,
or its NVIDIA module is missing, even if the running kernel's `nvidia-smi` works.
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

MIT © Pavel Rykov. Not affiliated with NVIDIA, Docker Inc., or the vLLM,
Infinity, OpenWebUI, Ollama projects.
