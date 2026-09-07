#!/bin/sh
# Wrapper to run the hardened dsh container.
# Usage:
#   ./run-dsh.sh seed              # seed oMLX patches + pnpm store (once)
#   ./run-dsh.sh web               # web UI on http://127.0.0.1:8080
#   ./run-dsh.sh web <project>     # web UI, with <project> mounted at /workspace
#   ./run-dsh.sh headless "..."    # one-shot headless job
#   ./run-dsh.sh headless "..." <project>  # headless, with <project> at /workspace
#   ./run-dsh.sh plugin web add <pkg>   # manage plugins (pnpm) in a profile
#   ./run-dsh.sh enable-terminal         # inject prebuilt node-pty into dsh-better-sidebar
#   ./run-dsh.sh sessions               # list recent dsh sessions (id, turns, title)
#   ./run-dsh.sh runs [latest|<substr>] # list or cat headless run logs
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

# Run a headless dsh job with stdout+stderr teed to runs/<ts>-<slug>.log and
# dsh's real exit code propagated. POSIX sh has no pipefail/PIPESTATUS, so the
# command runs in a subshell with errexit disabled; its exit code is written to
# a sidecar file and read back after the pipe completes. $@ are the dsh args
# that follow `--profile headless`. Uses $MNT (set by the caller) for the
# project bind-mount, matching the rest of the wrapper.
run_headless_logged() {
  mkdir -p runs
  _rhl_ts=$(date +%Y%m%d_%H%M%S)
  _rhl_slug=$(printf '%s' "$*" | tr -c '[:alnum:]' '_' | sed 's/__*/_/g;s/^_//;s/_$//' | cut -c1-30)
  [ -n "$_rhl_slug" ] || _rhl_slug="job"
  _rhl_log="runs/${_rhl_ts}-${_rhl_slug}.log"
  _rhl_exitf="runs/.last_exit"
  printf '[dsh] logging to %s\n' "$_rhl_log"
  # shellcheck disable=SC2086
  ( set +e; docker compose run --rm $MNT dsh-headless --profile headless "$@"; echo $? > "$_rhl_exitf" ) 2>&1 | tee "$_rhl_log"
  _rhl_rc=$(cat "$_rhl_exitf" 2>/dev/null || echo 0)
  rm -f "$_rhl_exitf"
  printf '[dsh] log saved: %s (exit %s)\n' "$_rhl_log" "$_rhl_rc"
  return "$_rhl_rc"
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
    JOB="$1"; shift
    MNT=$(mount_project "${1:-}")
    run_headless_logged "$JOB"
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
        ls -1t runs/*.log | sed 's#runs/##'
      fi
    elif [ "$ARG" = "latest" ]; then
      L=$(ls -1t runs/*.log 2>/dev/null | head -1)
      if [ ! -f "$L" ]; then echo "No run logs." >&2; exit 1; fi
      cat "$L"
    else
      case "$ARG" in */*) echo "Invalid log name." >&2; exit 2 ;; esac
      L=$(ls -1 runs/*"$ARG"* 2>/dev/null | head -1)
      if [ ! -f "$L" ]; then echo "No run log matching \"$ARG\"." >&2; exit 1; fi
      cat "$L"
    fi
    ;;
  *)
    echo "Usage: $0 {seed|web|headless \"<job>\"|plugin <profile> <pnpm args>|enable-terminal|sessions|runs [latest|<substr>]}" >&2
    exit 2
    ;;
esac
