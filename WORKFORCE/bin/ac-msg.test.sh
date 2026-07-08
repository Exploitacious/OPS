#!/usr/bin/env bash
# ac-msg.test.sh — runnable test suite for ac-msg's bound_root guard.
#
# Builds a self-contained scratch AC_ROOT in a mktemp dir (NEVER touches any
# live FLEETPROJECTS runtime), hand-writes sender manifests to cover the
# three bound_root shapes, then asserts cmd_send:
#   - matching bound_root                 -> send succeeds, message lands
#   - mismatched bound_root               -> dies, "wrong project" error
#   - manifest missing bound_root (legacy) -> dies, "re-register" error
#     (regression test for the legacy-passthrough hole: IDEAS.md
#     "Cross-project AC_ROOT bound_root check has legacy-passthrough hole")
#
# Run:  bash ~/OPS/WORKFORCE/bin/ac-msg.test.sh
# Exit: 0 = all pass; non-zero on first failure.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)/ac-msg"
[ -x "$BIN" ] || { echo "FAIL: ac-msg not executable at $BIN" >&2; exit 1; }

TDIR="$(mktemp -d "${TMPDIR:-/tmp}/ac-msg-test.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Each case gets its own AC_ROOT so a stray inbox/manifest write from one
# case can never leak into another.
ROOT_A="$TDIR/proj-a"
ROOT_B="$TDIR/proj-b"
ROOT_C="$TDIR/proj-c"
OTHER_ROOT="$TDIR/proj-other"   # the "elsewhere" bound_root for the mismatch case

mkdir -p "$ROOT_A/runtime/manifest.d" \
         "$ROOT_B/runtime/manifest.d" \
         "$ROOT_C/runtime/manifest.d"

# --- Case (a): manifest WITH matching bound_root -> send succeeds. ----------
cat > "$ROOT_A/runtime/manifest.d/Alice.json" <<EOF
{
  "name": "Alice",
  "role": "agent",
  "status": "ready",
  "bound_root": "$ROOT_A"
}
EOF

OUT="$(AC_ROOT="$ROOT_A" "$BIN" send --from Alice --to Bob --topic case-a-matching </dev/null 2>"$TDIR/err-a")"
rc=$?
[ "$rc" -eq 0 ] || fail "case (a) expected exit 0, got $rc: $(cat "$TDIR/err-a")"
ID="$OUT"
[ -f "$ROOT_A/runtime/inbox/Bob/${ID}.md" ] || fail "case (a) message not delivered to Bob's inbox"
pass "matching bound_root: send succeeds and message lands"

# --- Case (b): manifest WITH mismatched bound_root -> dies, wrong-project. --
cat > "$ROOT_B/runtime/manifest.d/Carol.json" <<EOF
{
  "name": "Carol",
  "role": "agent",
  "status": "ready",
  "bound_root": "$OTHER_ROOT"
}
EOF

set +e
OUT="$(AC_ROOT="$ROOT_B" "$BIN" send --from Carol --to Bob --topic case-b-mismatch </dev/null 2>"$TDIR/err-b")"
rc=$?
set -e 2>/dev/null || true
[ "$rc" -ne 0 ] || fail "case (b) expected non-zero exit, got 0"
grep -qi "wrong project" "$TDIR/err-b" || fail "case (b) missing 'wrong project' error: $(cat "$TDIR/err-b")"
[ ! -d "$ROOT_B/runtime/inbox/Bob" ] || fail "case (b) message must not be delivered"
pass "mismatched bound_root: dies with wrong-project error"

# --- Case (c): manifest WITHOUT bound_root (legacy) -> dies, re-register. --
cat > "$ROOT_C/runtime/manifest.d/Dave.json" <<EOF
{
  "name": "Dave",
  "role": "agent",
  "status": "ready"
}
EOF

set +e
OUT="$(AC_ROOT="$ROOT_C" "$BIN" send --from Dave --to Bob --topic case-c-legacy </dev/null 2>"$TDIR/err-c")"
rc=$?
set -e 2>/dev/null || true
[ "$rc" -ne 0 ] || fail "case (c) expected non-zero exit, got 0"
grep -qi "re-register" "$TDIR/err-c" || fail "case (c) missing 're-register' error: $(cat "$TDIR/err-c")"
grep -qi "bound_root" "$TDIR/err-c" || fail "case (c) error should name bound_root: $(cat "$TDIR/err-c")"
[ ! -d "$ROOT_C/runtime/inbox/Bob" ] || fail "case (c) message must not be delivered (legacy-passthrough hole)"
pass "legacy manifest without bound_root: dies with re-register error"

echo
echo "ALL TESTS PASSED"
