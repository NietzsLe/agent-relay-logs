<!-- BEGIN relay-logs -->
## Relay — cross-agent work log

This project uses **agent-relay-logs** (`.relay/`). The system is local-only and
ignored by git; it is not a source of truth.

- **Start of every real task** (not for pure Q&A):
  ```bash
  .relay/relay --agent <name> start "<short title>" --scope <path,...>
  ```
  The first call prints `session=<id>`. Reuse it in every later command with
  `--session <id>` (each shell command is a new process).
- **Right before the final response of the turn:**
  `.relay/relay --session <id> sync` — picks up work done by other agents while
  you were working.
- **When done / abandoning / blocked:**
  ```bash
  .relay/relay --session <id> end --status done|partial|abandoned|blocked \
    --summary "..." --changes <file/commit,...> --impact "what the next person should know"
  ```

Rules:

- Only log real work; never log secrets, tokens, or PII.
- A `start` without an `end` means work is still in progress.
- The log is only *relatively* complete. "Not in the log" does not mean "did not
  happen" — verify with `git log/status`, files, and the real project state.
- Read `.relay/README.md` for the full model.

_This block belongs to **agent-relay-logs** and is managed by its installer. To
uninstall, run `scripts/uninstall.sh` from the agent-relay-logs repository, or
delete everything between this line's marker and the END marker._
<!-- END relay-logs -->
