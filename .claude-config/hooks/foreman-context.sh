#!/usr/bin/env bash
# foreman-context.sh: SessionStart hook. Prints CONTEXT/foreman.md, the doctrine
# that binds the main thread only, into a foreman session's context.
#
# Why it exists. CONTEXT/core.md is the one file every session and every subagent
# loads, and a good part of it (intake, orchestration, review, merge, model choice,
# rhythm) bound only the foreman, so every lane paid for text it was told not to
# apply. That text lives in CONTEXT/foreman.md and this hook delivers it where it
# binds: a main session runs it on startup, resume, clear and compact (the matchers
# the Stage-1 settings register), so the text also comes back after a compaction.
# A subagent (agent-lane) starts under SubagentStart, and this hook is registered on
# SessionStart only, so it never sees the file at start. A T3-delegated lane (t3-lane)
# is different: it is a top-level session, it runs SessionStart like a foreman, and
# only the lane-class check below keeps the file out of it.
#
# Who gets it. bin/lane-class decides: only "foreman" prints. A lane (t3-lane,
# agent-lane) gets nothing. A missing, slow or confused lane-class degrades to
# "foreman" (the contract every lane-class consumer shares): a lane that wrongly
# receives foreman.md wastes tokens, a foreman that wrongly does not would lose its
# rules.
#
# Known gap. A lane's own auto-compaction also fires SessionStart (source compact)
# with the parent's session id, so lane-class calls it a foreman and it gets the
# file once per compaction. OPS's PreCompact hook writes no lane marker to tell the
# two apart, so there is nothing for this hook to read; the cost is one file of at
# most 8 KB in a lane's fresh context.
#
# Fails open and says nothing on any error: no file, unreadable file, empty file, no
# lane-class, exit 0 always. core.md tells a foreman with no "Foreman doctrine" block
# to read the file itself, so silence degrades to a manual read, never to a missing
# rule. An OPS copy that has no CONTEXT/foreman.md yet (an older template) prints
# nothing, and nothing is wrong.
#
# Size. Claude Code shows the model only a 2,000-character preview of hook output
# past 10,000 characters, and that preview would still open with the doctrine's
# heading, so the foreman would believe it holds a rule set it never saw. A file over
# MAX_BYTES therefore prints nothing at all and the core.md fallback fires instead.
# MAX_BYTES is 8192 on purpose: verify-ops check 19 (check_hook_byte_budget) fails any
# SessionStart hook whose printed CONTEXT file passes 8192 bytes, and this hook must
# not accept a file the gate rejects.
#
# The root is this script's own checkout, not $HOME/OPS, so the hook run from a
# worktree reads that worktree's file.
# Run by hand: foreman-context.sh </dev/null  (stdin closed, or a payload on it).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
ROOT="$(cd "$HOOK_DIR/../.." && pwd)" || exit 0
DOC="$ROOT/CONTEXT/foreman.md"
LANE_CLASS="$ROOT/.claude-config/bin/lane-class"
MAX_BYTES=8192

# shellcheck source=hooklib.sh
. "$HOOK_DIR/hooklib.sh" 2>/dev/null || exit 0

[ -f "$DOC" ] && [ -r "$DOC" ] || exit 0

TO="$(hook_timeout 2>/dev/null)" || TO=""

# The SessionStart payload, when there is one. A terminal stdin is skipped and a
# pipe that never closes is cut at 2 s, so a hand run never hangs.
PAYLOAD=""
if [[ ! -t 0 ]]; then
  if [ -n "$TO" ]; then PAYLOAD="$("$TO" 2 cat 2>/dev/null)" || PAYLOAD="${PAYLOAD:-}"
  else PAYLOAD="$(cat 2>/dev/null)" || PAYLOAD=""; fi
fi

# Who is this? Anything but a clean lane answer counts as the foreman.
cls=""
if [ -x "$LANE_CLASS" ]; then
  if [ -n "$TO" ]; then cls="$("$TO" -k 1 3 "$LANE_CLASS" <<<"$PAYLOAD" 2>/dev/null)" || cls=""
  else cls="$("$LANE_CLASS" <<<"$PAYLOAD" 2>/dev/null)" || cls=""; fi
fi
case "$cls" in
  t3-lane|agent-lane) exit 0 ;;
esac

size="$(wc -c < "$DOC" 2>/dev/null | tr -d ' ')" || exit 0
[[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && [ "$size" -le "$MAX_BYTES" ] || exit 0

out="$(cat -- "$DOC" 2>/dev/null)" || exit 0
[ -n "$out" ] || exit 0
printf '%s\n' "$out"
exit 0
