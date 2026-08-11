# Preset: Ollama

Simplest way to serve GGUF models. Same image works CPU-only and with GPUs —
the difference is exactly the `deploy:` block (GPU reservation). This is the
canonical minimal example of GPU passthrough in compose.

## Folders

```bash
sudo mkdir -pv /srv/ollama/ollama_data
```

## `/srv/ollama/docker-compose.yaml`

```yaml
services:
  ollama:
    image: ollama/ollama:latest
    restart: unless-stopped
    volumes:
      - ./ollama_data:/root/.ollama       # downloaded models live here
    ports:
      - "11434:11434"
    # Remove the deploy block below and you get the CPU-only variant
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all                  # or device_ids: [ "0" ] to pin
              capabilities: [ gpu ]
    logging:
      driver: "json-file"
      options:
        max-size: "100k"
```

## Run and verify

```bash
cd /srv/ollama
docker compose pull
docker compose up -d

docker compose exec ollama ollama pull qwen3:8b
docker compose exec ollama ollama list
curl -s http://<SERVER_IP>:11434/api/generate \
  -d '{"model":"qwen3:8b","prompt":"ping","stream":false}' | jq -r .response
```

While a prompt is running, `nvidia-smi` on the host must show the `ollama`
process using GPU memory — that is the proof the GPU is actually used (CPU-only
fallback is silent otherwise).
