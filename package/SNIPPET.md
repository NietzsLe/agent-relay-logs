## Relay — cross-agent work log

**Scope:** `.relay/` is for local work on this checkout only, not shared through
git (it is ignored). If `.relay/relay` does not exist on this machine, ignore
this section.

This repository has `.relay/` (see `.relay/README.md`): each agent session logs
work **start** and **finish** so other sessions know the context. Tool:
`.relay/relay` (python3). Set your agent name with `--agent`
(claude/opencode/codex/…); the first call prints a session id — **reuse it** with
`--session <id>` in every later command (each shell command is a new process, so
environment variables do not persist).

- **Start of every real task** (after each user prompt that asks for work):
  `.relay/relay --agent <name> [--session <id>] start "short title" --scope <path,…>`
  — syncs unread changes automatically before writing.
- **Right before the final response of the turn:**
  `.relay/relay --session <id> sync` — picks up changes that appeared while you
  were working.
- **When done / abandoning / blocked:**
  `.relay/relay --session <id> end --status done|partial|abandoned|blocked --summary "…" --changes <file/commit,…> --impact "what the next person should know"`.
  Do not leave work hanging: a `start` without `end` means *work in progress*.
- Only log real work, not pure Q&A. Never log secrets or PII.

**Load silently:** the content of `sync` is *environment knowledge* so you think
in the right context; it is not something you must report back. Whether to
mention it, and how, is your choice (default: do not narrate).

**Limits:** the log is only *relatively* complete — some sessions/people do not
use relay, sessions crash before `end`, and work can happen outside the agent
(deploy, manual SQL, another machine). "Not in the log" does not mean "did not
happen"; "no open work" does not mean "nobody is working." The source of truth is
the real state (`git log/status`, files, database) — verify anything in the log
that your work depends on.
