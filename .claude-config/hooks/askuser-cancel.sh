#!/usr/bin/env bash
# askuser-cancel.sh: tell an agent that a rejected AskUserQuestion is not an answer from the Operator.
#
# In T3 Code a message or notification that arrives while a question card is pending cancels the
# question. Claude Code gives the agent the stock rejection ("The user doesn't want to proceed
# with this tool use ... STOP what you are doing and wait for the user"), the agent reads it as
# the Operator declining, and records a decision nobody made (the cancel came from another
# thread's message, not from the Operator).
#
# This hook adds the missing fact: the question was cancelled, it is no answer, do not record
# it as declined, re-ask once or proceed on the stated default. The work is in
# askuser-cancel.py; its docstring has the probe that shaped the registration:
#
#   REGISTER ON  UserPromptSubmit  (the cancelling message is delivered right after the
#                                   rejection; this is the one event in time to matter)
#                Stop              (the backstop when nothing arrives behind the cancel)
#                PostToolUse, matcher AskUserQuestion  (harmless, and covers a Claude Code
#                                   that starts firing it; as of 2.1.319 a rejected tool
#                                   never runs, so no PostToolUse, PostToolUseFailure or
#                                   PermissionDenied event exists for it. It shares the
#                                   once-per-question record and the 30-minute freshness
#                                   check with the other two, so registering it never
#                                   doubles a report)
#              A new hook is registered in the Stage-1 settings.json, which Stage 2 never writes.
#
# Fail-open like every non-guard hook: exit 0 always, print nothing unless there is a
# cancelled question to report, finish inside 8 seconds. The common case (nothing was
# cancelled) costs a grep over the transcript tail and no Python.
# Knobs: ASKUSER_CANCEL=0 turns it off. Tests: askuser-cancel-selftest.sh.
set -uo pipefail
exec 2>/dev/null

[ "${ASKUSER_CANCEL:-1}" = "0" ] && exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD=""
[ -t 0 ] || PAYLOAD="$(cat 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

# shellcheck source=/dev/null
. "$HOOK_DIR/hooklib.sh" 2>/dev/null || exit 0

# Fast path for the two transcript events: no rejection text in the last 256 KB of the
# transcript means nothing to say, and the interpreter never starts. A tool event
# (PostToolUse and friends) carries the text itself and goes straight to the helper.
EVENT="$(printf '%s' "$PAYLOAD" | hook_field hook_event_name 2>/dev/null || true)"
case "$EVENT" in
  UserPromptSubmit|Stop)
    TP="$(printf '%s' "$PAYLOAD" | hook_field transcript_path 2>/dev/null || true)"
    TP="$(hook_pathnorm "$TP")"
    [ -n "$TP" ] && [ -f "$TP" ] || exit 0
    tail -c 262144 "$TP" 2>/dev/null | grep -qE "doesn't want to proceed with this tool use|Tool permission request aborted" || exit 0
    ;;
esac

PY="$(hook_python)" || exit 0
TO="$(hook_timeout)" || TO=""
if [ -n "$TO" ]; then
  out="$(printf '%s' "$PAYLOAD" | "$TO" -k 1 8 "$PY" -I "$HOOK_DIR/askuser-cancel.py" 2>/dev/null)" || exit 0
else
  out="$(printf '%s' "$PAYLOAD" | "$PY" -I "$HOOK_DIR/askuser-cancel.py" 2>/dev/null)" || exit 0
fi
# Only the helper's one JSON line leaves this script; anything else is dropped.
case "$out" in
  '{"hookSpecificOutput": {"hookEventName": "'*'"}}'|'{"decision": "block", "reason": "'*'"}') printf '%s\n' "$out" ;;
esac
exit 0
