#!/bin/sh
# Wrapper to run the hardened dsh container.
# Usage:
#   ./run-dsh.sh seed              # seed oMLX patches + pnpm store (once)
#   ./run-dsh.sh web               # web UI on http://127.0.0.1:8080
#   ./run-dsh.sh web <project>     # web UI, with <project> mounted at /workspace
#   ./run-dsh.sh headless "..."    # one-shot headless job
#   ./run-dsh.sh headless "..." <project>  # headless, with <project> at /workspace
#   ./run-dsh.sh plugin web add <pkg>   # manage plugins (pnpm) in a profile
set -e
cd "$(dirname "$0")"
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
    # shellcheck disable=SC2086
    docker compose run --rm $MNT dsh-headless --profile headless "$JOB"
    ;;
  plugin)
    shift
    profile="$1"; shift
    docker compose run --rm dsh-headless plugin --profile "$profile" "$@"
    ;;
  seed)
    docker compose run --rm --entrypoint /usr/local/bin/seed-omlx.sh dsh-headless
    ;;
  *)
    echo "Usage: $0 {seed|web|headless \"<job>\"|plugin <profile> <pnpm args>}" >&2
    exit 2
    ;;
esac
