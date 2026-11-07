#!/usr/bin/env bash
# lane-class-test.sh: behavior tests for bin/lane-class, the one test every boot
# hook uses to tell a foreman from a lane.
#
# All three answers are covered, each by more than one kind of evidence:
#   agent-lane  an agent_id in the hook payload; agent_type alone is the --agent
#               main thread and does not count.
#   t3-lane     a T3 thread id with the "thread:" prefix T3 gives its own
#               delegated and provider threads (no db read), but only for the
#               session the environment belongs to (the payload's session_id must
#               be the one in CLAUDE_CODE_SESSION_ID, or that variable unset): an
#               empty payload or another session's id inherits nothing, so a hook
#               test run from inside a delegated lane still sees a foreman;
#               --self classifies the calling session from its own environment; a
#               bare-uuid thread is a foreman unless the state db gives it a
#               subagent lineage; with no trusted thread id the payload's session
#               id is mapped through the state db (an unmapped or ambiguous
#               session is NOT guessed at); with no db the transcript's first user
#               message ("Act as the <kind> sub-agent for this task.") decides.
#   foreman     everything else: garbage, empty and tty-less input, a corrupt or
#               missing db, a missing jq, and a missing python all answer foreman
#               with exit 0.
# Also pinned: the override env wins; the db is never written; the fast paths and
# the db path stay under 300 ms; and, when this host runs T3, one real delegated
# session id and one real top-level session id read from the live read-only db
# classify correctly (SKIP without a T3 db).
#
# Every other case builds a throwaway db and transcript under a temp dir. The
# ambient T3CODE_THREAD_ID, CLAUDE_CODE_SESSION_ID and OPS_LANE_CLASS are cleared
# for each run and set per case.
#
# Usage: lane-class-test.sh    (exit 0 all pass, 1 otherwise)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LC="${LANE_CLASS_UNDER_TEST:-$HERE/../lane-class}"
[ -x "$LC" ] || { echo "FAIL: $LC missing or not executable"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required"; exit 1; }
BASH_BIN="$(command -v bash)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }

# run_lc <payload> [VAR=value ...]: prints the verdict; $rc holds the exit code.
run_lc() {
  local payload="$1"; shift
  out="$(printf '%s' "$payload" | env -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_LANE_CLASS \
      -u LANE_CLASS_DB -u LANE_CLASS_NO_DB HOME="$T/home" "$@" "$BASH_BIN" "$LC" 2>"$T/err")"
  rc=$?
}
expect() {  # expect <label> <want> <payload> [env...]
  local label="$1" want="$2" payload="$3"; shift 3
  run_lc "$payload" "$@"
  if [ "$out" = "$want" ] && [ "$rc" -eq 0 ]; then ok "$label -> $want"
  else bad "$label: want $want, got '$out' (rc=$rc)" "$(cat "$T/err")"; fi
}

mkdir -p "$T/home"
echo "lane-class-test:"

# --- fixture state db: the two tables lane-class reads ------------------------
DB="$T/statev2.sqlite"
python3 -I - "$DB" <<'PY' || { echo "FAIL: cannot build the fixture db"; exit 1; }
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, active_provider_thread_id TEXT, payload_json TEXT NOT NULL)")
con.execute("CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT PRIMARY KEY, thread_id TEXT, owner_node_id TEXT, payload_json TEXT NOT NULL)")
def thread(tid, lineage=None):
    pj = {"id": tid}
    if lineage:
        pj["lineage"] = lineage
    con.execute("INSERT INTO orchestration_v2_projection_threads VALUES (?,?,?)", (tid, "pt-" + tid, json.dumps(pj)))
def provider(pid, tid, native):
    con.execute("INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,NULL,?)",
                (pid, tid, json.dumps({"nativeThreadRef": {"nativeId": native}})))
DELEG = "thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Ax"
thread(DELEG, {"parentThreadId": "p", "relationshipToParent": "subagent", "rootThreadId": "p"})
provider("pt-d", DELEG, "sess-delegated")
thread("11111111-1111-4111-8111-111111111111")                      # a top-level foreman thread
provider("pt-f", "11111111-1111-4111-8111-111111111111", "sess-foreman")
# a bare-uuid thread that nevertheless carries a subagent lineage (a possible future shape)
thread("22222222-2222-4222-8222-222222222222", {"parentThreadId": "p", "relationshipToParent": "subagent"})
provider("pt-u", "22222222-2222-4222-8222-222222222222", "sess-uuid-sub")
# one session id mapped to two different threads: ambiguous, never guessed
provider("pt-a1", DELEG, "sess-ambiguous")
provider("pt-a2", "11111111-1111-4111-8111-111111111111", "sess-ambiguous")
thread("thread:manual:foreman")
provider("pt-prefixed-top", "thread:manual:foreman", "sess-prefixed-top")
con.commit(); con.close()
PY
DB_SUM_BEFORE="$(cksum < "$DB")"; DB_MT_BEFORE="$(stat -c %Y "$DB")"

# --- 1. the hook payload ------------------------------------------------------
expect "agent_id set" agent-lane '{"agent_id":"agent-abc123","session_id":"s","hook_event_name":"SubagentStart"}'
expect "agent_id set wins over a foreman thread id" agent-lane '{"agent_id":"a1"}' T3CODE_THREAD_ID=11111111-1111-4111-8111-111111111111
expect "agent_type without agent_id is the --agent main thread" foreman '{"agent_type":"x","session_id":"s"}' LANE_CLASS_NO_DB=1
expect "empty agent_id is not a lane" foreman '{"agent_id":"","session_id":"s"}' LANE_CLASS_NO_DB=1

# --- 2. T3CODE_THREAD_ID in the environment -----------------------------------
SIDP='{"session_id":"sess-env"}'
expect "delegated-task thread id" t3-lane "$SIDP" 'T3CODE_THREAD_ID=thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Ax' LANE_CLASS_NO_DB=1
expect "T3-made provider subagent thread id" t3-lane "$SIDP" 'T3CODE_THREAD_ID=thread:provider:claudeAgent:native-thread:x' LANE_CLASS_NO_DB=1
expect "an unrecognized thread prefix is not proof of delegation" foreman "$SIDP" 'T3CODE_THREAD_ID=thread:manual:foreman' LANE_CLASS_NO_DB=1
expect "bare uuid thread id, state db says top-level" foreman "$SIDP" T3CODE_THREAD_ID=11111111-1111-4111-8111-111111111111 LANE_CLASS_DB="$DB"
expect "bare uuid thread id with a subagent lineage in the db" t3-lane "$SIDP" T3CODE_THREAD_ID=22222222-2222-4222-8222-222222222222 LANE_CLASS_DB="$DB"
expect "bare uuid thread id, no db" foreman "$SIDP" T3CODE_THREAD_ID=33333333-3333-4333-8333-333333333333 LANE_CLASS_NO_DB=1

# --- 2b. the ambient thread id is only used for the session it belongs to -----
LANE_ENV=(T3CODE_THREAD_ID=thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Ax LANE_CLASS_NO_DB=1)
expect "payload session id equals CLAUDE_CODE_SESSION_ID: the ambient lane thread id counts" t3-lane "$SIDP" "${LANE_ENV[@]}" CLAUDE_CODE_SESSION_ID=sess-env
expect "payload session id is another session's: the ambient lane thread id is ignored" foreman "$SIDP" "${LANE_ENV[@]}" CLAUDE_CODE_SESSION_ID=some-outer-lane
expect "empty payload: the ambient lane thread id is ignored" foreman '' "${LANE_ENV[@]}"
expect "payload without a session id: the ambient lane thread id is ignored" foreman '{}' "${LANE_ENV[@]}" CLAUDE_CODE_SESSION_ID=some-outer-lane
# --self: the calling session, from its own environment (no payload)
self_lc() {  # self_lc VAR=value...
  out="$(env -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_LANE_CLASS -u LANE_CLASS_DB -u LANE_CLASS_NO_DB HOME="$T/home" "$@" "$BASH_BIN" "$LC" --self </dev/null 2>"$T/err")"; rc=$?
}
self_lc "${LANE_ENV[@]}"
{ [ "$out" = t3-lane ] && [ "$rc" -eq 0 ]; } && ok "--self: this session's own lane thread id counts" || bad "--self lane: '$out' rc=$rc"
self_lc T3CODE_THREAD_ID=11111111-1111-4111-8111-111111111111 LANE_CLASS_DB="$DB"
{ [ "$out" = foreman ] && [ "$rc" -eq 0 ]; } && ok "--self: a top-level thread id is a foreman" || bad "--self foreman: '$out' rc=$rc"
self_lc LANE_CLASS_DB="$DB" CLAUDE_CODE_SESSION_ID=sess-delegated
{ [ "$out" = t3-lane ] && [ "$rc" -eq 0 ]; } && ok "--self: with no thread id, CLAUDE_CODE_SESSION_ID is mapped through the state db" || bad "--self via db: '$out' rc=$rc"

# --- 3. session id through the state db ---------------------------------------
expect "session id mapped to a delegated-task thread" t3-lane '{"session_id":"sess-delegated"}' LANE_CLASS_DB="$DB"
expect "session id mapped to a top-level thread" foreman '{"session_id":"sess-foreman"}' LANE_CLASS_DB="$DB"
expect "a prefixed thread with a top-level db row is still a foreman" foreman '{"session_id":"sess-prefixed-top"}' LANE_CLASS_DB="$DB"
expect "session id mapped to a uuid thread with a subagent lineage" t3-lane '{"session_id":"sess-uuid-sub"}' LANE_CLASS_DB="$DB"
expect "session id that maps to two threads is not guessed" foreman '{"session_id":"sess-ambiguous"}' LANE_CLASS_DB="$DB"
expect "unmapped session id" foreman '{"session_id":"sess-nobody"}' LANE_CLASS_DB="$DB"
expect "no session id in the payload: the ambient CLAUDE_CODE_SESSION_ID is not used for a lookup" foreman '{}' LANE_CLASS_DB="$DB" CLAUDE_CODE_SESSION_ID=sess-delegated

# --- 4. transcript first message (no thread id, no db) ------------------------
tx() {  # tx <file> <first user text>
  python3 -I - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "custom-title", "customTitle": "t"}) + "\n")
    f.write(json.dumps({"type": "attachment", "attachment": {"type": "hook_success"}}) + "\n")
    f.write(json.dumps({"type": "user", "isSidechain": False, "message": {"role": "user", "content": sys.argv[2]}}) + "\n")
PY
}
tx "$T/lane.jsonl" $'Act as the review sub-agent for this task.\n\nYou are a read-only lane.'
tx "$T/plain.jsonl" 'In this thread, I want to explore my previous threads.'
tx "$T/deleg.jsonl" 'Delegated task: check the disk.'
tx "$T/architect.jsonl" 'Act as the lane architect and explain our design.'
tx "$T/agent-role.jsonl" 'Act as a security sub-agent and explain the assessment.'
tx "$T/deleg-question.jsonl" 'Delegated task handling needs a design review.'
expect "transcript opens with the delegate_task wrapper" t3-lane "{\"transcript_path\":\"$T/lane.jsonl\"}" LANE_CLASS_NO_DB=1
expect "transcript opens with a Delegated task notice" t3-lane "{\"transcript_path\":\"$T/deleg.jsonl\"}" LANE_CLASS_NO_DB=1
expect "transcript opens with a person's prompt" foreman "{\"transcript_path\":\"$T/plain.jsonl\"}" LANE_CLASS_NO_DB=1
expect "lane in a normal role prompt does not silence a foreman" foreman "{\"transcript_path\":\"$T/architect.jsonl\"}" LANE_CLASS_NO_DB=1
expect "sub-agent in a normal role prompt is not the delegation wrapper" foreman "{\"transcript_path\":\"$T/agent-role.jsonl\"}" LANE_CLASS_NO_DB=1
expect "a question about delegated tasks is still a foreman" foreman "{\"transcript_path\":\"$T/deleg-question.jsonl\"}" LANE_CLASS_NO_DB=1
expect "ambiguous session mapping beats a lane-looking transcript" foreman "{\"session_id\":\"sess-ambiguous\",\"transcript_path\":\"$T/lane.jsonl\"}" LANE_CLASS_DB="$DB"
expect "transcript path that does not exist" foreman "{\"transcript_path\":\"$T/none.jsonl\"}" LANE_CLASS_NO_DB=1
# A known top-level thread id beats a lane-looking first message: the id is the evidence.
expect "uuid thread id outranks the first message" foreman "{\"session_id\":\"sess-env\",\"transcript_path\":\"$T/lane.jsonl\"}" T3CODE_THREAD_ID=11111111-1111-4111-8111-111111111111 LANE_CLASS_DB="$DB"

# --- 5. override, junk, and degraded inputs -----------------------------------
expect "override forces t3-lane" t3-lane '{"agent_id":""}' OPS_LANE_CLASS=t3-lane
expect "override forces foreman over an agent_id" foreman '{"agent_id":"a1"}' OPS_LANE_CLASS=foreman
expect "an unknown override value is ignored" agent-lane '{"agent_id":"a1"}' OPS_LANE_CLASS=bogus
expect "garbage payload" foreman 'not json at all {{{' LANE_CLASS_NO_DB=1
expect "empty payload" foreman '' LANE_CLASS_NO_DB=1
expect "a JSON array payload" foreman '[1,2]' LANE_CLASS_NO_DB=1
expect "non-string agent_id" foreman '{"agent_id":7,"session_id":"s"}' LANE_CLASS_NO_DB=1

# no stdin at all (a terminal-less caller with stdin closed)
out="$(env -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_LANE_CLASS HOME="$T/home" LANE_CLASS_NO_DB=1 "$BASH_BIN" "$LC" <&- 2>/dev/null)"; rc=$?
{ [ "$out" = foreman ] && [ "$rc" -eq 0 ]; } && ok "closed stdin -> foreman, exit 0" || bad "closed stdin: '$out' rc=$rc"

# an open pipe that never closes must not hang the hook past the bounded read
# (timed on the classifier alone: the writer is a background `sleep 2`)
t0="$(date +%s%N)"
( sleep 2 | env -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_LANE_CLASS HOME="$T/home" LANE_CLASS_NO_DB=1 \
    "$BASH_BIN" -c '"$1" >"$3" 2>/dev/null; date +%s%N >"$2"' x "$LC" "$T/hang.t1" "$T/hang.out" ) &
hang_pid=$!
for _ in $(seq 1 60); do [ -s "$T/hang.t1" ] && break; sleep 0.05; done
if [ -s "$T/hang.t1" ]; then
  ms=$(( ($(cat "$T/hang.t1") - t0) / 1000000 ))
  [ "$ms" -lt 1500 ] && [ "$(cat "$T/hang.out")" = foreman ] && ok "an open, silent stdin pipe is read for under 1.5 s (took ${ms} ms)" \
    || bad "open stdin pipe held the classifier ${ms} ms or answered '$(cat "$T/hang.out")'"
else
  bad "classifier did not return within 3 s on an open, silent stdin pipe"
fi
wait "$hang_pid" 2>/dev/null

# a corrupt db: foreman, exit 0, no output on stdout besides the verdict
printf 'this is not a sqlite file' > "$T/corrupt.sqlite"
expect "corrupt state db" foreman '{"session_id":"sess-delegated"}' LANE_CLASS_DB="$T/corrupt.sqlite"
expect "state db that does not exist" foreman '{"session_id":"sess-delegated"}' LANE_CLASS_DB="$T/nope.sqlite"
# a db without the tables
python3 -I -c "import sqlite3,sys; sqlite3.connect(sys.argv[1]).execute('create table x(y)').connection.commit()" "$T/empty.sqlite"
expect "state db without the projection tables" foreman '{"session_id":"sess-delegated"}' LANE_CLASS_DB="$T/empty.sqlite"

# no jq on PATH: the python fallback reads the payload. PATH holds only python3.
# The real interpreter, not a pyenv shim: a shim needs a full PATH to find its own tools.
REAL_PY="$(python3 -I -c 'import sys; print(sys.executable)')"
mkdir -p "$T/nojq"; ln -s "$REAL_PY" "$T/nojq/python3"
out="$(printf '%s' '{"agent_id":"a1"}' | env -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_LANE_CLASS PATH="$T/nojq" HOME="$T/home" "$BASH_BIN" "$LC" 2>/dev/null)"; rc=$?
{ [ "$out" = agent-lane ] && [ "$rc" -eq 0 ]; } && ok "no jq: python fallback reads agent_id" || bad "no jq fallback: '$out' rc=$rc"
out="$(printf '%s' '{"session_id":"sess-delegated"}' | env -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_LANE_CLASS PATH="$T/nojq" HOME="$T/home" LANE_CLASS_DB="$DB" "$BASH_BIN" "$LC" 2>/dev/null)"; rc=$?
{ [ "$out" = t3-lane ] && [ "$rc" -eq 0 ]; } && ok "no jq: session id still maps through the state db" || bad "no jq db path: '$out' rc=$rc"
# no python and no jq: nothing can be read, so the answer is the default
mkdir -p "$T/empty-path"
out="$(printf '%s' '{"session_id":"sess-delegated"}' | env -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_LANE_CLASS PATH="$T/empty-path" HOME="$T/home" LANE_CLASS_DB="$DB" "$BASH_BIN" "$LC" 2>/dev/null)"; rc=$?
{ [ "$out" = foreman ] && [ "$rc" -eq 0 ]; } && ok "no jq and no python: foreman, exit 0" || bad "no parser: '$out' rc=$rc"

# --- 6. the db is only read ---------------------------------------------------
[ "$DB_SUM_BEFORE" = "$(cksum < "$DB")" ] && [ "$DB_MT_BEFORE" = "$(stat -c %Y "$DB")" ] \
  && ok "the state db is unchanged after every lookup (read-only)" || bad "the state db changed"
ls "$T"/statev2.sqlite-* >/dev/null 2>&1 && bad "a journal or wal file appeared beside the db" || ok "no journal or wal file appeared beside the db"

# --- 7. speed: the contract is under 300 ms -----------------------------------
best() {  # best <env...>: fastest of three runs, in ms
  local _try t0 t1 b=99999 ms
  for _try in 1 2 3; do
    t0="$(date +%s%N)"
    printf '%s' "$PAYLOAD_T" | env -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_LANE_CLASS HOME="$T/home" "$@" "$BASH_BIN" "$LC" >/dev/null 2>&1
    t1="$(date +%s%N)"; ms=$(( (t1 - t0) / 1000000 )); [ "$ms" -lt "$b" ] && b="$ms"
  done
  printf '%s' "$b"
}
PAYLOAD_T='{"agent_id":"a1"}'; ms="$(best LANE_CLASS_NO_DB=1)"
[ "$ms" -lt 300 ] && ok "agent_id path ${ms} ms (< 300)" || bad "agent_id path took ${ms} ms"
PAYLOAD_T='{"session_id":"sess-env"}'; ms="$(best T3CODE_THREAD_ID=thread:delegated-task:x LANE_CLASS_NO_DB=1)"
[ "$ms" -lt 300 ] && ok "thread-id path ${ms} ms (< 300)" || bad "thread-id path took ${ms} ms"
PAYLOAD_T='{"session_id":"sess-delegated"}'; ms="$(best LANE_CLASS_DB="$DB")"
[ "$ms" -lt 300 ] && ok "state db path ${ms} ms (< 300)" || bad "state db path took ${ms} ms"

# --- 8. one real delegated session from the live read-only T3 db --------------
REAL_DB="${T3CODE_HOME:-$HOME/.t3}/userdata/statev2.sqlite"
if [ -f "$REAL_DB" ]; then
  # The newest delegated-task thread's native session id and the newest top-level
  # (bare uuid) thread's, both read-only. Either missing is a SKIP, not a pass.
  ids="$(python3 -I - "$REAL_DB" <<'PY' 2>/dev/null
import sqlite3, sys, urllib.parse
con = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(sys.argv[1]), uri=True, timeout=2)
con.execute("PRAGMA query_only=1")
def newest(where):
    r = con.execute("SELECT json_extract(pt.payload_json, '$.nativeThreadRef.nativeId') FROM orchestration_v2_projection_provider_threads pt "
                    "JOIN orchestration_v2_projection_threads t ON t.thread_id = pt.thread_id WHERE pt.owner_node_id IS NULL AND " + where +
                    " AND json_extract(pt.payload_json, '$.nativeThreadRef.nativeId') IS NOT NULL ORDER BY t.updated_at DESC LIMIT 1").fetchone()
    return r[0] if r else ""
print(newest("t.thread_id LIKE 'thread:delegated-task:%'"))
print(newest("t.thread_id NOT LIKE 'thread:%'"))
PY
)" || ids=""
  real_lane="$(printf '%s\n' "$ids" | sed -n 1p)"; real_top="$(printf '%s\n' "$ids" | sed -n 2p)"
  if [ -n "$real_lane" ]; then
    run_lc "{\"session_id\":\"$real_lane\"}" T3CODE_HOME="${T3CODE_HOME:-$HOME/.t3}" HOME="$HOME"
    { [ "$out" = t3-lane ] && [ "$rc" -eq 0 ]; } && ok "real delegated-task session (${real_lane:0:8}...) from the live T3 db -> t3-lane" \
      || bad "real delegated-task session classified '$out' (rc=$rc)" "$(cat "$T/err")"
  else
    echo "SKIP: the live T3 db holds no delegated-task session"
  fi
  if [ -n "$real_top" ]; then
    run_lc "{\"session_id\":\"$real_top\"}" T3CODE_HOME="${T3CODE_HOME:-$HOME/.t3}" HOME="$HOME"
    { [ "$out" = foreman ] && [ "$rc" -eq 0 ]; } && ok "real top-level session (${real_top:0:8}...) from the live T3 db -> foreman" \
      || bad "real top-level session classified '$out' (rc=$rc)"
  else
    echo "SKIP: the live T3 db holds no top-level session"
  fi
else
  echo "SKIP: no T3 db at $REAL_DB (not a T3 host, or run in the sandbox)"
fi

echo "lane-class-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
