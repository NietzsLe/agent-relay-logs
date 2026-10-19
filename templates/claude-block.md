<!-- BEGIN relay-logs -->
## Relay — cross-agent work log

This project uses **agent-relay-logs** (`.relay/`). The full rules live in the
`relay-logs` block of `AGENTS.md` (or in `.relay/README.md` if that file is
absent).

- Start: `.relay/relay --agent <name> start "<title>" --scope <path,...>`
  then reuse the printed `--session <id>`.
- Before the final response: `.relay/relay --session <id> sync`.
- Finish: `.relay/relay --session <id> end --status done|partial|abandoned|blocked --summary "..."`.
- Local-only, no secrets/PII, not a source of truth.

_This block belongs to **agent-relay-logs** and is managed by its installer. To
uninstall, run `scripts/uninstall.sh` from the agent-relay-logs repository, or
delete everything between this line's marker and the END marker._
<!-- END relay-logs -->
