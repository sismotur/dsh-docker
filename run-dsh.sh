#!/bin/sh
# Wrapper to run the hardened dsh container.
# Usage:
#   ./run-dsh.sh seed              # seed oMLX patches into the volume (once)
#   ./run-dsh.sh web               # web UI on http://127.0.0.1:8080
#   ./run-dsh.sh headless "..."    # one-shot headless job
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
  seed)
    docker compose run --rm --entrypoint /usr/local/bin/seed-omlx.sh dsh-headless
    ;;
  *)
    echo "Usage: $0 {seed|web|headless \"<job>\"}" >&2
    exit 2
    ;;
esac
