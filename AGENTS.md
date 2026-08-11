# Authoring & maintaining the `gpu-server-setup` skill

Agent guide for working **inside this skill repository**. Read it before editing
`SKILL.md`, the references, the presets, `scripts/check.sh`, or any plugin
manifest.

> Naming (Russian): the adjective for "agent / agentic" is **«агентный»**, never
> «агентский».

## Repository layout

This skill is packaged for **Claude Code**, **Cursor**, and **OpenAI Codex**
(and installs as a plain skill folder for other agents). The layout is **flat** —
`SKILL.md` and its assets live at the repo root, and the plugin manifests point
their skill source at `./`.

```
gpu-server-setup/
├─ .claude-plugin/
│  ├─ plugin.json        # Claude Code plugin manifest
│  └─ marketplace.json   # single-plugin marketplace (plugin lives at "./")
├─ .cursor-plugin/plugin.json    # Cursor manifest
├─ .codex-plugin/plugin.json     # Codex manifest (interface block + skills: "./")
├─ SKILL.md              # CANONICAL skill: YAML frontmatter + instructions
├─ references/           # deep knowledge, loaded on demand from SKILL.md
├─ presets/              # ready docker-compose stacks (adapt, don't paste verbatim)
├─ scripts/check.sh      # staged verification script (pure bash)
├─ README.md  AGENTS.md  LICENSE
```

There is no `skills/<name>/` subfolder — the root **is** the skill.

## Editing rules

- **Keep `SKILL.md` thin.** It holds the workflow, the stage gates, and the hard
  rules. Depth goes in `references/` and `presets/`. If a section grows past a
  screen, move the detail into a reference and link it.
- **One package source.** Every install path in this skill uses the official
  NVIDIA CUDA apt repo + the official Docker repo. Never add instructions that
  mix distro `nvidia-*` packages, `ubuntu-drivers`, or `.run` installers into
  the same flow — mixed sources are the #1 support burden this skill exists to
  prevent.
- **Gates are not optional.** Any edit must preserve the staged verification
  order (lspci → nvidia-smi → GPU-in-Docker → service health) and the rule that
  the agent stops on a failing gate.
- **Presets must stay runnable.** They are working configs with
  `<PLACEHOLDER>` tokens for site-specific values (IPs, tokens, models where
  relevant). Never bake in real IPs or secrets. Version numbers in `image:`
  tags are allowed (they document a known-good combination) but prefer noting
  "check for the current release" where staleness bites.
- **check.sh is pure bash**, no dependencies beyond coreutils/curl/docker. It
  must stay read-only except the single `docker run … nvidia-smi` gate, must
  not use `set -e` (it collects failures), and must exit non-zero on any FAIL.
  After editing run `bash -n scripts/check.sh` and exercise it on a machine
  with and without a configured GPU.
- **Version drift.** Driver branches, CUDA majors, and image tags in the text
  are examples of a known-good state, not eternal truth. When refreshing them,
  update `nvidia-cuda.md`, the presets, and the README consistently in one
  commit.

## Keeping metadata in sync

When you change the description or bump the version, update it in **all** of:

- `SKILL.md` frontmatter (`version`, `description`)
- `.claude-plugin/plugin.json` **and** `.claude-plugin/marketplace.json`
- `.cursor-plugin/plugin.json`
- `.codex-plugin/plugin.json` (both top-level and the `interface` block)
- `README.md`

Keep the `name` identical everywhere: `gpu-server-setup`. Inside this repo's own
`.claude-plugin/marketplace.json` both the plugin `version` and the top-level
`metadata.version` track this skill, so bump both.

## Publishing: mirror every version bump into the `rpa-skills` catalog

This skill is also published through the
**[rpa-skills](https://github.com/EvilFreelancer/rpa-skills)** marketplace, which
keeps its **own copy** of this skill's `version` and `description`. Until the
catalog is updated, anyone installing from it still gets the old metadata. The
catalog **follows, never leads** — release here first, then update it in the same
session. The full process lives in that repo's `AGENTS.md`.

**MANDATORY** whenever `version` or `description` changes here:

1. `.claude-plugin/marketplace.json` (catalog) — in the `gpu-server-setup`
   entry set `version` to the new number and refresh `description` if it changed.
2. `.agents/plugins/marketplace.json` (catalog, Codex) — no per-plugin `version`
   there; the entry points at `ref: main`, so the version follows by itself.
   Refresh `description` if it changed, and the `ref` only when the entry pins a
   tag or a sha.
3. Top-level `metadata.version` in **both** catalog manifests — bump the **patch**
   level on every mirrored skill release, and keep the two manifests identical.
   A skill added, removed, or renamed takes a minor bump instead.
4. `README.md` (catalog) — the Skills-table row, only when the purpose or the
   description changed.

Verify from a checkout of the catalog:

```bash
grep -A3 '"name": "gpu-server-setup"' .claude-plugin/marketplace.json
python3 -m json.tool .claude-plugin/marketplace.json  >/dev/null && echo claude-ok
python3 -m json.tool .agents/plugins/marketplace.json >/dev/null && echo codex-ok
```

## What this skill does NOT do

- It does not manage NVIDIA on Windows/WSL, macOS, RHEL-family, Arch, or NixOS.
- It does not cover AMD/Intel GPUs, ROCm, or oneAPI.
- It does not do Kubernetes (device plugin, GPU operator) — single-host Docker
  Compose only.
- It does not benchmark or fine-tune models; it prepares the server and brings
  the serving stack up.
