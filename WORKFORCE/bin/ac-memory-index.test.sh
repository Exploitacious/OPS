#!/usr/bin/env bash
# ac-memory-index.test.sh — runnable test suite for ac-memory-index.
#
# Builds a self-contained scratch fixture of fake memory files in a mktemp
# dir (NEVER touches any live memory directory), then asserts the generator:
#   - emits the expected index with correct type-precedence ordering
#   - parses quoted/escaped scalar values losslessly
#   - is idempotent across re-runs
#   - never indexes MEMORY.md itself
#   - handles a missing-frontmatter file (exit 2, flagged, good lines kept,
#     kebab fallback title)
#   - keys the link target on FILENAME, not the frontmatter `name:` field
#
# Run:  bash ~/OPS/WORKFORCE/bin/ac-memory-index.test.sh
# Exit: 0 = all pass; non-zero on first failure.
set -uo pipefail

GEN="$(cd "$(dirname "$0")" && pwd)/ac-memory-index"
[ -x "$GEN" ] || { echo "FAIL: generator not executable at $GEN" >&2; exit 1; }

TDIR="$(mktemp -d "${TMPDIR:-/tmp}/ac-memory-index-test.XXXXXX")"
ERRFILE="$TDIR/.stderr"
trap 'rm -rf "$TDIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- Fixture: one file per type, including a colon+quotes description. -------
cat > "$TDIR/alpha-thing.md" <<'EOF'
---
name: alpha-thing
title: Alpha Thing
description: First alphabetical project note
metadata:
  node_type: memory
  type: project
---
body text, ignored by the indexer
EOF

cat > "$TDIR/zeta-feedback.md" <<'EOF'
---
name: zeta-feedback
title: Zeta Feedback
description: "A feedback note with: a colon and quotes"
metadata:
  node_type: memory
  type: feedback
---
body
EOF

cat > "$TDIR/ref-card.md" <<'EOF'
---
name: ref-card
title: Reference Card
description: A reference entry
metadata:
  node_type: memory
  type: reference
---
body
EOF

# A description carrying escaped double quotes — must round-trip exactly.
cat > "$TDIR/quoted-desc.md" <<'EOF'
---
name: quoted-desc
title: Quoted Desc
description: "old \"dead end\" verdicts are priors not laws"
metadata:
  type: feedback
---
body
EOF

# --- Test 1: expected output + ordering + quote/escape handling. -------------
GOT="$("$GEN" --check "$TDIR")"; rc=$?
[ "$rc" -eq 0 ] || fail "expected exit 0 on clean fixture, got $rc"

EXPECTED="- [Alpha Thing](alpha-thing.md) — First alphabetical project note
- [Quoted Desc](quoted-desc.md) — old \"dead end\" verdicts are priors not laws
- [Zeta Feedback](zeta-feedback.md) — A feedback note with: a colon and quotes
- [Reference Card](ref-card.md) — A reference entry"

[ "$GOT" = "$EXPECTED" ] || fail "output mismatch:
--- got ---
$GOT
--- expected ---
$EXPECTED"
pass "expected output + type precedence + quoted/escaped value round-trip"

# --- Test 2: --check writes nothing. ----------------------------------------
[ ! -f "$TDIR/MEMORY.md" ] || fail "--check must not write MEMORY.md"
pass "--check writes nothing"

# --- Test 3: write mode equals --check output. ------------------------------
"$GEN" "$TDIR" 2>/dev/null
[ -f "$TDIR/MEMORY.md" ] || fail "write mode did not create MEMORY.md"
[ "$(cat "$TDIR/MEMORY.md")" = "$EXPECTED" ] || fail "written file != --check output"
pass "write mode == --check output"

# --- Test 4: idempotent. ----------------------------------------------------
SUM1="$(md5sum < "$TDIR/MEMORY.md")"
"$GEN" "$TDIR" 2>/dev/null
SUM2="$(md5sum < "$TDIR/MEMORY.md")"
[ "$SUM1" = "$SUM2" ] || fail "not idempotent: index changed on re-run"
pass "idempotent across re-runs"

# --- Test 5: MEMORY.md never self-references. -------------------------------
grep -q "MEMORY.md)" "$TDIR/MEMORY.md" && fail "MEMORY.md indexed itself"
pass "MEMORY.md excluded from its own index"

# --- Test 6: missing-frontmatter -> exit 2, flagged, good lines kept. -------
cat > "$TDIR/broken-note.md" <<'EOF'
this file has no frontmatter at all
just a body
EOF
OUT="$("$GEN" --check "$TDIR" 2>"$ERRFILE")"; rc=$?
ERR="$(cat "$ERRFILE")"
[ "$rc" -eq 2 ] || fail "expected exit 2 with a broken file, got $rc"
echo "$ERR" | grep -q "broken-note.md" || fail "broken file not flagged on stderr"
echo "$OUT" | grep -q "Alpha Thing" || fail "good line dropped when broken file present"
echo "$OUT" | grep -q "\[Broken Note\](broken-note.md)" || fail "kebab fallback title missing"
pass "missing-frontmatter: exit 2 + flagged + good lines kept + kebab fallback"

# --- Test 7: link target is the FILENAME, not the name: field. --------------
cat > "$TDIR/odd-filename.md" <<'EOF'
---
name: some-internal-name
title: Odd Filename Note
description: name field differs from filename
metadata:
  type: feedback
---
EOF
OUT="$("$GEN" --check "$TDIR" 2>/dev/null)"
echo "$OUT" | grep -q "(odd-filename.md)" || fail "link target should be the filename"
pass "link target uses filename, not the name: field"

echo
echo "ALL TESTS PASSED"
