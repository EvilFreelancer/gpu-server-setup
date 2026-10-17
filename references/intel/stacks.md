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
  volumes: ["/srv/models:/models:ro"]
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

Community numbers on 2x A770 with Qwen3.8-27B Q4_K_M, llama.cpp SYCL layer
split: prefill about 576 t/s, decode about 14 t/s (xe driver, PCIe 3.0 x8,
<https://github.com/zhaoyshine/dual-intel-arc-a770-llm-bench>). A second report
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
    volumes: ["./ollama_data:/root/.ollama"]
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
    volumes: ["./ovms_data:/models:rw"]
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
ENV VLLM_XPU_USE_SAMPLER_KERNEL=0 ZES_ENABLE_SYSMAN=1 VLLM_WORKER_MULTIPROC_METHOD=spawn \
    FI_PROVIDER=shm CCL_ATL_SHM=1 CCL_ATL_TRANSPORT=ofi CCL_ZE_IPC_EXCHANGE=sockets CCL_WORKER_COUNT=2
```

```bash
docker run -d --name vllm-a770 --device /dev/dri -v /dev/dri/by-path:/dev/dri/by-path \
  --ipc=host --shm-size 16g -p 8000:8000 -v /srv/models:/models \
  -v vllm-a770-cache:/root/.cache -v vllm-a770-triton:/root/.triton vllm-a770:0.31.0 \
  --model /models/<MODEL>-AWQ-INT4 --pipeline-parallel-size 2 --tensor-parallel-size 1 \
  --dtype float16 --attention-backend TRITON_ATTN --enforce-eager \
  --limit-mm-per-prompt '{"image":0,"video":0}' --max-model-len 16384 --gpu-memory-utilization 0.92
```

- `VLLM_XPU_USE_SAMPLER_KERNEL=0`: the fused sampler needs FP64.
- fp16 only (vLLM refuses bf16 on "a770"), no FlashAttention backend, no
  vision, no MoE models that need the SYCL-TLA grouped GEMM.
- Pipeline parallel, not tensor parallel: TP does two all-reduces per layer
  through host memory, which a chipset slot at PCIe 3.0 x2 turns into the
  bottleneck; PP sends a few KB per token.
- Keep the cache volumes: the first start JIT-compiles SPIR-V and autotunes
  Triton for minutes.
- Expectation on 2x A770 (Qwen3.8-27B AWQ-INT4, both cards x8, xe driver):
  PP2 prefill 73 t/s, decode 11.3 t/s, against llama.cpp SYCL 576 t/s and
  14.2 t/s. vLLM pays off only for many concurrent requests.

The archived ipex-llm image (`intelanalytics/ipex-llm-serving-xpu:0.8.3-b19`)
is vLLM 0.8.3, predates the current GDN models and carries known security
issues; do not use it on an open network.
