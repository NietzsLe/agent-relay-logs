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
contains() { grep -qF -- "$1" "$2" || fail "$2 is missing: $1"; }
not_contains() { ! grep -qF -- "$1" "$2" || fail "$2 still contains: $1"; }
count() { grep -cF -- "$1" "$2" 2>/dev/null || true; }

# print every event of a session (the log is one file per day, shared)
events_of() { python3 - "$1" <<'EOF'
import json, glob, sys
want = sys.argv[1]
for path in sorted(glob.glob(".relay/data/*.jsonl")):
    for line in open(path):
        e = json.loads(line)
        if e.get("session") == want:
            print(json.dumps(e, ensure_ascii=False))
EOF
}

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
./.relay/relay --agent tester --session "$SID" end --status done --summary "finished" --verify "ok" --changes src/a >/dev/null
./.relay/relay --agent tester --session "$SID" start "second task" --scope src/b >/dev/null

SID2="test2-$$"
OUT=$(./.relay/relay --agent other --session "$SID2" sync)
echo "$OUT" | grep -q "second task" || fail "sync did not show the open task"
OUT2=$(./.relay/relay --agent other --session "$SID2" sync)
[ -z "$OUT2" ] || fail "second sync should be empty, got: $OUT2"
./.relay/relay --agent tester --session "$SID" end --status done --summary "finished again" --verify "ok" >/dev/null
./.relay/relay doctor >/dev/null
pass "relay start/end/sync/doctor"

# --- v3.1: quality nudges, open, and end gate ---------------------------
SID3="test3-$$"
ERR=$(./.relay/relay --agent tester --session "$SID3" start "thin task" 2>&1 >/dev/null)
echo "$ERR" | grep -q -- "--plan" || fail "thin start gave no nudge"
./.relay/relay open | grep -q "thin task" || fail "open did not list the open task"
if ./.relay/relay --agent tester --session "$SID3" end --status done >/dev/null 2>"$TMP/gate.err"; then
    fail "end without --verify should fail the gate"
fi
grep -q "GATE" "$TMP/gate.err" || fail "gate gave no GATE message"
./.relay/relay --session "$SID3" end --status done --summary "s" --verify "ok" --force >/dev/null
events_of "$SID3" | grep -q '"forced": true' || fail "--force did not record forced=true"
events_of "$SID3" | python3 -c 'import json,sys
ends = [json.loads(l) for l in sys.stdin if json.loads(l)["type"] == "end"]
last = ends[-1]
assert last.get("forced") is True, "not forced"
assert last.get("gate"), "re-close lost the original gate"
assert last.get("verify") == ["ok"], "re-close lost the new verify"
' || fail "--force re-close did not preserve gate/detail"
./.relay/relay open | grep -q "thin task" && fail "open still lists a closed task"
./.relay/relay open --stale | grep -q "no stale" || fail "open --stale should be empty"
pass "quality nudges, open, and end gate"

# --- schema v3: detail in every event type ---------------------------------
P4="$TMP/project4"
mkdir -p "$P4"
"$ROOT/scripts/install.sh" --target "$P4" >/dev/null
cd "$P4"
S4="v3-$$"
./.relay/relay --agent tester2 --session "$S4" start "task v3" \
    --goal "why this task exists" --plan "step one" --plan "step two" \
    --scope "src/a.py,src/b.py" --tags "perf,db" --accept "tests green" --refs "T-65,L-42" >/dev/null
TASK=$(events_of "$S4" | python3 -c 'import json,sys
for line in sys.stdin:
    e = json.loads(line)
    if e["type"] == "start":
        print(e["id"]); break')
[ -n "$TASK" ] || fail "no task id written"

./.relay/relay --session "$S4" note --kind problem --text "deadlock in migrate" \
    --detail "ERROR: lock wait timeout" >/dev/null
./.relay/relay --session "$S4" end --status done \
    --summary "everything works now" --done "applied advisory lock" \
    --problem "deadlock => advisory lock" --verify "pytest green" \
    --metric "p50 120ms -> 40ms (n=200, window=10m)" \
    --changes "src/a.py, src/b.py" --commit "abc1234" --next "T-66" --lesson "L-42" \
    --impact "needs deploy" >/dev/null

events_of "$S4" | python3 -c '
import json, sys
by = {}
for line in sys.stdin:
    e = json.loads(line)
    by.setdefault(e["type"], []).append(e)
errs = []
def check(cond, msg):
    if not cond:
        errs.append(msg)
start = by["start"][0]
end = by["end"][0]
note = by["note"][0]
check(start.get("goal") == "why this task exists", "goal not stored")
check(start.get("plan") == ["step one", "step two"], "plan not stored: %r" % start.get("plan"))
check(start.get("scope") == ["src/a.py", "src/b.py"], "scope not split: %r" % start.get("scope"))
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
'
pass "every event type stores its detail"

# --- one file per day, shared by every session ------------------------------
DAYFILES=$(ls .relay/data/*.jsonl 2>/dev/null | wc -l)
[ "$DAYFILES" = "1" ] || fail "expected 1 data file per day, found $DAYFILES"
ls .relay/data/*.jsonl | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}\.jsonl$' \
    || fail "data file is not named YYYY-MM-DD.jsonl"
[ -f ".relay/cursors/$S4.json" ] || fail "cursor is not in cursors/<session>.json"
pass "one file per day, cursors in their own directory"

# --- a session never sees its own events as somebody else's news -------------
OUT=$(./.relay/relay --agent tester2 --session "$S4" sync --all)
echo "$OUT" | grep -q "task v3" && fail "a session saw its own task in sync"
pass "sync hides a session's own events"

# --- migration from the old per-session layout ------------------------------
P5="$TMP/project5"
mkdir -p "$P5/.relay/data"
cp "$ROOT/package/relay" "$P5/.relay/relay"
chmod +x "$P5/.relay/relay"
printf '%s\n' '{"id": "old-1", "ts": "2026-10-19T10:00:00Z", "type": "start", "session": "legacy", "agent": "legacy", "cwd": ".", "branch": "main", "head": "abc1234", "title": "legacy task", "scope": ["src/legacy"]}' > "$P5/.relay/data/legacy-session.jsonl"
cd "$P5"
./.relay/relay --agent tester --session "post-migrate-$$" start "after migration" >/dev/null
[ -f ".relay/data/legacy/legacy-session.jsonl" ] || fail "legacy file was not moved to data/legacy/"
grep -q "legacy task" .relay/data/2026-10-19.jsonl || fail "legacy events were not folded into the day file"
OUT=$(./.relay/relay --agent reader3 --session "reader3-$$" sync --all)
echo "$OUT" | grep -q "legacy task" || fail "migrated v1 events do not render"
pass "legacy per-session files migrate into the day file"

# --- smart comma splitting --------------------------------------------------
cd "$P4"
./.relay/relay --agent tester3 --session "split-$$" start "split test" --scope "x.py,y.py,repo (new, commit abc)" >/dev/null
./.relay/relay --session "split-$$" end --status done --summary "s" --verify "ok" \
    --changes "repo (new, commit abc)" --changes "x.py,y.py" >/dev/null
events_of "split-$$" | python3 -c '
import json, sys
end = [json.loads(l) for l in sys.stdin if json.loads(l)["type"] == "end"][0]
if end.get("changes") != ["repo (new, commit abc)", "x.py", "y.py"]:
    print("FAIL: changes not parsed as expected: %r" % end.get("changes"), file=sys.stderr)
    sys.exit(1)
'
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

# --- a note can still be attached after the task was closed -----------------
./.relay/relay --session "$S4" note --kind result --text "correction: number was wrong" >/dev/null
events_of "$S4" | grep -q "correction" || fail "note after end was not attached to the session's last task"
# my own session's last task wins over other sessions' open tasks of the same agent
./.relay/relay --agent tester2 --session "noisy-$$" start "unrelated open task" >/dev/null
./.relay/relay --session "$S4" note --kind result --text "second correction" >/dev/null \
    || fail "note on a closed session failed when the agent has other open tasks"
events_of "$S4" | grep -q "second correction" || fail "note landed on the wrong task"
pass "note after end attaches to the last task of the session"

# --- oversized events stay valid JSON ---------------------------------------
python3 - <<EOF
import json, subprocess, glob
big = "x" * 300
args = ["./.relay/relay", "--agent", "big", "--session", "big-$$", "start", "big task"]
for _ in range(12):
    args += ["--plan", big]
for _ in range(30):
    args += ["--scope", big]
subprocess.run(args, check=True, capture_output=True)
found = False
for path in glob.glob(".relay/data/*.jsonl"):
    for line in open(path):
        e = json.loads(line)   # must not raise
        if e["type"] == "start" and e.get("session") == "big-$$":
            assert e.get("trimmed") is True, "oversized event was not flagged as trimmed"
            found = True
assert found, "the oversized start event was not written"
EOF
pass "oversized events stay valid JSON and are flagged"

# --- v4: rhythm, scope, long commands, score ----------------------------------
P6="$TMP/project6"
mkdir -p "$P6"
"$ROOT/scripts/install.sh" --target "$P6" >/dev/null
cd "$P6"
git init -q .
git add .
git -c user.name=test -c user.email=test@example.com commit -qm "initial"
V4="v4-$$"
TASKV4=$(./.relay/relay --agent tester4 --session "$V4" start "rhythm task" \
    --goal "g" --plan "p1" --scope "tracked.txt" --accept "a" \
    | grep "^task=" | cut -d= -f2)
[ -n "$TASKV4" ] || fail "v4 start printed no task id"
echo tracked > tracked.txt
./.relay/relay --session "$V4" note --kind progress --text "did step one" \
    --next "step two" --where "tracked.txt:10" >/dev/null
events_of "$V4" | grep -q '"next": "step two"' || fail "note --next not stored"
events_of "$V4" | grep -q '"where": \["tracked.txt:10"\]' || fail "note --where not stored"

# scope drift: an unlogged file change must trip tick (exit 2)
echo change > outside.txt
set +e
./.relay/relay --session "$V4" tick >"$TMP/tick1.out" 2>&1
TICK1=$?
set -e
[ "$TICK1" = 2 ] || fail "tick should flag files outside the scope (exit=$TICK1)"
grep -q "ngoài scope" "$TMP/tick1.out" || fail "tick gave no scope message"
./.relay/relay --session "$V4" scope --add "outside.txt" --why "needed too" >/dev/null
set +e
./.relay/relay --session "$V4" tick >"$TMP/tick2.out" 2>&1
TICK2=$?
set -e
[ "$TICK2" = 0 ] || fail "tick after scope --add should pass (exit=$TICK2)"
grep -q "ngoài scope" "$TMP/tick2.out" && fail "drift persists after scope --add"

# run --record: late and over are computed with tolerance both ways
./.relay/relay --session "$V4" run --record --cmd "sleep 60" --eta 1m --actual 70s --exit 0 >/dev/null
./.relay/relay --session "$V4" run --eta 5m -- sleep 1 >/dev/null
./.relay/relay board | grep -q "rhythm task" || fail "board did not list the open task"
./.relay/relay board | grep -q "step two" || fail "board did not show the next step"
sleep 2
set +e
RELAY_GAP_MAX=1 RELAY_NUDGE=0 ./.relay/relay --session "$V4" tick >"$TMP/tick3.out" 2>&1
TICK3=$?
set -e
[ "$TICK3" = 2 ] || fail "tick should flag silence past a 1s limit (exit=$TICK3)"
grep -q "chưa ghi" "$TMP/tick3.out" || fail "tick gave no silence message"

# guard --stop: once, and never against an explicit ack
echo '{"stop_hook_active": true}' | ./.relay/relay --session "$V4" guard --stop >/dev/null \
    || fail "guard with stop_hook_active should pass"
set +e
RELAY_GAP_MAX=1 ./.relay/relay --session "$V4" guard --stop >"$TMP/guard.out" 2>&1
GUARD=$?
set -e
[ "$GUARD" = 2 ] || fail "guard should block when silent too long (exit=$GUARD)"

# --key maps a harness session to a relay session
./.relay/relay --agent tester4 --key "key-$$" start "keyed task" --scope tracked.txt >/dev/null
[ -f ".relay/keys/key-$$.json" ] || fail "key mapping not saved"
./.relay/relay --key "key-$$" note --kind progress --text "via key" >/dev/null \
    || fail "note --key failed"
KSES=$(python3 -c "import json; print(json.load(open('.relay/keys/key-$$.json'))['session'])")
events_of "$KSES" | grep -q "via key" || fail "note via --key landed in the wrong session"
./.relay/relay --key "key-$$" run --record --cmd "sleep 60" --eta 1m --actual 200s --exit 0 >/dev/null
events_of "$KSES" | grep -q '"late_s": 80' || fail "late_s not computed (200s vs eta 1m)"
./.relay/relay --key "key-$$" run --record --cmd "quick" --eta 10m --actual 60s --exit 0 >/dev/null
events_of "$KSES" | grep -q '"over_s": 90' || fail "over_s not computed (60s vs eta 10m)"
./.relay/relay --key "key-$$" run --record --cmd "undeclared" --actual 200s --exit 0 >/dev/null
events_of "$KSES" | grep -q '"late_s": 80' || fail "undeclared 200s run should count late_s=80"

# end records the score; show prints it
./.relay/relay --session "$V4" end --status done --summary "done it" --done "d1" \
    --verify "pytest ok" --changes "tracked.txt,outside.txt" >/dev/null
OUT=$(./.relay/relay --session "show-$$" show "$TASKV4")
echo "$OUT" | grep -q "score: " || fail "show did not print the score"
echo "$OUT" | grep -q "step two" || fail "show did not print the note next step"
echo "$OUT" | grep -q "tracked.txt:10" || fail "show did not print the note where"
./.relay/relay stats | grep -q "score TB" || fail "stats printed no scoreboard"
pass "rhythm, scope, long commands, score, keys, guard"

# --- porcelain's leading column must survive -------------------------------
# regression: git()'s whole-output strip() ate the " M file" leading space,
# so the first changed file parsed as "racked.txt" and tick cried drift
rm -f outside.txt
echo more >> tracked.txt
./.relay/relay --agent tester4 --key "key2-$$" start "porcelain test" --scope tracked.txt >/dev/null
./.relay/relay --key "key2-$$" tick >/dev/null \
    || fail "tick flagged an in-scope change (porcelain parse bug)"
./.relay/relay --key "key2-$$" end --status done --summary "ok" --verify "tick green" >/dev/null
pass "porcelain leading column survives"

# --- hooks install/uninstall -------------------------------------------------
P7="$TMP/project7"
mkdir -p "$P7"
"$ROOT/scripts/install.sh" --target "$P7" --hooks >/dev/null
[ -f "$P7/.opencode/plugins/opencode-nudge.js" ] || fail "opencode plugin not installed"
python3 -c "import json; d=json.load(open('$P7/.claude/settings.local.json')); assert 'relay tick --hook' in json.dumps(d), 'tick hook missing'; assert 'relay guard --stop' in json.dumps(d), 'guard hook missing'" \
    || fail "claude hooks not merged"
"$ROOT/scripts/install.sh" --target "$P7" --hooks >/dev/null
python3 -c "import json; d=json.load(open('$P7/.claude/settings.local.json')); assert json.dumps(d).count('relay tick --hook') == 2, 'hooks not idempotent'" \
    || fail "hook install is not idempotent"
"$ROOT/scripts/uninstall.sh" --target "$P7" >/dev/null
[ ! -e "$P7/.opencode/plugins/opencode-nudge.js" ] || fail "uninstall left the plugin behind"
python3 -c "import json,os; p='$P7/.claude/settings.local.json'; assert not os.path.exists(p) or 'relay tick' not in open(p).read(), 'hooks left behind'" \
    || fail "uninstall left claude hooks behind"
pass "hooks install and uninstall"

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

# --- v4.2: browser + image delegation guidance in fresh installs -----------------
P8="$TMP/project8"
mkdir -p "$P8"
"$ROOT/scripts/install.sh" --target "$P8" >/dev/null
contains "claude --chrome" "$P8/AGENTS.md"
contains "codex exec" "$P8/AGENTS.md"
contains "-i ./ref.png" "$P8/AGENTS.md"
contains "generated_images" "$P8/AGENTS.md"
contains "relay-logs agents-block v4" "$P8/AGENTS.md"
contains "claude --chrome" "$P8/CLAUDE.md"
contains "codex exec" "$P8/CLAUDE.md"
contains "relay-logs claude-block v4" "$P8/CLAUDE.md"
python3 -c "import json; d=json.load(open('$P8/.relay/install.json')); assert d.get('block_versions',{}).get('AGENTS.md')==4, d.get('block_versions'); assert d.get('block_versions',{}).get('CLAUDE.md')==4" \
    || fail "manifest has no block_versions"
pass "fresh installs teach browser and image delegation and stamp block versions"

# --- v4.2: legacy (unstamped) blocks upgrade in place ----------------------
P9="$TMP/project9"
mkdir -p "$P9"
printf '# AGENTS.md\n\nKeep this line.\n\n<!-- BEGIN relay-logs -->\n## Relay — old text\n<!-- END relay-logs -->\n' > "$P9/AGENTS.md"
OUT=$("$ROOT/scripts/install.sh" --target "$P9" 2>&1)
echo "$OUT" | grep -q "unversioned -> v4" || fail "upgrade did not report unversioned -> v4: $OUT"
contains "claude --chrome" "$P9/AGENTS.md"
contains "codex exec" "$P9/AGENTS.md"
contains "relay-logs agents-block v4" "$P9/AGENTS.md"
contains "Keep this line." "$P9/AGENTS.md"
[ "$(count "BEGIN relay-logs" "$P9/AGENTS.md")" = "1" ] || fail "upgrade duplicated the block"
pass "legacy blocks upgrade to the versioned template, user text kept"

# --- v4.2: doctor flags outdated blocks, reinstall is a no-op when current -
sed -i 's/relay-logs agents-block v4/relay-logs agents-block v1/' "$P9/AGENTS.md"
OUT=$("$ROOT/scripts/relay_setup.py" doctor --target "$P9" 2>&1)
echo "$OUT" | grep -q "outdated" || fail "doctor did not flag the outdated block"
OUT=$("$ROOT/scripts/install.sh" --target "$P9" 2>&1)
echo "$OUT" | grep -q "v1 -> v4" || fail "reinstall did not report v1 -> v4: $OUT"
OUT2=$("$ROOT/scripts/install.sh" --target "$P9" 2>&1)
echo "$OUT2" | grep -q "unchanged (already v4)" || fail "second install is not a no-op: $OUT2"
[ "$(count "BEGIN relay-logs" "$P9/AGENTS.md")" = "1" ] || fail "reinstall duplicated the block"
pass "doctor flags outdated blocks; reinstall upgrades once, then is a no-op"

# --- v4.2: version constants stay in sync across runtime/templates/registry --
python3 - "$ROOT" <<'EOF'
import re, sys
root = sys.argv[1]
relay = open(root + "/package/relay", encoding="utf-8").read()
setup = open(root + "/scripts/relay_setup.py", encoding="utf-8").read()
tmpl = {}
for name in ("agents-block.md", "claude-block.md"):
    text = open(root + "/templates/" + name, encoding="utf-8").read()
    m = re.search(r"relay-logs\s+\S+\s+v(\d+)", text)
    assert m, "template %s has no version stamp" % name
    tmpl[name] = int(m.group(1))
reg = {}
for line in open(root + "/templates/VERSIONS", encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    fname, ver = line.split()
    reg[fname] = int(ver.lstrip("v"))
m1 = re.search(r"^BLOCK_VERSION\s*=\s*(\d+)", relay, re.M)
assert m1, "relay has no BLOCK_VERSION"
rbv = int(m1.group(1))
assert set(tmpl) == set(reg), "VERSIONS registry does not cover all templates"
assert all(v == rbv for v in tmpl.values()), "template stamps disagree: %r" % tmpl
assert all(v == rbv for v in reg.values()), "registry disagrees: %r" % reg
print("runtime BLOCK_VERSION=%d templates=%r registry=%r" % (rbv, tmpl, reg))
EOF
pass "runtime, templates, and registry agree on the block version"

# --- board reports block status; outdated blocks are flagged in-session ----
P10="$TMP/project10"
mkdir -p "$P10"
"$ROOT/scripts/install.sh" --target "$P10" >/dev/null
cd "$P10"
git init -q . 2>/dev/null || true
OUT=$(./.relay/relay --agent probe --session "probe-$$" board 2>&1)
echo "$OUT" | grep -q "blocks: v4 OK" || fail "board did not report current blocks: $OUT"
sed -i 's/relay-logs agents-block v4/relay-logs agents-block v1/' AGENTS.md
OUT2=$(./.relay/relay --agent probe --session "probe2-$$" board 2>&1)
echo "$OUT2" | grep -qi "outdated" || fail "board did not flag the outdated block: $OUT2"
echo "$OUT2" | grep -q "AGENTS.md" || fail "board did not name the outdated file: $OUT2"
OUT3=$(./.relay/relay doctor 2>&1)
echo "$OUT3" | grep -q "OUTDATED" || fail "doctor did not flag the outdated block"
echo "$OUT3" | grep -q "up to date" || fail "doctor did not confirm the current block"
"$ROOT/scripts/install.sh" --target "$P10" >/dev/null
OUT4=$(./.relay/relay --agent probe --session "probe3-$$" board 2>&1)
echo "$OUT4" | grep -q "blocks: v4 OK" || fail "board not green after upgrade: $OUT4"
pass "board and doctor flag outdated blocks; upgrade closes the loop"

# --- audit coverage: multi-harness unlogged-session detection --------------
AUD="$TMP/audit-proj"
mkdir -p "$AUD/.relay/data"
cat > "$AUD/.relay/data/2026-10-21.jsonl" <<'EOF'
{"id": "t1", "ts": "2026-10-21T10:00:00Z", "type": "join", "session": "rs-covered", "agent": "opencode", "cwd": ".", "branch": "main", "head": "abc"}
{"id": "t2", "ts": "2026-10-21T10:01:00Z", "type": "start", "session": "rs-covered", "agent": "opencode", "title": "logged task", "scope": ["a.py"]}
{"id": "t3", "ts": "2026-10-21T10:05:00Z", "type": "end", "session": "rs-covered", "agent": "opencode", "status": "done", "summary": "ok", "verify": ["green"]}
EOF
AUDDB="$TMP/audit-opencode.db"
python3 - "$AUDDB" "$AUD" <<'EOF'
import sqlite3, sys
db, target = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
con.execute("CREATE TABLE session_v2 (id TEXT, title TEXT, agent TEXT, directory TEXT, time_created INTEGER, time_updated INTEGER)")
con.execute("CREATE TABLE session_message (session_id TEXT, type TEXT, data TEXT)")
# relay window is 10:00-10:05Z = 1792576800000-1792577100000 ms
con.execute("INSERT INTO session_v2 VALUES ('ses-logged','logged opencode task','build',?,1792576860000,1792577100000)", (target,))
con.execute("INSERT INTO session_message VALUES ('ses-logged','user','{\"text\":\"do work\"}')")
con.execute("INSERT INTO session_message VALUES ('ses-logged','assistant','{\"content\":[{\"type\":\"tool\"}]}')")
con.execute("INSERT INTO session_v2 VALUES ('ses-missed','missed image task','build',?,1792577280000,1792577400000)", (target,))
con.execute("INSERT INTO session_message VALUES ('ses-missed','user','{\"text\":\"gen image\"}')")
con.execute("INSERT INTO session_message VALUES ('ses-missed','assistant','{\"content\":[{\"type\":\"tool\"}]}')")
con.commit()
con.close()
EOF
# fake claude store: project dir name is the target path with / -> -
AUDCL="$TMP/audit-claude/$(printf '%s' "$AUD" | sed 's/\//-/g')"
mkdir -p "$AUDCL"
cat > "$AUDCL/aaaa1111.jsonl" <<'EOF'
{"type": "user", "sessionId": "aaaa1111", "timestamp": "2026-10-21T10:08:00.000Z", "message": {"content": "missed claude task"}}
{"type": "assistant", "sessionId": "aaaa1111", "timestamp": "2026-10-21T10:09:00.000Z", "content": [{"type": "tool_use"}]}
EOF
# fake codex store: rollout with session_meta cwd + user + exec line
AUDCX="$TMP/audit-codex/2026/10/21"
mkdir -p "$AUDCX"
CODEVTARGET="$AUD" python3 - "$AUDCX/rollout-test.jsonl" <<'EOF'
import json, os, sys
path = sys.argv[1]
cwd = os.environ["CODEVTARGET"]
with open(path, "w") as fh:
    fh.write(json.dumps({"type": "session_meta", "payload": {"id": "01a1miss", "cwd": cwd}}) + "\n")
    fh.write(json.dumps({"type": "response_item", "timestamp": "2026-10-21T10:12:00.000Z", "payload": {"role": "user", "content": [{"type": "input_text", "text": "hi"}]}}) + "\n")
    fh.write(json.dumps({"type": "event_msg", "timestamp": "2026-10-21T10:13:00.000Z", "payload": {"type": "exec_command_begin"}}) + "\n")
EOF
AUDOUT=$(OPENCODE_DB="$AUDDB" CLAUDE_PROJECTS_DIR="$TMP/audit-claude" CODEX_SESSIONS_DIR="$TMP/audit-codex" \
    python3 "$ROOT/scripts/audit_coverage.py" --target "$AUD" --since 2026-10-21 --until 2026-10-21 2>&1) \
    || true
echo "$AUDOUT" | grep -q "ses-missed" || fail "audit did not flag the unlogged opencode session"
echo "$AUDOUT" | grep -q "aaaa1111" || fail "audit did not flag the unlogged claude session"
echo "$AUDOUT" | grep -q "01a1miss" || fail "audit did not flag the unlogged codex session"
echo "$AUDOUT" | grep -q "ses-logged" && fail "audit flagged a covered session as unlogged"
OPENCODE_DB="$AUDDB" CLAUDE_PROJECTS_DIR="$TMP/audit-claude" CODEX_SESSIONS_DIR="$TMP/audit-codex" \
    python3 "$ROOT/scripts/audit_coverage.py" --target "$AUD" --since 2026-10-21 --until 2026-10-21 >/dev/null 2>&1 \
    && fail "audit should exit 1 when gaps exist"
OPENCODE_DB="$AUDDB" CLAUDE_PROJECTS_DIR="$TMP/audit-claude" CODEX_SESSIONS_DIR="$TMP/audit-codex" \
    python3 "$ROOT/scripts/audit_coverage.py" --target "$AUD" --since 2026-10-22 --until 2026-10-22 >/dev/null 2>&1 \
    || fail "audit should exit 0 when no harness session is in range"
pass "audit flags unlogged sessions across opencode/claude/codex stores"

# --- opencode nudge plugin stays valid JS (V2 contract) ---------------------
if command -v node >/dev/null 2>&1; then
    node --check "$ROOT/scripts/hooks/opencode-nudge.js" \
        || fail "opencode-nudge.js is not valid JS"
    pass "nudge plugin is valid JS"
fi
grep -q "export default" "$ROOT/scripts/hooks/opencode-nudge.js" \
    || fail "nudge plugin must have a default export (V2 contract)"
grep -q "Plugin.define" "$ROOT/scripts/hooks/opencode-nudge.js" \
    || fail "nudge plugin must use Plugin.define (V2 contract)"
grep -q 'id: "relay-nudge"' "$ROOT/scripts/hooks/opencode-nudge.js" \
    || fail "nudge plugin must define id relay-nudge"
grep -q "ctx.session.hook" "$ROOT/scripts/hooks/opencode-nudge.js" \
    || fail "nudge plugin must register a session hook"
grep -q "ctx.tool.hook" "$ROOT/scripts/hooks/opencode-nudge.js" \
    || fail "nudge plugin must register tool hooks"
grep -q "ctx.shell.hook" "$ROOT/scripts/hooks/opencode-nudge.js" \
    || fail "nudge plugin must register a shell hook"
if grep -q "RelayNudgePlugin" "$ROOT/scripts/hooks/opencode-nudge.js"; then
    fail "nudge plugin still exports the V1 RelayNudgePlugin symbol"
fi
if grep -q '"shell.env"' "$ROOT/scripts/hooks/opencode-nudge.js"; then
    fail "nudge plugin still uses the V1 shell.env hook key"
fi
pass "nudge plugin meets the V2 contract"

# --- v4.2: bump-blocks keeps templates, registry, and runtime in sync ------
"$ROOT/scripts/relay_setup.py" bump-blocks --to v4 --dry-run 2>&1 \
    | grep -q "already v4" || fail "bump-blocks --dry-run should report already-v4"
if "$ROOT/scripts/relay_setup.py" bump-blocks --to banana >/dev/null 2>&1; then
    fail "bump-blocks should reject a non-numeric version"
fi
DRY=$("$ROOT/scripts/relay_setup.py" bump-blocks --to v5 --dry-run 2>&1)
echo "$DRY" | grep -q "would update" || fail "bump-blocks --dry-run reported no updates for v5"
grep -q "relay-logs agents-block v4" "$ROOT/templates/agents-block.md" \
    || fail "dry run must not rewrite the agents stamp"
grep -q "^BLOCK_VERSION = 4$" "$ROOT/package/relay" \
    || fail "dry run must not rewrite BLOCK_VERSION"
pass "bump-blocks syncs stamps, registry, and runtime in one step"

echo "all tests passed"
