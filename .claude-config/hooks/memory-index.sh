#!/usr/bin/env bash
# memory-index.sh — SessionStart hook for Claude Code.
#
# Regenerates the active memory directory's MEMORY.md from the per-file
# frontmatter, so the index is always a DERIVED artifact equal to the set
# of memory files present — never a hand-maintained list that cross-machine
# sync (additive cp + git) silently clobbers.
#
# Resolves the open MEMORY.md-format question in 2026-05-13__memory-sync-doctrine.md. Full rationale:
# WORKFORCE/protocol/lessons/2026-06-25__memory-index-generated.md and the
# [[feedback-no-rsync-delete-memory-mirror]] memory.
#
# Profile-agnostic. Claude Code stores per-cwd memory under
#   $CLAUDE_CONFIG_DIR/projects/<encoded-cwd>/memory/
# where CLAUDE_CONFIG_DIR defaults to ~/.claude (override it if you run a
# second profile), and <encoded-cwd> is the cwd with every "/" turned into
# "-" (e.g. -home-you-OPS). If you run more than one profile, each one wires
# its memory dir to the same OPS store, so regenerating in place is correct
# regardless of which profile fired the hook.
#
# This is best-effort + non-blocking: a regen failure must never abort the
# session start. Mirrors the exit semantics of pre-compact.sh / the other
# SessionStart hooks (test -x ... || true at the registration site).
#
# Diagnostic env vars:
#   MEMORY_INDEX_DEBUG=1   — verbose logging to stderr
#   MEMORY_INDEX_DIR=<dir> — override the target dir (testing)

set -uo pipefail
# No `set -e`: partial-success behavior. A failed subcommand logs + continues.

dbg() {
  [[ "${MEMORY_INDEX_DEBUG:-0}" == "1" ]] && printf 'memory-index: %s\n' "$*" >&2
  return 0
}

INDEXER="$HOME/OPS/WORKFORCE/bin/ac-memory-index"
if [[ ! -x "$INDEXER" ]]; then
  dbg "indexer not found/executable at $INDEXER — nothing to do"
  exit 0
fi

# Resolve the active memory dir.
#   1. explicit override wins (testing)
#   2. else $CLAUDE_CONFIG_DIR/projects/<encoded-cwd>/memory
CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
ENCODED_CWD="$(pwd | sed 's|/|-|g')"   # Claude encodes cwd this way
MEM_DIR="${MEMORY_INDEX_DIR:-$CLAUDE_CFG/projects/${ENCODED_CWD}/memory}"

dbg "claude_cfg=$CLAUDE_CFG encoded_cwd=$ENCODED_CWD mem_dir=$MEM_DIR"

# The memory dir may be a real dir OR a symlink into the OPS store; both
# resolve fine here. If it doesn't exist yet (no memory written for this cwd
# on this machine), there's nothing to index — exit quietly.
if [[ ! -d "$MEM_DIR" ]]; then
  dbg "memory dir absent ($MEM_DIR) — nothing to index"
  exit 0
fi

# Regenerate in place. The indexer is idempotent and only ever rewrites
# MEMORY.md (never touches the memory files). Exit code 2 means some file
# needed a kebab-fallback title (informational, not an error); we still
# succeed so the session start is never blocked.
if [[ "${MEMORY_INDEX_DEBUG:-0}" == "1" ]]; then
  "$INDEXER" "$MEM_DIR" || true
else
  "$INDEXER" "$MEM_DIR" >/dev/null 2>&1 || true
fi

dbg "regenerated $MEM_DIR/MEMORY.md"
exit 0
