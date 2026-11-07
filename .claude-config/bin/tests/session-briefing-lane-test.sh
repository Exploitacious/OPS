#!/usr/bin/env bash
# session-briefing-lane-test.sh: behavior tests for the lane gate in the SessionStart
# briefing (hooks/session-briefing.sh).
#
# Why: a T3-delegated lane is its own top-level session, so it booted through the
# briefing like the main thread and got every line a foreman acts on (memory flush
# queue, hygiene, backup and update lines), none of which a lane can use. The hook now
# asks bin/lane-class and prints one line to a lane.
#
# Pinned:
#   foreman (no lane signal, a uuid thread id, an unmapped session, no payload): the
#     whole briefing, every section the hook printed before the gate;
#   t3-lane (a delegated-task thread id for the session the payload names): the
#     briefing is ONE line naming the class and none of the foreman lines, and nothing
#     is started or written for it (no leftover-stamp scan, no state file);
#   agent-lane (agent_id in the payload): the same silence;
#   the verdict is only taken for the session the environment belongs to: an ambient
#     lane thread id with another session's payload, or no payload, is still a foreman
#     (this is what keeps every hook test hermetic when run from inside a delegated lane);
#   OPS_LANE_CLASS forces the answer;
#   a missing bin/lane-class degrades to foreman, the old behavior.
#
# Every path is under a temp dir. The suite refuses to run outside the sandbox because
# the briefing starts a scan that writes state files (the sandbox guard below).
#
# Usage: session-briefing-lane-test.sh    (exit 0 all pass, 1 otherwise)
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
BRIEF_HOOK="$HERE/../../hooks/session-briefing.sh"
[ -f "$BRIEF_HOOK" ] || { echo "FAIL: the hook is missing"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required (the hooks' own parser)"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }

echo "session-briefing-lane-test:"
mkdir -p "$T/home/.claude-compact-cycle" "$T/work" "$T/cfg/projects" "$T/ops/CONTEXT"
printf '# Core\n' > "$T/ops/CONTEXT/core.md"
# a leftover session stamp a foreman's briefing would start a scan for
printf 'started_at=%s\ncwd=%s\nboot_repo=-\nboot_head=-\ntmux=-\nsource=startup\n' "$(date -d '30 hours ago' -Is)" "$T/work" \
  > "$T/home/.claude-compact-cycle/session-start-leftover"
touch -d '30 hours ago' "$T/home/.claude-compact-cycle/session-start-leftover"
# a copy of the hooks and bin trees, so a case can remove bin/lane-class without touching the repo
mkdir -p "$T/tree"; cp -r "$HERE/../../hooks" "$T/tree/hooks"; mkdir -p "$T/tree/bin"
for f in "$HERE/.."/*; do [ -f "$f" ] && cp -P "$f" "$T/tree/bin/" 2>/dev/null; done

# run <hook> <payload> [VAR=value ...]: stdout in $out, exit code in $rc.
run() {
  local hook="$1" payload="$2"; shift 2
  out="$(cd "$T/work" && printf '%s' "$payload" | env -u TMUX -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_LANE_CLASS \
      -u OPS_STATE_DIR -u OPS_ORPHAN_SCAN -u T3CODE_HOME \
      HOME="$T/home" OPS_DIR="$T/ops" CLAUDE_CONFIG_DIR="$T/cfg" LANE_CLASS_NO_DB=1 "$@" bash "$hook" 2>"$T/err")"
  rc=$?
}
has() { case "$out" in *"$1"*) return 0 ;; esac; return 1; }
STATE="$T/home/.local/state/ops"

LANE_THREAD='thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Ax'
PAYLOAD='{"hook_event_name":"SessionStart","source":"startup","session_id":"sess-lane-test"}'
FOREMAN_LINES=('SESSION BRIEFING' ' Worker:' ' Config:' ' Boot:')

# --- the foreman keeps everything -------------------------------------------------
run "$BRIEF_HOOK" "$PAYLOAD" OPS_ORPHAN_SCAN=sync
all=1; for l in "${FOREMAN_LINES[@]}"; do has "$l" || { all=0; bad "foreman briefing lost the line '$l'" "$out"; }; done
[ "$all" -eq 1 ] && [ "$rc" -eq 0 ] && ok "foreman: the briefing keeps SESSION BRIEFING, Worker, Config and Boot" || true
run "$BRIEF_HOOK" "$PAYLOAD" T3CODE_THREAD_ID=11111111-1111-4111-8111-111111111111
has 'SESSION BRIEFING' && ok "foreman on a bare-uuid T3 thread: the full briefing" || bad "uuid thread lost the briefing" "$out"
run "$BRIEF_HOOK" ''
has 'SESSION BRIEFING' && ok "no payload at all (a manual or test run): the full briefing" || bad "empty payload lost the briefing" "$out"
rm -rf "$STATE"

# --- a T3-delegated lane gets one line --------------------------------------------
run "$BRIEF_HOOK" "$PAYLOAD" T3CODE_THREAD_ID="$LANE_THREAD"
lines="$(printf '%s\n' "$out" | grep -c .)"
{ [ "$rc" -eq 0 ] && [ "$lines" -eq 1 ] && has 't3-lane session' && has 'not printed for lanes'; } \
  && ok "t3-lane: the briefing is one line that names the class" || bad "t3-lane briefing: $lines lines, rc=$rc" "$out"
for l in ' Worker:' ' Config:' ' Boot:' ' Hygiene:' ' Memory:' ' Backup:' ' Reminders:' ' Snapshot:' ' Repo:'; do has "$l" && bad "t3-lane briefing printed '$l'"; done
ok "t3-lane: none of the foreman lines (Worker, Config, Boot, Hygiene, Memory, Backup, Reminders, Snapshot, Repo)"
sleep 1
[ ! -e "$STATE/orphan-scan.status" ] && ok "t3-lane: no leftover-stamp scan is started" || bad "t3-lane started a scan" "$(cat "$STATE/orphan-scan.status")"
run "$BRIEF_HOOK" "$PAYLOAD" OPS_ORPHAN_SCAN=sync
[ -e "$STATE/orphan-scan.status" ] && ok "foreman: the scan does start (positive control for the check above)" || bad "foreman started no scan"
rm -rf "$STATE"
run "$BRIEF_HOOK" '{"hook_event_name":"SessionStart","source":"resume","session_id":"sess-lane-test"}' T3CODE_THREAD_ID="$LANE_THREAD"
{ has 't3-lane session' && [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ]; } && ok "t3-lane on resume: still one line" || bad "t3-lane resume" "$out"

# --- an in-process lane (agent_id) -----------------------------------------------
run "$BRIEF_HOOK" '{"hook_event_name":"SessionStart","source":"startup","session_id":"s","agent_id":"agent-9"}'
{ has 'agent-lane session' && [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] && [ "$rc" -eq 0 ]; } \
  && ok "agent-lane (agent_id): one line naming the class" || bad "agent-lane briefing" "$out"

# --- the verdict belongs to the session the environment belongs to -------------------
run "$BRIEF_HOOK" "$PAYLOAD" T3CODE_THREAD_ID="$LANE_THREAD" CLAUDE_CODE_SESSION_ID=some-outer-lane-session
has 'SESSION BRIEFING' && ok "an ambient lane thread id with ANOTHER session's payload: foreman (a test inside a lane stays hermetic)" || bad "foreign ambient lane id leaked" "$out"
run "$BRIEF_HOOK" '' T3CODE_THREAD_ID="$LANE_THREAD"
has 'SESSION BRIEFING' && ok "an ambient lane thread id with no payload: foreman" || bad "payload-less ambient lane id leaked" "$out"
run "$BRIEF_HOOK" "$PAYLOAD" T3CODE_THREAD_ID="$LANE_THREAD" CLAUDE_CODE_SESSION_ID=sess-lane-test
has 't3-lane session' && ok "the same thread id with the matching session id: lane" || bad "matching ambient lane id not honored" "$out"
run "$BRIEF_HOOK" "$PAYLOAD" OPS_LANE_CLASS=t3-lane
has 't3-lane session' && ok "OPS_LANE_CLASS=t3-lane forces the lane answer" || bad "override ignored" "$out"
run "$BRIEF_HOOK" "$PAYLOAD" OPS_LANE_CLASS=foreman T3CODE_THREAD_ID="$LANE_THREAD"
has 'SESSION BRIEFING' && ok "OPS_LANE_CLASS=foreman forces the foreman answer over a lane thread id" || bad "foreman override ignored" "$out"

# --- a missing or broken lane-class is a foreman, the old behavior ----------------------
rm -f "$T/tree/bin/lane-class"
[ ! -e "$T/tree/bin/lane-class" ] || bad "could not remove the copied lane-class"
run "$T/tree/hooks/session-briefing.sh" "$PAYLOAD" T3CODE_THREAD_ID="$LANE_THREAD"
has 'SESSION BRIEFING' && ok "no bin/lane-class: the briefing falls back to the full foreman text" || bad "missing lane-class changed the briefing" "$out"
printf '#!/usr/bin/env bash\necho "not a class"; exit 7\n' > "$T/tree/bin/lane-class"; chmod +x "$T/tree/bin/lane-class"
run "$T/tree/hooks/session-briefing.sh" "$PAYLOAD" T3CODE_THREAD_ID="$LANE_THREAD"
has 'SESSION BRIEFING' && ok "a failing lane-class falls back to the full foreman text" || bad "failing lane-class changed the briefing" "$out"

echo "session-briefing-lane-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
