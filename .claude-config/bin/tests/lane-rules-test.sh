#!/usr/bin/env bash
# lane-rules-test.sh: behavior tests for hooks/lane-rules.sh, the lane shell-rule
# block.
#
# Pinned: the block stays under about 1,200 characters and names each remedy
# (await, git -C, safe-pkill, capital-B Bash, ToolSearch select after a
# compaction, rm -rf of a variable); it names no private tool or system and no
# measured count; it has no em dash, en dash or non-ASCII character; any agent
# definition that carries the block's heading carries the whole block, exactly
# once (a stale partial copy is a defect); a SubagentStart payload gets it as
# hookSpecificOutput.additionalContext JSON; an agent whose definition already
# carries it is not told twice, and a stale definition without it still is; a
# SessionStart payload for a T3-delegated lane gets it as plain stdout (on
# startup, resume and compact) and a foreman session gets NOTHING; and every
# failure path (junk payload, no jq, no lane-class script) prints nothing and
# exits 0.
#
# Hermetic: HOME, CLAUDE_CONFIG_DIR and the lane signals are cleared per run, since
# lane-class reads T3CODE_THREAD_ID from the environment.
#
# Usage: lane-rules-test.sh    (exit 0 all pass, 1 otherwise)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CFG="$HERE/../.."
HOOK="${LANE_RULES_UNDER_TEST:-$CFG/hooks/lane-rules.sh}"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }
mkdir -p "$T/home" "$T/cfg/agents"

# run_hook <payload> [VAR=value ...]: stdout in $out, exit code in $rc.
run_hook() {
  local payload="$1"; shift
  out="$(printf '%s' "$payload" | env -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_LANE_CLASS \
      HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" LANE_CLASS_NO_DB=1 "$@" bash "$HOOK" 2>"$T/err")"
  rc=$?
}

echo "lane-rules-test:"
BLOCK="$(bash "$HOOK" --block)"

# --- 1. the text ---------------------------------------------------------------
n="${#BLOCK}"
[ "$n" -gt 500 ] && [ "$n" -le 1200 ] && ok "the block is $n characters (limit about 1,200)" || bad "block is $n characters"
for need in 'sleep N; check' 'bin/await' 'git -C' 'worktrees' 'pkill -f' 'safe-pkill' 'capital B' 'ToolSearch select:' 'compaction' 'rm -rf' 'VAR:?' 'Monitor' 'run_in_background'; do
  case "$BLOCK" in *"$need"*) ;; *) bad "block lacks '$need'" ;; esac
done
ok "the block names every remedy (await, git -C, safe-pkill, Bash, ToolSearch, rm -rf)"
python3 -I - "$BLOCK" <<'PY' && ok "no em dash, en dash or non-ASCII character in the block" || bad "the block holds a non-ASCII character"
import sys
assert all(ord(c) < 128 for c in sys.argv[1]), [c for c in sys.argv[1] if ord(c) >= 128]
PY
# Generic rules only: no measured counts from any one box (a count is two or more
# digits in a row), and no rule that depends on a particular connector: the block
# says nothing about writing through an external system.
if printf '%s' "$BLOCK" | grep -qE '[0-9]{2,}'; then
  bad "the block quotes a measured count"
else
  ok "the block quotes no measured count"
fi
if printf '%s' "$BLOCK" | grep -qiE 'before any write|domain skill'; then
  bad "the block carries a connector-specific rule"
else
  ok "the block carries no connector-specific rule"
fi
bash "$HOOK" --block >/dev/null 2>&1; [ $? -eq 0 ] && ok "--block exits 0" || bad "--block did not exit 0"

# --- 2. agent definitions that carry the block carry all of it -------------------
head_line="${BLOCK%%$'\n'*}"
carried=0
for f in "$CFG"/agents/*.md; do
  [ -f "$f" ] || continue
  grep -qF "$head_line" "$f" || continue
  carried=$((carried + 1))
  python3 -I - "$f" "$BLOCK" <<'PY' && ok "$(basename "$f") carries the identical block, once" || bad "$(basename "$f") carries a stale or doubled copy of the block"
import sys
text, block = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2]
assert text.count(block) == 1
PY
done
[ "$carried" -gt 0 ] || echo "NOTE: no agent definition carries the block yet (the hook supplies it at SubagentStart)"

# --- 3. SubagentStart ------------------------------------------------------------
run_hook '{"hook_event_name":"SubagentStart","agent_id":"agent-1","agent_type":"general-purpose","session_id":"s"}'
python3 -I - "$out" "$BLOCK" <<'PY' && ok "SubagentStart: the block is hookSpecificOutput.additionalContext JSON" || bad "SubagentStart envelope wrong: $out"
import json, sys
d = json.loads(sys.argv[1])
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "SubagentStart" and h["additionalContext"] == sys.argv[2]
PY
[ "$rc" -eq 0 ] || bad "SubagentStart exit $rc"

# an agent whose definition carries the block is not told twice; a stale one is
printf -- '---\nname: has-block\n---\n%s\n' "$BLOCK" > "$T/cfg/agents/has-block.md"
printf -- '---\nname: stale\n---\nOld body without the rules.\n' > "$T/cfg/agents/stale.md"
run_hook '{"hook_event_name":"SubagentStart","agent_id":"a2","agent_type":"has-block"}'
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "SubagentStart: an agent whose definition carries the block gets nothing extra" || bad "duplicate injection: '$out'"
run_hook '{"hook_event_name":"SubagentStart","agent_id":"a3","agent_type":"stale"}'
[[ "$out" == *additionalContext* ]] && ok "SubagentStart: a stale definition without the block still gets it from the hook" || bad "stale definition got nothing"
printf -- '---\nname: ops-worker\n---\n%s\nOld body.\n' "${BLOCK%%$'\n'*}" > "$T/cfg/agents/ops-worker.md"
run_hook '{"hook_event_name":"SubagentStart","agent_id":"a-stale","agent_type":"ops-worker"}'
[[ "$out" == *additionalContext* ]] && ok "a stale installed agent beats the newer source copy and still receives the full block" || bad "new source hid a stale installed definition"
run_hook '{"hook_event_name":"SubagentStart","agent_id":"a4","agent_type":"../../etc/passwd"}'
[[ "$out" == *additionalContext* ]] && [ "$rc" -eq 0 ] && ok "SubagentStart: a path-shaped agent_type is sanitized and treated as unknown" || bad "path-shaped agent_type: '$out' rc=$rc"
run_hook '{"hook_event_name":"SubagentStart","agent_id":"a5"}'
[[ "$out" == *additionalContext* ]] && ok "SubagentStart: no agent_type at all still gets the block" || bad "no agent_type got nothing"
run_hook '{"hook_event_name":"SubagentStart","agent_id":"a6","agent_type":"../has-block"}'
[[ "$out" == *additionalContext* ]] && ok "an invalid type is not transformed into another agent's name" || bad "sanitized type suppressed the block"

# --- 4. SessionStart: a lane gets it, a foreman gets nothing -------------------
for src in startup resume compact; do
  run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"$src\",\"session_id\":\"s\"}" T3CODE_THREAD_ID='thread:delegated-task:command%3Amcp%3Ax'
  [ "$out" = "$BLOCK" ] && [ "$rc" -eq 0 ] && ok "SessionStart ($src), T3-delegated lane: the block, as plain stdout" || bad "lane SessionStart ($src): '$out' rc=$rc"
done
run_hook '{"hook_event_name":"SessionStart","source":"startup","session_id":"s"}' T3CODE_THREAD_ID=11111111-1111-4111-8111-111111111111
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "SessionStart, foreman thread: nothing printed" || bad "foreman got output: '$out'"
run_hook '{"hook_event_name":"SessionStart","source":"startup","session_id":"s"}'
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "SessionStart, no thread id and no db: foreman, nothing printed" || bad "unresolvable session got output: '$out'"
run_hook '{"hook_event_name":"SessionStart","source":"startup"}' OPS_LANE_CLASS=foreman T3CODE_THREAD_ID='thread:delegated-task:x'
[ -z "$out" ] && ok "the foreman override beats a lane thread id" || bad "override ignored"
# a session whose first message is a lane brief (no thread id, no db, transcript on resume)
python3 -I - "$T/lane.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "Act as the implementation sub-agent for this task.\n\nDo it."}}) + "\n")
PY
run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"resume\",\"session_id\":\"s\",\"transcript_path\":\"$T/lane.jsonl\"}"
[ "$out" = "$BLOCK" ] && ok "SessionStart (resume): a transcript opening with the delegate_task wrapper is a lane" || bad "transcript-detected lane got '$out'"

# --- 5. every failure path prints nothing and exits 0 ---------------------------
run_hook 'not json {{{'
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "junk payload: nothing, exit 0" || bad "junk payload: '$out' rc=$rc"
run_hook ''
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "empty payload (a foreman, or a manual run): nothing, exit 0" || bad "empty payload: '$out' rc=$rc"
run_hook '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' T3CODE_THREAD_ID='thread:delegated-task:x'
[ -z "$out" ] && ok "an event it does not serve prints nothing" || bad "PreToolUse got output: '$out'"
# the hook copied alone, with no bin/lane-class beside it: a lane SessionStart degrades to foreman silence
mkdir -p "$T/alone/hooks"; cp "$HOOK" "$T/alone/hooks/lane-rules.sh"; cp "$CFG/hooks/hooklib.sh" "$T/alone/hooks/hooklib.sh"
out="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | env -u OPS_LANE_CLASS HOME="$T/home" T3CODE_THREAD_ID='thread:delegated-task:x' bash "$T/alone/hooks/lane-rules.sh" 2>/dev/null)"; rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "no bin/lane-class beside the hook: silent, exit 0 (degrades to foreman)" || bad "missing lane-class: '$out' rc=$rc"
# no jq on PATH: the python fallback still emits valid JSON
REAL_PY="$(python3 -I -c 'import sys; print(sys.executable)')"
mkdir -p "$T/nojq"; ln -s "$REAL_PY" "$T/nojq/python3"
for tool in cat head tr grep dirname; do ln -s "$(command -v $tool)" "$T/nojq/$tool"; done
out="$(printf '%s' '{"hook_event_name":"SubagentStart","agent_id":"a","agent_type":"x"}' | env -u T3CODE_THREAD_ID HOME="$T/home" CLAUDE_CONFIG_DIR="$T/cfg" PATH="$T/nojq" "$(command -v bash)" "$HOOK" 2>/dev/null)"; rc=$?
python3 -I - "$out" <<'PY' && [ "$rc" -eq 0 ] && ok "no jq: the python fallback still emits valid additionalContext JSON" || bad "no jq fallback: '$out' rc=$rc"
import json, sys
assert json.loads(sys.argv[1])["hookSpecificOutput"]["additionalContext"].startswith("Lane shell rules")
PY

echo "lane-rules-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
