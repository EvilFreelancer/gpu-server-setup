# Serving stacks on Intel Arc

What actually runs in Docker on Intel discrete GPUs, checked on 2026-10-17. The
NVIDIA presets in `presets/` do not apply: their images are CUDA builds. Tags
below existed in the registries on that date; they move fast, so re-check the
current one before deploying and pin it (`b<build>` or a digest, never
`latest`).

The user-space runtime (Level Zero, OpenCL, SYCL, Mesa Vulkan) ships inside
these images. The host only provides the kernel driver, the firmware and the
`/dev/dri` nodes (see `driver.md`, `docker.md`).

## Which stack for which card

| Stack | Alchemist (A770, A750, A380) | Battlemage (B580, B60, B70) | Image (2026-10-17) |
|---|---|---|---|
| llama.cpp SYCL | yes, the fastest option | yes | `ghcr.io/ggml-org/llama.cpp:server-intel-b11706` |
| llama.cpp Vulkan | yes, slow prefill (Mesa does not use XMX on DG2) | yes | `ghcr.io/ggml-org/llama.cpp:server-vulkan-b11706` |
| Ollama (Vulkan backend, on by default) | yes | yes | `ollama/ollama:0.40.6` |
| OpenVINO Model Server | yes (LLM, embeddings, rerank, Whisper) | yes | `openvino/model_server:2026.4.1-gpu` |
| whisper.cpp SYCL / Vulkan | yes | yes | `ghcr.io/ggml-org/whisper.cpp:main-intel-<sha>` / `main-vulkan-<sha>` |
| upstream vLLM XPU | **no**: `vllm-xpu-kernels` is built for PVC, BMG-G21, BMG-G31 only | yes | `vllm/vllm-openai-xpu:v0.31.0` |
| `intel/llm-scaler-vllm` | **no** (B60/B70 only) | yes | `intel/llm-scaler-vllm:1.5` |
| ipex-llm vLLM / Ollama | frozen at vLLM 0.8.3, project archived | n/a | `intelanalytics/ipex-llm-serving-xpu:0.8.3-b19` |
| TEI XPU, Infinity | not recommended: TEI XPU is built on the archived IPEX, Infinity has no Intel backend | | |

Alchemist has no native FP64; anything that requires it fails at start
(`Required aspect fp64 is not supported`). IPEX and ipex-llm are archived;
PyTorch upstream (`torch` XPU builds) replaced them.

For embeddings on Arc use OVMS `--task embeddings` or llama.cpp `--embedding`.

## Common container rules

- Pass `/dev/dri` (or single nodes, see `docker.md`); no `--privileged`, no
  `--ipc=host` except for the vLLM family.
- Images that run as root (llama.cpp, Ollama) need no `group_add`. Non-root
  images (OVMS runs as uid 1000 inside) need the host's numeric render GID:
  `group_add: ["<RENDER_GID>"]` from `stat -c %g /dev/dri/renderD128`.
- `ZES_ENABLE_SYSMAN=1` in SYCL/Level Zero services, so the runtime can read
  free VRAM.
- One service per card, pinned (`ONEAPI_DEVICE_SELECTOR=level_zero:<N>` or a
  single render node). Splitting one model across cards costs PCIe bandwidth:
  check where each card sits first (`lspci -tv`, link width in `driver.md`).
  A card behind the chipset on PCIe 3.0 x2 makes tensor split pointless; use
  layer split or one model per card.

## llama.cpp SYCL (recommended for Alchemist)

```yaml
x-sycl: &sycl
  image: ghcr.io/ggml-org/llama.cpp:server-intel-b11706
  devices: ["/dev/dri:/dev/dri"]
  volumes:
    - ./models:/models:ro
    - ./sycl_cache:/root/.cache          # NEO compiler cache: 80 s -> 6 s restarts, see below
  restart: unless-stopped
  logging: {driver: json-file, options: {max-size: "100k"}}

services:
  llm-0:                                # one model per card
    <<: *sycl
    environment: {ONEAPI_DEVICE_SELECTOR: "level_zero:0", ZES_ENABLE_SYSMAN: "1"}
    command: ["-m", "/models/<MODEL>.gguf", "-ngl", "99", "-fa", "on",
              "-c", "32768", "-sm", "none", "-mg", "0", "--host", "0.0.0.0"]
    ports: ["8080:8080"]

  llm-2card:                            # alternative: one model over both cards
    <<: *sycl
    environment: {ONEAPI_DEVICE_SELECTOR: "level_zero:0;level_zero:1", ZES_ENABLE_SYSMAN: "1"}
    command: ["-m", "/models/<MODEL>.gguf", "-ngl", "99", "-fa", "on",
              "-sm", "layer", "-ts", "1,1", "-ctk", "q8_0", "-ctv", "q8_0",
              "--host", "0.0.0.0"]
    ports: ["8081:8080"]
```

- Health: `GET /health` (the image has its own `HEALTHCHECK`), then
  `/v1/models` and one `/v1/chat/completions`.
- `-sm layer` is the default and the right one for consumer boards; `-sm tensor`
  helps prefill only with fast links; `row` is unsupported on SYCL.
- Workarounds from the SYCL docs: `GGML_SYCL_DEV2DEV_MEMCPY=2` for garbled
  output or crashes with several GPUs, `GGML_SYCL_FA_ONEDNN_MAX_KV=24576` for
  `DEVICE_LOST` at long context.
- Docs: <https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/SYCL.md>.
- **Check the answers, not only the speed.** The reorder optimization of
  ggml-sycl (`GGML_SYCL_ENABLE_OPT`, on by default) breaks some quant mixes on
  DG2 on both drivers: an unsloth UD-Q4_K_M 27B (Q4_K, Q5_K, Q6_K, Q8_0, IQ4_XS,
  IQ4_NL, IQ3_S, Q3_K tensors) answers "17*23?" with a string of threes while
  `llama-bench` reports a fine speed, and whisper.cpp q8_0 models produce garbage
  the same way. `GGML_SYCL_ENABLE_OPT=0` fixes the output and costs about a third
  of the decode. Better: a quant made only of Q4_K, Q6_K and Q8_0 (the ggml-org
  Q4_K_M uploads) is correct with the optimization on; on 2x A770 under xe the
  ggml-org 27B decodes at 13.2 t/s against 8.3 for the UD one with it off. After
  every image bump, ask a question with a known answer before trusting a number.

### Startup time: keep the compiler cache

The official image is built without AOT, so the SYCL kernels are JIT-compiled
from SPIR-V on every container start. On a Ryzen 5 3500X with an A770 that
took about 80 s before `/health` answered, even for a 1 GB model already in
the page cache. The Intel compute runtime (NEO) caches what it compiles in
`$HOME/.cache/neo_compiler_cache`, which dies with the container. Mounting a
volume there (`./sycl_cache:/root/.cache` above) cut the next start to 6 s;
the cache holds 20-50 MB.

This is not `SYCL_CACHE_PERSISTENT=1`, which the llama.cpp docs advise
against (it mixes old and new binaries after an update). The NEO cache is
keyed by the binary, the build options and the device, so a new image tag or
another card simply adds entries.

### Building your own image: F16 and AOT

Only needed for a custom build; the official `server-intel` images already
have what matters.

- `-DGGML_SYCL_F16=ON` - FP16 compute in the SYCL paths, faster prompt
  processing on Arc. CMake defaults to `OFF`, the official
  `.devops/intel.Dockerfile` sets it `ON` (also for `b11706`). The XMX paths
  then run in FP16 (`GGML_SYCL_DYNAMIC_PRECISION=F16`); activations above
  65504 overflow, so if a model produces garbage, try
  `GGML_SYCL_DYNAMIC_PRECISION=BF16` at run time.
- `-DGGML_SYCL_DEVICE_ARCH=<arch>` - ahead-of-time compilation for one
  architecture, passed to `ocloc -device`: `acm-g10` for A770/A750, `acm-g11`
  for A380/A310, `bmg-g21` for B580/B570. The binary skips the JIT start but
  runs only on that architecture. The llama.cpp docs say runtime speed equals
  JIT; not benchmarked here, and the compiler-cache volume already removes the
  start-up cost. **Catch:** a JIT build links the kernels with
  `-ze-intel-greater-than-4GB-buffer-required`, an AOT build skips that flag
  (`Skipping -ze-intel-greater-than-4GB-buffer-required for spir64_gen AOT` in
  `ggml/src/ggml-sycl/CMakeLists.txt`), so an AOT binary can fail on buffers
  above 4 GiB; `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1` is the usual
  companion of such builds. To build: add the flag to the `cmake -B build ...`
  line of `.devops/intel.Dockerfile`, then
  `docker build -f .devops/intel.Dockerfile --target server .` on a machine
  with plenty of RAM; on a 6-core desktop expect a long build.

### Allocations above 4 GiB

Intel GPUs limit a single device allocation to about 4 GiB
(`maxMemAllocSize`). Current llama.cpp (since late 2025) handles it itself: its
Level Zero allocation path asks for the relaxed limit, and it splits buffers
anyway. Checked on an A770: a 180k context with 4.9 GiB of KV cache started
fine with the default settings and with `GGML_SYCL_USE_LEVEL_ZERO_API=0`.

`UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1` is the switch for other SYCL
programs (PyTorch XPU and so vLLM, AOT and old llama.cpp builds) that fail with
`can't allocate ... Bytes of memory on device` or `can NOT allocate memory
block with size larger than 4GB`:

- it makes the runtime report the whole VRAM as the allocation limit and
  compiles every kernel with `-ze-opt-greater-than-4GB-buffer-required`
  (stateless addressing), so the first start JIT-compiles everything again;
- the official llama.cpp JIT image already links its kernels that way, so its
  speed did not change (A770, pp512 5131 vs 5132 t/s, tg128 51.2 vs 51.5 t/s):
  harmless there, just unnecessary; with an AOT build (above) it is the fix;
- the name is the one the code reads (`unified-runtime/.../device.cpp`); the
  Unified Runtime docs call it `UR_L0_USE_RELAXED_ALLOCATION_LIMITS`, which
  does nothing. On Linux it goes into `environment:`, not `set ...`.

Measured on 2x A770 (one card on PCIe 4.0 x16, one behind the chipset on 3.0 x2,
layer split, b11706, 1024 tokens in):

| Model | i915, one user decode | xe, one user decode | xe, total out tok/s at 1 / 4 / 8 / 16 users |
|---|---|---|---|
| Qwen3.6-35B-A3B Q4_K_M (MoE) | 20.1 t/s | 43.5 t/s | 29 / 23 / 28 / 28.5 |
| Qwen3.8-27B Q4_K_M, ggml-org | not measured | 13.2 t/s | 10.4 / 21.7 / 20.7 / 18.1 |

Prefill stayed at 440-510 t/s on both drivers. The server does not gain past
4-8 users; more users only wait longer for the first token, and at 8-16 users a
few requests fail on both drivers. Community numbers on 2x A770 with the 27B
Q4_K_M: prefill about 576 t/s, decode about 14 t/s (xe driver, PCIe 3.0 x8,
<https://github.com/zhaoyshine/dual-intel-arc-a770-llm-bench>); a second report
measured decode 13.7 t/s on i915 against 18.7 t/s on xe for a 30B Q4_K_S
(<https://github.com/ggml-org/llama.cpp/discussions/23313>).

## llama.cpp Vulkan

Same layout with `server-vulkan-b11706`; select cards with
`GGML_VK_VISIBLE_DEVICES: "0"` or `--device Vulkan0`. Prefill on Alchemist is
several times slower than SYCL, decode is close.

## Ollama

```yaml
services:
  ollama:
    image: ollama/ollama:0.40.6
    devices: ["/dev/dri:/dev/dri"]
    environment: {GGML_VK_VISIBLE_DEVICES: "0,1"}    # OLLAMA_VULKAN=0 turns Vulkan off
    volumes: ["./models:/root/.ollama"]
    ports: ["11434:11434"]
    restart: unless-stopped
```

Health: `GET /api/version`, then `ollama ps` inside the container must show
`100% GPU` while a model answers.

## OpenVINO Model Server

```yaml
services:
  ovms-0:
    image: openvino/model_server:2026.4.1-gpu
    user: "1000:1000"
    group_add: ["<RENDER_GID>"]
    devices: ["/dev/dri:/dev/dri"]
    volumes: ["./models:/models:rw"]
    command: ["--source_model", "OpenVINO/<MODEL>-int4-ov", "--model_repository_path", "/models",
              "--rest_port", "8000", "--target_device", "GPU.0"]
    ports: ["8000:8000"]
```

- Both cards for one model: `--target_device HETERO:GPU.0,GPU.1
  --model_distribution_policy PIPELINE_PARALLEL`.
- Other tasks: `--task embeddings|rerank|speech2text`.
- Health: `/v2/health/ready`; chat at `/v3/chat/completions`.

## vLLM

Battlemage and Data Center Max: upstream `vllm/vllm-openai-xpu` and Intel's
`intel/llm-scaler-vllm` are the supported paths; read the hardware list in
their README before pulling. A working 4x Arc Pro B70 recipe with patched
kernels: <https://github.com/Lumnus/b70-flash-next>
(<https://github.com/vllm-project/vllm-xpu-kernels/issues/620>).

Alchemist is not supported upstream
(<https://github.com/vllm-project/vllm-xpu-kernels/issues/92>), but current
vLLM runs on it **without building anything**: the prebuilt
`vllm-xpu-kernels` wheel carries a generic SPIR-V entry that the Intel
runtime JIT-compiles for DG2, and the kernels that do not compile there can
be routed around. Rebuilding the kernels with a DG2 AOT target gains nothing
(SYCL-TLA, the base of the heavy kernels, supports Xe-HPC/Xe2/Xe3 only) and
costs hours on a desktop CPU.

Recipe reconstructed from <https://github.com/zhaoyshine/dual-intel-arc-a770-llm-bench>
(vLLM `25b0add7b`, contained in v0.31.0; tested there on the xe driver):

```dockerfile
FROM vllm/vllm-openai-xpu:v0.31.0
# Out-of-tree plugin: registers a QwenGatedDeltaNetAttention that forces the
# Triton (FLA) path, because the SYCL GDN kernel crashes IGC on DG2. About 15
# lines with a vllm.general_plugins entry point; write your own, the source
# repo has no license.
COPY gdn-plugin /opt/gdn-plugin
RUN pip install --no-deps --no-build-isolation /opt/gdn-plugin
# UR_L0_USE_IMMEDIATE_COMMANDLISTS=0: 6.5x faster decode on i915, neutral on xe
ENV VLLM_XPU_USE_SAMPLER_KERNEL=0 ZES_ENABLE_SYSMAN=1 VLLM_WORKER_MULTIPROC_METHOD=spawn UR_L0_USE_IMMEDIATE_COMMANDLISTS=0 \
    FI_PROVIDER=shm CCL_ATL_SHM=1 CCL_ATL_TRANSPORT=ofi CCL_ZE_IPC_EXCHANGE=sockets CCL_WORKER_COUNT=2
```

```bash
docker run -d --name vllm-a770 --device /dev/dri -v /dev/dri/by-path:/dev/dri/by-path --cap-add SYS_PTRACE \
  --ipc=host --shm-size 16g -p 8000:8000 -v /opt/containers/vllm-a770/models:/models \
  -v vllm-a770-cache:/root/.cache -v vllm-a770-triton:/root/.triton vllm-a770:0.31.0 \
  --model /models/<MODEL>-AWQ-INT4 --pipeline-parallel-size 2 --tensor-parallel-size 1 \
  --dtype float16 --attention-backend TRITON_ATTN --enforce-eager \
  --limit-mm-per-prompt '{"image":0,"video":0}' --max-model-len 16384 --kv-cache-memory-bytes 2G
```

- `VLLM_XPU_USE_SAMPLER_KERNEL=0`: the fused sampler needs FP64.
- If PyTorch fails on a single allocation above 4 GiB (large KV blocks,
  long contexts), add `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1`, see
  "Allocations above 4 GiB" above; the reference setup did not need it.
- fp16 only (vLLM refuses bf16 on "a770"), no FlashAttention backend, no
  vision, no MoE models that need the SYCL-TLA grouped GEMM.
- Pipeline parallel, not tensor parallel: TP does two all-reduces per layer
  through host memory, which a chipset slot at PCIe 3.0 x2 turns into the
  bottleneck; PP sends a few KB per token.
- Keep the cache volumes: the first start JIT-compiles SPIR-V and autotunes
  Triton for minutes.
- What the command and the image above carry beyond the reference recipe, each
  found from a crash or a profile on a 2x A770 box:
  1. `-v /dev/dri/by-path:/dev/dri/by-path`: oneCCL looks
     the cards up there, the workers die with `init_device_fds: opendir failed`
     without it;
  2. `--cap-add SYS_PTRACE`: oneCCL takes the peer worker's device fd with
     `pidfd_getfd`; without it every collective fails with
     `mem_to_ipc_handle: device_fd is invalid value`;
  3. `--kv-cache-memory-bytes <N>G` instead of `--gpu-memory-utilization`: on
     i915 the profiler sees the whole card as free after loading and sizes a KV
     cache the stage cannot hold;
  4. i915 only: `UR_L0_USE_IMMEDIATE_COMMANDLISTS=0`. Every kernel launch ended in
     a blocking ioctl, regular command lists cut a 27B decode step from 3.75 s to
     0.58 s. On xe the setting hardly matters.
- MoE on Alchemist: the AWQ checkpoints have no working experts path on DG2 (the
  XPU experts kernel wants Xe2/Xe3, the Triton WNA16 kernel refuses the AutoAWQ
  layout). A GPTQ checkpoint with `--quantization moe_wna16 --moe-backend triton`
  runs, once the FP64 router op `topk_softmax` is replaced with the same
  computation in torch (a few lines in the plugin).
- Measured on 2x A770 (PP2, 1024 tokens in, 128 out):

  | | i915 | xe |
  |---|---|---|
  | Qwen3.8-27B AWQ, one user decode | 1.7 t/s | 8.4 t/s |
  | 27B, total out at 4 / 8 users | 2.3 / not measured | 6.4 / 7.2 t/s |
  | 27B, 16 users, 1.5 GB KV per stage | not measured | 8-10 sequences fit, about 1 t/s |
  | Qwen3.6-35B-A3B GPTQ, one user decode | 0.7 t/s | 2.4 t/s |

  The community reference (decode 11.3 t/s, prefill 73 t/s, xe, both cards x8) is
  close to the xe number. vLLM does not batch on Alchemist: every added sequence
  makes the decode step longer, four users share less than twice what one gets,
  and llama.cpp serves the same 27B faster at every load. Tried on xe without a
  gain: XPU graphs (`cudagraph_mode: FULL_DECODE_ONLY`, the capture ends in
  `UR_RESULT_ERROR_DEVICE_LOST`), the newest compute runtime, and switching
  prefix caching off for the hybrid model. Use vLLM on Alchemist only when its
  API features matter more than speed.

The archived ipex-llm image (`intelanalytics/ipex-llm-serving-xpu:0.8.3-b19`)
is vLLM 0.8.3, predates the current GDN models and carries known security
issues; do not use it on an open network.
