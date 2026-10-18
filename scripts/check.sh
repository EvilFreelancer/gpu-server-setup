#!/usr/bin/env bash
#
# check.sh — staged verification of a GPU server: host → docker → services.
# Covers NVIDIA and Intel discrete GPUs (Arc); the vendor is detected from lspci.
# Read-only except for one optional `docker run` (ubuntu + nvidia-smi for
# NVIDIA, the Intel compute-runtime image + clinfo for Intel).
#
# Usage:
#   bash check.sh                                   # layer 1 (host) + layer 2 (docker)
#   bash check.sh http://10.0.0.5:8081/health ...   # + layer 3 (each URL must answer 200)
#   bash check.sh --no-docker-run ...               # skip the containerized GPU test
#   bash check.sh --vendor intel ...                # check one vendor only (nvidia|intel)
#   sudo bash check.sh ...                          # Intel: also checks GuC in dmesg
#
# Exit code: 0 = all checks passed (SKIPs allowed), 1 = at least one FAIL.

FAILED=0
DOCKER_RUN_TEST=1
VENDOR=auto
URLS=()
SYSFS=${CHECK_SYSFS:-/sys}
DEVFS=${CHECK_DEVFS:-/dev}
INTEL_GATE_IMAGE=${INTEL_GATE_IMAGE:-intel/compute-runtime:26.31.39395.13-runtime-ubuntu24.04-20260907}
PATH="$PATH:/usr/sbin:/sbin"
export PATH

while [ $# -gt 0 ]; do
  case "$1" in
    --no-docker-run) DOCKER_RUN_TEST=0 ;;
    --vendor) shift; VENDOR=${1:-} ;;
    --vendor=*) VENDOR=${1#--vendor=} ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) URLS+=("$1") ;;
  esac
  shift
done
case "$VENDOR" in
  auto|nvidia|intel) ;;
  *) echo "unknown --vendor '$VENDOR' (nvidia|intel)"; exit 1 ;;
esac

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILED=1; }
skip() { printf 'SKIP  %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }

# Discrete Intel GPUs: DG1 (4905), Alchemist (56xx), Battlemage (e2xx), Max (0bdx).
INTEL_ID_RE='\[8086:(4905|56[0-9a-f]{2}|e2[0-9a-f]{2}|0bd[0-9a-f])\]'

echo "=== Layer 1: host ==="

# GPUs on the PCI bus (VGA/3D/display controllers only, audio functions excluded)
PCI_GPUS=$(lspci 2>/dev/null | grep -iE "vga|3d" | grep -ci nvidia)
INTEL_SLOTS=()
while read -r slot _; do
  [ -n "$slot" ] && INTEL_SLOTS+=("$slot")
done < <(lspci -Dnn 2>/dev/null | grep -iE "vga|3d|display" | grep -E "$INTEL_ID_RE")

CHECK_NVIDIA=0
CHECK_INTEL=0
case "$VENDOR" in
  nvidia) CHECK_NVIDIA=1 ;;
  intel) CHECK_INTEL=1 ;;
  auto)
    [ "${PCI_GPUS:-0}" -gt 0 ] && CHECK_NVIDIA=1
    [ "${#INTEL_SLOTS[@]}" -gt 0 ] && CHECK_INTEL=1
    if [ "$CHECK_NVIDIA" -eq 0 ] && [ "$CHECK_INTEL" -eq 0 ]; then
      fail "lspci: no NVIDIA GPUs visible (and no Intel discrete GPU) — hardware/passthrough problem"
    fi
    ;;
esac

# --- NVIDIA host -------------------------------------------------------------
if [ "$CHECK_NVIDIA" -eq 1 ]; then
  if [ "${PCI_GPUS:-0}" -gt 0 ]; then
    pass "lspci: $PCI_GPUS NVIDIA GPU(s) on the bus"
  else
    fail "lspci: no NVIDIA GPUs visible — hardware/passthrough problem"
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    if SMI_OUT=$(nvidia-smi -L 2>&1); then
      SMI_GPUS=$(printf '%s\n' "$SMI_OUT" | grep -c '^GPU')
      DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
      pass "nvidia-smi: $SMI_GPUS GPU(s), driver ${DRV:-unknown}"
      if [ "$PCI_GPUS" -gt 0 ] && [ "$SMI_GPUS" -ne "$PCI_GPUS" ]; then
        fail "GPU count mismatch: lspci=$PCI_GPUS vs nvidia-smi=$SMI_GPUS"
      fi
    else
      fail "nvidia-smi errors: $(printf '%s' "$SMI_OUT" | head -1) (Secure Boot? DKMS? reboot?)"
    fi
  else
    fail "nvidia-smi not found — driver not installed"
  fi
fi

# --- Intel host --------------------------------------------------------------
INTEL_DRIVERS=()
INTEL_RENDER=()
if [ "$CHECK_INTEL" -eq 1 ]; then
  if [ "${#INTEL_SLOTS[@]}" -gt 0 ]; then
    pass "lspci: ${#INTEL_SLOTS[@]} Intel discrete GPU(s) on the bus"
  else
    fail "lspci: no Intel discrete GPUs visible — hardware/passthrough problem"
  fi

  DMESG=""
  DMESG_OK=0
  if DMESG=$(dmesg 2>/dev/null) && [ -n "$DMESG" ]; then
    DMESG_OK=1
  fi

  for slot in "${INTEL_SLOTS[@]}"; do
    dev="$SYSFS/bus/pci/devices/$slot"
    drv=$(cd "$dev/driver" 2>/dev/null && pwd -P)
    drv=${drv##*/}
    case "$drv" in
      i915|xe)
        pass "$slot: kernel driver $drv"
        INTEL_DRIVERS+=("$drv")
        ;;
      *)
        fail "$slot: no i915/xe driver bound (${drv:-none}) — firmware, force_probe or kernel too old, see references/intel/troubleshooting.md"
        ;;
    esac

    render="$DEVFS/dri/by-path/pci-$slot-render"
    if [ -e "$render" ]; then
      node=$(realpath -e "$render" 2>/dev/null)      # docker --device rejects ':' in paths
      pass "$slot: render node ${node:-$render}"
      INTEL_RENDER+=("${node:-$render}")
    else
      fail "$slot: no render node in $DEVFS/dri/by-path — driver did not initialise the card"
    fi

    # BAR 2 is the VRAM aperture; without Resizable BAR it stays at 256 MiB.
    bar=$(sed -n 3p "$dev/resource" 2>/dev/null)
    read -r start end _ <<< "$bar"
    if [ -n "$end" ] && [ "$((end))" -gt 0 ]; then
      size_mib=$(( (end - start + 1) / 1048576 ))
      if [ "$size_mib" -ge 1024 ]; then
        pass "$slot: Resizable BAR active (BAR2 $size_mib MiB)"
      else
        fail "$slot: BAR2 only $size_mib MiB — enable Above 4G Decoding and Re-Size BAR in BIOS"
      fi
    else
      skip "$slot: cannot read BAR sizes"
    fi

    if [ "$DMESG_OK" -eq 1 ]; then
      if printf '%s\n' "$DMESG" | grep -F "$slot" | grep -qE 'GUC: submission enabled|Using GuC firmware'; then
        pass "$slot: GuC firmware running"
      else
        fail "$slot: no GuC in dmesg — firmware package missing (firmware-intel-graphics / linux-firmware)?"
      fi
    else
      skip "$slot: dmesg not readable, run as root to check GuC"
    fi
    if [ "$DMESG_OK" -eq 1 ] && printf '%s\n' "$DMESG" | grep -F "$slot" | grep -q 'as wedged'; then
      fail "$slot: the driver declared the card wedged — only a reboot brings it back, see references/intel/troubleshooting.md"
    fi

    # xe on Alchemist runtime-suspends an idle card after 1 s; on a 2x A770 box that went
    # together with GuC failures that wedged a card (references/intel/driver.md, 2a).
    if [ "$drv" = xe ]; then
      case "$(cat "$dev/device" 2>/dev/null)" in
        0x56*)
          pm=$(cat "$dev/power/control" 2>/dev/null)
          case "$pm" in
            on) pass "$slot: runtime PM off for Alchemist on xe (power/control=on)" ;;
            "") skip "$slot: cannot read power/control" ;;
            *) warn "$slot: Alchemist on xe with runtime PM on (power/control=$pm) — keep it awake, references/intel/driver.md section 2a" ;;
          esac
          ;;
      esac
    fi
  done
fi

# --- Kernel readiness for every installed kernel ----------------------------
# NVIDIA: DKMS needs headers and a built module for every installed kernel.
# Intel: the driver is in-tree (checked per kernel); headers matter only when
# DKMS modules exist (e.g. an out-of-tree fan driver), and then those modules
# must be built for every installed kernel too.
DKMS_MODS=()
if command -v dkms >/dev/null 2>&1; then
  while read -r m; do
    [ -n "$m" ] && [ "$m" != nvidia ] && DKMS_MODS+=("$m")
  done < <(dkms status 2>/dev/null | sed -n 's#^\([^/, ]*\)[/,].*#\1#p' | sort -u)
fi
HEADERS_NEEDED=$CHECK_NVIDIA
[ "${#DKMS_MODS[@]}" -gt 0 ] && HEADERS_NEEDED=1
MODULES=()
[ "$CHECK_NVIDIA" -eq 1 ] && MODULES+=(nvidia)
while read -r m; do
  [ -n "$m" ] && MODULES+=("$m")
done < <(printf '%s\n' "${INTEL_DRIVERS[@]}" "${DKMS_MODS[@]}" | sort -u)

if [ "$CHECK_NVIDIA" -eq 1 ]; then
  echo "=== Kernel headers and NVIDIA modules (before reboot) ==="
else
  echo "=== Kernel modules for installed kernels (before reboot) ==="
fi

RUNNING_KERNEL=$(uname -r)
KERNELS=("$RUNNING_KERNEL")
HEADER_METAS=()
if command -v dpkg-query >/dev/null 2>&1; then
  if IMAGE_PACKAGES=$(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'linux-image-*' 2>/dev/null); then
    while read -r status package; do
      [ "$status" = "installed" ] || continue
      case "$package" in
        *-dbg|*-dbgsym|*-signed-template|linux-image-extra-*) continue ;;
        linux-image-unsigned-[0-9]*) KERNELS+=("${package#linux-image-unsigned-}") ;;
        linux-image-[0-9]*) KERNELS+=("${package#linux-image-}") ;;
        linux-image-*) HEADER_METAS+=("linux-headers-${package#linux-image-}") ;;
      esac
    done <<< "$IMAGE_PACKAGES"
  else
    fail "cannot list installed kernel images — check the dpkg database"
  fi
  if [ "$HEADERS_NEEDED" -eq 1 ]; then
    # Debian flavours are explicit; Ubuntu's uname suffix cannot distinguish GA/HWE.
    if [ "${#HEADER_METAS[@]}" -eq 0 ]; then
      case "$RUNNING_KERNEL" in
        *-cloud-amd64) HEADER_METAS=(linux-headers-cloud-amd64) ;;
        *-rt-amd64) HEADER_METAS=(linux-headers-rt-amd64) ;;
        *-amd64) HEADER_METAS=(linux-headers-amd64) ;;
        *) fail "cannot determine headers tracking metapackage — restore the matching kernel image/headers tracking pair; do not guess GA/HWE from uname" ;;
      esac
    fi
    while read -r package; do
      [ -n "$package" ] || continue
      if [ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null)" = "installed" ]; then
        pass "headers tracking metapackage: $package"
      else
        fail "headers tracking metapackage missing: $package — install it for future kernel upgrades"
      fi
    done < <(printf '%s\n' "${HEADER_METAS[@]}" | sort -u)
  fi
else
  fail "dpkg-query not found — cannot verify installed kernels"
fi

while read -r kernel; do
  if [ "$HEADERS_NEEDED" -eq 1 ]; then
    if readlink -e "/lib/modules/$kernel/build/Makefile" >/dev/null 2>&1; then
      pass "kernel headers: $kernel"
    else
      fail "kernel headers missing for $kernel — install linux-headers-$kernel before rebooting"
    fi
  fi
  for module in "${MODULES[@]}"; do
    label=$module
    [ "$module" = nvidia ] && label=NVIDIA
    if MODULE=$(modinfo -k "$kernel" -F filename "$module" 2>/dev/null) && [ -n "$MODULE" ]; then
      pass "$label module built for $kernel"
    else
      fail "$label module missing for $kernel — fix headers/DKMS (dkms autoinstall -k $kernel) or the kernel package before rebooting"
    fi
  done
done < <(printf '%s\n' "${KERNELS[@]}" | sort -u)

if [ "$CHECK_NVIDIA" -eq 1 ]; then
  if command -v nvcc >/dev/null 2>&1; then
    pass "nvcc: $(nvcc --version | grep -o 'release [0-9.]*')"
  else
    skip "nvcc not found (fine for Docker-only hosts)"
  fi
fi

echo "=== Layer 2: docker ==="

if command -v docker >/dev/null 2>&1; then
  pass "docker: $(docker --version 2>/dev/null || echo present)"

  if docker compose version >/dev/null 2>&1; then
    pass "docker compose plugin present"
  else
    fail "docker compose plugin missing"
  fi

  if [ "$CHECK_NVIDIA" -eq 1 ]; then
    if docker info 2>/dev/null | grep -qi 'Runtimes:.*nvidia'; then
      pass "nvidia runtime registered in dockerd"
    else
      fail "nvidia runtime not registered — run: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
    fi

    if [ "$DOCKER_RUN_TEST" -eq 1 ]; then
      if DOCKER_SMI=$(docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi -L 2>&1); then
        DOCKER_GPUS=$(printf '%s\n' "$DOCKER_SMI" | grep -c '^GPU')
        if [ "$DOCKER_GPUS" -eq "${SMI_GPUS:-0}" ] && [ "$DOCKER_GPUS" -gt 0 ]; then
          pass "GPU inside container: $DOCKER_GPUS GPU(s) — matches host"
        else
          fail "GPU inside container: $DOCKER_GPUS GPU(s), host has ${SMI_GPUS:-0}"
        fi
      else
        fail "docker run --gpus all failed: $(printf '%s' "$DOCKER_SMI" | head -1)"
      fi
    else
      skip "containerized nvidia-smi test (--no-docker-run)"
    fi
  fi

  if [ "$CHECK_INTEL" -eq 1 ]; then
    if [ "$DOCKER_RUN_TEST" -eq 1 ] && [ "${#INTEL_RENDER[@]}" -gt 0 ]; then
      DEVICE_ARGS=()
      i=0
      for node in "${INTEL_RENDER[@]}"; do
        DEVICE_ARGS+=(--device "$node:/dev/dri/renderD$((128 + i))")
        i=$((i + 1))
      done
      if DOCKER_CL=$(docker run --rm "${DEVICE_ARGS[@]}" "$INTEL_GATE_IMAGE" clinfo -l 2>&1); then
        DOCKER_GPUS=$(printf '%s\n' "$DOCKER_CL" | grep -c 'Device #')
        if [ "$DOCKER_GPUS" -eq "${#INTEL_RENDER[@]}" ]; then
          pass "Intel GPU inside container: $DOCKER_GPUS GPU(s) — matches host"
        else
          fail "Intel GPU inside container: $DOCKER_GPUS GPU(s), host has ${#INTEL_RENDER[@]} render node(s)"
        fi
      else
        fail "docker run --device /dev/dri/... clinfo failed: $(printf '%s' "$DOCKER_CL" | head -1)"
      fi
    elif [ "$DOCKER_RUN_TEST" -eq 0 ]; then
      skip "containerized clinfo test (--no-docker-run)"
    else
      fail "no Intel render nodes to pass into a container"
    fi
  fi
else
  fail "docker not found"
fi

if [ "${#URLS[@]}" -gt 0 ]; then
  echo "=== Layer 3: services ==="
  for url in "${URLS[@]}"; do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)
    if [ "$CODE" = "200" ]; then
      pass "$url -> 200"
    else
      fail "$url -> ${CODE:-no answer}"
    fi
  done
fi

# Informational: which processes actually sit on which GPU. An empty list under
# running services usually means a silent CPU fallback (see troubleshooting.md).
if [ "$CHECK_NVIDIA" -eq 1 ] && command -v nvidia-smi >/dev/null 2>&1 && [ "${SMI_GPUS:-0}" -gt 0 ]; then
  echo "=== GPU placement (compute processes) ==="
  APPS=$(nvidia-smi --query-compute-apps=gpu_bus_id,pid,process_name,used_gpu_memory --format=csv,noheader 2>/dev/null)
  if [ -n "$APPS" ]; then
    printf '%s\n' "$APPS"
  else
    echo "none — no process is on any GPU right now (services idle, absent, or fallen back to CPU)"
  fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All checks passed."
else
  echo "There are failures — fix the FIRST failing layer before anything above it (see references/<vendor>/troubleshooting.md)."
fi
exit "$FAILED"
