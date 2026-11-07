#!/usr/bin/env bash
# askuser-cancel-selftest.sh: prove askuser-cancel.sh tells an agent that a rejected
# AskUserQuestion is not an answer, exactly once, on the events that can carry it, and is
# silent everywhere else. Fixture hook JSON throughout; no network, and every path the hook
# reads (HOME, the state dir, the transcripts) is under a temp dir. The transcript fixtures
# have the shape of two real cancellations: an AskUserQuestion tool_use, a tool_result with
# is_error true and the stock rejection text, a user record "[Request interrupted by user for
# tool use]", a queue-operation, then the message that cancelled it. Exit 0 = every case
# passes; 1 = a case fails.
# shellcheck disable=SC2015
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/askuser-cancel.sh"
fails=0
pass(){ printf '  PASS  %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; fails=$((fails + 1)); }

echo "askuser-cancel-selftest:"
command -v python3 >/dev/null 2>&1 || { echo "askuser-cancel-selftest: SKIP (no python3; the hook is silent without it)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "askuser-cancel-selftest: FAIL (jq required for the assertions)"; exit 1; }

T="$(mktemp -d)"
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup(){ rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/state" "$T/home"
LOG="$T/state/askuser-cancel.jsonl"

STOCK="The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."
ago() { date -u -d "$1 seconds ago" +%Y-%m-%dT%H:%M:%S.000Z; }

run() { # <payload json> [NAME=VALUE ...]: stdout in $OUT, exit in $RC
  local json="$1"; shift
  OUT="$(printf '%s' "$json" | env HOME="$T/home" OPS_STATE_DIR="$T/state" "$@" bash "${HOOKSH:-$HOOK}" 2>"$T/err")"; RC=$?
}
silent() { if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -s "$T/err" ]; then pass "$1"; else fail "$1" "rc=$RC out='${OUT:0:140}' err='$(head -c 100 "$T/err")'"; fi; }
context() { # <label> <event>: one additionalContext line for that event, carrying the message
  if [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] \
     && [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$OUT" 2>/dev/null)" = "$2" ] \
     && jq -e '.hookSpecificOutput.additionalContext | test("not record a decision as declined") and test("Re-ask once") and test("stated default") and test("unless they say they declined")' <<<"$OUT" >/dev/null 2>&1; then pass "$1"
  else fail "$1" "rc=$RC out='${OUT:0:200}'"; fi
}
blocked() { # <label>
  if [ "$RC" -eq 0 ] && [ "$(jq -r .decision <<<"$OUT" 2>/dev/null)" = block ] \
     && jq -e '.reason | test("not record a decision as declined")' <<<"$OUT" >/dev/null 2>&1; then pass "$1"
  else fail "$1" "rc=$RC out='${OUT:0:200}'"; fi
}

# --- tool events: the text is in the result or the error ---------------------------------
tool_event() { # <event> <tool> <json fragment for the result field> [tool_use_id] [session] [transcript]
  jq -nc --arg e "$1" --arg t "$2" --argjson r "$3" --arg id "${4:-toolu_1}" --arg sid "${5:-s-tool}" --arg tp "${6:-/nonexistent}" \
    '{session_id:$sid,transcript_path:$tp,cwd:"/tmp",hook_event_name:$e,tool_name:$t,tool_input:{questions:[{question:"Which color?"}]},tool_use_id:$id} + $r'
}
STOCKJ="{\"tool_response\":$(jq -Rn --arg s "$STOCK" '$s')}"
run "$(tool_event PostToolUse AskUserQuestion "$STOCKJ" toolu_p1 s-tool-1)"
context "PostToolUse: a rejection string becomes additionalContext" PostToolUse
run "$(tool_event PostToolUse AskUserQuestion "{\"tool_response\":{\"is_error\":true,\"content\":[{\"type\":\"text\",\"text\":$(jq -Rn --arg s "$STOCK" '$s')}]}}" toolu_p2 s-tool-2)"
context "PostToolUse: the text inside a nested result object is found" PostToolUse
run "$(tool_event PostToolUseFailure AskUserQuestion '{"error":"Tool permission request aborted","is_interrupt":true}' toolu_f1 s-tool-3)"
context "PostToolUseFailure: the aborted variant is found" PostToolUseFailure
run "$(tool_event PermissionDenied AskUserQuestion "{\"reason\":$(jq -Rn --arg s "$STOCK" '$s')}" toolu_d1 s-tool-4)"
context "PermissionDenied: handled too, should Claude Code ever send it" PermissionDenied
run "$(tool_event PostToolUse AskUserQuestion '{"tool_response":{"answers":{"Which color?":"Red"}}}' toolu_p3 s-tool-5)"
silent "PostToolUse: an answered question is left alone"
run "$(tool_event PostToolUse Bash "{\"tool_response\":{\"stdout\":$(jq -Rn --arg s "$STOCK" '$s')}}" toolu_p4 s-tool-6)"
silent "PostToolUse: another tool is never judged, whatever its output says"
run "$(tool_event PostToolUse AskUserQuestion "$STOCKJ" toolu_p5 s-tool-7 | jq -c '.agent_id = "agent-9"')"
silent "a lane (agent_id) is never told"
run "$(tool_event PostToolUse AskUserQuestion "$STOCKJ" toolu_p6 s-tool-8)" ASKUSER_CANCEL=0
silent "ASKUSER_CANCEL=0 turns it off"

# One rejected question is reported once across every event (a tool branch with no once-per-id
# record would tell the agent twice or three times: PostToolUse twice, or PostToolUse and then
# UserPromptSubmit).
run "$(tool_event PostToolUse AskUserQuestion "$STOCKJ" toolu_o1 s-once-1)"
context "tool events: the first report of a rejected question speaks" PostToolUse
run "$(tool_event PostToolUse AskUserQuestion "$STOCKJ" toolu_o1 s-once-1)"
silent "  the same event again for the same question and session is silent"
run "$(tool_event PostToolUseFailure AskUserQuestion '{"error":"Tool permission request aborted"}' toolu_o1 s-once-1)"
silent "  and so is another event name for the same question"
run "$(tool_event PostToolUse AskUserQuestion "$STOCKJ" toolu_o2 s-once-1)"
context "  a second, different rejected question in the same session speaks" PostToolUse
run "$(tool_event PostToolUse AskUserQuestion "$STOCKJ" toolu_o1 s-once-2)"
context "  and another session's copy speaks on its own" PostToolUse
run "$(tool_event PostToolUse AskUserQuestion "$STOCKJ" "" s-once-3)"
context "a tool event with no tool_use_id still speaks (nothing to key the record by)" PostToolUse

# --- transcript events: UserPromptSubmit (in time) and Stop (the backstop) ------------
rec_ask()    { jq -nc --arg id "$1" --arg ts "$2" '{type:"assistant",isSidechain:false,timestamp:$ts,message:{role:"assistant",content:[{type:"tool_use",id:$id,name:"AskUserQuestion",input:{questions:[{question:"Which color?"}]}}]}}'; }
rec_reject() { jq -nc --arg id "$1" --arg ts "$2" --arg s "$STOCK" '{type:"user",isSidechain:false,timestamp:$ts,message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,content:$s,is_error:true}]}}'; }
rec_answer() { jq -nc --arg id "$1" --arg ts "$2" '{type:"user",isSidechain:false,timestamp:$ts,message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,content:"User has answered your questions: Red"}]}}'; }
rec_text()   { jq -nc --arg t "$1" --arg ts "$2" '{type:"user",isSidechain:false,timestamp:$ts,message:{role:"user",content:[{type:"text",text:$t}]}}'; }
rec_queue()  { jq -nc '{type:"queue-operation",operation:"dequeue"}'; }
mk() { local out="$1"; shift; : > "$out"; local r; for r in "$@"; do printf '%s\n' "$r" >> "$out"; done; }
event() { # <event> <session> <transcript>
  jq -nc --arg e "$1" --arg s "$2" --arg t "$3" '{session_id:$s,transcript_path:$t,cwd:"/tmp",hook_event_name:$e,prompt:"From another thread: new exploration task",stop_hook_active:false}'
}

NOW="$(ago 20)"
mk "$T/cancelled.jsonl" "$(rec_text 'Start the work' "$(ago 300)")" "$(rec_ask toolu_A "$(ago 120)")" "$(rec_reject toolu_A "$NOW")" \
   "$(rec_text '[Request interrupted by user for tool use]' "$NOW")" "$(rec_queue)" "$(rec_text 'From another thread: new exploration task for you' "$NOW")"
run "$(event UserPromptSubmit s-1 "$T/cancelled.jsonl")"
context "UserPromptSubmit: the message that cancelled the question brings the reminder with it" UserPromptSubmit
[ "$(tail -1 "$LOG" | jq -r .outcome)" = context ] && [ "$(tail -1 "$LOG" | jq -r .event)" = UserPromptSubmit ] && ! grep -q "Which color" "$LOG" \
  && pass "  and the log line has the event and the outcome, never question text" || fail "log line" "$(tail -1 "$LOG")"
run "$(event UserPromptSubmit s-1 "$T/cancelled.jsonl")"
silent "  the same cancelled question is reported once per session"
run "$(event Stop s-1 "$T/cancelled.jsonl")"
silent "  and not again at Stop"
run "$(event UserPromptSubmit s-2 "$T/cancelled.jsonl")"
context "  another session's copy is reported on its own" UserPromptSubmit

run "$(event Stop s-3 "$T/cancelled.jsonl")"
blocked "Stop: a cancelled question the agent never corrected blocks the stop once"
[ "$(tail -1 "$LOG" | jq -r .outcome)" = stop_block ] && pass "  logged as stop_block" || fail "stop log" "$(tail -1 "$LOG")"
run "$(event Stop s-3 "$T/cancelled.jsonl")"
silent "  and only once"
run "$(event Stop s-4 "$T/cancelled.jsonl" | jq -c '.stop_hook_active = true')"
silent "Stop: a stop that is already a continuation (stop_hook_active) is never blocked"

mk "$T/stale.jsonl" "$(rec_ask toolu_B "$(ago 7300)")" "$(rec_reject toolu_B "$(ago 7200)")" "$(rec_text 'a later message' "$(ago 7100)")"
run "$(event UserPromptSubmit s-5 "$T/stale.jsonl")"
silent "a cancellation older than 30 minutes is ignored"
mk "$T/reasked.jsonl" "$(rec_ask toolu_C "$(ago 120)")" "$(rec_reject toolu_C "$(ago 100)")" "$(rec_ask toolu_D "$(ago 60)")" "$(rec_text 'a later message' "$(ago 30)")"
run "$(event UserPromptSubmit s-6 "$T/reasked.jsonl")"
silent "a question that was asked again afterwards is no longer reported"
mk "$T/answered.jsonl" "$(rec_ask toolu_E "$(ago 120)")" "$(rec_answer toolu_E "$(ago 100)")" "$(rec_text 'a later message' "$(ago 30)")"
run "$(event UserPromptSubmit s-7 "$T/answered.jsonl")"
silent "an answered question is left alone"
mk "$T/other-tool.jsonl" "$(jq -nc --arg ts "$(ago 100)" '{type:"assistant",isSidechain:false,timestamp:$ts,message:{role:"assistant",content:[{type:"tool_use",id:"toolu_F",name:"Edit",input:{}}]}}')" "$(rec_reject toolu_F "$(ago 90)")"
run "$(event UserPromptSubmit s-8 "$T/other-tool.jsonl")"
silent "a rejected Edit is not an AskUserQuestion and is left alone"
mk "$T/side.jsonl" "$(rec_ask toolu_G "$(ago 100)" | jq -c '.isSidechain = true')" "$(rec_reject toolu_G "$(ago 90)" | jq -c '.isSidechain = true')"
run "$(event UserPromptSubmit s-9 "$T/side.jsonl")"
silent "a question from an in-process lane (sidechain) is not reported to the foreman"
# --- one question, every event: the tool branch shares the record and the freshness check ----
run "$(tool_event PostToolUse AskUserQuestion "$STOCKJ" toolu_A s-x-1 "$T/cancelled.jsonl")"
context "a tool event for a rejected question reports it" PostToolUse
run "$(event UserPromptSubmit s-x-1 "$T/cancelled.jsonl")"
silent "  the UserPromptSubmit that follows does not report the same question again"
run "$(event Stop s-x-1 "$T/cancelled.jsonl")"
silent "  and neither does Stop"
run "$(event UserPromptSubmit s-x-2 "$T/cancelled.jsonl")"
context "UserPromptSubmit first reports the question" UserPromptSubmit
run "$(tool_event PostToolUse AskUserQuestion "$STOCKJ" toolu_A s-x-2 "$T/cancelled.jsonl")"
silent "  and a tool event for the same question after it is silent"
run "$(tool_event PostToolUse AskUserQuestion "$STOCKJ" toolu_B s-x-3 "$T/stale.jsonl")"
silent "a tool event for a rejection older than 30 minutes is ignored, like the transcript events"
# Without a session id the record is kept per transcript path, so a repeat is still recognised.
nosid() { jq -c 'del(.session_id)'; }
run "$(event UserPromptSubmit x "$T/cancelled.jsonl" | nosid)"
context "a payload with no session id still reports the question" UserPromptSubmit
run "$(event UserPromptSubmit x "$T/cancelled.jsonl" | nosid)"
silent "  once: the record is kept per transcript"
run "$(event Stop x "$T/cancelled.jsonl" | nosid)"
silent "  and not again at Stop"
cp "$T/cancelled.jsonl" "$T/cancelled-copy.jsonl"
run "$(event UserPromptSubmit x "$T/cancelled-copy.jsonl" | nosid)"
context "  another transcript is reported on its own" UserPromptSubmit

printf 'a plain transcript with no question in it\n{"type":"user"}\n' > "$T/plain.jsonl"
run "$(event UserPromptSubmit s-10 "$T/plain.jsonl")"
silent "a transcript with no rejection costs nothing and says nothing"
before="$(wc -l < "$LOG")"
for junk in 'not json' '' '[]' '{"hook_event_name":"UserPromptSubmit"}' '{"hook_event_name":"Stop","transcript_path":"/nonexistent/x.jsonl"}' '{"hook_event_name":"SessionStart"}'; do
  run "$junk"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "garbage or unrelated input: '${junk:0:40}'" "rc=$RC out='$OUT'"
done
[ "$(wc -l < "$LOG")" = "$before" ] && pass "garbage, empty and unrelated events exit 0, print nothing and log nothing" || fail "garbage input logged"

# --- lanes: bin/lane-class decides, found beside the hook's directory ------------------
CC="$T/cc"; mkdir -p "$CC/hooks" "$CC/bin"
cp "$DIR/askuser-cancel.sh" "$DIR/askuser-cancel.py" "$DIR/hooklib.sh" "$CC/hooks/"
lane_stub() {
  printf '#!/usr/bin/env bash\ncat > "%s/lane-payload"\necho x >> "%s/lane-calls"\n%s\n' "$T" "$T" "$1" > "$CC/bin/lane-class"
  chmod +x "$CC/bin/lane-class"; : > "$T/lane-calls"
}
HOOKSH="$CC/hooks/askuser-cancel.sh"
lane_stub 'echo t3-lane'
run "$(event UserPromptSubmit l-1 "$T/cancelled.jsonl")"
silent "a t3-lane thread is never told"
[ "$(tail -1 "$LOG" | jq -r .outcome)" = pass_lane ] && pass "  and the log says it was a lane" || fail "lane log" "$(tail -1 "$LOG")"
[ "$(jq -r .session_id "$T/lane-payload")" = l-1 ] && pass "  bin/lane-class receives the hook JSON on stdin" || fail "lane-class stdin"
run "$(tool_event PostToolUse AskUserQuestion "$STOCKJ" toolu_l1 l-tool)"
silent "a t3-lane thread is not told on a tool event either"
[ "$(tail -1 "$LOG" | jq -r .outcome)" = pass_lane ] && pass "  and the log says it was a lane" || fail "tool event lane log" "$(tail -1 "$LOG")"
calls_before="$(wc -l < "$T/lane-calls" | tr -d ' ')"
run "$(event UserPromptSubmit l-2 "$T/plain.jsonl")"
[ "$(wc -l < "$T/lane-calls" | tr -d ' ')" = "$calls_before" ] && pass "an ordinary prompt never pays for bin/lane-class" || fail "lane-class asked without a cancelled question"
lane_stub 'echo foreman'
run "$(event UserPromptSubmit l-3 "$T/cancelled.jsonl")"
context "a foreman is told" UserPromptSubmit
lane_stub 'sleep 3; echo t3-lane'
t0="$(date +%s%N)"; run "$(event UserPromptSubmit l-4 "$T/cancelled.jsonl")"; ms=$(( ($(date +%s%N) - t0) / 1000000 ))
if [ "$(jq -r .hookSpecificOutput.hookEventName <<<"$OUT" 2>/dev/null)" = UserPromptSubmit ] && [ "$ms" -lt 2500 ]; then
  pass "a hung bin/lane-class is cut off and counts as foreman (${ms} ms)"
else fail "hung lane-class" "ms=$ms out='${OUT:0:100}'"; fi
rm -f "$CC/bin/lane-class"
run "$(event UserPromptSubmit l-5 "$T/cancelled.jsonl")"
context "no bin/lane-class on this box means foreman (the contract's fallback)" UserPromptSubmit
unset HOOKSH

# --- robustness -------------------------------------------------------------------------
mkdir -p "$T/bad/hooks"; cp "$DIR/askuser-cancel.sh" "$DIR/hooklib.sh" "$T/bad/hooks/"
printf 'import sys\nsys.stdout.write("garbage\\n")\nraise SystemExit(3)\n' > "$T/bad/hooks/askuser-cancel.py"
HOOKSH="$T/bad/hooks/askuser-cancel.sh" run "$(event UserPromptSubmit b-1 "$T/cancelled.jsonl")"
silent "a helper that prints garbage and exits nonzero is silent"
printf 'import sys\nsys.stdout.write("something else entirely\\n")\n' > "$T/bad/hooks/askuser-cancel.py"
HOOKSH="$T/bad/hooks/askuser-cancel.sh" run "$(event UserPromptSubmit b-2 "$T/cancelled.jsonl")"
silent "helper output that is not one of the two JSON shapes is dropped"
if grep -qE $'\xe2\x80\x94|\xe2\x80\x93' "$DIR/askuser-cancel.py"; then fail "the reminder text has no em or en dash"; else pass "the reminder text has no em or en dash"; fi

if [ "$fails" -eq 0 ]; then
  echo "askuser-cancel-selftest: ALL CASES PASS"
  exit 0
else
  echo "askuser-cancel-selftest: $fails case(s) failing"
  exit 1
fi
