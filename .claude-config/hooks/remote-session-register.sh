#!/usr/bin/env bash
# remote-session-register.sh — SessionStart hook that self-registers any Claude
# Code session running INSIDE tmux into the remote-sessions registry, so
# reboot-resume (start-remote-claude.sh) covers hand-launched sessions, not only
# skill-created ones.
#
# Why a hook and not just the skill: the skill registers sessions IT creates. A
# session the operator started by hand (`tmux new -s Foo; claude`) is invisible
# to boot-resume until it registers itself — this closes that gap. The upsert is
# idempotent: the same tmux session re-registers with its NEWEST session id on
# every restart/clear/compact, which is exactly the id boot-resume must resume
# from.
#
# Contract: a SessionStart hook must NEVER block session start. Every failure
# mode (opted out, not in tmux, no tmux binary, missing lib, unparseable stdin)
# exits 0 silently. It emits a status line only when it actually registers a
# session or deliberately skips an archived name.
#
# Opt out with RC_AUTOREGISTER=0.
set -uo pipefail

# --- fast, silent guards (cheapest first) ---
[ "${RC_AUTOREGISTER:-1}" = "0" ] && exit 0        # explicit opt-out
[ -n "${TMUX:-}" ] || exit 0                        # only tmux sessions are resumable on boot
command -v tmux >/dev/null 2>&1 || exit 0

# --- locate + source the shared library (self-locate from this hook's own dir) ---
# Registry naming/IO/schema lives in exactly one place; the hook must not fork it.
HOOK_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LIB="$HOOK_DIR/../remote-sessions/lib-remote-claude.sh"
[ -r "$LIB" ] || exit 0
# shellcheck source=/dev/null
source "$LIB"

# --- read the SessionStart JSON payload from stdin (non-blocking) ---
PAYLOAD=""
[ -t 0 ] || PAYLOAD="$(cat 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

# --- parse session_id, transcript_path, cwd (jq is NOT a hard dependency) ---
# Prefer python3 (robust JSON); fall back to a crude sed extractor for hosts
# without it. Any parse failure leaves the fields empty and we exit below —
# a hook must not block session start on malformed input.
sid=""; tpath=""; jcwd=""
if command -v python3 >/dev/null 2>&1; then
  parsed="$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def g(k):
    return (d.get(k) or "").replace("\t", " ").replace("\n", " ")
print("%s\t%s\t%s" % (g("session_id"), g("transcript_path"), g("cwd")))
' 2>/dev/null || true)"
  IFS=$'\t' read -r sid tpath jcwd <<<"$parsed"
else
  # Pure-shell fallback: extract the first "key":"value" string per field. Good
  # enough for the flat SessionStart payload (paths carry no embedded quotes).
  jget() { printf '%s' "$PAYLOAD" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1; }
  sid="$(jget session_id)"; tpath="$(jget transcript_path)"; jcwd="$(jget cwd)"
fi
[ -n "$sid" ] || exit 0

# --- derive the registry row fields ---
# NAME = this tmux session's name (normalized the same way new-remote-claude.sh does).
sname="$(tmux display-message -p '#S' 2>/dev/null || true)"
name="$(rc_normalize_name "$sname")"
[ -n "$name" ] || exit 0

# WORKDIR = cwd reported by Claude (fall back to the hook's own cwd if absent).
workdir="${jcwd:-$(pwd)}"

# CONFIG_DIR = the transcript_path prefix before /projects/ — this is the profile's
# config dir. Empty (default) when it is the default $HOME/.claude, so the row stays
# 3-column for the common case.
cfg=""
case "$tpath" in
  */projects/*) cfg="${tpath%%/projects/*}" ;;
esac
[ "$cfg" = "$HOME/.claude" ] && cfg=""

# --- respect the park decision: never re-register an ARCHIVED name ---
# Auto-registering a parked session would drag it back onto the boot registry,
# undoing a deliberate archive. Skip (loudly) instead.
if [ -n "$(rc_resolve_name "$name" "$ARCHIVE")" ]; then
  echo "SKIP name=$name (archived — leaving parked; revive it explicitly to resume on boot)"
  exit 0
fi

# --- case/format collision guard ---
# tmux names are case-sensitive but rc_normalize_name folds case + separators, so two live tmux
# sessions ("dev" and "Dev") can map to ONE registry name. Protect an EXISTING canonical session
# from being clobbered by a stray: if THIS session's raw name is not already canonical (raw !=
# normalized) AND a live session spelled exactly canonical is present to hold the row, skip.
# Gate on the canonical rival being present — NOT merely on a collision count — so that when no
# canonical-named session exists, a non-canonical one (e.g. hand-typed "morning briefing") still
# registers. A messy-but-present row beats no boot-resumable row. (tmux presence guaranteed by
# the fast guards at the top.)
if [ "$sname" != "$name" ]; then
  canonical_present=0
  while read -r other; do
    [ "$other" = "$name" ] && canonical_present=1
  done <<EOF
$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
EOF
  if [ "$canonical_present" = "1" ]; then
    echo "SKIP name=$name (case/format collision: raw '$sname' is not canonical; the canonical session holds the registry row)"
    exit 0
  fi
fi

# --- upsert: same session re-registers with its newest id on every restart ---
rc_register "$name" "$workdir" "$sid" "$cfg"
echo "OK registered name=$name workdir=$workdir session_id=$sid profile=${cfg:-default}"
exit 0
