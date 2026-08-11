# NVIDIA driver + CUDA from the official repo

Everything installs from **NVIDIA's CUDA apt repository** — never mix it with
distro `nvidia-*` packages, `ubuntu-drivers autoinstall`, or `.run` installers.
One source, or you get dependency knots that are painful to untangle.

Supported here: **Debian 10–13** and **Ubuntu 20.04–24.04**, x86_64.

## 1. Check OS and hardware first

```bash
cat /etc/issue.net                     # or: . /etc/os-release && echo $ID $VERSION_ID
lspci | grep -E "VGA|3D|NVIDIA"        # every GPU must be listed here
```

If `lspci` shows no NVIDIA device — stop. That is a hardware / VM-passthrough
problem, no driver will fix it.

## 2. Add the CUDA repo (cuda-keyring)

Substitute `$distro/$arch` with the real values — `debian12/x86_64`,
`ubuntu2404/x86_64`, `ubuntu2204/x86_64`, … Full list:
https://developer.download.nvidia.com/compute/cuda/repos/

```bash
cd /tmp
wget https://developer.download.nvidia.com/compute/cuda/repos/$distro/$arch/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update
ls -la /etc/apt/sources.list.d/ | grep cuda    # cuda-$distro-$arch.list must exist
```

## 3. Kernel headers (DKMS prerequisite)

The repo driver builds its kernel module via DKMS. On minimal installs headers
are often missing and the module silently fails to build:

```bash
sudo apt -y install linux-headers-$(uname -r)   # Debian; Ubuntu: linux-headers-generic
```

## 4. Install driver (+ CUDA toolkit when needed)

Two working patterns:

**Metapackages (Debian-style, always-latest):**

```bash
sudo apt -y install nvidia-open                     # open modules — Turing and newer
sudo apt -y install nvidia-driver                   # proprietary — Pascal and older ONLY
sudo apt -y install nvidia-open cuda-toolkit-13-1   # + toolkit when the host compiles
```

Watch the metapackage names: plain `nvidia-driver` resolves its kernel-module
alternative to the **proprietary** one, so on Turing+ install `nvidia-open`
(it pulls `nvidia-kernel-open-dkms` and conflicts with the proprietary
module). The full `cuda` metapackage drags the proprietary driver chain in —
pair `nvidia-open` with `cuda-toolkit-X-Y` instead when you need the toolkit
next to open modules.

**Versioned packages (Ubuntu-style, explicit):**

```bash
sudo apt -y install nvidia-driver-590-open nvidia-utils-590 cuda-toolkit-13-1
```

Decisions to make with the user:

- **Do you need CUDA on the host at all?** For Docker-only inference (vLLM,
  llama.cpp, Ollama) the host needs **only the driver** — CUDA lives inside the
  images. Install `cuda-toolkit-X-Y` only to compile things on the host; the
  full `cuda` metapackage additionally drags the driver in.
- **Open vs proprietary kernel modules.** Open GPU kernel modules
  (Debian-style `nvidia-open`, Ubuntu-style `nvidia-driver-XXX-open`) are for
  Turing (RTX 20xx) and newer, and the only option for the newest generations
  (e.g. Blackwell RTX 6000 needs driver >= 590, open). Pascal and older
  (GTX 10xx) need the proprietary module — plain `nvidia-driver` without
  `-open`.
- **Minimum driver for the card.** New GPU generations require a minimum driver
  branch; check the release notes when the card is recent. Symptom of too-old
  driver: `nvidia-smi` works but shows `ERR!` or the card is missing.

**Reboot after installing the driver**, then gate:

```bash
sudo reboot
# after relogin:
nvidia-smi
```

All GPUs listed, driver version shown → pass. Note: the CUDA version in the
`nvidia-smi` header ("CUDA Version"; renamed to "CUDA UMD Version" on driver
610+) is the **max the driver supports**, not an installed toolkit.

## 5. Multiple CUDA versions and alternatives

CUDA versions coexist, one directory each in `/usr/local/`:

```bash
ls -la /usr/local/ | grep cuda
```

`/usr/local/cuda` is a symlink managed by Debian alternatives. Switch globally:

```bash
sudo update-alternatives --config cuda
nvcc --version          # verify the release line matches your choice
```

If `nvcc` is not found, the toolkit is not installed or `/usr/local/cuda/bin`
is not in `PATH`.

## 6. Pin the driver against surprise upgrades

Unattended upgrades can bump the driver's userland while the loaded kernel
module stays old → every CUDA app dies with "Driver/library version mismatch"
until reboot. On production servers hold what you installed:

```bash
sudo apt-mark hold nvidia-open nvidia-driver nvidia-driver-libs   # hold what you actually installed
apt-mark showhold
```

Hold the **top-level metapackage you installed** (`nvidia-open` or
`nvidia-driver`) plus its libs — holding only the libs leaves the metapackage
floating.

(Versioned installs like `nvidia-driver-590-open` only move within their
branch, but holding is still the predictable option.) To upgrade later:
`apt-mark unhold …`, upgrade, reboot, re-hold.

## Secure Boot warning

With Secure Boot enabled, the unsigned DKMS module will not load — `nvidia-smi`
says it "couldn't communicate with the NVIDIA driver" even though packages
installed fine. Check **before** debugging anything else:

```bash
mokutil --sb-state
```

Either disable Secure Boot in UEFI or enroll a MOK key and sign the module.
Decide with the user; do not silently assume it is off.
