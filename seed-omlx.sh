#!/bin/sh
# Seed the oMLX cordis.patch.yml into the DSH_HOME volume for both profiles.
# Run via: ./run-dsh.sh seed   (or: docker compose run --rm --entrypoint /usr/local/bin/seed-omlx.sh dsh-headless)
set -e
: "${DSH_HOME:=/data}"
for p in web headless; do
  mkdir -p "$DSH_HOME/profiles/$p"
  cp "/opt/dsh-patches/$p/cordis.patch.yml" "$DSH_HOME/profiles/$p/cordis.patch.yml"
  echo "seeded $DSH_HOME/profiles/$p/cordis.patch.yml"
done
# pnpm store on the writable volume (rootfs is read-only at runtime).
mkdir -p "${PNPM_HOME:-$DSH_HOME/.pnpm}"
echo "oMLX patches + pnpm store ready."
