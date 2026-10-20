## Relay — cross-agent work log

**Scope:** `.relay/` is for local work on this checkout only, not shared through
git (it is ignored). If `.relay/relay` does not exist on this machine, ignore
this section.

This repository has `.relay/` (see `.relay/README.md`): each agent session logs
**what it will do, what it hits, and what it leaves behind** so other sessions
know the context. Tool: `.relay/relay` (python3). Set your agent name with
`--agent` (claude/opencode/codex/…); the first call prints a session id —
**reuse it** with `--session <id>` in every later command (each shell command is
a new process, so environment variables do not persist).

The log is one file per day: `.relay/data/YYYY-MM-DD.jsonl` (every session of
that day), cursors per session in `.relay/cursors/`.

- **First: see what other sessions are doing right now:**
  `.relay/relay board` — open tasks with now · next · scope-clash lines.
- **Start of every real task** (after each user prompt that asks for work):
  ```bash
  .relay/relay --agent <name> start "<one-line title>" \
    --goal "<what and why>" --plan "<step 1>" --plan "<step 2>" \
    --scope <path,...> --tags <keyword,...> --accept "<how done is judged>"
  ```
  — syncs unread changes automatically before writing.
- **While working: one line per step, at least every 10 minutes.**
  Time inside a declared `run` window does not count.
  ```bash
  .relay/relay --session <id> note --kind progress --text "<what just happened>" --next "<next step>"
  ```
- **The working scope changed:**
  `.relay/relay --session <id> scope --add <path,...> --why "<reason>"`
- **A command that takes a while** (more than ~2 minutes):
  `.relay/relay --session <id> run --eta 8m -- <command>`
- **After each big step and right before the final response of the turn:**
  `.relay/relay --session <id> sync` — picks up work done by other agents while
  you were working.
- **When done / abandoning / blocked:**
  ```bash
  .relay/relay --session <id> end --status done|partial|abandoned|blocked \
    --summary "<what the world looks like now>" \
    --done "<step completed>" --problem "<problem> => <how it was resolved>" \
    --verify "<how it was checked> => <result>" \
    --metric "<before> -> <after> (n=..., window=...)" \
    --changes <file,...> --commit <sha> --next "<open item>" --lesson L-nn \
    --impact "<what the next person must know>"
  ```
  `end` exits 1 on gate violation (silence over the limit, badly estimated
  commands, unlogged scope drift, `done` without `--verify`) — the event is
  still recorded and the task is closed. Re-run the same `end` with `--force`
  to accept the penalty.

Rules:

- Only log real work, not pure Q&A. Never log secrets, tokens, or PII.
- Be specific: "fixed the bug" is worthless, "migration deadlock → switched to
  advisory lock; test `pytest tests/test_migrate.py` green" is useful.
- A `start` without an `end` means work is still in progress.
- The log is only *relatively* complete. "Not in the log" does not mean "did not
  happen" — verify with `git log/status`, files, and the real project state.
- Read `.relay/README.md` for the full model.

**Load silently:** the content of `sync` is *environment knowledge* so you think
in the right context; it is not something you must report back. Whether to
mention it, and how, is your choice (default: do not narrate).

**Limits:** the log is only *relatively* complete — some sessions/people do not
use relay, sessions crash before `end`, and work can happen outside the agent
(deploy, manual SQL, another machine). "Not in the log" does not mean "did not
happen"; "no open work" does not mean "nobody is working." The source of truth is
the real state (`git log/status`, files, database) — verify anything in the log
that your work depends on.
