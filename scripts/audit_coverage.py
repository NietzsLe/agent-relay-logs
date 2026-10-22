#!/usr/bin/env python3
"""Audit relay coverage: find harness sessions that did real work but never
logged to .relay/.

Reads (never writes):
- this machine's harness session stores: opencode (sqlite), Claude Code
  (JSONL per project), Codex (rollout JSONL). Cursor is detected and skipped
  with a notice (no local store format pinned yet).
- the target's .relay/data/*.jsonl day files.

A harness session counts as real work when it has at least one user prompt
and (tool calls OR duration > 60s OR more than one user prompt). It counts
as covered when a relay session's time window overlaps it. Matching is
heuristic (no shared key without hooks) — time overlap only.

Exit 1 when unlogged real-work sessions are found, else 0.
Store locations can be overridden for tests:
  OPENCODE_DB, CLAUDE_PROJECTS_DIR, CODEX_SESSIONS_DIR.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
OPENCODE_DB = os.environ.get(
    "OPENCODE_DB", os.path.join(HOME, ".local/share/opencode/opencode.db"))
CLAUDE_PROJECTS = os.environ.get(
    "CLAUDE_PROJECTS_DIR", os.path.join(HOME, ".claude/projects"))
CODEX_SESSIONS = os.environ.get(
    "CODEX_SESSIONS_DIR", os.path.join(HOME, ".codex/sessions"))


def parse_ts(value):
    """ISO-8601 (with or without offset, with or without Z) -> epoch float."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        # epoch seconds or milliseconds?
        return float(value / 1000) if value > 1e12 else float(value)
    text = str(value).strip()
    if not text:
        return None
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        return datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


def fmt(epoch):
    if epoch is None:
        return "?"
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%m-%d %H:%M")


def under(path, root):
    path = os.path.normpath(path or "")
    root = os.path.normpath(root)
    return path == root or path.startswith(root + os.sep)


def collect_opencode(target):
    """(sessions, notice). sessions: list of dicts."""
    sessions = []
    if not os.path.isfile(OPENCODE_DB):
        return sessions, "opencode store absent (skipped)"
    try:
        con = sqlite3.connect("file:%s?mode=ro" % OPENCODE_DB, uri=True)
        con.row_factory = sqlite3.Row
        rows = con.execute(
            "SELECT id, title, agent, directory, time_created, time_updated"
            " FROM session_v2").fetchall()
    except Exception as ex:  # schema drift, locked, ...
        return sessions, "opencode store unreadable: %s (skipped)" % ex
    for r in rows:
        if not under(r["directory"] or "", target):
            continue
        sid = r["id"]
        start = (r["time_created"] or 0) / 1000
        end = (r["time_updated"] or r["time_created"] or 0) / 1000
        try:
            msgs = con.execute(
                "SELECT type, data FROM session_message WHERE session_id=?",
                (sid,)).fetchall()
        except Exception:
            msgs = []
        n_user = 0
        has_tool = False
        for m in msgs:
            if m["type"] != "assistant":
                if m["type"] == "user":
                    n_user += 1
                continue
            data = m["data"] or ""
            if '"type":"tool"' in data.replace(" ", ""):
                has_tool = True
            else:
                try:
                    d = json.loads(data)
                except ValueError:
                    continue
                content = d.get("content") if isinstance(d, dict) else None
                if isinstance(content, list) and any(
                        isinstance(p, dict) and p.get("type") == "tool"
                        for p in content):
                    has_tool = True
        sessions.append({
            "harness": "opencode", "id": sid,
            "title": (r["title"] or "(no title)")[:80],
            "start": start, "end": end,
            "n_user": n_user, "has_tool": has_tool,
        })
    try:
        con.close()
    except Exception:
        pass
    return sessions, "opencode: %d session(s) in target" % len(sessions)


def collect_claude(target):
    sessions = []
    dirname = os.path.normpath(target).replace("/", "-")
    projdir = os.path.join(CLAUDE_PROJECTS, dirname)
    if not os.path.isdir(projdir):
        return sessions, "claude store: no project dir (skipped)"
    for path in glob.glob(os.path.join(projdir, "*.jsonl")):
        n_user = 0
        n_tool = 0
        first = None
        last = None
        title = ""
        sidechain_only = True
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    if d.get("type") == "user":
                        if d.get("isSidechain"):
                            continue
                        sidechain_only = False
                        n_user += 1
                        ts = parse_ts(d.get("timestamp"))
                        if ts is not None:
                            first = ts if first is None else min(first, ts)
                            last = ts if last is None else max(last, ts)
                        if not title:
                            m = d.get("message", {})
                            c = m.get("content", "") if isinstance(m, dict) else ""
                            if isinstance(c, str) and c.strip():
                                title = c.strip().replace("\n", " ")[:80]
                    elif d.get("type") == "assistant":
                        ts = parse_ts(d.get("timestamp"))
                        if ts is not None:
                            last = ts if last is None else max(last, ts)
                        if "tool_use" in line:
                            n_tool += 1
        except OSError:
            continue
        if sidechain_only or n_user == 0:
            continue
        if first is None:
            try:
                first = last = os.path.getmtime(path)
            except OSError:
                continue
        sessions.append({
            "harness": "claude", "id": os.path.basename(path)[:8],
            "title": title or "(no title)",
            "start": first, "end": last or first,
            "n_user": n_user, "has_tool": n_tool > 0,
        })
    return sessions, "claude: %d session(s) in target" % len(sessions)


def collect_codex(target):
    sessions = []
    if not os.path.isdir(CODEX_SESSIONS):
        return sessions, "codex store absent (skipped)"
    for path in glob.glob(os.path.join(CODEX_SESSIONS, "**", "*.jsonl"),
                           recursive=True):
        meta = None
        first = None
        last = None
        n_user = 0
        has_tool = False
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    if d.get("type") == "session_meta" and meta is None:
                        meta = d.get("payload", {})
                        continue
                    ts = parse_ts(d.get("timestamp"))
                    if ts is not None:
                        first = ts if first is None else min(first, ts)
                        last = ts if last is None else max(last, ts)
                    if d.get("type") == "response_item":
                        role = d.get("payload", {}).get("role")
                        if role == "user":
                            n_user += 1
                    if ("function_call" in line or "exec_command" in line
                            or '"type": "tool"' in line):
                        has_tool = True
        except OSError:
            continue
        if not meta:
            continue
        cwd = meta.get("cwd") or ""
        if not under(cwd, target):
            continue
        if n_user == 0 and first is None:
            continue
        if first is None:
            try:
                first = last = os.path.getmtime(path)
            except OSError:
                continue
        sessions.append({
            "harness": "codex", "id": str(meta.get("id") or meta.get("session_id") or "?")[:8],
            "title": "(codex session)",
            "start": first, "end": last or first,
            "n_user": n_user, "has_tool": has_tool,
        })
    return sessions, "codex: %d session(s) in target" % len(sessions)


def collect_cursor():
    for cand in (os.path.join(HOME, ".cursor"),
                 os.path.join(HOME, ".config/Cursor")):
        if os.path.exists(cand):
            return [], "cursor store present but format not supported (skipped)"
    return [], "cursor not installed (skipped)"


def collect_relay(target, since, until):
    """relay sessions: {session: (first, last, agent, texts)}."""
    sessions = {}
    pattern = os.path.join(target, ".relay", "data", "????-??-??.jsonl")
    for path in sorted(glob.glob(pattern)):
        day = os.path.basename(path)[:10]
        if since and day < since:
            continue
        if until and day > until:
            continue
        try:
            fh = open(path, encoding="utf-8")
        except OSError:
            continue
        with fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                s = e.get("session")
                if not s:
                    continue
                ts = parse_ts(e.get("ts"))
                first, last, agent, texts = sessions.get(
                    s, (None, None, e.get("agent"), []))
                if ts is not None:
                    first = ts if first is None else min(first, ts)
                    last = ts if last is None else max(last, ts)
                for key in ("title", "text", "cmd", "summary"):
                    val = e.get(key)
                    if isinstance(val, str) and val:
                        texts.append(val)
                sessions[s] = (first, last, agent or "?", texts)
    return sessions


def is_real_work(h):
    if h["n_user"] == 0:
        return False
    duration = (h["end"] or 0) - (h["start"] or 0)
    return h["has_tool"] or duration > 60 or h["n_user"] > 1


def overlaps(h_start, h_end, r_first, r_last):
    if r_first is None or r_last is None:
        return False
    return r_first <= h_end and r_last >= h_start


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Audit relay coverage across harness session stores.")
    parser.add_argument("--target", default=".",
                        help="target repository (default: current directory)")
    parser.add_argument("--since", default=None,
                        help="only relay days >= YYYY-MM-DD")
    parser.add_argument("--until", default=None,
                        help="only relay days <= YYYY-MM-DD")
    args = parser.parse_args(argv)
    target = os.path.abspath(args.target)
    if not os.path.isdir(target):
        print("error: target is not a directory: %s" % target,
              file=sys.stderr)
        return 2

    harness = []
    notices = []
    for collector in (lambda: collect_opencode(target),
                      lambda: collect_claude(target),
                      lambda: collect_codex(target),
                      collect_cursor):
        try:
            found, notice = collector()
        except Exception as ex:  # never let one store break the audit
            found, notice = [], "collector failed: %s (skipped)" % ex
        harness.extend(found)
        notices.append(notice)

    relay = collect_relay(target, args.since, args.until)
    if args.since or args.until:
        lo = datetime.strptime(args.since, "%Y-%m-%d").replace(
            tzinfo=timezone.utc).timestamp() if args.since else 0
        hi = (datetime.strptime(args.until, "%Y-%m-%d").replace(
            tzinfo=timezone.utc).timestamp() + 86400) if args.until else float("inf")
        harness = [h for h in harness
                   if (h["end"] or 0) >= lo and (h["start"] or 0) < hi]

    deleg_hints = []
    for _s, (_f, _l, _a, texts) in relay.items():
        blob = " ".join(texts).lower()
        if "chrome" in blob or "codex exec" in blob or "delegat" in blob:
            deleg_hints.append(blob)

    unlogged = []
    covered = 0
    trivial = 0
    for h in sorted(harness, key=lambda x: x["start"] or 0):
        if not is_real_work(h):
            trivial += 1
            continue
        hit = any(overlaps(h["start"], h["end"], f, l)
                  for f, l, _a, _t in relay.values())
        if hit:
            covered += 1
            continue
        maybe_delegated = (
            h["harness"] == "claude"
            and any("chrome" in b or "claude" in b for b in deleg_hints))
        unlogged.append((h, maybe_delegated))

    print("audit relay coverage %s" % target)
    for notice in notices:
        print("  store: %s" % notice)
    print("  relay sessions in range: %d" % len(relay))
    print("  harness sessions: %d real work, %d trivially skipped"
          % (covered + len(unlogged), trivial))
    if not unlogged:
        print("result: OK — every real-work harness session overlaps a relay session")
        return 0
    print("result: %d unlogged real-work session(s):" % len(unlogged))
    for h, maybe in sorted(unlogged, key=lambda x: x[0]["start"] or 0):
        flag = " (possibly covered via --chrome delegation — verify parent log)" if maybe else ""
        print("  UNLOGGED [%s] %s -> %s | %s | user=%d tool=%s | %s%s"
              % (h["harness"], fmt(h["start"]), fmt(h["end"]), h["id"],
                 h["n_user"], "yes" if h["has_tool"] else "no",
                 h["title"], flag))
    return 1


if __name__ == "__main__":
    sys.exit(main())
