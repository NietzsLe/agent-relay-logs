<!-- BEGIN relay-logs -->
## Relay — cross-agent work log

This project uses **agent-relay-logs** (`.relay/`). The system is local-only and
ignored by git; it is not a source of truth. Its purpose: other agent sessions
and humans must be able to read your work without asking you.

**Log this much detail — a log of "task X started" is useless:**

| Event | Must contain |
|---|---|
| `start` | what will be done and why (`--goal`), the steps (`--plan`), how "done" is judged (`--accept`), files you expect to touch (`--scope`), keywords (`--tags`) |
| `note` | one line on what just happened (`--text`) + the next step (`--next`); kind: progress/problem/decision/result/blocker |
| `scope` | every path added to the working scope (`--add`) + why (`--why`) |
| `run` | every command expected to take >2 minutes: estimated time (`--eta`), then the measured result |
| `end` | what was actually done (`--done`), every problem and how it was resolved (`--problem`), how it was verified (`--verify`), numbers before/after (`--metric`), files and commits (`--changes`, `--commit`), what the next person must know (`--impact`), open items (`--next`), lesson codes (`--lesson`) |

**Commands**

```bash
# first: see what other sessions are doing right now (now · next · scope clash)
.relay/relay board

# start of a real task (not for pure Q&A) — prints session=… , reuse it below
.relay/relay --agent <name> start "<one-line title>" \
  --goal "<what and why>" --plan "<step 1>" --plan "<step 2>" \
  --scope <path,...> --tags <keyword,...> --accept "<how done is judged>"

# while working: one line per step, at least every 10 minutes
.relay/relay --session <id> note --kind progress --text "<what just happened>" --next "<next step>"

# the working scope changed
.relay/relay --session <id> scope --add <path,...> --why "<reason>"

# a command that takes a while (build, test suite, migration)
.relay/relay --session <id> run --eta 8m -- <command>

# after each big step: pull what other sessions did
.relay/relay --session <id> sync

# when done / abandoning / blocked (exit 1 on gate violation: fix or --force)
.relay/relay --session <id> end --status done|partial|abandoned|blocked \
  --summary "<what the world looks like now>" \
  --done "<step completed>" --problem "<problem> => <how it was resolved>" \
  --verify "<how it was checked> => <result>" \
  --metric "<before> -> <after> (n=..., window=...)" \
  --changes <file,...> --commit <sha> --next "<open item>" --lesson L-nn \
  --impact "<what the next person must know>"
```

**Rhythm (checked by the tool, not by memory):**

- `relay tick` prints at most one line when something needs you: silence past
  the reminder, files outside the logged scope, or unread news from other
  sessions. Silence means everything is fine.
- Log at least every 10 minutes of active work. Time inside a declared
  `run`/`wait` window does not count.
- Every command you expect to take more than 2 minutes gets `--eta` first
  (`relay run --eta 8m -- …`). Underestimating past tolerance and
  overestimating wildly both cost score.
- Every scope change gets one `scope` line before you keep working.
- `end` refuses (exit 1, still recorded and closed) on: silence over the limit,
  badly estimated commands, unlogged scope drift, or `done` without `--verify`.
  Re-run with `--force` to accept the penalty.

Rules:

- Be specific: "fixed the bug" is worthless; "migration deadlock → advisory
  lock; `pytest tests/test_migrate.py` green" is useful.
- Only log real work; never log secrets, tokens, or PII.
- A `start` without an `end` means work is still in progress.
- The log is one file per day — `.relay/data/YYYY-MM-DD.jsonl` (all sessions of
  that day); read cursors live in `.relay/cursors/`, harness keys in `.relay/keys/`.
- The log is only *relatively* complete. "Not in the log" does not mean "did not
  happen" — verify with `git log/status`, files, and the real project state.
- Read `.relay/README.md` for the full model; `relay show <task>` prints one
  task in full, `relay stats` prints the scoreboard.

_This block belongs to **agent-relay-logs** and is managed by its installer. To
uninstall, run `scripts/uninstall.sh` from the agent-relay-logs repository, or
delete everything between this line's marker and the END marker._
<!-- END relay-logs -->
