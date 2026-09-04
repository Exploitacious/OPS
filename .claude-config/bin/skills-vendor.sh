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
# uncloned source repo trips the drift gate. On a fresh fork the source repos are
# not cloned yet, so MISSING (WARN) is the normal state until you clone them.

set -uo pipefail

ROOT="$HOME/OPS"
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
command -v rsync >/dev/null 2>&1 || { echo "skills-vendor: rsync not found" >&2; exit 3; }

MODE="${1:-sync}"
case "$MODE" in
  sync|--check) ;;
  *) echo "usage: skills-vendor.sh [sync|--check]" >&2; exit 3 ;;
esac

# Build the exclude args once, in both rsync and diff shapes.
RSYNC_EXCL=(--exclude='.git')
DIFF_EXCL=(-x '.git')
for g in "${GUI_LOCAL[@]}"; do
  RSYNC_EXCL+=(--exclude="$g")
  DIFF_EXCL+=(-x "$g")
done

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
  mkdir -p "$dstdir"
  out="$(rsync -ai --delete "${RSYNC_EXCL[@]}" "$srcdir"/ "$dstdir"/ 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "skills-vendor: rsync failed for $name (rc=$rc)" >&2
    [ -n "$out" ] && echo "$out" >&2
    exit 3
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
