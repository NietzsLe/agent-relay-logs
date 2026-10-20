# `.relay` — per-session work log for multiple agents (schema v4)

A small, self-contained system that can be copied into another project. Goal:
agent sessions (Claude, OpenCode, Codex, …) working in the same repository can
see **what each session planned, what it hit, and what it left behind** — so
they understand the environment without asking the user again.

## Layout

```text
.relay/
├── relay              the CLI
├── README.md          this file
├── SNIPPET.md         short usage snippet
├── keys/
│   └── <key>.json     harness session → relay session mapping (for hooks)
├── data/
│   ├── 2026-10-19.jsonl   every event of that UTC day — all sessions, one file
│   ├── 2026-10-20.jsonl
│   └── legacy/            per-session files from v1/v2, kept after migration
└── cursors/
    └── <session>.json     per-session read cursor: {data file → byte offset}
```

**One file per day.** Every session writes into the same `data/YYYY-MM-DD.jsonl`,
so the log can be read as a diary of the day ("what happened today, in order,
who did it"). Appends use `O_APPEND` with a single `write()`, so concurrent
sessions never interleave a line.

**Cursors are per session**, in their own directory: each session remembers how
far it has read in each day file, so `sync` shows only what is new *to that
session* and never repeats itself. A session never sees its own events as
somebody else's news.

**Migration.** Installations from v1/v2 (one file per session) are migrated
automatically on the next command: the events are folded into the day file of
their timestamp and the original file is moved to `data/legacy/` — nothing is
deleted. `relay migrate --dry-run` shows what would move.

## Scope: local only

`.relay/` is for work on **this local checkout only**. It is **not shared through
git** (the directory is ignored), so other machines or clones do not see each
other's logs. Do not treat it as a source of truth for other people/machines.

## Why the log is detailed

A log that only says *"task X started"* is useless to the next session. Every
event type therefore carries the context that a reader needs:

| Event | Answers | Fields |
|---|---|---|
| `join` | Who/where am I? | agent, model, user, host, pid, cwd, project, branch, head, worktree, dirty |
| `start` | **What will be done, how, and how is it judged done?** | title, goal, plan, accept, outs, scope, tags, refs |
| `note` | **What just happened + what is next?** | task, kind (progress/problem/decision/result/blocker/question), text (1 line), next (1 line), detail, where, refs |
| `scope` | **The working scope changed — where and why?** | task, add, why |
| `wait` | **A long command is starting — what, how long?** | task, cmd, eta_s |
| `run` | **That command finished — how long, what exit?** | task, cmd, eta_s, actual_s, exit, late_s, over_s |
| `end` | **What was done, what broke, how was it verified, what is left?** | status, summary, done, problems, verify, metrics, changes, commits, impact, next, lessons, refs, duration_s, notes, score, gate, forced |

The `note` type is what makes a long task legible: an agent that works for an
hour can record a problem at minute 10 instead of only reporting at the end.

## Model

- Events are appended to `data/YYYY-MM-DD.jsonl` (one file per UTC day, shared
  by all sessions). Each line is one JSON object.
- Every event carries `id, ts, type, v (schema version), session, agent, cwd,
  branch, head`.
- **`start` without `end` means work is still in progress.** Work older than 12
  hours (`RELAY_STALE_HOURS`) is labelled "possibly abandoned".
- **Read cursor** for each session: `cursors/<session>.json` maps each day file
  to the byte offset already read. `sync` prints only unread events and
  advances the cursor; nothing new means no output (saves tokens). Events whose
  `scope` or `tags` overlap the current session's open work are marked `!` and
  sorted first.
- First run in a session: open work, the notes attached to it, and the last ~10
  finished tasks with their plans — not the whole history. `sync --all` shows
  everything without advancing the cursor.
- The **agent name is inherited** from the session's `join` event, so
  `relay --session <id> end ...` no longer records the agent as "agent".
- Lists are parsed with a bracket/quote-aware splitter: `--changes "a.py,b.py"`
  and `--changes "repo (new, commit abc)"` both survive.
- Every event line is valid JSON, even when oversized: oversized events are
  trimmed and flagged with `"trimmed": true` instead of being cut mid-object.
- Old (schema v1/v2) events are still readable and still render.

## Commands

```text
relay [--session ID] [--key KEY] [--agent NAME] [--model M] start "title"
      [--goal TEXT] [--plan TEXT]... [--accept TEXT]... [--out TEXT]...
      [--scope a,b]... [--tags a,b]... [--refs a,b]...

relay [--session ID] note [TASK]
      --kind progress|problem|decision|result|blocker|question
      --text "one line" [--next "one line"] [--detail TEXT]...
      [--where a,b]... [--refs a,b]...

relay [--session ID] scope [TASK] --add a,b... --why TEXT

relay [--session ID] wait [TASK] --cmd CMD [--eta 8m]
relay [--session ID] run [--task ID] --eta 8m -- CMD...
relay [--session ID] run --record --cmd CMD --actual 95s [--eta 8m] [--exit N]

relay [--session ID] end [TASK] --status done|partial|abandoned|blocked
      [--summary TEXT] [--done TEXT]... [--problem TEXT]... [--verify TEXT]...
      [--metric TEXT]... [--changes a,b]... [--commit sha]... [--next TEXT]...
      [--lesson L-nn]... [--refs a,b]... [--impact TEXT] [--force]

relay [--session ID] sync [--all] [--full] [--task ID]
relay [--session ID] show [TASK] [--json]
relay tick [--json] [--hook]     rhythm check: one line at most, exit 2 on violation
relay board                      open tasks with now/next/scope-clash lines
relay open [--stale]        list open tasks of every session (stale ones flagged)
relay stats                      scoreboard over closed tasks
relay guard --stop               Claude Code Stop hook: block once when silent too long
relay migrate [--dry-run]
relay doctor
relay version
```

- Without `--session`/`$RELAY_SESSION`, a session id is generated and printed
  (`session=…`); later commands must pass it back. `$RELAY_AGENT` and
  `$RELAY_MODEL` are honoured. `--key`/`$RELAY_KEY` maps a harness session to a
  relay session (written by hooks, so the agent never types an id).
- `end`/`note`/`scope`/`wait`/`run` without a task id use the open task of the
  session; if the session has none, the single open task of the same agent is
  used, otherwise the command refuses and lists the candidates. `note` falls
  back to the most recent task of the session, so a correction can still be
  attached after the task was closed.
- `run` without `--record` executes the command after `--`, writes `wait`
  first and `run` after, and exits with the command's exit code.
- `show` prints one task in full (plan, notes, scope changes, runs, problems,
  verification, score). `stats` prints the scoreboard.
- Relay errors never block the main work (printed to stderr, exit 0) — except
  `end` gate violations (exit 1, event still recorded) and `tick` violations
  (exit 2, nothing written).

## What to write in each field

```text
start  title   one line, ≤120 chars: "Sửa N+1 ở trang danh sách bất động sản"
       goal    what and why, in 1–3 sentences
       plan    the steps you will take, in order
       accept  how "done" is judged (test xanh? số đo? tài liệu?)
       scope   paths you expect to touch  → other agents avoid the same files
       tags    keywords (perf, db, deploy) → other agents can find your work
       outs    explicitly out of scope

note   kind=problem   what broke, what you tried, what it costs
       kind=decision  a choice you made and why
       kind=result    a measured outcome
       kind=blocker   what you need from whom
       text   one paragraph; detail lines for raw output/measurements

end    summary   dense: what the world looks like now
       done      steps actually completed
       problems  every problem hit → how it was resolved (mark UNRESOLVED)
       verify    how you checked it + the result
       metrics   before → after (n=…, window=…, condition)
       changes   files/dirs touched
       commits   commit shas
       impact    what the next person must know
       next      open items / next steps
       lessons   lesson codes (L-nn) if you wrote one
```

## Limits (important)

The log is **only relatively complete**: some sessions/people do not use relay,
sessions can crash before `end`, and work can happen outside the agent (deploy,
manual SQL, another machine). **"Not in the log" does not mean "did not happen";
"no open work" does not mean "nobody is working."** The source of truth is the
real state (`git log/status`, files, database) — verify anything in the log that
your work depends on.

## Quality nudges (v3.1)

`start` without `--plan/--accept/--scope`, and `end --status done` without
`--summary/--verify`, print a one-line hint on stderr (never blocks). `relay
doctor` and `relay open --stale` list tasks left open past `RELAY_STALE_HOURS`;
close them with `relay end <task> --status abandoned|blocked`.

## Rhythm, long commands, score (v4)

- **Rhythm.** Log at least every `RELAY_GAP_MAX` seconds (default 600) of active
  work. Time inside a declared `wait`/`run` window does not count.
  `relay tick` checks: silence overdue, files outside the logged scope,
  expired wait windows, unread news. It prints at most one line and exits 2 on
  violation, else stays silent. `RELAY_NUDGE` (default 480) controls the soft
  reminder threshold.
- **Long commands.** Anything expected to take more than `RELAY_MIN_DECLARE`
  (default 120s) gets `--eta`: `relay run --eta 8m -- <cmd>` (executes and
  measures) or `relay wait --eta 8m --cmd "…"` + `relay run --record` (for
  harnesses that time the tool call themselves). Tolerance is
  `max(60s, 25%×eta)`; under- and over-estimating past tolerance both cost
  score, and a run over 120s with no declared eta counts its excess as late.
- **Scope.** `relay scope --add <path> --why "…"` extends the working scope.
  `tick` compares `git status` against the effective scope; `end` diffs
  `--changes` the same way. Drift costs scope points.
- **Gate.** `end` always records the event but exits 1 when: silence past the
  limit (wait excluded), late estimates, unlogged scope drift, or `done`
  without `--verify`. `--force` records acceptance instead (`forced: true`).
- **Score (0–100).** rhythm 50 · scope 20 · close 20 (summary/done/verify/next)
  · open 10 (goal/plan/scope) · −10 when forced. Floored at 0. `relay stats`
  and `relay doctor` print the board.

## Load silently, do not report

The content of `sync` is environment knowledge for the agent to think with, not
something to narrate back to the user. Read it (1) when starting real work
(`start` syncs automatically) and (2) right before the final response. The agent
decides whether it is worth mentioning in the response.

## Install / uninstall

See the `agent-relay-logs` repository: `INSTALL.md` and `UNINSTALL.md`. The
short version: `scripts/install.sh` / `scripts/uninstall.sh` with
`--target <project>`. Upgrading an existing installation to a newer runtime
needs `--force` (the runtime file is replaced, `data/` is never touched).
