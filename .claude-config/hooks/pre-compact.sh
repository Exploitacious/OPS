#!/usr/bin/env bash
# pre-compact.sh — PreCompact hook for Claude Code.
#
# Fires before every auto- or manual-compaction. Reads the PreCompact
# JSON payload on stdin ({trigger, reason, estimated_tokens_removed}).
# Captures the MECHANICAL session state to a durable file under
# $CLAUDE_CONFIG_DIR/projects/<workspace>/pre-compact-<ts>.md (CLAUDE_CONFIG_DIR
# defaults to ~/.claude; a different dir if you run a second profile via that
# env var) so post-compact self-recovery has something to read.
#
# This is the SAFETY-NET layer — fires no matter what, even if the
# user never says "compact". The thoughtful AI synthesis lives in the
# `pre-compact-synthesis` skill (~/OPS/SKILLS/), which Claude
# invokes when the user signals wrap-up.
#
# Implements operating-doctrine Principle 2 ("Compaction is a pause,
# not death") as automation. Pairs with the existing SessionStart
# hook (ac-reorient) for post-compact re-anchoring.
#
# Fleet dispatch: if AC_ROOT + AC_NAME are set AND the fleet
# ac-pre-compact script exists, this hook delegates to it (the fleet
# version writes a richer journal anchor). Solo sessions fall through
# to the local snapshot path.
#
# Exit semantics (per Claude Code hook spec):
# - Stdout JSON `{"decision": "allow"}` allows the compaction to
#   proceed. We never block; the hook is for record-keeping, not
#   policy.
# - Stderr is shown to the operator if exit code 2; we exit 0 on
#   success and on any internal failure (best-effort — a hook crash
#   must not block the user's /compact).
#
# Diagnostic env vars:
#   PRE_COMPACT_DEBUG=1   — verbose logging to stderr
#   PRE_COMPACT_NO_FLEET=1 — skip fleet dispatch even if AC_ROOT set
#                           (useful for testing the solo path)

set -uo pipefail
# Note: NO `set -e` — we want partial-success behavior. A failed
# subcommand should log + continue, not abort the whole hook.

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_LOCAL="$(date -Iseconds)"
CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECTS_ROOT="$CLAUDE_CFG/projects"
WORKSPACE_KEY="$(pwd | sed 's|/|-|g')"  # claude encodes cwd this way
SNAPSHOT_DIR="$PROJECTS_ROOT/$WORKSPACE_KEY"
SNAPSHOT_TS="$(date -u +%Y%m%d-%H%M%S)"
SNAPSHOT_FILE="$SNAPSHOT_DIR/pre-compact-${SNAPSHOT_TS}.md"

dbg() {
  [[ "${PRE_COMPACT_DEBUG:-0}" == "1" ]] && printf 'pre-compact: %s\n' "$*" >&2
  return 0
}

# Read the PreCompact JSON payload on stdin (non-blocking — if the
# payload is missing or malformed, treat the hook as a manual probe).
PAYLOAD=""
if [[ ! -t 0 ]]; then
  PAYLOAD="$(cat 2>/dev/null || true)"
fi

# Best-effort payload parse. python3 is universal on Linux + macOS;
# fall back to a string scan if it isn't.
TRIGGER="unknown"
REASON=""
EST_TOKENS=""
if [[ -n "$PAYLOAD" ]] && command -v python3 >/dev/null 2>&1; then
  read -r TRIGGER REASON EST_TOKENS < <(
    printf '%s' "$PAYLOAD" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('trigger', 'unknown'),
          d.get('reason', '').replace('\\n', ' ')[:200] or '-',
          d.get('estimated_tokens_removed', '-'))
except Exception:
    print('unknown - -')
"
  )
fi

dbg "trigger=$TRIGGER reason=$REASON est_tokens=$EST_TOKENS"

# ── Fleet dispatch ──────────────────────────────────────────────────────
# If we're in a fleet session (AC_ROOT + AC_NAME set + fleet
# ac-pre-compact installed), the fleet script does the richer
# journal-anchor rewrite. We still record a local snapshot below as
# a belt-and-suspenders trail.
if [[ "${PRE_COMPACT_NO_FLEET:-0}" != "1" ]] \
   && [[ -n "${AC_ROOT:-}" ]] \
   && [[ -n "${AC_NAME:-}" ]] \
   && [[ -x "$HOME/OPS/WORKFORCE/bin/ac-pre-compact" ]]; then
  dbg "dispatching to fleet ac-pre-compact"
  "$HOME/OPS/WORKFORCE/bin/ac-pre-compact" --silent 2>/dev/null || true
fi

# ── Local snapshot (always) ─────────────────────────────────────────────
mkdir -p "$SNAPSHOT_DIR" 2>/dev/null || true

# Detect git state. Defensive on the "not in a repo" case.
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
GIT_BRANCH="-"
GIT_AHEAD_BEHIND="-"
GIT_STATUS="(not a git repo)"
GIT_LAST_COMMITS="(not a git repo)"
GIT_DIFFSTAT="(not a git repo)"

if [[ -n "$GIT_ROOT" ]]; then
  GIT_BRANCH="$(git -C "$GIT_ROOT" branch --show-current 2>/dev/null || echo '(detached)')"
  # ahead/behind vs upstream — quietly degrade if no upstream tracked
  GIT_AHEAD_BEHIND="$(git -C "$GIT_ROOT" rev-list --left-right --count '@{upstream}'...HEAD 2>/dev/null | awk '{print "behind="$1" ahead="$2}' || echo '(no upstream)')"
  GIT_STATUS="$(git -C "$GIT_ROOT" status --short 2>/dev/null | head -40 || echo '(unavailable)')"
  [[ -z "$GIT_STATUS" ]] && GIT_STATUS="(clean)"
  GIT_LAST_COMMITS="$(git -C "$GIT_ROOT" log --oneline -10 2>/dev/null || echo '(unavailable)')"
  GIT_DIFFSTAT="$(git -C "$GIT_ROOT" diff --stat HEAD 2>/dev/null | tail -15 || echo '(unavailable)')"
  [[ -z "$GIT_DIFFSTAT" ]] && GIT_DIFFSTAT="(no working-tree changes)"
fi

# Write the snapshot.
{
  echo "# Pre-compact snapshot — $NOW"
  echo ""
  echo "Captured by \`~/OPS/.claude-config/hooks/pre-compact.sh\` (PreCompact hook)."
  echo "Local time: $NOW_LOCAL"
  echo ""
  echo "## Compaction context"
  echo ""
  echo "- trigger: \`$TRIGGER\`"
  echo "- reason: $REASON"
  echo "- estimated_tokens_removed: $EST_TOKENS"
  echo "- cwd: \`$(pwd)\`"
  echo "- AC_ROOT: \`${AC_ROOT:-(unset — solo session)}\`"
  echo "- AC_NAME: \`${AC_NAME:-(unset)}\`"
  echo ""
  echo "## Git state"
  echo ""
  echo "- root: \`${GIT_ROOT:-(no repo)}\`"
  echo "- branch: \`$GIT_BRANCH\`"
  echo "- vs upstream: \`$GIT_AHEAD_BEHIND\`"
  echo ""
  echo "### Working tree (\`git status --short\`)"
  echo ""
  echo '```'
  printf '%s\n' "$GIT_STATUS"
  echo '```'
  echo ""
  echo "### Recent commits (\`git log --oneline -10\`)"
  echo ""
  echo '```'
  printf '%s\n' "$GIT_LAST_COMMITS"
  echo '```'
  echo ""
  echo "### Working-tree diffstat (\`git diff --stat HEAD\`)"
  echo ""
  echo '```'
  printf '%s\n' "$GIT_DIFFSTAT"
  echo '```'
  echo ""
  echo "## Post-compact reading order"
  echo ""
  echo "1. This snapshot (you are here)."
  echo "2. \`SESSION_HANDOFF.md\` at the project root if present — the durable narrative anchor."
  echo "3. \`MEMORY.md\` under \`$CLAUDE_CFG/projects/<workspace>/memory/\` — saved lessons."
  echo "4. \`git log --oneline -20\` if more context is needed."
  echo ""
  echo "Per operating-doctrine Principle 2 (Compaction is a pause, not death):"
  echo "continuity is not a handoff to a new entity — it is self-recovery via durable storage."
} > "$SNAPSHOT_FILE" 2>/dev/null

dbg "snapshot written: $SNAPSHOT_FILE"

# ── Session work-log (feeds the session-close reconciliation gate) ──────────
# Append a compact-time segment so a multi-compact session's full activity is
# reconstructable at CLOSE for time entry. This is the MECHANICAL spine (git
# delta + elapsed since session start); the pre-compact-synthesis skill adds a
# narrative line separately. Best-effort — a failure here never blocks the
# compact. NOTE: this only records; it never reconciles. WIP/work-tracking
# reconciliation is a session-CLOSE act (session-close skill), never a compact.
command -v work_session_key >/dev/null 2>&1 \
  || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hooklib.sh" 2>/dev/null || true
WORK_KEY="$(work_session_key 2>/dev/null || true)"
if [[ -n "$WORK_KEY" ]]; then
  RUNDIR="$HOME/.claude-compact-cycle"
  mkdir -p "$RUNDIR" 2>/dev/null || true
  WORKLOG="$RUNDIR/work-log-$WORK_KEY"
  START_STAMP="$RUNDIR/session-start-$WORK_KEY"
  STARTED="-"; ELAPSED="-"
  if [[ -f "$START_STAMP" ]]; then
    STARTED="$(grep -m1 '^started_at=' "$START_STAMP" 2>/dev/null | cut -d= -f2-)"
    if [[ -n "$STARTED" ]]; then
      _s0="$(date -d "$STARTED" +%s 2>/dev/null || echo 0)"
      if [[ "$_s0" -gt 0 ]]; then
        _d=$(( $(date +%s) - _s0 )); (( _d < 0 )) && _d=0
        ELAPSED="$(printf '%dh%02dm' $(( _d/3600 )) $(( (_d%3600)/60 )))"
      fi
    fi
  fi
  {
    echo "## segment $NOW_LOCAL — trigger=$TRIGGER elapsed=$ELAPSED"
    echo "repo=${GIT_ROOT:--} branch=$GIT_BRANCH cwd=$(pwd)"
    echo "recent_commits:"
    printf '%s\n' "$GIT_LAST_COMMITS" | sed 's/^/  /'
    echo "diffstat:"
    printf '%s\n' "$GIT_DIFFSTAT" | sed 's/^/  /'
    echo ""
  } >> "$WORKLOG" 2>/dev/null || true
  # Cap the log so a pause-forever session can't grow it unbounded (mirrors the
  # snapshot retention below). Newest ~500 lines is many segments' worth.
  wl_lines="$(wc -l < "$WORKLOG" 2>/dev/null || echo 0)"
  if [[ "${wl_lines:-0}" -gt 500 ]]; then
    tail -n 500 "$WORKLOG" > "$WORKLOG.tmp" 2>/dev/null && mv "$WORKLOG.tmp" "$WORKLOG" 2>/dev/null || rm -f "$WORKLOG.tmp" 2>/dev/null
  fi
  dbg "work-log segment appended: $WORKLOG"
fi

# ── Retention ───────────────────────────────────────────────────────────
# Long-running workspaces accumulate one snapshot per compaction
# forever. Cap at the newest N so the projects dir doesn't grow
# unbounded across weeks of use. Newest 10 is plenty for any sane
# recovery scenario — the resume hook only reads the latest.
RETENTION_KEEP="${PRE_COMPACT_RETENTION:-10}"
if [[ "$RETENTION_KEEP" =~ ^[0-9]+$ ]] && (( RETENTION_KEEP > 0 )); then
  # Sort by mtime, skip the newest N, delete the rest. Defensive on
  # the no-match case (ls returns nothing → tail returns nothing →
  # xargs is a no-op).
  ls -1t "$SNAPSHOT_DIR"/pre-compact-*.md 2>/dev/null \
    | tail -n +$((RETENTION_KEEP + 1)) \
    | xargs -r rm -f 2>/dev/null || true
  dbg "retention applied (keep=$RETENTION_KEEP)"
fi

# Always allow the compaction. The hook is record-keeping, never policy.
# Per the Claude Code hook schema, PreCompact has no documented
# "allow" channel — `decision` only accepts "approve"|"block", and
# the canonical pass-through is to exit 0 with no JSON. Empty exit
# lets Claude Code proceed with the compaction.
exit 0
