# Changelog

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
