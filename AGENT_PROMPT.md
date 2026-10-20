# Prompts for handing this repository to an agent

Use these when you want another agent (Claude Code, OpenCode, Codex, …) to
install or remove the system in a target project.

## Install — short version

```text
Read AGENTS.md and INSTALL.md in /path/to/agent-relay-logs, then install
agent-relay-logs into /path/to/target. Run the dry-run first, then the real
install, then the verification steps. Touch only .relay/, .gitignore, AGENTS.md
and CLAUDE.md. Report every file you changed and the verification output.
```

## Install — self-contained

```text
You are in the repository /path/to/target. The directory
/path/to/agent-relay-logs contains the "agent-relay-logs" installer: a small,
local-only work log that lets several coding agents in the same repository see
what each session started and finished.

Do this:
1. Read /path/to/agent-relay-logs/AGENTS.md, INSTALL.md and package/README.md.
2. Inspect /path/to/target: existing AGENTS.md, CLAUDE.md, .gitignore, and
   whether .relay/ already exists. Do not delete anything you find.
3. Run: /path/to/agent-relay-logs/scripts/install.sh --target /path/to/target --dry-run
   and read the output before doing anything else. If it says the runtime is
   older than the package, re-run the real install with --force.
4. Run the same command without --dry-run (add --backup).
5. Verify: /path/to/target/.relay/relay doctor, and one
   start → note → end → show cycle (the runtime is schema v4: start carries
   goal/plan/accept/scope, note records progress with text/next while working,
   scope logs working-scope changes, run records long commands with eta,
   end carries done/problems/verify/metrics/next/impact plus gate and score).
   With --hooks, also check the opencode plugin and the merged claude hooks.
6. Show the git diff of AGENTS.md, CLAUDE.md and .gitignore. Do not commit
   unless I ask, and never commit .relay/.

Report: files changed, verification output, and how to uninstall
(/path/to/agent-relay-logs/UNINSTALL.md).
```

## Uninstall — short version

```text
Read UNINSTALL.md in /path/to/agent-relay-logs, then remove agent-relay-logs
from /path/to/target. Check for open work first, run the dry-run, then the real
removal. By default keep the logs as .relay.removed-<timestamp>/. Report every
file you changed.
```

## Uninstall — self-contained

```text
You are in the repository /path/to/target, which has the "agent-relay-logs"
system installed (a .relay/ directory plus a relay-logs marker block in
AGENTS.md and CLAUDE.md). The installer lives in /path/to/agent-relay-logs.

Do this:
1. Read /path/to/agent-relay-logs/UNINSTALL.md.
2. Run: /path/to/target/.relay/relay sync --all   (report any open work)
3. Run: /path/to/agent-relay-logs/scripts/uninstall.sh --target /path/to/target --dry-run
   and read the output.
4. Run the same command without --dry-run. Keep the logs unless I ask for
   --purge.
5. Show the git diff of AGENTS.md, CLAUDE.md and .gitignore. Do not commit
   unless I ask.

Report: files changed, what happened to .relay/, and how to restore it.
```

## Notes for the person writing the prompt

- Always give absolute paths; agents rarely share your working directory.
- Say "read INSTALL.md first" — it contains the verification and commit rules.
- Say "do not commit" unless the agent should commit. The relay runtime must
  never be committed.
- If the target is a production checkout, prefer `--dry-run` and verify the
  diff before writing.
