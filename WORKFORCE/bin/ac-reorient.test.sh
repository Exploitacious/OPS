#!/usr/bin/env bash
# ac-reorient.test.sh — runnable test suite for ac-reorient's solo gating +
# startup/compact source branching.
#
# Regression test for two bugs found by 2026-07-06 audit:
#   (1) startup source printed the full re-anchor dump on top of the
#       Quick-boot banner (fell through instead of exiting), so startup
#       output was BIGGER than compact/resume -- inverting the documented
#       "compact/resume = full re-anchor; startup = compact identity"
#       intent.
#   (2) plain solo sessions (no AC_NAME, no AC_ROOT) got the fleet
#       project-binding lecture on every single SessionStart, which is
#       noise outside fleet mode (foreman-charter.sh + session-briefing.sh
#       already cover solo posture).
#
# Builds a self-contained scratch AC_ROOT under mktemp (NEVER touches any
# live FLEETPROJECTS runtime), then asserts:
#   - solo env (AC_NAME/AC_ROOT both unset) + startup  -> zero-byte output
#   - solo env (AC_NAME/AC_ROOT both unset) + compact  -> zero-byte output
#   - fleet env + startup  -> small Quick-boot banner only (no full-dump
#     markers), byte count strictly less than fleet compact
#   - fleet env + compact  -> full re-anchor dump (Re-read order marker
#     present)
#   - fleet env + resume   -> full re-anchor dump too (same size as compact
#     -- resume is not "startup", so it must NOT get the short banner)
#   - partial state (AC_NAME set, AC_ROOT unset) -> unchanged: still shows
#     the fleet project-binding lecture (this path is untouched by the
#     solo-gating fix)
# All cases must also exit 0 (ac-reorient is a context surface, not a gate).
#
# Run:  bash ~/OPS/WORKFORCE/bin/ac-reorient.test.sh
# Exit: 0 = all pass; non-zero on first failure.
set -uo pipefail

GEN="$(cd "$(dirname "$0")" && pwd)/ac-reorient"
[ -x "$GEN" ] || { echo "FAIL: ac-reorient not executable at $GEN" >&2; exit 1; }

TDIR="$(mktemp -d "${TMPDIR:-/tmp}/ac-reorient-test.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Self-contained fleet fixture -- empty runtime tree is enough; ac-reorient
# tolerates missing subdirs (prints "(no ... dir)" placeholders for each).
FLEET_ROOT="$TDIR/fleet-project"
mkdir -p "$FLEET_ROOT/runtime/manifest.d"

# =============================================================================
# Case 1: solo env (AC_NAME/AC_ROOT both unset), source=startup -> 0 bytes.
# =============================================================================
OUT=$(env -i HOME="$HOME" PATH="$PATH" bash -c \
  'echo "{\"source\":\"startup\"}" | "'"$GEN"'"'); rc=$?
[ "$rc" -eq 0 ] || fail "solo+startup exited $rc (want 0)"
[ -z "$OUT" ] || fail "solo+startup produced output (want 0 bytes): $(printf '%s' "$OUT" | wc -c) bytes"
pass "solo env + startup -> zero-byte output, exit 0"

# =============================================================================
# Case 2: solo env, source=compact -> 0 bytes.
# =============================================================================
OUT=$(env -i HOME="$HOME" PATH="$PATH" bash -c \
  'echo "{\"source\":\"compact\"}" | "'"$GEN"'"'); rc=$?
[ "$rc" -eq 0 ] || fail "solo+compact exited $rc (want 0)"
[ -z "$OUT" ] || fail "solo+compact produced output (want 0 bytes): $(printf '%s' "$OUT" | wc -c) bytes"
pass "solo env + compact -> zero-byte output, exit 0"

# =============================================================================
# Case 3: fleet env, source=startup -> short Quick-boot banner ONLY.
# =============================================================================
OUT=$(AC_ROOT="$FLEET_ROOT" AC_NAME="Captain" bash -c \
  'echo "{\"source\":\"startup\"}" | "'"$GEN"'"'); rc=$?
STARTUP_LEN=$(printf '%s' "$OUT" | wc -c)
[ "$rc" -eq 0 ] || fail "fleet+startup exited $rc (want 0)"
[ -n "$OUT" ] || fail "fleet+startup produced no output (want Quick-boot banner)"
printf '%s' "$OUT" | grep -q "(startup)" || fail "fleet+startup missing '(startup)' banner marker"
printf '%s' "$OUT" | grep -q "Re-read order" && fail "fleet+startup leaked the full re-anchor dump (found 'Re-read order')"
pass "fleet env + startup -> Quick-boot banner only ($STARTUP_LEN bytes), no full-dump leak"

# =============================================================================
# Case 4: fleet env, source=compact -> full re-anchor dump, strictly bigger
# than the startup banner from Case 3 (this is the inversion regression).
# =============================================================================
OUT=$(AC_ROOT="$FLEET_ROOT" AC_NAME="Captain" bash -c \
  'echo "{\"source\":\"compact\"}" | "'"$GEN"'"'); rc=$?
COMPACT_LEN=$(printf '%s' "$OUT" | wc -c)
[ "$rc" -eq 0 ] || fail "fleet+compact exited $rc (want 0)"
printf '%s' "$OUT" | grep -q "Re-read order" || fail "fleet+compact missing full re-anchor dump marker 'Re-read order'"
[ "$COMPACT_LEN" -gt "$STARTUP_LEN" ] || \
  fail "inversion regression: fleet compact ($COMPACT_LEN B) not > fleet startup ($STARTUP_LEN B)"
pass "fleet env + compact -> full re-anchor dump ($COMPACT_LEN bytes), strictly larger than startup"

# =============================================================================
# Case 5: fleet env, source=resume -> also full re-anchor dump (same size as
# compact), NOT the short startup banner.
# =============================================================================
OUT=$(AC_ROOT="$FLEET_ROOT" AC_NAME="Captain" bash -c \
  'echo "{\"source\":\"resume\"}" | "'"$GEN"'"'); rc=$?
RESUME_LEN=$(printf '%s' "$OUT" | wc -c)
[ "$rc" -eq 0 ] || fail "fleet+resume exited $rc (want 0)"
[ "$RESUME_LEN" -eq "$COMPACT_LEN" ] || \
  fail "fleet resume ($RESUME_LEN B) != fleet compact ($COMPACT_LEN B) -- resume must get the full dump too"
pass "fleet env + resume -> full re-anchor dump, matches compact size"

# =============================================================================
# Case 6: partial state (AC_NAME set, AC_ROOT unset) -> untouched by the
# solo-gating fix; still shows the fleet project-binding lecture.
# =============================================================================
OUT=$(env -i HOME="$HOME" PATH="$PATH" AC_NAME="Captain" bash -c \
  'echo "{\"source\":\"startup\"}" | "'"$GEN"'"'); rc=$?
[ "$rc" -eq 0 ] || fail "partial-state exited $rc (want 0)"
printf '%s' "$OUT" | grep -q "No project bound yet" || \
  fail "partial state (AC_NAME set, AC_ROOT unset) lost its project-binding lecture"
pass "partial state (AC_NAME set, AC_ROOT unset) -> lecture banner unchanged"

echo
echo "ALL TESTS PASSED"
