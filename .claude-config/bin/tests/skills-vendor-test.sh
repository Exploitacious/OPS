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
#     hand-edited mirror, one holding a .git, and any unrecorded folder that
#     differs from its source, even under a name that mounted before the record
#     existed) is moved to .claude-config/backup/skills-replaced/ with its
#     content intact, then replaced; a mirror sync wrote and one already equal
#     to its source update in place with no backup; a failed install moves the
#     folder back, in both engines
#   - a failed rsync or tar copy leaves an owned mirror exactly as it was (the
#     new mirror is built in a temp dir and swapped in)
#   - the BACKUP line is printed even when a later step fails, and a RESTORED
#     line follows it when a failed install moves the folder back
#   - no mv -T: a PATH mv that rejects -T (as BSD/macOS mv does) still syncs
#   - stale SKILLS/.vendor.XXXXXX dirs from an interrupted run are cleaned at
#     the start of a sync; a mirror a kill left aside between the two renames
#     is moved back first (with its GUI-local files); other names are untouched;
#     .gitignore keeps the staging dirs out of the backup
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
for a in "$@"; do case "$a" in */tree) exit 71 ;; esac; done
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

# Folders with no record. One equal to its source is a mirror and updates in
# place. One that differs is kept in the backup, even under a name that mounted
# before the record existed (2026-10-19: those six names counted as owned, so a
# user's own meta-skill-creator was overwritten in place with no backup).
o="$TDIR/own-legacy"
mkdir -p "$o/SKILLS/dynamic-workflows" "$o/SKILLS/epsilon" "$o/SKILLS/meta-skill-creator" \
  "$o/PROJECTS/src/skills/dynamic-workflows" "$o/PROJECTS/src/skills/epsilon" "$o/PROJECTS/src/skills/meta-skill-creator"
printf 'dynamic-workflows\tsrc/skills/dynamic-workflows\nepsilon\tsrc/skills/epsilon\nmeta-skill-creator\tsrc/skills/meta-skill-creator\n' > "$o/SKILLS/VENDORED.tsv"
printf 'current\n' > "$o/PROJECTS/src/skills/dynamic-workflows/SKILL.md"
printf 'older vendored copy\n' > "$o/SKILLS/dynamic-workflows/SKILL.md"
printf 'dropped upstream\n' > "$o/SKILLS/dynamic-workflows/gone.md"
printf 'mirror GUI prompt\n' > "$o/SKILLS/dynamic-workflows/00_System_Prompt.md"
printf 'same\n' > "$o/PROJECTS/src/skills/epsilon/SKILL.md"
printf 'same\n' > "$o/SKILLS/epsilon/SKILL.md"
printf 'vendored meta-skill-creator\n' > "$o/PROJECTS/src/skills/meta-skill-creator/SKILL.md"
printf 'MY OWN HAND-WRITTEN SKILL\n' > "$o/SKILLS/meta-skill-creator/SKILL.md"
printf 'mine\n' > "$o/SKILLS/meta-skill-creator/my-extra.md"
for engine in "${engines[@]}"; do
  rm -rf "$TDIR/legacy-$engine"; cp -a "$o" "$TDIR/legacy-$engine"
  out="$(SKILLS_VENDOR_NO_RSYNC="$engine" run_sv "$TDIR/legacy-$engine" sync)" || fail "engine $engine: unrecorded sync failed: $out"
  m="$TDIR/legacy-$engine/SKILLS"
  for n in dynamic-workflows meta-skill-creator; do
    line="$(printf '%s\n' "$out" | grep "^BACKUP   $n: ")" || fail "engine $engine: unrecorded $n that differs from its source was not moved aside: $out"
    diff -r --no-dereference "$o/SKILLS/$n" "${line##* kept at }" >/dev/null || fail "engine $engine: the backup of $n lost content"
    printf '%s\n' "$out" | grep -q "^SYNCED   $n\$" || fail "engine $engine: $n not SYNCED: $out"
  done
  [ "$(cat "$m/meta-skill-creator/SKILL.md")" = "vendored meta-skill-creator" ] && [ ! -e "$m/meta-skill-creator/my-extra.md" ] \
    || fail "engine $engine: meta-skill-creator mirror not installed cleanly"
  [ "$(cat "$m/dynamic-workflows/SKILL.md")" = current ] && [ ! -e "$m/dynamic-workflows/gone.md" ] \
    || fail "engine $engine: dynamic-workflows mirror not installed"
  printf '%s\n' "$out" | grep -q '^UNCHANGED epsilon$' || fail "engine $engine: equal mirror not UNCHANGED: $out"
  printf '%s\n' "$out" | grep -q '^BACKUP   epsilon' && fail "engine $engine: a mirror equal to its source was moved aside: $out"
  for n in dynamic-workflows epsilon meta-skill-creator; do
    grep -q "^$n	sha256:" "$m/.vendored-state.tsv" || fail "engine $engine: $n was not recorded"
  done
  [ "$(backups "$TDIR/legacy-$engine")" = 2 ] || fail "engine $engine: expected 2 backups, found $(backups "$TDIR/legacy-$engine")"
done
pass "unrecorded folders: equal to the source updates in place; different is kept in the backup, legacy names included"

# A failed install moves the local folder back, in both engines.
REAL_RSYNC="$(command -v rsync || true)"
export REAL_RSYNC
mkdir -p "$TDIR/bin-install"
cat > "$TDIR/bin-install/mv" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in */tree) exit 71 ;; esac; done
exec "$REAL_MV" "$@"
STUB
cat > "$TDIR/bin-install/rsync" <<'STUB'
#!/usr/bin/env bash
src="${*: -2:1}" dst="${*: -1}"
case "$src" in */gamma/) mkdir -p "$dst" && echo partial > "${dst}partial"; exit 23 ;; esac
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
  # The BACKUP line named a path that is gone now; stdout must say so too.
  printf '%s\n' "$out" | grep -A100 '^BACKUP   gamma: ' | grep -q "^RESTORED gamma: the install failed, so the folder is back at $o/SKILLS/gamma" \
    || fail "engine $engine: no RESTORED line after the BACKUP line: $out"
done
pass "a failed install moves the local folder back, says so after the BACKUP line, and exits 3"

# A failed or interrupted rsync must not leave an owned mirror half-updated
# (2026-10-19: rsync --delete ran in place, so a failure left a mirror that
# matched neither the record nor the source, and the next sync moved it aside
# with its GUI-local files). The stub writes into its destination, then fails.
if command -v rsync >/dev/null 2>&1; then
  mkdir -p "$TDIR/bin-halfway"
  cat > "$TDIR/bin-halfway/rsync" <<'STUB'
#!/usr/bin/env bash
dst="${*: -1}"
mkdir -p "$dst" && echo 'half-written' > "${dst}SKILL.md" && rm -f "${dst}refs/a.md"
exit 23
STUB
  chmod +x "$TDIR/bin-halfway/rsync"
  o="$TDIR/halfway"
  make_tree "$o"
  run_sv "$o" sync >/dev/null || fail "halfway fixture sync failed"
  printf 'moved on again\n' >> "$o/PROJECTS/src/skills/alpha/SKILL.md"
  cp -a "$o/SKILLS" "$TDIR/halfway-before"
  out="$(PATH="$TDIR/bin-halfway:$PATH" run_sv "$o" sync 2>&1)"; rc=$?
  [ "$rc" -eq 3 ] || fail "a failing rsync exited $rc, want 3: $out"
  diff -r --no-dereference "$TDIR/halfway-before" "$o/SKILLS" >/dev/null \
    || { diff -r --no-dereference "$TDIR/halfway-before" "$o/SKILLS" >&2; fail "a failing rsync changed the owned mirror"; }
  [ -z "$(find "$o/SKILLS" -maxdepth 1 -name '.vendor.*' -print -quit)" ] || fail "a failing rsync left a temp dir in SKILLS"
  out="$(run_sv "$o" sync)" || fail "the sync after a failed rsync failed: $out"
  printf '%s\n' "$out" | grep -q '^BACKUP' && fail "the sync after a failed rsync moved the mirror aside: $out"
  printf '%s\n' "$out" | grep -q '^SYNCED   alpha$' || fail "the sync after a failed rsync did not update alpha: $out"
  [ "$(cat "$o/SKILLS/alpha/00_System_Prompt.md")" = "mirror-side GUI prompt" ] || fail "the GUI-local file left the mirror"
  pass "a failing rsync leaves the owned mirror as it was; the next sync updates it in place"
else
  echo "SKIP: failing rsync on an owned mirror (rsync not installed)"
fi

# The BACKUP line is printed as soon as a folder is moved aside, so a later
# failure (here the ledger write: sort fails unless it is the -z sort of the
# digest) still says where the folder went.
mkdir -p "$TDIR/bin-nosort"
REAL_SORT="$(command -v sort)"; export REAL_SORT
cat > "$TDIR/bin-nosort/sort" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" -z "*) exec "$REAL_SORT" "$@" ;; esac
exit 2
STUB
chmod +x "$TDIR/bin-nosort/sort"
for engine in "${engines[@]}"; do
  o="$TDIR/late-fail-$engine"
  make_tree "$o"
  SKILLS_VENDOR_NO_RSYNC="$engine" run_sv "$o" sync >/dev/null || fail "engine $engine: late-failure fixture sync failed"
  add_local "$o" gamma
  cp -a "$o/SKILLS/gamma" "$TDIR/late-gamma-$engine"
  out="$(PATH="$TDIR/bin-nosort:$PATH" SKILLS_VENDOR_NO_RSYNC="$engine" run_sv "$o" sync 2>&1)"; rc=$?
  [ "$rc" -eq 3 ] || fail "engine $engine: a failed ledger write exited $rc, want 3: $out"
  printf '%s\n' "$out" | grep -q 'could not record it' || fail "engine $engine: the ledger failure was not reported: $out"
  line="$(printf '%s\n' "$out" | grep '^BACKUP   gamma: ')" || fail "engine $engine: no BACKUP line after a late failure: $out"
  diff -r --no-dereference "$TDIR/late-gamma-$engine" "${line##* kept at }" >/dev/null || fail "engine $engine: the named backup does not hold the folder"
done
pass "the BACKUP line is printed before a later failure"

# --- No mv -T: BSD and macOS mv reject it, and every swap failed there. --------
mkdir -p "$TDIR/bin-bsdmv"
cat > "$TDIR/bin-bsdmv/mv" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = -T ] && { echo "mv: illegal option -- T" >&2; exit 64; }; done
exec "$REAL_MV" "$@"
STUB
chmod +x "$TDIR/bin-bsdmv/mv"
for engine in "${engines[@]}"; do
  o="$TDIR/bsd-$engine"
  make_tree "$o"
  out="$(PATH="$TDIR/bin-bsdmv:$PATH" SKILLS_VENDOR_NO_RSYNC="$engine" run_sv "$o" sync 2>&1)" || fail "engine $engine: sync with a BSD-style mv failed: $out"
  printf '%s\n' "$out" | grep -q '^SYNCED   alpha$' || fail "engine $engine: alpha not SYNCED with a BSD-style mv: $out"
  check_mirror "$o" "engine $engine, BSD-style mv"
done
pass "sync never passes mv -T: a mv that rejects it (BSD, macOS) still swaps mirrors in"

# --- Stale staging dirs from an interrupted run are cleaned. -------------------
o="$TDIR/stale"
make_tree "$o"
run_sv "$o" sync >/dev/null || fail "stale fixture sync failed"
printf 'gui setup\n' > "$o/SKILLS/alpha/SETUP.md"
mkdir -p "$o/SKILLS/.vendor.Ab12Cd/tree" "$o/SKILLS/.vendor.keep-me" "$o/SKILLS/.vendor.Zz9"
printf 'half copy\n' > "$o/SKILLS/.vendor.Ab12Cd/tree/SKILL.md"
# The state a kill between the two renames leaves: the mirror in previous/,
# the new tree beside it, and SKILLS/alpha missing.
mkdir -p "$o/SKILLS/.vendor.Qw34Er"; printf 'alpha\n' > "$o/SKILLS/.vendor.Qw34Er/name"
mv "$o/SKILLS/alpha" "$o/SKILLS/.vendor.Qw34Er/previous"; mkdir "$o/SKILLS/.vendor.Qw34Er/tree"
# A leftover from an earlier release, with no record of its skill.
mkdir -p "$o/SKILLS/.vendor.Ty56Ui/previous"; printf 'orphan\n' > "$o/SKILLS/.vendor.Ty56Ui/previous/SKILL.md"
out="$(run_sv "$o" sync 2>&1)" || fail "sync over stale staging dirs failed: $out"
printf '%s\n' "$out" | grep -q '^RESTORED alpha: an interrupted sync had left it in .vendor.Qw34Er' || fail "the mirror a kill left aside was not restored: $out"
[ "$(cat "$o/SKILLS/alpha/SETUP.md" 2>/dev/null)" = "gui setup" ] || fail "the restored mirror lost its GUI-local file"
line="$(printf '%s\n' "$out" | grep '^BACKUP   .vendor.Ty56Ui: ')" || fail "an unplaceable leftover was not kept in the backup: $out"
[ "$(cat "${line##* kept at }/SKILL.md")" = orphan ] || fail "the leftover's backup lost its content"
[ -z "$(find "$o/SKILLS" -maxdepth 1 -name '.vendor.??????' -print -quit)" ] || fail "a stale staging dir survived: $(ls -a "$o/SKILLS")"
[ -d "$o/SKILLS/.vendor.keep-me" ] && [ -d "$o/SKILLS/.vendor.Zz9" ] || fail "a dir not named like a staging dir was removed"
printf '%s\n' "$out" | grep -q '^UNCHANGED alpha$' || fail "the restored mirror was not recognized as owned: $out"
g="$TDIR/ignore-check"; git init -q "$g" && cp "$(cd "$(dirname "$SV")/../.." && pwd)/.gitignore" "$g/.gitignore"
mkdir -p "$g/SKILLS/.vendor.Ab12Cd"; : > "$g/SKILLS/.vendor.Ab12Cd/x"
git -C "$g" check-ignore -q SKILLS/.vendor.Ab12Cd/x || fail ".gitignore does not keep SKILLS/.vendor.*/ out of the backup"
pass "stale staging dirs are cleaned (a mirror a kill left aside comes back first); .gitignore keeps them out of git"

echo "ALL PASS"
