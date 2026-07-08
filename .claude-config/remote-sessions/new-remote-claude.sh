#!/usr/bin/env bash
# Start ONE remote-controlled Claude Code session in tmux, on demand.
# On-demand sibling of start-remote-claude.sh; both share lib-remote-claude.sh.
# Usage: new-remote-claude.sh <name> [workdir]
#   <name>    session name (any case/spacing; normalized to Title-Case-Hyphen)
#   [workdir] directory to open Claude in (default: $HOME). Ignored if the name is already
#             registered — the session keeps its registered dir so its conversation resumes.
# The session is registered so it also returns (and resumes) after a VM reboot.
set -u
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib-remote-claude.sh"

RAW_NAME="${1:-}"
WORKDIR="${2:-$DEFAULT_WORKDIR}"

[ -n "$RAW_NAME" ] || { echo "ERR_USAGE: session name required — new-remote-claude.sh <name> [workdir]" >&2; exit 2; }
NAME="$(rc_normalize_name "$RAW_NAME")"
[ -n "$NAME" ] || { echo "ERR_NAME: name '$RAW_NAME' normalized to empty" >&2; exit 2; }

if tmux has-session -t "$NAME" 2>/dev/null; then
  echo "ERR_EXISTS: a tmux session named '$NAME' is already running (cwd: $(tmux display-message -p -t "$NAME" -F '#{pane_current_path}' 2>/dev/null))" >&2
  exit 3
fi

# If this name is already registered, reuse its dir + session-id so it resumes; else mint a new id.
existing="$(rc_lookup "$NAME")"
if [ -n "$existing" ]; then
  WORKDIR="$(printf '%s' "$existing" | cut -f1)"
  SID="$(printf '%s' "$existing" | cut -f2)"
else
  [ -d "$WORKDIR" ] || { echo "ERR_DIR: directory not found: $WORKDIR" >&2; exit 4; }
  SID="$(rc_new_uuid)"
fi

rc_register "$NAME" "$WORKDIR" "$SID"
rc_launch  "$NAME" "$WORKDIR" "$SID"
