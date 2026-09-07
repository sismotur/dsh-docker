#!/bin/sh
# In-container hardening invariant checks. Runs INSIDE the hardened dsh
# container (invoked by test-hardening.sh) and asserts the in-container half of
# the Security invariants documented in README.md.
#
# It must run under the real runtime security context (cap_drop ALL,
# no-new-privileges, read-only rootfs, /tmp noexec tmpfs), which is why
# test-hardening.sh launches it via `docker compose run` rather than on the host.
#
# Emits one line per check:
#   PASS: <name>
#   FAIL: <name> (<detail>)
# Exits with the number of failed checks (0 = all pass).
#
# Do NOT run this directly on the host — it is meaningless outside the container.

pass=0
fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL: %s (%s)\n' "$1" "$2"; fail=$((fail + 1)); }

# check NAME CMD...      — PASS if CMD exits 0
check()      { n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else no "$n" "exit $?"; fi; }
# check_fail NAME CMD...  — PASS if CMD exits non-zero (for "should fail" cases)
check_fail() { n="$1"; shift; if "$@" >/dev/null 2>&1; then no "$n" "expected failure, got success"; else ok "$n"; fi; }
# check_eq NAME ACTUAL EXPECTED
check_eq()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got '$2' want '$3'"; fi; }

# ---------------------------------------------------------------------------
# Runtime context (docker-compose.yml security_opt / cap_drop / read_only)
# ---------------------------------------------------------------------------

check_eq "rt:uid-1000"          "$(id -u)" 1000
check_eq "rt:cap-eff-zero"      "$(awk '/^CapEff:/{print $2}' /proc/self/status)" 0000000000000000
check_eq "rt:cap-bnd-zero"      "$(awk '/^CapBnd:/{print $2}' /proc/self/status)" 0000000000000000
check_eq "rt:no-new-privs"      "$(awk '/^NoNewPrivs:/{print $2}' /proc/self/status)" 1
# Writes to the read-only rootfs must fail.
check_fail "rt:rootfs-readonly"   sh -c 'echo x > /_t 2>/dev/null'
check_fail "rt:etc-not-writable"  sh -c 'echo x > /etc/_t 2>/dev/null'
check_fail "rt:usr-not-writable"  sh -c 'echo x > /usr/_t 2>/dev/null'
# The three writable paths must still be writable.
check      "rt:tmp-writable"        sh -c 'echo x >/tmp/_t && rm /tmp/_t'
check      "rt:data-writable"       sh -c 'echo x >/data/_t && rm /data/_t'
check      "rt:workspace-writable"  sh -c 'echo x >/workspace/_t && rm /workspace/_t'
# /tmp is noexec: a binary/script cannot be execve'd from the tmpfs.
check_fail "rt:tmp-noexec" sh -c 'printf "#!/bin/sh\nexit 0\n" >/tmp/_x.sh && chmod +x /tmp/_x.sh && /tmp/_x.sh'

# ---------------------------------------------------------------------------
# Build context (Dockerfile runtime image)
# ---------------------------------------------------------------------------

# No setuid/setgid binaries anywhere on the rootfs.
check_fail "build:no-setuid"   sh -c 'find / -xdev -perm /6000 -type f 2>/dev/null | grep -q .'
# Build tools exist only in the builder stage; the runtime ships none.
check_fail "build:no-python3"  command -v python3
check_fail "build:no-make"     command -v make
check_fail "build:no-gcc"      command -v g++
# System gitconfig baked with safe.directory = /workspace.
check      "build:gitconfig-safe" sh -c 'grep -q "safe" /etc/gitconfig && grep -q "/workspace" /etc/gitconfig'
# npm/pnpm lifecycle scripts blocked by default (rogue-plugin supply-chain gate).
check_eq   "build:ignore-scripts" "$(printenv npm_config_ignore_scripts)" true
# node-pty prebuild baked into the read-only runtime.
check      "build:node-pty-prebuild" test -f /opt/prebuilds/node-pty/pty.node

# ---------------------------------------------------------------------------
# Permission / supply-chain (in-container static mechanism checks)
# ---------------------------------------------------------------------------

# dsh-subprocess credential scrub: the SENSITIVE_ENV_PATTERN must be present
# and contain all four sensitive keywords (fail-closed scrub on every spawn).
SUBP=$(find /usr/local/lib/node_modules -path '*dsh-subprocess/lib/index.js' 2>/dev/null | head -1)
if [ -n "$SUBP" ]; then
  check "perm:env-scrub-pattern" sh -c "
    grep -q SENSITIVE_ENV_PATTERN '$SUBP' &&
    grep -q KEY '$SUBP' && grep -q PASSWORD '$SUBP' &&
    grep -q SECRET '$SUBP' && grep -q TOKEN '$SUBP'"
else
  no "perm:env-scrub-pattern" "dsh-subprocess/lib/index.js not found"
fi

# dsh default permission preset is workspace-write (sandboxed + ask), the
# restrictive end; danger-full-access is the opt-in permissive preset.
PP=$(find /usr/local/lib/node_modules -path '*dsh-permission-presets/lib/index.js' 2>/dev/null | head -1)
if [ -n "$PP" ]; then
  check "perm:default-preset-workspace-write" grep -q 'workspace-write' "$PP"
else
  no "perm:default-preset-workspace-write" "dsh-permission-presets/lib/index.js not found"
fi

printf '\nIN-CONTAINER: %d passed, %d failed\n' "$pass" "$fail"
exit "$fail"
