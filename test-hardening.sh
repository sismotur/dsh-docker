#!/bin/sh
# Hardening validation suite for the dsh-hardened container.
#
# Builds the image and asserts every security invariant documented in
# README.md ("Security invariants"). Exits non-zero if any invariant fails,
# so it can gate CI or a pre-deploy check.
#
# Usage:
#   ./test-hardening.sh             # build, then run all checks
#   ./test-hardening.sh --no-build  # skip the build, test the current image
#
# Requires `docker`, `docker compose`, and `jq` on the host.

cd "$(dirname "$0")"
BUILD=1
[ "${1:-}" = "--no-build" ] && BUILD=0

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required on the host (lockfile integrity checks). Install jq and re-run." >&2
  exit 2
fi

HOST_PASS=0
HOST_FAIL=0
hok() { printf 'PASS: %s\n' "$1"; HOST_PASS=$((HOST_PASS + 1)); }
hno() { printf 'FAIL: %s (%s)\n' "$1" "${2:-}"; HOST_FAIL=$((HOST_FAIL + 1)); }
hcheck()      { n="$1"; shift; if "$@" >/dev/null 2>&1; then hok "$n"; else hno "$n" "exit $?"; fi; }
hcheck_fail() { n="$1"; shift; if "$@" >/dev/null 2>&1; then hno "$n" "expected failure, got success"; else hok "$n"; fi; }

# lockfile_integrity PATH — true if every fetched package (non-link) has an
# integrity hash. Workspace links and the root package are excluded.
lockfile_integrity() {
  jq -e '[.packages | to_entries[]
         | select(.key | startswith("node_modules/"))
         | select(.value.link != true)]
        | all(.[]; .value.integrity)' "$1" >/dev/null 2>&1
}

echo "=== Phase A: host static checks ==="

# Runtime controls declared in docker-compose.yml
hcheck "host:web-port-loopback"   grep -q '127.0.0.1:8080:8080' docker-compose.yml
hcheck "host:cap-drop-all"        grep -q 'cap_drop:' docker-compose.yml
hcheck "host:cap-drop-all-value"  grep -q -- '- ALL' docker-compose.yml
hcheck "host:no-new-privs"        grep -q 'no-new-privileges:true' docker-compose.yml
hcheck "host:read-only-rootfs"    grep -q 'read_only: true' docker-compose.yml
hcheck "host:tmpfs-noexec"        grep -q '/tmp:noexec' docker-compose.yml
hcheck "host:pids-limit"          grep -q 'pids_limit: 512' docker-compose.yml
hcheck "host:mem-limit"           grep -q 'mem_limit: 4g' docker-compose.yml
hcheck "host:cpus-limit"          grep -q 'cpus:' docker-compose.yml
hcheck "host:isolation-env"       grep -q 'DSH_ISOLATION_PLATFORM=docker' docker-compose.yml
hcheck "host:sandboxed-env"       grep -q 'IS_SANDBOXED=1' docker-compose.yml

# No env var in docker-compose.yml relaxes approval or widens the sandbox.
if grep -qiE 'approval.*never|danger-full-access|yolo|auto_approve|autoApprove' docker-compose.yml; then
  hno "host:no-relaxing-env" "found a permission-relaxing token in docker-compose.yml"
else
  hok "host:no-relaxing-env"
fi

# Build controls declared in the Dockerfile
hcheck "host:dockerfile-npm-ci"          grep -q 'npm ci' Dockerfile
hcheck "host:dockerfile-setuid-strip"    grep -q 'perm /6000' Dockerfile
hcheck "host:dockerfile-ignore-scripts"  grep -q 'npm_config_ignore_scripts=true' Dockerfile
hcheck "host:dockerfile-gitconfig"       grep -q 'safe' Dockerfile

# Supply chain: committed lockfiles with full integrity coverage
hcheck "host:lockfile-exists-global-tools" test -f global-tools/package-lock.json
hcheck "host:lockfile-exists-pty-build"    test -f pty-build/package-lock.json
hcheck "host:lockfile-integrity-global-tools" lockfile_integrity global-tools/package-lock.json
hcheck "host:lockfile-integrity-pty-build"    lockfile_integrity pty-build/package-lock.json

echo "host static: $HOST_PASS passed, $HOST_FAIL failed"

if [ "$BUILD" = 1 ]; then
  echo
  echo "=== Phase B: build image ==="
  if docker compose build >/dev/null 2>&1; then
    printf 'PASS: build\n'
  else
    rc=$?
    printf 'FAIL: build (exit %s)\n' "$rc"
    echo "Aborting; in-container checks need a built image." >&2
    exit 1
  fi
else
  echo
  echo "=== Phase B: build skipped (--no-build) ==="
fi

echo
echo "=== Phase C: in-container checks ==="
# Bind-mount the checker read-only into the container and run it under the real
# runtime security context (caps, read-only rootfs, tmpfs noexec). The bind mount
# overlays the read-only rootfs at /s.sh; `sh /s.sh` reads it (no execve of the
# file, so /tmp noexec is irrelevant). --no-deps avoids starting litellm.
INNER_OUT=$(docker compose run --rm --no-deps \
  -v "$PWD/hardening-checks.sh:/s.sh:ro" \
  --entrypoint sh dsh-headless /s.sh 2>/dev/null)
IC_FAIL=$?
printf '%s\n' "$INNER_OUT"

IC_PASS=$(printf '%s\n' "$INNER_OUT" | sed -n 's/.*IN-CONTAINER: \([0-9]*\) passed.*/\1/p')
[ -n "$IC_PASS" ] || IC_PASS=0

TOTAL_PASS=$((HOST_PASS + IC_PASS))
TOTAL_FAIL=$((HOST_FAIL + IC_FAIL))

echo
echo "=== Result: $TOTAL_PASS passed, $TOTAL_FAIL failed ==="
if [ "$TOTAL_FAIL" = 0 ]; then
  echo "ALL INVARIANTS HOLD"
  exit 0
else
  echo "INVARIANT VIOLATIONS DETECTED" >&2
  exit "$TOTAL_FAIL"
fi
