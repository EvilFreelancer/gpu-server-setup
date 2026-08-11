# Docker Engine + NVIDIA Container Toolkit

Goal: `docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi` prints the
same GPU table as the host. Until that works, no compose stack will see a GPU.

## 1. Remove legacy packages

Distro-packaged docker conflicts with Docker CE. Clean first:

```bash
sudo apt -y remove docker.io docker-doc docker-compose podman-docker containerd runc
```

Some Ubuntu builds also ship `docker-compose-v2` — remove it too if present.

## 2. Install Docker Engine (official repo)

Works on both Debian and Ubuntu — the repo URL is derived from `/etc/os-release`:

```bash
sudo apt -y install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Gate:

```bash
sudo docker run --rm hello-world
docker version && docker compose version
```

Let the operator's user run docker without sudo:

```bash
sudo adduser <USERNAME> docker
newgrp docker      # affects only the current shell
id                 # must show the docker group
```

`newgrp` helps only in the shell where it ran — over ssh simply reconnect and
check `id` in the new session.

## 3. NVIDIA Container Toolkit (nvidia-ctk)

The toolkit adds the `nvidia` runtime to Docker; without it containers cannot
touch the GPUs at all.

**Path A — CUDA repo already added** (see `nvidia-cuda.md`): the package is
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

## 4. Wire the runtime into Docker

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

## 5. Giving GPUs to containers

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

## 6. Service layout convention

One service = one folder under `/srv` with its compose file and data dir:

```
/srv/<service>/
├─ docker-compose.yaml
└─ <service>_data/          # caches, models, state — survives container recreation
```

Always cap logs in every service, or json logs eat the disk over weeks:

```yaml
    logging:
      driver: "json-file"
      options:
        max-size: "100k"
```

**Where the space goes:** Docker 28+ defaults to the containerd image store —
images land in `/var/lib/containerd` (a vLLM image unpacks to ~30 GB there)
while `/var/lib/docker` stays almost empty, and `docker images` shows the new
DISK USAGE / CONTENT SIZE columns. Point disk monitoring at the right
directory.
