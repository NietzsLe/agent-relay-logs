<!-- BEGIN relay-logs -->
## Relay — cross-agent work log

This project uses **agent-relay-logs** (`.relay/`). The system is local-only and
ignored by git; it is not a source of truth. Its purpose: other agent sessions
and humans must be able to read your work without asking you.

**Log this much detail — a log of "task X started" is useless:**

| Event | Must contain |
|---|---|
| `start` | what will be done and why (`--goal`), the steps (`--plan`), how "done" is judged (`--accept`), files you expect to touch (`--scope`), keywords (`--tags`) |
| `note` | what just happened while working: progress, a problem, a decision, a measured result, or a blocker (`--kind`) |
| `end` | what was actually done (`--done`), every problem and how it was resolved (`--problem`), how it was verified (`--verify`), numbers before/after (`--metric`), files and commits (`--changes`, `--commit`), what the next person must know (`--impact`), open items (`--next`), lesson codes (`--lesson`) |

**Commands**

```bash
# start of a real task (not for pure Q&A) — prints session=… , reuse it below
.relay/relay --agent <name> start "<one-line title>" \
  --goal "<what and why>" --plan "<step 1>" --plan "<step 2>" \
  --scope <path,...> --tags <keyword,...> --accept "<how done is judged>"

# while working (this is what makes a long task readable by others)
.relay/relay --session <id> note --kind progress|problem|decision|result|blocker \
  --text "<what happened>" --detail "<raw output, numbers, error>"

# right before your final response of the turn
.relay/relay --session <id> sync

# when done / abandoning / blocked
.relay/relay --session <id> end --status done|partial|abandoned|blocked \
  --summary "<what the world looks like now>" \
  --done "<step completed>" --problem "<problem> => <how it was resolved>" \
  --verify "<how it was checked> => <result>" \
  --metric "<before> -> <after> (n=..., window=...)" \
  --changes <file,...> --commit <sha> --next "<open item>" --lesson L-nn \
  --impact "<what the next person must know>"
```

Rules:

- Be specific: "fixed the bug" is worthless; "migration deadlock → advisory
  lock; `pytest tests/test_migrate.py` green" is useful.
- Only log real work; never log secrets, tokens, or PII.
- A `start` without an `end` means work is still in progress.
- The log is one file per day — `.relay/data/YYYY-MM-DD.jsonl` (all sessions of
  that day); read cursors live in `.relay/cursors/`.
- The log is only *relatively* complete. "Not in the log" does not mean "did not
  happen" — verify with `git log/status`, files, and the real project state.
- Read `.relay/README.md` for the full model; `relay show <task>` prints one
  task in full.

_This block belongs to **agent-relay-logs** and is managed by its installer. To
uninstall, run `scripts/uninstall.sh` from the agent-relay-logs repository, or
delete everything between this line's marker and the END marker._
<!-- END relay-logs -->
