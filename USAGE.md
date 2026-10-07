# dsh-docker — simple usage guide

Short reference for running and checking this stack on your Mac.
For full design and security detail, see [README.md](README.md).

## What you need

- Docker Desktop (or Docker Engine + Compose)
- A `.env` file with a non-empty `DEEPSEEK_API_KEY` (any local value is fine
  for TensorFold; copy from `.env.example`)
- TensorFold running on the host for real LLM answers
  - Fast: `http://127.0.0.1:8421` (`omlx-qwen36`)
  - Optional quality: `http://127.0.0.1:8423` (`tf-qwen38`)

Optional:

- `agents/private/` — confidential agent rules (gitignored; used at seed)
- `projects.local.sh` — project path aliases (copy `projects.example.sh`)

## One-time setup

```bash
cd ~/dsh-docker          # or your clone path
cp .env.example .env     # edit DEEPSEEK_API_KEY if needed
docker compose build
./run-dsh.sh seed
./run-dsh.sh doctor
```

`seed` installs cordis patches and builds `$DSH_HOME/AGENTS.md` from
`agents/public/` plus `agents/private/` when that folder exists.

Re-run `seed` after changing agent packs or patches. Rebuild the image after
changing `Dockerfile` or `global-tools/` dependencies.

## Everyday commands

All of these are from the repo root via `./run-dsh.sh`.

### Check the stack

```bash
./run-dsh.sh status      # containers, LiteLLM, TensorFold, oMLX
./run-dsh.sh doctor      # first-run readiness checklist
```

### Web UI

```bash
./run-dsh.sh web
```

Opens (or prints) the UI on `http://127.0.0.1:8080`. A one-time token URL is
copied to the clipboard when possible.

With a project mounted at `/workspace`:

```bash
./run-dsh.sh web ~/path/to/project
./run-dsh.sh web api                 # if defined in projects.local.sh
```

### Headless one-shot job

```bash
./run-dsh.sh headless "Reply with exactly: DSH OK"
./run-dsh.sh headless "run the tests" ~/path/to/project
```

Background job:

```bash
./run-dsh.sh headless --bg "list files in the workspace" ~/path/to/project
./run-dsh.sh logs latest
./run-dsh.sh runs
./run-dsh.sh stop latest             # cancel a live background job
```

### Templates

```bash
./run-dsh.sh task                    # list templates/
./run-dsh.sh task review ~/path/to/project
./run-dsh.sh task --bg changelog ~/path/to/project
```

### Shell inside the container

```bash
./run-dsh.sh exec                    # interactive sh
./run-dsh.sh exec dsh --help
./run-dsh.sh exec dsh --version
./run-dsh.sh exec dsh --profile headless --dump-config | head
```

### Plugins (advanced)

```bash
./run-dsh.sh plugin web add <npm-package>
./run-dsh.sh plugin headless <pnpm-args...>
```

### Sessions and logs

```bash
./run-dsh.sh sessions
./run-dsh.sh runs
./run-dsh.sh runs latest
./run-dsh.sh runs clean 10
./run-dsh.sh logs latest
```

## How to test that everything works

### 1. Packaging / security suite

```bash
./test-hardening.sh --no-build    # use current image
./test-hardening.sh               # rebuild, then full suite
```

Pass criteria: final line **`ALL INVARIANTS HOLD`** (0 failed).

### 2. Doctor + status

```bash
./run-dsh.sh seed
./run-dsh.sh doctor
./run-dsh.sh status
```

Pass criteria: no **FAIL** on doctor for required items; TensorFold reachable;
LiteLLM reachable after first web/headless (or `docker compose up -d litellm`).

### 3. LLM path (LiteLLM → TensorFold)

```bash
# start router if needed
docker compose up -d litellm

KEY=$(grep '^DEEPSEEK_API_KEY=' .env | cut -d= -f2-)

curl -sS "http://127.0.0.1:4000/v1/models" \
  -H "Authorization: Bearer $KEY"

curl -sS "http://127.0.0.1:4000/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "omlx-qwen36",
    "max_tokens": 32,
    "messages": [{"role": "user", "content": "Say only: TF OK"}]
  }'
```

Pass criteria: models list includes `omlx-qwen36` (and optionally `tf-qwen38`);
chat returns content like `TF OK`.

### 4. Full agent smoke

```bash
./run-dsh.sh headless "Say only: DSH OK"
./run-dsh.sh web
```

Pass criteria: headless prints an answer; web UI loads with the token URL.

## Models in the UI (typical)

| Choice | Backend | When to use |
| --- | --- | --- |
| `smart-router` | TensorFold fast (`omlx-qwen36`) | Default |
| `omlx-qwen36` | `:8421` | Fast coding |
| `tf-qwen38` / `Qwen3.8-27B-OptiQ-4bit` | `:8423` | Higher quality, slower |

## After pulling updates

```bash
git pull
docker compose build
./run-dsh.sh seed
./test-hardening.sh --no-build
./run-dsh.sh doctor
```

## Common problems

| Symptom | What to try |
| --- | --- |
| Doctor: TensorFold not reachable | `tensorfold service status` / start `omlx-qwen36` |
| Headless fails immediately | Check `.env` key; `./run-dsh.sh status` |
| LiteLLM down | `docker compose up -d litellm` |
| Old dsh behavior after upgrade | `docker compose build` (image must match lockfile) |
| Agent ignores private rules | Ensure `agents/private/` exists, then `./run-dsh.sh seed` |
| Native addon / “failed to map segment” | Compose must set `NARB_DISABLE_NATIVE_CACHE=1` (already default here) |
| Plugin install “no space” on /tmp | `/tmp` is 64MB tmpfs; caches use `/data/tmp` via `TMPDIR` — re-seed or `mkdir -p` under volume; do not fill host `/tmp` |
| `web_search_preview` / tools error | LiteLLM hook strips built-in OpenAI tools; recreate litellm: `docker compose up -d --force-recreate litellm` |

## More detail

- Architecture and hardening: [README.md](README.md)
- Agent packs (public/private): [agents/README.md](agents/README.md)
- License / DeepSeek attribution: [LICENSE](LICENSE), [NOTICE.md](NOTICE.md)
