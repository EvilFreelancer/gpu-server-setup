# Docker Engine (vendor-neutral)

The same Docker CE install serves every GPU vendor. What differs is how a
container gets the GPU: NVIDIA adds a runtime
([`nvidia/container-toolkit.md`](nvidia/container-toolkit.md)), Intel passes
device nodes ([`intel/docker.md`](intel/docker.md)).

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

## 3. Daemon defaults

Cap container logs host-wide in `/etc/docker/daemon.json`, so a service that
forgot its own `logging:` block cannot fill the disk. Merge the keys into the
existing file instead of overwriting it: on NVIDIA hosts `nvidia-ctk` keeps its
`runtimes` block there.

```json
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "3"
    }
}
```

```bash
sudo python3 -m json.tool /etc/docker/daemon.json >/dev/null && echo json-ok
sudo systemctl restart docker
docker info --format '{{.LoggingDriver}}'      # json-file
```

A LAN whose router resolver drops queries under load (large model downloads
open hundreds of connections) also wants `"dns": ["<RESOLVER_IP>", ...]` here
or per service.

## 4. Service layout convention

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
