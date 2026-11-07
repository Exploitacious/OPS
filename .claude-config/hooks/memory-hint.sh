#!/usr/bin/env bash
# memory-hint.sh: UserPromptSubmit hook. When the prompt is strongly about
# something a memory entry already says, puts up to three lines in the model's
# context at the moment it is about to act:
#   Relevant memory: <name>: <description>
#
# Why it exists. A memory pool outgrows what a session reads at its start: a
# ruling that is only a name in an index reaches the model as a name or not at
# all, and the same correction recurs days later. This hook covers that by what
# the prompt is about, on every prompt.
#
# How: bin/memory-index --hint reads the payload on stdin and scores the prompt
# against the names and descriptions of this directory's pool and the root pool.
# A local keyword scorer: no model call, no network, a few tens of milliseconds
# (a paid call per prompt is the wrong tool for text this short and local). The
# rules live in memory-index (HINT_*):
#   - at least two distinct words match, the score reaches a bar calibrated on
#     real prompts, and only entries near the best score print; otherwise nothing;
#   - nothing for a message the harness sent (slash commands, compaction
#     summaries, batons, scheduled wakes, task notifications, notes from other
#     agents), for a prompt too short or too long to be a request, or from a lane
#     (agent_id in the payload, or bin/lane-class saying t3-lane or agent-lane:
#     a lane carries its brief, and a hint there is noise);
#   - the lane check runs only when there is something to print, so the common
#     no-match prompt pays for one interpreter start and nothing else.
#
# Quiet and fail-open, as every non-guard hook: exit 0 always, nothing printed
# when there is nothing to say, a 3 s cap on the scorer and a 2 s cap on
# lane-class. A failure is one line in
# ${OPS_STATE_DIR:-~/.local/state/ops}/memory-hint.log, not a stderr line the
# model never sees. MEMORY_HINT=0 turns the hook off.
#
# A box whose bin/lane-class is absent (it ships separately) counts as a foreman
# and gets the hint, the contract every consumer of lane-class shares. A box whose
# bin/memory-index has no --hint yet gets nothing and no log line: an older indexer
# would otherwise fail, and log, on every prompt.
set -uo pipefail
exec 2>/dev/null

[ "${MEMORY_HINT:-1}" = "0" ] && exit 0

# Python can log a caught exception, but cannot log its own startup failure or
# timeout. Keep those failures visible too without interrupting the prompt.
export MEMORY_HINT_LOG="${OPS_STATE_DIR:-$HOME/.local/state/ops}/memory-hint.log"
hint_failure() {
  mkdir -p "${MEMORY_HINT_LOG%/*}" &&
    printf '%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$1" >> "$MEMORY_HINT_LOG"
  return 0
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/hooklib.sh" || { hint_failure "cannot load hooklib.sh"; exit 0; }
INDEXER="$HOOK_DIR/../bin/memory-index"
[ -r "$INDEXER" ] || { hint_failure "indexer missing or unreadable: $INDEXER"; exit 0; }
grep -q -e '--hint' "$INDEXER" || exit 0

# The checkout whose .claude-memory/ is the store: OPS_DIR (tests, a checkout
# outside ~/OPS), else the checkout this hook lives in.
OPS_H="${OPS_DIR:-$(cd "$HOOK_DIR/../.." && pwd)}"

PAYLOAD=""
if [ ! -t 0 ]; then
  PAYLOAD="$(cat)" || { hint_failure "hook input could not be read"; exit 0; }
fi
[ -n "$PAYLOAD" ] || exit 0

PY="$(hook_python)" || { hint_failure "no usable Python interpreter"; exit 0; }
TO="$(hook_timeout)" || TO=""

if [ -n "$TO" ]; then
  OUT="$(printf '%s' "$PAYLOAD" | "$TO" -k 1 3 "$PY" "$INDEXER" --hint --ops "$OPS_H")"
else
  OUT="$(printf '%s' "$PAYLOAD" | "$PY" "$INDEXER" --hint --ops "$OPS_H")"
fi
rc=$?
[ "$rc" -eq 0 ] || { hint_failure "scorer or input pipe failed (status $rc)"; exit 0; }
[ -n "$OUT" ] || exit 0

# Lanes get no hint. Resolved last, and only on a match (bin/lane-class, one of
# foreman, t3-lane, agent-lane; unresolvable or missing means foreman, the
# contract every consumer shares).
if [ -n "$TO" ]; then LANE="$("$TO" -k 1 2 "$HOOK_DIR/../bin/lane-class" <<<"$PAYLOAD")" || LANE=foreman
else LANE="$("$HOOK_DIR/../bin/lane-class" <<<"$PAYLOAD")" || LANE=foreman; fi
case "$LANE" in t3-lane|agent-lane) exit 0 ;; esac

printf '%s\n' "$OUT"
exit 0
