# Intel Arc: kernel driver, firmware and host tools

Covers discrete Intel GPUs on Debian/Ubuntu: Alchemist (Arc A770, A750, A380,
Arc Pro A-series, PCI ids `0x56xx`) and Battlemage (Arc B580, B570, Arc Pro
B50/B60/B70, ids `0xe2xx`). Checked on 2026-10-17 against Debian 13 with
kernels 6.12 and 7.2 (trixie-backports).

The big difference from NVIDIA: **the driver is in the kernel.** There is no
vendor apt repo, no DKMS and no reboot-time module build; the distro kernel
plus the distro firmware package is the whole host driver. The compute
user-space (Level Zero, OpenCL, SYCL) belongs inside the containers.

## 1. Check hardware and BIOS first

```bash
lspci -nn | grep -Ei 'vga|3d|display'          # every card, e.g. "DG2 [Arc A770] [8086:56a0]"
lspci -tv                                     # where each card hangs: CPU root port or chipset
sudo lspci -vv -d 8086: | grep -E 'Resizable BAR|BAR 2: current size'
```

- **Resizable BAR is mandatory.** `BAR 2: current size` must equal the VRAM
  (16GB on an A770 16 GB). Without it only 256 MiB is CPU-visible, model loads
  crawl and allocations fail; i915 logs `Using a reduced BAR size`. Fix in
  BIOS: Above 4G Decoding on, Re-Size BAR on, CSM off.
- **Read the real link on the card's upstream bridge.** An Arc card carries
  its own PCIe switch (`Device 4fa0` upstream, `4fa4` downstream), so the GPU
  function always shows a fake `2.5GT/s x1`. The bridge above it shows what
  the slot gives:

  ```bash
  for b in $(lspci -d 8086:4fa0 | cut -d' ' -f1); do
    echo "$b $(cat /sys/bus/pci/devices/0000:$b/current_link_speed) x$(cat /sys/bus/pci/devices/0000:$b/current_link_width)"
  done
  ```

  Consumer boards often wire the second x16 slot through the chipset at PCIe
  3.0 x2 or x4. Record it: it decides whether splitting one model across cards
  makes sense (`stacks.md`).
- Secure Boot does not matter: i915/xe are in-tree and signed by the distro.

## 2. Kernel driver: i915 or xe

| Generation | Default driver | Notes |
|---|---|---|
| Alchemist (DG2, `0x56xx`) | **i915** | xe needs `i915.force_probe=!<id> xe.force_probe=<id>` on every kernel up to at least 7.3; experimental, HuC was still missing in mid-2026 |
| Battlemage (BMG, `0xe2xx`) | **xe** | i915 does not support it; use a kernel of 6.12 or newer, preferably the newest available |

Stay on the default driver. Community benchmarks show xe giving better SYCL
decode on DG2 (llama.cpp 9.8 to 13.9 t/s), so it is a valid experiment, but
never run both: one card, one driver.

Kernel choice for Alchemist on Debian 13: the stock 6.12 works for compute,
but i915 only exposes the GPU temperature in hwmon from **6.13**
(`temp1_input`). When the host has to see GPU temperatures (monitoring,
fan control from GPU temperature), install the kernel from
`trixie-backports`:

```bash
echo "deb http://deb.debian.org/debian trixie-backports main contrib non-free non-free-firmware" | \
  sudo tee /etc/apt/sources.list.d/trixie-backports.list
sudo apt update
sudo apt -y install -t trixie-backports linux-image-amd64 linux-headers-amd64 firmware-intel-graphics
```

Installed backports packages keep upgrading from backports. Headers are only
needed when an out-of-tree module (DKMS) is built for this kernel, such as
the `it87` fan driver from `power-cooling.md`; then the same rule as for
NVIDIA applies: the tracking `linux-headers-<flavour>` metapackage stays
installed so DKMS rebuilds for every future kernel before its first boot.

## 3. Firmware

i915/xe load GuC (scheduling, power management via SLPC), HuC (media) and DMC
(display) from `/lib/firmware/i915/` (Alchemist) or `/lib/firmware/xe/`
(Battlemage):

| Distro | Package |
|---|---|
| Debian 13 | `firmware-intel-graphics` (non-free-firmware) |
| Debian 12 | `firmware-misc-nonfree` (non-free-firmware) |
| Ubuntu | `linux-firmware` |

`non-free-firmware` must be enabled in the apt sources. Take the firmware from
the same suite as the kernel (backports kernel, backports firmware).

**GATE (host): every card is bound and its firmware runs.**

```bash
lspci -k -d 8086: | grep -A2 -E 'VGA|Display' | grep 'in use'    # i915 (or xe) per card
ls -l /dev/dri/by-path/                                            # a -card and a -render node per card
sudo dmesg | grep -E 'GuC firmware|GUC: submission|HuC: authenticated|reduced BAR'
```

Expected per card: `GuC firmware i915/dg2_guc_70.bin version 70.x.y`,
`GUC: submission enabled`, `HuC: authenticated for all workloads`, and no
`reduced BAR` line. `sudo cat /sys/kernel/debug/dri/<pci-slot>/gt0/uc/guc_info`
must say `status: RUNNING`. The count of render nodes in `by-path` must equal
the count of cards in `lspci`.

`mei ... Could not read FW version` from `mei-gscfi` is common on partner
cards and harmless for compute.

## 4. Host tools

All from the distro, nothing compiled:

```bash
sudo apt -y install intel-gpu-tools nvtop lm-sensors
sudo adduser <USERNAME> render        # plus video; then re-login
```

| Tool | What it shows |
|---|---|
| `intel_gpu_top -L`, `intel_gpu_top -d pci:slot=0000:05:00.0` | card list, engine load, frequency, power |
| `nvtop` | per-card load and memory for i915/xe (fdinfo), all vendors in one view |
| `sensors` | i915 hwmon: fan RPM, power cap, energy, GPU temperature from kernel 6.13 |
| `cat /sys/class/drm/card*/gt_act_freq_mhz` | current GT clock |

Not needed on the host:

- **Compute runtime** (`intel-opencl-icd`, `libze-intel-gpu1`): every serving
  image carries its own. Debian 13 does not even ship it (only forky/sid, not
  installable on trixie); Ubuntu has it in universe (26.04) and in the
  `kobuk-team/intel-graphics` PPA. On Debian, if the host itself must run
  OpenCL/Level Zero, the only clean source is the pinned `.deb` set from
  <https://github.com/intel/compute-runtime/releases> (exact IGC version
  match, manual updates).
- **xpu-smi / XPU Manager**: officially supports Data Center and Arc Pro
  B-series only; on consumer Alchemist it works partly at best and needs that
  compute runtime on the host. hwmon, `intel_gpu_top` and `nvtop` cover the
  same ground.
- **oneAPI Base Toolkit** on the host: only for compiling SYCL code; build in
  `intel/oneapi-toolkit` containers instead.

## 5. Long-running compute kernels

i915 kills a compute submission that runs longer than
`CONFIG_DRM_I915_REQUEST_TIMEOUT` (20 s on Debian) and resets engines that
miss the heartbeat. Inference kernels stay far below that. If a long kernel
does get killed, raise the per-engine knobs before touching module
parameters:

```bash
cat /sys/class/drm/card0/engine/ccs0/{heartbeat_interval_ms,preempt_timeout_ms}
```

`i915.enable_hangcheck=0` is an unsafe parameter (it taints the kernel) and an
old recipe; do not set it by default. Never change `i915.enable_guc`.
