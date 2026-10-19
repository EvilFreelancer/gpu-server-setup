# Intel GPUs inside Docker

Intel needs no container toolkit and no Docker runtime: a container reaches
the GPU through the DRM device nodes, and the user-space stack (Level Zero,
OpenCL, SYCL, Mesa Vulkan) lives in the image. Docker Engine itself comes from
[`../docker-engine.md`](../docker-engine.md).

Goal: a stock image lists every Arc card the host has. Until that works, no
compose stack will see a GPU.

## 1. Device nodes and the render group

Each card is one `cardN` (display, `video` group) and one `renderD12N`
(compute, `render` group). Compute only needs the render node. Map cards to
nodes by PCI address, never by guessing from the index:

```bash
ls -l /dev/dri/by-path/
# pci-0000:05:00.0-render -> ../renderD128
# pci-0000:0a:00.0-render -> ../renderD129
stat -c '%n %G %g' /dev/dri/renderD*      # group render and its numeric GID
```

The operator's user needs `render` (and `video` for display tools) on the
host to run `intel_gpu_top`, `clinfo` or `xpu-smi` without sudo:

```bash
sudo adduser <USERNAME> render
sudo adduser <USERNAME> video
```

## 2. Gate: the container sees every card

A container gets **zero** GPUs by default; access is always explicit through
`--device`. The gate uses Intel's compute-runtime image (1.35 GB, OpenCL and
Level Zero inside, `clinfo` included); pin a current tag from
<https://hub.docker.com/r/intel/compute-runtime/tags>:

```bash
docker run --rm --device /dev/dri \
  intel/compute-runtime:26.31.39395.13-runtime-ubuntu24.04-20260907 clinfo -l
# Platform #0: Intel(R) OpenCL Graphics
#  +-- Device #0: Intel(R) Arc(TM) A770 Graphics
#  `-- Device #1: Intel(R) Arc(TM) A770 Graphics
```

Every card must appear once. Fewer devices than `/dev/dri/by-path/*-render`
entries means a card is missing: fix the host layer first
(`troubleshooting.md`). `scripts/check.sh` runs this gate with only the
discrete cards' render nodes, so an integrated GPU cannot inflate the count.

Stack-level checks with the images you will actually run (both list every
card with its free VRAM):

```bash
docker run --rm --device /dev/dri -e ZES_ENABLE_SYSMAN=1 \
  ghcr.io/ggml-org/llama.cpp:server-intel-b11706 --list-devices      # SYCL0.. (16 GB image)
docker run --rm --device /dev/dri \
  ghcr.io/ggml-org/llama.cpp:server-vulkan-b11706 --list-devices     # Vulkan0.. (1.2 GB)
```

`--device` takes the host path up to the first `:`, so the by-path names
(`pci-0000:05:00.0-render`) cannot be passed directly; resolve them first
(`realpath /dev/dri/by-path/pci-0000:05:00.0-render`).

Images that do not run as root (OpenVINO Model Server runs as uid 1000) also
need the render GID of **this host**, because the GID inside the image
differs:

```bash
docker run --rm --device /dev/dri --group-add "$(stat -c %g /dev/dri/renderD128)" <image> ...
```

## 3. Giving cards to services

All cards:

```yaml
services:
  app:
    image: <image>
    devices: ["/dev/dri:/dev/dri"]
```

One card per service. Either pass the whole `/dev/dri` and select inside the
runtime:

```yaml
    environment:
      ONEAPI_DEVICE_SELECTOR: "level_zero:0"     # SYCL / Level Zero (llama.cpp SYCL, PyTorch XPU)
      # ZE_AFFINITY_MASK: "0"                    # Level Zero only, lower level
      # GGML_VK_VISIBLE_DEVICES: "0"             # llama.cpp / Ollama Vulkan
      # --target_device GPU.0                    # OpenVINO, in the command
```

or pass only that card's render node, which makes the isolation physical
(inside the container the card becomes index 0):

```yaml
    devices:
      - /dev/dri/renderD129:/dev/dri/renderD128     # = realpath of pci-0000:0a:00.0-render
```

Render node numbers follow probe order and are stable on a fixed hardware
layout, but re-check `ls -l /dev/dri/by-path/` after moving cards between
slots.

The selector index follows the runtime's own enumeration, which normally
matches PCI order (`by-path` order). Confirm with the gate output before
pinning production services, and prefer the render-node mapping when a wrong card
would hurt.

Keep `ZES_ENABLE_SYSMAN=1` in SYCL and Level Zero services: without it the
runtime cannot report free VRAM, and some loaders mis-size their buffers.

Cap logs in every service (`logging:` block or the daemon defaults in
`../docker-engine.md`), one folder per service, `/opt/containers/<service>` with its weights inside, image tags
pinned.
