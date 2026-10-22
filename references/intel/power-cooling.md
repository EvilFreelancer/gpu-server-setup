# Intel Arc: power cap, clocks, fans and idle power

Standalone tasks, done **when the user asks**: a PSU or a tight case cannot
take every card at full board power, the cards run hot, or idle power is too
high. Same discipline as the NVIDIA power-limit runbook
(`../nvidia/monitoring.md`): query first, never invent the wattage, verify
the readback, persist with a systemd unit.

## What can and cannot be controlled from Linux

| Knob | i915 (Alchemist) | xe (Battlemage; Alchemist when force-probed) |
|---|---|---|
| Sustained power limit (PL1) | `hwmon/power1_max`, RW, microwatts | `hwmon/power1_max` (card) or `power2_max` (package, DG2 on xe) |
| Clock cap | `/sys/class/drm/cardN/gt_max_freq_mhz` + `gt_boost_freq_mhz` | `/sys/bus/pci/devices/<bdf>/tile0/gt0/freq0/max_freq` |
| Undervolt | no | no |
| GPU temperature | `hwmon/temp1_input` from kernel **6.13** | `temp2_input` (package) from 6.15, `temp3_input` (VRAM) on DG2 |
| Energy counter | `hwmon/energy1_input` | `energy2_input`, the package only on DG2: it misses VRAM, fans and VRMs |
| Fan speed (read) | `hwmon/fan1_input` from kernel 6.12 | `fan1_input`, `fan2_input` from 6.16 |
| **Fan curve / fan speed (write)** | **no** | not in mainline (Intel patch series adding `pwm*` to xe, 2026, unmerged) |

On xe every hwmon read takes a runtime PM reference and wakes a suspended
card; a poller (telemetry, `arc-maxtemp` under `fancontrol`) then keeps an idle
Alchemist card cycling through sleep and wake. Keep such cards awake
(`driver.md` section 2a).

**The card's own fan curve cannot be changed from Linux.** It lives in the
card firmware and moves only with firmware updates. A custom curve set in
Windows (Arc Control / Intel Graphics Software) is applied by the Windows
driver at runtime and is not stored on the card, so it does not carry over.
`xpu-smi`, LACT and CoolerControl have no Arc fan control either. When a user
asks for "more aggressive GPU cooling", say this plainly and offer what works:

1. less heat: a power cap and, if needed, a clock cap;
2. more air: case and motherboard fans driven by the hottest GPU temperature;
3. less idle heat: ASPM L1, about 10 C lower idle on an A770 (section 4).

## 1. Power cap

**Query first.** hwmon values are microwatts; resolve the hwmon directory per
card every time, the `hwmonN` index changes between boots:

```bash
for c in /sys/class/drm/card[0-9]; do
  h=$(ls -d $c/device/hwmon/hwmon* 2>/dev/null) || continue
  echo "$(basename $(readlink -f $c/device)) $(cat $h/name) PL1=$(( $(cat $h/power1_max)/1000000 ))W rated=$(( $(cat $h/power1_rated_max)/1000000 ))W"
done
```

`power1_rated_max` is the default TDP; partner cards often report `0`, then
the allowed range is unknown and the hardware clamps silently (the readback
shows the clamp only when both firmware limits are non-zero). There is no
`power1_input`: compute watts from `energy1_input` (microjoules) over time:

```bash
h=/sys/class/drm/card0/device/hwmon/hwmon*; e1=$(cat $h/energy1_input); sleep 10; e2=$(cat $h/energy1_input)
echo "$(( (e2 - e1) / 10000000 )) W"
```

**Choosing a value.** Arc A770: total board power 225 W, PL1 usually 190-210
W out of the box. For LLM inference, decode is memory-bound and barely notices
a cap around 75-80 % (170 W on an A770); prefill slows down more. The user
names the number or confirms a proposal.

**Set and verify (the gate):**

```bash
echo 170000000 | sudo tee /sys/class/drm/card0/device/hwmon/hwmon*/power1_max
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_max          # must read back 170000000
cat /sys/class/drm/card0/gt/gt0/throttle_reason_pl1               # 1 while the cap is limiting under load
```

**Persist.** The value is lost at every reboot. Install
`scripts/arc-power-cap.sh` from this skill as `/usr/local/sbin/arc-power-cap`
with a oneshot unit. The script finds cards by PCI device id, waits for the
driver, picks `power1_max` or `power2_max`, optionally caps clocks, and logs
the readback:

```bash
sudo install -m 0755 scripts/arc-power-cap.sh /usr/local/sbin/arc-power-cap
printf 'ARC_IDS="0x56a0"\nARC_PL1_W=170\n# ARC_MAX_MHZ=2000\n' | sudo tee /etc/default/arc-power-cap
sudo tee /etc/systemd/system/arc-power-cap.service >/dev/null <<'EOF'
[Unit]
Description=Power cap (PL1) for Intel Arc GPUs via hwmon
After=systemd-modules-load.service systemd-udev-trigger.service
ConditionPathExists=/usr/local/sbin/arc-power-cap

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/arc-power-cap

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now arc-power-cap
sudo journalctl -u arc-power-cap -b --no-pager     # "<bdf> i915 power1_max: set 170 W, readback 170 W" per card
```

`ARC_IDS` lists the PCI device ids to cap (`lspci -nn`), so mixed hosts cap
only the intended model.

## 2. Clock cap

A lower top clock lowers voltage, so power and heat drop faster than speed.
Set max and boost together (boost is applied separately), within
`gt_RPn_freq_mhz`..`gt_RP0_freq_mhz` (300..2400 MHz on an A770):

```bash
echo 2000 | sudo tee /sys/class/drm/card0/gt_max_freq_mhz /sys/class/drm/card0/gt_boost_freq_mhz
```

`ARC_MAX_MHZ` in `/etc/default/arc-power-cap` persists it through the same
unit.

## 3. Case fans from the GPU temperature

Needs the GPU temperature in hwmon (kernel 6.13+, see `driver.md`) and a
motherboard Super I/O driver with PWM outputs.

**Find the Super I/O chip and its driver:**

```bash
sudo sensors-detect --auto | grep -E 'Found|Driver'
```

| Chip | Driver |
|---|---|
| Nuvoton NCT67xx | `nct6775`, in-tree |
| ITE IT86xx/IT87xx known to mainline | `it87`, in-tree |
| ITE IT8689E, IT8688E and other newer ITE (Gigabyte boards), reported as `unknown chip with ID 0x86..` | out-of-tree <https://github.com/frankcrawford/it87> via DKMS |

Out-of-tree `it87` through DKMS (headers metapackage for the running kernel
flavour must be installed, see `driver.md`):

```bash
sudo git clone https://github.com/frankcrawford/it87.git /usr/local/src/it87
cd /usr/local/src/it87
V=$(sudo git -c safe.directory=$PWD describe --long --always).$(date -u +%Y%m%d)
sudo mkdir -p /usr/src/it87-$V && sudo cp dkms.conf Makefile compat.h it87.c /usr/src/it87-$V/
sudo sed -i "/^PACKAGE_VERSION=/ s/=.*/=\"$V\"/" /usr/src/it87-$V/dkms.conf
sudo dkms add -m it87 -v $V && sudo dkms install -m it87 -v $V -k <KERNEL>
echo it87 | sudo tee /etc/modules-load.d/it87.conf
echo "options it87 ignore_resource_conflict=1" | sudo tee /etc/modprobe.d/it87.conf   # ACPI claims the ports on Gigabyte boards
```

`sudo dkms status` must list it87 as `installed` for every installed kernel
before a reboot, same gate as the NVIDIA module.

**Map PWM outputs to fans.** `pwmconfig` does it interactively by stopping
each output for a few seconds. Leave the CPU fan header under firmware
control: only list case-fan outputs in `fancontrol`. Writing `1` to
`pwmN_enable` takes an output into manual mode; writing back the old value
(usually `2`, automatic) hands it back to the board.

**Drive them from the hottest card.** `fancontrol` (lm-sensors 3.6.2+) accepts
a command as the temperature input: `FCTEMPS=hwmonX/pwmY=!/usr/local/bin/arc-maxtemp`.

```sh
#!/bin/sh
# /usr/local/bin/arc-maxtemp - hottest Arc temperature in millidegrees.
# Prints 100000 (full fan speed) when no GPU temperature is readable.
m=0
for h in /sys/class/drm/card[0-9]/device/hwmon/hwmon*; do
  case "$(cat "$h/name" 2>/dev/null)" in i915|xe) ;; *) continue ;; esac
  for t in "$h"/temp*_input; do
    v=$(cat "$t" 2>/dev/null) || continue
    [ "$v" -gt "$m" ] && m=$v
  done
done
[ "$m" -gt 0 ] || m=100000
echo "$m"
```

Thresholds for Alchemist: within spec up to about 90 C, throttling starts
around there. Aim to keep sustained load at or below 80 C: start ramping at
45-50 C, full speed at 75-80 C, never stop the case fans entirely (`MINPWM`
above the stall point).

**Calibrate before choosing MINPWM.** The PWM scale is not linear, and in
firmware (auto) mode the board reads back a meaningless duty: a Gigabyte B550
showed `pwm=63` while it actually ran the case fans at about 1090 RPM, which
a manual `pwm` of ~175 gives. Sweep each output in manual mode and record RPM
(`pwmN_enable=1`, write 64..255, read `fanN_input`, then restore the old
enable value). "More aggressive than the BIOS" means a `MINPWM` above the
value that reproduces the BIOS idle RPM.

**The hwmon index is not stable.** An out-of-tree `it87` loaded from
`modules-load.d` races the udev-loaded sensors, so its `hwmonN` changes
between boots, and `fancontrol` refuses a config whose `DEVPATH`/`DEVNAME` no
longer match. Keep a template (`/etc/fancontrol.in` with `@HWMON@`,
`@DEVPATH@`, `@DEVNAME@`) and render `/etc/fancontrol` before every start from
a drop-in. The Debian unit runs with `ProtectSystem=strict`, so the renderer
needs the `+` prefix:

```ini
# /etc/systemd/system/fancontrol.service.d/arc.conf
[Unit]
After=systemd-modules-load.service arc-power-cap.service

[Service]
ExecStartPre=
ExecStartPre=+/usr/local/sbin/arc-fancontrol-config
ExecStartPre=/usr/sbin/fancontrol --check
```

```sh
#!/bin/sh
# /usr/local/sbin/arc-fancontrol-config
set -eu
hw=""
for h in /sys/class/hwmon/hwmon*; do
  case "$(cat "$h/name" 2>/dev/null)" in it86*|it87*|nct6*) hw=${h##*/}; break ;; esac
done
[ -n "$hw" ] || { echo "no Super I/O hwmon" >&2; exit 1; }
devpath=$(readlink -f "/sys/class/hwmon/$hw/device" | sed 's#^/sys/##')
devname=$(cat "/sys/class/hwmon/$hw/name")
sed -e "s#@HWMON@#$hw#g" -e "s#@DEVPATH@#$devpath#g" -e "s#@DEVNAME@#$devname#g" \
  /etc/fancontrol.in > /etc/fancontrol.new && mv /etc/fancontrol.new /etc/fancontrol
```

**Gate:** under load (or with a fake hot reading) the chosen `pwmN` rises and
the matching `fanN_input` follows; `systemctl is-active fancontrol`; after a
reboot `journalctl -u fancontrol -b` shows the rendered `hwmonN`.

## 4. Idle power and ASPM

Without PCIe ASPM L1 an Arc A770 idles at about 40 W per card, the card's
own fan curve then holds it around 50-56 C, and a tight case heats up for
nothing. Intel's advice (BIOS "Native ASPM" plus L1 on the root port) is not
enough on Linux, because the kernel never enables L1 on the link above the
card:

- each card is a chain: root port, the card's switch (`4fa0` upstream,
  `4fa4` downstream ports), the GPU (`56a0`) and an HDMI audio function
  (`4f90`);
- L1 is allowed on a link only if every endpoint below it accepts the summed
  L1 exit latency; a kernel quirk (Linux 5.19) lifts the limit for the GPU
  function, but the audio function still declares 64 us, and the outer link
  alone needs up to 64 us plus the internal hop;
- so the whole chain stays in L0. `lspci -vv` shows `ASPM Disabled` on the
  card's upstream bridge even with `pcie_aspm.policy=powersupersave`.

The fix on a headless server: remove the HDMI audio function from the bus,
let the kernel recompute, allow plain L1 only. `scripts/arc-aspm.sh` does it
in a safe order:

0. waits up to `ARC_WAIT_S` seconds (60) until i915 or xe has bound every
   Arc GPU, see "L1 after the driver" below;
1. forbids every ASPM state on all links that are not part of an Arc card
   (NIC, chipset, SATA keep their firmware state);
2. forbids the L1.1/L1.2 substates everywhere;
3. removes the Arc audio functions (`ARC_AUDIO_IDS`);
4. sets the policy to `powersupersave`;
5. checks every Arc link and fails if a card stopped answering.

```bash
sudo install -m 0755 scripts/arc-aspm.sh /usr/local/sbin/arc-aspm
printf 'ARC_IDS="0x56a0"\nARC_AUDIO_IDS="0x4f90"\n' | sudo tee /etc/default/arc-aspm
# unit: same shape as arc-power-cap.service, ExecStart=/usr/local/sbin/arc-aspm
sudo systemctl enable --now arc-aspm
sudo journalctl -u arc-aspm -b -o cat     # "driver bound to every Arc GPU", then "arc-aspm: <bdf> l1_aspm=1" for every Arc link
sudo lspci -vv -s <card upstream bridge> | grep LnkCtl     # ASPM L1 Enabled
```

**L1 after the driver.** A card that gets L1 before i915 or xe probes it never
reaches the deep idle: `LnkCtl` reads `ASPM L1 Enabled` on both ends, the GT
sits in RC6, and the card still draws about 40 W, as if ASPM were off. Turning
L1 off and on again once the driver is up does not bring it back, and neither
does runtime suspend; only a boot in the right order does. The unit is ordered
after `systemd-udev-trigger.service` only, which does not wait for the driver:
the GPU driver loads from the root file system when it is not in the
initramfs, and a fast boot disk lets the unit win the race. Seen on 2x A770
(xe, kernel 7.2.9) after a move from an HDD to an NVMe on 2026-10-22: the unit
finished 10 ms before xe probed the first card, both cards idled at 39-50 W
for a day; with L1 set after the probe they went back under 1 W at once. The
script now waits for the driver itself, so the unit needs no extra ordering. When
the wait times out it still sets L1, exits 1 and says which card had no
driver; such a card needs a reboot that loads the driver first.

To check a box: the journal of the boot shows the driver's `Found dg2` (or
`Found DG2`) lines before the first `arc-aspm: ... l1_aspm=1` line, and the
energy counter of an idle card hardly moves (sample `energy*_input` 10 s apart:
well under 1 W, against 39 W in the bad order).

**Plain L1 only.** On an AMD B550 board the first attempt also enabled
L1.1 on the CPU root-port link (`powersupersave` does that when the root
port advertises substates): that card dropped off the bus at once (config
space reads `ffff`, `Unable to change power state ... device inaccessible`)
and only a reboot brought it back. With substates forbidden the same link
runs L1 stably, and the card behind the chipset never had substates.

**Test before persisting.** On a live box start with a revert timer, and fence
the NIC first:

```bash
sudo systemd-run --on-active=600 /bin/sh -c 'echo default > /sys/module/pcie_aspm/parameters/policy; echo 1 > /sys/bus/pci/rescan'
echo 0 | sudo tee /sys/bus/pci/devices/<nic-bdf>/link/l1_aspm
sudo od -An -tx2 -N2 /sys/bus/pci/devices/<bdf>/config     # 8086 = alive, ffff = card lost
```

Under xe, change a card's link only while the card is awake
(`cat /sys/bus/pci/devices/<bdf>/power/runtime_status` says `active`): writing
`link/l1_aspm` on the link of a runtime-suspended A770 failed its resume and took
it off the bus until a reboot. `arc-aspm` at boot did not hit this on the same box;
with the udev rule of `driver.md` section 2a the cards never suspend at all.

**Measured on 2x A770 (ASRock, B550, kernel 7.2):** idle 50-56 C with the
card fans cycling became 39-45 C with the card fans stopped; llama.cpp
`llama-bench` speed unchanged (pp512 5151 vs 5109 t/s, tg64 51 t/s). The i915
energy counter stops advancing in this deep idle (it reads 0 W), so take idle
watts from a wall meter, not from `energy1_input`.

Reverting: `echo default > /sys/module/pcie_aspm/parameters/policy`, then
`echo 1 > /sys/bus/pci/rescan` brings the audio functions back (their latency
then disables L1 again by itself).
