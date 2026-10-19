#!/usr/bin/env bash
# skills-vendor.sh - mount the shared skill source(s) into OPS/SKILLS.
#
# OPS mounts portable technique skills rather than carrying a drifting fork of
# each (SKILLS/README.md § "Skill sources"). This script IS that mount: the skill
# repos cloned under PROJECTS/ are the source of truth, and it mirrors the skill
# dirs they publish into SKILLS/<name>/ so a fix is made once at the source and
# flows here. One mount mechanism, not two: the "mounting" the README describes is
# this vendoring, gate-checked by verify-ops.sh.
#
# Manifest: SKILLS/VENDORED.tsv. One row per skill, tab-separated:
#   <name><TAB><source-dir relative to $ROOT/PROJECTS>
# The mirror for a row lands at $ROOT/SKILLS/<name>/. Lines starting with # and
# blank lines are ignored.
#
# Usage:
#   skills-vendor.sh            sync (default): mirror each source dir into
#                               SKILLS/<name>/ (rsync -a --delete semantics,
#                               built in a temp dir and swapped in). Prints one
#                               line per skill: SYNCED / UNCHANGED / SKIP, plus
#                               a BACKUP line naming where a folder sync did
#                               not write was moved (see "Ownership" below),
#                               and a RESTORED line when a folder went back to
#                               its place (a failed install, or one an
#                               interrupted run left aside).
#   skills-vendor.sh sync       same as above, explicit.
#   skills-vendor.sh --check    read-only drift gate. Prints DRIFT / OK /
#                               MISSING per skill. Exit 1 if any DRIFT, 2 if any
#                               MISSING and no DRIFT, 0 clean. Fails loud: a
#                               missing manifest or tool exits 3.
#
# verify-ops.sh runs `skills-vendor.sh --check` as its skills-mirror check and
# reports FAIL on DRIFT / WARN on MISSING, so an un-synced source edit or an
# uncloned source repo trips the drift gate. deploy.sh clones the public default
# source and runs a sync, so a deployed host starts clean; MISSING (WARN) means
# the clone has not happened (no network at deploy time, or a source of your own
# you have not cloned yet).
#
# The checkout is $OPS_DIR when set (deploy.sh passes the tree it runs from),
# else ~/OPS. rsync is preferred but not required: a host without it (a minimal
# Debian container, Git Bash) syncs through tar with the same excludes and the
# same delete semantics, so a missing package never leaves the mounts unsynced.
# SKILLS_VENDOR_NO_RSYNC=1 forces that path (tests compare the two). Either
# engine builds the new mirror in a temp dir beside the old one and swaps it in
# with a rename, restoring the old mirror if the swap fails: an rsync straight
# into the mirror left it half-updated when rsync failed or was interrupted.
# The renames always target a name that does not exist, which plain mv handles
# the same on GNU and BSD/macOS (mv -T is GNU-only, so every swap failed there).
# A run that is interrupted leaves its SKILLS/.vendor.XXXXXX staging dir behind;
# the next sync cleans it, first moving back a mirror a kill left aside between
# the two renames (RESTORED line). Two syncs at once are not supported.
#
# Ownership: sync never deletes a folder it did not write. A manifest row
# claims SKILLS/<name>, but the folder already there can be the Operator's own
# skill (a release that adds a row, as 2026-10-19 added grill-me, tdd and
# diagnosing-bugs, meets every existing copy that kept its own SKILLS/tdd).
# SKILLS/.vendored-state.tsv records a content digest of each mirror sync
# writes, and an existing destination is updated in place only when it is
# provably a mirror:
#   1. its digest matches the recorded one (what sync last wrote), or
#   2. it already equals the source (the sync has nothing to remove).
# Anything else, or any destination holding a .git (sync never writes one), is
# moved to .claude-config/backup/skills-replaced/<name>-<UTC>/, outside the
# skills index, before the install, and the BACKUP line is printed at once, so
# a later failure still tells the user where the folder went; a failed install
# moves it back. The digest skips the GUI-local files, which sync keeps in
# place, so GUI authoring in a mirror never reads as foreign content. A
# hand-edited mirror does, and is kept the same way. A folder with no record
# that differs from its source is kept the same way too, even under one of the
# six names that mounted before the record existed: a pre-record mirror that is
# behind its source cannot be told from the Operator's own or hand-edited copy,
# and treating those names as owned overwrote such a copy with no backup. Its
# GUI-local files move with it.

set -uo pipefail

ROOT="${OPS_DIR:-$HOME/OPS}"
if [ ! -d "$ROOT" ]; then
  echo "skills-vendor: no harness root found ($ROOT)" >&2
  exit 3
fi
ROOT="$(cd "$ROOT" && pwd -P)" || exit 3

PROJECTS="$ROOT/PROJECTS"
SKILLS="$ROOT/SKILLS"
MANIFEST="$SKILLS/VENDORED.tsv"
# A mirror root must be a real directory: rsync follows a destination symlink
# with a trailing slash, and the fallback creates its staging dirs here.
if [ -L "$SKILLS" ] || [ ! -d "$SKILLS" ]; then
  echo "skills-vendor: unsafe skills directory: $SKILLS" >&2
  exit 3
fi
if [ -d "$PROJECTS" ]; then
  PROJECTS="$(cd "$PROJECTS" && pwd -P)" || exit 3
fi

# GUI dual-track scaffolding is SKILLS-local by convention: the claude.ai Project
# mirror (00_System_Prompt.md, its SETUP.md install guide, and the
# meta-skill-creator 05_gui_dual_track.md note) is kept out of shared skill
# repos, so the source repos deliberately lack it. SKILLS is the GUI-authoring
# home, so exclude these from the --delete sync (the mirror keeps them; --delete
# would destroy the only copy) and from the drift check (so they never read as
# false DRIFT). If a source repo ever legitimately ships one of these names,
# revisit this list.
GUI_LOCAL=('00_System_Prompt.md' '05_gui_dual_track.md' 'SETUP.md')

LEDGER="$SKILLS/.vendored-state.tsv"
BACKUP_ROOT="$ROOT/.claude-config/backup/skills-replaced"

[ -f "$MANIFEST" ] || { echo "skills-vendor: manifest missing: $MANIFEST" >&2; exit 3; }

MODE="${1:-sync}"
case "$MODE" in
  sync|--check) ;;
  *) echo "usage: skills-vendor.sh [sync|--check]" >&2; exit 3 ;;
esac

USE_RSYNC=1
if [ "${SKILLS_VENDOR_NO_RSYNC:-0}" = 1 ] || ! command -v rsync >/dev/null 2>&1; then
  USE_RSYNC=0
fi
if [ "$MODE" = sync ] && [ "$USE_RSYNC" = 0 ]; then
  command -v tar >/dev/null 2>&1 || { echo "skills-vendor: neither rsync nor tar found" >&2; exit 3; }
fi
# The ownership digest. Without a hasher sync cannot tell a mirror from a local
# folder, so it stops rather than guess.
HASH_CMD=()
if command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  HASH_CMD=(shasum -a 256)
elif [ "$MODE" = sync ]; then
  echo "skills-vendor: neither sha256sum nor shasum found: cannot tell a mirror from a local folder" >&2
  exit 3
fi

# Build the exclude args once, in rsync, tar, and diff shapes.
RSYNC_EXCL=(--exclude='.git')
TAR_EXCL=(--exclude='.git')
DIFF_EXCL=(-x '.git')
GUI_FIND=()
for g in "${GUI_LOCAL[@]}"; do
  RSYNC_EXCL+=(--exclude="$g")
  TAR_EXCL+=(--exclude="$g")
  DIFF_EXCL+=(-x "$g")
  [ "${#GUI_FIND[@]}" -eq 0 ] || GUI_FIND+=(-o)
  GUI_FIND+=(-name "$g")
done

# Validate the whole manifest before any mount changes. A bad later row must
# not leave an earlier mirror partially synced. Membership declares ownership;
# it does not grant access to SKILLS itself, a symlink target, or a local file.
names=()
sources=()
while IFS=$'\t' read -r name src || [ -n "$name" ]; do
  case "$name" in ''|'#'*) continue ;; esac
  [ -n "$src" ] || { echo "skills-vendor: malformed manifest row (no source): '$name'" >&2; exit 3; }
  if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    echo "skills-vendor: unsafe manifest name: '$name'" >&2; exit 3
  fi
  case "$src" in *..*|/*|.|./*|*/./*|*/.) echo "skills-vendor: unsafe manifest source: '$src'" >&2; exit 3 ;; esac
  srcdir="$PROJECTS/$src"
  dstdir="$SKILLS/$name"
  if [ -L "$dstdir" ] || { [ -e "$dstdir" ] && [ ! -d "$dstdir" ]; }; then
    echo "skills-vendor: unsafe mirror destination: $dstdir" >&2; exit 3
  fi
  if [ -d "$srcdir" ]; then
    srcdir="$(cd "$srcdir" && pwd -P)" || exit 3
    case "$srcdir" in
      "$PROJECTS"/*) ;;
      *) echo "skills-vendor: source escapes PROJECTS: $src" >&2; exit 3 ;;
    esac
  fi
  names+=("$name")
  sources+=("$srcdir")
done < "$MANIFEST"

# Refuse a source symlink where preserving a GUI-local file needs a directory.
# mkdir -p and cp would otherwise follow it and write outside the staging tree.
gui_parent_dirs() {
  local base="$1" rel="${2#./}" component
  while [[ "$rel" == */* ]]; do
    component="${rel%%/*}"
    rel="${rel#*/}"
    base="$base/$component"
    [ ! -L "$base" ] && mkdir -p "$base" || return 1
  done
}

# stage_mirror <src> <dst>: build the new mirror in a temp dir beside <dst>,
# then swap it in only when it differs. Prints "changed" or "same"; returns
# non-zero on any failure, leaving <dst> as it was (an rsync or tar that fails
# midway only ever touched the temp copy).
#   rsync: start from a copy of <dst>, so rsync's excludes keep its GUI-local
#   files, --delete drops stale ones, and its itemized output says whether
#   anything changed, exactly as the old in-place sync did.
#   tar: the source minus the excludes, plus <dst>'s own GUI-local files, and
#   a content compare against <dst>.
stage_mirror() {
  local src="$1" dst="$2" tmp rel rc out content
  tmp="$(mktemp -d "$SKILLS/.vendor.XXXXXX")" || return 1
  # The skill this staging dir belongs to, so a later run can put back a
  # mirror a kill left in $tmp/previous (clean_stale).
  printf '%s\n' "${dst##*/}" > "$tmp/name" || { rm -rf "$tmp"; return 1; }
  if [ "$USE_RSYNC" = 1 ]; then
    if [ -d "$dst" ]; then
      cp -a "$dst" "$tmp/tree" || { rm -rf "$tmp"; return 1; }
    else
      mkdir "$tmp/tree" || { rm -rf "$tmp"; return 1; }
    fi
    # --checksum: rsync's default quick check skips a file whose size and mtime
    # match, so an edit that kept the size within the same second stayed DRIFT
    # (--check compares content) while sync said UNCHANGED. Skill dirs are
    # small; comparing content costs nothing.
    out="$(rsync -ai --checksum --delete "${RSYNC_EXCL[@]}" "$src"/ "$tmp/tree"/ 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "skills-vendor: rsync failed (rc=$rc)" >&2
      [ -n "$out" ] && echo "$out" >&2
      rm -rf "$tmp"; return 1
    fi
    # -i also itemizes time-only updates (".d..t......", ".f..t......"): a
    # mirror whose directory mtime moved (a GUI-local file written into it, a
    # restore) read as changed or not depending on which second the steps fell
    # in, so the sync result flipped between SYNCED and UNCHANGED (seen
    # 2026-10-19 as a 2-in-12 test flake). Only those lines are ignored; a mode,
    # owner or content change still counts.
    content="$(printf '%s\n' "$out" | grep -v -E '^\.[a-zA-Z]\.\.[tT]\.{6}( |$)' | grep -v '^$' || true)"
    if [ -d "$dst" ] && [ -z "$content" ]; then
      rm -rf "$tmp" || return 1; echo same; return 0
    fi
  else
    mkdir "$tmp/tree" || { rm -rf "$tmp"; return 1; }
    if ! (cd "$src" && tar "${TAR_EXCL[@]}" -cf - .) | (cd "$tmp/tree" && tar -xf -); then
      rm -rf "$tmp"; return 1
    fi
    if [ -d "$dst" ]; then
      # Save find's status as well as its NUL-delimited results. Process
      # substitution hides read errors and newline-delimited names lose data.
      # Like rsync's excludes, preserve matching symlinks and whole directories;
      # prune them so their children cannot be copied a second time.
      (cd "$dst" && find . \( "${GUI_FIND[@]}" \) -prune -print0) > "$tmp/gui-files" || { rm -rf "$tmp"; return 1; }
      while IFS= read -r -d '' rel; do
        gui_parent_dirs "$tmp/tree" "$rel" && [ ! -L "$tmp/tree/$rel" ] &&
          cp -a "$dst/$rel" "$tmp/tree/$rel" || { rm -rf "$tmp"; return 1; }
      done < "$tmp/gui-files"
    fi
    if [ -d "$dst" ]; then
      diff -rq --no-dereference "$tmp/tree" "$dst" >/dev/null 2>&1
      rc=$?
      case "$rc" in
        0) rm -rf "$tmp" || return 1; echo same; return 0 ;;
        1) ;;
        *) rm -rf "$tmp"; return 1 ;;
      esac
    fi
    chmod 755 "$tmp/tree" || { rm -rf "$tmp"; return 1; }
  fi
  # Keep the prior mirror until installation succeeds. Each rename targets a
  # name that does not exist, so plain mv renames rather than moving into a
  # directory, on GNU and BSD alike. A destination something recreated in
  # between is refused rather than nested into.
  if [ -d "$dst" ]; then
    mv "$dst" "$tmp/previous" || { rm -rf "$tmp"; return 1; }
  fi
  if [ -e "$dst" ] || [ -L "$dst" ] || ! mv "$tmp/tree" "$dst"; then
    if [ -d "$tmp/previous" ] && { [ -e "$dst" ] || [ -L "$dst" ] || ! mv "$tmp/previous" "$dst"; }; then
      echo "skills-vendor: restore failed; previous mirror retained at $tmp/previous" >&2
      return 1
    fi
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp" || return 1
  echo changed
}

# tree_digest <dir>: a sha256 over every path, entry type, file content and
# symlink target under <dir>, skipping the GUI-local names the way the sync
# does. Paths are NUL-delimited and sorted in the C locale, so the value is the
# same on every machine. Prints "sha256:<hex>"; non-zero on any failure.
tree_digest() {
  local dir="$1" list rel t sum out
  list="$(mktemp "${TMPDIR:-/tmp}/skills-vendor.XXXXXX")" || return 1
  if ! (cd "$dir" && find . \( "${GUI_FIND[@]}" \) -prune -o -print0) > "$list" \
     || ! LC_ALL=C sort -z -o "$list" "$list"; then
    rm -f "$list"; return 1
  fi
  out="$(
    while IFS= read -r -d '' rel; do
      if [ -L "$dir/$rel" ]; then
        t="$(readlink "$dir/$rel")" || exit 1
        printf 'l\0%s\0%s\0' "$rel" "$t"
      elif [ -d "$dir/$rel" ]; then
        printf 'd\0%s\0' "$rel"
      elif [ -f "$dir/$rel" ]; then
        sum="$("${HASH_CMD[@]}" < "$dir/$rel")" || exit 1
        printf 'f\0%s\0%s\0' "$rel" "${sum%% *}"
      else
        printf 'o\0%s\0' "$rel"
      fi
    done < "$list" | "${HASH_CMD[@]}"
  )" || { rm -f "$list"; return 1; }
  rm -f "$list"
  printf 'sha256:%s\n' "${out%% *}"
}

# ledger_get <name>: the recorded digest, or nothing.
ledger_get() {
  [ -f "$LEDGER" ] || return 0
  awk -F'\t' -v n="$1" '$1 == n { v = $2 } END { if (v != "") print v }' "$LEDGER"
}

# ledger_set <name> <digest>: record a mirror's digest. Written whole through a
# temp file, so an interrupted run never leaves half a ledger.
ledger_set() {
  local tmp
  [ "$(ledger_get "$1")" = "$2" ] && return 0
  tmp="$(mktemp "$SKILLS/.vendored-state.XXXXXX")" || return 1
  {
    printf '# skills-vendor.sh state: a content digest of each mirror it wrote.\n'
    printf '# Generated; do not edit. A folder whose digest is not here is not\n'
    printf '# treated as a mirror, so sync moves it aside instead of deleting it.\n'
    (
      if [ -f "$LEDGER" ]; then
        awk -F'\t' -v n="$1" '!/^#/ && NF >= 2 && $1 != n' "$LEDGER" || exit 1
      fi
      printf '%s\t%s\n' "$1" "$2"
    ) | LC_ALL=C sort
  } > "$tmp" && mv -f "$tmp" "$LEDGER" || { rm -f "$tmp"; return 1; }
}

# owned_mirror <name> <src> <dst>: 0 when <dst> is a mirror sync owns (the
# Ownership rules in the header), 1 when it is not, 2 when that cannot be
# decided (the caller stops before changing anything).
owned_mirror() {
  local name="$1" src="$2" dst="$3" found recorded current rc
  found="$(find "$dst" -name .git -print -quit)" || return 2
  [ -z "$found" ] || return 1
  recorded="$(ledger_get "$name")" || return 2
  current="$(tree_digest "$dst")" || return 2
  [ -n "$recorded" ] && [ "$recorded" = "$current" ] && return 0
  diff -rq --no-dereference "${DIFF_EXCL[@]}" "$src" "$dst" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) ;;
    *) return 2 ;;
  esac
  return 1
}

# move_aside <name> <dst>: move a folder sync does not own out of the skills
# index. Prints the backup path.
move_aside() {
  local name="$1" dst="$2" stamp base path n=1
  stamp="$(date -u +%Y%m%dT%H%M%SZ)" || return 1
  mkdir -p "$BACKUP_ROOT" || return 1
  base="$BACKUP_ROOT/$name-$stamp"
  path="$base"
  while [ -e "$path" ] || [ -L "$path" ]; do n=$((n + 1)); path="$base-$n"; done
  mv -- "$dst" "$path" || return 1
  printf '%s\n' "$path"
}

# restore_aside <backup> <dst>: after a failed install, drop what this run
# wrote at <dst> (nothing else was there: the folder had been moved aside) and
# move the folder back. The BACKUP line already on stdout names <backup>, which
# no longer exists, so a RESTORED line on stdout says where the folder is.
restore_aside() {
  local backup="$1" dst="$2"
  if rm -rf -- "$dst" && mv -- "$backup" "$dst"; then
    rmdir "$BACKUP_ROOT" 2>/dev/null
    echo "skills-vendor: restored $dst" >&2
    printf 'RESTORED %s: the install failed, so the folder is back at %s; the BACKUP path above no longer exists\n' "${dst##*/}" "$dst"
  else
    echo "skills-vendor: could not restore $dst; your folder is kept at $backup" >&2
  fi
}

# clean_stale: remove the staging dirs interrupted runs left in SKILLS (they
# are untracked, and the daily backup's git add -A committed them). Only
# directories named exactly like mktemp's .vendor.XXXXXX are touched. One whose
# previous/ is a mirror a kill left aside between the two renames, with its
# skill folder now missing, is moved back first: previous/ can hold the only
# copy of GUI-local files. A previous/ that cannot be placed (no name record,
# from an earlier release) goes to the backup dir, never to rm.
clean_stale() {
  local d name dest
  for d in "$SKILLS"/.vendor.??????; do
    case "${d##*/}" in .vendor.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) continue ;; esac
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    if [ -d "$d/previous" ] && [ ! -L "$d/previous" ]; then
      name=""; [ -f "$d/name" ] && name="$(head -n 1 "$d/name")"
      if [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] && [ ! -e "$SKILLS/$name" ] && [ ! -L "$SKILLS/$name" ]; then
        mv "$d/previous" "$SKILLS/$name" || { echo "skills-vendor: could not move $d/previous back to $SKILLS/$name; left it there" >&2; exit 3; }
        printf 'RESTORED %s: an interrupted sync had left it in %s; it is back in place\n' "$name" "${d##*/}"
      elif [ -z "$name" ]; then
        dest="$(move_aside "vendor-leftover" "$d/previous")" || { echo "skills-vendor: could not move $d/previous aside; left it there" >&2; exit 3; }
        printf 'BACKUP   %s: an interrupted sync left a mirror it could not place; kept at %s\n' "${d##*/}" "$dest"
      fi
    fi
    rm -rf "$d" || echo "skills-vendor: could not remove the stale staging dir $d" >&2
  done
}

drift=0
missing=0
[ "$MODE" = sync ] && clean_stale

for i in "${!names[@]}"; do
  name="${names[$i]}"
  srcdir="${sources[$i]}"
  src="${srcdir#"$PROJECTS"/}"
  dstdir="$SKILLS/$name"

  if [ "$MODE" = "--check" ]; then
    if [ ! -d "$srcdir" ]; then
      printf 'MISSING  %s (source not cloned: %s)\n' "$name" "$src"
      missing=1
    elif [ ! -d "$dstdir" ]; then
      printf 'DRIFT    %s (not vendored yet)\n' "$name"
      drift=1
    else
      out="$(diff -rq --no-dereference "${DIFF_EXCL[@]}" "$srcdir" "$dstdir" 2>&1)"
      rc=$?
      if [ "$rc" -gt 1 ]; then
        echo "skills-vendor: diff failed for $name (rc=$rc): $out" >&2
        exit 3
      elif [ "$rc" -ne 0 ]; then
        printf 'DRIFT    %s\n' "$name"
        echo "$out" | sed 's/^/         /'
        drift=1
      else
        printf 'OK       %s\n' "$name"
      fi
    fi
    continue
  fi

  # sync
  if [ ! -d "$srcdir" ]; then
    printf 'SKIP     %s (source repo not cloned: %s)\n' "$name" "$src"
    continue
  fi
  # A destination sync does not own is moved aside first (Ownership, above).
  backup=""
  if [ -d "$dstdir" ]; then
    owned_mirror "$name" "$srcdir" "$dstdir"
    case "$?" in
      0) ;;
      1)
        if ! backup="$(move_aside "$name" "$dstdir")"; then
          echo "skills-vendor: could not move $dstdir aside; left it as it was" >&2
          exit 3
        fi
        # Said now, not after the install: a failure below (or a kill) must
        # not leave the folder in the backup with nobody told where it went.
        printf 'BACKUP   %s: the existing folder was not a mirror sync wrote; kept at %s\n' "$name" "$backup"
        ;;
      *)
        echo "skills-vendor: could not tell whether $dstdir is a mirror sync wrote; left it as it was" >&2
        exit 3
        ;;
    esac
  fi
  engine=tar; [ "$USE_RSYNC" = 1 ] && engine=rsync
  if ! res="$(stage_mirror "$srcdir" "$dstdir")"; then
    echo "skills-vendor: $engine copy failed for $name; the previous mirror is unchanged" >&2
    [ -n "$backup" ] && restore_aside "$backup" "$dstdir"
    exit 3
  fi
  out=""; [ "$res" = changed ] && out="changed"
  if ! digest="$(tree_digest "$dstdir")" || ! ledger_set "$name" "$digest"; then
    echo "skills-vendor: synced $name but could not record it in $LEDGER" >&2
    exit 3
  fi
  if [ -n "$out" ]; then
    printf 'SYNCED   %s\n' "$name"
  else
    printf 'UNCHANGED %s\n' "$name"
  fi
done

if [ "$MODE" = "--check" ]; then
  [ "$drift" -ne 0 ] && exit 1
  [ "$missing" -ne 0 ] && exit 2
  exit 0
fi
exit 0
