# AGENTS.md — agent-relay-logs

This repository is the canonical source of **agent-relay-logs**: a small,
local-only work log that lets multiple coding agents share what they are doing
in one repository.

It is an installer plus a single-file Python CLI, not an application.

## Read this first

1. `README.md` — what the system is and how it works.
2. `INSTALL.md` — exact install runbook for a target project.
3. `UNINSTALL.md` — exact removal runbook.
4. `package/README.md` — runtime documentation copied into targets.
5. `tests/test.sh` — executable acceptance tests.

## Mission

When a user gives you this repository and a target project, install the system
into that target **without destroying existing content**, verify it, and report
exactly what changed.

## The log contract (applies to any change of the runtime)

- Every event type must carry the detail a reader needs:
  `start` = goal/plan/accept/scope/tags · `note` = kind/text/next/detail/where/refs ·
  `scope` = add/why · `wait/run` = cmd/eta/actual/exit/late/over ·
  `end` = summary/done/problems/verify/metrics/changes/commits/next/lessons/impact/gate/score.
  A log of "task X started" is worth nothing to the next session.
- **One file per day**: `data/YYYY-MM-DD.jsonl` holds every session's events of
  that UTC day; cursors live in `cursors/<session>.json`, harness key mappings
  in `keys/<key>.json`. Appends must be atomic (`O_APPEND` + a single `write()`),
  so concurrent sessions never interleave a line.
- **Rhythm is mechanical**: GAP_MAX/NUDGE/MIN_DECLARE envs, `tick` (exit 2 on
  violation), scope drift via `git status`, `run` measures long commands with
  two-sided tolerance, `end` gates (exit 1, event still recorded) and scores
  (rhythm 50 / scope 20 / close 20 / open 10 / forced −10, floored at 0).
  Never write guidance that exempts logging ("no need to log when…") — the
  tool detects exemptions, the docs only state triggers.
- One line must always be valid JSON. Oversized events are trimmed and flagged
  (`"trimmed": true`) — never cut mid-object.
- Schema v1/v2/v3 events must stay readable; new fields are optional and additive.
  Old per-session files are migrated into the day file, never deleted.
- Hooks (`scripts/hooks/`, installed with `--hooks`) must never block the main
  work: append-only, best-effort, no exceptions, uninstall removes exactly what
  install added.
- The agent name is inherited from the session's `join` event, so later commands
  do not have to repeat `--agent`.
- List options are split on commas that are not inside brackets or quotes
  (`--changes "repo (new, commit abc)"` must survive).
- Any runtime change needs a matching test in `tests/test.sh`.
- When you use the relay yourself (in any project), log with the same detail —
  a half-empty log teaches the next session the wrong habit.

## Hard rules

- Touch only these paths in the target: `.relay/`, `.gitignore`, `AGENTS.md`,
  `CLAUDE.md`.
- Never overwrite a target file wholesale. The installer inserts or replaces a
  marker block: `<!-- BEGIN relay-logs -->` … `<!-- END relay-logs -->`.
- Never duplicate a block. Installation must be idempotent.
- Never move or delete `.relay/data` unless the user explicitly asks. Uninstall
  moves `.relay/` to `.relay.removed-<timestamp>` by default.
- `.relay/` is local-only and git-ignored. Never commit it.
- Do not log secrets, tokens, PII, or customer data in relay events.
- Do not add third-party dependencies. Python 3 standard library and POSIX
  shell only.
- Run `./tests/test.sh` before committing changes to this repository.
- Keep this repository's docs and runtime docs in English. A target project's
  docs may be in any language; the marker block content is the same English
  block by design.
- If markers are unbalanced, stop and ask. Do not guess where the block ends.

## Install into a target

```bash
./scripts/install.sh --target /path/to/project --dry-run
./scripts/install.sh --target /path/to/project --backup
```

To **upgrade an existing installation** (older runtime in `.relay/relay`), add
`--force`: the runtime files are replaced, `.relay/data` is never touched.

Then follow the verification steps in `INSTALL.md`. Commit only the target's
`AGENTS.md`, `CLAUDE.md`, and `.gitignore` changes. Do not commit `.relay/`.

## Uninstall

```bash
./scripts/uninstall.sh --target /path/to/project --dry-run
./scripts/uninstall.sh --target /path/to/project
```

Default behavior: remove marker blocks, remove the `.relay/` line from
`.gitignore`, and move `.relay/` to `.relay.removed-<timestamp>`. Use `--purge`
to delete logs or `--keep-relay` to remove only the instructions.

## Verification

```bash
./tests/test.sh
python3 -m py_compile scripts/relay_setup.py package/relay
```

<!-- BEGIN relay-logs -->
## agent-relay-logs — system declaration

This section belongs to the **agent-relay-logs** system. If the system is no
longer used, delete everything between this marker and
`<!-- END relay-logs -->`.

- Source of truth for this repository: `README.md`, `INSTALL.md`,
  `UNINSTALL.md`.
- The runtime copied into targets lives in `package/` and is documented in
  `package/README.md`.
- Marker contract: `<!-- BEGIN relay-logs -->` / `<!-- END relay-logs -->`.
  The same markers are inserted into a target's `AGENTS.md` and `CLAUDE.md`.
- The CLI is intentionally small: `start`, `note`, `scope`, `wait`/`run`, `end`,
  `sync`, `board`, `tick`, `stats`, `guard`, `show`, `open`, `migrate`,
  `doctor`, `version`.
- The log is local-only and only *relatively* complete. "Not in the log" does
  not mean "did not happen"; verify with git and the real project state.
<!-- END relay-logs -->
