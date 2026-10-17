# Troubleshooting Intel Arc

Debug **in layer order**: host GPU, then Docker, then the service. A failure
in layer N makes every layer above it fail too.

## The 3-layer checklist

```bash
# 1. Host sees every card, driver bound, firmware running, ReBAR on
lspci -nn | grep -Ei 'vga|3d|display'
ls -l /dev/dri/by-path/
sudo dmesg | grep -E 'GuC firmware|GUC: submission|HuC: auth|reduced BAR'

# 2. Docker sees every card
docker run --rm --device /dev/dri intel/compute-runtime:<tag> clinfo -l

# 3. Service answers and actually runs on the GPU
curl -s http://<SERVER_IP>:8080/health
intel_gpu_top -d pci:slot=<bdf>        # Render/Compute busy while it answers
```

`sudo bash scripts/check.sh` runs layers 1-2 (as root it also reads GuC from
dmesg) and verifies that i915/xe and every DKMS module exist for every
installed kernel.

## Symptom, cause, fix

| Symptom | Likely cause | Fix |
|---|---|---|
| card in `lspci`, no `/dev/dri/by-path/pci-<bdf>-render` | no driver bound: Battlemage on i915 or a kernel without its id; DG2 bound to xe without `force_probe` | `lspci -k -s <bdf>`; Alchemist: i915 (default); Battlemage: xe on a recent kernel (backports) |
| dmesg: `GuC firmware ... failed to load`, `-ENOENT`, `wedged` | firmware package missing or older than the kernel expects | install `firmware-intel-graphics` (Debian 13; `firmware-misc-nonfree` on Debian 12, `linux-firmware` on Ubuntu) from the same suite as the kernel, `update-initramfs -u`, reboot |
| `Using a reduced BAR size of 256MiB` | Resizable BAR off | BIOS: Above 4G Decoding on, Re-Size BAR on, CSM off |
| config space of a card reads `ffff`, `Unable to change power state from D3hot to D0, device inaccessible`, the card vanished from `clinfo` | the link died, typically after enabling ASPM L1.1 substates on a CPU root-port link | reboot (a warm reboot retrains the link); then allow plain L1 only (`power-cooling.md` section 4) |
| idle about 40 W per card, cards at 50-56 C doing nothing | ASPM L1 is off on the card's upstream link (the HDMI audio function's 64 us latency blocks it) | `scripts/arc-aspm.sh` (`power-cooling.md` section 4) |
| `sensors` shows `fan1` but no `temp1` for i915 | kernel older than 6.13 | backports kernel (`driver.md` section 2) |
| hwmon `power1_max` write accepted, readback different | the firmware clamps silently to its own range | use a value inside the card's real range; `power1_rated_max` of 0 means the range is not reported |
| `sensors-detect`: `Found unknown chip with ID 0x8689` (Gigabyte boards), `modprobe it87` says `No such device` | mainline it87 does not know the Super I/O | out-of-tree `frankcrawford/it87` via DKMS with `ignore_resource_conflict=1` (`power-cooling.md` section 3) |
| `fancontrol` does not start after a reboot: `Configuration appears to be outdated` | the Super I/O `hwmonN` index changed | render `/etc/fancontrol` from a template before every start (`power-cooling.md` section 3) |
| case fans slower under `fancontrol` than under the BIOS | the BIOS auto mode reads back a meaningless duty | calibrate RPM against `pwm` in manual mode, set `MINPWM` above the BIOS idle RPM |
| `docker: bad format for path: /dev/dri/by-path/pci-0000:...` | `--device` splits on `:` | pass the resolved node (`realpath ...`) |
| container sees no GPU, host is fine | no `--device /dev/dri` / `devices:` entry | add the device grant; containers see zero GPUs by default |
| container as non-root: `Permission denied` on `/dev/dri/renderD*` | the image's `render` GID differs from the host's | `group_add: ["<host render GID>"]` (`stat -c %g /dev/dri/renderD128`) |
| `Required aspect fp64 is not supported` | Alchemist has no FP64; the image or kernel needs it | vLLM: `VLLM_XPU_USE_SAMPLER_KERNEL=0`; otherwise a stack without the FP64 path (`stacks.md`) |
| llama.cpp SYCL: garbled output or crash with two cards | device-to-device copies | `GGML_SYCL_DEV2DEV_MEMCPY=2` |
| llama.cpp SYCL: `DEVICE_LOST` at long context | oneDNN flash-attention path | `GGML_SYCL_FA_ONEDNN_MAX_KV=24576` |
| service "hangs" on first start | weights downloading, or SPIR-V JIT and Triton autotune (vLLM) | watch logs; keep the cache volumes so the next start is fast |
| llama.cpp SYCL needs about 80 s to answer `/health` after every restart | JIT compilation of the SYCL kernels, the compiler cache dies with the container | mount `/root/.cache` as a volume (`stacks.md`); or an AOT build for the card's architecture |
| `can't allocate 5000000000 Bytes of memory on device`, `can NOT allocate memory block with size larger than 4GB` | the ~4 GiB single-allocation limit of Intel GPUs | `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1` for that service (not `..._USE_...`); the official llama.cpp image does not need it, AOT builds of llama.cpp do |
| model loads take minutes | HDD root disk, a 16 GB image plus the weights | put `/srv/models` and Docker's data on SSD/NVMe when there is one |
| `mei ... Could not read FW version` in dmesg | partner-card GSC quirk | harmless for compute |
