#!/usr/bin/env bash
# skills-vendor-test.sh: runnable test suite for .claude-config/bin/skills-vendor.sh.
#
# Builds a throwaway OPS tree (manifest, a source repo under PROJECTS/, and a
# stale mirror) under mktemp and drives the script with OPS_DIR pointing there;
# it never reads or writes the real ~/OPS. Asserts:
#   - sync mirrors the source minus .git and the GUI-local files, deletes stale
#     mirror files, and keeps the mirror's own GUI-local files
#   - the rsync engine and the rsync-free tar engine (SKILLS_VENDOR_NO_RSYNC=1,
#     the path a host without rsync takes) produce identical trees
#   - a rerun reports UNCHANGED; --check reports OK, MISSING, and DRIFT with
#     exit codes 0, 2, and 1
#   - OPS_DIR selects the checkout, so HOME is irrelevant
#
# Run:  bash ~/OPS/.claude-config/bin/tests/skills-vendor-test.sh
# Exit: 0 = all pass; non-zero on first failure.
set -uo pipefail

SV="$(cd "$(dirname "$0")/.." && pwd)/skills-vendor.sh"
[ -f "$SV" ] || { echo "FAIL: skills-vendor.sh missing at $SV" >&2; exit 1; }

TDIR="$(mktemp -d "${TMPDIR:-/tmp}/skills-vendor-test.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# make_tree <dir>: a fresh OPS fixture with one cloned source (alpha) and one
# uncloned (beta), and a stale mirror of alpha.
make_tree() {
  local o="$1"
  mkdir -p "$o/SKILLS/alpha/old" "$o/PROJECTS/src/skills/alpha/refs" "$o/PROJECTS/src/skills/alpha/.git"
  printf 'alpha\tsrc/skills/alpha\nbeta\tsrc/skills/beta\n# comment row\n' > "$o/SKILLS/VENDORED.tsv"
  printf 'new skill body\n' > "$o/PROJECTS/src/skills/alpha/SKILL.md"
  printf 'ref\n' > "$o/PROJECTS/src/skills/alpha/refs/a.md"
  printf 'source-side GUI file\n' > "$o/PROJECTS/src/skills/alpha/00_System_Prompt.md"
  printf 'git internals\n' > "$o/PROJECTS/src/skills/alpha/.git/HEAD"
  printf 'old skill body\n' > "$o/SKILLS/alpha/SKILL.md"
  printf 'stale\n' > "$o/SKILLS/alpha/old/stale.md"
  printf 'mirror-side GUI prompt\n' > "$o/SKILLS/alpha/00_System_Prompt.md"
}

# run_sv <tree> <args...>: the script against <tree>, with an unrelated HOME.
run_sv() { local o="$1"; shift; HOME="$TDIR/elsewhere" OPS_DIR="$o" bash "$SV" "$@"; }

check_mirror() {
  local m="$1/SKILLS/alpha" label="$2"
  [ "$(cat "$m/SKILL.md")" = "new skill body" ] || fail "$label: SKILL.md not refreshed"
  [ -f "$m/refs/a.md" ] || fail "$label: nested source file not copied"
  [ -e "$m/old/stale.md" ] && fail "$label: stale mirror file survived the sync"
  [ -e "$m/.git" ] && fail "$label: .git was copied into the mirror"
  [ "$(cat "$m/00_System_Prompt.md")" = "mirror-side GUI prompt" ] || fail "$label: the mirror's GUI-local file was replaced or deleted"
  [ -d "$1/SKILLS/beta" ] && fail "$label: an uncloned source produced a mirror dir"
  ls -A "$1/SKILLS" | grep -q '^\.vendor\.' && fail "$label: a temp dir was left in SKILLS"
  return 0
}

# --- tar engine (what a host without rsync runs). -----------------------------
make_tree "$TDIR/tar"
out="$(SKILLS_VENDOR_NO_RSYNC=1 run_sv "$TDIR/tar" sync)" || fail "tar sync exited non-zero: $out"
printf '%s\n' "$out" | grep -q '^SYNCED   alpha$' || fail "tar sync did not report SYNCED alpha: $out"
printf '%s\n' "$out" | grep -q '^SKIP     beta ' || fail "tar sync did not SKIP the uncloned source: $out"
check_mirror "$TDIR/tar" "tar engine"
pass "tar engine mirrors the source, drops stale files and .git, keeps GUI-local files"
out="$(SKILLS_VENDOR_NO_RSYNC=1 run_sv "$TDIR/tar" sync)"
printf '%s\n' "$out" | grep -q '^UNCHANGED alpha$' || fail "tar rerun was not UNCHANGED: $out"
pass "tar engine rerun reports UNCHANGED"

# --- rsync engine, and parity with tar. ---------------------------------------
if command -v rsync >/dev/null 2>&1; then
  make_tree "$TDIR/rsync"
  out="$(run_sv "$TDIR/rsync" sync)" || fail "rsync sync exited non-zero: $out"
  check_mirror "$TDIR/rsync" "rsync engine"
  diff -r "$TDIR/rsync/SKILLS" "$TDIR/tar/SKILLS" >/dev/null || { diff -r "$TDIR/rsync/SKILLS" "$TDIR/tar/SKILLS" >&2; fail "rsync and tar engines produced different mirrors"; }
  pass "rsync and tar engines produce identical mirrors"
else
  echo "SKIP: rsync engine parity (rsync not installed)"
fi

# --- --check: OK + MISSING exits 2; a source edit is DRIFT, exit 1. -----------
out="$(run_sv "$TDIR/tar" --check)"; rc=$?
[ "$rc" -eq 2 ] || fail "--check with one uncloned source exited $rc, want 2: $out"
printf '%s\n' "$out" | grep -q '^OK       alpha$' || fail "--check did not report OK alpha: $out"
printf '%s\n' "$out" | grep -q '^MISSING  beta ' || fail "--check did not report MISSING beta: $out"
pass "--check reports OK and MISSING (exit 2)"
printf 'edited at the source\n' >> "$TDIR/tar/PROJECTS/src/skills/alpha/refs/a.md"
out="$(run_sv "$TDIR/tar" --check)"; rc=$?
[ "$rc" -eq 1 ] || fail "--check after a source edit exited $rc, want 1: $out"
printf '%s\n' "$out" | grep -q '^DRIFT    alpha$' || fail "--check did not report DRIFT alpha: $out"
pass "--check reports an un-synced source edit as DRIFT (exit 1)"
mkdir -p "$TDIR/tar/PROJECTS/src/skills/beta"; printf 'b\n' > "$TDIR/tar/PROJECTS/src/skills/beta/SKILL.md"
SKILLS_VENDOR_NO_RSYNC=1 run_sv "$TDIR/tar" sync >/dev/null || fail "tar sync after the edit failed"
out="$(run_sv "$TDIR/tar" --check)"; rc=$?
[ "$rc" -eq 0 ] || fail "--check after a full sync exited $rc, want 0: $out"
pass "--check is clean (exit 0) once every source is cloned and synced"

# --- OPS_DIR is the checkout; without it and without ~/OPS the script stops. --
out="$(env -u OPS_DIR HOME="$TDIR/elsewhere" bash "$SV" --check 2>&1)"; rc=$?
[ "$rc" -eq 3 ] || fail "no OPS_DIR and no ~/OPS exited $rc, want 3: $out"
pass "without OPS_DIR it reads ~/OPS, and a missing root fails loud (exit 3)"

echo "ALL PASS"
