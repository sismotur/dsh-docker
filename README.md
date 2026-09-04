# dsh — hardened Docker setup

Runs the DeepSeek harness CLI (`@deepseek-ai/dsh`) inside a locked-down
container instead of bare-metal on the host.

## Why

Bare-metal dsh is a full agent harness: it runs arbitrary bash, reads/writes
files, browses the web, and spawns subagents with your user's full privileges.
This setup confines it to a non-root, capability-stripped, read-only-root
container with only one workspace directory exposed.

## Hardening configuration

Each control below is set in `docker-compose.yml` (runtime) or `Dockerfile`
(build). The verified effect is what was observed during validation.

### Runtime controls (docker-compose.yml)

- **Non-root user** — `user: "1000:1000"`. The container runs as the
  `node` user (uid 1000, shipped by `node:25-slim`), never root. Verified:
  `id` reports `uid=1000(node)`.
- **All capabilities dropped** — `cap_drop: [ALL]`. Removes every Linux
  capability (e.g. `CAP_SYS_ADMIN`, `CAP_NET_ADMIN`). Verified:
  `CapEff: 0000000000000000` (zero effective capabilities).
- **No privilege escalation** — `security_opt: [no-new-privileges:true]`.
  Blocks `setuid` binaries from raising privileges.
- **Read-only root filesystem** — `read_only: true`. The container rootfs
  is mounted read-only. Verified: writes to `/` and `/etc` fail with
  "Read-only file system". Only three paths are writable:
  - `/tmp` — `tmpfs` (`noexec,nosuid`, 64 MB), ephemeral per container.
  - `/data` — named volume `dsh-home`, persistent `DSH_HOME` state.
  - `/workspace` — bind-mounted to `~/dsh-docker/workspace`, the only host
    directory the agent can touch.
- **Scoped volumes** — only `./workspace` is bind-mounted. No `~`, `~/.ssh`,
  `~/.aws`, `~/.config`, or browser dirs are exposed.
- **Resource limits** — `cpus: "4"`, `mem_limit: 4g`, `pids_limit: 512`.
  Caps CPU, memory, and process count to bound runaway agent loops.
- **Loopback-only port** — `127.0.0.1:8080:8080`. The web UI is reachable
  only from the host, never from the network.

### Build controls (Dockerfile)

- **Multi-stage build** — `python3`, `make`, `g++` install in the `builder`
  stage for the native addon `node-addon-require-builtin` but are not copied
  to the runtime image. The runtime ships only Node + dsh.
- **Explicit node entrypoint** — `ENTRYPOINT ["node", "--expose-internals",
  ".../bin.js"]`. dsh's HMR plugin requires `--expose-internals`; `NODE_OPTIONS`
  rejects that flag, so it must be a CLI argument.

### Daemon isolation (macOS)

On macOS, Docker Desktop runs `dockerd` inside a sandboxed Linux VM (Apple
Virtualization.framework), not as root on the host. There is no host `docker`
group. `rootlesskit` / `dockerd-rootless.sh` are Linux-only and do not apply.
For an extra escape barrier, enable Docker Desktop **Enhanced Container
Isolation** (Settings -> Features) to run the container under a user-space
kernel (gVisor), blocking escapes even on a kernel CVE.

## Prerequisites

- Docker Desktop running.
- A local oMLX OpenAI-compatible server on `http://127.0.0.1:8000/v1` (host).

## Deployment

### 1. Configure the API key

```sh
cd ~/dsh-docker
cp .env.example .env        # edit .env, set DEEPSEEK_API_KEY
```

The key is passed to the container via compose `environment`; it is never
baked into the image. `.env` is gitignored.

### 2. Create the workspace bind mount

```sh
mkdir -p workspace
```

This is the only host directory the agent can read/write. Put files for it
to work on here before starting a job.

### 3. Build the image

```sh
docker compose build
```

Produces `dsh-hardened:latest`. Rebuild after any `Dockerfile` or patch
change. The gcloud docker-auth warnings in build output are harmless noise
from GCR registry credential helpers and do not affect the build.

### 4. Seed the oMLX patches (once, and after every `down -v`)

```sh
./run-dsh.sh seed
```

Copies the container-variant `cordis.patch.yml` into `/data/profiles/{web,headless}/`
inside the `dsh-home` volume. These repoint dsh's `deepseek-official` adapter
at `http://host.docker.internal:8000/v1` (the host oMLX server).

### 5. Verify the deployment

```sh
# dsh boots inside the container:
docker run --rm dsh-hardened:latest --help | head -3

# Hardening is active (non-root, no caps, read-only rootfs):
docker compose run --rm --entrypoint sh dsh-headless -c \
  'id; grep CapEff /proc/1/status; (echo x > /_t) 2>&1 || echo "rootfs read-only OK"'

# The container can reach the host oMLX server:
echo 'fetch("http://host.docker.internal:8000/v1/models").then(r=>console.log("HTTP",r.status)).catch(e=>console.log("ERR",e.message))' \
  | docker run --rm -i --entrypoint node dsh-hardened:latest -
```

Expected: `id` shows `uid=1000`, `CapEff` is all zeros, rootfs write fails,
and the oMLX fetch returns `HTTP 401` (reachable; auth needed until the key
is set). See the "Starting and stopping" section to run jobs.

## Starting and stopping

dsh has no background daemon. Each invocation is an ephemeral container
(`--rm`) whose lifecycle depends on the profile:

### Web profile (long-running, interactive)

```sh
./run-dsh.sh web        # serves the UI at http://127.0.0.1:8080
```

Runs in the foreground. Stop it with `Ctrl+C` in that terminal; the
container exits and is removed automatically.

### Headless profile (one-shot)

```sh
./run-dsh.sh headless "run the tests"
```

Runs one job, prints the result, and exits on its own. No manual stop
needed; the container removes itself when done.

### Checking what is running

```sh
docker compose ps       # list active containers
```

### Cleaning up (containers, volume, image)

```sh
docker compose down         # remove containers and network
# Add `-v` to also delete the dsh-home volume (wipes profiles/sessions/settings):
docker compose down -v
docker image rm dsh-hardened:latest   # remove the built image
```

Re-run `./run-dsh.sh seed` after `down -v` to restore the oMLX patches into
the recreated volume.

The agent can only read/write `/workspace` (bind-mounted to
`~/dsh-docker/workspace`) and `/data` (its private state volume). Put files
you want it to touch in `~/dsh-docker/workspace` first.

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
