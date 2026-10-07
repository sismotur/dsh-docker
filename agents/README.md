# Agent instruction packs

dsh loads a single file: `$DSH_HOME/AGENTS.md` (baseline every session).
This directory holds **source packs** that `seed-omlx.sh` concatenates into
that file.

## Layout

| Path | Git | Purpose |
| --- | --- | --- |
| `public/*.md` | yes | Safe generic rules (baked into the image) |
| `private.example/*.md` | yes | Placeholders — **not** seeded |
| `private/*.md` | **no** (gitignored) | Confidential/host context; mounted at seed |

Pack filenames are sorted (`10-…`, `20-…`) to control merge order.

## Seed

```bash
./run-dsh.sh seed
```

Merge order:

1. Banner comment
2. All `public/*.md` (sorted)
3. All `private/*.md` if the host directory exists and is mounted

Without `agents/private/`, AGENTS.md is public-only (fine for a public clone).

## Edit workflow

1. Edit packs under `agents/public/` or `agents/private/`.
2. Public pack changes: `docker compose build` then `./run-dsh.sh seed`.
3. Private-only changes: `./run-dsh.sh seed` (bind-mounted; no rebuild).

## Project overlay

A workspace `AGENTS.md` (when a project is mounted at `/workspace`) still
overrides/supplements the global file per dsh.
