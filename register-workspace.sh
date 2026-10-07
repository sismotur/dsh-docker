#!/bin/sh
# Pre-register /workspace in the dsh workspace registry so it appears in the
# web UI's "Choose workspace" screen automatically. Runs before dsh boots.
# Titles the entry after WORKSPACE_NAME (the real host folder's basename, set
# by run-dsh.sh's mount_project), falling back to "workspace" when unset.
# Since every project is bind-mounted at the same /workspace path, an existing
# entry is updated in place (not skipped) so the title always tracks whichever
# project is currently mounted, instead of getting stuck on the first one.
set -eu
: "${DSH_HOME:=/data}"
: "${WORKSPACE_NAME:=workspace}"
REG="$DSH_HOME/storages/workspace.json"

# If /workspace doesn't exist (no mount), nothing to register.
[ -d /workspace ] || exit 0

# If the registry doesn't exist yet, dsh will create it on boot; skip.
[ -f "$REG" ] || exit 0

NOW=$(node -e 'console.log(new Date().toISOString())')

node -e '
const fs = require("fs");
const crypto = require("crypto");
const regPath = process.argv[1];
const name = process.argv[2];
const now = process.argv[3];
const reg = JSON.parse(fs.readFileSync(regPath, "utf8"));
reg.global.workspaceIds = reg.global.workspaceIds || [];
reg.tables = reg.tables || {};
reg.tables.workspaces = reg.tables.workspaces || {};

const existingId = Object.keys(reg.tables.workspaces).find(
  (id) => reg.tables.workspaces[id].path === "/workspace"
);

if (existingId) {
  reg.tables.workspaces[existingId].title = name;
  reg.tables.workspaces[existingId].updatedAt = now;
} else {
  const id = crypto.randomUUID();
  reg.global.workspaceIds.push(id);
  reg.tables.workspaces[id] = {
    path: "/workspace",
    title: name,
    sessionIds: [],
    createdAt: now,
    updatedAt: now
  };
}

fs.writeFileSync(regPath, JSON.stringify(reg, null, 2) + "\n");
' "$REG" "$WORKSPACE_NAME" "$NOW"

echo "registered /workspace as \"$WORKSPACE_NAME\" in $REG"
