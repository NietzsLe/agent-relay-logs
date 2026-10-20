<!-- BEGIN relay-logs -->
## Relay — cross-agent work log

This project uses **agent-relay-logs** (`.relay/`). The full rules live in the
`relay-logs` block of `AGENTS.md` (or in `.relay/README.md` if that file is
absent).

- First: `.relay/relay board` — see what other sessions are doing right now.
- Start: `.relay/relay --agent <name> start "<title>" --goal "<what and why>" --plan "<step>" --scope <path,...>`
  then reuse the printed `--session <id>`.
- While working: one line per step, at least every 10 minutes —
  `.relay/relay --session <id> note --kind progress --text "<what happened>" --next "<next step>"`.
- Scope changed: `.relay/relay --session <id> scope --add <path> --why "<reason>"`.
- Long command: `.relay/relay --session <id> run --eta 8m -- <command>`.
- After each big step and before the final response: `.relay/relay --session <id> sync`.
- Finish: `.relay/relay --session <id> end --status done|partial|abandoned|blocked --summary "..." --done "..." --problem "<problem> => <fix>" --verify "..." --impact "..."`.
- `relay tick` prints at most one line when something needs you; silence means fine.
  `end` exits 1 on gate violation (still recorded) — fix or `--force`.
- Detail matters: goal/plan/accept on start, text+next on notes, done/problems/
  verify/metrics/next on end. The log is one file per day
  (`.relay/data/YYYY-MM-DD.jsonl`), cursors in `.relay/cursors/`. Local-only,
  no secrets/PII, not a source of truth.

_This block belongs to **agent-relay-logs** and is managed by its installer. To
uninstall, run `scripts/uninstall.sh` from the agent-relay-logs repository, or
delete everything between this line's marker and the END marker._
<!-- END relay-logs -->
