# Preset: vLLM (OpenAI-compatible LLM server)

One `vllm/vllm-openai` container **per model, pinned to its own GPU** via
`device_ids`. Scale by copying the service block. Adapt, don't paste blindly:
fill every `<PLACEHOLDER>`, drop flags that don't apply to your model.

## Folders

```bash
sudo mkdir -pv /srv/vllm/vllm_data
# uid shift only matters when Docker userns-remap is enabled; harmless otherwise
sudo chown 100000:100000 /srv/vllm/vllm_data
```

## `/srv/vllm/docker-compose.yaml`

Working two-GPU example: a big model on GPU 0, a smaller one on GPU 1. For a
single GPU keep only one service.

```yaml
services:
  gpt-oss-120b:
    image: vllm/vllm-openai:v0.17.0
    restart: always
    volumes:
      - ./vllm_data:/root/.cache          # model + compile cache, survives restarts
    entrypoint: vllm
    command: >
      serve openai/gpt-oss-120b
      --served-model-name openai/gpt-oss-120b
      --trust-remote-code
      --dtype auto
      --gpu-memory-utilization 0.9
      --max-num-seqs 2
      --max-model-len 128000
      --max-num-batched-tokens 128000
      --kv-cache-dtype fp8
      --no-enable-prefix-caching
      --enable-auto-tool-choice
      --tool-call-parser openai
      --tensor-parallel-size 1
    environment:
      LD_LIBRARY_PATH: /usr/local/nvidia/lib64:/usr/local/nvidia/lib:/usr/lib/x86_64-linux-gnu
      NCCL_IGNORE_DISABLED_P2P: "1"
      HF_HUB_ENABLE_HF_TRANSFER: "0"
      VLLM_NO_USAGE_STATS: "1"
      DO_NOT_TRACK: "1"
    ports:
      - 8081:8000
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: [ "0" ]
              capabilities: [ gpu ]
    logging:
      driver: "json-file"
      options:
        max-size: "100k"

  qwen35-27b:
    image: vllm/vllm-openai:v0.17.0
    restart: always
    volumes:
      - ./vllm_data:/root/.cache
    entrypoint: vllm
    command: >
      serve Qwen/Qwen3.5-27B
      --served-model-name Qwen/Qwen3.5-27B
      --dtype auto
      --mm-encoder-tp-mode data
      --mm-processor-cache-type shm
      --gpu-memory-utilization 0.7
      --max-model-len 128000
      --max-num-seqs 2
      --max-num-batched-tokens 32768
      --tensor-parallel-size 1
      --kv-cache-dtype fp8
      --enable-chunked-prefill
      --async-scheduling
      --enable-auto-tool-choice
      --tool-call-parser qwen3_coder
      --reasoning-parser qwen3
    environment:
      LD_LIBRARY_PATH: /usr/local/nvidia/lib64:/usr/local/nvidia/lib:/usr/lib/x86_64-linux-gnu
      NCCL_IGNORE_DISABLED_P2P: "1"
      HF_HUB_ENABLE_HF_TRANSFER: "0"
      VLLM_NO_USAGE_STATS: "1"
      DO_NOT_TRACK: "1"
    ports:
      - 8082:8000
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: [ "1" ]
              capabilities: [ gpu ]
    logging:
      driver: "json-file"
      options:
        max-size: "100k"
```

## Flags that matter

| Flag / env | Why |
|------------|-----|
| `--served-model-name` | the model id clients must send; keep it equal to the HF id unless the user wants an alias |
| `--gpu-memory-utilization` | headroom control; lower it (0.7) when the GPU is shared with another service |
| `--max-model-len`, `--max-num-batched-tokens` | context + batch budget; must fit in VRAM together with weights, and `--max-model-len` must not exceed the model's own `max_position_embeddings` — vLLM refuses to start above it |
| `--kv-cache-dtype fp8` | halves KV-cache memory on Ada/Hopper/Blackwell; drop on older GPUs |
| `--enable-auto-tool-choice` + `--tool-call-parser` | function calling; parser is model-family-specific: `openai` for gpt-oss, `hermes` for plain Qwen3 chat, `qwen3_coder` for Qwen3-Coder/Qwen3.5 — check vLLM's tool-call docs before adapting to another family |
| `--reasoning-parser` | only for reasoning models (Qwen3 etc.) |
| `--trust-remote-code` | needed by models with custom code; mention it to the user, it executes repo code |
| `LD_LIBRARY_PATH` | workaround: some GPUs (seen on RTX 6000 Blackwell) fail to find driver libs inside the container without it |
| `NCCL_IGNORE_DISABLED_P2P=1` | avoids NCCL init failures on consumer boards without P2P |
| `VLLM_NO_USAGE_STATS`, `DO_NOT_TRACK` | telemetry off |
| gated models | add `HF_TOKEN: <HF_TOKEN>` to `environment` (Llama, Gemma, …) |

Multi-GPU for ONE big model: put both ids in `device_ids: [ "0", "1" ]` and set
`--tensor-parallel-size 2` (instead of one service per GPU).

## Run and verify

```bash
cd /srv/vllm
docker compose pull
docker compose up -d
docker compose logs -f        # wait for "Application startup complete"
```

First start is slow twice: the image pull is ~10 GB compressed (~30 GB
unpacked) and can outlast the model download, then the model itself lands in
`vllm_data`. Watch the logs, do not assume failure early.

```bash
curl -s http://<SERVER_IP>:8081/health          # empty 200 = alive
curl -s http://<SERVER_IP>:8081/v1/models | jq
curl -s http://<SERVER_IP>:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-oss-120b","messages":[{"role":"user","content":"ping"}],"max_tokens":256}'
```

Give the smoke test a real token budget: reasoning models spend tokens on
thinking first, so with a tiny `max_tokens` a perfectly healthy server returns
`content: null` + `finish_reason: "length"`.

Update / restart:

```bash
docker compose down && docker compose pull && docker compose up -d
```
