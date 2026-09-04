# dsh — hardened Docker setup

Runs the DeepSeek harness CLI (`@deepseek-ai/dsh`) inside a locked-down
container instead of bare-metal on the host.

## Why

Bare-metal dsh is a full agent harness: it runs arbitrary bash, reads/writes
files, browses the web, and spawns subagents with your user's full privileges.
This setup confines it to a non-root, capability-stripped, read-only-root
container with only one workspace directory exposed.

## Hardening applied

- Non-root user `node` (uid 1000, shipped by the base image) inside the container.
- `cap_drop: ALL` — no Linux capabilities.
- `no-new-privileges: true` — cannot gain privileges.
- `read_only: true` root filesystem; only `/tmp` (tmpfs) and `/data`
  (`DSH_HOME`, named volume) are writable.
- Resource limits: 4 CPU, 4 GB memory, 512 PIDs.
- Only `./workspace` is bind-mounted read-write; no `~`, `~/.ssh`, `~/.aws`,
  `~/.config`, or browser dirs.
- Web UI published on `127.0.0.1:8080` only (no external exposure).
- Multi-stage build: build tools (python3, make, g++) stay in the builder,
  not the runtime image.

On macOS, Docker Desktop already runs the daemon inside a sandboxed Linux VM,
so there is no host-root `dockerd`. For an extra escape barrier, enable
Docker Desktop **Enhanced Container Isolation** (Settings -> Features).

## Prerequisites

- Docker Desktop running.
- A local oMLX OpenAI-compatible server on `http://127.0.0.1:8000/v1` (host).

## First-time setup

```sh
cd ~/dsh-docker
cp .env.example .env        # edit .env, set DEEPSEEK_API_KEY
mkdir -p workspace
docker compose build
./run-dsh.sh seed           # seed oMLX patches into the volume
```

## Usage

```sh
./run-dsh.sh web                     # web UI at http://127.0.0.1:8080
./run-dsh.sh headless "run the tests"  # one-shot job
```

The agent can only read/write `/workspace` (bind-mounted to `~/dsh-docker/workspace`)
and `/data` (its private state volume). Put files you want it to touch in
`~/dsh-docker/workspace` first.

## oMLX config

The patches in `patches/` repoint the `deepseek-official` adapter at
`http://host.docker.internal:8000/v1` (the host oMLX server, as seen from the
container) and advertise four 4-bit models. The backup of the original
bare-metal config is in `~/dsh-omlx-backup/`.

## Files

- `Dockerfile` — multi-stage build.
- `docker-compose.yml` — hardened service definitions.
- `patches/{web,headless}/cordis.patch.yml` — container-variant oMLX patches.
- `seed-omlx.sh` — seeds patches into the `DSH_HOME` volume.
- `run-dsh.sh` — host wrapper.
- `.env.example` — API key template.
