#!/bin/sh
# Inject the prebuilt node-pty native binary into the installed
# dsh-better-sidebar plugin so the terminal tab works.
#
# node-pty (a dependency of dsh-better-sidebar) ships prebuilds for darwin and
# win32 but NOT for linux. The runtime image deliberately has no build tools
# (python3/make/g++) to stay minimal and hardened, so node-pty's native addon
# cannot be compiled at plugin-install time. Instead, pty.node is pre-compiled
# in the Docker builder stage and baked into the runtime image at
# /opt/prebuilds/node-pty/pty.node. This script copies it into the plugin's
# node-pty build/Release/ directory, which is the first path the loader checks
# (lib/utils.js loadNativeModule).
#
# Run AFTER installing the plugin:
#   ./run-dsh.sh plugin web add dsh-better-sidebar
#   ./run-dsh.sh enable-terminal
#
# Idempotent: safe to re-run. Does nothing if the binary is already in place.
set -eu

PREBUILD=/opt/prebuilds/node-pty/pty.node
NP_DIR=/data/profiles/web/node_modules/node-pty
DEST="$NP_DIR/build/Release/pty.node"

if [ ! -f "$PREBUILD" ]; then
	echo "enable-terminal: prebuilt pty.node not found at $PREBUILD" >&2
	echo "  rebuild the image: docker compose build" >&2
	exit 1
fi

if [ ! -d "$NP_DIR" ]; then
	echo "enable-terminal: node-pty not installed at $NP_DIR" >&2
	echo "  install the plugin first: ./run-dsh.sh plugin web add dsh-better-sidebar" >&2
	exit 1
fi

# Skip if already injected (cmp returns 0 for identical files).
if [ -f "$DEST" ] && cmp -s "$PREBUILD" "$DEST"; then
	echo "enable-terminal: pty.node already in place, nothing to do."
	exit 0
fi

mkdir -p "$(dirname "$DEST")"
cp "$PREBUILD" "$DEST"
echo "enable-terminal: injected pty.node into $DEST"
echo "  hard-refresh the browser (Cmd/Ctrl+Shift+R) to activate the terminal tab."
