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

PROJECTS="$ROOT/PROJECTS"
SKILLS="$ROOT/SKILLS"
MANIFEST="$SKILLS/VENDORED.tsv"

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
for g in "${GUI_LOCAL[@]}"; do
  RSYNC_EXCL+=(--exclude="$g")
  TAR_EXCL+=(--exclude="$g")
  DIFF_EXCL+=(-x "$g")
done

# tar_mirror <src> <dst>: the rsync-free sync. Builds the new mirror in a temp
# dir beside <dst> (source minus the excludes, plus <dst>'s own GUI-local files,
# which rsync's excludes protect from --delete), then swaps it in only when it
# differs. Prints "changed" or "same"; returns non-zero on any failure, leaving
# <dst> as it was.
tar_mirror() {
  local src="$1" dst="$2" tmp rel g
  tmp="$(mktemp -d "$SKILLS/.vendor.XXXXXX")" || return 1
  if ! (cd "$src" && tar "${TAR_EXCL[@]}" -cf - .) | (cd "$tmp" && tar -xf -); then
    rm -rf "$tmp"; return 1
  fi
  if [ -d "$dst" ]; then
    for g in "${GUI_LOCAL[@]}"; do
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        mkdir -p "$tmp/$(dirname "$rel")" && cp -p "$dst/$rel" "$tmp/$rel" || { rm -rf "$tmp"; return 1; }
      done < <(cd "$dst" && find . -type f -name "$g")
    done
  fi
  if [ -d "$dst" ] && diff -rq "$tmp" "$dst" >/dev/null 2>&1; then
    rm -rf "$tmp"; echo same; return 0
  fi
  rm -rf "$dst" && mv "$tmp" "$dst" || { rm -rf "$tmp"; return 1; }
  chmod 755 "$dst"   # mktemp -d creates 0700; match a normal checkout dir
  echo changed
}

drift=0
missing=0

while IFS=$'\t' read -r name src || [ -n "$name" ]; do
  case "$name" in ''|'#'*) continue ;; esac
  [ -n "$src" ] || { echo "skills-vendor: malformed manifest row (no source): '$name'" >&2; exit 3; }
  # rsync --delete aims at $SKILLS/$name; refuse any row that could escape it
  case "$name" in *..*|*/*) echo "skills-vendor: unsafe manifest name: '$name'" >&2; exit 3 ;; esac
  case "$src" in *..*|/*) echo "skills-vendor: unsafe manifest source: '$src'" >&2; exit 3 ;; esac

  srcdir="$PROJECTS/$src"
  dstdir="$SKILLS/$name"

  if [ "$MODE" = "--check" ]; then
    if [ ! -d "$srcdir" ]; then
      printf 'MISSING  %s (source not cloned: %s)\n' "$name" "$src"
      missing=1
    elif [ ! -d "$dstdir" ]; then
      printf 'DRIFT    %s (not vendored yet)\n' "$name"
      drift=1
    else
      out="$(diff -rq "${DIFF_EXCL[@]}" "$srcdir" "$dstdir" 2>&1)"
      if [ -n "$out" ]; then
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
    mkdir -p "$dstdir"
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
done < "$MANIFEST"

if [ "$MODE" = "--check" ]; then
  [ "$drift" -ne 0 ] && exit 1
  [ "$missing" -ne 0 ] && exit 2
  exit 0
fi
exit 0
