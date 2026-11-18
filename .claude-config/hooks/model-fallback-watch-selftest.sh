#!/usr/bin/env bash
# model-fallback-watch-selftest.sh: prove model-fallback-watch.sh flags a refusal fallback in
# the session or in any of its lanes exactly once, in the shape a Stop hook must answer with
# (one JSON block line, exit 0), and stays silent otherwise: no event, the words quoted in a
# message or a raw file, a continuation stop (stop_hook_active), an event already logged,
# garbage in, the off switch. Also: all three fallback subtypes, flat and nested lanes,
# concurrent Stops logging one row, a line that completes after a Stop, a ledger that cannot
# be written (offsets kept, flag repeats, retry succeeds), a state path blocked by a regular
# file (fails the same way as root), an unexpected helper error, owner-only state under a
# permissive umask, and no Python on PATH.
# Offline and hermetic: the transcripts, lane files and state dir are under a temp dir, with
# synthetic model ids; no host transcript is read.
# Exit 0 = every case passes; 1 = a case fails; 77 = did not run (a prerequisite is missing).
# shellcheck disable=SC2015
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/model-fallback-watch.sh"
HELPER="$DIR/model-fallback-watch.py"
fails=0
pass(){ printf '  PASS  %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; fails=$((fails + 1)); }

echo "model-fallback-watch-selftest:"
command -v python3 >/dev/null 2>&1 || { echo "model-fallback-watch-selftest: did not run: no python3 (the hook is silent without it)"; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "model-fallback-watch-selftest: did not run: no jq (the assertions need it)"; exit 77; }

T="$(mktemp -d)"
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup(){ chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
export OPS_STATE_DIR="$T/state"
LEDGER="$T/state/model-fallbacks.tsv"
PROJ="$T/projects/p"
mkdir -p "$PROJ"
M_BIG=example-model-large; M_FB=example-model-fallback; M_MID=example-model-mid

event(){  # event <uuid> <from> <to> <category> [subtype] [scope] [requestId]
  jq -cn --arg u "$1" --arg f "$2" --arg t "$3" --arg c "$4" --arg st "${5:-model_refusal_fallback}" --arg sc "${6:-}" --arg r "${7:-req_$1}" \
    '{type:"system",subtype:$st,apiRefusalCategory:$c,originalModel:$f,fallbackModel:$t,
      requestId:$r,retractedMessageUuids:[],refusedUserMessageUuid:null,uuid:$u,timestamp:"2026-01-02T09:00:00.000Z"}
     + (if $sc != "" then {scope:$sc} else {} end)'
}
ordinary(){  # a user and an assistant record
  printf '%s\n' '{"type":"user","uuid":"u1","message":{"role":"user","content":"hi"}}' \
    '{"type":"assistant","uuid":"a1","message":{"model":"example-model-large","content":[{"type":"text","text":"hello"}]}}'
}
payload(){  # payload <session_id> <stop_hook_active>
  jq -cn --arg s "$1" --arg tp "$PROJ/$1.jsonl" --argjson a "$2" \
    '{session_id:$s,transcript_path:$tp,hook_event_name:"Stop",stop_hook_active:$a}'
}
run(){  # run <session_id> <stop_hook_active> -> stdout of the hook
  payload "$1" "$2" | bash "$HOOK"
}
rows(){ [ -f "$LEDGER" ] && tail -n +2 "$LEDGER" | grep -c . || echo 0; }
mode(){ python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
is_block(){ printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

# 1. A clean session with a clean lane: silent, no ledger.
ordinary > "$PROJ/s1.jsonl"; mkdir -p "$PROJ/s1/subagents"; ordinary > "$PROJ/s1/subagents/agent-aaa.jsonl"
out="$(run s1 false)"
[ -z "$out" ] && [ ! -f "$LEDGER" ] && pass "clean session and lane: silent, no ledger" || fail "clean session and lane: silent, no ledger" "$out"

# 2. A fallback in the session itself: one block line that names both models and the category,
#    and the hook exits 0 while saying so.
{ ordinary; event ev-1 "$M_BIG" "$M_FB" cyber; ordinary; } > "$PROJ/s2.jsonl"
out="$(payload s2 false | bash "$HOOK")"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e --arg f "$M_BIG" --arg t "$M_FB" '.decision == "block" and (.reason | contains("this session: " + $f + " moved to " + $t + " after a cyber refusal at ")) and (.reason | contains("from that point on it ran on " + $t)) and (.systemMessage | startswith("Model fallback: this session: " + $f + " to " + $t))' >/dev/null 2>&1 \
   && [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ]; then pass "session fallback: exit 0 and one block line naming the models and the category"
else fail "session fallback: exit 0 and one block line naming the models and the category" "rc $rc $out"; fi
[ "$(rows)" = 1 ] && head -1 "$LEDGER" | grep -q '^logged_at	session_id	where	event_key' \
  && pass "session fallback: one ledger row under a header" || fail "session fallback: one ledger row under a header" "$(cat "$LEDGER" 2>/dev/null)"
printf '%s' "$out" | jq -e --arg l "$LEDGER" '.reason | contains("Logged in " + $l)' >/dev/null 2>&1 \
  && pass "session fallback: the reason names the ledger" || fail "session fallback: the reason names the ledger" "$out"

# 3. The same stop again: already logged, silent, no new row.
out="$(run s2 false)"
[ -z "$out" ] && [ "$(rows)" = 1 ] && pass "an event already logged is not flagged again" || fail "an event already logged is not flagged again" "$out / rows $(rows)"

# 4. A fallback inside a background lane, with its description from the meta file.
ordinary > "$PROJ/s4.jsonl"; mkdir -p "$PROJ/s4/subagents"
{ ordinary; event ev-4 "$M_BIG" "$M_MID" biology; } > "$PROJ/s4/subagents/agent-bbb.jsonl"
printf '%s\n' '{"agentType":"worker","description":"Premise pass on the plan","finished":true}' > "$PROJ/s4/subagents/agent-bbb.meta.json"
out="$(run s4 false)"
printf '%s' "$out" | jq -e --arg f "$M_BIG" --arg t "$M_MID" '.decision == "block" and (.reason | contains("lane '"'"'Premise pass on the plan'"'"' (worker): " + $f + " moved to " + $t + " after a biology refusal"))' >/dev/null 2>&1 \
  && pass "lane fallback: names the lane by its description and type" || fail "lane fallback: names the lane by its description and type" "$out"

# 5. Decoys: the words quoted in a message (escaped JSON), in a raw tool-results file, and a
#    system record with another subtype. None is an event.
ordinary > "$PROJ/s5.jsonl"
jq -cn '{type:"user",uuid:"u9",message:{role:"user",content:("see {\"type\":\"system\",\"subtype\":\"model_refusal_fallback\"} in the notes")}}' >> "$PROJ/s5.jsonl"
jq -cn '{type:"assistant",uuid:"a9",message:{model:"example-model-large",content:[{type:"tool_use",name:"Bash",input:{command:"grep -rlF \"\\\"subtype\\\":\\\"model_refusal_fallback\\\"\" ."}}]}}' >> "$PROJ/s5.jsonl"
jq -cn '{type:"system",subtype:"model_refusal_fallback_note",uuid:"x1",originalModel:"a",fallbackModel:"b"}' >> "$PROJ/s5.jsonl"
jq -cn '{type:"user",subtype:"model_refusal_fallback",uuid:"x2",originalModel:"a",fallbackModel:"b"}' >> "$PROJ/s5.jsonl"
jq -cn '{type:"system",subtype:"model_refusal_no_fallback",uuid:"x3",originalModel:"a"}' >> "$PROJ/s5.jsonl"
mkdir -p "$PROJ/s5/subagents" "$PROJ/s5/tool-results"
printf '%s\n' '{"type":"system","subtype":"model_refusal_fallback"}' > "$PROJ/s5/tool-results/raw.txt"
printf '%s\n' '{"type":"system","subtype":"model_refusal_fallback","uuid":"not-a-lane"}' > "$PROJ/s5/subagents/agent-ccc.meta.json"
out="$(run s5 false)"
[ -z "$out" ] && pass "quoted words, raw files, a user record and a hard refusal are not events" || fail "quoted words, raw files, a user record and a hard refusal are not events" "$out"

# 6. A continuation stop (stop_hook_active) never blocks and logs nothing; the next ordinary
#    stop flags the event.
{ ordinary; event ev-6 "$M_BIG" "$M_FB" cyber; } > "$PROJ/s6.jsonl"
before="$(rows)"; out="$(run s6 true)"
[ -z "$out" ] && [ "$(rows)" = "$before" ] && pass "a continuation stop is silent and logs nothing" || fail "a continuation stop is silent and logs nothing" "$out"
out="$(run s6 false)"
is_block "$out" && pass "the next ordinary stop flags it" || fail "the next ordinary stop flags it" "$out"
out="$(run s6 false)"
[ -z "$out" ] && pass "and the repeat stop after that is silent" || fail "and the repeat stop after that is silent" "$out"

# 7. Two events at once (the session and a lane): one block, two lines, two rows.
{ ordinary; event ev-7a "$M_BIG" "$M_FB" cyber; } > "$PROJ/s7.jsonl"
mkdir -p "$PROJ/s7/subagents"; { event ev-7b "$M_BIG" "$M_FB" cyber; } > "$PROJ/s7/subagents/agent-ddd.jsonl"
before="$(rows)"; out="$(run s7 false)"
n="$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null | grep -c '^- ')"
[ "$n" = 2 ] && [ "$(rows)" = $((before + 2)) ] && pass "two events: one block with two lines and two rows" || fail "two events: one block with two lines and two rows" "lines $n rows $(rows)"

# 8. Garbage and absences: malformed lines, no transcript, not JSON, the off switch.
{ printf '%s\n' 'not json {"subtype":"model_refusal_fallback"'; ordinary; } > "$PROJ/s8.jsonl"
out="$(run s8 false)"; [ -z "$out" ] && pass "malformed lines: silent" || fail "malformed lines: silent" "$out"
out="$(jq -cn --arg tp "$PROJ/missing.jsonl" '{session_id:"m",transcript_path:$tp,stop_hook_active:false}' | bash "$HOOK")"
[ -z "$out" ] && pass "missing transcript: silent" || fail "missing transcript: silent" "$out"
out="$(printf 'not json' | bash "$HOOK")"; rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && pass "a payload that is not JSON: silent, exit 0" || fail "a payload that is not JSON: silent, exit 0" "rc $rc $out"
{ ordinary; event ev-8 "$M_BIG" "$M_FB" cyber; } > "$PROJ/s8b.jsonl"
before="$(rows)"; out="$(MODEL_FALLBACK_WATCH=0 run s8b false)"
[ -z "$out" ] && [ "$(rows)" = "$before" ] && pass "MODEL_FALLBACK_WATCH=0 turns it off (no flag, no row)" || fail "MODEL_FALLBACK_WATCH=0 turns it off (no flag, no row)" "$out"

# 9. All three fallback subtypes are flagged. Only the first has been seen on a real
#    installation; the other two are unverified, so this pins the fields they are read with.
{ ordinary; event ev-9a "$M_BIG" "$M_FB" cyber model_refusal_fallback; } > "$PROJ/s9a.jsonl"
out="$(run s9a false)"
printf '%s' "$out" | jq -e '.reason | contains("after a cyber refusal")' >/dev/null 2>&1 && pass "model_refusal_fallback is flagged" || fail "model_refusal_fallback is flagged" "$out"
{ ordinary; event ev-9b "$M_BIG" "$M_MID" "" model_fallback; } > "$PROJ/s9b.jsonl"
out="$(run s9b false)"
printf '%s' "$out" | jq -e --arg f "$M_BIG" --arg t "$M_MID" '.reason | contains($f + " moved to " + $t + " (model_fallback)")' >/dev/null 2>&1 \
  && pass "model_fallback is flagged" || fail "model_fallback is flagged" "$out"
{ ordinary; event ev-9c "$M_BIG" "$M_MID" "" model_consent_fallback; } > "$PROJ/s9c.jsonl"
out="$(run s9c false)"
printf '%s' "$out" | jq -e --arg f "$M_BIG" --arg t "$M_MID" '.reason | contains($f + " moved to " + $t + " (model_consent_fallback)")' >/dev/null 2>&1 \
  && pass "model_consent_fallback is flagged" || fail "model_consent_fallback is flagged" "$out"

# 10. A workflow lane, two levels down (subagents/workflows/wf_<id>/), with flat lanes
#     before it that have no event: every file is read and the nested one is found.
ordinary > "$PROJ/s11.jsonl"; mkdir -p "$PROJ/s11/subagents/workflows/wf_abc-123"
ordinary > "$PROJ/s11/subagents/agent-aaa.jsonl"; ordinary > "$PROJ/s11/subagents/agent-bbb.jsonl"
{ ordinary; event ev-11 "$M_BIG" "$M_FB" cyber; } > "$PROJ/s11/subagents/workflows/wf_abc-123/agent-zzz.jsonl"
out="$(run s11 false)"
printf '%s' "$out" | jq -e --arg f "$M_BIG" '.decision == "block" and (.reason | contains("lane zzz: " + $f + " moved to"))' >/dev/null 2>&1 \
  && pass "a workflow lane two levels down is read" || fail "a workflow lane two levels down is read" "$out"
ordinary > "$PROJ/s11b.jsonl"; mkdir -p "$PROJ/s11b/subagents"; ordinary > "$PROJ/s11b/subagents/agent-a1.jsonl"
{ ordinary; event ev-11b "$M_BIG" "$M_FB" cyber; } > "$PROJ/s11b/subagents/agent-a2.jsonl"
out="$(run s11b false)"
printf '%s' "$out" | jq -e '.reason | contains("lane a2:")' >/dev/null 2>&1 && pass "every flat lane is read, not just the first" || fail "every flat lane is read, not just the first" "$out"

# 11. Keys: a provisional and a final record share a requestId and are one event; a record
#     with no requestId falls back to its uuid; the same event in another session flags there.
{ ordinary; event ev-12a "$M_BIG" "$M_FB" cyber model_refusal_fallback "" req-shared;
  event ev-12b "$M_BIG" "$M_FB" cyber model_refusal_fallback "" req-shared; } > "$PROJ/s12.jsonl"
out="$(run s12 false)"; n="$(printf '%s' "$out" | jq -r '.reason' 2>/dev/null | grep -c '^- ')"
[ "$n" = 1 ] && pass "a provisional and a final record are one event" || fail "a provisional and a final record are one event" "lines $n"
jq -cn --arg f "$M_BIG" --arg t "$M_FB" '{type:"system",subtype:"model_refusal_fallback",originalModel:$f,fallbackModel:$t,uuid:"only-uuid"}' > "$PROJ/s12b.jsonl"
out="$(run s12b false)"; out2="$(run s12b false)"
is_block "$out" && [ -z "$out2" ] && grep -q '	only-uuid	' "$LEDGER" \
  && pass "no requestId: keyed by uuid, flagged once" || fail "no requestId: keyed by uuid, flagged once" "$out / $out2"
cp "$PROJ/s2.jsonl" "$PROJ/s12c.jsonl"; out="$(run s12c false)"
is_block "$out" && pass "the same event in another session flags there" || fail "the same event in another session flags there" "$out"

# 12. Scope local: one response, the model did not change.
{ ordinary; event ev-13 "$M_BIG" "$M_FB" cyber model_refusal_fallback local; } > "$PROJ/s13.jsonl"
out="$(run s13 false)"
printf '%s' "$out" | jq -e --arg t "$M_FB" '.reason | contains("one response in it came from " + $t + "; its own model did not change")' >/dev/null 2>&1 \
  && pass "scope local: one response, the model did not change" || fail "scope local: one response, the model did not change" "$out"

# 13. Robustness: an event after 300 lines; a line nested past the recursion limit before a
#     real event; a lone surrogate and a tab in a model id; an unreadable lane before an event
#     lane; a transcript path that is not .jsonl.
{ for _ in $(seq 150); do ordinary; done; event ev-14 "$M_BIG" "$M_FB" cyber; } > "$PROJ/s14.jsonl"
out="$(run s14 false)"; is_block "$out" && pass "an event after 300 lines is found" || fail "an event after 300 lines is found" "$out"
{ python3 -c 'print("{\"type\":\"system\",\"subtype\":\"model_refusal_fallback\",\"x\":" + "[" * 200000 + "]" * 200000 + "}")'
  event ev-14b "$M_BIG" "$M_FB" cyber; } > "$PROJ/s14b.jsonl"
out="$(run s14b false)"; printf '%s' "$out" | jq -e '.reason | contains("Model fallback (")' >/dev/null 2>&1 \
  && pass "a line nested past the recursion limit does not hide a later event" || fail "a line nested past the recursion limit does not hide a later event" "$out"
printf '%s\n' '{"type":"system","subtype":"model_refusal_fallback","originalModel":"example-model-large\ud800","fallbackModel":"example-model-fallback\tx","uuid":"ev-14c"}' > "$PROJ/s14c.jsonl"
out="$(run s14c false)"
is_block "$out" && grep '	ev-14c	' "$LEDGER" | awk -F'\t' '{exit (NF == 10 ? 0 : 1)}' \
  && pass "a lone surrogate and a tab in a model id: flagged, one 10-field row" || fail "a lone surrogate and a tab in a model id: flagged, one 10-field row" "$out"
if [ "$(id -u)" != 0 ]; then
  ordinary > "$PROJ/s14d.jsonl"; mkdir -p "$PROJ/s14d/subagents"
  { event ev-14d "$M_BIG" "$M_FB" cyber; } > "$PROJ/s14d/subagents/agent-a0.jsonl"; chmod 000 "$PROJ/s14d/subagents/agent-a0.jsonl"
  { event ev-14e "$M_BIG" "$M_FB" cyber; } > "$PROJ/s14d/subagents/agent-a9.jsonl"
  out="$(run s14d false)"; chmod 644 "$PROJ/s14d/subagents/agent-a0.jsonl"
  printf '%s' "$out" | jq -e '.reason | contains("lane a9:")' >/dev/null 2>&1 && pass "an unreadable lane does not stop the others" || fail "an unreadable lane does not stop the others" "$out"
else
  pass "an unreadable lane: skipped as root (permissions do not bind)"
fi
cp "$PROJ/s2.jsonl" "$PROJ/s2.json"; out="$(jq -cn --arg tp "$PROJ/s2.json" '{session_id:"s2x",transcript_path:$tp,stop_hook_active:false}' | bash "$HOOK")"
[ -z "$out" ] && pass "a transcript path that is not .jsonl is ignored" || fail "a transcript path that is not .jsonl is ignored" "$out"

# 14. Offsets: an event appended to an already-read transcript is flagged on the next Stop;
#     a transcript rewritten shorter is read again from the top.
ordinary > "$PROJ/s15.jsonl"; out="$(run s15 false)"
event ev-15 "$M_BIG" "$M_FB" cyber >> "$PROJ/s15.jsonl"; out="$(run s15 false)"
is_block "$out" && pass "an event appended after a Stop is flagged on the next" || fail "an event appended after a Stop is flagged on the next" "$out"
off="$(jq -r --arg p "$PROJ/s15.jsonl" '.[$p] | if type == "object" then .offset else . end' "$T/state/model-fallback-scan/s15.json" 2>/dev/null)"
[ "$off" = "$(wc -c < "$PROJ/s15.jsonl")" ] && pass "the read offset is saved at the end of what was read" || fail "the read offset is saved at the end of what was read" "offset $off size $(wc -c < "$PROJ/s15.jsonl")"
event ev-15b "$M_BIG" "$M_FB" cyber > "$PROJ/s15.jsonl"; out="$(run s15 false)"
is_block "$out" && pass "a transcript rewritten shorter is read from the top" || fail "a transcript rewritten shorter is read from the top" "$out"

# A replacement can be larger than the previous transcript. Check both an atomic rename
# and a truncate-and-rewrite on the same inode, with the new event before the old offset.
{ event ev-15c "$M_BIG" "$M_FB" cyber; ordinary; ordinary; } > "$PROJ/replacement.jsonl"
mv "$PROJ/replacement.jsonl" "$PROJ/s15.jsonl"
out="$(run s15 false)"
is_block "$out" && grep -q 'ev-15c' "$LEDGER" && pass "a larger replacement transcript starts at byte zero" \
  || fail "a larger replacement transcript starts at byte zero" "$out"
{ event ev-15d "$M_BIG" "$M_FB" cyber; ordinary; ordinary; ordinary; } > "$PROJ/s15.jsonl"
out="$(run s15 false)"
is_block "$out" && grep -q 'ev-15d' "$LEDGER" && pass "a larger rewrite on the same inode starts at byte zero" \
  || fail "a larger rewrite on the same inode starts at byte zero" "$out"

# 15. An incomplete line is not read, and is read whole once it completes.
{ ordinary; } > "$PROJ/s18.jsonl"
line="$(event ev-18 "$M_BIG" "$M_FB" cyber)"
printf '%s' "${line:0:60}" >> "$PROJ/s18.jsonl"
before="$(rows)"; out="$(run s18 false)"
[ -z "$out" ] && [ "$(rows)" = "$before" ] && pass "a half-written line is not an event yet" || fail "a half-written line is not an event yet" "$out"
printf '%s\n' "${line:60}" >> "$PROJ/s18.jsonl"
out="$(run s18 false)"
is_block "$out" && [ "$(rows)" = $((before + 1)) ] && pass "the same line, once complete, is flagged once" || fail "the same line, once complete, is flagged once" "$out / rows $(rows)"

# 16. A lane description is cut to one short line in the reason and the ledger.
ordinary > "$PROJ/s16.jsonl"; mkdir -p "$PROJ/s16/subagents"
{ event ev-16 "$M_BIG" "$M_FB" cyber; } > "$PROJ/s16/subagents/agent-d1.jsonl"
jq -cn --arg d "$(printf 'first line\nsecond line %0300d' 0)" '{agentType:"worker",description:$d}' > "$PROJ/s16/subagents/agent-d1.meta.json"
out="$(run s16 false)"
line="$(printf '%s' "$out" | jq -r '.reason' | grep '^- lane ')"
printf '%s' "$line" | grep -q "lane 'first line second line" && [ "${#line}" -lt 300 ] \
  && pass "a long two-line description stays one short line" || fail "a long two-line description stays one short line" "$line"

# 17. Concurrent Stops of one session: the lock and the ledger check give one row and one
#     flag, however the processes interleave.
{ ordinary; event ev-17 "$M_BIG" "$M_FB" cyber; } > "$PROJ/s17.jsonl"
before="$(rows)"; pids=()
for i in 1 2 3 4 5 6; do run s17 false > "$T/conc-$i.out" & pids+=($!); done
for p in "${pids[@]}"; do wait "$p"; done
nb="$(cat "$T"/conc-*.out | grep -c '"decision": "block"')"
[ "$nb" = 1 ] && [ "$(rows)" = $((before + 1)) ] && pass "six concurrent Stops: one flag, one ledger row" || fail "six concurrent Stops: one flag, one ledger row" "blocks $nb rows $(rows)"

# 18. A ledger that cannot be written (the ledger path is a directory, which fails even as
#     root): the flag still fires and says so, the offsets are not advanced, and once the
#     path is fixed the same event is logged and flagged on the next Stop.
S2="$T/state-bad"; mkdir -p "$S2/model-fallbacks.tsv"
{ ordinary; event ev-19 "$M_BIG" "$M_FB" cyber; } > "$PROJ/s19.jsonl"
out="$(OPS_STATE_DIR="$S2" run s19 false)"
printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("Could not write the ledger"))' >/dev/null 2>&1 \
  && pass "unwritable ledger: still flags and says so" || fail "unwritable ledger: still flags and says so" "$out"
[ ! -f "$S2/model-fallback-scan/s19.json" ] && pass "unwritable ledger: offsets are left for a retry" || fail "unwritable ledger: offsets are left for a retry" "$(cat "$S2/model-fallback-scan/s19.json")"
out="$(OPS_STATE_DIR="$S2" run s19 false)"
printf '%s' "$out" | jq -e '.reason | contains("Could not write the ledger")' >/dev/null 2>&1 \
  && pass "unwritable ledger: the flag repeats on the next Stop" || fail "unwritable ledger: the flag repeats on the next Stop" "$out"
rmdir "$S2/model-fallbacks.tsv"
out="$(OPS_STATE_DIR="$S2" run s19 false)"
printf '%s' "$out" | jq -e '.reason | contains("Logged in ")' >/dev/null 2>&1 && [ "$(grep -c 'ev-19' "$S2/model-fallbacks.tsv")" = 1 ] \
  && pass "retry after the fix: one row, flagged as logged" || fail "retry after the fix: one row, flagged as logged" "$out"
out="$(OPS_STATE_DIR="$S2" run s19 false)"
[ -z "$out" ] && pass "and then it is quiet" || fail "and then it is quiet" "$out"

# The next process may encounter a ledger append interrupted after its event ID.
# Only the complete row counts, and the earlier row must survive recovery.
event ev-19b "$M_BIG" "$M_FB" cyber >> "$PROJ/s19.jsonl"
printf '2026-01-02T09:00:00Z\ts19\tthis session\treq_ev-19b\t' >> "$S2/model-fallbacks.tsv"
size="$(wc -c < "$S2/model-fallbacks.tsv")"
out="$(payload s19 false | OPS_STATE_DIR="$S2" python3 -I -c '
import runpy
import sys
sys.modules["fcntl"] = None
runpy.run_path(sys.argv[1], run_name="__main__")
' "$HELPER")"
printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("requires manual repair without a lock"))' >/dev/null 2>&1 \
  && [ "$size" = "$(wc -c < "$S2/model-fallbacks.tsv")" ] \
  && pass "without fcntl, the incomplete ledger needs repair and stays intact" \
  || fail "without fcntl, the incomplete ledger needs repair and stays intact" "$out"
out="$(OPS_STATE_DIR="$S2" run s19 false)"
is_block "$out" && awk -F '\t' '
  NF != 10 { bad = 1 }
  $4 == "req_ev-19" { earlier++ }
  $4 == "req_ev-19b" { retried++ }
  END { exit (bad || earlier != 1 || retried != 1) }
' "$S2/model-fallbacks.tsv" && pass "an interrupted append is recovered without losing the new or existing row" \
  || fail "an interrupted append is recovered without losing the new or existing row" "$out"

# 19. A state path blocked by a regular file (no directory can be made, as root or not).
printf 'x' > "$T/blocker"
{ ordinary; event ev-20 "$M_BIG" "$M_FB" cyber; } > "$PROJ/s20.jsonl"
out="$(OPS_STATE_DIR="$T/blocker" run s20 false)"; rc=$?
printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("Could not write the ledger"))' >/dev/null 2>&1 && [ "$rc" = 0 ] \
  && pass "state path is a regular file: flags, says so, exit 0" || fail "state path is a regular file: flags, says so, exit 0" "rc $rc $out"

# 20. A ledger lock held by another process: the hook waits its bounded 5 seconds, then
#     reports the ledger as unwritable (and keeps offsets) instead of hanging or dropping it.
S3="$T/state-lock"; mkdir -p "$S3"; : > "$S3/model-fallbacks.tsv"
python3 -I -c 'import fcntl,sys,time
f=open(sys.argv[1],"a")
fcntl.flock(f,fcntl.LOCK_EX)
print("held",flush=True)
time.sleep(9)' "$S3/model-fallbacks.tsv" > "$T/holder.out" &
holder=$!
for _ in $(seq 50); do grep -q held "$T/holder.out" 2>/dev/null && break; sleep 0.1; done
{ ordinary; event ev-21 "$M_BIG" "$M_FB" cyber; } > "$PROJ/s21.jsonl"
t0=$SECONDS; out="$(OPS_STATE_DIR="$S3" run s21 false)"; waited=$((SECONDS - t0))
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("Could not write the ledger"))' >/dev/null 2>&1 && [ "$waited" -le 8 ] && [ ! -f "$S3/model-fallback-scan/s21.json" ] \
  && pass "a held ledger lock: flagged as unwritable after a bounded wait, offsets kept" || fail "a held ledger lock: flagged as unwritable after a bounded wait, offsets kept" "waited ${waited}s $out"

# 21. Owner-only state under a permissive umask: a state dir the hook creates is 0700, the
#     ledger and the offsets file 0600, the offsets directory 0700.
S4="$T/fresh/state"
{ ordinary; event ev-22 "$M_BIG" "$M_FB" cyber; } > "$PROJ/s22.jsonl"
out="$( umask 000; OPS_STATE_DIR="$S4" run s22 false )"
got="$(mode "${S4%/*}") $(mode "$S4") $(mode "$S4/model-fallbacks.tsv") $(mode "$S4/model-fallback-scan") $(mode "$S4/model-fallback-scan/s22.json")"
is_block "$out" && [ "$got" = "700 700 600 700 600" ] && pass "owner-only state under umask 000, including newly created ancestors" \
  || fail "owner-only state under umask 000, including newly created ancestors" "modes: $got"

# 22. An unexpected helper error is loud, not silent: the helper is run with its main()
#     made to raise after the continuation check, which reaches the real error handler. The traceback file is 0600, the
#     stop is blocked once naming it, a continuation stop stays silent, and a state path
#     that cannot hold the file says the traceback could not be saved.
cat > "$T/inject.py" <<'PYEOF'
import sys
src = open(sys.argv[1]).read().replace("    tp = payload.get(\"transcript_path\")\n", "    raise RuntimeError('injected failure')\n    tp = payload.get(\"transcript_path\")\n", 1)
sys.argv = [sys.argv[1]]
exec(compile(src, sys.argv[0], "exec"), {"__name__": "__main__"})
PYEOF
S5="$T/state-err"
out="$(payload s2 false | OPS_STATE_DIR="$S5" python3 "$T/inject.py" "$HELPER")"
printf '%s' "$out" | jq -e --arg e "$S5/model-fallback-watch.err" '.decision == "block" and (.reason | contains("traceback in " + $e))' >/dev/null 2>&1 \
  && grep -q 'injected failure' "$S5/model-fallback-watch.err" && [ "$(mode "$S5/model-fallback-watch.err")" = 600 ] \
  && pass "unexpected error: blocks naming a 0600 traceback file" || fail "unexpected error: blocks naming a 0600 traceback file" "$out"
out="$(payload s2 true | OPS_STATE_DIR="$S5" python3 "$T/inject.py" "$HELPER")"
[ -z "$out" ] && pass "unexpected error on a continuation stop: silent" || fail "unexpected error on a continuation stop: silent" "$out"
out="$(payload s2 false | OPS_STATE_DIR="$T/blocker" python3 "$T/inject.py" "$HELPER")"
printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("could not be saved"))' >/dev/null 2>&1 \
  && pass "unexpected error with no writable state: says the traceback was not saved" || fail "unexpected error with no writable state: says the traceback was not saved" "$out"

# 23. No Python 3 on PATH: the hook stays silent and exits 0 (documented), rather than
#     printing anything into the session.
NOPY="$T/nopy"; mkdir -p "$NOPY"
for tool in cat dirname jq bash; do ln -s "$(command -v "$tool")" "$NOPY/$tool"; done
{ ordinary; event ev-23 "$M_BIG" "$M_FB" cyber; } > "$PROJ/s23.jsonl"
before="$(rows)"; out="$(payload s23 false | PATH="$NOPY" "$(command -v bash)" "$HOOK")"; rc=$?
[ -z "$out" ] && [ "$rc" = 0 ] && [ "$(rows)" = "$before" ] && pass "no python on PATH: silent, exit 0, nothing logged" || fail "no python on PATH: silent, exit 0, nothing logged" "rc $rc $out"

# 24. Every ledger row has the header's field count.
awk -F'\t' 'NR == 1 { n = NF } NF != n { bad = 1 } END { exit bad }' "$LEDGER" && pass "every ledger row has the header's field count" || fail "every ledger row has the header's field count" "$(awk -F'\t' '{print NF}' "$LEDGER" | sort | uniq -c)"

# 25. No unexpected error was recorded along the way in the main state dir.
[ ! -s "$T/state/model-fallback-watch.err" ] && pass "no unexpected error recorded" || fail "no unexpected error recorded" "$(cat "$T/state/model-fallback-watch.err")"

if [ "$fails" -eq 0 ]; then
  echo "model-fallback-watch-selftest: ALL CASES PASS"
  exit 0
else
  echo "model-fallback-watch-selftest: $fails case(s) failing"
  exit 1
fi
