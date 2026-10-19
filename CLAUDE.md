# CLAUDE.md

> Read `AGENTS.md` first. It is the working contract for this repository.

This project is **agent-relay-logs**, the source repository for a local-only
cross-agent work log. It is not a typical application.

<!-- BEGIN relay-logs -->
## agent-relay-logs — quick context

This section belongs to the **agent-relay-logs** system. Remove it by deleting
everything between this marker and `<!-- END relay-logs -->`.

- Goal: install `.relay/` plus a marker block into another repository.
- Install: `./scripts/install.sh --target /path/to/project --dry-run`, then run
  the same command without `--dry-run`.
- Uninstall: `./scripts/uninstall.sh --target /path/to/project`.
- Read `INSTALL.md` and `UNINSTALL.md` before touching a target.
- Never commit `.relay/`; never log secrets or PII.
- Verify with `./tests/test.sh`.
<!-- END relay-logs -->
