# agent-relay-logs

A small, dependency-free work log that lets multiple coding agents (Claude Code,
OpenCode, Codex, Cursor, …) share what they are doing in the **same local
repository** — without a server, database, or shared memory.

Each agent writes to its own append-only session file. `sync` shows only events
the current session has not read yet. A `start` without an `end` means work is
still in progress. The log is local-only and git-ignored.

This repository is the **source and installer**. It is not an application and it
does not contain the log of any target project.

## Why this exists

When several agents and humans work in one repository, each session starts blind:
it does not know that another session is editing the same files, already tried a
fix, or left a task half-finished. `agent-relay-logs` gives every session a tiny,
cheap way to announce:

- **start** — what I am doing, and which paths I expect to touch;
- **end** — what changed, whether it is done, and what the next person must know.

The log is intentionally **not** a source of truth. It is context. The real state
is always `git log/status`, the files, and the running system.

## What gets installed into a target

Only four paths are touched:

| Path | Change |
|---|---|
| `.relay/` | Runtime: `relay` CLI (schema v4), `README.md`, `SNIPPET.md`; later `data/`, `cursors/`, `keys/`, `install.json` |
| `.gitignore` | Adds `.relay/` (if missing) |
| `AGENTS.md` | Inserts/replaces one `<!-- BEGIN relay-logs -->` … `<!-- END relay-logs -->` block |
| `CLAUDE.md` | Inserts/replaces the same kind of block |
| `.opencode/plugins/opencode-nudge.js` | Only with `--hooks`: timing + nudge plugin for OpenCode |
| `.claude/settings.local.json` | Only with `--hooks`: merged `tick`/`guard` hook entries |

The marker block is the whole uninstall contract: remove the block and the
instructions are gone. Existing project content is never replaced wholesale.

## What an agent is asked to log

The installed block is not "call `start`, call `end`" — it asks for detail,
because a log of *"task X started"* tells the next session nothing:

| Event | Required content |
|---|---|
| `start` | `--goal` (what and why), `--plan` (steps), `--accept` (how done is judged), `--scope` (files to touch), `--tags` (keywords) |
| `note` | `--kind progress\|problem\|decision\|result\|blocker` + `--text` + `--detail` (raw output, numbers, errors) — used *while* working |
| `end` | `--summary`, `--done`, `--problem` (problem → resolution), `--verify`, `--metric` (before → after with n and window), `--changes`, `--commit`, `--next`, `--lesson`, `--impact` |

## Quick start (human)

```bash
# From this repository:
./scripts/install.sh --target /path/to/project --dry-run
./scripts/install.sh --target /path/to/project --backup
```

Then verify:

```bash
./scripts/doctor.sh --target /path/to/project   # or: ./scripts/relay_setup.py doctor --target ...
/path/to/project/.relay/relay doctor
```

To remove:

```bash
./scripts/uninstall.sh --target /path/to/project --dry-run
./scripts/uninstall.sh --target /path/to/project
```

By default uninstall moves `.relay/` to `.relay.removed-<timestamp>/` so logs are
not lost. Use `--purge` to delete them, or `--keep-relay` to remove only the
instructions.

## Quick start (agent)

Give an agent this repository and a target project, then say:

> Read `AGENTS.md` and `INSTALL.md`, then install agent-relay-logs into
> `/path/to/project`. Run the dry-run first, then the real install, then verify.
> Report every file you changed.

`AGENT_PROMPT.md` contains copy-paste prompts (including a fully path-qualified
version).

## Repository layout

```text
agent-relay-logs/
├── README.md                  # this file
├── AGENTS.md                  # working contract for agents in this repo
├── CLAUDE.md                  # short pointer + relay system block
├── INSTALL.md                 # step-by-step install runbook for a target
├── UNINSTALL.md               # step-by-step uninstall runbook
├── AGENT_PROMPT.md            # copy-paste prompts for handing the repo to an agent
├── package/                   # exactly what gets copied to <target>/.relay/
│   ├── relay                  # CLI (Python 3 stdlib, no dependencies)
│   ├── README.md              # runtime documentation
│   └── SNIPPET.md             # short usage snippet for reference
├── templates/                 # marker blocks inserted into AGENTS.md / CLAUDE.md
│   ├── agents-block.md
│   └── claude-block.md
├── scripts/
│   ├── install.sh             # wrapper -> relay_setup.py install
│   ├── uninstall.sh           # wrapper -> relay_setup.py uninstall
│   ├── doctor.sh              # wrapper -> relay_setup.py doctor
│   └── relay_setup.py         # installer/uninstaller/doctor logic
└── tests/
    └── test.sh                # end-to-end acceptance tests
```

## How the runtime works

- **One file per day, shared by every session**: `.relay/data/YYYY-MM-DD.jsonl`.
  Appends use `O_APPEND` with a single `write()`, so concurrent sessions never
  interleave a line. The log reads as a diary of the day: what happened, in
  order, who did it.
- **Cursors are per session**, in `.relay/cursors/<session>.json` (day file →
  byte offset already read). `sync` shows only what is new to that session and
  never repeats itself; a session never sees its own events as somebody else's
  news.
- Installations from v1/v2 (one file per session) are migrated automatically:
  events are folded into the day file of their timestamp, the original file is
  moved to `data/legacy/`. Nothing is deleted.
- Four event types, each carrying the detail a reader needs:

  | Event | Answers | Fields |
  |---|---|---|
  | `join` | who/where am I? | agent, model, user, host, pid, cwd, project, branch, head, worktree, dirty |
  | `start` | **what will be done, how, and how is it judged done?** | title, goal, plan, accept, outs, scope, tags, refs |
  | `note` | **what is happening now, what broke, what was decided?** | task, kind (progress/problem/decision/result/blocker/question), text, detail, refs |
  | `end` | **what was done, what broke, how was it verified, what is left?** | status, summary, done, problems, verify, metrics, changes, commits, impact, next, lessons, refs, duration_s, notes |

  The `note` type is what makes a long task legible: an agent working for an
  hour records a problem at minute 10 instead of only reporting at the end.
- Each session has a cursor: `.relay/cursors/<session>.json` stores the byte
  offset read in every day file. `sync` prints only unread events and advances
  the cursor; nothing new means no output.
- First `sync` in a session shows open work, the notes attached to it, and the
  last ~10 finished tasks with their plans — not the whole history. `sync --all`
  shows everything without advancing the cursor.
- A `start` older than 12 hours (`RELAY_STALE_HOURS`) with no matching `end` is
  labelled "possibly abandoned".
- Events whose `scope` or `tags` overlap the current session's open work are
  marked `!` and sorted first.

## Design guarantees

- **Local only.** `.relay/` is git-ignored and never shared across machines by
  this tool.
- **No destructive rewrite.** Target files are edited only inside the marker
  block. Unbalanced markers are refused instead of guessed.
- **Idempotent.** Running install twice still leaves exactly one block.
- **Data-preserving.** Install never deletes `.relay/data`; uninstall moves it
  aside by default. Upgrading a runtime needs `--force` and still keeps `data/`.
- **Valid JSON always.** An oversized event is trimmed and flagged
  (`"trimmed": true`) instead of being cut mid-object, so the log never
  contains an unparseable line.
- **Correct attribution.** The agent name is inherited from the session's
  `join` event, so `relay --session <id> end …` no longer records the agent as
  "agent".
- **Robust parsing.** List options are split on commas that are not inside
  brackets or quotes, so `--changes "repo (new, commit abc)"` survives.
- **Readable.** `relay show <task>` prints one task in full; `relay sync --full`
  prints fields uncompacted.
- **Backwards compatible.** Schema v1 events still render; v2 events carry
  `"v": 2`.
- **No dependencies.** Python 3 standard library and POSIX `sh` only. `git` is
  optional (used for context fields when available).
- **No secrets.** The docs and CLI tell agents not to log secrets/PII. There is
  no automatic redaction — treat the log as a local plaintext file.

## Requirements

- Python 3.8+
- POSIX `sh` (for the wrappers)
- `git` optional, recommended

## Verification

```bash
./tests/test.sh
python3 -m py_compile scripts/relay_setup.py package/relay
```

`tests/test.sh` creates temporary targets and verifies: dry-run, install,
idempotent install, marker preservation, relay start/end/sync, uninstall,
idempotent uninstall, `--purge`, and refusal of unbalanced markers.

## Limitations

The log is only *relatively* complete. Some sessions do not use relay, a session
can crash before `end`, and work can happen outside the agent (deploy, manual SQL,
another machine). "Not in the log" does not mean "did not happen"; "no open work"
does not mean "nobody is working." Verify anything you depend on.

## License

Add a license before distributing publicly; this repository does not assume one.
