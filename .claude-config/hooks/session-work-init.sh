#!/usr/bin/env bash
# session-work-init.sh — SessionStart hook: stamp the session's start for the
# session-close WIP/work-tracking reconciliation gate.
#
# Writes ~/.claude-compact-cycle/session-start-<KEY> ONCE per session so the
# session-close gate can bound "what did this session touch / how long did it
# run" for time entry — even for a session that NEVER compacts (the common
# case, and the one that gets forgotten). The compact-time work-log is only
# bonus context on top of this stamp.
#
# Write-if-absent + startup-only: SessionStart also fires on resume and after
# compact; those must NOT reset t0 for a session that is merely continuing.
# So we stamp only when (a) no stamp exists yet AND (b) the boot source is a
# genuine start. A stale stamp (>7d — a revived tmux name whose close-cleanup
# never ran) is refreshed.
#
# Registered LAST in the SessionStart chain (after remote-session-register.sh)
# so the tmux session name is already settled and KEY is stable across the
# session's whole life.
#
# Best-effort, never a gate: exit 0 always. A crash here must never block boot.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/hooklib.sh"

RUNDIR="$HOME/.claude-compact-cycle"
KEY="$(work_session_key 2>/dev/null || true)"
[ -n "$KEY" ] || exit 0
STAMP="$RUNDIR/session-start-$KEY"

# --- write-if-absent: the SOLE guard, and it is sufficient ---
# SessionStart also fires on resume + after compact; a merely-CONTINUING session
# must not be re-stamped. A continuing session always still has its original
# stamp, so it exits here. Reaching PAST this point means NO stamp exists — a
# genuinely new work session: either a fresh startup OR a revived archived
# session (session-close deletes the stamp on close, so a revive starts clean).
# Both MUST be stamped, so we do NOT gate on the SessionStart source. (Gating on
# source was a bug: a revived session fires source=resume for its whole life, so
# it would never stamp — silently disabling the gate for the Archive close path.
# write-if-absent alone cannot over-stamp a continuing session.) A stale stamp
# (>7d — a reused tmux name whose close-cleanup never ran) is refreshed.
if [ -f "$STAMP" ]; then
  started="$(grep -m1 '^started_at=' "$STAMP" 2>/dev/null | cut -d= -f2-)"
  if [ -n "$started" ]; then
    age=$(( ( $(date +%s) - $(date -d "$started" +%s 2>/dev/null || date +%s) ) / 86400 ))
    [ "${age:-0}" -lt 7 ] && exit 0   # live/continuing session already stamped — leave t0 alone
  fi
fi

# SOURCE is recorded for diagnostics only — NOT a gate. Default "unknown" (fails
# closed, matching post-compact-resume.sh) when the payload is absent/malformed.
SOURCE="unknown"
if [[ ! -t 0 ]]; then
  _p="$(cat 2>/dev/null || true)"
  if [ -n "$_p" ]; then
    _s="$(printf '%s' "$_p" | hook_field source 2>/dev/null)" && [ -n "$_s" ] && SOURCE="$_s"
  fi
fi

mkdir -p "$RUNDIR" 2>/dev/null || true

RAW_TMUX="-"
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  RAW_TMUX="$(tmux display-message -p '#S' 2>/dev/null || echo -)"
fi

GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
BOOT_HEAD="-"
[ -n "$GIT_ROOT" ] && BOOT_HEAD="$(git -C "$GIT_ROOT" rev-parse --short HEAD 2>/dev/null || echo -)"

{
  echo "started_at=$(date -Is)"
  echo "cwd=$(pwd)"
  echo "boot_repo=${GIT_ROOT:--}"
  echo "boot_head=$BOOT_HEAD"
  echo "tmux=$RAW_TMUX"
  echo "source=$SOURCE"
} > "$STAMP" 2>/dev/null || true

exit 0
