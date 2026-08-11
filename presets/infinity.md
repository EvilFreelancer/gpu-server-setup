# Preset: Infinity (embedding server)

[Infinity](https://github.com/michaelfeil/infinity) serves embedding / reranker
models over an OpenAI-compatible API. One container can serve **several models**
(repeat the `--engine torch --model-id …` pair per model).

**GPU sharing caveat:** if Infinity is pinned to a GPU that also runs an LLM,
the two compete for VRAM and compute. Say this to the user explicitly and lower
the LLM's `--gpu-memory-utilization` to leave room, or give Infinity its own GPU.

## Folders

```bash
sudo mkdir -pv /srv/infinity/infinity_data
sudo mkdir -pv /srv/infinity/infinity
```

## `/srv/infinity/docker-compose.yaml`

```yaml
services:
  infinity:
    # image: michaelf34/infinity:0.0.77       # plain image, when no pin-fixes needed
    build:
      context: ./infinity                     # custom Dockerfile below
    restart: unless-stopped
    command: >
      v2
      --no-bettertransformer
      --engine torch --model-id Qwen/Qwen3-Embedding-8B
      --engine torch --model-id intfloat/multilingual-e5-large
      --port "7997"
    environment:
      - HF_HOME=/app/.cache
      - HF_HUB_ENABLE_HF_TRANSFER=0
      - DO_NOT_TRACK=1
      - HF_HUB_DISABLE_TELEMETRY=1
      - INFINITY_ANONYMOUS_USAGE_STATS=0
      - INFINITY_DISABLE_OPTIMUM=1
    volumes:
      - ./infinity_data:/app/.cache
    ports:
      - "7997:7997"
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

## `/srv/infinity/infinity/Dockerfile`

Needed only when the stock image's HF stack is too old for the model (e.g.
`transformers` without qwen3 support). Otherwise use the `image:` line and skip
the `build:` block.

```dockerfile
FROM michaelf34/infinity:0.0.77

# Keep HF stack compatible:
# - transformers must support the target model family
# - huggingface_hub must stay < 1.0 for older datasets/infinity image compatibility
RUN /app/.venv/bin/pip install --no-cache-dir \
    "transformers==4.56.2" \
    "huggingface_hub<1.0" \
    "tokenizers>=0.22,<0.23" \
    "safetensors>=0.4.3"

# Sanity check during build
RUN /app/.venv/bin/python -c "import transformers, huggingface_hub; print('transformers=', transformers.__version__); print('huggingface_hub=', huggingface_hub.__version__)"
```

## Run and verify

```bash
cd /srv/infinity
docker compose build
docker compose up -d
docker compose logs -f
```

```bash
curl -s http://<SERVER_IP>:7997/ | head       # Swagger/landing answers
curl -s http://<SERVER_IP>:7997/models | jq   # both models listed
curl -s http://<SERVER_IP>:7997/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"intfloat/multilingual-e5-large","input":["ping"]}' | head -c 200
```

Dependency/image update:

```bash
cd /srv/infinity
docker compose down
docker compose build --no-cache
docker compose up -d
```
