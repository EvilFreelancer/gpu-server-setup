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
pipx install nvitop       # or install it for real
```

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

## Power capping (optional, multi-GPU boxes)

Useful when the PSU or cooling cannot take all cards at full TGP:

```bash
nvidia-smi -q -d POWER            # look up Min/Max Power Limit first
sudo nvidia-smi -pm 1             # persistence mode
sudo nvidia-smi -pl 150           # cap at 150 W (per GPU; -i N for one card)
```

The limit resets on reboot — persist it with a tiny systemd unit:

```ini
# /etc/systemd/system/nvidia-power-limit.service
[Unit]
Description=NVIDIA power limit
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pm 1
ExecStart=/usr/bin/nvidia-smi -pl 150

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now nvidia-power-limit
```

Cap only within the card's allowed range; a too-low cap = throttling under
load, not free silence.
