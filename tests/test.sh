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
