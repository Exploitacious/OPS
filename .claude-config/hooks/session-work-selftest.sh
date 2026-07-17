#!/usr/bin/env bash
# session-work-selftest.sh — prove the session-start-stamp invariants the
# session-close WIP/work-tracking gate depends on. Run by hand or after deploy
# alongside guard-selftest.sh. Uses an isolated $HOME so it never touches the
# real ~/.claude-compact-cycle.
#
#   1. work_session_key is non-empty AND stable across calls.
#   2. First run with NO stamp writes one — on ANY SessionStart source,
#      including `resume` (a REVIVED archived session fires source=resume for
#      its whole life; if it didn't stamp on resume the gate would silently have
#      no t0 for the Archive close path — the regression this test locks out).
#   3. An existing FRESH stamp is NOT rewritten on a re-fire (write-if-absent
#      preserves the true t0 across compacts/resumes).
#
# Exit 0 = all invariants hold; 1 = a break.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
pass(){ printf '  PASS  %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

echo "session-work-selftest:"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
runinit(){ HOME="$T" bash "$DIR/session-work-init.sh"; }   # stdin = SessionStart payload

# 1. key stable + non-empty
. "$DIR/hooklib.sh"
k1="$(work_session_key)"; k2="$(work_session_key)"
if [ -n "$k1" ] && [ "$k1" = "$k2" ]; then pass "work_session_key stable + non-empty ($k1)"; else fail "work_session_key empty or unstable ('$k1' vs '$k2')"; fi

# 2a. startup, no stamp -> writes
rm -rf "$T/.claude-compact-cycle"
printf '{"source":"startup"}' | runinit
if ls "$T"/.claude-compact-cycle/session-start-* >/dev/null 2>&1; then pass "startup with no stamp writes a stamp"; else fail "startup did NOT write a stamp"; fi

# 2b. REGRESSION GUARD: resume with no stamp (revived session) -> MUST write
rm -rf "$T/.claude-compact-cycle"
printf '{"source":"resume"}' | runinit
if ls "$T"/.claude-compact-cycle/session-start-* >/dev/null 2>&1; then pass "revive (source=resume, no stamp) writes — revive-never-stamps guard"; else fail "revive did NOT stamp — the revive-never-stamps bug is back"; fi

# 3. existing fresh stamp preserved across a re-fire (write-if-absent)
rm -rf "$T/.claude-compact-cycle"
printf '{"source":"startup"}' | runinit
f="$(ls "$T"/.claude-compact-cycle/session-start-* 2>/dev/null | head -1)"
if [ -n "$f" ]; then
  echo "SENTINEL=keep" >> "$f"                  # a rewrite (> "$STAMP") would wipe this
  printf '{"source":"compact"}' | runinit
  if grep -q '^SENTINEL=keep' "$f" 2>/dev/null; then pass "existing fresh stamp preserved on re-fire (t0 intact)"; else fail "existing stamp was REWRITTEN — t0 clobbered on re-fire"; fi
else
  fail "could not create a stamp to test preservation"
fi

if [ "$fails" -eq 0 ]; then
  echo "session-work-selftest: ALL INVARIANTS HOLD"
  exit 0
else
  echo "session-work-selftest: $fails invariant(s) broken"
  exit 1
fi
