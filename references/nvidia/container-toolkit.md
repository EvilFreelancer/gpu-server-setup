# NVIDIA Container Toolkit: GPUs inside Docker

Goal: `docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi` prints the
same GPU table as the host. Until that works, no compose stack will see a GPU.

Prerequisite: Docker Engine from the official repo, see
[`../docker-engine.md`](../docker-engine.md). The toolkit is what adds the
`nvidia` runtime on top of it.

## 1. NVIDIA Container Toolkit (nvidia-ctk)

The toolkit adds the `nvidia` runtime to Docker; without it containers cannot
touch the GPUs at all.

**Path A — CUDA repo already added** (see `driver-cuda.md`): the package is
usually right there.

```bash
sudo apt update
sudo apt -y install nvidia-container-toolkit
```

**Path B — dedicated libnvidia-container repo** (works everywhere, use it when
Path A cannot resolve the package):

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update
sudo apt -y install nvidia-container-toolkit
```

## 2. Wire the runtime into Docker

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker        # mandatory — config is read at start
```

`/etc/docker/daemon.json` must now contain:

```json
{
    "runtimes": {
        "nvidia": {
            "args": [],
            "path": "nvidia-container-runtime"
        }
    }
}
```

Gate — the single most important check of the whole setup:

```bash
docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi
```

Every physical GPU must appear. If this fails, fix it before touching any
compose file (see `troubleshooting.md`).

## 3. Giving GPUs to containers

**By default a container sees ZERO GPUs.** Access is always explicit.

`docker run`:

```bash
docker run --rm --gpus all <image> nvidia-smi              # all GPUs
docker run --rm --gpus '"device=0,1"' <image> nvidia-smi   # specific GPUs (note the quoting)
docker run --rm --gpus 2 <image> nvidia-smi                # any two
```

`docker compose` — the `deploy` block per service:

```yaml
services:
  app:
    image: <image>
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all                  # or: device_ids: [ "0", "1" ]
              capabilities: [ gpu ]
```

Use `device_ids` to pin each service to its own GPU when several models share a
host — that is how one box serves N models without them evicting each other.
