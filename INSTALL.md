# Install agent-relay-logs into a project

Audience: an agent or human with shell access to a target repository.

The installer is intentionally narrow. It touches only `.relay/`, `.gitignore`,
`AGENTS.md`, and `CLAUDE.md`. It never rewrites a whole file; it inserts or
replaces one marker block:

```text
<!-- BEGIN relay-logs -->
...
<!-- END relay-logs -->
```

## What will change in the target

| Path | Change |
|---|---|
| `.relay/relay` | CLI copied from `package/relay` (schema v2) |
| `.relay/README.md`, `.relay/SNIPPET.md` | Runtime docs |
| `.relay/install.json` | Install manifest (local, git-ignored) |
| `.gitignore` | Adds `.relay/` if neither `.relay` nor `.relay/` is present |
| `AGENTS.md` | Marker block added or updated |
| `CLAUDE.md` | Marker block added or updated |

If `AGENTS.md` or `CLAUDE.md` does not exist, the installer creates a minimal
file. Use `--no-create` to skip missing files instead.

## Preconditions

1. Python 3.8+ is available: `python3 --version`.
2. The target path exists and is writable.
3. Read the target's existing `AGENTS.md` and `CLAUDE.md` so you know what you
   are adding to.
4. Check whether the target already has `.relay/`:
   ```bash
   ls -la /path/to/project/.relay 2>/dev/null || echo "no .relay"
   ```
   If it exists and contains `data/`, do not delete it. `--force` updates only
   the runtime files, never `data/`.
5. Check git state so the diff is easy to review:
   ```bash
   git -C /path/to/project status --short
   ```

## Step 1 — dry run

From the `agent-relay-logs` repository:

```bash
./scripts/install.sh --target /path/to/project --dry-run
```

Read the output. It lists every package file, the `.gitignore` decision, and the
`AGENTS.md` / `CLAUDE.md` action. No files are written in dry-run mode.

## Step 2 — install

```bash
./scripts/install.sh --target /path/to/project --backup
```

Useful flags:

| Flag | Effect |
|---|---|
| `--backup` | Writes `AGENTS.md.relay-backup-<timestamp>` / `CLAUDE.md.relay-backup-<timestamp>` before editing |
| `--force` | Updates existing `.relay/relay`, `README.md`, `SNIPPET.md` (never `data/`) — required to upgrade an older runtime |
| `--skip-agents` | Do not touch `AGENTS.md` |
| `--skip-claude` | Do not touch `CLAUDE.md` |
| `--no-create` | Do not create a missing `AGENTS.md` / `CLAUDE.md` |
| `--no-gitignore` | Do not modify `.gitignore` |

Installation is idempotent: running it again replaces the block instead of
adding a second one.

**Upgrading an existing installation:** if the target already has `.relay/`, the
runtime files are kept unless `--force` is given. The install output says which
version is installed and which one the package provides, e.g.
`relay: kept existing (v1.0.0; use --force to update to v2.0.0)`. Upgrade with:

```bash
./scripts/install.sh --target /path/to/project --force --backup
```

`.relay/data` (the existing log) is never touched by an upgrade.

## Step 3 — verify

```bash
TARGET=/path/to/project

# Structure and marker check
"$TARGET/.relay/relay" doctor

# Exercise the CLI end to end (start → note → end → show)
SID="verify-$(date +%s)"
"$TARGET/.relay/relay" --agent verify --session "$SID" start "verify install" \
  --goal "check the runtime works" --plan "start, note, end" --scope .relay
"$TARGET/.relay/relay" --agent verify --session "$SID" note --kind progress \
  --text "runtime responds" --detail "version: $("$TARGET/.relay/relay" --version)"
"$TARGET/.relay/relay" --agent verify --session "$SID" end --status done \
  --summary "install verified" --done "start/note/end cycle" \
  --verify "relay doctor + show" --impact "nothing"

# Read one task back in full
"$TARGET/.relay/relay" --session "$SID" show

# Marker counts: each must be exactly 1
grep -cF '<!-- BEGIN relay-logs -->' "$TARGET/AGENTS.md"
grep -cF '<!-- BEGIN relay-logs -->' "$TARGET/CLAUDE.md"

# Git ignore check
grep -nF '.relay/' "$TARGET/.gitignore"
```

Expected:

- `relay doctor` reports `relay 2.0.0 (schema 2)` and `result: OK`.
- `start` prints `task=…`; `note` prints `note=… task=…`; `end` prints
  `ended=… status=done duration=… notes=1`.
- `show` prints the goal, the plan, the note and the verification.
- Each `grep -c` prints `1`.
- `.gitignore` contains `.relay/`.

The verification events live in `.relay/data/verify-*`; they are local and
git-ignored. You may leave them or delete only those specific session files.

## Step 4 — review and commit

```bash
git -C "$TARGET" status --short
git -C "$TARGET" diff -- AGENTS.md CLAUDE.md .gitignore
```

Commit only the tracked changes, and only if the user asked you to commit:

```bash
git -C "$TARGET" add AGENTS.md CLAUDE.md .gitignore
git -C "$TARGET" commit -m "chore: add agent-relay-logs work log"
```

Never `git add .relay/` and never commit `.relay/data`.

## Step 5 — report

Use a short report like:

```text
Installed agent-relay-logs into /path/to/project.

Changed:
- .relay/relay, .relay/README.md, .relay/SNIPPET.md, .relay/install.json (git-ignored)
- .gitignore: added .relay/
- AGENTS.md: added relay-logs block
- CLAUDE.md: added relay-logs block

Verification:
- relay doctor: OK
- start/sync/end: passed
- marker count: 1 in each file

Uninstall:
- ./scripts/uninstall.sh --target /path/to/project
- default keeps logs as .relay.removed-<timestamp>/
```

## Manual fallback (if the script cannot run)

1. Copy the runtime:
   ```bash
   mkdir -p "$TARGET/.relay"
   cp package/relay package/README.md package/SNIPPET.md "$TARGET/.relay/"
   chmod +x "$TARGET/.relay/relay"
   ```
2. Add `.relay/` to the target's `.gitignore` if it is not already ignored.
3. Append `templates/agents-block.md` to `AGENTS.md`.
4. Append `templates/claude-block.md` to `CLAUDE.md`.
5. Run the verification in Step 3.

The manual path does not write `.relay/install.json`, so uninstall falls back to
removing the exact `.relay/` line and moving `.relay/` aside.

## Troubleshooting

- **`unbalanced relay markers`** — the target file contains a BEGIN without a
  matching END (or vice versa). Stop, inspect the file, and fix it manually. The
  installer refuses to guess.
- **`.relay/relay` exists but is different** — rerun with `--force` to update the
  runtime. `data/` is preserved.
- **`python3: command not found`** — install Python 3.8+ or use the manual
  fallback with another Python 3 interpreter.
- **`AGENTS.md` / `CLAUDE.md` missing** — they are created by default; use
  `--no-create` to require them to exist.
- **CRLF files** — the installer preserves the file's existing CRLF line endings.
- **Do not run the installer on a production host just to test it** — use a
  throwaway checkout or `--dry-run`.

## Checklist

- [ ] Dry run reviewed.
- [ ] Install exited 0.
- [ ] `relay doctor` says `OK`.
- [ ] `start` / `sync` / `end` worked.
- [ ] Exactly one marker block in each of `AGENTS.md` and `CLAUDE.md`.
- [ ] `.relay/` is ignored by git.
- [ ] Existing project content is intact.
- [ ] User knows how to uninstall (`UNINSTALL.md`).
