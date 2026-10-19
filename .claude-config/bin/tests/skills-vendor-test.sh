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
#   - ownership: a destination sync did not write (the Operator's own folder, a
#     hand-edited mirror, one holding a .git) is moved to
#     .claude-config/backup/skills-replaced/ with its content intact, then
#     replaced; a mirror sync wrote, a pre-record mirror of a legacy row, and
#     one already equal to its source update in place with no backup; a failed
#     install moves the folder back, in both engines
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
# uncloned (beta), and a stale mirror of alpha. The mirror is a real earlier
# sync of an older source (so the ownership record knows it), plus GUI-local
# files added to the mirror since; then the source moves on.
make_tree() {
  local o="$1" s="$1/PROJECTS/src/skills/alpha"
  mkdir -p "$o/SKILLS" "$s/old" "$s/refs/"$'two\nlines' "$s/refs/gui-dir"
  printf 'alpha\tsrc/skills/alpha\nbeta\tsrc/skills/beta\n# comment row\n' > "$o/SKILLS/VENDORED.tsv"
  printf 'old skill body\n' > "$s/SKILL.md"
  printf 'stale\n' > "$s/old/stale.md"
  run_sv "$o" sync >/dev/null || fail "fixture: the first sync failed"
  rm -rf "$s/old"
  mkdir -p "$s/.git"
  printf 'new skill body\n' > "$s/SKILL.md"
  printf 'ref\n' > "$s/refs/a.md"
  printf 'source-side GUI file\n' > "$s/00_System_Prompt.md"
  printf 'git internals\n' > "$s/.git/HEAD"
  printf 'mirror-side GUI prompt\n' > "$o/SKILLS/alpha/00_System_Prompt.md"
  printf 'nested GUI setup\n' > "$o/SKILLS/alpha/refs/"$'two\nlines/SETUP.md'
  ln -sf 00_System_Prompt.md "$o/SKILLS/alpha/05_gui_dual_track.md"
  mkdir -p "$o/SKILLS/alpha/refs/gui-dir/SETUP.md"
  printf 'directory scaffold\n' > "$o/SKILLS/alpha/refs/gui-dir/SETUP.md/private.txt"
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
  [ "$(cat "$m/refs/"$'two\nlines/SETUP.md')" = "nested GUI setup" ] || fail "$label: a GUI-local file with a newline in its path was lost"
  [ -L "$m/05_gui_dual_track.md" ] && [ "$(readlink "$m/05_gui_dual_track.md")" = 00_System_Prompt.md ] || fail "$label: a GUI-local symlink was lost or followed"
  [ "$(cat "$m/refs/gui-dir/SETUP.md/private.txt")" = "directory scaffold" ] || fail "$label: a GUI-local directory was lost"
  [ -d "$1/SKILLS/beta" ] && fail "$label: an uncloned source produced a mirror dir"
  [ -z "$(find "$1/SKILLS" -maxdepth 1 -name '.vendor*.*' ! -name .vendored-state.tsv -print -quit)" ] \
    || fail "$label: a temp dir was left in SKILLS"
  [ ! -e "$1/.claude-config/backup/skills-replaced" ] || fail "$label: a mirror sync wrote was moved aside"
  grep -q "^alpha	sha256:" "$1/SKILLS/.vendored-state.tsv" || fail "$label: the mirror was not recorded"
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

# Reject the entire manifest before updating any row, in both engines and both
# modes. A late bad row must leave even the earlier stale mirror untouched.
assert_rejected() {
  local o="$1" label="$2" mode engine rc out snapshot="$TDIR/before"
  rm -rf "$snapshot"
  cp -a "$o" "$snapshot" || fail "$label: snapshot failed"
  for engine in 0 1; do
    for mode in sync --check; do
      out="$(SKILLS_VENDOR_NO_RSYNC="$engine" run_sv "$o" "$mode" 2>&1)"; rc=$?
      [ "$rc" -eq 3 ] || fail "$label ($engine, $mode) exited $rc, want 3: $out"
      diff -r --no-dereference "$snapshot" "$o" >/dev/null || fail "$label ($engine, $mode) changed the fixture"
    done
  done
}

for bad in '.' '../escape' '/absolute' '.hidden'; do
  make_tree "$TDIR/bad-name"
  printf '%s\tsrc/skills/alpha\n' "$bad" >> "$TDIR/bad-name/SKILLS/VENDORED.tsv"
  assert_rejected "$TDIR/bad-name" "unsafe name $bad"
done
for bad in '.' '../escape' '/absolute'; do
  make_tree "$TDIR/bad-source"
  printf 'bad\t%s\n' "$bad" >> "$TDIR/bad-source/SKILLS/VENDORED.tsv"
  assert_rejected "$TDIR/bad-source" "unsafe source $bad"
done
pass "unsafe names and source traversal fail before any mirror changes"

make_tree "$TDIR/local-file"
printf 'private local notes\n' > "$TDIR/local-file/SKILLS/local.md"
printf 'local.md\tsrc/skills/alpha\n' >> "$TDIR/local-file/SKILLS/VENDORED.tsv"
assert_rejected "$TDIR/local-file" "local file destination"
make_tree "$TDIR/manifest-file"
printf 'VENDORED.tsv\tsrc/skills/alpha\n' >> "$TDIR/manifest-file/SKILLS/VENDORED.tsv"
assert_rejected "$TDIR/manifest-file" "manifest destination"
pass "manifest cannot replace a local file or itself"

mkdir "$TDIR/outside"
printf 'outside must survive\n' > "$TDIR/outside/SETUP.md"
cp -a "$TDIR/outside" "$TDIR/outside-before"
make_tree "$TDIR/dest-link"
rm -rf "$TDIR/dest-link/SKILLS/alpha"
ln -s "$TDIR/outside" "$TDIR/dest-link/SKILLS/alpha"
assert_rejected "$TDIR/dest-link" "destination symlink"
make_tree "$TDIR/root-link"
mv "$TDIR/root-link/SKILLS" "$TDIR/root-link/actual-skills"
ln -s actual-skills "$TDIR/root-link/SKILLS"
assert_rejected "$TDIR/root-link" "SKILLS root symlink"
make_tree "$TDIR/source-link"
ln -s "$TDIR/outside" "$TDIR/source-link/PROJECTS/escape"
printf 'bad\tescape\n' >> "$TDIR/source-link/SKILLS/VENDORED.tsv"
assert_rejected "$TDIR/source-link" "source symlink outside PROJECTS"
diff -r "$TDIR/outside-before" "$TDIR/outside" >/dev/null || fail "a symlink check changed outside data"
pass "mirror, SKILLS-root, and escaping source symlinks fail without writes"

# A source symlink must not redirect the fallback's GUI-local preservation copy
# outside its staging directory. Keep the old mirror if that overlay conflicts.
make_tree "$TDIR/gui-link"
printf 'mirror GUI setup\n' > "$TDIR/gui-link/SKILLS/alpha/refs/SETUP.md"
rm -rf "$TDIR/gui-link/PROJECTS/src/skills/alpha/refs"
ln -s "$TDIR/outside" "$TDIR/gui-link/PROJECTS/src/skills/alpha/refs"
cp -a "$TDIR/gui-link/SKILLS" "$TDIR/gui-link-before"
out="$(SKILLS_VENDOR_NO_RSYNC=1 run_sv "$TDIR/gui-link" sync 2>&1)"; rc=$?
[ "$rc" -eq 3 ] || fail "GUI overlay symlink exited $rc, want 3: $out"
diff -r --no-dereference "$TDIR/gui-link-before" "$TDIR/gui-link/SKILLS" >/dev/null || fail "GUI overlay failure changed the prior mirror"
diff -r "$TDIR/outside-before" "$TDIR/outside" >/dev/null || fail "GUI overlay wrote outside SKILLS"
pass "tar GUI preservation refuses a source symlink without changing either tree"

# Inject actual command failures in isolated PATHs. In particular, a failed
# final rename used to run after rm -rf had already destroyed the old mirror.
REAL_MV="$(command -v mv)"
export REAL_MV
for broken in mv tar find cp chmod diff; do
  make_tree "$TDIR/failure-$broken"
  cp -a "$TDIR/failure-$broken/SKILLS" "$TDIR/failure-$broken-before"
  mkdir "$TDIR/bin-$broken"
  if [ "$broken" = mv ]; then
    cat > "$TDIR/bin-$broken/$broken" <<'STUB'
#!/usr/bin/env bash
case "${2:-}" in */tree) exit 71 ;; esac
exec "$REAL_MV" "$@"
STUB
  else
    printf '#!/usr/bin/env bash\nexit 2\n' > "$TDIR/bin-$broken/$broken"
  fi
  chmod +x "$TDIR/bin-$broken/$broken"
  out="$(PATH="$TDIR/bin-$broken:$PATH" SKILLS_VENDOR_NO_RSYNC=1 run_sv "$TDIR/failure-$broken" sync 2>&1)"; rc=$?
  [ "$rc" -eq 3 ] || fail "injected $broken failure exited $rc, want 3: $out"
  diff -r --no-dereference "$TDIR/failure-$broken-before" "$TDIR/failure-$broken/SKILLS" >/dev/null || fail "injected $broken failure changed the old mirror or leaked staging data"
done
out="$(PATH="$TDIR/bin-diff:$PATH" run_sv "$TDIR/failure-diff" --check 2>&1)"; rc=$?
[ "$rc" -eq 3 ] || fail "--check swallowed diff error (exit $rc): $out"
pass "tar, find, cp, chmod, diff, and final rename failures retain the old mirror and exit 3"

make_tree "$TDIR/dangling-link"
ln -s missing "$TDIR/dangling-link/PROJECTS/src/skills/alpha/refs/link"
SKILLS_VENDOR_NO_RSYNC=1 run_sv "$TDIR/dangling-link" sync >/dev/null || fail "dangling source symlink sync failed"
out="$(run_sv "$TDIR/dangling-link" --check)"; rc=$?
[ "$rc" -eq 2 ] || fail "--check should compare the dangling symlink itself (exit $rc): $out"
printf '%s\n' "$out" | grep -q '^OK       alpha$' || fail "dangling symlink did not compare cleanly: $out"
pass "drift checks compare symlinks without following their targets"

# --- Ownership: never delete a folder sync did not write. ----------------------
# add_local <tree> <name>: a manifest row whose destination already holds the
# Operator's own skill folder (no record, not a legacy row).
add_local() {
  local o="$1" n="$2"
  mkdir -p "$o/PROJECTS/src/skills/$n" "$o/SKILLS/$n/notes"
  printf '%s\tsrc/skills/%s\n' "$n" "$n" >> "$o/SKILLS/VENDORED.tsv"
  printf 'vendored %s\n' "$n" > "$o/PROJECTS/src/skills/$n/SKILL.md"
  printf 'my own %s skill\n' "$n" > "$o/SKILLS/$n/SKILL.md"
  printf 'local-only notes\n' > "$o/SKILLS/$n/notes/private.md"
  printf 'my GUI prompt\n' > "$o/SKILLS/$n/00_System_Prompt.md"
}
backups() { find "$1/.claude-config/backup/skills-replaced" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }

engines=(1)
command -v rsync >/dev/null 2>&1 && engines+=(0)
for engine in "${engines[@]}"; do
  o="$TDIR/own-$engine"
  make_tree "$o"
  add_local "$o" gamma
  cp -a "$o/SKILLS/gamma" "$TDIR/gamma-before-$engine"
  out="$(run_sv "$o" --check)"; rc=$?
  [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '^DRIFT    gamma$' \
    || fail "engine $engine: --check did not report the local folder as DRIFT (exit $rc): $out"
  out="$(SKILLS_VENDOR_NO_RSYNC="$engine" run_sv "$o" sync)" || fail "engine $engine: sync over a local folder failed: $out"
  line="$(printf '%s\n' "$out" | grep '^BACKUP   gamma: ')" || fail "engine $engine: no BACKUP line for gamma: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^BACKUP')" = 1 ] || fail "engine $engine: a mirror sync wrote was moved aside: $out"
  backup="${line##* kept at }"
  case "$backup" in */.claude-config/backup/skills-replaced/gamma-*Z) ;; *) fail "engine $engine: backup outside the backup dir: $backup" ;; esac
  diff -r --no-dereference "$TDIR/gamma-before-$engine" "$backup" >/dev/null || fail "engine $engine: the backup lost the local folder's content"
  [ "$(cat "$o/SKILLS/gamma/SKILL.md")" = "vendored gamma" ] || fail "engine $engine: gamma was not installed"
  [ ! -e "$o/SKILLS/gamma/notes" ] && [ ! -e "$o/SKILLS/gamma/00_System_Prompt.md" ] || fail "engine $engine: local content stayed in the mirror"
  printf '%s\n' "$out" | grep -q '^SYNCED   gamma$' || fail "engine $engine: gamma not SYNCED: $out"
  out="$(run_sv "$o" --check)"; rc=$?
  [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q '^OK       gamma$' || fail "engine $engine: --check after the sync (exit $rc): $out"
  out="$(SKILLS_VENDOR_NO_RSYNC="$engine" run_sv "$o" sync)" || fail "engine $engine: rerun failed"
  printf '%s\n' "$out" | grep -q '^UNCHANGED gamma$' || fail "engine $engine: rerun not UNCHANGED: $out"
  printf 'vendored gamma v2\n' > "$o/PROJECTS/src/skills/gamma/SKILL.md"
  out="$(SKILLS_VENDOR_NO_RSYNC="$engine" run_sv "$o" sync)" || fail "engine $engine: update failed"
  printf '%s\n' "$out" | grep -q '^SYNCED   gamma$' || fail "engine $engine: update not SYNCED: $out"
  printf '%s\n' "$out" | grep -q '^BACKUP' && fail "engine $engine: updating a recorded mirror made a backup: $out"
  [ "$(backups "$o")" = 1 ] || fail "engine $engine: expected exactly one backup, found $(backups "$o")"
  [ "$(cat "$o/SKILLS/gamma/SKILL.md")" = "vendored gamma v2" ] || fail "engine $engine: recorded mirror not updated"
done
pass "a local folder under a mounted name is kept in the backup intact, then replaced; --check reports it"

# A hand-edited mirror, and a destination holding a .git, are not mirrors sync
# wrote either.
o="$TDIR/own-edits"
make_tree "$o"
run_sv "$o" sync >/dev/null || fail "hand-edit fixture sync failed"
printf 'my local edit\n' >> "$o/SKILLS/alpha/SKILL.md"
printf 'edited at the source\n' >> "$o/PROJECTS/src/skills/alpha/refs/a.md"
out="$(run_sv "$o" sync)" || fail "sync over a hand-edited mirror failed: $out"
line="$(printf '%s\n' "$out" | grep '^BACKUP   alpha: ')" || fail "hand-edited mirror not moved aside: $out"
grep -q 'my local edit' "${line##* kept at }/SKILL.md" || fail "the backup lost the hand edit"
mkdir -p "$o/PROJECTS/src/skills/delta" "$o/SKILLS/delta/.git"
printf 'delta\tsrc/skills/delta\n' >> "$o/SKILLS/VENDORED.tsv"
printf 'delta\n' > "$o/PROJECTS/src/skills/delta/SKILL.md"
printf 'delta\n' > "$o/SKILLS/delta/SKILL.md"
printf 'ref: refs/heads/main\n' > "$o/SKILLS/delta/.git/HEAD"
out="$(run_sv "$o" sync)" || fail "sync over a git checkout failed: $out"
line="$(printf '%s\n' "$out" | grep '^BACKUP   delta: ')" || fail "a destination with a .git was not moved aside: $out"
[ -f "${line##* kept at }/.git/HEAD" ] || fail "the backup lost the .git"
pass "a hand-edited mirror and a git checkout are kept in the backup"

# Mirrors that predate the record: a legacy row's stale mirror and a mirror
# equal to its source update in place, with no backup, and get recorded.
o="$TDIR/own-legacy"
mkdir -p "$o/SKILLS/dynamic-workflows" "$o/SKILLS/epsilon" "$o/PROJECTS/src/skills/dynamic-workflows" "$o/PROJECTS/src/skills/epsilon"
printf 'dynamic-workflows\tsrc/skills/dynamic-workflows\nepsilon\tsrc/skills/epsilon\n' > "$o/SKILLS/VENDORED.tsv"
printf 'current\n' > "$o/PROJECTS/src/skills/dynamic-workflows/SKILL.md"
printf 'older vendored copy\n' > "$o/SKILLS/dynamic-workflows/SKILL.md"
printf 'dropped upstream\n' > "$o/SKILLS/dynamic-workflows/gone.md"
printf 'mirror GUI prompt\n' > "$o/SKILLS/dynamic-workflows/00_System_Prompt.md"
printf 'same\n' > "$o/PROJECTS/src/skills/epsilon/SKILL.md"
printf 'same\n' > "$o/SKILLS/epsilon/SKILL.md"
for engine in "${engines[@]}"; do
  rm -rf "$TDIR/legacy-$engine"; cp -a "$o" "$TDIR/legacy-$engine"
  out="$(SKILLS_VENDOR_NO_RSYNC="$engine" run_sv "$TDIR/legacy-$engine" sync)" || fail "engine $engine: legacy sync failed: $out"
  printf '%s\n' "$out" | grep -q '^BACKUP' && fail "engine $engine: a pre-record mirror was moved aside: $out"
  printf '%s\n' "$out" | grep -q '^SYNCED   dynamic-workflows$' || fail "engine $engine: legacy mirror not SYNCED: $out"
  printf '%s\n' "$out" | grep -q '^UNCHANGED epsilon$' || fail "engine $engine: equal mirror not UNCHANGED: $out"
  m="$TDIR/legacy-$engine/SKILLS"
  [ "$(cat "$m/dynamic-workflows/SKILL.md")" = current ] && [ ! -e "$m/dynamic-workflows/gone.md" ] \
    || fail "engine $engine: legacy mirror not updated in place"
  [ "$(cat "$m/dynamic-workflows/00_System_Prompt.md")" = "mirror GUI prompt" ] || fail "engine $engine: legacy mirror lost its GUI-local file"
  grep -q '^dynamic-workflows	sha256:' "$m/.vendored-state.tsv" && grep -q '^epsilon	sha256:' "$m/.vendored-state.tsv" \
    || fail "engine $engine: pre-record mirrors were not recorded"
  [ "$(backups "$TDIR/legacy-$engine")" = 0 ] || fail "engine $engine: a backup was made"
done
pass "pre-record mirrors (a legacy row, one equal to its source) update in place with no backup"

# A failed install moves the local folder back, in both engines.
REAL_RSYNC="$(command -v rsync || true)"
export REAL_RSYNC
mkdir -p "$TDIR/bin-install"
cat > "$TDIR/bin-install/mv" <<'STUB'
#!/usr/bin/env bash
case "${2:-}" in */tree) exit 71 ;; esac
exec "$REAL_MV" "$@"
STUB
cat > "$TDIR/bin-install/rsync" <<'STUB'
#!/usr/bin/env bash
dst="${*: -1}"
case "$dst" in */gamma/) mkdir -p "$dst" && echo partial > "${dst}partial"; exit 23 ;; esac
exec "$REAL_RSYNC" "$@"
STUB
chmod +x "$TDIR/bin-install/mv" "$TDIR/bin-install/rsync"
for engine in "${engines[@]}"; do
  o="$TDIR/restore-$engine"
  make_tree "$o"
  SKILLS_VENDOR_NO_RSYNC="$engine" run_sv "$o" sync >/dev/null || fail "engine $engine: restore fixture sync failed"
  add_local "$o" gamma
  cp -a "$o/SKILLS" "$TDIR/restore-before-$engine"
  out="$(PATH="$TDIR/bin-install:$PATH" SKILLS_VENDOR_NO_RSYNC="$engine" run_sv "$o" sync 2>&1)"; rc=$?
  [ "$rc" -eq 3 ] || fail "engine $engine: a failed install exited $rc, want 3: $out"
  diff -r --no-dereference "$TDIR/restore-before-$engine" "$o/SKILLS" >/dev/null \
    || fail "engine $engine: the local folder was not restored after a failed install"
  [ "$(backups "$o")" = 0 ] || fail "engine $engine: a restored folder also left a backup"
  printf '%s\n' "$out" | grep -q 'restored' || fail "engine $engine: the restore was not reported: $out"
done
pass "a failed install moves the local folder back and exits 3"

echo "ALL PASS"
