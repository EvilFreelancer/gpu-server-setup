#!/bin/sh
# arc-power-cap - apply a sustained power limit (PL1) and an optional clock cap
# to every Intel Arc card, resolving hwmon paths by PCI device id at run time.
set -u
CONF=${ARC_CONF:-/etc/default/arc-power-cap}
[ -r "$CONF" ] && . "$CONF"
: "${ARC_IDS:=0x56a0}"     # PCI device ids, space separated (A750 = 0x56a1)
: "${ARC_PL1_W:=170}"      # sustained limit in W (hwmon wants microwatts)
: "${ARC_TAU_MS:=}"        # optional averaging window, ms (power1_max_interval)
: "${ARC_MAX_MHZ:=}"       # optional GT max/boost clock cap, MHz
: "${ARC_WAIT_S:=60}"      # how long to wait for the driver to bind
SYS=${SYS:-/sys}

devs=""
for d in "$SYS"/bus/pci/devices/*; do
  [ "$(cat "$d/vendor" 2>/dev/null)" = 0x8086 ] || continue
  case " $ARC_IDS " in *" $(cat "$d/device") "*) devs="$devs $d" ;; esac
done
[ -n "$devs" ] || { echo "no PCI devices with ids: $ARC_IDS" >&2; exit 1; }

rc=0
for d in $devs; do
  bdf=${d##*/}; hw=""; t=0
  while [ "$t" -lt "$ARC_WAIT_S" ]; do          # hwmonN index is not stable
    for h in "$d"/hwmon/hwmon*; do
      [ -r "$h/name" ] || continue
      case "$(cat "$h/name")" in i915|xe) hw=$h; break ;; esac
    done
    [ -n "$hw" ] && break
    sleep 1; t=$((t + 1))
  done
  [ -n "$hw" ] || { echo "$bdf: no i915/xe hwmon" >&2; rc=1; continue; }

  f=""                                          # i915: power1_max; xe on DG2: power2_max
  for a in power1_max power2_max; do
    [ -w "$hw/$a" ] && { f=$hw/$a; break; }
  done
  [ -n "$f" ] || { echo "$bdf: no writable power*_max" >&2; rc=1; continue; }
  echo $((ARC_PL1_W * 1000000)) > "$f" || rc=1
  [ -n "$ARC_TAU_MS" ] && { echo "$ARC_TAU_MS" > "${f}_interval" || rc=1; }

  if [ -n "$ARC_MAX_MHZ" ]; then
    for c in "$d"/drm/card*; do                 # i915
      [ -w "$c/gt_max_freq_mhz" ] || continue
      echo "$ARC_MAX_MHZ" > "$c/gt_max_freq_mhz" || rc=1
      echo "$ARC_MAX_MHZ" > "$c/gt_boost_freq_mhz" || rc=1
    done
    for x in "$d"/tile*/gt*/freq0/max_freq; do  # xe
      [ -w "$x" ] && { echo "$ARC_MAX_MHZ" > "$x" || rc=1; }
    done
  fi
  echo "$bdf $(cat "$hw/name") ${f##*/}: set ${ARC_PL1_W} W, readback $(($(cat "$f") / 1000000)) W"
done
exit "$rc"
