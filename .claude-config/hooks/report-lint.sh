#!/usr/bin/env bash
# report-lint.sh: Stop hook. When a foreman's FINAL message to the Operator asks them to
# decide more than three things, carries a decision table, or names things only by ID in its
# asks, block the stop once with a short reason that tells the agent to post it again as a
# short ask card (at most three asks with a recommendation and a default, everything else
# as one-line "decided" or "I'm handling" items, names beside any ID). Earlier narration in
# the turn is never judged: only the message the Operator reads last counts.
#
# WHY: asks an Operator cannot act on (a long decision list, a decision table, a message
# that points at things only by number) recur although written reporting rules cover each
# case, because prose in a doctrine file does not fire at the moment the message is
# written. This checks the shape of the final message at the one point that does. It judges
# SHAPE only and never reads for deferral: an agent that says "I will do this later" is not
# policed here.
#
# The work is in report-lint.py (stdlib only); its docstring has the rules and the
# thresholds. This wrapper keeps the promises the helper cannot keep if it never starts:
# exit 0 always, print nothing unless the helper prints the one block line, finish inside
# 8 seconds (hook_timeout), and never let a stale interpreter or a crash put anything else
# into the session.
#
# Never blocks: a message under 400 characters, a stop that is already the rewrite
# (stop_hook_active), a lane (agent_id, or bin/lane-class saying t3-lane or agent-lane;
# a box without bin/lane-class counts as a foreman), the same message twice, or anything
# the helper cannot read.
#
# Knobs: REPORT_LINT=0 turns it off; REPORT_LINT_MAX_ASKS (default 3) moves the ask
# threshold; REPORT_LINT_TICKET_RE replaces the ticket-ID pattern (see report-lint.py).
# Every Stop that had a final message long enough to judge leaves one line in
# ${OPS_STATE_DIR:-~/.local/state/ops}/report-lint.jsonl (counts and a hash, never text).
# Register it on Stop in the Stage-1 settings.json. Tests: report-lint-selftest.sh.
set -uo pipefail
exec 2>/dev/null

[ "${REPORT_LINT:-1}" = "0" ] && exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HOOK_DIR/hooklib.sh" 2>/dev/null || exit 0
PY="$(hook_python)" || exit 0
PAYLOAD=""
[ -t 0 ] || PAYLOAD="$(cat 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

TO="$(hook_timeout)" || TO=""
if [ -n "$TO" ]; then
  out="$(printf '%s' "$PAYLOAD" | "$TO" -k 1 8 "$PY" -I "$HOOK_DIR/report-lint.py" 2>/dev/null)" || exit 0
else
  out="$(printf '%s' "$PAYLOAD" | "$PY" -I "$HOOK_DIR/report-lint.py" 2>/dev/null)" || exit 0
fi
# Only the helper's one block line leaves this script; anything else is dropped.
case "$out" in
  '{"decision": "block", "reason": "'*'"}') printf '%s\n' "$out" ;;
esac
exit 0
