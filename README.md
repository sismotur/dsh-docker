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
- **Init process** — `init: true` adds a proper PID 1 (tini) for correct signal
  handling and zombie reaping.
- **Restart policy** — `restart: unless-stopped`. Containers survive crashes and
  reboots. Applies to `docker compose up`-started services (e.g. litellm);
  `run --rm` ephemeral containers are not affected.
- **Log limits** — `logging: json-file` with `max-size: 10m, max-file: 3`.
  Prevents unbounded log growth on disk (caps at ~30 MB per service).

### Build controls (Dockerfile)

- **Multi-stage build** — `python3`, `make`, `g++` install in the `builder`
  stage for the native addon `node-addon-require-builtin` but are not copied
  to the runtime image. The runtime ships only Node + dsh + pnpm.
- **pnpm for plugin management** — installed in the builder and symlinked into
  runtime. Its store (`PNPM_HOME=/data/.pnpm`) lives on the writable named
  volume, not the read-only rootfs.
- **Postinstall scripts blocked by default** — `npm_config_ignore_scripts=true`
  plus pnpm 11's build-approval gate prevent npm lifecycle scripts from
  executing at install time. This neutralizes the primary supply-chain vector
  for a rogue plugin (a malicious `postinstall` cannot run). See
  [Plugins](#plugins) for the trusted-plugin override.
- **Explicit node entrypoint** — `ENTRYPOINT ["node", "--expose-internals",
  ".../bin.js"]`. dsh's HMR plugin requires `--expose-internals`; `NODE_OPTIONS`
  rejects that flag, so it must be a CLI argument.
- **socat TCP proxy for web** — dsh refuses `--host 0.0.0.0` (RCE safety),
  binding only to `127.0.0.1` inside the container, which Docker port
  forwarding cannot reach. A `web-entrypoint.sh` runs dsh on `127.0.0.1:8090`
  and `socat` bridges `0.0.0.0:8080` -> `127.0.0.1:8090` so the published port
  works. socat runs as the non-root `node` user; the host port is still
  `127.0.0.1`-only.
- **setuid/setgid stripped** — Debian base binaries (`su`, `passwd`, `mount`,
  etc.) have their setuid/setgid bits removed. No privilege-escalation surface
  remains (CIS Docker Benchmark).
- **Dev tools pre-installed** — `git`, `curl`, `jq`, `less`, `ripgrep`,
  `openssh-client` are added for in-container development (search, API
  testing, paging, git operations). These are userland utilities; none open
  ports or grant privileges.

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
cp .env.example .env        # edit .env, set DEEPSEEK_API_KEY and git identity
```

The API key is passed to the container via compose `environment`; it is never
baked into the image. `.env` is gitignored. Set `GIT_AUTHOR_NAME` /
`GIT_AUTHOR_EMAIL` (and the `COMMITTER` equivalents) too if you want the agent
to commit with your identity — the host `~/.gitconfig` is not mounted.

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
./run-dsh.sh web                           # serves the UI at http://127.0.0.1:8080
./run-dsh.sh web ~/Development/myproject   # same, with myproject mounted at /workspace
```

Runs in the foreground. Stop it with `Ctrl+C` in that terminal; the
container exits and is removed automatically.

### Headless profile (one-shot)

```sh
./run-dsh.sh headless "run the tests"
./run-dsh.sh headless "run the tests" ~/Development/myproject   # with project mounted
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
`~/dsh-docker/workspace` by default) and `/data` (its private state volume).
Put files you want it to touch in the workspace first, or pass a project path
(see below).

## Working on existing projects

To work on an existing repo, pass its path as an extra argument. The wrapper
bind-mounts that directory at `/workspace`, so the agent works directly on
your real repo — no clone, no copy, no syncing:

```sh
./run-dsh.sh web ~/Development/inventrip_api
./run-dsh.sh headless "fix the login bug" ~/Development/inventrip_api
```

The agent sees the repo at `/workspace`, with full read/write access to your
uncommitted changes, branches, and git history. Edits land on the real files
on your host immediately.

### Git identity

The host `~/.gitconfig` is not mounted, so set git identity in `.env`:

```sh
GIT_AUTHOR_NAME="Your Name"
GIT_AUTHOR_EMAIL="you@example.com"
GIT_COMMITTER_NAME="Your Name"
GIT_COMMITTER_EMAIL="you@example.com"
```

These are passed through to the container; commits made inside use your
identity.

### SSH keys for git push

`~/.ssh` is deliberately not mounted. If the repo uses an SSH remote and you
need `git push` from inside the container, generate a throwaway key or use an
HTTPS remote with a token instead. Mounting host SSH keys would expose them
to the agent.

### Security tradeoffs

Passing a project path expands the blast radius to that one directory —
intentional, since you chose to expose it. All other hardening still applies
(non-root, zero capabilities, read-only rootfs, no-new-privileges). Secrets
inside the project (`.env`, credential files) become visible to the agent;
consider whether you want that before mounting.

## Plugins

dsh profiles are extensible with plugin bundles. Plugin management is CLI-only
(the web UI's Plugins page shows installed plugins and their settings but
cannot install or remove them). Installs run inside the hardened container via
the wrapper, so they are confined by the same controls as the agent itself.

### Installing, listing, and removing

```sh
./run-dsh.sh plugin web add <package>        # install a plugin into the web profile
./run-dsh.sh plugin web list                 # list installed plugins
./run-dsh.sh plugin web remove <package>     # remove a plugin
```

`<package>` is any npm package name; dsh forwards to pnpm in the profile
directory (`/data/profiles/<name>`). A package that declares a `dsh.bundle` is
loaded as a profile layer; a plain dependency is installed but not layered in
until a later version adds a bundle.

### Persistence

Plugin installs persist on the `dsh-home` named volume (`/data`):
- `docker compose down` — **keeps** installed plugins (volume retained).
- `docker compose down -v` — **wipes** plugins, sessions, settings, and the
  pnpm store. Re-run `./run-dsh.sh seed` after `down -v` to restore the oMLX
  patches.

### Rogue-plugin protection

Two independent gates prevent a malicious package from running code at install
time:

1. **`ignore-scripts` env var** — blocks npm lifecycle scripts
   (`preinstall`, `install`, `postinstall`).
2. **pnpm 11 build-approval** — ignores build scripts unless explicitly
   approved.

Both are active by default. A rogue plugin's `postinstall` cannot execute.

At runtime, a loaded plugin runs as the unprivileged `node` user inside the
container with zero capabilities and a read-only rootfs — the same confinement
as the agent. Its blast radius is limited to `/workspace` and `/data`.

### Installing a trusted plugin that needs a native build

Some legitimate plugins ship native addons that require a build step. To allow
build scripts for a one-time trusted install, override both gates:

```sh
docker compose run --rm -e npm_config_ignore_scripts= --entrypoint sh dsh-headless \
  -c 'cd /data/profiles/web && pnpm add <package> --config.dangerouslyAllowAllBuilds=true'
```

This is intentionally verbose so that build approval is a deliberate, informed
act — not a default.

### Installing a git-hosted plugin

Some plugins are not published to npm (or the npm name is taken by an unrelated
package). Install them from GitHub with `github:<owner>/<repo>`. Git-hosted
plugins run a `prepare` build script, so both gates must be overridden:

```sh
docker compose run --rm -e npm_config_ignore_scripts= dsh-headless \
  plugin --profile web add "github:<owner>/<repo>"
```

The image includes `ca-certificates` so git HTTPS works. If SSL errors persist
on an older image, set `GIT_SSL_NO_VERIFY=1` (safe in the sandboxed container).

### Installed plugins

#### dsh-better-sidebar (file editor, Git panel, browser)

The [dsh-better-sidebar](https://github.com/omdsh-dev/DSH-better-sidebar) plugin
adds a full sidebar workspace to the dsh web UI: file explorer + CodeMirror
editor, Git panel (diff/stage/commit), embedded browser, and background task
view. It is installed in the web profile on the `dsh-home` volume.

The plugin's terminal feature depends on `node-pty` (a native addon). It is
**intentionally not compiled** — `node-pty` ships no Linux prebuilds (only
darwin/win32), so the terminal tab does not function inside the Linux
container. All other features (file editor, Git panel, browser) work normally.

To skip the native build without erroring, pnpm's `allowBuilds` is set to
`false` for `node-pty` in the profile's `pnpm-workspace.yaml`:

```yaml
allowBuilds:
  node-pty: false
```

**Reinstall after a volume wipe** (`docker compose down -v`):

```sh
# 1. Re-seed the oMLX patches and default model.
./run-dsh.sh seed

# 2. Set allowBuilds for node-pty (skip native build without error).
docker compose run --rm --entrypoint sh dsh-headless -c '
  cat >> /data/profiles/web/pnpm-workspace.yaml << EOF
allowBuilds:
  node-pty: false
EOF'

# 3. Install the plugin.
./run-dsh.sh plugin web add dsh-better-sidebar
```

After installation, hard-refresh the browser (Cmd/Ctrl+Shift+R) to see the
sidebar.

#### dsh-at-file (@file mentions)

[dsh-at-file](https://github.com/omdsh-dev/dsh-at-file) adds Codex-style `@file`
mentions to the prompt composer: type `@`, search workspace files, attach their
contents to the prompt. Pure UI plugin, no native deps. Same author as
dsh-better-sidebar.

```sh
./run-dsh.sh plugin web add dsh-at-file
```

#### aegis (engineering discipline skills)

[aegis](https://github.com/ganyuanran/aegis) is an engineering method pack:
baseline-first planning, systematic debugging, verification before completion,
and repair/retirement tracking. It enforces habits that prevent reworks — the
agent aligns with the real codebase state before editing and proves completion
with fresh evidence. Pure TypeScript skills, no native deps.

**Must be installed from GitHub** (the npm name `aegis` is an unrelated old JS
library):

```sh
docker compose run --rm -e npm_config_ignore_scripts= dsh-headless \
  plugin --profile web add "github:ganyuanran/aegis"
```

#### dsh-context (context window insight)

[dsh-context](https://github.com/bowenliang123/dsh-context) adds a context
insight panel: see what the model's context window contains, per-message token
stats, compression/injection events, and composition vs window size. Useful in
long agentic sessions to understand when and why the agent loses track. Pure UI
plugin, no native deps.

```sh
./run-dsh.sh plugin web add dsh-context
```

## MCP servers

MCP (Model Context Protocol) servers are pre-installed in the image and
injected via `cordis.patch.yml` for predictable, reproducible configuration —
no UI setup, no `npx`, no runtime network fetch.

### Memory server (knowledge graph)

The `@modelcontextprotocol/server-memory` package is pre-installed and
loaded as an `mcp-client` plugin instance in both web and headless profiles.
It provides persistent knowledge-graph memory across sessions:

- **Tools exposed**: `mcp__memory__create_entities`,
  `mcp__memory__create_relations`, `mcp__memory__add_observations`,
  `mcp__memory__delete_entities`, `mcp__memory__delete_observations`,
  `mcp__memory__delete_relations`, `mcp__memory__read_graph`,
  `mcp__memory__search_nodes`, `mcp__memory__open_nodes`.
- **Transport**: stdio (spawned as a child process inside the container).
- **Memory file**: `/data/memory.jsonl` on the `dsh-home` named volume —
  persists across `docker compose down` (retained); wiped by `down -v`.
- **Config source**: `patches/{web,headless}/cordis.patch.yml` (the `insert`
  block adding the `mcp-memory` entry).

The memory server is spawned automatically when dsh boots; no manual startup
is needed. To add more MCP servers, add another `insert` block in the patch
file and rebuild.

## LiteLLM router (auto model selection)

dsh points at a LiteLLM proxy (`litellm` compose service, port 4000) instead of
oMLX directly. LiteLLM's `complexity_router` classifies each request by
complexity and routes to the appropriate oMLX model — like Warp's "auto":

```
dsh container  →  LiteLLM (port 4000)  →  oMLX (port 8000)  →  models
                   classifies + routes
```

### Tiers

| Tier | Model | Active params | When |
|---|---|---|---|
| SIMPLE | Qwen3-VL-30B-A3B-Instruct-4bit | 3B | Greetings, simple lookups |
| MEDIUM | Qwen3-VL-30B-A3B-Instruct-4bit | 3B | Standard coding tasks |
| COMPLEX | Qwen3.8-27B-OptiQ-4bit | 27B | Architecture, multi-file |
| REASONING | Qwen3.6-35B-A3B-4bit | 3B | Deep analysis (thinking mode) |

The heuristic classifier is sub-millisecond (no extra model calls). Context-window
escalation is on by default: if a prompt provably won't fit the chosen model,
it auto-escalates to a bigger one. `classification_mode: user_turn` classifies
only new user asks and carries the decision through tool-result turns (fewer
classifier calls in agentic sessions).

### Default model

dsh's `agent-default-model` is set to `smart-router`. Individual models are
also advertised for manual per-session selection in the dsh UI.

### Fallbacks

If a model fails, LiteLLM falls back: `smart-router` → `Qwen3-VL-30B-A3B`,
`Qwen3-VL-30B-A3B` → `Qwen3.8-27B-OptiQ`, `Qwen3.8-27B-OptiQ` →
`Qwen3-VL-30B-A3B`, `Qwen3.6-35B-A3B` → `Qwen3.8-27B-OptiQ`.

### Config

- `litellm-config.yaml` — model list, auto router tiers, fallback chains.
- The `litellm` service is a long-running container started with
  `docker compose up -d litellm`. The wrapper starts it automatically before
  dsh.
- LiteLLM reaches oMLX via `host.docker.internal:8000`; dsh reaches LiteLLM via
  the compose network (`litellm:4000`).
- LiteLLM has a healthcheck (`/health/liveliness`) and `restart: unless-stopped`.
- Each target model sets `drop_params: true` **per-model** (not in
  `litellm_settings`) so unsupported params like dsh's `thinking` (sent when
  `reasoningEffort` is High) are dropped before reaching oMLX. Setting it
  globally would strip the `tools` parameter from router requests.

### oMLX settings tuning

The oMLX server config (`~/.omlx/settings.json`) was tuned for this setup:
`chunked_prefill`, `hot_cache_max_size: 32GB`, `initial_cache_blocks: 512`,
`burst_decode_mode: fast`, `max_concurrent_requests: 3`,
`max_context_window: 262144`. Backup at `~/.omlx/settings.json.bak.*`.

### oMLX tool parser fix (structured tool calls)

dsh sends the OpenAI `tools` parameter and expects structured `tool_calls` in
the response. Without `tool_parser_type` set in a model's
`tokenizer_config.json`, oMLX returns text-formatted tool calls
(`<function=bash>...`) as content with `finish_reason: stop` — dsh cannot
parse or execute them, so tools appear as raw text in the chat.

The fix: add `"tool_parser_type": "qwen3_coder"` to each model's
`tokenizer_config.json` (at `~/.omlx/models/<model>/tokenizer_config.json`).
This tells oMLX to parse the model's text output into structured
`tool_calls` with `finish_reason: tool_calls`.

Models fixed (backup at `tokenizer_config.json.bak`):

| Model | tool_parser_type | Status |
|---|---|---|
| Qwen3-VL-30B-A3B-Instruct-4bit | `qwen3_coder` | works (fix applied) |
| Qwen3.8-27B-OptiQ-4bit | `qwen3_coder` | works (was already set) |
| Qwen3.6-35B-A3B-4bit | `qwen3_coder` | works (fix applied) |
| Qwen3-Next-80B-A3B-Instruct-MLX-4bit | `qwen3_coder` | set (not yet verified) |

**Note:** Qwen3-Coder-30B-A3B-Instruct-4bit was removed from the setup because
it uses a different tokenizer (token IDs 151643/151645 vs 248044/248046) and
returns text-formatted tool calls despite the `tool_parser_type` setting. The
SIMPLE/MEDIUM tiers now use Qwen3-VL-30B-A3B-Instruct-4bit, which returns
structured `tool_calls` correctly and adds vision capability.

**After applying the fix, restart oMLX** so it reloads model configs.

```sh
# Apply the fix to a model:
python3 -c "
import json
p = '$HOME/.omlx/models/<model>/tokenizer_config.json'
d = json.load(open(p))
d['tool_parser_type'] = 'qwen3_coder'
json.dump(d, open(p, 'w'), indent=2, ensure_ascii=False)
print('done')
"
# Then restart oMLX (quit the app and relaunch).
```

## oMLX config

The backup of the original bare-metal dsh config is in `~/dsh-omlx-backup/`.
The oMLX server itself is configured via `~/.omlx/settings.json` (not part of
this repo). See the LiteLLM router section above for the current routing setup.

## Security audit

A full root-privilege audit was performed against the built image and running
container. All root-privilege escalation vectors are neutralized:

- Container user: `uid=1000(node)` (never root).
- Effective capabilities: `CapEff: 0000000000000000` (zero).
- Bounding capabilities: `CapBnd: 0000000000000000` (cannot acquire caps).
- `NoNewPrivs: 1` — setuid binaries cannot escalate.
- `Seccomp: 2` (filter mode) active.
- Root filesystem read-only; `/tmp` is `nosuid,nodev,noexec`.
- All root-owned paths (`/`, `/etc`, `/usr`, `/var`, `/root`, `/home`, `/opt`)
  unwritable by the container user.
- `sudo` not installed; setuid/setgid bits stripped from all base binaries.
- `--privileged` not used; no host namespaces.

No root privileges are exposed. The blast radius is limited to `/workspace`
and `/data`.

## Files

- `Dockerfile` — multi-stage build (dsh + pnpm + socat + dev tools + MCP memory server, build tools excluded).
- `docker-compose.yml` — hardened service definitions (dsh + litellm router).
- `litellm-config.yaml` — LiteLLM proxy config: model list, auto router tiers, fallbacks.
- `web-entrypoint.sh` — web entrypoint: dsh on loopback + socat proxy.
- `register-workspace.sh` — pre-registers `/workspace` in the dsh workspace registry on boot.
- `patches/{web,headless}/cordis.patch.yml` — LiteLLM router + MCP server patches.
- `seed-omlx.sh` — seeds patches and the pnpm store into the `DSH_HOME` volume.
- `run-dsh.sh` — host wrapper (seed / web / headless / plugin; starts litellm, accepts a project path).
- `.env.example` — API key and git identity template.
