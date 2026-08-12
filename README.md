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
├─ .claude-plugin/ .cursor-plugin/ .codex-plugin/   # agent manifests
├─ AGENTS.md  README.md  LICENSE
```

## Install

**Claude Code** (single-plugin marketplace in this repo):

```
/plugin marketplace add EvilFreelancer/gpu-server-setup
/plugin install gpu-server-setup
```

**Any agent (manual):** copy this folder into the agent's skills directory
(e.g. `~/.claude/skills/gpu-server-setup/`). The agent loads it from the
`SKILL.md` frontmatter.

**Cursor / Codex:** point the agent at the repo; the `.cursor-plugin/` and
`.codex-plugin/` manifests describe the same skill.

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
