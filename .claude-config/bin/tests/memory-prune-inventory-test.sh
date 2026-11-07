#!/usr/bin/env bash
# memory-prune-inventory-test.sh: runnable test suite for the memory-prune
# skill's pool inventory (SKILLS/memory-prune/scripts/inventory).
#
# Builds a scratch store of fake pools in a mktemp dir (NEVER touches a live
# memory directory) and asserts the inventory:
#   - reports a small readable pool as ok and an index-only pool as EMPTY
#   - flags a pool over the index limit as OVER-LIMIT
#   - reports a pool it cannot read as UNMEASURED, never as ok and never as an
#     EMPTY "safe to rmdir" candidate (an unreadable directory makes its file
#     glob expand to nothing, which reads exactly like an empty pool)
#   - fails (exit 1) on a missing or unreadable store, where a report of zero
#     pools would read like a clean one
#   - prints its usage header for --help and only the header
#
# The inventory is read-only, so this suite needs no sandbox. The permission
# cases are skipped when the suite runs as root, which ignores file modes.
#
# Run:  bash ~/OPS/.claude-config/bin/tests/memory-prune-inventory-test.sh
# Exit: 0 = all pass; non-zero on the first failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INVENTORY="$HERE/../../../SKILLS/memory-prune/scripts/inventory"
[ -f "$INVENTORY" ] || { echo "FAIL: inventory not found at $INVENTORY" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/memory-prune-inventory-test.XXXXXX")"
# A chmod 000 pool cannot be removed until its mode is restored.
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

entry() {  # <pool dir> <file stem>
  cat > "$1/$2.md" <<EOF
---
name: $2
description: fixture entry $2
metadata:
  type: reference
---
body
EOF
}

STORE="$T/store"
mkdir -p "$STORE/good" "$STORE/indexonly" "$STORE/locked"
entry "$STORE/good" one
printf '%s\n' '- [One](one.md) - fixture entry one' > "$STORE/good/MEMORY.md"
printf '%s\n' '# index only, no entries' > "$STORE/indexonly/MEMORY.md"
entry "$STORE/locked" two

inv() { env HOME="$T/home" bash "$INVENTORY" --store "$STORE" "$@" 2>&1; }

# 1. A small readable pool is ok; an index-only pool is EMPTY and staged as
#    removable (the behavior the UNMEASURED case must never be confused with).
out="$(inv)"
grep -qE '^good .* ok$' <<< "$out" || fail "readable pool is not ok: $out"
grep -qE '^indexonly .* EMPTY$' <<< "$out" || fail "index-only pool is not EMPTY: $out"
grep -q 'safe to rmdir' <<< "$out" || fail "an empty pool is no longer staged: $out"
pass "a readable pool is ok and an index-only pool is EMPTY"

# 2. The index limit still flags a pool.
out="$(inv --limit 10)"
grep -qE '^good .* OVER-LIMIT$' <<< "$out" || fail "an index over the limit is not OVER-LIMIT: $out"
pass "a pool over the index limit is OVER-LIMIT"

# 3. --help prints the header and only the header.
out="$(env HOME="$T/home" bash "$INVENTORY" --help 2>&1)"
grep -q 'memory-prune skill' <<< "$out" && ! grep -q 'set -uo' <<< "$out" \
  || fail "--help does not print exactly the header: $out"
pass "--help prints the usage header only"

# 4. A missing store fails loudly.
env HOME="$T/home" bash "$INVENTORY" --store "$T/no-such-store" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "a missing store exited $rc, not 1"
pass "a missing store exits 1"

if [ "$(id -u)" = 0 ]; then
  echo "SKIP: running as root, file modes are ignored; the unreadable-pool and unreadable-store cases did not run"
  exit 0
fi

# 5. A pool with no permissions is UNMEASURED, counted, staged for access
#    repair, and never offered for removal.
chmod 000 "$STORE/locked"
out="$(inv)"; rc=$?
chmod 755 "$STORE/locked"
[ "$rc" -eq 0 ] || fail "an unreadable pool made the report exit $rc: $out"
grep -qE '^locked .* UNMEASURED$' <<< "$out" || fail "an unreadable pool is not UNMEASURED: $out"
grep -q '1 unmeasured' <<< "$out" || fail "the summary does not count the unmeasured pool: $out"
if grep -E 'safe to rmdir' -A3 <<< "$out" | grep -q 'locked'; then
  fail "an unreadable pool was staged as removable: $out"
fi
grep -q 'restore read access' <<< "$out" || fail "no access-repair candidate was staged: $out"
pass "an unreadable pool is UNMEASURED, never an empty removal candidate"

# 6. An index file that exists but cannot be read leaves the pool UNMEASURED too.
printf '%s\n' '- [Two](two.md) - fixture entry two' > "$STORE/locked/MEMORY.md"
chmod 000 "$STORE/locked/MEMORY.md"
out="$(inv)"
chmod 644 "$STORE/locked/MEMORY.md"
grep -qE '^locked .* UNMEASURED$' <<< "$out" || fail "an unreadable index did not leave the pool UNMEASURED: $out"
pass "an unreadable index file leaves its pool UNMEASURED"

# 7. An unreadable store is an error, not a report of zero pools.
chmod 000 "$STORE"
env HOME="$T/home" bash "$INVENTORY" --store "$STORE" >/dev/null 2>&1; rc=$?
chmod 755 "$STORE"
[ "$rc" -eq 1 ] || fail "an unreadable store exited $rc, not 1"
pass "an unreadable store exits 1"

echo "all memory-prune inventory checks passed"
