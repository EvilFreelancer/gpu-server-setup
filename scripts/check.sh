#!/usr/bin/env bash
#
# check.sh — staged verification of a GPU server: host → docker → services.
# Read-only except for one optional `docker run` of the ubuntu image.
#
# Usage:
#   bash check.sh                                   # layer 1 (host) + layer 2 (docker)
#   bash check.sh http://10.0.0.5:8081/health ...   # + layer 3 (each URL must answer 200)
#   bash check.sh --no-docker-run ...               # skip the containerized nvidia-smi test
#
# Exit code: 0 = all checks passed (SKIPs allowed), 1 = at least one FAIL.

FAILED=0
DOCKER_RUN_TEST=1
URLS=()

for arg in "$@"; do
  case "$arg" in
    --no-docker-run) DOCKER_RUN_TEST=0 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) URLS+=("$arg") ;;
  esac
done

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILED=1; }
skip() { printf 'SKIP  %s\n' "$1"; }

echo "=== Layer 1: host ==="

# GPUs on the PCI bus (VGA/3D controllers only, audio functions excluded)
PCI_GPUS=$(lspci 2>/dev/null | grep -iE "vga|3d" | grep -ci nvidia)
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

if command -v nvcc >/dev/null 2>&1; then
  pass "nvcc: $(nvcc --version | grep -o 'release [0-9.]*')"
else
  skip "nvcc not found (fine for Docker-only hosts)"
fi

echo "=== Layer 2: docker ==="

if command -v docker >/dev/null 2>&1; then
  pass "docker: $(docker --version 2>/dev/null || echo present)"

  if docker compose version >/dev/null 2>&1; then
    pass "docker compose plugin present"
  else
    fail "docker compose plugin missing"
  fi

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
if command -v nvidia-smi >/dev/null 2>&1 && [ "${SMI_GPUS:-0}" -gt 0 ]; then
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
  echo "There are failures — fix the FIRST failing layer before anything above it (see references/troubleshooting.md)."
fi
exit "$FAILED"
