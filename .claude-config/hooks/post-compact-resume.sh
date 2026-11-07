#!/usr/bin/env bash
# post-compact-resume.sh: SessionStart hook that surfaces the
# pre-compact snapshot when a session resumes from compaction.
#
# Reads the SessionStart JSON payload on stdin. The payload's
# `source` field tells us why the session started:
#
#   "startup": fresh `claude` invocation
#   "resume" : `claude --resume` on an existing session
#   "compact": resumed after auto- or manual-compaction
#   "clear"  : after `/clear`
#
# We only act on source=compact. For every other source we exit 0
# silently so this hook stays out of the way.
#
# When we DO act: find the latest pre-compact-<ts>.md snapshot under
# $CLAUDE_CONFIG_DIR/projects/<workspace>/ (CLAUDE_CONFIG_DIR defaults to
# ~/.claude; a different dir if you run a second profile via that env var),
# print its contents to stdout. SessionStart hook stdout gets injected into
# the resume context, so post-compact-Claude reads the snapshot as part of
# its initial input: closing the four-artifact loop automatically.
#
# Pairs with the PreCompact hook (pre-compact.sh) which writes the
# snapshot. Together they implement how-i-work.md P2.
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

# Diagnostic log: every invocation appends payload + cwd so we can
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
  # Truncate if it gets large (>200KB): keep newest tail.
  if [[ -f "$DBG_LOG" ]] && (( $(stat -c%s "$DBG_LOG" 2>/dev/null || echo 0) > 204800 )); then
    tail -c 102400 "$DBG_LOG" > "$DBG_LOG.tmp" 2>/dev/null && mv "$DBG_LOG.tmp" "$DBG_LOG" 2>/dev/null || true
  fi
fi

# Extract `source` field. Best-effort; if parsing fails, exit silently
# so we never gum up session start.
SOURCE="unknown"
if [[ -n "$PAYLOAD" ]]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hooklib.sh"
  # Portable extractor (jq -> python). The old `python3 -c` never ran on
  # Windows Git Bash (no python3 shim), so SOURCE stayed 'unknown' and the
  # resume banner never fired.
  _s="$(printf '%s' "$PAYLOAD" | hook_field source)" && [[ -n "$_s" ]] && SOURCE="$_s"
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

# Deferred tool schemas do not survive a compaction: every mcp__ tool and a few
# built-ins (Monitor, WebFetch, WebSearch) must be selected again with ToolSearch,
# and a call made from memory is rejected by the server or by Claude Code ("This
# tool's schema was not sent to the API"). In one measured set of sessions 5.9% of
# such calls failed, against 0.05% once the tool was selected. This names the tools
# the session was using, most recently used first, and says to re-select LAZILY, one
# name just before its first call: selecting 17 to 54 tools at once reloads tens of
# KB of schemas on every compaction, which can cost more than the failures it
# prevents.
# mcp-reselect.py picks the list: Claude Code's own record of the discovered tools
# (compactMetadata.preCompactDiscoveredTools on the fresh compact_boundary record)
# when readable, else the snapshot's section from pre-compact.sh, else the tool
# calls in the transcript. It prints nothing when there is nothing to name, and a
# failure of any step prints nothing: this is a hint, never a gate. The block prints
# LAST, after the snapshot, closest to the model's next turn.
HOOK_DIR_RESUME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reselect_block() {
  local py tp to out src total shown=0 line
  py="$(hook_python 2>/dev/null)" || return 0
  [[ -r "$HOOK_DIR_RESUME/mcp-reselect.py" ]] || return 0
  tp="$(printf '%s' "$PAYLOAD" | hook_field transcript_path 2>/dev/null)" || tp=""
  local -a args=(resume "$tp")
  [[ -n "$LATEST" && -r "$LATEST" ]] && args+=(--snapshot "$LATEST")
  to="$(hook_timeout 2>/dev/null)" || to=""
  if [[ -n "$to" ]]; then out="$("$to" 5 "$py" "$HOOK_DIR_RESUME/mcp-reselect.py" "${args[@]}" 2>/dev/null)" || out=""
  else out="$("$py" "$HOOK_DIR_RESUME/mcp-reselect.py" "${args[@]}" 2>/dev/null)" || out=""; fi
  [[ -n "$out" ]] || return 0
  src="$(printf '%s\n' "$out" | sed -n 's/^# source: //p' | head -1)"
  total="$(printf '%s\n' "$out" | sed -n 's/^# total: //p' | head -1)"
  case "$src" in
    boundary) src="Claude Code's own record of the tools it had discovered" ;;
    snapshot) src="the pre-compact snapshot" ;;
    *) src="the tool calls since the previous compaction" ;;
  esac
  printf '\n============================================================\n'
  printf ' DEFERRED TOOL SCHEMAS DID NOT SURVIVE THIS COMPACTION\n'
  printf '============================================================\n'
  printf 'A compaction drops the schemas of deferred tools (every mcp__ tool, plus Monitor,\n'
  printf 'WebFetch and a few other built-ins). Calling one from memory fails ("This tool'"'"'s\n'
  printf 'schema was not sent to the API", or a rejected parameter) far more often than\n'
  printf 'calling it after it was selected.\n'
  printf 'Before the FIRST call to any tool below, run ToolSearch with query\n'
  printf '"select:<exact name>" for that one tool. Copy the name from this list or from\n'
  printf 'ToolSearch, never type it from memory. Select lazily, one tool just before its\n'
  printf 'first use: loading them all reloads tens of KB of schemas you may never call.\n'
  printf 'Tools you had loaded or used (%s, most recently used first; from %s):\n' "${total:-?}" "$src"
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != "#"* ]] || continue
    printf '  %s\n' "$line"; shown=$((shown + 1))
  done <<<"$out"
  if [[ "${total:-0}" =~ ^[0-9]+$ ]] && (( total > shown )); then
    printf '  (+%d more were loaded; ToolSearch finds a tool by name)\n' "$(( total - shown ))"
  fi
  printf '============================================================\n'
}
RESELECT_BLOCK="$(reselect_block)"

if [[ -z "$LATEST" ]] || [[ ! -r "$LATEST" ]]; then
  # No snapshot found. Print a one-line note so resumed-Claude
  # knows the system was supposed to fire but didn't find an
  # artifact (which itself is useful information: means the
  # PreCompact hook didn't run or wrote to a different workspace).
  cat <<EOF

============================================================
 POST-COMPACT RESUME: $(date -u +%Y-%m-%dT%H:%M:%SZ)
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

Per how-i-work.md P2: continuity is self-recovery
via durable storage. Files survive; conversation context does not.
============================================================
EOF
  [[ -z "$RESELECT_BLOCK" ]] || printf '%s\n' "$RESELECT_BLOCK"
  exit 0
fi

# Surface the snapshot. SessionStart hook stdout is injected into
# the resume context, so the snapshot contents land in Claude's
# initial input automatically.
cat <<EOF

============================================================
 POST-COMPACT RESUME: $(date -u +%Y-%m-%dT%H:%M:%SZ)
============================================================
Session resumed from compaction. Reading the pre-compact snapshot
the PreCompact hook left for you. This is your durable
continuity anchor: the conversation summary is fine-grained but
you may have lost specific files / branches / decisions.

Per how-i-work.md P2 (Compaction is a pause, not
death): continuity is self-recovery via durable storage. The
snapshot below was written automatically before the compaction.
Cross-reference it with \`SESSION_HANDOFF.md\` at the project root
(if present) and the \`MEMORY.md\` index for the full picture.

ON RESUME: verify before you act. The summary is a hypothesis;
the code/files are truth. Re-confirm the current task, the target
files, and any "decided" detail against the repo BEFORE editing.
Honor a RESUME PROTOCOL block (NEXT ACTION / VERIFY FIRST / DO NOT
/ DEAD ENDS / ASK OPERATOR) if the anchor has one. On genuine
ambiguity, ask the operator: then save the answer to memory so
the next session doesn't re-ask.

Source: \`$LATEST\`
============================================================

EOF

# The snapshot's own "Deferred tools" section is the fallback source of the block
# printed below it; printing both would list the names twice.
if [[ -n "$RESELECT_BLOCK" ]]; then
  awk '
  /^## Deferred tools used before this compaction[[:space:]]*$/ { skip = 1; next }
  skip && /^## / { skip = 0 }
  !skip { print }
' "$LATEST"
else
  # Preserve the persisted names and instruction if the replacement hint could
  # not be built (missing Python or helper, a timeout, an unreadable transcript).
  cat "$LATEST"
fi

[[ -z "$RESELECT_BLOCK" ]] || printf '%s\n' "$RESELECT_BLOCK"

exit 0
