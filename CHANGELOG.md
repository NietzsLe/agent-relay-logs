# Changelog

## Unreleased

- Nudge plugin reminds once per session at the first chat request (`board` +
  `start`, including short tests and `/tmp` outputs) — the only net that
  catches sessions too short for tick-based nudges. `node --check` pins the
  plugin syntax in `tests/test.sh`.
- New `scripts/audit_coverage.py`: cross-checks opencode/Claude/Codex session
  stores on the local machine against the target's `.relay/data/` and reports
  real-work harness sessions with no overlapping relay session (exit 1).
  Read-only; heuristic matching without hooks; store paths overridable for
  tests. `README.md` documents usage.

## v4.2.0 — image generation via Codex, one-step block bump

- Agent guidance: tasks needing images (new illustrations, diagrams, assets,
  mockups — or edits/variants from reference images) are delegated by default
  to the `codex` CLI (`codex exec --skip-git-repo-check -C <dir> [-i ref.png]
  "... save as ./<path>.png. Use your image generation tool."`), which has a
  built-in image generation tool. Reference images attach with repeatable `-i`;
  verify the saved file afterwards; never paste secrets into delegated prompts.
  When Codex is unavailable, the agent must say exactly what is missing instead
  of skipping or claiming images are impossible.
- Block versions are now bumped in one step: `python3 scripts/relay_setup.py
  bump-blocks --to vN` syncs the template stamps, `templates/VERSIONS`, and
  `BLOCK_VERSION` in `package/relay`. `AGENTS.md` documents the checklist
  (bump → content assert in `tests/test.sh` → verify → CHANGELOG entry).

## v4.1.0 — browser delegation, versioned blocks, self-healing setup

- Agent guidance: tasks needing a real browser are delegated by default to the
  `claude` CLI (`claude --chrome --model sonnet -p "..."`); no local Chrome
  needed (remote Chrome). Static reads still use `webfetch`. Verify results
  independently; never paste secrets into delegated prompts. When delegation
  is unavailable, the agent must say exactly what is missing instead of
  skipping silently.
- Marker blocks are now version-stamped (`<!-- relay-logs <name> vN -->`;
  `templates/VERSIONS` is the registry). Re-running install upgrades blocks
  wholesale and reports `vOld -> vNew` (`unchanged (already vN)` when
  identical); `doctor` shows installed block versions and flags outdated ones;
  `install.json` records `block_versions`. Legacy blocks without a stamp count
  as unversioned and are upgraded on the next install.
- Self-healing setup: the runtime knows `BLOCK_VERSION` and every `board`
  prints block status (`blocks: vN OK` or names outdated/missing files);
  `relay doctor` reports the same. Installed blocks instruct the agent to
  fetch the installer repo and (re)install when `.relay/` is absent or blocks
  are outdated — a fresh clone becomes compatible inside the session, no
  manual version tracking.

## v4.0.0 — rhythm enforcement, scope tracking, scoreboard, hooks

- New event types: `scope` (working-scope changes with `--why`), `wait`/`run`
  (long commands with eta/actual/exit/late/over).
- `note` gains `--next` (one line) and `--where` (repeatable).
- `relay tick`: one-line rhythm check, exit 2 on violation (silence past
  `RELAY_GAP_MAX`, files outside the logged scope, expired wait windows,
  unread news). Silent when everything is fine.
- `relay board`: open tasks with now/next/scope-clash lines. `sync` prepends
  this block when there are new events.
- `relay run`: executes a command with timing (`--eta 8m -- <cmd>`) or records
  a harness-measured run (`--record`). Two-sided eta tolerance; undeclared
  runs over 120s count as late.
- `relay end`: hard gate (exit 1, event still recorded) + 0–100 score
  (rhythm 50 / scope 20 / close 20 / open 10 / forced −10). `--force` records
  acceptance; re-closing a gate-failed task with `--force` marks it forced.
- `relay stats` (+ `doctor`): tasks, average score, median notes/task, max
  silence, gate fails, per-agent scores.
- `relay --key`: harness session → relay session mapping (`keys/`), so hooks
  never need a session id.
- `install.sh --hooks`: OpenCode plugin (tool timing, `RELAY_KEY`, 8-minute
  nudge) + merged Claude Code hooks (`UserPromptSubmit`, `PostToolUse`,
  Stop `guard`). Uninstall removes exactly what install added.
- Env knobs: `RELAY_GAP_MAX` (600s), `RELAY_NUDGE` (480s), `RELAY_MIN_DECLARE`
  (120s), `RELAY_STALE_HOURS` (12h).
- Docs state triggers only — never exemptions ("no need to log when…").

## v3.1.0 — quality nudges, `open` command, stale/thin checks in doctor

## v3.0.0 — one file per day, per-session cursors, auto-migration

## v2.0.0 — detailed start/note/end events, `show`, safer parsing

## v1.0.0 — installer, runtime, docs, tests
