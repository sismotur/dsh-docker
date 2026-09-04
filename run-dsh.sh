#!/bin/sh
# Wrapper to run the hardened dsh container.
# Usage:
#   ./run-dsh.sh seed              # seed oMLX patches + pnpm store (once)
#   ./run-dsh.sh web               # web UI on http://127.0.0.1:8080
#   ./run-dsh.sh headless "..."    # one-shot headless job
#   ./run-dsh.sh plugin web add <pkg>   # manage plugins (pnpm) in a profile
set -e
cd "$(dirname "$0")"
case "${1:-}" in
  web)
    docker compose run --rm dsh-web --profile web --port 8080
    ;;
  headless)
    shift
    docker compose run --rm dsh-headless --profile headless "$@"
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
