# Uninstall agent-relay-logs from a project

Audience: an agent or human with shell access to a target repository.

Uninstall is the mirror image of install: remove the marker blocks, remove the
`.relay/` line from `.gitignore`, and take the runtime away. Logs are preserved
by default.

## What will change in the target

| Path | Default | `--purge` | `--keep-relay` |
|---|---|---|---|
| `AGENTS.md`, `CLAUDE.md` | Marker block removed | same | same |
| `.gitignore` | `.relay/` line removed | same | same |
| `.relay/` | moved to `.relay.removed-<timestamp>/` | deleted | kept in place |
| `AGENTS.md` / `CLAUDE.md` created by the installer | deleted if still empty | same | same |

Nothing else in the target is modified. Files that the installer created (a
missing `AGENTS.md` / `CLAUDE.md`) are removed only when they contain nothing
but the installer's own header and block.

## Preconditions

1. Check whether other agents are mid-task. If `.relay/` exists:
   ```bash
   /path/to/project/.relay/relay sync --all
   ```
   Tell the user about open work before removing the log.
2. Remember that the default keeps the logs in `.relay.removed-<timestamp>/`.
   If the user wants the logs gone, use `--purge`.

## Step 1 — dry run

```bash
./scripts/uninstall.sh --target /path/to/project --dry-run
```

The output lists every action. Nothing is written in dry-run mode.

## Step 2 — run

```bash
# Default: remove instructions, keep logs as .relay.removed-<timestamp>/
./scripts/uninstall.sh --target /path/to/project

# Delete logs as well
./scripts/uninstall.sh --target /path/to/project --purge

# Remove only the instructions; keep .relay/ working
./scripts/uninstall.sh --target /path/to/project --keep-relay
```

Useful flags:

| Flag | Effect |
|---|---|
| `--backup` | Back up `AGENTS.md` / `CLAUDE.md` before editing |
| `--skip-agents` | Do not touch `AGENTS.md` |
| `--skip-claude` | Do not touch `CLAUDE.md` |
| `--no-gitignore` | Do not modify `.gitignore` |
| `--purge` | Delete `.relay/` (including logs) instead of moving it aside |
| `--keep-relay` | Keep `.relay/` in place |

Uninstall is idempotent: running it again on an already-clean target is a no-op.

## Step 3 — verify

```bash
TARGET=/path/to/project

# No markers left
grep -cF '<!-- BEGIN relay-logs -->' "$TARGET/AGENTS.md" 2>/dev/null || echo "0 (clean)"
grep -cF '<!-- BEGIN relay-logs -->' "$TARGET/CLAUDE.md" 2>/dev/null || echo "0 (clean)"

# No .relay/ line left
grep -nF '.relay/' "$TARGET/.gitignore" 2>/dev/null || echo "no .relay/ line (clean)"

# Runtime gone or moved aside
ls -d "$TARGET"/.relay.removed-* 2>/dev/null || echo "no .relay.removed-* directory"
ls -d "$TARGET/.relay" 2>/dev/null && echo "still present (expected only with --keep-relay)"
```

Expected: `0 (clean)` for both marker counts, no `.relay/` line, and a
`.relay.removed-<timestamp>/` directory unless `--purge` or `--keep-relay` was
used.

## Step 4 — review and commit

```bash
git -C "$TARGET" status --short
git -C "$TARGET" diff -- AGENTS.md CLAUDE.md .gitignore
```

Commit only the tracked changes, and only if the user asked:

```bash
git -C "$TARGET" add AGENTS.md CLAUDE.md .gitignore
git -C "$TARGET" commit -m "chore: remove agent-relay-logs work log"
```

## Step 5 — restore (optional)

The default keeps everything. To bring the system back:

```bash
mv "$TARGET"/.relay.removed-* "$TARGET/.relay"
./scripts/install.sh --target "$TARGET"
```

`install` re-adds the marker blocks and the `.relay/` gitignore line, and keeps
the existing log data.

## Manual fallback (if the script cannot run)

1. Delete the block in `AGENTS.md` and `CLAUDE.md` — everything between
   `<!-- BEGIN relay-logs -->` and `<!-- END relay-logs -->`, including the
   markers.
2. Remove the `.relay/` line from `.gitignore`.
3. Remove `.relay/` (or move it to `.relay.removed-<timestamp>/`).

Leave every other line of those files exactly as it was.

## Checklist

- [ ] Open work reported to the user before removing the log.
- [ ] Dry run reviewed; the right mode chosen (default / `--purge` / `--keep-relay`).
- [ ] Uninstall exited 0.
- [ ] No `BEGIN relay-logs` marker left in `AGENTS.md` or `CLAUDE.md`.
- [ ] No `.relay/` line left in `.gitignore`.
- [ ] Logs preserved (`.relay.removed-*`) or deliberately purged.
- [ ] Existing project content intact (`git diff` reviewed).
