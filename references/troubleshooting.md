# Troubleshooting

Debug **in layer order** — host GPU → Docker → service. A failure in layer N
makes every layer above it fail too; fixing from the top down wastes hours.

## The 3-layer checklist

```bash
# 1. Host sees GPUs
nvidia-smi

# 2. Docker sees GPUs
docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi

# 3. Services answer
docker ps
curl -s http://<SERVER_IP>:8081/health
curl -s http://<SERVER_IP>:8081/v1/models | jq
cd /srv/<service> && docker compose logs -f
```

`scripts/check.sh` in this skill runs layers 1–2 (and optional health URLs)
automatically, and prints which processes sit on which GPU — an empty list
under running services is the silent-CPU-fallback smell:

```bash
bash scripts/check.sh                                  # host + docker gates
bash scripts/check.sh http://<SERVER_IP>:8081/health   # + service endpoints
```

## Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `lspci` shows no NVIDIA device | hardware not seated / VM without GPU passthrough | fix at BIOS/hypervisor level; no driver will help |
| `nvidia-smi`: "couldn't communicate with the NVIDIA driver" / "No devices were found" | kernel module not loaded: Secure Boot blocks unsigned DKMS module, or headers were missing so DKMS never built, or no reboot after install | `mokutil --sb-state`; `sudo dkms status` (dkms lives in /usr/sbin); install `linux-headers-$(uname -r)` then `sudo dpkg-reconfigure nvidia-kernel-dkms` (or reinstall driver); reboot |
| `nvidia-smi`: "Driver/library version mismatch" | userland updated (often unattended-upgrades) while old module still loaded | reboot; then `apt-mark hold` the driver packages (see `nvidia-cuda.md`) |
| `docker: Error response from daemon: could not select device driver "nvidia"` | nvidia-container-toolkit not installed, or `nvidia-ctk runtime configure` not run, or docker not restarted after it | install toolkit → `sudo nvidia-ctk runtime configure --runtime=docker` → `sudo systemctl restart docker` |
| host `nvidia-smi` fine, container sees no GPU | missing `--gpus` flag / compose `deploy` block | add explicit GPU grant — containers get zero GPUs by default (see `docker-nvidia.md` §5) |
| `permission denied ... /var/run/docker.sock` | user not in `docker` group or not re-logged-in | `sudo adduser <user> docker`, re-login, verify with `id` |
| vLLM dies at start with CUDA OOM | model + KV cache do not fit; or another process already holds VRAM | check `nvidia-smi` for squatters; lower `--gpu-memory-utilization`, `--max-model-len`, `--max-num-batched-tokens`; `--kv-cache-dtype fp8` |
| NCCL init errors on consumer boards | P2P not available between cards | `NCCL_IGNORE_DISABLED_P2P=1` in the service environment |
| container crashes with driver-lib "cannot open shared object" | container cannot find driver libs (seen on newest GPUs) | set `LD_LIBRARY_PATH: /usr/local/nvidia/lib64:/usr/local/nvidia/lib:/usr/lib/x86_64-linux-gnu` in the service |
| service "hangs" on first start | it is downloading tens of GB of weights | `docker compose logs -f` shows progress; check `df -h`; wait — do not restart in a loop |
| model runs but painfully slow, VRAM at 0 MiB | silent CPU fallback (typical for Ollama without the `deploy` block) | grant the GPU, confirm the process appears in `nvidia-smi` while answering |
| `nvcc: command not found` but driver works | only the driver is installed, or PATH lacks `/usr/local/cuda/bin` | fine for Docker-only hosts; else install `cuda-toolkit-X-Y`, check `update-alternatives --config cuda` |
| apt dependency knot around `nvidia-*` | mixed sources: distro driver + CUDA repo + `.run` leftovers | purge all `nvidia-*` from the foreign source, keep exactly one source (the CUDA repo), `apt -f install` |
| `nouveau` grabbed the cards (rare with repo driver) | blacklist not applied yet | verify `lsmod | grep nouveau`; the packaged driver installs the blacklist — `sudo update-initramfs -u` and reboot |

## Reading vLLM logs

`docker compose logs -f` — the lines that matter:

- `Automatically detected platform cuda` — GPU actually detected;
- weight-loading progress bars — the long phase, be patient;
- `# GPU blocks: N` — KV cache allocated, memory math worked out;
- `Application startup complete` / `Uvicorn running` — API is up, `/health`
  will answer now.
