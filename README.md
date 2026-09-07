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
- **One-time token auth (dsh 0.1.2+)** — dsh gates web access behind a
  one-time token in the launch URL. The bare `http://127.0.0.1:8080` returns
  401; the tokenized URL (printed at startup) sets an auth cookie on first
  open. `web-entrypoint.sh` rewrites the internal port in dsh's startup URL
  line to the published proxy port so the user gets the correct tokenized URL.
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

## Permission model and fail-safe defaults

dsh enforces its own permission layer on top of this container's OS-level
confinement. It exposes two independent knobs, bundled into named presets that
a user switches with the `/permission` command:

- **Sandbox mode** — `read-only` | `workspace-write` | `danger-full-access`
  (how far the bash executor lets writes escape).
- **Approval policy** — `ask` | `never` (whether each action needs human
  confirmation).

The shipped preset table has two entries:

- **`workspace-write`** — sandbox `workspace-write` + approval `ask`. This is
  the **default**: writes confined to the workspace, every action approved.
- **`danger-full-access`** — sandbox `danger-full-access` + approval `never`.
  Full access, no confirmation. The permissive end.

### Fail-safe posture

The design fails closed — an unknown or unset permission resolves to the
restrictive value, never to allow (the same principle behind Warp's execution
profiles):

- **No relaxing env var is injected.** The container sets only
  `DEEPSEEK_API_KEY`, the git-identity vars, `GIT_CONFIG_SYSTEM`,
  `DSH_ISOLATION_PLATFORM`, and `IS_SANDBOXED`. None widens the sandbox or
  suppresses approval, so dsh's restrictive default (`workspace-write` +
  `ask`) holds for every fresh session.
- **Switching to `danger-full-access` is a deliberate, in-session act** via
  `/permission`, recorded as durable user intent — never a build-time or env
  default.
- **The credential scrub is fail-closed.** `dsh-subprocess` strips any
  env-var whose **name** matches `/KEY|PASSWORD|SECRET|TOKEN/i` before
  spawning commands. It removes on match and keeps only verified survivors,
  so a mis-typed secret name is dropped, not leaked.

### Defense in depth

dsh's `workspace-write` sandbox is enforced *on top of* the container's
OS-level confinement (read-only rootfs, `cap_drop: ALL`, `no-new-privileges`,
uid 1000). Even a session running `danger-full-access` cannot escape the
container: the blast radius stays `/workspace` and `/data`.

### Rule for future changes

Any new autonomy or approval knob must default to the restrictive end (`ask`
or `workspace-write`) unless deliberately opted in. Never inject a setting
that relaxes approval or widens the sandbox as a build or env default.

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

Runs in the foreground. dsh 0.1.2+ prints a **tokenized URL** at startup
(`http://127.0.0.1:8080/?token=...`) — open that exact URL in your browser;
the bare URL without the token returns 401. The token sets an auth cookie
valid for 30 days. Stop the container with `Ctrl+C`; it exits and is removed
automatically.

### Headless profile (one-shot)

```sh
./run-dsh.sh headless "run the tests"
./run-dsh.sh headless "run the tests" ~/Development/myproject   # with project mounted
```

Runs one job, prints the result, and exits on its own. No manual stop
needed; the container removes itself when done. Before starting, the wrapper
runs a fail-fast preflight: it aborts if `DEEPSEEK_API_KEY` is unset in `.env`
(a guaranteed failure for every request) and warns — but still proceeds — if
the local oMLX server is unreachable (a network blip may be transient).

### Background headless jobs

```sh
./run-dsh.sh headless --bg "run the tests"                # returns immediately
./run-dsh.sh headless --bg "run the tests" ~/Development/myproject
./run-dsh.sh logs latest       # follow the job live (Ctrl+C detaches, job keeps running)
./run-dsh.sh logs <substr>     # follow (or, once finished, print) a specific job's log
```

Use `--bg` for a job you want to fire off and check on later instead of
watching in the foreground. Unlike the synchronous path, the container is not
auto-removed until its output has been fully captured to `runs/`, so nothing
is lost if you check back after it has already finished — `logs` prints the
completed log instead of trying to attach. `./run-dsh.sh runs` marks a
still-running background job with `[running]`.

### Checking what is running

```sh
./run-dsh.sh status     # containers, LiteLLM/oMLX reachability, API key, dsh-home volume usage
docker compose ps       # list active containers only
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

### Session history

List past dsh sessions (id, turn count, last-activity timestamp, title):

```sh
./run-dsh.sh sessions
```

Sessions persist on the `dsh-home` volume (`/data`), so they survive
`docker compose down` and are wiped only by `down -v`. The list reads the
session-projection cache inside the container via a read-only bind-mount of
`list-sessions.js` — no image rebuild needed.

To reopen a session, start the web UI (`./run-dsh.sh web`) and pick it from
the sidebar's session list. dsh exposes no CLI resume flag for the web or
headless profiles (its `--resume` is a `tui`-profile flag, and no `tui`
profile is shipped here), so resuming is a web UI action, not a CLI one.

### Run logs

Every headless run (foreground or `--bg`) is teed to a timestamped log under
`runs/`, so the output is not lost when the ephemeral container exits. The
wrapper propagates dsh's real exit code (POSIX `sh` has no `pipefail`, so the
exit code is captured via a sidecar file, not the pipe) and appends a run
summary to the end of the log:

```
---- run summary ----
task:      run the tests
started:   2026-09-07 14:18:23
duration:  45s
exit code: 0
log:       runs/20260907_141823-run_the_tests.log
```

The summary is deliberately limited to what the wrapper can observe directly
from the outside (task text, wall-clock timing, exit code). Turn count, token
usage, and tool-call counts are not included: they exist only inside dsh's
own session log, which stores each event as a separate zstd-compressed frame
(hundreds per session) in a format tied to an evolving internal RFC, not a
stable public API — parsing it would be fragile and likely to break on a dsh
upgrade.

```sh
./run-dsh.sh runs                # list run logs (newest first); [running] tags live jobs
./run-dsh.sh runs latest         # print the most recent run log
./run-dsh.sh runs <substr>       # print a log whose name contains <substr>
./run-dsh.sh runs clean [N]      # prune all but the newest N logs (default 10); live jobs skipped
```

`runs clean` prunes old logs, keeping the newest N (default 10); a log whose
background job is still running is never pruned. `runs/` is gitignored. Web
(interactive) runs are not logged — only headless (unattended) runs, which is
where lost output matters.

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

### safe.directory for bind-mounted repos

Bind-mounted repos under `/workspace` are owned by the host uid, not the
container's uid 1000, so git's `safe.directory` check would reject them as
"dubious ownership". The fix is a system gitconfig baked into the image at
build time:

```ini
# /etc/gitconfig (baked by the Dockerfile)
[safe]
	directory = /workspace
```

`docker-compose.yml` sets `GIT_CONFIG_SYSTEM=/etc/gitconfig` so git reads it.
This replaced an earlier `GIT_CONFIG_COUNT=1` / `GIT_CONFIG_KEY_0` /
`GIT_CONFIG_VALUE_0` env-var trio that broke inside dsh: dsh's command-spawn
credential scrub (`dsh-subprocess`) strips any env-var whose **name** matches
`/KEY|PASSWORD|SECRET|TOKEN/i`. `GIT_CONFIG_COUNT` survived the scrub but
`GIT_CONFIG_KEY_0` was stripped, leaving git with a count of 1 and no key →
`error: missing config key GIT_CONFIG_KEY_0`. `GIT_CONFIG_SYSTEM` survives
the scrub (no sensitive keyword in the name) and is in dsh's bootstrap env
allowlist, so it reaches both direct and agent-spawned git invocations.

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

#### dsh-better-sidebar (file editor, Git panel, terminal, browser)

The [dsh-better-sidebar](https://github.com/omdsh-dev/DSH-better-sidebar) plugin
adds a full sidebar workspace to the dsh web UI: file explorer + CodeMirror
editor, Git panel (diff/stage/commit), embedded browser, terminal, and
background task view. It is installed in the web profile on the `dsh-home`
volume.

**Open chat files in the sidebar** (`interceptOpenPath`, on by default): file
links in chat (tool-row paths, produced-files row, mentions) open in the
sidebar editor instead of the system default app. This feature hooks dsh's
`remote.session.openWorkspacePath` funnel, which arrived in dsh 0.1.2 — it
was inert on 0.1.1-rc.2 (the wrapper bailed when the method was absent, so
clicks fell through to the no-op `xdg-open` shim). The 0.1.2-rc.1 upgrade
activates it. Toggle it in Settings → Side card → "Open chat files in the
sidebar".

##### Terminal tab (node-pty native addon)

The terminal tab depends on `node-pty`, a native addon. `node-pty` 1.1.0
ships prebuilds for darwin and win32 but **not for linux**, so the binary must
be compiled from source. The runtime image has no build tools (kept minimal
for hardening — no `python3`/`make`/`g++`), so `pty.node` is pre-compiled in
the Docker **builder** stage and baked into the runtime image at
`/opt/prebuilds/node-pty/pty.node`. pnpm's `allowBuilds: node-pty: false` in
the profile's `pnpm-workspace.yaml` skips the compile at install time (it
would fail without build tools); the prebuilt binary is injected afterward.

node-pty uses N-API (ABI-stable), so the 81 KB binary loads across Node.js
versions. The loader (`lib/utils.js`) checks `build/Release/pty.node` first,
which is where the injection puts it. On Linux the native `pty.node` handles
`forkpty()` directly; the `spawn-helper` binary the plugin's `ensureSpawnHelper`
looks for is macOS-only and not needed.

Enable the terminal after installing the plugin:

```sh
./run-dsh.sh plugin web add dsh-better-sidebar
./run-dsh.sh enable-terminal   # injects pty.node; idempotent
```

Then hard-refresh the browser (Cmd/Ctrl+Shift+R). The terminal tab opens a
login shell (`-l`), resolved as an emulator would: an explicitly configured
shell → `$SHELL` → the passwd login shell → `/bin/bash`.

##### Customizing terminal aliases

Edit `dsh-aliases.sh` in this repo to add, remove, or change the aliases and
shell functions available in the terminal tab. The Dockerfile bakes it into
`/etc/profile.d/dsh-aliases.sh`, which `/etc/profile` sources for bash login
shells (the terminal spawns `bash -l`). It is NOT sourced by dsh's bash tool
(non-login `bash -c`), so the aliases apply only to the interactive terminal.
After editing, rebuild and restart:

```sh
docker compose build
docker rm -f $(docker ps -q --filter name=dsh-web) 2>/dev/null
./run-dsh.sh web
```

Only include aliases safe for the sandbox: no secrets, no destructive ops,
no host-only paths, and no binaries absent from the image.

**Security**: the terminal runs a PTY in the same sandbox as the agent — same
uid 1000, zero capabilities, read-only rootfs, seccomp filter. A PTY is a
standard POSIX facility with no privilege escalation. The agent already has
full command execution via the bash tool; the terminal adds interactivity
with no expansion of the blast radius (still `/workspace` and `/data`).

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

# 4. Inject the prebuilt node-pty binary to activate the terminal tab.
./run-dsh.sh enable-terminal
```

After installation, hard-refresh the browser (Cmd/Ctrl+Shift+R) to see the
sidebar.

#### dsh-at-file — removed (incompatible with dsh 0.1.2-rc.1)

dsh-at-file v0.6.3 (the only published version) imports `settingsNamespace`
from `@deepseek-ai/dsh-settings`, an export removed in dsh 0.1.2-rc.1. It
fails to load and breaks the entire plugin tree at boot. There is no newer
version. It was removed from the web profile. The `@file` hover button in
dsh-better-sidebar's file explorer covers the same use case.

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

## Security invariants

The testable properties the hardened image guarantees. Each is phrased as an
invariant that must hold after every build. The `./test-hardening.sh` suite
asserts all of them automatically (host static checks + in-container checks
under the real runtime security context); run it after any hardening change.
They are also verified by the smoke commands in [Deployment §5](#5-verify-the-deployment)
and the [Security audit](#security-audit) above.

**Runtime (docker-compose.yml)**

1. Runs as uid 1000, never root — `id` reports `uid=1000(node)`.
2. Zero effective capabilities — `CapEff: 0000000000000000`.
3. Zero bounding capabilities — `CapBnd: 0000000000000000`.
4. `NoNewPrivs: 1` — setuid binaries cannot escalate.
5. Root filesystem read-only — writes to `/` and `/etc` fail.
6. Only three writable paths: `/tmp` (tmpfs, `noexec,nosuid`, 64 MB), `/data`
   (named volume), `/workspace` (bind mount).
7. `/tmp` is `noexec` — no binary execution from tmpfs.
8. No host secrets mounted — `~/.ssh`, `~/.aws`, `~/.config`, browser dirs
   are not exposed.
9. Web port loopback-only — `127.0.0.1:8080`, never the network.
10. Resource-bounded — `cpus: 4`, `mem_limit: 4g`, `pids_limit: 512`.

**Build (Dockerfile)**

11. No setuid/setgid binaries — `find / -xdev -perm /6000` returns nothing.
12. Build tools (`python3`, `make`, `g++`) exist only in the builder stage;
    the runtime ships none.
13. `/etc/gitconfig` baked with `safe.directory = /workspace` so bind-mounted
    repos pass git's ownership check.
14. `npm_config_ignore_scripts=true` in the runtime — npm/pnpm lifecycle
    scripts blocked by default (rogue-plugin supply-chain gate).

**Permission (dsh + container)**

15. dsh's default preset is `workspace-write` (sandboxed + `ask`) — the
    restrictive end; `danger-full-access` is opt-in per session.
16. No container env var relaxes approval or widens the sandbox.
17. `dsh-subprocess` scrubs env-vars matching `/KEY|PASSWORD|SECRET|TOKEN/i`
    on every command spawn (fail-closed).

**Supply chain (lockfiles)**

18. The builder installs `global-tools` and `pty-build` with `npm ci` from
    committed `package-lock.json` files — every tarball fetched by sha512
    integrity hash, no "latest" resolution at build time.
19. `node-pty` is compiled from a verified tarball in the builder; only the
    81 KB `pty.node` binary crosses into the read-only runtime.

## Validating hardening

Run the hardening validation suite after any `Dockerfile`, `docker-compose.yml`,
or lockfile change to confirm every security invariant still holds:

```sh
./test-hardening.sh             # build, then run all checks
./test-hardening.sh --no-build  # test the current image without rebuilding
```

Phase A checks the host config statically (compose runtime controls, Dockerfile
build controls, lockfile integrity via `jq`). Phase B builds the image. Phase C
bind-mounts `hardening-checks.sh` into a container and runs it under the real
runtime security context (cap_drop ALL, no-new-privileges, read-only rootfs,
/tmp noexec tmpfs) to assert the in-container invariants. The suite exits
non-zero on any failure, so it can gate a pre-deploy check. Requires `docker`,
`docker compose`, and `jq` on the host.

## Files

- `Dockerfile` — multi-stage build (dsh + pnpm + socat + dev tools + MCP memory server, build tools excluded).
- `global-tools/` — pinned, integrity-verified dependency tree (`package.json` + `package-lock.json`) for the builder-stage global tools (dsh, pnpm, MCP memory server); installed via `npm ci`.
- `pty-build/` — pinned, integrity-verified dependency tree (`package.json` + `package-lock.json`) for the node-pty native-addon compile; installed via `npm ci`.
- `docker-compose.yml` — hardened service definitions (dsh + litellm router).
- `litellm-config.yaml` — LiteLLM proxy config: model list, auto router tiers, fallbacks.
- `web-entrypoint.sh` — web entrypoint: dsh on loopback + socat proxy + token-URL port rewrite.
- `register-workspace.sh` — pre-registers `/workspace` in the dsh workspace registry on boot.
- `patches/{web,headless}/cordis.patch.yml` — LiteLLM router + MCP server patches.
- `seed-omlx.sh` — seeds patches and the pnpm store into the `DSH_HOME` volume.
- `run-dsh.sh` — host wrapper (seed / web / headless [--bg] / plugin / enable-terminal / sessions / runs / logs / status; starts litellm, accepts a project path, preflight-checks the stack before headless jobs, tees headless output to `runs/` with a run summary).
- `list-sessions.js` — in-container helper (bind-mounted read-only) that lists dsh sessions from the session-projection cache; invoked by `./run-dsh.sh sessions`.
- `enable-terminal.sh` — injects the prebuilt node-pty binary into the dsh-better-sidebar plugin so the terminal tab works.
- `test-hardening.sh` — host-side hardening validation suite driver (Phase A host static checks, Phase B build, Phase C in-container checks); exits non-zero on any invariant violation.
- `hardening-checks.sh` — in-container invariant checks (uid, caps, no-new-privs, read-only rootfs, /tmp noexec, no setuid, no build tools, gitconfig, ignore-scripts, node-pty prebuild, env-scrub pattern, default preset); invoked by `test-hardening.sh`.
- `.env.example` — API key and git identity template.
