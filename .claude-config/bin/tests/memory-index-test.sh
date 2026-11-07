#!/usr/bin/env bash
# memory-index-test.sh: runnable test suite for .claude-config/bin/memory-index.
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
#   - labels a title-less entry by its `name:` (the pool entry format has no
#     `title:`, so a large pool used to fail --check) and flags only a file
#     with neither
#   - WARNS, and only warns, on a pool of more than 60 entries: the index is
#     still written and the exit status is unchanged (a pool is its owner's)
#   - warns, without failing, on more than 20 pinned entries
#   - --find ranks the entry a query is about first
#
# Run:  bash ~/OPS/.claude-config/bin/tests/memory-index-test.sh
# Exit: 0 = all pass; non-zero on first failure.
set -uo pipefail

GEN="$(cd "$(dirname "$0")/.." && pwd)/memory-index"
[ -x "$GEN" ] || { echo "FAIL: generator not executable at $GEN" >&2; exit 1; }

TDIR="$(mktemp -d "${TMPDIR:-/tmp}/memory-index-test.XXXXXX")"
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

# A description carrying escaped double quotes: it must round-trip exactly.
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

# The index separator is a space, an em dash, and a space (memory-index
# INDEX_SEP). Built from its UTF-8 bytes so this file carries no em dash.
SEP=" $(printf '\342\200\224') "
EXPECTED="- [Alpha Thing](alpha-thing.md)${SEP}First alphabetical project note
- [Quoted Desc](quoted-desc.md)${SEP}old \"dead end\" verdicts are priors not laws
- [Zeta Feedback](zeta-feedback.md)${SEP}A feedback note with: a colon and quotes
- [Reference Card](ref-card.md)${SEP}A reference entry"

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

# --- Test 8: a title-less entry is labelled by its name:, not flagged. --------
# The harness's pool entry format (the digest's "Write:" line) is name,
# description, metadata.type: no title:. The label is the name, Title Cased the
# way the kebab fallback of the file name was, so an index regenerated after the
# fix is byte-identical to the old one and tracked MEMORY.md files do not churn.
N="$(mktemp -d "${TMPDIR:-/tmp}/memory-index-names.XXXXXX")"
cat > "$N/billing-writes-pass-author.md" <<'EOF'
---
name: billing-writes-pass-author
description: "Billing writes need the author set to the driving engineer"
metadata:
  type: feedback
---
body
EOF
OUT="$("$GEN" --check "$N" 2>"$ERRFILE")"; rc=$?
[ "$rc" -eq 0 ] || fail "a name:-only entry must pass --check (exit 0), got $rc: $(cat "$ERRFILE")"
[ "$OUT" = "- [Billing Writes Pass Author](billing-writes-pass-author.md)${SEP}Billing writes need the author set to the driving engineer" ] \
  || fail "name: label wrong: $OUT"
[ ! -s "$ERRFILE" ] || fail "a name:-only entry printed a problem: $(cat "$ERRFILE")"
# title: still wins over name:.
cat > "$N/titled.md" <<'EOF'
---
name: some-name
title: The Real Title
description: titled
metadata:
  type: feedback
---
EOF
OUT="$("$GEN" --check "$N" 2>/dev/null)"
grep -q '^- \[The Real Title\](titled.md)' <<< "$OUT" || fail "title: should beat name:"
# A file with neither title: nor name: is the only one flagged.
printf -- '---\ndescription: nameless\nmetadata:\n  type: feedback\n---\n' > "$N/nameless-thing.md"
OUT="$("$GEN" --check "$N" 2>"$ERRFILE")"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'nameless-thing.md: missing title: and name:' "$ERRFILE" \
  && ! grep -q 'billing-writes-pass-author.md' "$ERRFILE" || fail "only the file with neither key should be flagged (rc=$rc): $(cat "$ERRFILE")"
echo "$OUT" | grep -q '\[Nameless Thing\](nameless-thing.md)' || fail "kebab fallback missing for the nameless file"
pass "name: labels a title-less entry; only a file with neither title: nor name: is flagged (exit 2)"
rm -rf "$N"

# --- Test 9: 139 name:-only entries are not flagged. -----------------------------
N="$(mktemp -d "${TMPDIR:-/tmp}/memory-index-139.XXXXXX")"
python3 - "$N" <<'PY'
import sys
for i in range(139):
    stem = f"reference-thing-{i:03d}"
    open(f"{sys.argv[1]}/{stem}.md", "w").write(
        f"---\nname: {stem}\ndescription: entry {i}\nmetadata:\n  type: reference\n---\nbody\n")
PY
# 139 is over the 60-entry warning line; the point here is that not one of the 139
# is flagged as missing a title, and that the warning does not change the exit.
OUT="$("$GEN" --check "$N" 2>"$ERRFILE")"; rc=$?
[ "$rc" -eq 0 ] || fail "139 name:-only entries: expected exit 0 (a warning, not a failure), got $rc"
! grep -q 'need backfill\|missing title' "$ERRFILE" || fail "a name:-only entry was flagged as missing a title: $(head -3 "$ERRFILE")"
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 139 ] || fail "expected 139 index lines"
rm -rf "$N"
pass "139 name:-only entries: none flagged as missing a title"

# --- Test 10: the 60-entry pool cap is a WARN, never an error. ---------------------
mkpool() {  # mkpool <dir> <count> [pinned count]
  python3 - "$1" "$2" "${3:-0}" <<'PY'
import os, sys
d, n, pins = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
os.makedirs(d, exist_ok=True)
for i in range(n):
    stem = f"entry-{i:03d}"
    pin = "  pinned: true\n" if i < pins else ""
    open(f"{d}/{stem}.md", "w").write(
        f"---\nname: {stem}\ndescription: entry number {i}\nmetadata:\n  type: feedback\n{pin}---\nbody\n")
PY
}
C="$(mktemp -d "${TMPDIR:-/tmp}/memory-index-cap.XXXXXX")"
mkpool "$C/ok" 60
"$GEN" --check "$C/ok" >/dev/null 2>"$ERRFILE"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$ERRFILE" ] || fail "60 entries is at the cap and must be silent (rc=$rc): $(cat "$ERRFILE")"
mkpool "$C/over" 61
OUT="$("$GEN" --check "$C/over" 2>"$ERRFILE")"; rc=$?
[ "$rc" -eq 0 ] || fail "61 entries must still exit 0 (a warning only), got $rc"
grep -q 'WARN: 61 entries in .*over the 60-entry pool cap' "$ERRFILE" || fail "cap warning must carry the count: $(cat "$ERRFILE")"
grep -q 'nothing was removed' "$ERRFILE" || fail "cap warning must say nothing was removed: $(cat "$ERRFILE")"
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 61 ] || fail "--check still prints the whole index over the cap"
"$GEN" "$C/over" 2>"$ERRFILE"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$C/over/MEMORY.md" ] && [ "$(wc -l < "$C/over/MEMORY.md")" -eq 61 ] \
  || fail "write mode over the cap must write the index and exit 0 (rc=$rc)"
[ "$(find "$C/over" -name 'entry-*.md' | wc -l)" -eq 61 ] || fail "an over-cap pool lost entries"
# A broken file still reports its own exit status; the cap never outranks it.
printf 'no frontmatter\n' > "$C/over/bare.md"
"$GEN" --check "$C/over" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "over the cap with a broken file must exit 2 (the broken file), got $rc"
pass "pool cap: 60 is silent; 61 warns with the count, exits 0, writes the index and removes nothing"

# --- Test 11: more than 20 pinned entries warn, never fail. -------------------------
mkpool "$C/pins" 30 21
"$GEN" --check "$C/pins" >/dev/null 2>"$ERRFILE"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'WARN: 21 pinned entries' "$ERRFILE" || fail "21 pinned must warn and pass (rc=$rc): $(cat "$ERRFILE")"
mkpool "$C/pins20" 30 20
"$GEN" --check "$C/pins20" >/dev/null 2>"$ERRFILE"
[ ! -s "$ERRFILE" ] || fail "20 pinned must be silent: $(cat "$ERRFILE")"
pass "pinned cap: 21 pinned warn on stderr and exit 0; 20 are silent"

# --- Test 12: --find ranks the entry the words are about first. ---------------------
F="$C/find-cwd"; mkdir -p "$F"
cat > "$F/reference-vpn-gateway-restart.md" <<'EOF'
---
name: reference-vpn-gateway-restart
description: The VPN gateway restarts its agent after a 3017 event
metadata:
  type: reference
---
EOF
cat > "$F/feedback-invoice-rounding-let-it-be.md" <<'EOF'
---
name: feedback-invoice-rounding-let-it-be
description: Do not chase rounding on invoice time entries; send hours once
metadata:
  type: feedback
---
EOF
for i in 1 2 3 4 5 6 7 8 9 10; do
  printf -- '---\nname: filler-%s\ndescription: unrelated filler entry %s about something else\nmetadata:\n  type: reference\n---\n' "$i" "$i" > "$F/filler-$i.md"
done
OUT="$(MEMORY_INDEX_DIR="$F" MEMORY_DIGEST_ROOT_DIR="$C/none" MEMORY_DIGEST_HOST=t "$GEN" --find --ops "$C" --cwd "$C" rounding on invoice billing 2>&1)"
first="$(printf '%s\n' "$OUT" | head -1 | cut -f3)"
[ "$first" = feedback-invoice-rounding-let-it-be ] || fail "--find ranked the wrong entry first: $OUT"
printf '%s\n' "$OUT" | head -1 | grep -qP '^\d+\.\d\tthis\t' || fail "--find line shape is score, pool, name, description: $OUT"
"$GEN" --find >/dev/null 2>&1 && fail "--find with no words must fail"
pass "--find: the entry the words are about ranks first; no words is an error"

# --- Test 13: the source carries no literal em dash character. -----------------------
if grep -q -e "$(printf '\342\200\224')" -e "$(printf '\342\200\223')" "$GEN"; then fail "memory-index carries an em or en dash character (spell it as an escape)"; fi
pass "memory-index has no em or en dash character"
rm -rf "$C"

echo
echo "ALL TESTS PASSED"
