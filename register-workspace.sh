#!/bin/sh
# Pre-register /workspace in the dsh workspace registry so it appears in the
# web UI's "Choose workspace" screen automatically. Runs before dsh boots.
# Safe: no-op if /workspace is already registered or doesn't exist.
set -eu
: "${DSH_HOME:=/data}"
REG="$DSH_HOME/storages/workspace.json"

# If /workspace doesn't exist (no mount), nothing to register.
[ -d /workspace ] || exit 0

# If the registry doesn't exist yet, dsh will create it on boot; skip.
[ -f "$REG" ] || exit 0

# If /workspace is already registered, skip.
if grep -q '"/workspace"' "$REG" 2>/dev/null; then
  exit 0
fi

# Generate a workspace record and merge it into the registry.
ID=$(node -e 'console.log(crypto.randomUUID())')
NOW=$(node -e 'console.log(new Date().toISOString())')

node -e '
const fs = require("fs");
const reg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const id = process.argv[2];
const now = process.argv[3];
reg.global.workspaceIds = reg.global.workspaceIds || [];
reg.global.workspaceIds.push(id);
reg.tables = reg.tables || {};
reg.tables.workspaces = reg.tables.workspaces || {};
reg.tables.workspaces[id] = {
  path: "/workspace",
  title: "workspace",
  sessionIds: [],
  createdAt: now,
  updatedAt: now
};
fs.writeFileSync(process.argv[1], JSON.stringify(reg, null, 2) + "\n");
' "$REG" "$ID" "$NOW"

echo "pre-registered /workspace in $REG"
