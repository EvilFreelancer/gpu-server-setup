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
  crawl, allocations fail and the cards can behave erratically; i915 logs
  `Using a reduced BAR size`. Fix in BIOS: Above 4G Decoding on, Re-Size BAR
  on, CSM off (Re-Size BAR needs UEFI boot). Check it before installing
  anything; `scripts/check.sh` fails on a BAR2 below 1 GiB.
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
| Alchemist (DG2, `0x56xx`) | **i915** | xe needs `i915.force_probe=!<id> xe.force_probe=<id>` on every kernel up to at least 7.3; force-probed, HuC is not loaded under xe (media only). Faster for compute and less stable, see section 2a before switching |
| Battlemage (BMG, `0xe2xx`) | **xe** | i915 does not support it; use a kernel of 6.12 or newer, preferably the newest available |

Start on the default driver and prove the gates on it. Never run both: one
card, one driver.

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

### 2a. Alchemist on xe: what it gives and what it costs

Measured on 2x A770 16 GB (6-core Ryzen host, kernel 7.2 from trixie-backports,
GuC 70.53.0), the same images, weights and load tests before and after the
switch. The CPU governor went from `powersave` to `performance` at the same time,
so the host-bound gains belong to both changes.

| Workload | i915 | xe |
|---|---|---|
| llama.cpp SYCL, MoE 35B-A3B Q4_K_M, decode for one user | 20.1 t/s | 43.5 t/s |
| llama.cpp SYCL, dense 27B Q4_K_M, decode for one user | 6.7 t/s | 8.3 t/s with the same quant, 13.2 t/s with a quant that keeps the reorder path (`stacks.md`) |
| vLLM 0.31, dense 27B AWQ, pipeline parallel 2, one user | 1.7 t/s | 8.4 t/s |
| vLLM 0.31, MoE 35B-A3B GPTQ, one user | 0.7 t/s | 2.4 t/s |
| whisper.cpp SYCL, large-v3-turbo q8_0 | 20x real time | 30x real time |
| sentence-transformers embedders, texts/s | | +5 % (a GPU-bound 4B model) to 2.7x (a server that waited on the host) |

Vectors, transcripts and LLM answers were identical on both drivers. vLLM
still does not scale with users on xe (`stacks.md`).

What it costs:

- **A card can wedge, and only a reboot brings it back.** A GuC crash
  (`GuC Crash dump notification`) or a lost host-to-GuC message
  (`FAST_REQ H2G fence ... failed`, `CT dequeue failed: -71`) makes xe reset the
  GT; reloading the GuC then fails (`load failed ... Auth = 0x01`,
  `firmware signature verification failed`) and xe declares the device wedged.
  Unbinding and binding xe, an FLR and a secondary bus reset all end in the same
  signature failure (`probe with driver xe failed with error -71`). Seen twice on
  one of two cards within an hour, under a llama.cpp load test and during a vLLM
  start; the other card and everything running on it kept working.
- **Runtime PM.** xe runtime-suspends an idle card after one second
  (`power/control=auto`, `autosuspend_delay_ms=1000`), and every hwmon read wakes
  it again, so a telemetry or fan script that polls every few seconds turns idle
  time into a sleep and wake cycle every few seconds. With the cards kept awake
  by the rule below, the same workloads ran for more than three hours without a
  single GuC, CT or reset message. That is a correlation from one box, not a
  proven cause; keep the rule anyway, it costs nothing measurable in speed:

  ```bash
  # /etc/udev/rules.d/80-arc-runtime-pm.rules
  # xe allows runtime PM itself at probe, so the rule fires on bind, after it.
  ACTION=="bind", SUBSYSTEM=="pci", DRIVER=="xe", ATTR{vendor}=="0x8086", ATTR{device}=="0x56*", ATTR{power/control}="on"
  ```

  Check after the next boot: `cat /sys/bus/pci/devices/<bdf>/power/control` is
  `on` and `power/runtime_suspended_time` stays at 0. `scripts/check.sh` warns when
  an Alchemist card on xe still has runtime PM on.
- **Never change a card's link settings while it is runtime-suspended.** Writing
  `link/l1_aspm` on the link of a suspended card made the resume fail
  (`Unable to change power state from D3hot to D0, device inaccessible`, config
  space reads `ffff`) and the card stayed off the bus until a reboot. With the
  rule above the cards are never suspended.
- **vLLM:** `[drm] VM worker error: -12` in the kernel log, on the card with the
  larger pipeline stage, killed the engine during first requests that were still
  JIT-compiling kernels; with a warm compiler cache it did not happen.
- **sysfs and debugfs move.** hwmon on DG2 under xe: `temp2_input` (package) and
  `temp3_input` (VRAM), `power2_max` (package; there is no `power1`),
  `energy2_input`, which counts the package only, not the whole card (0.3-0.9 W
  idle, so it says nothing about the wall), `fan1_input` and `fan2_input`. GT
  clocks and throttle reasons are under
  `/sys/bus/pci/devices/<bdf>/tile0/gt0/freq0/`. debugfs: VRAM in `tile0/vram_mm`,
  the GuC as `found release version X` in `gt0/uc/guc_info`. The scripts of this
  skill handle both drivers.
- Tips that changed nothing here: pinning the GT minimum frequency to the
  maximum (`tile0/gt0/freq0/min_freq`), and the newest compute runtime in the image
  (NEO 26.35 with IGC 2.41 instead of the 26.27 of the vLLM image; it also
  recompiled every kernel for 5 minutes on the first start).

Switch, after the i915 gates passed, and the way back:

```bash
# /etc/default/grub, keep a copy of the old file
GRUB_CMDLINE_LINUX_DEFAULT="quiet i915.force_probe=!56a0 xe.force_probe=56a0"
sudo update-grub && sudo reboot          # back to i915: drop both parameters, update-grub, reboot
```

The kernel logs `Setting dangerous option force_probe - tainting kernel`, which
is expected. Re-run the stage-1 and stage-2 gates; under xe the GuC line is
`Using GuC firmware from i915/dg2_guc_70.bin version 70.x.y` and there is no HuC
line.

Worth it for a box that serves LLMs, embeddings or speech on Alchemist when a
reboot after a rare wedge is acceptable. Where unattended stability matters
more than speed, stay on i915.

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

Expected per card on i915: `GuC firmware i915/dg2_guc_70.bin version 70.x.y`,
`GUC: submission enabled`, `HuC: authenticated for all workloads`, and no
`reduced BAR` line; on xe: `Using GuC firmware from ... version 70.x.y` and no HuC
line (section 2a). `sudo cat /sys/kernel/debug/dri/<pci-slot>/gt0/uc/guc_info`
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
