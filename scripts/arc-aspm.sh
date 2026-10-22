#!/bin/sh
# arc-aspm - PCIe ASPM L1 for Intel Arc cards only, to cut their idle power.
#
# Without ASPM L1 an Arc A770 idles at about 40 W. The kernel will not enable
# L1 on the link above the card by itself: the card's HDMI audio function
# accepts only 64 us of L1 exit latency, the path exceeds that, so the whole
# chain stays in L0 (the quirk in drivers/pci/quirks.c covers the GPU function
# only). This script:
#   0. waits until i915 or xe has bound every Arc GPU: a card that gets L1 before
#      the driver probes it never reaches its deep idle and stays at about 40 W,
#      and turning L1 off and on again later does not bring it back (2x A770,
#      xe, 2026-10-22: a boot from NVMe ran this before xe probed the cards);
#   1. forbids every ASPM state on every link that is NOT part of an Arc card
#      (NICs, chipset, SATA keep their firmware state, which is usually off);
#   2. forbids the L1.1/L1.2 substates everywhere (L1.1 on a CPU root-port link
#      dropped an A770 off the bus on an AMD B550 board; plain L1 was stable);
#   3. removes the Arc HDMI audio functions (useless on a headless box);
#   4. switches the kernel policy to powersupersave, which now can only reach
#      plain L1 on the Arc links;
#   5. prints the resulting state of every Arc link and fails if a card's
#      config space no longer answers.
# Config: /etc/default/arc-aspm (ARC_IDS, ARC_AUDIO_IDS, ARC_WAIT_S). Revert: write
# "default" to /sys/module/pcie_aspm/parameters/policy, then
# "echo 1 > /sys/bus/pci/rescan" brings the audio functions back.
set -u
CONF=${ARC_CONF:-/etc/default/arc-aspm}
[ -r "$CONF" ] && . "$CONF"
: "${ARC_IDS:=0x56a0}"           # GPU PCI device ids
: "${ARC_AUDIO_IDS:=0x4f90}"     # their HDMI audio functions (DG2: 0x4f90-0x4f92)
: "${ARC_WAIT_S:=60}"            # how long to wait for i915/xe to bind every card
SYS=${SYS:-/sys}
DEVS=$SYS/bus/pci/devices

is_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
dev_id() { cat "$DEVS/$1/device" 2>/dev/null; }
vendor() { cat "$DEVS/$1/vendor" 2>/dev/null; }

# Arc chain: the GPU plus every Intel bridge above it (the card's own PCIe
# switch), stopping at the first non-Intel ancestor (root port or chipset).
chain=""
gpus=""
for d in "$DEVS"/*; do
  b=${d##*/}
  [ "$(vendor "$b")" = 0x8086 ] && is_in "$(dev_id "$b")" "$ARC_IDS" || continue
  gpus="$gpus $b"
  path=$(cd "$d" 2>/dev/null && pwd -P) || continue
  while :; do
    node=${path##*/}
    case "$node" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]:*) ;; *) break ;; esac
    [ "$(vendor "$node")" = 0x8086 ] || break
    chain="$chain $node"
    path=${path%/*}
  done
done
[ -n "$gpus" ] || { echo "arc-aspm: no Arc GPU with ids: $ARC_IDS" >&2; exit 1; }

rc=0
# L1 only after the driver has probed every card (step 0 above).
t=0
while :; do
  unbound=""
  for b in $gpus; do
    case "$(readlink "$DEVS/$b/driver" 2>/dev/null)" in
      */i915|*/xe) ;;
      *) unbound="$unbound $b" ;;
    esac
  done
  [ -z "$unbound" ] && { echo "arc-aspm: driver bound to every Arc GPU after ${t} s"; break; }
  if [ "$t" -ge "$ARC_WAIT_S" ]; then
    echo "arc-aspm: no i915/xe on$unbound after ${ARC_WAIT_S} s; setting L1 anyway, but these cards will not reach their deep idle until a reboot that loads the driver first" >&2
    rc=1
    break
  fi
  sleep 1; t=$((t + 1))
done

for d in "$DEVS"/*; do
  b=${d##*/}
  [ -d "$d/link" ] || continue
  for f in "$d"/link/l1_1_aspm "$d"/link/l1_2_aspm "$d"/link/l1_1_pcipm "$d"/link/l1_2_pcipm; do
    [ -e "$f" ] && { echo 0 > "$f" || rc=1; }
  done
  if ! is_in "$b" "$chain"; then
    for f in "$d"/link/l0s_aspm "$d"/link/l1_aspm "$d"/link/clkpm; do
      [ -e "$f" ] && { echo 0 > "$f" || rc=1; }
    done
  fi
done

for d in "$DEVS"/*; do
  b=${d##*/}
  [ "$(vendor "$b")" = 0x8086 ] && is_in "$(dev_id "$b")" "$ARC_AUDIO_IDS" || continue
  echo "arc-aspm: removing Arc audio function $b"
  echo 1 > "$d/remove" || rc=1
done

echo powersupersave > "$SYS/module/pcie_aspm/parameters/policy" || rc=1

for b in $chain; do
  [ -e "$DEVS/$b/link/l1_aspm" ] || continue
  if [ "$(od -An -tx2 -N2 "$DEVS/$b/config" 2>/dev/null | tr -d ' ')" != 8086 ]; then
    echo "arc-aspm: $b does not answer config reads, card lost; reboot" >&2
    rc=1
    continue
  fi
  echo "arc-aspm: $b l1_aspm=$(cat "$DEVS/$b/link/l1_aspm")"
done
exit "$rc"
