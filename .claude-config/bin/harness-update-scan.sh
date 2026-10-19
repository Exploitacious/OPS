#!/usr/bin/env bash
# harness-update-scan.sh: the mechanical half of the harness-update skill.
#
# Classifies how the local (private, personalized) OPS copy differs from the
# PUBLIC upstream template, so the judgment half (SKILLS/harness-update/SKILL.md)
# can decide what to pull. The risk direction is one-way and that shapes every
# rule here: this pulls PUBLIC template code INTO a PRIVATE repo, so a wrong copy
# breaks the Operator's personalization, which is worse than a missed update. Therefore
# identity/memory/handoff surfaces are hard-excluded in BOTH directions, and the
# CONFLICT class is never auto-applied.
#
# Usage (from inside the OPS copy: it scans the repo of the working directory):
#   harness-update-scan.sh                 report only (default): classify, print, touch nothing
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
# Never git-commits. Never writes the marker: the skill updates last_synced to
# the fetched sha at commit time, so a report-only run leaves zero state behind.
#
# Env overrides: OPS_UPSTREAM (owner/repo), OPS_UPSTREAM_BRANCH (default main),
# OPS_REMOTE (default ops-template).
#
# Classes compare (mode, blob), not the blob alone, so a mode-only change (a
# script made executable upstream) is an UPDATE when the local mode still
# matches the last-synced one, and a MODE line (same content, different exec
# bit) otherwise; MODE is reported, never applied. A template symlink is
# applied as a symlink.
#
# Exit: 0 = scan ran · 2 ERR_USAGE · 3 ERR_NOREPO (not inside an OPS copy) ·
#       4 ERR_REMOTE · 5 ERR_FETCH · 6 ERR_APPLY
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
    *) echo "ERR_USAGE: unknown arg '$arg'; usage: harness-update-scan.sh [--apply-safe] [--verbose]" >&2; exit 2 ;;
  esac
done

# Self-contained by contract: copies that predate this script run it straight
# from the template (git show ops-template/main:<this path> > tmp; bash tmp), so
# it finds its root from the cwd and must never source a helper file from the
# repo. tests/harness-update-scan-test.sh pins this.
# The scan must run inside the OPS working tree: it compares the tree, not HEAD,
# so the Operator's uncommitted personalization is part of the input.
OPS_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERR_NOREPO: not inside a git repository (run from the OPS working tree: cd ~/OPS)" >&2; exit 3; }
cd "$OPS_ROOT" || { echo "ERR_NOREPO: cannot cd to repo root $OPS_ROOT" >&2; exit 3; }
# Refuse any repo that is not an OPS copy, before the first write. The scan
# acts on the cwd's repo, so run from a project clone it added the
# ops-template remote there and --apply-safe copied the whole template into it
# (2026-10-19). Every OPS copy has BOOTSTRAP.md (every template commit since the
# first release carries it) or .claude-config/ (which holds the marker).
if [ ! -f BOOTSTRAP.md ] && [ ! -d .claude-config ] && [ ! -f .claude-config/ops-upstream-ref ]; then
  echo "ERR_NOREPO: $OPS_ROOT is not an OPS copy (no BOOTSTRAP.md, no .claude-config/); nothing was changed." >&2
  echo "  Run the scan from inside your copy, for example: (cd ~/OPS && bash <this script> [--apply-safe])" >&2
  exit 3
fi

MARKER=".claude-config/ops-upstream-ref"

# --- resolve upstream + baseline from the marker (defaults on first sync) ---
UPSTREAM="$DEFAULT_UPSTREAM"
LAST_SYNCED=""
if [ -f "$MARKER" ]; then
  # `|| [ -n "$k" ]` keeps a last line with no trailing newline (Notepad, a
  # printf without \n): plain `read` returns 1 on it and the loop would drop
  # last_synced, silently turning a delta scan into a first-sync compare.
  while IFS='=' read -r k v || [ -n "$k" ]; do
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

# --- translate a marker from before the 2026-10-19 history rewrite ---
# The template's main was rewritten with git filter-repo on 2026-10-19 to remove
# a private name from one old commit. Every commit got a new SHA; every tree is
# identical except that commit's. A copy synced before then holds a last_synced
# the template no longer has, which would drop the scan into a first-sync
# compare (every difference a CONFLICT). Its rewritten twin has the same tree, so
# the delta stays exact. OPS_REWRITE_MAP adds "old new" lines (tests, or a
# future rewrite).
REWRITE_MAP="
  06ec12e4711fade9484c5eee13624a2ca0563a4a 90426aab098171bb9d41184b9d19b4faed8c7afa
  13863529aca24dd367ee647fd6d049144cb5273a 904349179797cd9b35b451dcdc71275f1fdfcfb9
  187ccb80f01d11389107a4c7c088c8dfde52871e 0fd2665eb85d7dd61fad18e9b8b7e7e2c6ad2859
  1c4290f7053d021643624e35327ea30ecce8ba46 2f90cf1848d37e1695ebd2f5680a4c61663fc659
  2ba5f4f67546233babf56f2efc4925b66f75e612 cc53e07fd0e28fc73d5a96711f82509a26569dae
  34b7c5aa931789b9902aa9ccba8a387d44c69c25 7f18131fc3592dce052441d3385cf8686643d7b4
  48da2de5e29dc64e03b8de3027456e8a709524c9 351dfcc152ab7f37237a28a065932da5790a3edd
  493b59167647a18a3ff3f80d07302a36cc7a98da 86aecb6946fba7e63e933c670be89ae40b321f2f
  4c8e095542903f1c76baaa4ed69f9bda89b5aa01 7965a9c1a552f2b8919b90e77a6744fa9b78bd3f
  4d5bf0e3d3ea92728d7f8bc2b570eb0dadbf1a48 f441bc9a543e03c885b0c6fd9b8d2ae45a9683f1
  55b60bbe08de529dbc4e5297b1c8f79063e89332 899200cc5f491b9a76bb7358800c1972f82e3c46
  59187502c614ef0c9433be3ad1f94789d273c0d2 b7348e397939f0061383cc4d61c574b9087666a4
  5ee76b9f3aa4d7ede7bdf73ae21774c5451ab845 d0fbde9fe2f533ce2abdc0677f9b7227f00880f6
  737268f3797ed4b059aa8b82f1ff895b99b12ae6 a0c4ebd124bc39caa09489523b474076fbce8d51
  7a12c51f3367faba92bb699fcc22c6ce10063dac 659bf415e8db70474361dc5356a3b393f9f098eb
  7f78b62f16a6d20080a3b32fadb37c6a7d79e648 73916c876fe9567bdfd26044805df133bf9946a0
  84e48b0b3d5c18bc8a1df1912fc49d169fff29e1 d53c3b1d25a375ce4eef393f12f6eaef909f0548
  96e7976ea32a590efc844cb0ce741e7e12968bd3 06646490e71c1127e7c42e693c29feb0cf9d9ba5
  a01ab68bb43313e497f14f9b11f842a241236c23 8013f9e2a045afcdb9bd65f5a6afa8ce809e9d85
  a2ce6ea553ef4e2239741559625b7cb397e4bea9 e7a915998755962cc784eba1fc2b7b6763307d02
  a3892f087c26b2f239bba998ee61e091086200a7 c5858b6b0372cccfc4b50acdcc62c1da4172f926
  a4b7f2ec8657aaa734007d56c09b1b5baa57b441 ce6bbbab6a1ca2478d39eb46f87744041cd1ef47
  a5dbc059feefec379772f2130a9d92ac77874fe1 0ed150489085537cf396e95d922b5d8a1213b96b
  a5e0ae3c320645397f4ef50a679f7dba26d2a8fe 629efe85d09f338e28e9d2cc19300799e2efdb24
  ac036f9cfec9f07630cd76cc66ddc5e89e2b4021 0458b3beb7c4093235bb77722b5c577860c95007
  aca18753e1bb9ebf911aa6ee6d8385acc5436c0d 480450a315883d6a3df3da564e954869e3d2823b
  ad8c20d60008aafc32664f490c95f23ee45411c1 7834e4c2ba9ebecf84027b3ff16ee784d9fc259f
  b1ceefeef70afae5a8f5134a51880e83d876d621 4bdfb7d71edc3783d36ff9abb12ade324ae5211d
  b7c0977570dcd977cc5485758993b1a0d25a4ff9 f63a8f1d25f3c1e51906bb590133f1cb4b6053c5
  bc462f49f324d4468cdb3666757e2c5c88490052 e1303922e1e55b728a1f9bf9d9281bef69d6c6ad
  ce25ccfdc66949de2f3c6160e7cd829837476298 7ee78297700f540acf0496a220463a8a09e7d2b5
  cfcde73f3fc80115639ec5e4adb4955e765daa02 da991d6e528a77d5fe99859c40d1b1dd64a6cca2
  d987ffedfa4d474a025691eb9322fb837ab3b07e 9bcd1499ac64f70b384e1f56f80dc8805fbc2b27
  db76b1d68aa16e3a4a209f860fcc016cd699bca8 01dc15ee34a94dc066e6ce845659d4cf0a859d7f
  eb92f3767b7a677ad4397e42e1f9ed58dc06147b 1b288f3cf3bbd7761be5e4c8a8e742b9d7a2e484
  f87bd96b034dd8529d67d7220f4735634881669f d771aae7ae447d0d713e1ed56c00a1eec4135efc
${OPS_REWRITE_MAP:-}"
if [ -n "$LAST_SYNCED" ] && [ "${#LAST_SYNCED}" -ge 7 ]; then
  TWIN="$(printf '%s\n' "$REWRITE_MAP" | awk -v want="$LAST_SYNCED" \
    'NF==2 && index($1, want)==1 {print $2; exit}')"
  if [ -n "$TWIN" ]; then
    echo "NOTE: last_synced ${LAST_SYNCED:0:12} predates the 2026-10-19 history rewrite; using its rewritten twin ${TWIN:0:12} (same tree). The marker gets the new sha at the next sync commit." >&2
    LAST_SYNCED="$TWIN"
  fi
fi

# --- pick the mode: delta needs a marker sha that is a real, fetched commit ---
MODE="first-sync"
if [ -n "$LAST_SYNCED" ]; then
  if git cat-file -e "${LAST_SYNCED}^{commit}" 2>/dev/null; then
    MODE="delta"
  else
    echo "WARN: last_synced '$LAST_SYNCED' is not a known commit; falling back to first-sync compare" >&2
  fi
fi

# Hard exclusion: the Operator's identity + private working surfaces. These never
# sync in EITHER direction and are never even named in the report (naming a
# private file is itself a boundary crossing). The category list is printed in the
# header so the Operator sees where the boundary sits.
#
# Current names first: the identity templates BOOTSTRAP fills (USER.md, voice.md,
# standing-orders.md), the context slots it fills with the Operator's own systems
# and people (work-tracking.md, team.md, tools.md), and the marker. Then the
# retired names, kept on purpose: the template deletes them, so without this line
# a delta scan would list a filled, not-yet-migrated identity file as REMOVED and
# invite its deletion before its content has moved (DEPLOYMENT.md, "Migrating to
# the core boot"). verify-ops.sh check 23 fails if any of these names drop out.
is_excluded() {
  case "$1" in
    CONTEXT/USER.md|CONTEXT/voice.md|CONTEXT/standing-orders.md|CONTEXT/.bootstrapped) return 0 ;;
    CONTEXT/work-tracking.md|CONTEXT/team.md|CONTEXT/tools.md) return 0 ;;
    CONTEXT/about-me.md|CONTEXT/brand-voice.md|CONTEXT/working-preferences.md|CONTEXT/boot-digest.md) return 0 ;;
    CONTEXT/projects/*) return 0 ;;
    .claude-memory/*|.claude-handoffs/*|NOTES/*|DELIVERABLES/*|PROJECTS/*|ARCHIVE/*) return 0 ;;
  esac
  return 1
}

# Replacing the leaf safely is not enough: a personalized parent directory
# may be a symlink outside this copy, or into excluded CONTEXT identity files.
# Treat every symlink ancestor as a manual conflict, even one pointing inside
# the repo, so spelling a public path cannot bypass the private-path boundary.
has_symlink_ancestor() {
  local rest="$1" parent="$OPS_ROOT" part
  while [[ "$rest" = */* ]]; do
    part="${rest%%/*}"; rest="${rest#*/}"; parent="$parent/$part"
    [ -L "$parent" ] && return 0
  done
  return 1
}

# Entries are "<mode> <blob>". A blob sha does not include the mode, so a file
# made executable upstream with the same content compared IDENTICAL and was
# never applied, and a copy whose scripts lost the exec bit was never told.
# Paths are literal, never pathspecs.
tree_entry() { GIT_LITERAL_PATHSPECS=1 git ls-tree "$1" -- "$2" 2>/dev/null | awk '$2 != "tree" {print $1 " " $3; exit}'; }
up_entry()   { tree_entry "$UP_REF" "$1"; }                                # empty if absent upstream
base_entry() { [ -n "$LAST_SYNCED" ] && tree_entry "$LAST_SYNCED" "$1"; }  # empty if absent at last sync
# Where the filesystem keeps no exec bit (core.fileMode=false: Windows, some
# mounts), the local mode comes from the index, or upstream's for an untracked
# file, so the bit never reads as a difference.
FILEMODE="$(git config --bool core.fileMode 2>/dev/null)" || FILEMODE=true
# loc_entry <path>: the local "<mode> <blob>", empty when absent. The blob goes
# through the same filters git applies on commit (--path honors .gitattributes
# eol/normalization), so a CRLF checkout does not read as a false CONFLICT. A
# symlink hashes as git stores it (its target), never the file it points to.
# Exit 2 when the path exists but cannot be read as a file or link (a hash
# failure, a directory in the way): that must never read as "absent" and NEW.
loc_entry() {
  local f="$OPS_ROOT/$1" sha mode t
  if [ -L "$f" ]; then
    t="$(readlink "$f")" && sha="$(printf '%s' "$t" | git hash-object --stdin 2>/dev/null)" || return 2
    printf '120000 %s' "$sha"
  elif [ -f "$f" ]; then
    sha="$(git hash-object --path "$1" -- "$f" 2>/dev/null)" && [ -n "$sha" ] || return 2
    if [ "$FILEMODE" = false ]; then
      mode="$(GIT_LITERAL_PATHSPECS=1 git ls-files -s -- "$1" 2>/dev/null | awk '{print $1; exit}')"
      [ -n "$mode" ] || mode="${2%% *}"
    elif [ -x "$f" ]; then mode=100755
    else mode=100644; fi
    printf '%s %s' "${mode:-100644}" "$sha"
  elif [ -e "$f" ]; then
    return 2
  fi
}

# Only files upstream changed since last sync. --no-renames is required: git
# diff detects renames by default (diff.renames, git 2.9+), and a rename line
# carries two paths, so the renamed file dropped out of the delta (never NEW,
# old path never REMOVED) and the next sync commit advanced last_synced past it
# for good. With --no-renames a rename is a D (old path, REMOVED) plus an A (new
# path, NEW). --name-only drops the status column, and -z stops git C-quoting
# unusual paths, which would match no blob. The list stays NUL-delimited to the
# reader, so a path holding a newline is one path, not two fragments.
candidates_delta() { git diff --no-renames --name-only -z "$LAST_SYNCED..$UP_REF"; }
candidates_first() { git ls-tree -r --name-only -z "$UP_REF"; }  # every upstream file (local-only paths never enter here)

gen_candidates() { if [ "$MODE" = delta ]; then candidates_delta; else candidates_first; fi; }

NEW=0; UPD=0; CON=0; IDENT=0; REM=0; EXC=0; MODES=0
APPLY_LIST=()
SEEN=$'\n'   # the delta's paths, so the mode audit below skips them

is_file_mode() { case "$1" in 100644|100755) return 0 ;; esac; return 1; }

classify_one() {
  local path="$1" up loc base rc=0
  if is_excluded "$path"; then EXC=$((EXC+1)); return 0; fi
  SEEN="$SEEN$path"$'\n'
  if has_symlink_ancestor "$path"; then
    echo "CONFLICT  $path (symlink ancestor; check the destination by hand)"; CON=$((CON+1)); return 0
  fi
  up="$(up_entry "$path")"
  loc="$(loc_entry "$path" "$up")" || rc=$?
  if [ -z "$up" ]; then
    # gone from upstream. Never auto-delete a local file; surface it for a manual call.
    if [ -n "$loc" ] || [ "$rc" -ne 0 ]; then echo "REMOVED   $path"; REM=$((REM+1)); fi
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    echo "CONFLICT  $path (the local path cannot be read as a file; check it by hand)"; CON=$((CON+1)); return 0
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
  # (Operator never touched it) → a safe fast-forward. A mode-only difference is
  # an UPDATE too when the local mode is still the last-synced one. Otherwise
  # both sides moved.
  if [ "$MODE" = delta ]; then
    base="$(base_entry "$path")"
    if [ -n "$base" ] && { [ "$loc" = "$base" ] || { [ "${loc#* }" = "${up#* }" ] && [ "${loc%% *}" = "${base%% *}" ]; }; }; then
      echo "UPDATE    $path"; UPD=$((UPD+1)); APPLY_LIST+=("$path"); return 0
    fi
  fi
  if [ "${loc#* }" = "${up#* }" ] && is_file_mode "${loc%% *}" && is_file_mode "${up%% *}"; then
    mode_line "$path" "${loc%% *}" "${up%% *}"; return 0
  fi
  echo "CONFLICT  $path"; CON=$((CON+1)); return 0
}

mode_line() {
  local fix="a+x"; [ "$3" = 100644 ] && fix="a-x"
  echo "MODE      $1 (local $2, upstream $3: same content; chmod $fix if you did not change it on purpose)"
  MODES=$((MODES+1))
}

# Delta mode visits only what upstream changed, so a script an earlier scanner
# wrote without its exec bit (the copy then failed deploy's memory-init check)
# was never seen. This pass reports every other upstream file whose content
# matches but whose exec bit differs. Never applied: the bit may be on purpose.
mode_audit() {
  [ "$FILEMODE" = false ] && return 0
  local entry mode rest sha path f lm
  while IFS= read -r -d '' entry; do
    mode="${entry%% *}"; rest="${entry#* }"; rest="${rest#* }"
    sha="${rest%%$'\t'*}"; path="${entry#*$'\t'}"
    is_file_mode "$mode" || continue
    is_excluded "$path" && continue
    has_symlink_ancestor "$path" && continue
    case "$SEEN" in *$'\n'"$path"$'\n'*) continue ;; esac
    f="$OPS_ROOT/$path"
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    if [ -x "$f" ]; then lm=100755; else lm=100644; fi
    [ "$lm" = "$mode" ] && continue
    [ "$(git hash-object --path "$path" -- "$f" 2>/dev/null)" = "$sha" ] || continue
    mode_line "$path" "$lm" "$mode"
  done < <(git ls-tree -r -z "$UP_REF")
}

# The mode comes from the upstream tree entry, not the redirect: `> dest`
# creates a NEW file at the umask mode (no exec bit) and keeps an UPDATE file's
# old mode, so a template script arrived non-executable and deploy.sh's
# `[[ -x memory-init ]]` failed the migration. 100755 means executable; any
# other blob mode clears the bit, as a checkout would. chmod names who (a+x,
# a-x): a bare +x/-x is filtered by the umask, which under 027 left group or
# other bits behind and made chmod fail. A 120000 entry is a symlink and is
# created as one (`> dest` wrote its target as text). Each file is built
# beside its destination and renamed into place: the old path (a symlink, or
# this script while it runs) is replaced, never written through.
apply_safe() {
  local path dest dir mode tmp target rc=0 n=0
  for path in "${APPLY_LIST[@]}"; do
    # Recheck at the write boundary: the working tree can change after the scan.
    if has_symlink_ancestor "$path"; then
      echo "ERR_APPLY: symlink ancestor for $path; nothing copied there" >&2; rc=1; continue
    fi
    dest="$OPS_ROOT/$path"; dir="$(dirname "$dest")"
    mode="$(tree_entry "$UP_REF" "$path")"; mode="${mode%% *}"
    if [ -z "$mode" ]; then
      echo "ERR_APPLY: no tree entry for $path in $UP_REF" >&2; rc=1; continue
    fi
    if [ -d "$dest" ] && [ ! -L "$dest" ]; then
      echo "ERR_APPLY: a directory is in the way of $path" >&2; rc=1; continue
    fi
    mkdir -p "$dir" || { echo "ERR_APPLY: mkdir failed for $path" >&2; rc=1; continue; }
    n=$((n + 1)); tmp="$dir/.harness-update.$$.$n"
    rm -f "$tmp"
    if [ "$mode" = 120000 ]; then
      target="$(git cat-file -p "$UP_REF:$path" 2>/dev/null)" && ln -s "$target" "$tmp" \
        || { rm -f "$tmp"; echo "ERR_APPLY: could not create the symlink $path" >&2; rc=1; continue; }
    else
      git cat-file -p "$UP_REF:$path" > "$tmp" 2>/dev/null \
        || { rm -f "$tmp"; echo "ERR_APPLY: could not write $path" >&2; rc=1; continue; }
      if [ "$mode" = 100755 ]; then chmod a+x "$tmp"; else chmod a-x "$tmp"; fi \
        || { rm -f "$tmp"; echo "ERR_APPLY: could not set mode $mode on $path" >&2; rc=1; continue; }
    fi
    # rm first: mv onto a symlink to a directory would move into that directory.
    if { [ -e "$dest" ] || [ -L "$dest" ]; } && ! rm -f "$dest"; then
      rm -f "$tmp"; echo "ERR_APPLY: could not replace $path" >&2; rc=1; continue
    fi
    mv "$tmp" "$dest" || { rm -f "$tmp"; echo "ERR_APPLY: could not move $path into place" >&2; rc=1; continue; }
    echo "OK applied $path"
  done
  return $rc
}

# --- report ---
echo "# harness-update scan: $(date -Is)"
echo "# upstream: $UPSTREAM ($UP_REF @ ${UP_SHA:0:12})"
if [ "$MODE" = delta ]; then
  echo "# mode: delta since last_synced ${LAST_SYNCED:0:12}"
else
  echo "# mode: first-sync (no baseline: differences classify as CONFLICT, not UPDATE)"
fi
echo "# hard-excluded (both directions, never listed): CONTEXT identity files"
echo "#   (USER, voice, standing-orders, work-tracking, team, tools, .bootstrapped, projects/,"
echo "#   and the retired about-me, brand-voice, working-preferences, boot-digest),"
echo "#   .claude-memory/ .claude-handoffs/ NOTES/ DELIVERABLES/ PROJECTS/ ARCHIVE/"
echo "# classes: NEW=safe copy · UPDATE=fast-forward copy · CONFLICT=port by hand ·"
echo "#   MODE=same content, exec bit differs (chmod by hand) · IDENTICAL=in sync ·"
echo "#   REMOVED=upstream deleted (manual call). local-only files hidden."
[ "$APPLY" = 1 ] && echo "# --apply-safe: copying NEW + UPDATE only"
echo "#"

while IFS= read -r -d '' p; do
  [ -n "$p" ] && classify_one "$p"
done < <(gen_candidates)
[ "$MODE" = delta ] && mode_audit

echo "#"
echo "# summary: $NEW new · $UPD update · $CON conflict · $MODES mode · $IDENT identical · $REM removed ($EXC excluded)"

if [ "$APPLY" = 1 ]; then
  if [ "${#APPLY_LIST[@]}" -eq 0 ]; then
    echo "OK --apply-safe: nothing to copy (no NEW/UPDATE)"
  else
    echo "# applying ${#APPLY_LIST[@]} safe file(s): NEW + UPDATE only, never CONFLICT ..."
    apply_safe || exit 6
  fi
  echo "# marker NOT written, nothing committed; the skill sets last_synced=$UP_SHA at commit time"
fi
