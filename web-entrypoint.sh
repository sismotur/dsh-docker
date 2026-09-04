#!/bin/sh
# Web entrypoint: run dsh on 127.0.0.1 (its safety requirement) and bridge
# 0.0.0.0:8080 -> 127.0.0.1:8090 via socat so Docker can publish the port.
# Any args after this script's flags are forwarded to dsh.
set -eu

DSH_PORT=8090
PROXY_PORT=8080

# Pre-register /workspace in the workspace registry so it appears in the UI.
/usr/local/bin/register-workspace.sh || true

# Start dsh on loopback only (dsh refuses 0.0.0.0 for RCE safety). Its own
# startup line reports the internal port; suppress it so it cannot mislead.
node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js \
  --profile web --host 127.0.0.1 --port "$DSH_PORT" --no-open \
  --trusted-host 127.0.0.1:"$PROXY_PORT" --trusted-host localhost:"$PROXY_PORT" \
  "$@" 2>&1 | grep -v "dsh web: http" &
DSH_PID=$!

# socat forwards Docker's published port to dsh's loopback socket.
socat TCP-LISTEN:"$PROXY_PORT",fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:"$DSH_PORT" &
SOCAT_PID=$!

# Print the URL the user should actually open (host port, not the internal one).
printf '\ndsh web: http://127.0.0.1:%s  (open this in your browser)\n\n' "$PROXY_PORT"

# If either process dies, kill the other and exit.
trap 'kill "$DSH_PID" "$SOCAT_PID" 2>/dev/null || true; exit 0' INT TERM
wait "$SOCAT_PID"
kill "$DSH_PID" 2>/dev/null || true
