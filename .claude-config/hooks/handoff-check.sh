#!/usr/bin/env bash
# handoff-check.sh — SessionStart notifier for PROJECT-KEYED handoff batons.
#
# Surfaces a PENDING baton for THE CURRENT PROJECT ONLY. Batons live at
# ~/OPS/.claude-handoffs/pending/<project-key>.md (key = git repo root or
# cwd; see key.sh). Because the banner is keyed to the session's own project,
# parallel sessions on different projects NEVER see each other's batons —
# this is the fix for "handoffs picking up another agent's work".
#
# Notify ONLY. Never auto-loads context (that would re-inject stale state
# every session). The session-handoff skill does the actual pickup and
# archives the baton so this stops firing. Exit 0 always — a surface, not a
# gate. If you run more than one profile via CLAUDE_CONFIG_DIR, this fires in
# each of them (settings.json is symlinked into every config dir).
#
# MUST NOT regress to surfacing batons globally: the bug this replaces was a
# single ACTIVE_HANDOFF.md + a hook with no project filter, which blasted one
# project's baton into every unrelated session on every profile.

set -uo pipefail

HANDOFF_DIR="${OPS_DIR:-$HOME/OPS}/.claude-handoffs"
KEY_SH="$HANDOFF_DIR/key.sh"

# Current project key — shared logic via key.sh, with an inline fallback so a
# missing/non-exec helper degrades gracefully instead of crashing the hook.
if [ -x "$KEY_SH" ]; then
  KEY="$(bash "$KEY_SH" 2>/dev/null)"
else
  _root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  KEY="$(printf '%s' "$_root" | sed 's|/|-|g; s|^-*||')"
fi
[ -n "$KEY" ] || exit 0

BATON="$HANDOFF_DIR/pending/$KEY.md"

# Legacy single-baton fallback (pre project-keying): surface ONLY if its
# recorded cwd matches this session — never blast an old global baton.
if [ ! -f "$BATON" ] && [ -f "$HANDOFF_DIR/ACTIVE_HANDOFF.md" ]; then
  _legacy="$HANDOFF_DIR/ACTIVE_HANDOFF.md"
  _lcwd="$(grep -iE '^cwd:' "$_legacy" 2>/dev/null | head -1 | sed -E 's/^[^:]*:[[:space:]]*//')"
  [ "$_lcwd" = "$(pwd)" ] && BATON="$_legacy"
fi

[ -f "$BATON" ] || exit 0
grep -qiE '^status:[[:space:]]*pending' "$BATON" 2>/dev/null || exit 0

field() { grep -iE "^$1:" "$BATON" 2>/dev/null | head -1 | sed -E 's/^[^:]*:[[:space:]]*//'; }
writer="$(field written_by)"
when="$(field written_at)"
bcwd="$(field cwd)"
goal="$(grep -m1 -E '^# Handoff:' "$BATON" 2>/dev/null | sed -E 's/^# Handoff:[[:space:]]*//')"

# Single-profile default is ~/.claude. If you run a second profile via
# CLAUDE_CONFIG_DIR (e.g. a personal account alongside a work one), this
# shows that dir's basename instead of "default" so the banner still tells
# you which profile the baton is being read from.
_cfg_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
_cfg_dir="${_cfg_dir//\\//}"   # normalize backslashes so a Windows path compares sanely
cur="default"
[ "$_cfg_dir" = "$HOME/.claude" ] || cur="$(basename "$_cfg_dir")"

cat <<EOF
============================================================
 PENDING HANDOFF (this project)  —  you are on: ${cur}
============================================================
Project: ${KEY}
From:    ${writer:-unknown}   @   ${when:-unknown}
Cwd:     ${bcwd:-unknown}
Task:    ${goal:-<open the baton>}

Pick up:  say "resume handoff"  (or run /session-handoff)
Baton:    ${BATON}
============================================================
EOF
exit 0
