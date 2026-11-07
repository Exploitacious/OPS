#!/usr/bin/env bash
# report-lint-selftest.sh: prove report-lint.sh sends an over-long ask back exactly once,
# for the right reasons, and is silent in every other case: short messages, the rewrite
# itself (stop_hook_active), lanes, the same message twice, deferral language, garbage in.
# Offline: every path the hook reads (HOME, the state dir, the transcript) is under a temp
# dir. The shape rules have their own unit tests in report-lint-regression-test.py, run at
# the end. Exit 0 = every case passes; 1 = a case fails.
# shellcheck disable=SC2015
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/report-lint.sh"
fails=0
pass(){ printf '  PASS  %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; fails=$((fails + 1)); }

echo "report-lint-selftest:"
command -v python3 >/dev/null 2>&1 || { echo "report-lint-selftest: SKIP (no python3; the hook is silent without it)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "report-lint-selftest: FAIL (jq required for the assertions)"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1

T="$(mktemp -d)"
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup(){ rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/state" "$T/home"
LOG="$T/state/report-lint.jsonl"

# --- fixtures: the same shapes the unit tests use ----------------------------------
FIX="$DIR/report-lint-regression-test.py"
python3 -B - "$FIX" "$T" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fx", sys.argv[1]); fx = importlib.util.module_from_spec(spec); spec.loader.exec_module(fx)
t = sys.argv[2]
files = {"list24": fx.numbered_decisions(24), "list3": fx.numbered_decisions(3), "list4": fx.numbered_decisions(4),
         "table": fx.DECISION_TABLE,
         "card": fx.ASK_CARD, "deferral": fx.DEFERRAL, "status": fx.STATUS_WITH_IDS,
         "short": "## Decisions for you\n" + "".join("%d. Approve job %d? I recommend yes.\n" % (i, i) for i in range(1, 9))}
for name, body in files.items():
    open(f"{t}/{name}.txt", "w").write(body)
PY
[ "$(wc -c < "$T/short.txt")" -lt 400 ] || fail "fixture: the short message must be under 400 characters"
# ... and it must be a message the rules WOULD send back were it long enough, or the case proves nothing.
python3 -B - "$DIR/report-lint.py" "$T/short.txt" <<'PY' || fail "fixture: the short message must trip the ask rule when judged on shape alone"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rl", sys.argv[1]); rl = importlib.util.module_from_spec(spec); spec.loader.exec_module(rl)
v = rl.judge(open(sys.argv[2]).read())
sys.exit(0 if v and v[0] == "asks" else 1)
PY

# payload <session> <message file> [key=value jq args as JSON snippets]: a Stop payload.
payload() {
  local sid="$1" file="$2"; shift 2
  jq -nc --arg s "$sid" --rawfile m "$file" '{session_id:$s,transcript_path:"/nonexistent",cwd:"/tmp",hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:$m}' \
    | jq -c "$@" 2>/dev/null || true
}
run() { # <payload json> [NAME=VALUE ...]: stdout in $OUT, exit in $RC, wall ms in $MS
  local json="$1"; shift
  local t0 t1
  t0="$(date +%s%N)"
  OUT="$(printf '%s' "$json" | env HOME="$T/home" OPS_STATE_DIR="$T/state" "$@" bash "${HOOKSH:-$HOOK}" 2>"$T/err")"
  RC=$?
  t1="$(date +%s%N)"; MS=$(( (t1 - t0) / 1000000 ))
}
logf() { tail -1 "$LOG" | jq -r "$1"; }
silent() { # <label>: no stdout, exit 0
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -s "$T/err" ]; then pass "$1"; else fail "$1" "rc=$RC out='${OUT:0:120}' err='$(head -c 120 "$T/err")'"; fi
}
blocks() { # <label> <trigger>: one valid block line naming the trigger
  if [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] \
     && [ "$(jq -r .decision <<<"$OUT" 2>/dev/null)" = block ] && [ -n "$(jq -r .reason <<<"$OUT" 2>/dev/null)" ] \
     && [ "$(logf .trigger)" = "$2" ] && [ "$(logf .outcome)" = blocked ]; then pass "$1"
  else fail "$1" "rc=$RC out='${OUT:0:200}' log=$(tail -1 "$LOG" 2>/dev/null)"; fi
}

# --- the three triggers ---------------------------------------------------------------
run "$(payload s-asks "$T/list24.txt")"
blocks "a 24-item decision list is sent back" asks
reason="$(jq -r .reason <<<"$OUT")"
if [ "${#reason}" -lt 700 ] && grep -q 'ask card' <<<"$reason" && grep -q 'at most three asks' <<<"$reason" \
   && ! grep -qiE 'later|tomorrow|defer|next week' <<<"$reason" && ! grep -q $'\xe2\x80\x94' <<<"$reason"; then
  pass "the reason is short, names the ask card and the cap, and never mentions deferral"
else fail "reason text" "${#reason} chars: $reason"; fi
if [ "$(logf .detail.asks)" -ge 20 ] && [ "$(logf .session)" = s-asks ] && [ "$(logf .chars)" -gt 400 ] && ! grep -q "Item 1 of the device" "$LOG"; then
  pass "the log line carries counts and a hash, never message text"
else fail "log content" "$(tail -1 "$LOG")"; fi

run "$(payload s-asks "$T/list24.txt")"
silent "the same message is never sent back twice"
[ "$(logf .outcome)" = pass_already_blocked ] && pass "  and the log says why" || fail "second stop log" "$(tail -1 "$LOG")"
run "$(payload s-other "$T/list24.txt")"
blocks "another session's copy of the message is judged on its own" asks

run "$(payload s-table "$T/table.txt")"
blocks "a decision table is sent back" table
[ "$(logf .detail.rows)" = 6 ] && pass "  with its row count" || fail "table rows" "$(tail -1 "$LOG")"

run "$(payload s-ids "$T/list3.txt")"
silent "three decisions pass"
run "$(payload s-four "$T/list4.txt")"
blocks "a fourth decision is sent back (the rule: more than three)" asks
[ "$(logf .detail.asks)" = 4 ] && pass "  with its count" || fail "four-ask count" "$(tail -1 "$LOG")"
MIXED="$T/mixed.txt"
{ printf 'Two calls for you.\n\n## Decisions for you\n\n'
  printf '1. **#1395 D3.** Should clearing an incident need a grant? I recommend the token only.\n'
  printf '2. **#375 and 9b799c0.** Flip the reconcile flag after the dry run? I recommend yes, per ENG-1001.\n'
  printf 'Everything else is on track and nothing is blocked today.%.0s ' $(seq 1 7); printf '\n'; } > "$MIXED"
run "$(payload s-ids "$MIXED")"
blocks "bare IDs inside two asks are sent back" ids
run "$(payload s-status "$T/status.txt")"
silent "a status paragraph full of PR numbers is left alone"
NAMED="$T/named.txt"
{ printf 'Three calls for you.\n\n## Needs you\n\n'
  printf '1. **Printer rollout (ENG-1001)** is overdue. Should I log today'"'"'s time on it? I recommend yes.\n'
  printf '2. **Seat expansion (ENG-1002)** is waiting. Should I close it out? I recommend yes.\n'
  printf '3. **License audit (ENG-1003)** is ready. Should I send it? I recommend yes.\n'
  printf 'Everything else is on track and nothing is blocked today.%.0s ' $(seq 1 7); printf '\n'; } > "$NAMED"
run "$(payload s-named "$NAMED")"
silent "three asks whose IDs each have their title beside them are not sent back"
SELLER="$T/seller.txt"
{ printf 'Ask every seller:\n'
  for i in 1 2 3 4 5; do printf -- '- Has unit number %s ever been in a crash, and what was fixed on it?\n' "$i"; done
  printf 'Everything else is routine and nothing is blocked today.%.0s ' $(seq 1 6); printf '\n'; } > "$SELLER"
run "$(payload s-seller "$SELLER")"
silent "questions to put to someone else under an imperative heading are not asks for the Operator"
TICKETS="$T/tickets.txt"
{ printf 'Two calls for you.\n\n## Decisions for you\n\n'
  printf '1. Should I close ENG-1001? I recommend yes.\n'
  printf '2. Approve ENG-1002 and ENG-1003? I recommend yes.\n'
  printf 'Everything else is on track and nothing is blocked today.%.0s ' $(seq 1 7); printf '\n'; } > "$TICKETS"
run "$(payload s-tkt-1 "$TICKETS")"
blocks "three bare tracker IDs (ENG-1001 style) inside two asks are sent back" ids
run "$(payload s-tkt-2 "$TICKETS")" REPORT_LINT_TICKET_RE='\bJOB/[0-9]{3}\b'
silent "REPORT_LINT_TICKET_RE replaces the ticket pattern: under another scheme those are not IDs"

# --- what must not block -------------------------------------------------------------
run "$(payload s-card "$T/card.txt")"
silent "the ask card shape (three asks, a bucket of eight lines) passes: the fix must not trip the check"
run "$(payload s-def "$T/deferral.txt")"
silent "deferral language is never policed"
run "$(payload s-short "$T/short.txt")"
silent "a message under 400 characters is never sent back, however many asks it has"
run "$(payload s-sha "$T/list24.txt" '.stop_hook_active = true')"
silent "a stop that is already the rewrite (stop_hook_active) is never blocked"
run "$(payload s-agent "$T/list24.txt" '.agent_id = "agent-abc123"')"
silent "a lane (agent_id) is never blocked"
run "$(payload s-off "$T/list24.txt")" REPORT_LINT=0
silent "REPORT_LINT=0 turns the hook off"
run "$(payload s-evt "$T/list24.txt" '.hook_event_name = "SubagentStop"')"
silent "another hook event is ignored"
before="$(wc -l < "$LOG")"
for junk in 'not json' '' '[]' '{"hook_event_name":"Stop"}' '{"hook_event_name":"Stop","transcript_path":"/nonexistent/x.jsonl"}'; do
  run "$junk"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] || fail "garbage input: '${junk:0:30}'" "rc=$RC out='$OUT'"
done
[ "$(wc -l < "$LOG")" = "$before" ] && pass "garbage and empty input exit 0, print nothing and log nothing" || fail "garbage input logged"

# --- the transcript: only the final message of the turn is judged --------------------
tx() { # <out file> <records as jq -c args> ...: one JSONL file from JSON records
  local out="$1"; shift; : > "$out"
  local r; for r in "$@"; do printf '%s\n' "$r" >> "$out"; done
}
user() { jq -nc --arg t "$1" '{type:"user",isSidechain:false,message:{role:"user",content:$t}}'; }
asst() { jq -nc --arg t "$1" '{type:"assistant",isSidechain:false,message:{role:"assistant",content:[{type:"text",text:$t}]}}'; }
tool_use() { jq -nc '{type:"assistant",isSidechain:false,message:{role:"assistant",content:[{type:"tool_use",id:"t1",name:"Bash",input:{}}]}}'; }
tool_result() { jq -nc '{type:"user",isSidechain:false,message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",content:"ok"}]}}'; }
stop_of() { jq -nc --arg s "$1" --arg p "$2" '{session_id:$s,transcript_path:$p,hook_event_name:"Stop",stop_hook_active:false}'; }
# A long list in the middle of a working turn is narration; only the message the Operator reads
# last is judged. (A first build caught a 24-item list followed by "the decisions are above";
# the rule gives that up on purpose.)
tx "$T/tx-pointer.jsonl" "$(user 'Give me any decisions you need me to make')" "$(asst "$(cat "$T/list24.txt")")" "$(tool_use)" "$(tool_result)" \
   "$(asst 'The 24 decisions are above. I saved the full list to the resume note.')"
run "$(stop_of s-tx1 "$T/tx-pointer.jsonl")"
silent "a long list earlier in the turn is not judged when the final message is a short pointer to it"
tx "$T/tx-final.jsonl" "$(user 'what do you need from me')" "$(asst 'Checking the board first.')" "$(tool_use)" "$(tool_result)" "$(asst "$(cat "$T/list24.txt")")"
run "$(stop_of s-tx4 "$T/tx-final.jsonl")"
blocks "with no payload copy, the last text block of the turn is the one judged" asks
tx "$T/tx-clean-final.jsonl" "$(user 'prompt')" "$(asst "$(cat "$T/list24.txt")")" "$(asst "$(cat "$T/card.txt")")"
run "$(stop_of s-tx5 "$T/tx-clean-final.jsonl")"
silent "a clean ask card as the final message passes however long the narration before it was"
run "$(stop_of s-tx6 "$T/tx-pointer.jsonl" | jq -c --rawfile m "$T/list24.txt" '.last_assistant_message = $m')"
blocks "the payload's last_assistant_message wins over a transcript that lags it" asks
run "$(stop_of s-tx7 "$T/tx-final.jsonl" | jq -c '.last_assistant_message = "Short and clean, nothing to decide."')"
silent "  and a short payload copy is the final message even when the transcript's last block is a long list"
tx "$T/tx-old.jsonl" "$(user 'first prompt')" "$(asst "$(cat "$T/list24.txt")")" "$(user 'ok, thanks')" "$(asst 'Done. Nothing else is open right now.')"
run "$(stop_of s-tx2 "$T/tx-old.jsonl")"
silent "a list from an earlier turn is not judged again"
tx "$T/tx-lane.jsonl" "$(user 'prompt')" "$(jq -nc --arg t "$(cat "$T/list24.txt")" '{type:"assistant",isSidechain:true,message:{role:"assistant",content:[{type:"text",text:$t}]}}')" "$(asst 'Short answer.')"
run "$(stop_of s-tx3 "$T/tx-lane.jsonl")"
silent "text from an in-process lane (a sidechain record) is not judged"

# --- once per message, with or without a session id ----------------------------------
nosid() { jq -c 'del(.session_id)'; }
run "$(payload x "$T/list24.txt" '.transcript_path = "/nonexistent/one.jsonl"' | nosid)"
blocks "a payload with no session id is still judged and blocked" asks
run "$(payload x "$T/list24.txt" '.transcript_path = "/nonexistent/one.jsonl"' | nosid)"
silent "  and the same message is not sent back again: the record is kept per transcript"
[ "$(logf .outcome)" = pass_already_blocked ] && pass "  the log says why" || fail "no-session second stop log" "$(tail -1 "$LOG")"
run "$(payload x "$T/list24.txt" '.transcript_path = "/nonexistent/two.jsonl"' | nosid)"
blocks "  another transcript's copy is judged on its own" asks
run "$(payload x "$T/list24.txt" | nosid | jq -c 'del(.transcript_path)')"
blocks "with neither a session id nor a transcript the message is still blocked once" asks
run "$(payload x "$T/list24.txt" | nosid | jq -c 'del(.transcript_path)')"
silent "  and only once"

# --- lanes: bin/lane-class decides, the hook finds it beside its own directory --------
CC="$T/cc"; mkdir -p "$CC/hooks" "$CC/bin"
cp "$DIR/report-lint.sh" "$DIR/report-lint.py" "$DIR/hooklib.sh" "$CC/hooks/"
lane_stub() {
  printf '#!/usr/bin/env bash\ncat > "%s/lane-payload"\necho x >> "%s/lane-calls"\n%s\n' "$T" "$T" "$1" > "$CC/bin/lane-class"
  chmod +x "$CC/bin/lane-class"; : > "$T/lane-calls"
}
lane_calls() { wc -l < "$T/lane-calls" | tr -d ' '; }
HOOKSH="$CC/hooks/report-lint.sh"
lane_stub 'echo t3-lane'
run "$(payload l-1 "$T/list24.txt")"
silent "a t3-lane thread is never blocked"
[ "$(logf .outcome)" = pass_lane ] && [ "$(logf .lane)" = t3-lane ] && pass "  and the log says it was a lane" || fail "lane log" "$(tail -1 "$LOG")"
if [ "$(jq -r .session_id "$T/lane-payload")" = l-1 ] && [ "$(jq -r .hook_event_name "$T/lane-payload")" = Stop ]; then
  pass "  bin/lane-class receives the Stop payload on stdin"
else fail "lane-class stdin" "$(cat "$T/lane-payload")"; fi
lane_stub 'echo agent-lane'
run "$(payload l-2 "$T/list24.txt")"
silent "an agent-lane answer is never blocked either"
lane_stub 'echo foreman'
run "$(payload l-3 "$T/list24.txt")"
blocks "a foreman is blocked" asks
lane_stub 'echo t3-lane'
run "$(payload l-4 "$T/short.txt")"
[ "$(lane_calls)" = 0 ] && pass "an ordinary stop never pays for bin/lane-class" || fail "lane-class called for a short message" "calls=$(lane_calls)"
run "$(payload l-5 "$T/status.txt")"
[ "$(lane_calls)" = 0 ] && pass "  nor does a long message that passes the shape rules" || fail "lane-class called for a pass" "calls=$(lane_calls)"
lane_stub 'sleep 3; echo t3-lane'
run "$(payload l-6 "$T/list24.txt")"
if [ "$(jq -r .decision <<<"$OUT" 2>/dev/null)" = block ] && [ "$MS" -lt 2500 ]; then
  pass "a hung bin/lane-class is cut off, counts as foreman and still blocks (${MS} ms)"
else fail "hung lane-class" "ms=$MS out='${OUT:0:100}'"; fi
lane_stub 'echo banana'
run "$(payload l-7 "$T/list24.txt")"
[ "$(jq -r .decision <<<"$OUT" 2>/dev/null)" = block ] && pass "an unrecognised lane-class answer counts as foreman" || fail "bad lane-class answer" "out='${OUT:0:100}'"
rm -f "$CC/bin/lane-class"
run "$(payload l-8 "$T/list24.txt")"
[ "$(jq -r .decision <<<"$OUT" 2>/dev/null)" = block ] && pass "no bin/lane-class on this box means foreman (the contract's fallback)" || fail "absent lane-class" "out='${OUT:0:100}'"
unset HOOKSH

# --- robustness -----------------------------------------------------------------------
# A state dir that cannot be written must not turn a lint into a failure or a loop.
mkdir -p "$T/ro" && chmod 500 "$T/ro"
if [ "$(id -u)" != 0 ]; then
  OUT="$(payload r-1 "$T/list24.txt" | env HOME="$T/home" OPS_STATE_DIR="$T/ro/state" bash "$HOOK" 2>"$T/err")"; RC=$?
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && pass "an unwritable state dir: silent, exit 0 (without a record it will not block)" || fail "unwritable state" "rc=$RC out='${OUT:0:100}'"
fi
chmod 700 "$T/ro"
# The helper dying leaves exit 0 and no output.
mkdir -p "$T/bad/hooks"; cp "$DIR/report-lint.sh" "$DIR/hooklib.sh" "$T/bad/hooks/"
printf 'import sys\nsys.stdout.write("garbage\\n")\nraise SystemExit(3)\n' > "$T/bad/hooks/report-lint.py"
HOOKSH="$T/bad/hooks/report-lint.sh"; run "$(payload b-1 "$T/list24.txt")"; unset HOOKSH
silent "a helper that prints garbage and exits nonzero is silent"
printf 'import sys\nsys.stdout.write("something else entirely\\n")\n' > "$T/bad/hooks/report-lint.py"
HOOKSH="$T/bad/hooks/report-lint.sh"; run "$(payload b-2 "$T/list24.txt")"; unset HOOKSH
silent "helper output that is not the block line is dropped"

# --- the unit tests -------------------------------------------------------------------
if python3 -B "$DIR/report-lint-regression-test.py" >"$T/unit.out" 2>&1; then
  pass "shape, transcript, state and lane unit tests ($(grep -E '^Ran ' "$T/unit.out"))"
else
  fail "unit tests" "$(tail -15 "$T/unit.out")"
fi

if [ "$fails" -eq 0 ]; then
  echo "report-lint-selftest: ALL CASES PASS"
  exit 0
else
  echo "report-lint-selftest: $fails case(s) failing"
  exit 1
fi
