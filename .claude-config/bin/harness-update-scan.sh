#!/usr/bin/env bash
# harness-update-scan.sh — the mechanical half of the harness-update skill.
#
# Classifies how the local (private, personalized) OPS copy differs from the
# PUBLIC upstream template, so the judgment half (SKILLS/harness-update/SKILL.md)
# can decide what to pull. The risk direction is one-way and that shapes every
# rule here: this pulls PUBLIC template code INTO a PRIVATE repo, so a wrong copy
# breaks the Operator's personalization — worse than a missed update. Therefore
# identity/memory/handoff surfaces are hard-excluded in BOTH directions, and the
# CONFLICT class is never auto-applied.
#
# Usage:
#   harness-update-scan.sh                 report only (default) — classify, print, touch nothing
#   harness-update-scan.sh --apply-safe     copy NEW + UPDATE classes only; never CONFLICT, never delete
#   harness-update-scan.sh --verbose        also list IDENTICAL files (default: counted, not listed)
#   (flags combine, any order)
#
# Reads the sync-state marker .claude-config/ops-upstream-ref:
#   upstream=<owner/repo>      default Exploitacious/OPS
#   last_synced=<sha>          the upstream commit last pulled
# No marker → first-sync mode: full tree compare, no baseline, so any difference
# is a CONFLICT (UPDATE is not computable without a known last-synced version).
#
# Never git-commits. Never writes the marker — the skill updates last_synced to
# the fetched sha at commit time, so a report-only run leaves zero state behind.
#
# Env overrides: OPS_UPSTREAM (owner/repo), OPS_UPSTREAM_BRANCH (default main),
# OPS_REMOTE (default ops-template).
#
# Exit: 0 = scan ran · 2 ERR_USAGE · 3 ERR_NOREPO · 4 ERR_REMOTE · 5 ERR_FETCH ·
#       6 ERR_APPLY
set -uo pipefail

REMOTE="${OPS_REMOTE:-ops-template}"
BRANCH="${OPS_UPSTREAM_BRANCH:-main}"
DEFAULT_UPSTREAM="Exploitacious/OPS"

APPLY=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --apply-safe) APPLY=1 ;;
    --verbose|-v)  VERBOSE=1 ;;
    "") ;;
    *) echo "ERR_USAGE: unknown arg '$arg' — harness-update-scan.sh [--apply-safe] [--verbose]" >&2; exit 2 ;;
  esac
done

# The scan must run inside the OPS working tree — it compares the tree, not HEAD,
# so the Operator's uncommitted personalization is part of the input.
OPS_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERR_NOREPO: not inside a git repository (run from the OPS working tree)" >&2; exit 3; }
cd "$OPS_ROOT" || { echo "ERR_NOREPO: cannot cd to repo root $OPS_ROOT" >&2; exit 3; }

MARKER=".claude-config/ops-upstream-ref"

# --- resolve upstream + baseline from the marker (defaults on first sync) ---
UPSTREAM="$DEFAULT_UPSTREAM"
LAST_SYNCED=""
if [ -f "$MARKER" ]; then
  while IFS='=' read -r k v; do
    v="${v%$'\r'}"   # tolerate a CRLF marker on Windows checkouts
    case "$k" in
      upstream)    [ -n "$v" ] && UPSTREAM="$v" ;;
      last_synced) LAST_SYNCED="$v" ;;
    esac
  done < "$MARKER"
fi
[ -n "${OPS_UPSTREAM:-}" ] && UPSTREAM="$OPS_UPSTREAM"

# --- ensure the ops-template remote exists, then fetch it (HTTPS: no SSH key
# needed to read a public template) ---
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  git remote add "$REMOTE" "https://github.com/$UPSTREAM.git" \
    || { echo "ERR_REMOTE: could not add remote $REMOTE -> $UPSTREAM" >&2; exit 4; }
  echo "OK added remote $REMOTE -> https://github.com/$UPSTREAM.git"
fi
if ! git fetch --quiet "$REMOTE" 2>/dev/null; then
  echo "ERR_FETCH: git fetch $REMOTE failed (network down, or wrong upstream '$UPSTREAM'?)" >&2
  exit 5
fi
UP_REF="$REMOTE/$BRANCH"
UP_SHA="$(git rev-parse "$UP_REF" 2>/dev/null)" || {
  echo "ERR_FETCH: $UP_REF not found after fetch (wrong branch '$BRANCH'?)" >&2; exit 5; }
echo "OK fetched $UP_REF @ ${UP_SHA:0:12}"

# --- pick the mode: delta needs a marker sha that is a real, fetched commit ---
MODE="first-sync"
if [ -n "$LAST_SYNCED" ]; then
  if git cat-file -e "${LAST_SYNCED}^{commit}" 2>/dev/null; then
    MODE="delta"
  else
    echo "WARN: last_synced '$LAST_SYNCED' is not a known commit — falling back to first-sync compare" >&2
  fi
fi

# Hard exclusion: the Operator's identity + private working surfaces. These never
# sync in EITHER direction and are never even named in the report (naming a
# private file is itself a boundary crossing). The category list is printed in the
# header so the Operator sees where the boundary sits.
is_excluded() {
  case "$1" in
    CONTEXT/about-me.md|CONTEXT/brand-voice.md|CONTEXT/working-preferences.md|CONTEXT/.bootstrapped) return 0 ;;
    CONTEXT/projects/*) return 0 ;;
    .claude-memory/*|.claude-handoffs/*|NOTES/*|DELIVERABLES/*|PROJECTS/*|ARCHIVE/*) return 0 ;;
  esac
  return 1
}

up_blob()   { git rev-parse -q --verify "$UP_REF:$1"      2>/dev/null; }  # blob sha upstream, empty if absent
base_blob() { git rev-parse -q --verify "$LAST_SYNCED:$1" 2>/dev/null; }  # blob sha at last sync, empty if absent
# Local blob sha via the same filters git would apply on commit (--path honors
# .gitattributes eol/normalization) so a CRLF working-tree checkout does not read
# as a false CONFLICT against the LF-normalized upstream blob.
loc_blob()  { [ -f "$OPS_ROOT/$1" ] && git hash-object --path "$1" -- "$OPS_ROOT/$1" 2>/dev/null; }

candidates_delta() {  # only files upstream changed since last sync (renames decompose to D+A, no -M)
  git diff --name-status "$LAST_SYNCED..$UP_REF" | while IFS=$'\t' read -r _status path; do
    [ -n "$path" ] && printf '%s\n' "$path"
  done
}
candidates_first() { git ls-tree -r --name-only "$UP_REF"; }  # every upstream file (local-only paths never enter here)

gen_candidates() { if [ "$MODE" = delta ]; then candidates_delta; else candidates_first; fi; }

NEW=0; UPD=0; CON=0; IDENT=0; REM=0; EXC=0
APPLY_LIST=()

classify_one() {
  local path="$1" up loc base
  if is_excluded "$path"; then EXC=$((EXC+1)); return 0; fi
  up="$(up_blob "$path")"
  loc="$(loc_blob "$path")"
  if [ -z "$up" ]; then
    # gone from upstream. Never auto-delete a local file; surface it for a manual call.
    if [ -n "$loc" ]; then echo "REMOVED   $path"; REM=$((REM+1)); fi
    return 0
  fi
  if [ -z "$loc" ]; then
    echo "NEW       $path"; NEW=$((NEW+1)); APPLY_LIST+=("$path"); return 0
  fi
  if [ "$up" = "$loc" ]; then
    IDENT=$((IDENT+1))
    [ "$VERBOSE" = 1 ] && echo "IDENTICAL $path"
    return 0
  fi
  # differs upstream. UPDATE only when local still matches the last-synced version
  # (Operator never touched it) → a safe fast-forward. Otherwise both sides moved.
  if [ "$MODE" = delta ]; then
    base="$(base_blob "$path")"
    if [ -n "$base" ] && [ "$loc" = "$base" ]; then
      echo "UPDATE    $path"; UPD=$((UPD+1)); APPLY_LIST+=("$path"); return 0
    fi
  fi
  echo "CONFLICT  $path"; CON=$((CON+1)); return 0
}

apply_safe() {
  local path dest rc=0
  for path in "${APPLY_LIST[@]}"; do
    dest="$OPS_ROOT/$path"
    mkdir -p "$(dirname "$dest")" || { echo "ERR_APPLY: mkdir failed for $path" >&2; rc=1; continue; }
    if git cat-file -p "$UP_REF:$path" > "$dest" 2>/dev/null; then
      echo "OK applied $path"
    else
      echo "ERR_APPLY: could not write $path" >&2; rc=1
    fi
  done
  return $rc
}

# --- report ---
echo "# harness-update scan — $(date -Is)"
echo "# upstream: $UPSTREAM ($UP_REF @ ${UP_SHA:0:12})"
if [ "$MODE" = delta ]; then
  echo "# mode: delta since last_synced ${LAST_SYNCED:0:12}"
else
  echo "# mode: first-sync (no baseline — differences classify as CONFLICT, not UPDATE)"
fi
echo "# hard-excluded (both directions, never listed): CONTEXT identity files"
echo "#   (about-me, brand-voice, working-preferences, .bootstrapped, projects/),"
echo "#   .claude-memory/ .claude-handoffs/ NOTES/ DELIVERABLES/ PROJECTS/ ARCHIVE/"
echo "# classes: NEW=safe copy · UPDATE=fast-forward copy · CONFLICT=port by hand ·"
echo "#   IDENTICAL=in sync · REMOVED=upstream deleted (manual call). local-only files hidden."
[ "$APPLY" = 1 ] && echo "# --apply-safe: copying NEW + UPDATE only"
echo "#"

while IFS= read -r p; do
  [ -n "$p" ] && classify_one "$p"
done < <(gen_candidates)

echo "#"
echo "# summary: $NEW new · $UPD update · $CON conflict · $IDENT identical · $REM removed ($EXC excluded)"

if [ "$APPLY" = 1 ]; then
  if [ "${#APPLY_LIST[@]}" -eq 0 ]; then
    echo "OK --apply-safe: nothing to copy (no NEW/UPDATE)"
  else
    echo "# applying ${#APPLY_LIST[@]} safe file(s) — NEW + UPDATE only, never CONFLICT ..."
    apply_safe || exit 6
  fi
  echo "# marker NOT written, nothing committed — the skill sets last_synced=$UP_SHA at commit time"
fi
