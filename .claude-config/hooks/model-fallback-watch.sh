#!/usr/bin/env bash
# model-fallback-watch.sh - Stop hook: flag a session or lane that a refusal moved to another
# model, so the Operator can scrutinize why and follow up. The work is in
# model-fallback-watch.py (stdlib only); its docstring has what it reads, the ledger, and why
# it blocks once.
#
# This wrapper keeps the promises the helper cannot keep if it never starts: exit 0 always,
# print nothing unless the helper prints its one block line, finish inside 8 seconds
# (hook_timeout), and never let a stale interpreter or a crash put anything else into the
# session. Platform behavior: with no Python 3 the hook is silent (nothing can read the
# transcripts); with neither gnutimeout nor timeout the helper runs without the 8 s bound
# (its own ledger lock wait is bounded at 5 s). Registered on Stop in the Stage-1 settings,
# behind `test -x`, so this file must stay executable.
# Off switch: MODEL_FALLBACK_WATCH=0. Tests: model-fallback-watch-selftest.sh.
set -uo pipefail
exec 2>/dev/null

[ "${MODEL_FALLBACK_WATCH:-1}" = "0" ] && exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HOOK_DIR/hooklib.sh" 2>/dev/null || exit 0
PY="$(hook_python)" || exit 0
PAYLOAD=""
[ -t 0 ] || PAYLOAD="$(cat 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

TO="$(hook_timeout)" || TO=""
if [ -n "$TO" ]; then
  out="$(printf '%s' "$PAYLOAD" | "$TO" -k 1 8 "$PY" -I "$HOOK_DIR/model-fallback-watch.py" 2>/dev/null)" || exit 0
else
  out="$(printf '%s' "$PAYLOAD" | "$PY" -I "$HOOK_DIR/model-fallback-watch.py" 2>/dev/null)" || exit 0
fi
# Only the helper's one block line leaves this script; anything else is dropped.
case "$out" in
  '{"decision": "block", "reason": "'*) printf '%s\n' "$out" ;;
esac
exit 0
