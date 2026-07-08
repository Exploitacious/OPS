#!/usr/bin/env bash
# ac-register.test.sh — runnable test suite for ac-register's agent claim path.
#
# Regression test for the check-then-write name-claim race in cmd_register's
# agent branch: pick_agent_name -> is_claimed -> write_manifest used to run
# unlocked, so two concurrent `ac-register --role agent` calls could both
# pass is_claimed on the same free name before either had written a
# manifest, and both would "win" the same identity. write_manifest itself
# is atomic (tmp+mv) — the race was in the claim, not the write.
#
# Builds a self-contained scratch fixture (fake AC_FLEET + AC_ROOT under
# mktemp), NEVER touches any live fleet/project runtime, then asserts:
#   - sequential sanity: a single registration claims the expected name
#   - concurrency: N (>=8) concurrent auto-name registrations against a
#     pool sized to exactly N all succeed and claim UNIQUE names — no two
#     manifests share an identity, and manifest count == N
#   - the lock artifact (manifest.d/.register.lock) exists after a run,
#     as a tripwire in case a future edit silently drops the locking
#
# Run:  bash ~/OPS/WORKFORCE/bin/ac-register.test.sh
# Exit: 0 = all pass; non-zero on first failure.
set -uo pipefail

GEN="$(cd "$(dirname "$0")" && pwd)/ac-register"
[ -x "$GEN" ] || { echo "FAIL: ac-register not executable at $GEN" >&2; exit 1; }

command -v flock >/dev/null 2>&1 || {
  echo "FAIL: flock not installed — required for the claim lock under test" >&2
  exit 1
}

TDIR="$(mktemp -d "${TMPDIR:-/tmp}/ac-register-test.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- Scratch fixture: fake fleet root with its own name-pool.md. ------------
FLEET="$TDIR/fleet"
mkdir -p "$FLEET/personalities"
cat > "$FLEET/personalities/name-pool.md" <<'EOF'
# Name Pool (test fixture)

## Coordinators

1. Captain
2. Marshal

## Agents

1. Alfa
2. Bravo
3. Charlie
4. Delta
5. Echo
6. Foxtrot
7. Golf
8. Hotel
9. India
10. Juliet

## Scope tags
EOF

export AC_FLEET="$FLEET"

# =============================================================================
# Test 1: sequential sanity — one registration claims the first pool name.
# =============================================================================
ROOT1="$TDIR/root-seq"
export AC_ROOT="$ROOT1"

GOT="$("$GEN" --role agent 2>"$TDIR/seq.err")"; rc=$?
[ "$rc" -eq 0 ] || fail "sequential registration exited $rc: $(cat "$TDIR/seq.err")"
[ "$GOT" = "Alfa" ] || fail "expected first pool name 'Alfa', got '$GOT'"
[ -f "$ROOT1/runtime/manifest.d/Alfa.json" ] || fail "manifest not written for Alfa"
pass "sequential: single registration claims expected name + writes manifest"

unset AC_ROOT

# =============================================================================
# Test 2: concurrency — N(=10) concurrent auto-name registrations against a
# pool of exactly 10 names must all succeed with UNIQUE names claimed.
# =============================================================================
ROOT2="$TDIR/root-race"
export AC_ROOT="$ROOT2"
N=10
OUTDIR="$TDIR/race-out"
mkdir -p "$OUTDIR"

pids=()
for i in $(seq 1 "$N"); do
  ( AC_SESSION_ID="race-$i-$$" "$GEN" --role agent \
      > "$OUTDIR/$i.out" 2>"$OUTDIR/$i.err" ) &
  pids+=("$!")
done

fail_wait=0
for pid in "${pids[@]}"; do
  wait "$pid" || fail_wait=1
done
[ "$fail_wait" -eq 0 ] || {
  echo "--- stderr from failed jobs ---" >&2
  cat "$OUTDIR"/*.err >&2
  fail "one or more concurrent registrations exited non-zero (pool sized to N, all should succeed)"
}

NAMES="$(cat "$OUTDIR"/*.out | grep -v '^$')"
TOTAL=$(printf '%s\n' "$NAMES" | wc -l)
UNIQUE=$(printf '%s\n' "$NAMES" | sort -u | wc -l)

[ "$TOTAL" -eq "$N" ] || fail "expected $N names returned, got $TOTAL:
$NAMES"
[ "$UNIQUE" -eq "$N" ] || fail "duplicate name claimed under concurrency: $UNIQUE unique of $N returned:
$(printf '%s\n' "$NAMES" | sort | uniq -c | sort -rn)"
pass "concurrency: $N concurrent registrations against a $N-slot pool all claimed unique names"

MANIFEST_COUNT=$(find "$ROOT2/runtime/manifest.d" -maxdepth 1 -name '*.json' | wc -l)
[ "$MANIFEST_COUNT" -eq "$N" ] || fail "expected $N manifest files, found $MANIFEST_COUNT"
pass "concurrency: manifest count matches N (no lost or double writes)"

[ -f "$ROOT2/runtime/manifest.d/.register.lock" ] || \
  fail "lock artifact missing — claim critical section may no longer be locked"
pass "lock artifact present (tripwire: locking wasn't silently dropped)"

unset AC_ROOT

echo
echo "ALL TESTS PASSED"
