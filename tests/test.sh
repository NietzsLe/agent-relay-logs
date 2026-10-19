#!/bin/sh
# End-to-end tests for agent-relay-logs. POSIX sh + Python 3 only.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BASE=${TMPDIR:-/tmp}
TMP=$(mktemp -d "$BASE/agent-relay-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
contains() { grep -qF "$1" "$2" || fail "$2 is missing: $1"; }
not_contains() { ! grep -qF "$1" "$2" || fail "$2 still contains: $1"; }
count() { grep -cF "$1" "$2" 2>/dev/null || true; }

# --- static checks ---------------------------------------------------------
python3 -m py_compile "$ROOT/scripts/relay_setup.py" "$ROOT/package/relay"
sh -n "$ROOT/scripts/install.sh"
sh -n "$ROOT/scripts/uninstall.sh"
pass "Python and shell syntax"

# --- fixture ---------------------------------------------------------------
P="$TMP/project"
mkdir -p "$P"
cat > "$P/AGENTS.md" <<'EOF'
# AGENTS.md

Existing project rule: keep me.
EOF
cat > "$P/CLAUDE.md" <<'EOF'
# CLAUDE.md

Existing Claude rule: keep me too.
EOF
printf 'node_modules/\n' > "$P/.gitignore"
git -C "$P" init -q
git -C "$P" add .
git -C "$P" -c user.name=test -c user.email=test@example.com commit -qm "initial"

# --- dry run ---------------------------------------------------------------
"$ROOT/scripts/install.sh" --target "$P" --dry-run >/dev/null
[ ! -e "$P/.relay" ] || fail "dry run created .relay"
not_contains "BEGIN relay-logs" "$P/AGENTS.md"
pass "dry run leaves the target untouched"

# --- install ---------------------------------------------------------------
"$ROOT/scripts/install.sh" --target "$P" --backup >/dev/null
[ -x "$P/.relay/relay" ] || fail ".relay/relay is not executable"
[ -f "$P/.relay/README.md" ] || fail ".relay/README.md missing"
[ -f "$P/.relay/install.json" ] || fail "install manifest missing"
contains "BEGIN relay-logs" "$P/AGENTS.md"
contains "END relay-logs" "$P/AGENTS.md"
contains "BEGIN relay-logs" "$P/CLAUDE.md"
contains ".relay/" "$P/.gitignore"
[ "$(count "BEGIN relay-logs" "$P/AGENTS.md")" = "1" ] || fail "duplicate block in AGENTS.md"
[ "$(count "BEGIN relay-logs" "$P/CLAUDE.md")" = "1" ] || fail "duplicate block in CLAUDE.md"
ls "$P"/AGENTS.md.relay-backup-* >/dev/null 2>&1 || fail "--backup did not create a backup"
contains "Existing project rule: keep me." "$P/AGENTS.md"
contains "Existing Claude rule: keep me too." "$P/CLAUDE.md"
pass "install copies the runtime and preserves project content"

# --- idempotent install ----------------------------------------------------
"$ROOT/scripts/install.sh" --target "$P" >/dev/null
[ "$(count "BEGIN relay-logs" "$P/AGENTS.md")" = "1" ] || fail "install is not idempotent (AGENTS.md)"
[ "$(count "BEGIN relay-logs" "$P/CLAUDE.md")" = "1" ] || fail "install is not idempotent (CLAUDE.md)"
pass "install is idempotent"

# --- relay behaviour -------------------------------------------------------
cd "$P"
SID="test-$$"
./.relay/relay --agent tester --session "$SID" start "first task" --scope src/a >/dev/null
./.relay/relay --agent tester --session "$SID" end --status done --summary "finished" --changes src/a >/dev/null
./.relay/relay --agent tester --session "$SID" start "second task" --scope src/b >/dev/null

SID2="test2-$$"
OUT=$(./.relay/relay --agent other --session "$SID2" sync)
echo "$OUT" | grep -q "second task" || fail "sync did not show the open task"
OUT2=$(./.relay/relay --agent other --session "$SID2" sync)
[ -z "$OUT2" ] || fail "second sync should be empty, got: $OUT2"
./.relay/relay --agent tester --session "$SID" end --status done --summary "finished again" >/dev/null
./.relay/relay doctor >/dev/null
pass "relay start/end/sync/doctor"

# --- schema v2: detail in every event type ---------------------------------
P4="$TMP/project4"
mkdir -p "$P4"
"$ROOT/scripts/install.sh" --target "$P4" >/dev/null
cd "$P4"
S4="v2-$$"
./.relay/relay --agent tester2 --session "$S4" start "task v2" \
    --goal "why this task exists" --plan "step one" --plan "step two" \
    --scope "src/a,src/b" --tags "perf,db" --accept "tests green" --refs "T-65,L-42" >/dev/null
TASK=$(python3 - <<EOF
import json, glob
for line in open(glob.glob(".relay/data/$S4.jsonl")[0]):
    e = json.loads(line)
    if e["type"] == "start":
        print(e["id"])
EOF
)
[ -n "$TASK" ] || fail "no task id written"

./.relay/relay --session "$S4" note --kind problem --text "deadlock in migrate" \
    --detail "ERROR: lock wait timeout" >/dev/null
./.relay/relay --session "$S4" end --status done \
    --summary "everything works now" --done "applied advisory lock" \
    --problem "deadlock => advisory lock" --verify "pytest green" \
    --metric "p50 120ms -> 40ms (n=200, window=10m)" \
    --changes "src/a.py, src/b.py" --commit "abc1234" --next "T-66" --lesson "L-42" \
    --impact "needs deploy" >/dev/null

python3 - <<EOF
import json, glob, sys
events = [json.loads(l) for l in open(glob.glob(".relay/data/$S4.jsonl")[0])]
by = {}
for e in events:
    by.setdefault(e["type"], []).append(e)
start = by["start"][0]
end = by["end"][0]
note = by["note"][0]
errs = []
def check(cond, msg):
    if not cond:
        errs.append(msg)
check(start.get("goal") == "why this task exists", "goal not stored")
check(start.get("plan") == ["step one", "step two"], "plan not stored: %r" % start.get("plan"))
check(start.get("scope") == ["src/a", "src/b"], "scope not split: %r" % start.get("scope"))
check(start.get("tags") == ["perf", "db"], "tags not stored")
check(start.get("accept") == ["tests green"], "accept not stored")
check(start.get("refs") == ["T-65", "L-42"], "refs not stored")
check(note.get("kind") == "problem", "note kind missing")
check(note.get("detail") == ["ERROR: lock wait timeout"], "note detail missing")
check(end.get("done") == ["applied advisory lock"], "done not stored")
check(end.get("problems") == ["deadlock => advisory lock"], "problems not stored")
check(end.get("verify") == ["pytest green"], "verify not stored")
check(end.get("metrics") and "n=200" in end["metrics"][0], "metrics not stored")
check(end.get("changes") == ["src/a.py", "src/b.py"], "changes not split: %r" % end.get("changes"))
check(end.get("commits") == ["abc1234"], "commits not stored")
check(end.get("next") == ["T-66"], "next not stored")
check(end.get("lessons") == ["L-42"], "lessons not stored")
check(end.get("impact") == "needs deploy", "impact not stored")
check(end.get("notes") == 1, "note count not recorded: %r" % end.get("notes"))
check(isinstance(end.get("duration_s"), int), "duration not recorded")
check(end.get("agent") == "tester2", "agent not inherited: %r" % end.get("agent"))
check(note.get("agent") == "tester2", "note agent not inherited: %r" % note.get("agent"))
if errs:
    print("FAIL: " + "; ".join(errs), file=sys.stderr)
    sys.exit(1)
EOF
pass "every event type stores its detail"

# --- smart comma splitting --------------------------------------------------
./.relay/relay --agent tester3 --session "split-$$" start "split test" >/dev/null
./.relay/relay --session "split-$$" end --status done --summary "s" \
    --changes "repo (new, commit abc)" --changes "x.py,y.py" >/dev/null
python3 - <<EOF
import json, glob, sys
events = [json.loads(l) for l in open(glob.glob(".relay/data/split-$$.jsonl")[0])]
end = [e for e in events if e["type"] == "end"][0]
if end.get("changes") != ["repo (new, commit abc)", "x.py", "y.py"]:
    print("FAIL: changes not parsed as expected: %r" % end.get("changes"), file=sys.stderr)
    sys.exit(1)
EOF
pass "commas inside brackets do not break field parsing"

# --- show prints one task in full -------------------------------------------
OUT=$(./.relay/relay --session "show-$$" show "$TASK")
echo "$OUT" | grep -q "why this task exists" || fail "show did not print the goal"
echo "$OUT" | grep -q "deadlock in migrate" || fail "show did not print the note"
echo "$OUT" | grep -q "advisory lock" || fail "show did not print the problems"
echo "$OUT" | grep -q "n=200" || fail "show did not print the metrics"
pass "show prints the full task"

# --- notes are visible to other sessions ------------------------------------
OUT=$(./.relay/relay --agent reader --session "reader-$$" sync)
echo "$OUT" | grep -q "deadlock in migrate" || fail "sync did not show the note"
pass "sync shows notes of other sessions"

# --- oversized events stay valid JSON ---------------------------------------
python3 - <<EOF
import json, subprocess, glob, sys
big = "x" * 300
args = ["./.relay/relay", "--agent", "big", "--session", "big-$$", "start", "big task"]
for _ in range(12):
    args += ["--plan", big]
for _ in range(30):
    args += ["--scope", big]
subprocess.run(args, check=True, capture_output=True)
path = glob.glob(".relay/data/big-$$.jsonl")[0]
for line in open(path):
    e = json.loads(line)   # must not raise
    if e["type"] == "start":
        assert e.get("trimmed") is True, "oversized event was not flagged as trimmed"
EOF
pass "oversized events stay valid JSON and are flagged"

# --- old schema v1 events still render -------------------------------------
printf '%s\n' '{"id": "old-1", "ts": "2026-10-19T10:00:00Z", "type": "start", "session": "legacy", "agent": "legacy", "cwd": ".", "branch": "main", "head": "abc1234", "title": "legacy task", "scope": ["src/legacy"]}' > .relay/data/legacy.jsonl
OUT=$(./.relay/relay --agent reader2 --session "reader2-$$" sync --all)
echo "$OUT" | grep -q "legacy task" || fail "schema v1 events no longer render"
pass "schema v1 events still render"

# --- uninstall dry run -----------------------------------------------------
"$ROOT/scripts/uninstall.sh" --target "$P" --dry-run >/dev/null
contains "BEGIN relay-logs" "$P/AGENTS.md"
[ -d "$P/.relay" ] || fail "uninstall dry run removed .relay"
pass "uninstall dry run leaves the target untouched"

# --- uninstall -------------------------------------------------------------
"$ROOT/scripts/uninstall.sh" --target "$P" >/dev/null
not_contains "BEGIN relay-logs" "$P/AGENTS.md"
not_contains "BEGIN relay-logs" "$P/CLAUDE.md"
not_contains ".relay/" "$P/.gitignore"
[ ! -e "$P/.relay" ] || fail ".relay still present after uninstall"
ls -d "$P"/.relay.removed-* >/dev/null 2>&1 || fail "uninstall did not preserve .relay/ as .relay.removed-*"
contains "Existing project rule: keep me." "$P/AGENTS.md"
contains "Existing Claude rule: keep me too." "$P/CLAUDE.md"
pass "uninstall removes markers and preserves logs"

# --- idempotent uninstall --------------------------------------------------
"$ROOT/scripts/uninstall.sh" --target "$P" >/dev/null
pass "uninstall is idempotent"

# --- purge and created-file cleanup ---------------------------------------
P2="$TMP/project2"
mkdir -p "$P2"
"$ROOT/scripts/install.sh" --target "$P2" >/dev/null
[ -f "$P2/AGENTS.md" ] || fail "install did not create AGENTS.md in an empty target"
[ -f "$P2/CLAUDE.md" ] || fail "install did not create CLAUDE.md in an empty target"
"$ROOT/scripts/uninstall.sh" --target "$P2" --purge >/dev/null
[ ! -e "$P2/.relay" ] || fail "--purge left .relay behind"
[ ! -e "$P2/AGENTS.md" ] || fail "uninstall did not delete installer-created AGENTS.md"
[ ! -e "$P2/CLAUDE.md" ] || fail "uninstall did not delete installer-created CLAUDE.md"
pass "purge and created-file cleanup"

# --- marker safety ---------------------------------------------------------
P3="$TMP/project3"
mkdir -p "$P3"
printf '# AGENTS.md\n\n<!-- BEGIN relay-logs -->\nbroken\n' > "$P3/AGENTS.md"
if "$ROOT/scripts/install.sh" --target "$P3" >/dev/null 2>&1; then
    fail "install should refuse unbalanced markers"
fi
pass "install refuses to edit unbalanced markers"

echo "all tests passed"
