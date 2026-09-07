#!/bin/sh
# Wrapper to run the hardened dsh container.
# Usage:
#   ./run-dsh.sh seed              # seed oMLX patches + pnpm store (once)
#   ./run-dsh.sh web               # web UI on http://127.0.0.1:8080
#   ./run-dsh.sh web <project>     # web UI, with <project> mounted at /workspace
#   ./run-dsh.sh headless "..."    # one-shot headless job
#   ./run-dsh.sh headless "..." <project>  # headless, with <project> at /workspace
#   ./run-dsh.sh headless --bg "..." [project]  # same, detached; check back with logs/runs
#   ./run-dsh.sh plugin web add <pkg>   # manage plugins (pnpm) in a profile
#   ./run-dsh.sh enable-terminal         # inject prebuilt node-pty into dsh-better-sidebar
#   ./run-dsh.sh sessions               # list recent dsh sessions (id, turns, title)
#   ./run-dsh.sh runs [latest|<substr>|clean [N]]  # list, cat, or prune run logs (default keep 10)
#   ./run-dsh.sh logs [latest|<substr>] # follow a live background job, or cat it once finished
#   ./run-dsh.sh status                 # stack status: containers, litellm, oMLX, volume usage
set -e
cd "$(dirname "$0")"
# Absolute repo dir, for read-only bind-mounting host scripts into the container.
SCRIPT_DIR="$PWD"
# Mount a project dir at /workspace if a path argument is given.
# Also passes the real folder's basename through as WORKSPACE_NAME, so the
# dsh UI can label the workspace with the project's actual name instead of
# the generic "workspace" mount point.
# Returns the -v/-e flag string (or empty).
mount_project() {
  p="$1"
  if [ -z "$p" ]; then
    echo ""
    return
  fi
  if ! [ -d "$p" ]; then
    echo "Error: project path not found: $p" >&2
    exit 1
  fi
  abs=$(cd "$p" && pwd)
  name=$(basename "$abs")
  echo "-v $abs:/workspace -e WORKSPACE_NAME=$name"
}

# Ensure the LiteLLM router is running before dsh starts.
ensure_router() {
  docker compose up -d litellm 2>&1 | grep -v "gcloud\|docker-helper\|WARN\|credential" || true
}

# Build a short, filesystem-safe slug from job text for a run log's file name.
slugify() {
  printf '%s' "$*" | tr -c '[:alnum:]' '_' | sed 's/__*/_/g;s/^_//;s/_$//' | cut -c1-30
}

# Fail-fast checks before an unattended headless job: a missing API key is a
# deterministic failure for every request, so it aborts; an unreachable oMLX
# server only warns (transient network hiccups happen, and dsh may retry).
# Catches a broken stack in ~1s instead of after the container starts and the
# job fails deep in a request chain.
preflight_headless() {
  _pf_ok=1
  if [ ! -f .env ] || ! grep -qE '^DEEPSEEK_API_KEY=.+' .env || grep -q '^DEEPSEEK_API_KEY=changeme$' .env; then
    echo "[preflight] DEEPSEEK_API_KEY not set in .env (copy .env.example and edit it)." >&2
    _pf_ok=0
  fi
  if ! curl -fsS -m 3 http://127.0.0.1:8000/v1/models >/dev/null 2>&1; then
    echo "[preflight] warning: local oMLX server not reachable at 127.0.0.1:8000 -- the job will likely fail." >&2
  fi
  [ "$_pf_ok" = 1 ] || { echo "[preflight] aborting." >&2; return 1; }
  return 0
}

# Run a headless dsh job with stdout+stderr teed to runs/<ts>-<slug>.log and
# dsh's real exit code propagated. POSIX sh has no pipefail/PIPESTATUS, so the
# command runs in a subshell with errexit disabled; its exit code is written to
# a sidecar file and read back after the pipe completes. $@ are the dsh args
# that follow `--profile headless`. Uses $MNT (set by the caller) for the
# project bind-mount, matching the rest of the wrapper. A run-summary block
# (task, start time, duration, exit code) is appended to the log and printed,
# scoped to what the wrapper can observe directly -- turn/token/tool-call
# counts live only in dsh's session log, an undocumented format of hundreds of
# concatenated per-event zstd frames tied to an evolving internal RFC, too
# fragile to parse here.
run_headless_logged() {
  mkdir -p runs
  _rhl_ts=$(date +%Y%m%d_%H%M%S)
  _rhl_slug=$(slugify "$@")
  [ -n "$_rhl_slug" ] || _rhl_slug="job"
  _rhl_log="runs/${_rhl_ts}-${_rhl_slug}.log"
  _rhl_exitf="runs/.last_exit"
  _rhl_start=$(date +%s)
  printf '[dsh] logging to %s\n' "$_rhl_log"
  # shellcheck disable=SC2086
  ( set +e; docker compose run --rm $MNT dsh-headless --profile headless "$@"; echo $? > "$_rhl_exitf" ) 2>&1 | tee "$_rhl_log"
  _rhl_rc=$(cat "$_rhl_exitf" 2>/dev/null || echo 0)
  rm -f "$_rhl_exitf"
  _rhl_dur=$(($(date +%s) - _rhl_start))
  {
    echo ""
    echo "---- run summary ----"
    echo "task:      $*"
    echo "started:   $(date -r "$_rhl_start" '+%Y-%m-%d %H:%M:%S')"
    echo "duration:  ${_rhl_dur}s"
    echo "exit code: $_rhl_rc"
    echo "log:       $_rhl_log"
  } | tee -a "$_rhl_log"
  return "$_rhl_rc"
}

# Start a headless job detached: this function returns immediately, and a
# backgrounded 'docker logs -f' streams the container's output to
# runs/<ts>-<slug>.log. Unlike the synchronous path, the container is NOT
# --rm'd here -- it must still exist when the backgrounded log-follow attaches
# (tested: with --rm, a 2s job's container was already gone 3s later, losing
# the tail of its output). It is removed explicitly once the log stream ends
# naturally. The container id is saved to a .cid sidecar so 'runs'/'logs' can
# tell a live job from a finished one.
run_headless_bg() {
  mkdir -p runs
  _rhb_ts=$(date +%Y%m%d_%H%M%S)
  _rhb_slug=$(slugify "$@")
  [ -n "$_rhb_slug" ] || _rhb_slug="job"
  _rhb_log="runs/${_rhb_ts}-${_rhb_slug}.log"
  _rhb_cid="runs/${_rhb_ts}-${_rhb_slug}.cid"
  # shellcheck disable=SC2086
  _rhb_id=$(docker compose run -d $MNT dsh-headless --profile headless "$@")
  printf '%s' "$_rhb_id" > "$_rhb_cid"
  ( docker logs -f "$_rhb_id" > "$_rhb_log" 2>&1 < /dev/null; docker rm "$_rhb_id" >/dev/null 2>&1 ) &
  echo "[dsh] started in background: $(printf '%s' "$_rhb_id" | cut -c1-12)"
  echo "[dsh] log: $_rhb_log"
  echo "[dsh] follow with: $0 logs latest"
}

case "${1:-}" in
  web)
    ensure_router
    MNT=$(mount_project "${2:-}")
    # The web entrypoint runs dsh on 127.0.0.1 (safety) and socat-proxies
    # 0.0.0.0:8080 so Docker can publish the port. --service-ports publishes.
    # shellcheck disable=SC2086
    docker compose run --rm --service-ports $MNT dsh-web
    ;;
  headless)
    ensure_router
    shift
    if [ "${1:-}" = "--bg" ]; then
      shift
      JOB="$1"; shift
      MNT=$(mount_project "${1:-}")
      preflight_headless || exit 1
      run_headless_bg "$JOB"
    else
      JOB="$1"; shift
      MNT=$(mount_project "${1:-}")
      preflight_headless || exit 1
      run_headless_logged "$JOB"
    fi
    ;;
  plugin)
    shift
    profile="$1"; shift
    docker compose run --rm dsh-headless plugin --profile "$profile" "$@"
    ;;
  seed)
    docker compose run --rm --entrypoint /usr/local/bin/seed-omlx.sh dsh-headless
    ;;
  enable-terminal)
    docker compose run --rm --entrypoint /usr/local/bin/enable-terminal.sh dsh-headless
    ;;
  sessions)
    docker compose run --rm --no-deps \
      -v "$SCRIPT_DIR/list-sessions.js:/s.js:ro" \
      --entrypoint node dsh-headless /s.js list
    ;;
  runs)
    mkdir -p runs
    ARG="${2:-}"
    if [ -z "$ARG" ]; then
      if ! ls runs/*.log >/dev/null 2>&1; then
        echo "No run logs yet."
      else
        for f in $(ls -1t runs/*.log); do
          name=$(printf '%s' "$f" | sed 's#runs/##')
          cidf="${f%.log}.cid"
          if [ -f "$cidf" ] && docker inspect "$(cat "$cidf")" >/dev/null 2>&1; then
            echo "$name  [running]"
          else
            echo "$name"
          fi
        done
      fi
    elif [ "$ARG" = "latest" ]; then
      L=$(ls -1t runs/*.log 2>/dev/null | head -1)
      if [ ! -f "$L" ]; then echo "No run logs." >&2; exit 1; fi
      cat "$L"
    elif [ "$ARG" = "clean" ]; then
      KEEP="${3:-10}"
      case "$KEEP" in ''|*[!0-9]*) echo "Invalid keep count: $KEEP" >&2; exit 2 ;; esac
      if ! ls runs/*.log >/dev/null 2>&1; then
        echo "No run logs to clean."
      else
        _rc_kept=0; _rc_removed=0
        for f in $(ls -1t runs/*.log); do
          cidf="${f%.log}.cid"
          # Never prune a log whose background job is still running.
          if [ -f "$cidf" ] && docker inspect "$(cat "$cidf")" >/dev/null 2>&1; then
            continue
          fi
          _rc_kept=$((_rc_kept + 1))
          if [ "$_rc_kept" -gt "$KEEP" ]; then
            rm -f "$f" "$cidf"
            _rc_removed=$((_rc_removed + 1))
          fi
        done
        echo "Pruned $_rc_removed run log(s); kept newest $KEEP."
      fi
    else
      case "$ARG" in */*) echo "Invalid log name." >&2; exit 2 ;; esac
      L=$(ls -1 runs/*"$ARG"* 2>/dev/null | head -1)
      if [ ! -f "$L" ]; then echo "No run log matching \"$ARG\"." >&2; exit 1; fi
      cat "$L"
    fi
    ;;
  logs)
    mkdir -p runs
    ARG="${2:-latest}"
    if [ "$ARG" = "latest" ]; then
      CIDF=$(ls -1t runs/*.cid 2>/dev/null | head -1)
      LOGF=$(ls -1t runs/*.log 2>/dev/null | head -1)
    else
      case "$ARG" in */*) echo "Invalid log name." >&2; exit 2 ;; esac
      CIDF=$(ls -1 runs/*"$ARG"*.cid 2>/dev/null | head -1)
      LOGF=$(ls -1 runs/*"$ARG"*.log 2>/dev/null | head -1)
    fi
    if [ -n "$CIDF" ] && [ -f "$CIDF" ] && docker inspect "$(cat "$CIDF")" >/dev/null 2>&1; then
      echo "[dsh] following live job (Ctrl+C detaches; the job keeps running)" >&2
      exec docker logs -f "$(cat "$CIDF")"
    fi
    if [ -n "$LOGF" ] && [ -f "$LOGF" ]; then
      cat "$LOGF"
    else
      echo "No run logs found." >&2
      exit 1
    fi
    ;;
  status)
    echo "Containers:"
    docker compose ps
    echo
    printf 'LiteLLM router (127.0.0.1:4000):  '
    if curl -fsS -m 3 http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1; then
      echo "reachable"
    else
      echo "NOT reachable -- start with: docker compose up -d litellm"
    fi
    printf 'oMLX server (127.0.0.1:8000):     '
    if OMLX_MODELS=$(curl -fsS -m 3 http://127.0.0.1:8000/v1/models 2>/dev/null); then
      echo "reachable"
      if command -v jq >/dev/null 2>&1; then
        printf '%s' "$OMLX_MODELS" | jq -r '.data[]?.id' | sed 's/^/    - /'
      fi
    else
      echo "NOT reachable -- start the local oMLX server"
    fi
    printf 'DEEPSEEK_API_KEY:                 '
    if [ -f .env ] && grep -qE '^DEEPSEEK_API_KEY=.+' .env && ! grep -q '^DEEPSEEK_API_KEY=changeme$' .env; then
      echo "set"
    else
      echo "NOT set -- copy .env.example to .env and edit it"
    fi
    printf 'dsh-home volume usage:            '
    docker compose run --rm --no-deps --entrypoint sh dsh-headless -c 'du -sh /data 2>/dev/null' 2>/dev/null || echo "unknown"
    ;;
  *)
    echo "Usage: $0 {seed|web|headless [--bg] \"<job>\"|plugin <profile> <pnpm args>|enable-terminal|sessions|runs [latest|<substr>|clean [N]]|logs [latest|<substr>]|status}" >&2
    exit 2
    ;;
esac
