# `.relay` — per-session work log for multiple agents

A small, self-contained system that can be copied into another project. Its goal:
agent sessions (Claude, OpenCode, Codex, …) working in the same repository can
see what was **started** and **finished** in other sessions, so they understand
the environment without asking the user again.

## Scope: local only

`.relay/` is for work on **this local checkout only**. It is **not shared through
git** (the directory is ignored), so other machines or clones do not see each
other's logs. Do not treat it as a source of truth for other people/machines.

## Model

- Each session writes to its own append-only file `data/<session>.jsonl`
  (one writer per file, so sessions do not collide).
- Events: `join` (session profile: agent, model, user, host, pid, cwd, branch,
  head, worktree, dirty) · `start` (title, scope) · `end` (task, status,
  summary, changes, impact). Every event carries `session, agent, cwd, branch,
  head`.
- **A `start` without an `end` means work is still in progress.** Work older
  than 12 hours (`RELAY_STALE_HOURS`) is labelled "possibly abandoned".
- **Read cursor** for each session: `data/<session>.cursor` (byte offset already
  read in each other session's file). `sync` prints only unread events and
  advances the cursor; nothing new means no output (saves tokens). Items whose
  `scope` overlaps the current session's open work are marked `!` and sorted
  first.
- First run in a session: only open work plus roughly the last 10 finished
  items, not the whole history. See everything with `relay sync --all` (does not
  advance the cursor).

## Commands

```text
relay [--session ID] [--agent NAME] [--model M] start "title" [--scope a,b]
relay [--session ID] end [TASK] --status done|partial|abandoned|blocked --summary ".." [--changes a,b] [--impact ".."]
relay [--session ID] sync [--all]
relay doctor
relay version
```

Without `--session`/`$RELAY_SESSION`, a session id is generated and printed
(`session=…`); later commands must pass it back. `end` without `TASK` finishes the
most recent open task of the session. Relay errors never block the main work
(printed to stderr, exit 0). Event lines are capped at 4 KB.

## Limits (important)

The log is **only relatively complete**: some sessions/people do not use relay,
sessions can crash before `end`, and work can happen outside the agent (deploy,
manual SQL, another machine). **"Not in the log" does not mean "did not happen";
"no open work" does not mean "nobody is working."** The source of truth is the
real state (`git log/status`, files, database) — verify anything in the log that
your work depends on.

## Load silently, do not report

The content of `sync` is environment knowledge for the agent to think with, not
something to narrate back to the user. Read it (1) when starting real work
(`start` syncs automatically) and (2) right before the final response. The agent
decides whether it is worth mentioning in the response.

## Install / uninstall

See the `agent-relay-logs` repository: `INSTALL.md` and `UNINSTALL.md`. The
short version is to run `scripts/install.sh` / `scripts/uninstall.sh` from that
repository with `--target <project>`.
