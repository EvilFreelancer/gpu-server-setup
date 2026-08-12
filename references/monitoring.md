# Monitoring and host-side tooling

## Watching the GPUs

Zero-install, always works:

```bash
watch nvidia-smi          # refresh every 2s, Ctrl+C to exit
nvidia-smi -l 1           # same idea, 1s interval
```

Nicer interactive view — `nvitop` (htop for GPUs), installed via `pipx` so it
never touches system Python:

```bash
sudo apt -y install pipx
pipx run nvitop           # one-off, no permanent install
pipx install nvitop       # or install it for real…
pipx ensurepath           # …then ALWAYS run this: puts ~/.local/bin on PATH
```

`pipx ensurepath` edits the shell rc, so it takes effect in the **next** shell —
re-login / `exec $SHELL`, or for the current session
`export PATH="$HOME/.local/bin:$PATH"`. Skipping it is the classic
"installed nvitop, `command not found`" trap; `pipx run` alone needs no PATH.

Keys inside nvitop: arrows to move, `K` + `Enter` to kill a process, `Q` to quit.

What to look at during service start: memory column grows while the model
loads; a service that "runs" but uses 0 MiB VRAM is running on CPU.

## Python on the host

For occasional host-side scripting keep it minimal and isolated:

```bash
sudo apt -y install python3 python3-venv pipx
python3 -m venv .venv && . .venv/bin/activate      # per-project venv
```

Never `pip install` into system Python; on modern Debian/Ubuntu it is blocked
(PEP 668) anyway. `pipx` for tools, `venv` for projects, Docker for services.

## Power limit (power capping)

A standalone task, done **when the user asks for it**: the PSU or cooling
cannot take all cards at full TGP, or the user wants efficiency tuning. Needs
root; watts are integers. Never invent the wattage — the user names the
target, or you propose one from the queried range and confirm.

**1. Query the allowed range first.** The target must fall inside
`[Min, Max] Power Limit` of every card it applies to:

```bash
nvidia-smi -q -d POWER            # per GPU: Current / Default / Min / Max Power Limit
nvidia-smi --query-gpu=index,name,power.limit,power.min_limit,power.max_limit --format=csv
```

If the requested value is outside a card's range, do not clamp silently —
show the range and ask.

**2. Enable persistence mode** so the driver stays loaded and the setting is
not dropped when the last client exits:

```bash
sudo nvidia-smi -pm 1
```

**3. Set the limit** — all GPUs at once, or one card via `-i N`. On hosts with
mixed card models set each model separately with `-i`: their ranges differ.

```bash
sudo nvidia-smi -pl 250           # every GPU
sudo nvidia-smi -i 0 -pl 250      # only GPU 0
```

**4. Verify — this is the gate.** The new limit must show up before you call
it done:

```bash
nvidia-smi --query-gpu=index,power.limit,power.draw --format=csv
```

**5. Persist across reboots.** `-pl` does not survive a reboot — install a
oneshot systemd unit (one `ExecStart` line per `-i` group on mixed hosts):

```ini
# /etc/systemd/system/nvidia-power-limit.service
[Unit]
Description=NVIDIA power limit
After=systemd-modules-load.service
ConditionPathExists=/usr/bin/nvidia-smi

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pm 1
ExecStart=/usr/bin/nvidia-smi -pl 250

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now nvidia-power-limit
systemctl status nvidia-power-limit --no-pager   # must be active (exited), rc 0
```

Re-check the limit after driver upgrades — an upgrade can reset it until the
next boot re-runs the unit.

**When it fails:**

| Symptom | Meaning / action |
|---------|------------------|
| `Provided power limit … is not a valid power limit which should be between X and Y` | target outside the card's range — re-run step 1, pick a value inside, or report the range to the user |
| `Changing power management limit is not supported` | the card/driver combo does not allow capping (typical for laptop GPUs, some cards on recent drivers) — say so; there is no nvidia-smi workaround |
| power fields show `N/A` | same as above, or a driver problem — check `references/troubleshooting.md` layer 2 (driver) first |
| limit back to default after reboot | the systemd unit is missing, disabled, or failed — `systemctl status nvidia-power-limit` |

**Choosing a value:** for inference, capping to ~70-80 % of the default TGP
usually costs only a few percent of throughput (a 350 W RTX 3090 capped at
280 W keeps roughly 95 % of its performance); a cap near the Min limit means
hard throttling under load, not free silence.
