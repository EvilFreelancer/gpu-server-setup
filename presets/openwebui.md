# Preset: OpenWebUI (web interface)

Chat UI on top of any OpenAI-compatible backend (vLLM, Ollama, …). Runs on CPU,
needs no GPU pinning.

## Folders

```bash
sudo mkdir -pv /srv/openwebui/open-webui_data
sudo chown 100000:100000 /srv/openwebui/open-webui_data
```

Factory reset later = stop the container, delete `open-webui_data/`, start again.

## `/srv/openwebui/docker-compose.yaml`

```yaml
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:v0.8.5
    restart: unless-stopped
    ports:
      - "80:8080"
    volumes:
      - ./open-webui_data:/app/backend/data:rw
    environment:
      WEBUI_AUTH: False
      OPENAI_API_BASE_URL: http://<SERVER_IP>:8081/v1
      OPENAI_API_KEY: ~
      ENABLE_PERSISTENT_CONFIG: True
    logging:
      driver: "json-file"
      options:
        max-size: "100k"
```

Key points:

- `OPENAI_API_BASE_URL` points at the vLLM endpoint (`http://<SERVER_IP>:8081/v1`).
  Several backends: use `OPENAI_API_BASE_URLS` with `;`-separated URLs
  (`http://<SERVER_IP>:8081/v1;http://<SERVER_IP>:8082/v1`).
- Ollama backend instead: use `OLLAMA_BASE_URL: http://<SERVER_IP>:11434`.
- `WEBUI_AUTH: False` = no login at all. **Only acceptable on a closed network.**
  Warn the user; on anything reachable from outside set it to `True` (first
  registered user becomes admin).
- `OPENAI_API_KEY: ~` is YAML null — fine for an unauthenticated vLLM; put a
  real key there when the backend enforces one.
- UI is served on port 80 → `http://<SERVER_IP>/`.

## Run and verify

```bash
cd /srv/openwebui
docker compose pull
docker compose up -d
docker compose logs -f
```

First boot takes a few minutes before port 80 answers (DB init + embedding
model download) — do not restart it.

Open `http://<SERVER_IP>/` — the model list in the top-left must show the
models reported by `GET /v1/models` of the backend. If the list is empty, the
UI is up but the backend URL is wrong or the backend is down.

Headless check (with `WEBUI_AUTH: False` the empty-credential signin returns
the same token the UI acquires automatically; a bare `GET /api/models` answers
"Not authenticated" even with auth off):

```bash
TOKEN=$(curl -s -X POST http://<SERVER_IP>/api/v1/auths/signin \
  -H 'Content-Type: application/json' -d '{"email":"","password":""}' | jq -r .token)
curl -s http://<SERVER_IP>/api/models -H "Authorization: Bearer $TOKEN" | jq '[.data[].id]'
```
