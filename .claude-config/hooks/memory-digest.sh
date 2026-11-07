#!/usr/bin/env bash
# memory-digest.sh: SessionStart hook. Prints the memory digest (this
# directory's pool and the OPS root pool) when Claude Code's native auto-memory
# is off, so the session still starts with its memory.
#
# Why it exists. OPS keeps memory in git-synced pools under .claude-memory/,
# linked from Claude Code's per-directory memory dirs by bin/memory-init. With
# native auto-memory on, Claude Code loads each pool's MEMORY.md itself and this
# hook prints nothing. The Stage-1 settings can turn native auto-memory off
# (autoMemoryEnabled false; the current Stage-1 file does): then nothing native
# loads a pool, and this hook is the loader. It prints one block of at most
# 9,000 characters (Claude Code shows the model only a 2,000-character preview of
# a hook output past 10,000) on every SessionStart source it is registered for
# (startup, resume, clear, compact), so memory also comes back after a
# compaction, which the native load never did for a pool edited mid-session.
#
# Native on or off, in order: MEMORY_DIGEST=1 always prints and MEMORY_DIGEST=0
# never does; CLAUDE_CODE_DISABLE_AUTO_MEMORY set to 1 or true means off; then
# autoMemoryEnabled in <config>/settings.json (CLAUDE_CONFIG_DIR, else ~/.claude):
# false means off, anything else (absent included) is Claude Code's default, on.
# With no JSON parser at all the setting cannot be read, so the digest prints:
# a duplicate memory block costs less than a session with none. Project-level
# settings are not read; set MEMORY_DIGEST=1 where a project turns auto-memory
# off on its own. Whether auto-memory is on stays the owner's choice: this hook
# follows it and never changes it.
#
# Why a sibling of memory-index.sh, not an extension of it: memory-index.sh
# rewrites a pool's MEMORY.md and runs on startup|clear only, while the digest
# must print on every source and must never write. The digest itself is
# bin/memory-index --digest, beside the index writer, so the two read
# frontmatter through one parser. What it prints and in what order (pinned
# entries, then user and feedback entries, then the rest; names only past the
# budget): the --digest section of memory-index's header.
#
# Which pool: CLAUDE_PROJECT_DIR (set by Claude Code and stable across
# compactions even when the shell cd'ed), else the payload cwd, else pwd;
# memory-index maps it to its repository's main checkout and the host key. A
# directory with no pool gets the header and the routing rule, and no pool is
# ever created.
#
# Known gap (as in foreman-context.sh): a lane's own auto-compaction also fires
# SessionStart, and OPS's PreCompact writes no lane marker to tell it apart, so a
# lane gets the digest once per compaction.
#
# Quiet and bounded: no network, local reads only, a 5 s cap on the indexer,
# exit 0 always. The block is captured whole and printed once, so a crash or a
# timeout prints the one-line notice below, never a partial digest.
#
# Test env vars: MEMORY_INDEX_DIR (this directory's pool), MEMORY_DIGEST_ROOT_DIR
# (the root pool), MEMORY_DIGEST_HOST (the host key), OPS_DIR (the checkout whose
# .claude-memory/ is the store; default: this hook's own checkout).
# Test: bin/tests/memory-digest-test.sh. Run by hand: memory-digest.sh </dev/null
# (a terminal stdin is skipped, a pipe that never closes is cut at 2 s).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
OPS_H="${OPS_DIR:-$(cd "$HOOK_DIR/../.." && pwd)}"
INDEXER="$HOOK_DIR/../bin/memory-index"

notice() {
  printf 'OPS memory digest failed (%s); the full indexes are the MEMORY.md files under %s/.claude-memory/ (this directory'"'"'s pool and the root pool).\n' "$1" "$OPS_H"
  exit 0
}

# shellcheck source=hooklib.sh
. "$HOOK_DIR/hooklib.sh" 2>/dev/null || notice "cannot load hooklib.sh"

# native_memory_on: 0 when Claude Code loads the pools itself (print nothing).
native_memory_on() {
  local settings v
  case "${MEMORY_DIGEST:-}" in 1) return 1 ;; 0) return 0 ;; esac
  case "${CLAUDE_CODE_DISABLE_AUTO_MEMORY:-}" in 1|true|TRUE|True) return 1 ;; esac
  settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  [ -f "$settings" ] || return 0
  v="$(hook_field autoMemoryEnabled < "$settings" 2>/dev/null)" || return 1
  case "$v" in false|False) return 1 ;; esac
  return 0
}

native_memory_on && exit 0

TO="$(hook_timeout)" || TO=""
PAYLOAD=""
if [[ ! -t 0 ]]; then
  if [ -n "$TO" ]; then PAYLOAD="$("$TO" 2 cat 2>/dev/null)" || PAYLOAD="${PAYLOAD:-}"
  else PAYLOAD="$(cat 2>/dev/null)" || PAYLOAD=""; fi
fi

CWD="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$CWD" ] && [ -n "$PAYLOAD" ]; then
  CWD="$(printf '%s' "$PAYLOAD" | hook_field cwd 2>/dev/null)" || CWD=""
fi
[ -n "$CWD" ] || CWD="$PWD"

[ -r "$INDEXER" ] || notice "indexer missing at $INDEXER"
PY="$(hook_python)" || notice "no Python 3 interpreter"

if [ -n "$TO" ]; then
  out="$("$TO" -k 1 5 "$PY" "$INDEXER" --digest --cwd "$CWD" --ops "$OPS_H" </dev/null 2>/dev/null)"
else
  out="$("$PY" "$INDEXER" --digest --cwd "$CWD" --ops "$OPS_H" </dev/null 2>/dev/null)"
fi
rc=$?
case "$rc" in
  0) ;;
  124|137) notice "the indexer timed out after 5s" ;;
  *) notice "the indexer exited $rc" ;;
esac
[ -n "$out" ] || notice "the indexer printed nothing"
printf '%s\n' "$out"
exit 0
