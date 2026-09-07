#!/usr/bin/env node
// List or resolve dsh sessions from the session-projection cache.
//
// Run inside the hardened container, bind-mounted read-only, e.g.:
//   docker compose run --rm --no-deps \
//     -v "$PWD/list-sessions.js:/s.js:ro" --entrypoint node dsh-headless /s.js list
//   ... /s.js latest
//
// Reads $DSH_HOME/storages/session_projcache.json. Each session is keyed as
// "session-<uuid>"; dsh --resume takes the BARE uuid, so the prefix is stripped
// before printing. Recency is rows.sessionListMetadata.val.lastPromptAt
// (epoch ms), falling back to identity.createdAt.
//
// No dependencies — uses only the fs module shipped with Node.
const fs = require("fs");

const mode = process.argv[2] || "list";
const home = process.env.DSH_HOME || "/data";
const path = home + "/storages/session_projcache.json";

function loadSessions() {
  if (!fs.existsSync(path)) return [];
  let j;
  try {
    j = JSON.parse(fs.readFileSync(path, "utf8"));
  } catch (e) {
    console.error("list-sessions: cannot parse " + path + ": " + e.message);
    process.exit(1);
  }
  const table = (j.tables && j.tables.sessions) || {};
  const rows = [];
  for (const [key, rec] of Object.entries(table)) {
    const id = key.replace(/^session-/, "");
    const rowsObj = rec.rows || {};
    const meta = rowsObj.sessionListMetadata && rowsObj.sessionListMetadata.val;
    const title = (rowsObj.title && rowsObj.title.val) || "(untitled)";
    const stats = rowsObj.sessionStats && rowsObj.sessionStats.val;
    const turns = (stats && stats.turns) || 0;
    const ts =
      (meta && meta.lastPromptAt) ||
      (rec.identity && rec.identity.createdAt) ||
      0;
    rows.push({ id: id, title: title, turns: turns, ts: ts });
  }
  rows.sort(function (a, b) {
    return b.ts - a.ts;
  });
  return rows;
}

const rows = loadSessions();

if (mode === "latest") {
  if (rows.length) process.stdout.write(rows[0].id);
  process.exit(0);
}

if (!rows.length) {
  console.log("No sessions found.");
  process.exit(0);
}

for (const r of rows) {
  const when = r.ts
    ? new Date(r.ts).toISOString().replace("T", " ").slice(0, 16)
    : "unknown          ";
  const title = String(r.title).slice(0, 50);
  console.log(r.id + "  turns=" + r.turns + "  " + when + "  " + title);
}
