#!/usr/bin/env bash
# post-compact-resume.sh — SessionStart hook that surfaces the
# pre-compact snapshot when a session resumes from compaction.
#
# Reads the SessionStart JSON payload on stdin. The payload's
# `source` field tells us why the session started:
#
#   "startup" — fresh `claude` invocation
#   "resume"  — `claude --resume` on an existing session
#   "compact" — resumed after auto- or manual-compaction
#   "clear"   — after `/clear`
#
# We only act on source=compact. For every other source we exit 0
# silently so this hook stays out of the way.
#
# When we DO act: find the latest pre-compact-<ts>.md snapshot under
# $CLAUDE_CONFIG_DIR/projects/<workspace>/ (CLAUDE_CONFIG_DIR defaults to
# ~/.claude; a different dir if you run a second profile via that env var),
# print its contents to stdout. SessionStart hook stdout gets injected into
# the resume context, so post-compact-Claude reads the snapshot as part of
# its initial input — closing the four-artifact loop automatically.
#
# Pairs with the PreCompact hook (pre-compact.sh) which writes the
# snapshot. Together they implement operating-doctrine Principle 2.
#
# Exit semantics: always exit 0. SessionStart hooks failing should
# never block the session.

set -uo pipefail

CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Read SessionStart payload (non-blocking; payload may be absent in
# some test environments).
PAYLOAD=""
if [[ ! -t 0 ]]; then
  PAYLOAD="$(cat 2>/dev/null || true)"
fi

# Diagnostic log — every invocation appends payload + cwd so we can
# audit why the hook did or didn't surface a snapshot. Capped at
# 200KB via the simple-truncate guard below. Disable by unsetting
# POST_COMPACT_RESUME_DEBUG_LOG (default: $CLAUDE_CONFIG_DIR/post-compact-resume.log,
# i.e. ~/.claude/post-compact-resume.log by default).
DBG_LOG="${POST_COMPACT_RESUME_DEBUG_LOG:-$CLAUDE_CFG/post-compact-resume.log}"
if [[ -n "$DBG_LOG" ]]; then
  {
    printf '\n--- %s ---\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'cwd: %s\n' "$(pwd)"
    printf 'payload: %s\n' "${PAYLOAD:-<empty>}"
  } >> "$DBG_LOG" 2>/dev/null || true
  # Truncate if it gets large (>200KB) — keep newest tail.
  if [[ -f "$DBG_LOG" ]] && (( $(stat -c%s "$DBG_LOG" 2>/dev/null || echo 0) > 204800 )); then
    tail -c 102400 "$DBG_LOG" > "$DBG_LOG.tmp" 2>/dev/null && mv "$DBG_LOG.tmp" "$DBG_LOG" 2>/dev/null || true
  fi
fi

# Extract `source` field. Best-effort; if parsing fails, exit silently
# so we never gum up session start.
SOURCE="unknown"
if [[ -n "$PAYLOAD" ]] && command -v python3 >/dev/null 2>&1; then
  SOURCE="$(printf '%s' "$PAYLOAD" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('source', 'unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")"
fi

# Only handle the post-compact resume case.
if [[ "$SOURCE" != "compact" ]]; then
  exit 0
fi

# Locate the latest snapshot for this workspace.
WORKSPACE_KEY="$(pwd | sed 's|/|-|g')"
SNAPSHOT_DIR="$CLAUDE_CFG/projects/$WORKSPACE_KEY"

# Find the newest pre-compact-*.md snapshot (mtime-sorted).
LATEST="$(ls -1t "$SNAPSHOT_DIR"/pre-compact-*.md 2>/dev/null | head -1 || true)"

if [[ -z "$LATEST" ]] || [[ ! -r "$LATEST" ]]; then
  # No snapshot found. Print a one-line note so resumed-Claude
  # knows the system was supposed to fire but didn't find an
  # artifact (which itself is useful information — means the
  # PreCompact hook didn't run or wrote to a different workspace).
  cat <<EOF

============================================================
 POST-COMPACT RESUME — $(date -u +%Y-%m-%dT%H:%M:%SZ)
============================================================
Session resumed from compaction. No pre-compact snapshot found
under \`$SNAPSHOT_DIR/pre-compact-*.md\`.

The PreCompact hook either did not fire or wrote to a different
workspace path. Recovery fallback:

1. \`git status\` + \`git log --oneline -20\` in the project to
   see chronological action log.
2. Read \`SESSION_HANDOFF.md\` at the project root if present.
3. Read \`MEMORY.md\` under \`$CLAUDE_CFG/projects/<workspace>/memory/\`
   for saved lessons.

Per operating-doctrine Principle 2: continuity is self-recovery
via durable storage. Files survive; conversation context does not.
============================================================
EOF
  exit 0
fi

# Surface the snapshot. SessionStart hook stdout is injected into
# the resume context, so the snapshot contents land in Claude's
# initial input automatically.
cat <<EOF

============================================================
 POST-COMPACT RESUME — $(date -u +%Y-%m-%dT%H:%M:%SZ)
============================================================
Session resumed from compaction. Reading the pre-compact snapshot
the PreCompact hook left for you. This is your durable
continuity anchor — the conversation summary is fine-grained but
you may have lost specific files / branches / decisions.

Per operating-doctrine Principle 2 (Compaction is a pause, not
death): continuity is self-recovery via durable storage. The
snapshot below was written automatically before the compaction.
Cross-reference it with \`SESSION_HANDOFF.md\` at the project root
(if present) and the \`MEMORY.md\` index for the full picture.

ON RESUME — verify before you act. The summary is a hypothesis;
the code/files are truth. Re-confirm the current task, the target
files, and any "decided" detail against the repo BEFORE editing.
Honor a RESUME PROTOCOL block (NEXT ACTION / VERIFY FIRST / DO NOT
/ DEAD ENDS / ASK OPERATOR) if the anchor has one. On genuine
ambiguity, ask the operator — then save the answer to memory so
the next session doesn't re-ask.

Source: \`$LATEST\`
============================================================

EOF

cat "$LATEST"

exit 0
