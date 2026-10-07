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


# ---------------------------------------------------------------------------
# Agent packs + secret-leak gates (public/private split)
# ---------------------------------------------------------------------------

# Public packs present and numbered
hcheck "agents:public-dir"              test -d agents/public
hcheck "agents:public-core"             test -f agents/public/10-core.md
hcheck "agents:public-has-md"           sh -c 'ls agents/public/*.md >/dev/null 2>&1'
hcheck "agents:private-example-dir"     test -d agents/private.example
hcheck "agents:readme"                  test -f agents/README.md

# Monolithic file must be gone
hcheck_fail "agents:no-monolithic-global" test -f agents-global.md

# Dockerfile bakes public + examples only — never private/
hcheck "agents:dockerfile-copy-public"  grep -q 'agents/public' Dockerfile
hcheck "agents:dockerfile-copy-example" grep -q 'agents/private.example' Dockerfile
if grep -E 'COPY[[:space:]]+agents/private(/|[[:space:]])' Dockerfile >/dev/null 2>&1; then
  hno "agents:dockerfile-no-private-copy" "Dockerfile copies agents/private"
else
  hok "agents:dockerfile-no-private-copy"
fi
hcheck_fail "agents:dockerfile-no-agents-global" grep -q 'agents-global.md' Dockerfile

# seed concatenates packs into AGENTS.md
hcheck "agents:seed-public-dir-ref"     grep -q 'agents/public' seed-omlx.sh
hcheck "agents:seed-private-dir-ref"    grep -q 'agents/private' seed-omlx.sh
hcheck "agents:seed-writes-AGENTS"      grep -q 'AGENTS.md' seed-omlx.sh
hcheck_fail "agents:seed-no-cp-monolith" grep -q 'cp -f /opt/dsh-patches/agents-global.md' seed-omlx.sh

# run-dsh seed mounts private when present
hcheck "agents:run-dsh-seed-mount-private" grep -q 'agents/private:/opt/dsh-patches/agents/private' run-dsh.sh

# gitignore covers confidential paths
hcheck "agents:gitignore-private"       grep -q 'agents/private/' .gitignore
hcheck "agents:gitignore-projects-local" grep -q 'projects.local.sh' .gitignore

# If git is available: private must not be tracked; ignore must apply
if command -v git >/dev/null 2>&1 && [ -d .git ]; then
  if git ls-files --error-unmatch agents/private >/dev/null 2>&1; then
    hno "agents:git-private-untracked" "agents/private is tracked by git"
  else
    # also ensure no files under private are tracked
    if git ls-files 'agents/private/*' 2>/dev/null | grep -q .; then
      hno "agents:git-private-untracked" "files under agents/private are tracked"
    else
      hok "agents:git-private-untracked"
    fi
  fi
  if git check-ignore -q agents/private/20-inventrip-gcp.md 2>/dev/null \
     || git check-ignore -q agents/private 2>/dev/null; then
    hok "agents:git-ignores-private"
  else
    # private dir may be empty in CI; check gitignore pattern instead
    if grep -q '^agents/private/' .gitignore; then
      hok "agents:git-ignores-private"
    else
      hno "agents:git-ignores-private" "not ignored"
    fi
  fi
  if git ls-files --error-unmatch projects.local.sh >/dev/null 2>&1; then
    hno "agents:git-projects-local-untracked" "projects.local.sh is tracked"
  else
    hok "agents:git-projects-local-untracked"
  fi
  if git ls-files --error-unmatch .env >/dev/null 2>&1; then
    hno "agents:git-env-untracked" ".env is tracked"
  else
    hok "agents:git-env-untracked"
  fi
else
  hok "agents:git-checks-skipped"
fi

# Secret-leak scan over committed / would-be-public paths only
# (exclude agents/private, .env, projects.local.sh, lockfiles, .git)
secret_scan() {
  # Returns 0 if CLEAN (no matches), 1 if leak found (prints matches)
  _pat='voltaic-azimuth-105813|fsanti@sismotur\\.com|inventrip-postgres-f24a92b2|inventrip-gke-production|34\\.88\\.69\\.68|10\\.166\\.0\\.2|wordpress-website-sismotur-vm|sismotur-tools'
  # Use git ls-files when possible so we only scan tracked files
  if command -v git >/dev/null 2>&1 && [ -d .git ]; then
    # Exclude this suite and lockfiles — patterns are listed here as detectors.
    _hits=$(git grep -nI -E "$_pat" -- . \
      ':(exclude)*.lock' ':(exclude)*package-lock.json' \
      ':(exclude)test-hardening.sh' ':(exclude)hardening-checks.sh' \
      2>/dev/null || true)
  else
    _hits=$(grep -RIn -E "$_pat" \
      --exclude-dir=agents/private --exclude-dir=.git --exclude-dir=node_modules \
      --exclude-dir=runs --exclude=.env --exclude=projects.local.sh \
      --exclude=test-hardening.sh --exclude=hardening-checks.sh \
      . 2>/dev/null || true)
  fi
  if [ -n "$_hits" ]; then
    printf '%s\n' "$_hits"
    return 1
  fi
  return 0
}
if _leak_out=$(secret_scan); then
  hok "secrets:no-confidential-in-tracked"
else
  hno "secrets:no-confidential-in-tracked" "confidential markers in tracked files"
  printf '%s\n' "$_leak_out" | sed 's/^/  /' | head -20
fi

# private.example must not contain real inventrip production IDs
if grep -RIn -E 'voltaic-azimuth-105813|inventrip-postgres-f24a92b2|34\\.88\\.69\\.68|fsanti@sismotur' agents/private.example >/dev/null 2>&1; then
  hno "secrets:examples-are-placeholders" "private.example contains real identifiers"
else
  hok "secrets:examples-are-placeholders"
fi

# Public packs must not contain those either
if grep -RIn -E 'voltaic-azimuth-105813|inventrip-postgres-f24a92b2|34\\.88\\.69\\.68|fsanti@sismotur|inventrip_ios2|inventrip_android2' agents/public >/dev/null 2>&1; then
  hno "secrets:public-packs-clean" "public packs contain confidential markers"
else
  hok "secrets:public-packs-clean"
fi


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
