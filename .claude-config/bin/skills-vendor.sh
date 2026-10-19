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
#   skills-vendor.sh            sync (default): rsync each source dir into
#                               SKILLS/<name>/ (rsync -a --delete). Prints one
#                               line per skill: SYNCED / UNCHANGED / SKIP.
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
# SKILLS_VENDOR_NO_RSYNC=1 forces that path (tests compare the two).

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

# tar_mirror <src> <dst>: the rsync-free sync. Builds the new mirror in a temp
# dir beside <dst> (source minus the excludes, plus <dst>'s own GUI-local files,
# which rsync's excludes protect from --delete), then swaps it in only when it
# differs. Prints "changed" or "same"; returns non-zero on any failure, leaving
# <dst> as it was.
tar_mirror() {
  local src="$1" dst="$2" tmp rel rc
  tmp="$(mktemp -d "$SKILLS/.vendor.XXXXXX")" || return 1
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
  # Keep the prior mirror until installation succeeds. -T prevents a concurrent
  # destination directory or symlink from turning the rename into a nested move.
  if [ -d "$dst" ]; then
    mv -T "$dst" "$tmp/previous" || { rm -rf "$tmp"; return 1; }
  fi
  if ! mv -T "$tmp/tree" "$dst"; then
    if [ -d "$tmp/previous" ] && ! mv -T "$tmp/previous" "$dst"; then
      echo "skills-vendor: restore failed; previous mirror retained at $tmp/previous" >&2
      return 1
    fi
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp" || return 1
  echo changed
}

drift=0
missing=0

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
  if [ "$USE_RSYNC" = 1 ]; then
    mkdir -p "$dstdir" || exit 3
    # --checksum: rsync's default quick check skips a file whose size and mtime
    # match, so an edit that kept the size within the same second stayed DRIFT
    # (--check compares content) while sync said UNCHANGED. Skill dirs are
    # small; comparing content costs nothing.
    out="$(rsync -ai --checksum --delete "${RSYNC_EXCL[@]}" "$srcdir"/ "$dstdir"/ 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "skills-vendor: rsync failed for $name (rc=$rc)" >&2
      [ -n "$out" ] && echo "$out" >&2
      exit 3
    fi
  else
    if ! res="$(tar_mirror "$srcdir" "$dstdir")"; then
      echo "skills-vendor: tar copy failed for $name" >&2
      exit 3
    fi
    out=""; [ "$res" = changed ] && out="changed"
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
