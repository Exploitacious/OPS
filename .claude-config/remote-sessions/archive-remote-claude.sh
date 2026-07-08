#!/usr/bin/env bash
# Archive / revive remote-controlled Claude Code sessions.
# On-demand sibling of new-remote-claude.sh; shares lib-remote-claude.sh.
#
# Usage:
#   archive-remote-claude.sh archive <name>   Park a session: remove from the boot registry and kill its
#                                             tmux/remote-control (drops off your phone). History is kept;
#                                             the row + session-id move to the archive file.
#   archive-remote-claude.sh revive  <name>   Bring a parked session back: move it to the live registry and
#                                             launch it now, resuming its conversation. Returns on reboot again.
#   archive-remote-claude.sh list             List archived sessions (NAME  WORKDIR  SESSION_ID).
#
# <name> accepts any case/spacing; it is normalized to Title-Case-Hyphen the same way new-remote-claude.sh
# does, so "morning briefing" matches the stored "Morning-Briefing".
set -u
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$SCRIPT_DIR/lib-remote-claude.sh"

cmd="${1:-}"
case "$cmd" in
  archive|revive)
    raw="${2:-}"
    [ -n "$raw" ] || { echo "ERR_USAGE: archive-remote-claude.sh $cmd <name>" >&2; exit 2; }
    # Pass the raw name through — rc_archive/rc_revive resolve it case-insensitively against the
    # actual stored names, so any casing/spacing matches (e.g. "mcp dev lab" -> "MCP-Dev-Lab").
    if [ "$cmd" = "archive" ]; then rc_archive "$raw"; else rc_revive "$raw"; fi
    ;;
  list|ls)
    rc_archive_list
    ;;
  *)
    echo "ERR_USAGE: archive-remote-claude.sh <archive|revive|list> [name]" >&2
    exit 2
    ;;
esac
