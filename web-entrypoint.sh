#!/bin/sh
# Web entrypoint: run dsh on 127.0.0.1 (its safety requirement) and bridge
# 0.0.0.0:8080 -> 127.0.0.1:8090 via socat so Docker can publish the port.
# Any args after this script's flags are forwarded to dsh.
set -eu

DSH_PORT=8090
PROXY_PORT=8080

# Pre-register /workspace in the workspace registry so it appears in the UI.
# WORKSPACE_NAME is the host folder basename (e.g. inventrip_api), set by run-dsh.
# Use `sh` so a host bind-mount without +x still runs.
sh /usr/local/bin/register-workspace.sh || true

# Start dsh on loopback only (dsh refuses 0.0.0.0 for RCE safety). dsh 0.1.2+
# gates web access behind a one-time token in the launch URL, so its startup
# URL line (which carries the token) must reach the user — rewrite the internal
# port to the published proxy port instead of suppressing the line.
node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js \
  --profile web --host 127.0.0.1 --port "$DSH_PORT" --no-open \
  --trusted-host 127.0.0.1:"$PROXY_PORT" --trusted-host localhost:"$PROXY_PORT" \
  "$@" 2>&1 | sed -u "s#127.0.0.1:${DSH_PORT}#127.0.0.1:${PROXY_PORT}#g" &
DSH_PID=$!

# dsh may rewrite workspace titles from the mount path ("workspace") on boot.
# Re-apply WORKSPACE_NAME a few times after startup so the UI keeps inventrip_api.
(
  i=0
  while [ "$i" -lt 12 ]; do
    sleep 2
    sh /usr/local/bin/register-workspace.sh >/dev/null 2>&1 || true
    i=$((i + 1))
  done
) &

# socat forwards Docker's published port to dsh's loopback socket.
socat TCP-LISTEN:"$PROXY_PORT",fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:"$DSH_PORT" &
SOCAT_PID=$!

# If either process dies, kill the other and exit.
trap 'kill "$DSH_PID" "$SOCAT_PID" 2>/dev/null || true; exit 0' INT TERM
wait "$SOCAT_PID"
kill "$DSH_PID" 2>/dev/null || true
