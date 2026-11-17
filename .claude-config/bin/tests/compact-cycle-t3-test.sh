#!/usr/bin/env bash
# compact-cycle-t3-test.sh: behavior test for compact-cycle.sh --backend t3.
#
# Pin the real T3 contract: bare /compact triggers native compaction; appended
# arguments produce ordinary chat. Success requires a matching completion event,
# even when native compaction never sets activeTurnId. The local stub rejects
# false proof from ordinary replies, stale compactions and failed requests.
# Nothing touches a live T3 server. T3 is the only backend; the
# removed tmux/herdr/pane values must fail loud (exit 2) rather than compact some
# other way, and a bare call (no --backend) must run the T3 cycle.
#
# T3 0.1.0 (protocol 2): section 6 runs EVERY t3-api.sh exit code (parsed from its header)
# through every step against a fake t3-api.sh and pins the ERR_ line, the exit code, the status
# result, that no resume is sent and the baton is kept, and that nothing waits out a timeout.
# Section 7 runs the cycle end to end against the real t3-api.sh and lib/t3_ws.py on a stub that
# speaks protocol 2 (HTTP plus the /ws WebSocket, synthetic states in fixtures/t3-v2/write): a
# normal compaction, nothing-to-compact (a thread with no conversation: finished no-op, resume
# still sent), refusals, a session id target through statev2.sqlite, and a dead server.
#
# COMPLETED MEANS DONE (compact-cycle.sh): section 8 runs a compaction that completes
# while the thread is busy again (a thread with background work is woken seconds after its
# compaction), once against the fake t3-api.sh and once end to end against the protocol-2 stub, and
# pins that the resume baton is sent anyway, queued behind the active run. Every failure of the
# section 6 matrix must also log the raw status it saw (a `raw-status:` line), and a timeout or a
# thread that never went idle names the thread's state.
# Sandboxed, without a network: sections 7 and 8 run the real t3-api.sh, which dispatches
# turns into and settles threads on a real T3 server, so the suite refuses to run (exit 97)
# outside sandbox-run (the guard below) and with any route off the sandbox's own loopback
# (the check after it). OPS CI runs every suite as sandbox-run --no-net, and verify-ops.sh
# lists this one in OPS_SANDBOX_SUITES. Run it by hand the same way:
#   .claude-config/bin/sandbox-run --no-bind --no-net --ro-bind "$PWD" -- bash .claude-config/bin/tests/compact-cycle-t3-test.sh
#
# Exit 0 = all pass. Any failure exits 1 and prints the offending case.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
set -uo pipefail
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../compact-cycle.sh"
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

# No route to a live T3 server. The sandbox guard proves the mount sandbox, not a
# fresh network namespace (sandbox-run without --no-net shares the host's), so:
# the only interface must be loopback, checked first so nothing here opens a
# socket on a shared network, and then 127.0.0.1:3773, T3 Code's default port,
# must refuse, since in a fresh namespace nothing listens there.
python3 -I - <<'PY' || exit 97
import socket, sys
REFUSE = "refusing to run with a route to a live T3 server"
try:
    with open("/proc/net/dev", encoding="ascii", errors="replace") as f:
        ifaces = sorted(l.split(":", 1)[0].strip() for l in f.read().splitlines()[2:] if ":" in l)
except OSError as e:
    sys.exit("%s: cannot read /proc/net/dev (%s)" % (REFUSE, e))
if ifaces != ["lo"]:
    sys.exit("%s: interfaces %s, not loopback only; run it through sandbox-run --no-net"
             % (REFUSE, " ".join(ifaces) or "none"))
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect(("127.0.0.1", 3773))
except ConnectionRefusedError:
    pass
except OSError as e:
    sys.exit("%s: 127.0.0.1:3773 did not refuse (%s: %s)" % (REFUSE, type(e).__name__, e))
else:
    sys.exit("%s: something accepted a connection on 127.0.0.1:3773" % REFUSE)
finally:
    s.close()
PY
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); }
faild() { FAIL=$((FAIL+1)); echo "FAIL: $1"; [ $# -gt 1 ] && echo "  $2"; }

TMP="$(mktemp -d)"
STUB_PID=""
cleanup() { [ -n "$STUB_PID" ] && kill "$STUB_PID" >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT

TOKENF="$TMP/token"; printf '%s' "SENTINEL_T3_TOKEN_cc" > "$TOKENF"; chmod 600 "$TOKENF"
TARGET_THREAD="11111111-1111-1111-1111-111111111111"

# --- stub HTTP server ----------------------------------------------------------
# Initially busy, then idle. A normal turn re-arms the busy window; a bare compact
# instead emits request-correlated evidence without creating an active turn.
# Modes exercise absent proof, provider errors and a starting provider with no
# active turn. Dispatches are logged so each case checks ordering and count.
cat > "$TMP/stub.py" <<'PY'
import json, os, sys, http.server
LOG, PORTF = sys.argv[1], sys.argv[2]
INIT_BUSY = int(os.environ.get("STUB_INIT_BUSY", "4"))
TURN_BUSY = int(os.environ.get("STUB_TURN_BUSY", "3"))
TARGET = os.environ["STUB_TARGET_THREAD"]
state = {"busy": INIT_BUSY, "activities": [], "compact_id": None}
MODE = os.environ.get("STUB_MODE", "native")

def snapshot():
    hold = os.environ.get("STUB_HOLD_FILE")
    if hold and os.path.exists(hold):
        atid = "turn-run"
    elif state["busy"] > 0:
        atid = "turn-run"; state["busy"] -= 1
    else:
        atid = None
    def sess(tid, active):
        return {"threadId": tid, "status": "starting" if MODE == "starting" else ("running" if active else "idle"),
                "providerName": "claudeAgent", "providerInstanceId": "claudeAgent",
                "runtimeMode": "full-access", "activeTurnId": active,
                "lastError": None, "updatedAt": "2026-09-05T00:00:00.000Z"}
    return {"snapshotSequence": 1,
            "projects": [{"id": "p1", "title": "P1", "workspaceRoot": "/tmp", "defaultModelSelection": {}}],
            "threads": [
                {"id": TARGET, "title": "T", "projectId": "p1", "session": sess(TARGET, atid)},
                {"id": "other", "title": "O", "projectId": "p1", "session": sess("other", None)},
            ],
            "updatedAt": "2026-09-05T00:00:00.000Z"}

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith("/api/orchestration/snapshot"):
            self._send(snapshot())
        elif self.path.startswith("/api/orchestration/threads/"):
            mid = state["compact_id"]
            activities = [{"kind": "context-compaction", "payload": {"state": "compacted", "requestId": "old-request"}}]
            if mid and MODE != "no-evidence":
                if MODE == "error":
                    activities.append({"kind": "provider.turn.start.failed", "tone": "error", "payload": {"requestId": mid, "detail": "compact failed"}})
                else:
                    activities.append({"kind": "context-compaction", "payload": {"state": "compacted", "requestId": mid}})
            self._send({"page": {}, "snapshotSequence": 1, "thread": {"id": TARGET, "activities": activities}})
        else:
            self._send({"error": "not found"}, 404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode() if n else ""
        if self.path.startswith("/api/orchestration/dispatch"):
            with open(LOG, "a") as f:
                f.write(body + "\n")
            try:
                if json.loads(body).get("type") == "thread.turn.start":
                    cmd = json.loads(body)
                    if cmd.get("message", {}).get("text") == "/compact":
                        state["compact_id"] = cmd["message"]["messageId"]
                        # Native compaction can finish without an activeTurnId.
                        state["busy"] = 0
                    else:
                        state["busy"] = TURN_BUSY
            except Exception:
                pass
            self._send({"sequence": 1})
        else:
            self._send({"error": "not found"}, 404)

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(PORTF, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PY

start_stub() {  # $1 = dispatch-log path -> exports OPS_T3_BASE, sets STUB_PID
  local disp="$1" portf="$TMP/port.$$.$RANDOM"
  : > "$disp"
  STUB_TARGET_THREAD="$TARGET_THREAD" python3 "$TMP/stub.py" "$disp" "$portf" &
  STUB_PID=$!
  local i
  for i in $(seq 1 50); do [ -s "$portf" ] && break; sleep 0.1; done
  [ -s "$portf" ] || { echo "stub failed to start" >&2; return 1; }
  export OPS_T3_BASE="http://127.0.0.1:$(cat "$portf")"
}
stop_stub() { [ -n "$STUB_PID" ] && kill "$STUB_PID" >/dev/null 2>&1; STUB_PID=""; }

export OPS_T3_TOKEN_FILE="$TOKENF"
export CC_CYCLE_RUNDIR="$TMP/rundir"; mkdir -p "$CC_CYCLE_RUNDIR"
# Shrink the t3 cadence so the cycle runs in ~seconds; keep the completion confirm
# at its default (2) so the busy->idle wait is genuinely exercised.
export T3_POLL="0.25" T3_CONFIRM="2"

# --timeout 15, not 2: this helper serves only the two SUCCESS cases. compact-cycle.sh
# computes its compaction deadline on a whole-second clock (date +%s), so --timeout 2
# leaves 1 to 2 s for a status call plus two 0.25 s polls; a loaded box (the gate
# running every suite) lost that race and the worker timed out before it could see
# "completed". The loop exits the moment it succeeds, so a quiet box pays nothing. The
# failure cases below keep their short --timeout on purpose: they must still reach the
# timeout path quickly.
run_worker() {  # extra args... -> runs the t3 worker inline; STATUS/LOG under CC_CYCLE_RUNDIR
  "$SCRIPT" --worker --backend t3 --target "$TARGET_THREAD" \
    --grace 0 --idle-timeout 20 --timeout 15 "$@" >/dev/null 2>&1
}

status_result() { sed -n 's/.*result=\([^ ]*\).*/\1/p' "$CC_CYCLE_RUNDIR"/*.status 2>/dev/null | tail -1; }

# =============================================================================
# 1. Native success: bare /compact, correlated event, then resume; no active turn.
# =============================================================================
DISP1="$TMP/dispatch1.jsonl"
start_stub "$DISP1" || exit 1
BATON_OK="$TMP/resume-success.txt"; printf '%s\n' "RESUME_SENTINEL_TEXT" > "$BATON_OK"
run_worker --baton "$BATON_OK"; RC=$?
stop_stub

[ "$RC" -eq 0 ] && pass || faild "happy-path worker should exit 0, got $RC"
[ ! -f "$BATON_OK" ] && compgen -G "$BATON_OK.sent-*" >/dev/null \
  && pass || faild "successful resume must consume baton"

RES="$(status_result)"
[ "$RES" = "ok" ] && pass || faild "STATUS result should be ok, got '$RES'"

python3 - "$DISP1" <<'PY'
import json, sys
bodies = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(bodies) == 2, "expected 2 dispatches, got %d" % len(bodies)
t0 = bodies[0]["message"]["text"]
t1 = bodies[1]["message"]["text"]
errs = []
if bodies[0]["type"] != "thread.turn.start": errs.append("dispatch 0 not thread.turn.start")
if t0 != "/compact": errs.append("dispatch 0 text is not a /compact: %r" % t0[:40])

if t1 != "RESUME_SENTINEL_TEXT": errs.append("dispatch 1 is not the resume text: %r" % t1)
if errs:
    sys.stderr.write("\n".join(errs) + "\n"); sys.exit(1)
PY
[ $? -eq 0 ] && pass || faild "dispatch order/content wrong (see above)"

# =============================================================================
# 2. --no-resume: exactly one dispatch (the /compact), result ok-no-resume.
# =============================================================================
DISP2="$TMP/dispatch2.jsonl"
start_stub "$DISP2" || exit 1
BATON_KEEP="$TMP/resume-no-resume.txt"; printf '%s\n' "KEEP" > "$BATON_KEEP"
run_worker --baton "$BATON_KEEP" --no-resume; RC=$?
stop_stub

[ "$RC" -eq 0 ] && pass || faild "no-resume worker should exit 0, got $RC"
[ -f "$BATON_KEEP" ] && pass || faild "no-resume must retain baton"

RES="$(status_result)"
[ "$RES" = "ok-no-resume" ] && pass || faild "STATUS result should be ok-no-resume, got '$RES'"

N="$(grep -c . "$DISP2" 2>/dev/null || echo 0)"
[ "$N" -eq 1 ] && pass || faild "--no-resume should yield exactly 1 dispatch, got $N"

python3 - "$DISP2" <<'PY'
import json, sys
bodies = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert bodies, "no dispatch recorded"
t0 = bodies[0]["message"]["text"]
if not (bodies[0]["type"] == "thread.turn.start" and t0 == "/compact"):
    sys.stderr.write("no-resume single dispatch is not the /compact turn: %r\n" % t0[:40]); sys.exit(1)
PY
[ $? -eq 0 ] && pass || faild "no-resume dispatch is not the /compact turn (see above)"

# =============================================================================
# 3. Never idle: refuse to dispatch /compact into a busy thread (result busy, 0 dispatch).
#    Guards the MAJOR where a queued /compact + the gap before it starts was read
#    as completion and fired the resume early. If the thread never confirms idle,
#    the worker must abort untouched.
# =============================================================================
DISP3="$TMP/dispatch3.jsonl"
STUB_INIT_BUSY=1000000 start_stub "$DISP3" || exit 1
"$SCRIPT" --worker --backend t3 --target "$TARGET_THREAD" \
  --grace 0 --idle-timeout 2 --timeout 5 >/dev/null 2>&1; RC=$?
stop_stub
[ "$RC" -eq 5 ] && pass || faild "never-idle worker should exit 5, got $RC"
RES="$(status_result)"
[ "$RES" = "busy" ] && pass || faild "never-idle result should be 'busy', got '$RES'"
N="$(grep -c . "$DISP3" 2>/dev/null)" || N=0
[ "$N" -eq 0 ] && pass || faild "never-idle must dispatch nothing, got $N"

# Idle/normal replies and old compactions never prove this request completed.
for mode in no-evidence error starting; do
  disp="$TMP/dispatch-$mode.jsonl"
  STUB_MODE="$mode" start_stub "$disp" || exit 1
  failed_baton="$TMP/resume-$mode.txt"; printf '%s\n' "MUST_NOT_RESUME" > "$failed_baton"
  # idle-timeout 20, not 2: these modes test the evidence phase, and the stub is
  # idle from the first poll, so the wait costs nothing when the box is quiet. At 2s
  # a loaded box (the gate running every suite) starved the idle check and
  # the worker aborted busy with 0 dispatches, a flake seen twice.
  "$SCRIPT" --worker --backend t3 --target "$TARGET_THREAD" \
    --grace 0 --idle-timeout 20 --timeout 2 --baton "$failed_baton" >/dev/null 2>&1; RC=$?
  stop_stub
  [ "$RC" -eq 5 ] && pass || faild "$mode must fail, got $RC"
  N="$(wc -l < "$disp")"
  expected=1; [ "$mode" = "starting" ] && expected=0
  [ "$N" -eq "$expected" ] && pass || faild "$mode expected $expected dispatches, got $N"
  [ -f "$failed_baton" ] && pass || faild "$mode must retain baton"
done

# =============================================================================
# 4. T3 is the default: no --backend runs the same native cycle, via the SPAWNER
#    (detached setsid worker), not just --worker. Omit --baton as well so the
#    thread-keyed default file, lock and status contract is exercised end to end.
# =============================================================================
DISP4="$TMP/dispatch4.jsonl"
rm -f "$CC_CYCLE_RUNDIR"/*.status
HOLD4="$TMP/hold-spawn"; : > "$HOLD4"
STUB_HOLD_FILE="$HOLD4" start_stub "$DISP4" || exit 1
BATON_SP="$CC_CYCLE_RUNDIR/resume-$TARGET_THREAD.txt"; printf '%s\n' "SPAWN_RESUME_TEXT" > "$BATON_SP"
SPOUT="$("$SCRIPT" --target "$TARGET_THREAD" --grace 0 --idle-timeout 20 --timeout 5 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && pass || faild "spawner should exit 0, got $RC" "$SPOUT"
case "$SPOUT" in *"OK compactor spawned"*"backend=t3"*) pass ;; *) faild "spawner status line missing backend=t3" "$SPOUT" ;; esac
for i in $(seq 1 40); do [ -d "$CC_CYCLE_RUNDIR/$TARGET_THREAD.lock" ] && break; sleep 0.05; done
[ -d "$CC_CYCLE_RUNDIR/$TARGET_THREAD.lock" ] && pass || faild "spawned worker must hold the target's lock"
"$SCRIPT" --target "$TARGET_THREAD" --grace 0 >/dev/null 2>&1; RC=$?
[ "$RC" -eq 4 ] && pass || faild "second spawn for locked thread must exit 4, got $RC"
rm -f "$HOLD4"
for i in $(seq 1 120); do [ "$(status_result)" = "ok" ] && break; sleep 0.25; done
stop_stub
RES="$(status_result)"
[ "$RES" = "ok" ] && pass || faild "default-backend spawned cycle should end ok, got '$RES'"
[ -f "$CC_CYCLE_RUNDIR/$TARGET_THREAD.status" ] && pass || faild "spawned cycle must write the target's status"
[ ! -f "$BATON_SP" ] && pass || faild "default-backend spawned cycle must consume baton"
N="$(grep -c . "$DISP4" 2>/dev/null)" || N=0
[ "$N" -eq 2 ] && pass || faild "default-backend spawned cycle expected 2 dispatches, got $N"
python3 - "$DISP4" "$TARGET_THREAD" <<'PY'
import json, sys
bodies = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
assert [body["threadId"] for body in bodies] == [sys.argv[2]] * 2, bodies
assert [body["message"]["text"] for body in bodies] == ["/compact", "SPAWN_RESUME_TEXT"], bodies
PY
[ $? -eq 0 ] && pass || faild "spawned cycle must resume the target with its default baton"

# =============================================================================
# 5. Removed backends fail loud: exit 2, a message naming the removal, and no
#    dispatch and no status write (nothing was attempted).
# =============================================================================
for be in tmux herdr pane; do
  disp="$TMP/dispatch-removed-$be.jsonl"
  rm -f "$CC_CYCLE_RUNDIR"/*.status
  start_stub "$disp" || exit 1
  OUT="$("$SCRIPT" --worker --backend "$be" --target "$TARGET_THREAD" --grace 0 2>&1)"; RC=$?
  stop_stub
  [ "$RC" -eq 2 ] && pass || faild "--backend $be should exit 2, got $RC"
  case "$OUT" in *"was removed"*) pass ;; *) faild "--backend $be message should name the removal" "$OUT" ;; esac
  N="$(grep -c . "$disp" 2>/dev/null)" || N=0
  [ "$N" -eq 0 ] && pass || faild "--backend $be must dispatch nothing, got $N"
  [ -z "$(status_result)" ] && pass || faild "--backend $be must write no status"
done

# =============================================================================
# 6. EVERY t3-api.sh EXIT CODE, at every step. t3-api.sh exits with codes 2 to 12
#    and the worker used to fold them: a dead server read as a missing thread (ERR_TARGET), a
#    refused resume lost its code, and an answer the loop did not know polled to --timeout. A fake
#    t3-api.sh (the T3_API seam) fails exactly one step with one code. The list of codes is parsed
#    from t3-api.sh's own EXIT CODES header, so a code added there is run through every step here
#    and fails until compact-cycle.sh has a phrase for it. Each run must end fast (no hang), name
#    the code, send no resume, keep the baton, and leave the status file saying why.
# =============================================================================
T3_HEADER="$HERE/../t3-api.sh"
DOC_CODES="$(python3 - "$T3_HEADER" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if l.startswith("# EXIT CODES:"))
block = []
for l in lines[start:]:
    if not l.startswith("#"):
        break
    if block and not l.startswith("#   "):
        break
    block.append(l.lstrip("# ").strip())
text = " ".join(block)[len("EXIT CODES:"):].strip()
codes = []
for seg in text.split(" | "):
    m = re.match(r"(\d+)\b", seg.strip())
    if m:
        codes.append(int(m.group(1)))
print(" ".join(str(c) for c in codes))
PY
)"
# The documented list must include every code this suite knows (a header that stopped parsing would
# otherwise run an empty matrix and pass). Codes added to the header later are run too.
for c in 0 2 3 4 5 6 7 8 9 10 11 12; do
  case " $DOC_CODES " in
    *" $c "*) pass ;;
    *) faild "c6 the documented t3-api.sh exit codes must include $c" "parsed: [$DOC_CODES]" ;;
  esac
done
FAIL_CODES="$(for c in $DOC_CODES; do [ "$c" -ne 0 ] && printf '%s ' "$c"; done) 99"   # 99: an undocumented code

FAKE="$TMP/fake-t3-api.sh"
cat > "$FAKE" <<'FAKEEOF'
#!/usr/bin/env bash
# fake t3-api.sh: one subcommand fails with FAKE_RC_<sub> (dashes as underscores), optionally only from
# its Nth call on (FAKE_FROM_<sub>=N) and only through call M (FAKE_UNTIL_<sub>=M); everything else succeeds on an idle, healthy thread.
sub="${1:-}"; shift || true
printf '%s %s\n' "$sub" "$*" >> "$FAKE_LOG"
v="$(printf '%s' "$sub" | tr '-' '_')"
n=$(( $(cat "$FAKE_DIR/n.$v" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$FAKE_DIR/n.$v"
rcv="FAKE_RC_$v"; fromv="FAKE_FROM_$v"; untilv="FAKE_UNTIL_$v"
rc="${!rcv:-0}"; from="${!fromv:-1}"; until="${!untilv:-0}"
if [ "$rc" != 0 ] && [ "$n" -ge "$from" ] && { [ "$until" = 0 ] || [ "$n" -le "$until" ]; }; then echo "fake t3-api: $sub failing with $rc" >&2; exit "$rc"; fi
# FAKE_BUSY_AFTER_COMPACT=1: once `compact` was called the thread reads running with a background
# run (the thread a finished background task woke). FAKE_EVIDENCE_SEQ="a b c": the compact-status
# answers by call number, the last one repeating (pending, pending, completed).
case "$sub" in
  active-turn)        echo null ;;
  thread-for-session) echo "$FAKE_THREAD" ;;
  snapshot)
    if [ -n "${FAKE_BUSY_AFTER_COMPACT:-}" ] && [ -e "$FAKE_DIR/compacted" ]; then
      printf '{"threads":[{"id":"%s","session":{"status":"running","activeTurnId":"turn-background-1","lastError":null}}]}\n' "$FAKE_THREAD"
    else
      printf '{"threads":[{"id":"%s","session":{"status":"idle","activeTurnId":null,"lastError":null}}]}\n' "$FAKE_THREAD"
    fi ;;
  compact)            : > "$FAKE_DIR/compacted"; echo fake-message-id ;;
  compact-status)
    if [ -n "${FAKE_EVIDENCE_SEQ:-}" ]; then
      set -- $FAKE_EVIDENCE_SEQ; i=$n; [ "$i" -gt "$#" ] && i=$#; shift $((i - 1)); echo "$1"
    else echo "${FAKE_EVIDENCE:-completed}"; fi ;;
  send)               printf '%s\n' "$*" >> "$FAKE_SENDS"; echo '{"sequence":1}' ;;
  *) echo "fake t3-api: unhandled $sub" >&2; exit 2 ;;
esac
FAKEEOF
chmod +x "$FAKE"

MXN=0
# mx_run <step> <code> [evidence]: one worker run with <step> failing with <code>. Sets MX_RC, MX_LOG,
# MX_STATUS, MX_SENDS (resume messages sent), MX_BATON (path of the baton, which must survive).
mx_run() {
  local step="$1" code="$2" ev="${3:-}" rd t0
  MXN=$((MXN+1)); rd="$TMP/mx/$MXN"; mkdir -p "$rd"
  : > "$rd/fake.log"; : > "$rd/sends.log"; MX_BATON="$rd/baton.txt"; printf '%s\n' "MX_RESUME_TEXT" > "$MX_BATON"
  local -a fe=( FAKE_LOG="$rd/fake.log" FAKE_DIR="$rd" FAKE_SENDS="$rd/sends.log" FAKE_THREAD="$TARGET_THREAD" )
  case "$step" in
    resolve)         fe+=( FAKE_RC_active_turn="$code" ) ;;
    resolve-session) fe+=( FAKE_RC_active_turn=5 FAKE_RC_thread_for_session="$code" ) ;;
    session)         fe+=( FAKE_RC_snapshot="$code" ) ;;
    idle)            fe+=( FAKE_RC_snapshot="$code" FAKE_FROM_snapshot=2 ) ;;
    after)           fe+=( FAKE_RC_snapshot="$code" FAKE_FROM_snapshot=4 ) ;;   # 1 session read, 2 idle polls, 4 = the first poll after compaction
    compact)         fe+=( FAKE_RC_compact="$code" ) ;;
    status)          fe+=( FAKE_RC_compact_status="$code" ) ;;
    send)            fe+=( FAKE_RC_send="$code" ) ;;
    evidence)        fe+=( FAKE_EVIDENCE="$ev" ) ;;
    busyafter)       fe+=( FAKE_BUSY_AFTER_COMPACT=1 ) ;;
    busyafter-seq)   fe+=( FAKE_BUSY_AFTER_COMPACT=1 FAKE_EVIDENCE_SEQ="pending pending completed" ) ;;
    busyafter-noop)  fe+=( FAKE_BUSY_AFTER_COMPACT=1 FAKE_EVIDENCE=nothing-to-compact ) ;;
  esac
  t0=$SECONDS
  env "${fe[@]}" T3_API="$FAKE" T3_POLL=0.02 T3_CONFIRM=2 CC_CYCLE_RUNDIR="$rd" \
    timeout 60 "$SCRIPT" --worker --target "$TARGET_THREAD" --grace 0 --idle-timeout 20 --timeout 30 --baton "$MX_BATON" >/dev/null 2>&1
  MX_RC=$?; MX_ELAPSED=$((SECONDS - t0))
  MX_LOG="$(cat "$rd"/*.log 2>/dev/null)"
  MX_STATUS="$(sed -n 's/.*result=\([^ ]*\).*/\1/p' "$rd"/*.status 2>/dev/null | tail -1)"
  MX_SENDS="$(grep -c . "$rd/sends.log")"
}
# mx_expect <step> <code> <exit> <ERR_ prefix> <status result>: the run's outcome.
mx_expect() {
  local step="$1" code="$2" want_rc="$3" want_err="$4" want_status="$5" who="c6 $1 code $2"
  mx_run "$step" "$code"
  [ "$MX_RC" -eq "$want_rc" ] && pass || faild "$who: worker exit should be $want_rc, got $MX_RC (124 means it hung)" "$MX_LOG"
  grep -q "$want_err: .*t3-api.sh exit $code (" <<< "$MX_LOG" && pass || faild "$who: expected an $want_err line naming 't3-api.sh exit $code ('" "$MX_LOG"
  [ "$code" -ne 99 ] && { grep -q "t3-api.sh exit $code (an exit code t3-api.sh does not document)" <<< "$MX_LOG" && faild "$who: a documented code must have its own phrase, not the fallback" "$MX_LOG" || pass; }
  [ "$code" -eq 99 ] && { grep -q "t3-api.sh exit 99 (an exit code t3-api.sh does not document)" <<< "$MX_LOG" && pass || faild "$who: an undocumented code must say so" "$MX_LOG"; }
  [ "$MX_STATUS" = "$want_status" ] && pass || faild "$who: status result should be '$want_status', got '$MX_STATUS'" "$MX_LOG"
  [ "$MX_SENDS" -eq 0 ] && pass || faild "$who: no resume may be sent after this failure, got $MX_SENDS" "$MX_LOG"
  [ -f "$MX_BATON" ] && pass || faild "$who: the baton must be kept"
  [ "$MX_ELAPSED" -le 20 ] && pass || faild "$who: took ${MX_ELAPSED}s, it must not wait out a timeout" "$MX_LOG"
  grep -q "raw-status: compact-status=[^ ]* messageId=[^;]*; last thread read: " <<< "$MX_LOG" && pass || faild "$who: the failure log must carry the raw status it saw (a raw-status: line)" "$MX_LOG"
}
for code in $FAIL_CODES; do
  # Reads before anything is sent: not found is a missing target (exit 3), everything else a T3 API error (exit 6).
  for step in resolve session idle; do
    if [ "$code" -eq 5 ]; then
      [ "$step" = resolve ] && continue    # resolve with 5 falls through to thread-for-session; covered by resolve-session
      mx_expect "$step" "$code" 3 ERR_TARGET gone
    else
      mx_expect "$step" "$code" 6 ERR_T3API t3-api-error
    fi
  done
  if [ "$code" -eq 5 ]; then mx_expect resolve-session "$code" 3 ERR_TARGET gone
  else mx_expect resolve "$code" 6 ERR_T3API t3-api-error; mx_expect resolve-session "$code" 6 ERR_T3API t3-api-error; fi
  # The two writes and the status read: always ERR_DISPATCH or ERR_COMPACT, exit 5.
  mx_expect compact "$code" 5 ERR_DISPATCH compact-error
  mx_expect status "$code" 5 ERR_COMPACT compact-error
  mx_expect send "$code" 5 ERR_DISPATCH compact-error
done
# Code 4 on a write names the unknown outcome; the read after compaction maps like the reads before it.
mx_run compact 4
grep -q "the outcome is UNKNOWN" <<< "$MX_LOG" && pass || faild "c6 a lost compact request (code 4) must say the outcome is unknown" "$MX_LOG"
mx_run send 4
grep -q "the outcome is UNKNOWN" <<< "$MX_LOG" && pass || faild "c6 a lost resume (code 4) must say the outcome is unknown" "$MX_LOG"
mx_run compact 11
grep -q "the outcome is UNKNOWN" <<< "$MX_LOG" && faild "c6 a server refusal (code 11) is a known outcome" "$MX_LOG" || pass
for code in $FAIL_CODES; do
  if [ "$code" -eq 5 ]; then mx_expect after "$code" 3 ERR_TARGET gone; else mx_expect after "$code" 6 ERR_T3API t3-api-error; fi
done
# A refused resume is not recorded as sent: the fake's send log stays empty (checked above), and the
# status says compact-error, never ok.
# A transport blip (code 4) on the status read is retried: two failures then a good read, the cycle completes
# and the resume goes out once. A persistent outage is retried three times and then ends ERR_COMPACT (5).
rd="$TMP/mx/retry"; mkdir -p "$rd"; : > "$rd/fake.log"; : > "$rd/sends.log"; printf 'RETRY_RESUME\n' > "$rd/baton.txt"
env FAKE_LOG="$rd/fake.log" FAKE_DIR="$rd" FAKE_SENDS="$rd/sends.log" FAKE_THREAD="$TARGET_THREAD" FAKE_RC_compact_status=4 FAKE_UNTIL_compact_status=2 \
  T3_API="$FAKE" T3_POLL=0.02 CC_CYCLE_RUNDIR="$rd" timeout 60 "$SCRIPT" --worker --target "$TARGET_THREAD" --grace 0 --idle-timeout 20 --timeout 30 --baton "$rd/baton.txt" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(grep -c . "$rd/sends.log")" -eq 1 ] && [ "$(grep -c '^compact-status' "$rd/fake.log")" -ge 3 ] \
  && pass || faild "c6 two transport blips on the status read must be retried and the cycle must complete (rc=$RC)" "$(cat "$rd/fake.log")"
rd="$TMP/mx/retry2"; mkdir -p "$rd"; : > "$rd/fake.log"; : > "$rd/sends.log"; printf 'RETRY_RESUME\n' > "$rd/baton.txt"
env FAKE_LOG="$rd/fake.log" FAKE_DIR="$rd" FAKE_SENDS="$rd/sends.log" FAKE_THREAD="$TARGET_THREAD" FAKE_RC_compact_status=4 \
  T3_API="$FAKE" T3_POLL=0.02 CC_CYCLE_RUNDIR="$rd" timeout 60 "$SCRIPT" --worker --target "$TARGET_THREAD" --grace 0 --idle-timeout 20 --timeout 30 --baton "$rd/baton.txt" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 5 ] && pass || faild "c6 a persistent transport failure on the status read must end ERR_COMPACT (5), got $RC"
[ "$(grep -c '^compact-status' "$rd/fake.log")" -eq 3 ] && pass || faild "c6 a failing status read must be tried exactly three times, no more" "$(cat "$rd/fake.log")"

# An answer the worker does not know ends ERR_COMPACT at once (it used to poll to --timeout).
mx_run evidence 0 "something-new"
[ "$MX_RC" -eq 5 ] && grep -q "ERR_COMPACT: compact-status answered 'something-new'" <<< "$MX_LOG" && [ "$MX_ELAPSED" -le 20 ] \
  && pass || faild "c6 an unknown compact-status answer must be ERR_COMPACT immediately, got rc=$MX_RC after ${MX_ELAPSED}s" "$MX_LOG"
[ "$MX_SENDS" -eq 0 ] && [ -f "$MX_BATON" ] && pass || faild "c6 an unknown compact-status answer must send no resume and keep the baton"
# nothing-to-compact from the fake: finished no-op, resume still sent, status ok-nothing-to-compact. The fake's thread
# carries no lastError, which is fine (the expected refusal text is only tolerated, never required).
mx_run evidence 0 "nothing-to-compact"
[ "$MX_RC" -eq 0 ] && [ "$MX_STATUS" = "ok-nothing-to-compact" ] && [ "$MX_SENDS" -eq 1 ] && [ ! -f "$MX_BATON" ] \
  && pass || faild "c6 nothing-to-compact must finish ok-nothing-to-compact, send the resume once and consume the baton (rc=$MX_RC status=$MX_STATUS sends=$MX_SENDS)" "$MX_LOG"
grep -q "nothing to compact: T3 says the thread has no conversation yet" <<< "$MX_LOG" && pass || faild "c6 nothing-to-compact must say so in the log" "$MX_LOG"
# pending is still pending: it polls until the timeout and ends ERR_TIMEOUT (the contract the old code had for it).
rd="$TMP/mx/pending"; mkdir -p "$rd"; : > "$rd/fake.log"; : > "$rd/sends.log"; printf 'P\n' > "$rd/baton.txt"
env FAKE_LOG="$rd/fake.log" FAKE_DIR="$rd" FAKE_SENDS="$rd/sends.log" FAKE_THREAD="$TARGET_THREAD" FAKE_EVIDENCE=pending \
  T3_API="$FAKE" T3_POLL=0.05 CC_CYCLE_RUNDIR="$rd" timeout 60 "$SCRIPT" --worker --target "$TARGET_THREAD" --grace 0 --idle-timeout 20 --timeout 2 --baton "$rd/baton.txt" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 5 ] && grep -qh "ERR_TIMEOUT" "$rd"/*.log && [ ! -s "$rd/sends.log" ] && pass || faild "c6 a request that stays pending must end ERR_TIMEOUT with no resume, got $RC"
# nothing-to-compact with a lastError that is NOT the expected refusal still blocks the resume.
cat > "$TMP/fake-err-snapshot.sh" <<'EOF2'
#!/usr/bin/env bash
if [ "${1:-}" = snapshot ]; then
  printf '{"threads":[{"id":"%s","session":{"status":"error","activeTurnId":null,"lastError":"%s"}}]}\n' "$FAKE_THREAD" "$FAKE_LASTERR"; exit 0
fi
exec "$FAKE_REAL" "$@"
EOF2
chmod +x "$TMP/fake-err-snapshot.sh"
rd="$TMP/mx/errtext"; mkdir -p "$rd"; : > "$rd/fake.log"; : > "$rd/sends.log"; printf 'E\n' > "$rd/baton.txt"
env FAKE_LOG="$rd/fake.log" FAKE_DIR="$rd" FAKE_SENDS="$rd/sends.log" FAKE_THREAD="$TARGET_THREAD" FAKE_EVIDENCE=nothing-to-compact FAKE_REAL="$FAKE" \
  FAKE_LASTERR="Claude could not authenticate" T3_API="$TMP/fake-err-snapshot.sh" T3_POLL=0.02 CC_CYCLE_RUNDIR="$rd" \
  timeout 60 "$SCRIPT" --worker --target "$TARGET_THREAD" --grace 0 --idle-timeout 20 --timeout 5 --baton "$rd/baton.txt" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 5 ] && grep -qh "ERR_COMPACT: session error after compaction" "$rd"/*.log && [ ! -s "$rd/sends.log" ] \
  && pass || faild "c6 nothing-to-compact on a thread with a DIFFERENT lastError must not send the resume, got $RC"
env FAKE_LOG="$rd/fake.log" FAKE_DIR="$rd" FAKE_SENDS="$rd/sends.log" FAKE_THREAD="$TARGET_THREAD" FAKE_EVIDENCE=nothing-to-compact FAKE_REAL="$FAKE" \
  FAKE_LASTERR="Start a conversation before compacting this thread." T3_API="$TMP/fake-err-snapshot.sh" T3_POLL=0.02 CC_CYCLE_RUNDIR="$TMP/mx/errtext2" \
  timeout 60 "$SCRIPT" --worker --target "$TARGET_THREAD" --grace 0 --idle-timeout 20 --timeout 5 --baton "$rd/baton.txt" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(grep -c . "$rd/sends.log")" -eq 1 ] && pass || faild "c6 nothing-to-compact with the expected refusal as lastError must send the resume, got $RC"
# A COMPLETED compaction followed by a session error also sends nothing (the thread read after the
# proof exists for exactly this), and the ERR line names the error text.
rd="$TMP/mx/errcompleted"; mkdir -p "$rd"; : > "$rd/fake.log"; : > "$rd/sends.log"; printf 'E\n' > "$rd/baton.txt"
env FAKE_LOG="$rd/fake.log" FAKE_DIR="$rd" FAKE_SENDS="$rd/sends.log" FAKE_THREAD="$TARGET_THREAD" FAKE_EVIDENCE=completed FAKE_REAL="$FAKE" \
  FAKE_LASTERR="Claude could not authenticate" T3_API="$TMP/fake-err-snapshot.sh" T3_POLL=0.02 CC_CYCLE_RUNDIR="$rd" \
  timeout 60 "$SCRIPT" --worker --target "$TARGET_THREAD" --grace 0 --idle-timeout 20 --timeout 5 --baton "$rd/baton.txt" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 5 ] && grep -qh "ERR_COMPACT: session error after compaction (lastError: Claude could not authenticate); no resume" "$rd"/*.log && [ ! -s "$rd/sends.log" ] && [ -f "$rd/baton.txt" ] \
  && pass || faild "c6 a completed compaction followed by a session error must not send the resume and must name the error, got $RC" "$(cat "$rd"/*.log 2>/dev/null)"
# The spawner reports the same classes: not found is exit 3, a dead server exit 6, both before anything spawns.
rd="$TMP/mx/spawn"; mkdir -p "$rd"
env FAKE_LOG="$rd/fake.log" FAKE_DIR="$rd" FAKE_SENDS="$rd/sends.log" FAKE_THREAD="$TARGET_THREAD" FAKE_RC_active_turn=5 FAKE_RC_thread_for_session=5 \
  T3_API="$FAKE" CC_CYCLE_RUNDIR="$rd" "$SCRIPT" --target "$TARGET_THREAD" --grace 0 >"$rd/out.txt" 2>&1; RC=$?
[ "$RC" -eq 3 ] && grep -q "^ERR_TARGET: .*t3-api.sh exit 5" "$rd/out.txt" && pass || faild "c6 the spawner must exit 3 with ERR_TARGET for a thread that is not there, got $RC" "$(cat "$rd/out.txt")"
env FAKE_LOG="$rd/fake.log" FAKE_DIR="$rd" FAKE_SENDS="$rd/sends.log" FAKE_THREAD="$TARGET_THREAD" FAKE_RC_active_turn=4 \
  T3_API="$FAKE" CC_CYCLE_RUNDIR="$rd" "$SCRIPT" --target "$TARGET_THREAD" --grace 0 >"$rd/out.txt" 2>&1; RC=$?
[ "$RC" -eq 6 ] && grep -q "^ERR_T3API: .*t3-api.sh exit 4" "$rd/out.txt" && ! grep -q "OK compactor spawned" "$rd/out.txt" \
  && pass || faild "c6 the spawner must exit 6 with ERR_T3API for a dead server and spawn nothing, got $RC" "$(cat "$rd/out.txt")"
# A session id target resolves through thread-for-session and the cycle then runs on the thread it names.
mx_run resolve-session 0
[ "$MX_RC" -eq 0 ] && [ "$MX_STATUS" = "ok" ] && pass || faild "c6 active-turn 5 then a thread-for-session hit must resolve and complete (rc=$MX_RC status=$MX_STATUS)" "$MX_LOG"

# =============================================================================
# 7. The same cycle end to end on a protocol-2 server: the real t3-api.sh and lib/t3_ws.py against a
#    stub that speaks HTTP and the /ws WebSocket, serving the synthetic states in
#    fixtures/t3-v2/write/scratch-states.json (real shapes captured from the scratch 0.1.0 server, the
#    scratch ids replaced). Cases: a normal compaction (busy first, a pending run, then the compaction item),
#    a thread with no conversation (nothing-to-compact: finished no-op, resume sent), the same with
#    --no-resume, a run that completes without a compaction item, a refused /compact, a refused resume,
#    a decode defect, an archived thread, a request that stays pending, a session id target through
#    statev2.sqlite (hit, ambiguous, missing database), a dead server, and two cycles on one server with an
#    inherited OPS_T3_COMMAND_KEY (the stub replays a repeated commandId like the real server). No stub
#    request is ever a POST.
# =============================================================================
STATES="$HERE/fixtures/t3-v2/write/scratch-states.json"
[ -f "$STATES" ] || { echo "missing fixture $STATES" >&2; exit 1; }
cat > "$TMP/stub_v2.py" <<'PY'
import base64, copy, hashlib, http.server, json, os, struct, sys, threading, urllib.parse
LOG, PORTF, STATES_PATH, TOKEN_PATH = sys.argv[1:5]
MODE, TID = os.environ["STUB_V2_MODE"], os.environ["STUB_TARGET_THREAD"]
INIT_BUSY, PENDING_READS = int(os.environ.get("STUB_INIT_BUSY", "3")), int(os.environ.get("STUB_PENDING_READS", "2"))
TOKEN = open(TOKEN_PATH).read().strip()
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
S = json.load(open(STATES_PATH))["states"]
LOCK = threading.Lock()
st = {"phase": "pre", "shell_reads": 0, "post_reads": 0, "mid": None, "seq": 600, "dispatches": 0, "seen": set()}

def fix(obj, mid=None):
    text = json.dumps(obj).replace("@TID@", TID)
    if mid:
        text = text.replace(S["compact-ok"]["compactMessageId"], mid).replace(S["compact-empty"]["compactMessageId"], mid)
    return json.loads(text)

def empty_pre():
    s = copy.deepcopy(S["compact-empty"]); e = s["entry"]
    e.update(status="idle", lastError=None, lastErrorClass=None, latestRunId=None, latestRunCompletedAt=None,
             latestRunRequestedAt=None, latestRunStartedAt=None, latestUserMessageAt=None, latestUserAuthoredMessageAt=None,
             itemCount=0, visibleItemCount=0)
    p = s["bounded"]["projection"]
    for k in ("runs", "turnItems", "visibleTurnItems", "messages"):
        p[k] = []
    return s

def pending_variant(s, mid):
    s = copy.deepcopy(s); e = s["entry"]; p = s["bounded"]["projection"]
    run = [r for r in p["runs"] if r["userMessageId"] == mid][0]
    run["status"] = "running"; run["completedAt"] = None
    for k in ("turnItems", "visibleTurnItems"):
        p[k] = [i for i in p.get(k, []) if (i.get("item") or i).get("runId") != run["id"] or (i.get("item") or i).get("type") == "user_message"]
    e.update(status="running", activeRunId=run["id"], activityRunStatus="running", latestRunId=run["id"], latestRunCompletedAt=None)
    return s

def nocomp_variant(s, mid):
    s = copy.deepcopy(s); p = s["bounded"]["projection"]
    for k in ("turnItems", "visibleTurnItems"):
        p[k] = [i for i in p.get(k, []) if (i.get("item") or i).get("type") != "compaction"]
    return s

def busy_variant(s):
    """The compaction run completed, and a third run (a background task's notification) is
    already running: the thread is busy again, as a thread with background work is within
    seconds of its compaction. The compaction run and its completed compaction item stay."""
    s = copy.deepcopy(s); e = s["entry"]; p = s["bounded"]["projection"]
    r3 = copy.deepcopy(p["runs"][-1])
    r3.update(id="run:thread:@TID@:ordinal:3", ordinal=3, status="running", completedAt=None,
              userMessageId="bg-notification-0000-0000-0000-000000000003", queuePosition=None)
    p["runs"].append(r3)
    e.update(status="running", activeRunId=r3["id"], activityRunStatus="running", latestRunId=r3["id"], latestRunCompletedAt=None)
    return s

def current():
    """(shell entry or None, bounded) for the target thread now."""
    mid = st["mid"]
    if st["phase"] == "pre":
        if MODE.startswith("empty"):
            s = empty_pre()
        elif st["shell_reads"] <= INIT_BUSY:
            s = copy.deepcopy(S["running"])
        else:
            s = copy.deepcopy(S["idle"])
        s = fix(s)
        if MODE == "archived-race":
            s["bounded"]["projection"]["thread"]["archivedAt"] = "2026-10-17T19:40:00.000Z"
        return s["entry"], s["bounded"]
    base = fix(S["compact-empty" if MODE.startswith("empty") else "compact-ok"], mid)
    if MODE == "nocomp":
        base = nocomp_variant(base, mid)
    if MODE == "pending-forever":
        # the compact message is accepted but no run ever adopts it: the thread looks like the idle one
        s = fix(S["idle"]); return s["entry"], s["bounded"]
    if MODE in ("ok", "refuse-resume", "busy-after") and st["post_reads"] < PENDING_READS:
        base = pending_variant(base, mid)
    elif MODE == "busy-after":
        base = busy_variant(base)
    return base["entry"], base["bounded"]

def record(rec):
    with open(LOG, "a") as f:
        f.write(json.dumps(rec) + "\n")

def ws_frame(opcode, data):
    head = bytes([0x80 | opcode]); n = len(data)
    head += bytes([n]) if n < 126 else (bytes([126]) + struct.pack(">H", n) if n < 65536 else bytes([127]) + struct.pack(">Q", n))
    return head + data

def read_frame(rf):
    h = rf.read(2)
    if len(h) < 2:
        return None
    op, masked, n = h[0] & 0x0F, h[1] & 0x80, h[1] & 0x7F
    if n == 126: n = struct.unpack(">H", rf.read(2))[0]
    elif n == 127: n = struct.unpack(">Q", rf.read(8))[0]
    key = rf.read(4) if masked else b""
    data = rf.read(n)
    if masked: data = bytes(b ^ key[i % 4] for i, b in enumerate(data))
    return op, data

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _raw(self, code, ctype, text):
        b = text.encode(); self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _json(self, obj, code=200): self._raw(code, "application/json", json.dumps(obj))
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); self.rfile.read(n) if n else None
        with LOCK: record({"kind": "http", "method": "POST", "path": self.path})
        self._json({"code": "not_found"}, 404)
    def do_GET(self):
        path = self.path.split("?", 1)[0]; auth = self.headers.get("Authorization", "")
        if path == "/ws":
            return self.websocket(auth)
        with LOCK:
            record({"kind": "http", "method": "GET", "path": self.path})
            if path == "/.well-known/t3/environment":
                return self._json({"serverVersion": "0.1.0", "orchestrationProtocolVersion": 2})
            if auth != "Bearer " + TOKEN:
                return self._json({"code": "auth_invalid"}, 401)
            if self.headers.get("x-t3-orchestration-protocol") != "2":
                return self._raw(400, "text/plain", "")
            if path == "/api/orchestration/shell":
                st["shell_reads"] += 1
                entry, _ = current()
                return self._json({"schemaVersion": 1, "snapshotSequence": 3000 + st["shell_reads"], "archivedThreads": [],
                                   "projects": [{"id": "proj-write-lane", "title": "write-lane", "workspaceRoot": "/tmp/wl"}],
                                   "threads": [entry]})
            if path.startswith("/api/orchestration/threads/") and path.endswith("/bounded"):
                tid = urllib.parse.unquote(path[len("/api/orchestration/threads/"):-len("/bounded")])
                if tid != TID:
                    return self._json({"code": "not_found", "reason": "thread_not_found"}, 404)
                if st["phase"] == "compact":
                    st["post_reads"] += 1
                _, bounded = current()
                return self._json(bounded)
        self._raw(200, "text/html; charset=utf-8", "<!doctype html><html></html>")
    def websocket(self, auth):
        if auth != "Bearer " + TOKEN:
            self.close_connection = True
            return self._raw(401, "application/json", '{"_tag":"EnvironmentAuthInvalidError","code":"auth_invalid"}')
        accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"] + GUID).encode()).digest()).decode()
        self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          "Sec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        self.close_connection = True
        while True:
            fr = read_frame(self.rfile)
            if fr is None: return
            op, data = fr
            if op == 0x8: return
            if op != 0x1: continue
            msg = json.loads(data)
            if msg.get("_tag") != "Request": continue
            payload, rid = msg.get("payload") or {}, msg.get("id")
            with LOCK:
                # The server keeps one receipt per commandId and REPLAYS it for an id it has seen: the command is not
                # run again and nothing changes (probe a13, a22). Modeled here, so an id collision between two cycles
                # shows as replayed:true AND as a missing state change, not only as two equal strings.
                replayed = payload.get("commandId") in st["seen"]
                st["seen"].add(payload.get("commandId"))
                record({"kind": "ws", "tag": msg.get("tag"), "payload": payload, "replayed": replayed})
                is_compact = payload.get("text") == "/compact"
                if replayed:
                    ex = {"_tag": "Success", "value": {"sequence": st["seq"]}}
                else:
                    st["dispatches"] += 1
                    if is_compact:
                        st["mid"] = payload["messageId"]; st["phase"] = "compact"
                    if (MODE == "refuse-compact" and is_compact) or (MODE == "refuse-resume" and not is_compact):
                        ex = {"_tag": "Failure", "cause": [{"_tag": "Fail", "error": {"_tag": "OrchestrationV2DispatchCommandError", "message": "stub refusal of this command"}}]}
                    elif MODE == "die":
                        ex = {"_tag": "Failure", "cause": [{"_tag": "Die", "defect": "stub decode failure"}]}
                    else:
                        st["seq"] += 1; ex = {"_tag": "Success", "value": {"sequence": st["seq"]}}
            self.wfile.write(ws_frame(0x1, json.dumps({"_tag": "Exit", "requestId": rid, "exit": ex}).encode()))

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
with open(PORTF, "w") as f: f.write(str(srv.server_address[1]))
srv.serve_forever()
PY

V2_PID=""
v2_stop() { [ -n "$V2_PID" ] && kill "$V2_PID" >/dev/null 2>&1; V2_PID=""; }
trap 'v2_stop; cleanup' EXIT
# v2_start <mode> <log>: start the stub; exports OPS_T3_BASE.
v2_start() {
  local portf="$TMP/v2port.$RANDOM"
  : > "$2"
  STUB_V2_MODE="$1" STUB_TARGET_THREAD="$TARGET_THREAD" python3 "$TMP/stub_v2.py" "$2" "$portf" "$STATES" "$TOKENF" &
  V2_PID=$!
  local i; for i in $(seq 1 50); do [ -s "$portf" ] && break; sleep 0.1; done
  [ -s "$portf" ] || { echo "V2 stub failed to start" >&2; return 1; }
  export OPS_T3_BASE="http://127.0.0.1:$(cat "$portf")"
}
# A T3 home with no statev2.sqlite and no server-runtime.json: a V2 case that resolves a session id builds its own.
export T3CODE_HOME="$TMP/t3home-empty"; mkdir -p "$T3CODE_HOME/userdata"
unset T3_API
v2_case() {  # <mode> <extra worker args...>: runs the real worker once; sets V2_RC, V2_LOG_TXT, V2_STATUS, V2_WS (dispatch texts)
  local mode="$1"; shift
  local rd="$TMP/v2case/$mode.$RANDOM" wslog="$TMP/v2case/$mode.ws.$RANDOM"
  mkdir -p "$rd" "$TMP/v2case"
  v2_start "$mode" "$wslog" || exit 1
  V2_BATON="$rd/baton.txt"; printf '%s\n' "V2_RESUME_BATON_TEXT" > "$V2_BATON"
  CC_CYCLE_RUNDIR="$rd" T3_POLL=0.05 T3_CONFIRM=2 timeout 120 "$SCRIPT" --worker --target "${V2_TARGET:-$TARGET_THREAD}" \
    --grace 0 --idle-timeout 30 --timeout "${V2_TIMEOUT:-30}" --baton "$V2_BATON" "$@" >/dev/null 2>&1; V2_RC=$?
  v2_stop
  V2_LOG_TXT="$(cat "$rd"/*.log 2>/dev/null)"
  V2_STATUS="$(sed -n 's/.*result=\([^ ]*\).*/\1/p' "$rd"/*.status 2>/dev/null | tail -1)"
  V2_WSLOG="$wslog"
  V2_WS="$(python3 - "$wslog" <<'PY2'
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["kind"] == "ws":
        print(r["payload"].get("type"), repr(r["payload"].get("text")))
PY2
)"
  V2_POSTS="$(grep -c '"method": "POST"' "$wslog" 2>/dev/null)"; V2_POSTS="${V2_POSTS:-0}"
}
RESUME_Q="'V2_RESUME_BATON_TEXT'"
v2_ws_is() {  # <label> <expected dispatch lines, newline separated>: the WebSocket dispatches the stub saw
  [ "$V2_WS" = "$2" ] && pass || faild "$1: WebSocket dispatches should be [$(printf '%s' "$2" | tr '\n' ';')], got [$(printf '%s' "$V2_WS" | tr '\n' ';')]" "$V2_LOG_TXT"
}
v2_check() {  # <label> <exit> <status result> <log must contain, or ->
  [ "$V2_RC" -eq "$2" ] && pass || faild "$1: worker exit should be $2, got $V2_RC" "$V2_LOG_TXT"
  [ "$V2_STATUS" = "$3" ] && pass || faild "$1: status result should be '$3', got '$V2_STATUS'" "$V2_LOG_TXT"
  [ "$4" = "-" ] || { grep -qF -- "$4" <<< "$V2_LOG_TXT" && pass || faild "$1: the log must contain '$4'" "$V2_LOG_TXT"; }
  [ "$V2_POSTS" -eq 0 ] && pass || faild "$1: V2 has no HTTP write route and nothing may POST, saw $V2_POSTS"
}

# 7a. A normal compaction: busy for three shell reads, /compact queues a run that is pending for two reads and then
#     completes with its compaction item; the resume baton goes out once, after the proof, and is consumed.
v2_case ok
v2_check "c7a ok" 0 ok "native compaction verified"
v2_ws_is "c7a ok" "$(printf "message.dispatch '/compact'\nmessage.dispatch %s" "$RESUME_Q")"
[ ! -f "$V2_BATON" ] && compgen -G "$V2_BATON.sent-*" >/dev/null && pass || faild "c7a ok: the baton must be consumed on success"
python3 - "$V2_WSLOG" "$TARGET_THREAD" <<'PY'
import json, sys
ws = [json.loads(l)["payload"] for l in open(sys.argv[1]) if '"kind": "ws"' in l]
assert len(ws) == 2, ws
for p in ws:
    assert p["threadId"] == sys.argv[2] and p["dispatchMode"] == {"type": "queue_after_active"} and "deliveryIntent" not in p, p
assert ws[0]["messageId"] != ws[1]["messageId"] and ws[0]["commandId"] != ws[1]["commandId"], ws
PY
[ $? -eq 0 ] && pass || faild "c7a ok: both dispatches must be queue_after_active message.dispatch on the target with their own ids"

# 7b. THE FINDING: a thread whose provider session has no conversation yet. T3 refuses /compact with
#     "Start a conversation before compacting this thread." and t3-api.sh compact-status says nothing-to-compact.
#     That was polled as pending to --timeout and ended ERR_TIMEOUT with no resume. It is a finished no-op: the
#     cycle says so and STILL sends the resume baton, once, then consumes it.
v2_case empty
v2_check "c7b nothing-to-compact" 0 ok-nothing-to-compact "nothing to compact: T3 says the thread has no conversation yet"
v2_ws_is "c7b nothing-to-compact" "$(printf "message.dispatch '/compact'\nmessage.dispatch %s" "$RESUME_Q")"
[ ! -f "$V2_BATON" ] && compgen -G "$V2_BATON.sent-*" >/dev/null && pass || faild "c7b nothing-to-compact: the resume baton must be sent and consumed"
grep -q "ERR_" <<< "$V2_LOG_TXT" && faild "c7b nothing-to-compact is not an error: no ERR_ line may appear" "$V2_LOG_TXT" || pass
grep -q "no compaction needed, thread idle" <<< "$V2_LOG_TXT" && pass || faild "c7b nothing-to-compact must log that no compaction was needed" "$V2_LOG_TXT"
v2_case empty-nr --no-resume
v2_check "c7b nothing-to-compact --no-resume" 0 ok-no-resume "nothing to compact"
v2_ws_is "c7b nothing-to-compact --no-resume" "message.dispatch '/compact'"
[ -f "$V2_BATON" ] && pass || faild "c7b nothing-to-compact --no-resume must keep the baton"

# 7c. A run that completes without a compaction item is not a compaction (probe a65): ERR_COMPACT, no resume.
v2_case nocomp
v2_check "c7c no compaction item" 5 compact-error "ERR_COMPACT: provider rejected request"
v2_ws_is "c7c no compaction item" "message.dispatch '/compact'"
[ -f "$V2_BATON" ] && pass || faild "c7c no compaction item: the baton must be kept"

# 7d. Refusals on the writes: the server refuses /compact (exit 11), refuses the resume after a good compaction
#     (exit 11; the baton must NOT be consumed and nothing may be recorded as resumed), cannot decode (12), and the
#     client guard refuses an archived thread (10; nothing reaches the socket).
v2_case refuse-compact
v2_check "c7d refused compact" 5 compact-error "ERR_DISPATCH: native /compact request failed: t3-api.sh exit 11 (refused by the server"
v2_ws_is "c7d refused compact" "message.dispatch '/compact'"
[ -f "$V2_BATON" ] && pass || faild "c7d refused compact: the baton must be kept"
v2_case refuse-resume
v2_check "c7d refused resume" 5 compact-error "ERR_DISPATCH: resume dispatch failed: t3-api.sh exit 11 (refused by the server"
v2_ws_is "c7d refused resume" "$(printf "message.dispatch '/compact'\nmessage.dispatch %s" "$RESUME_Q")"
[ -f "$V2_BATON" ] && ! compgen -G "$V2_BATON.sent-*" >/dev/null && pass || faild "c7d refused resume: the baton must NOT be marked sent when the server refused it"
grep -q "resume dispatched" <<< "$V2_LOG_TXT" && faild "c7d refused resume: the log must not claim a resume" "$V2_LOG_TXT" || pass
v2_case die
v2_check "c7d decode defect" 5 compact-error "ERR_DISPATCH: native /compact request failed: t3-api.sh exit 12 (the server could not decode"
v2_case archived-race
v2_check "c7d archived thread" 5 compact-error "ERR_DISPATCH: native /compact request failed: t3-api.sh exit 10 (refused by a guard"
v2_ws_is "c7d archived thread" ""

# 7e. A /compact that no run ever adopts stays pending: ERR_TIMEOUT at --timeout, no resume (unchanged contract).
V2_TIMEOUT=2; v2_case pending-forever; V2_TIMEOUT=""
v2_check "c7e pending forever" 5 timeout "ERR_TIMEOUT:"
v2_ws_is "c7e pending forever" "message.dispatch '/compact'"
[ -f "$V2_BATON" ] && pass || faild "c7e pending forever: the baton must be kept"
# The timeout log says what the cycle saw (it used to say only that it timed out, so the
# cause had to be inferred from the T3 database), and takes one fresh read of the thread.
grep -q "raw-status: compact-status=pending messageId=[^;]*; last thread read: activeTurnId=null session.status=[a-z]* lastError=none" <<< "$V2_LOG_TXT" \
  && pass || faild "c7e pending forever: the log must carry the last compact-status and the last thread read" "$V2_LOG_TXT"
grep -q "ERR_TIMEOUT: no completed compaction for request .* (last compact-status: pending; thread: activeTurnId=null session.status=" <<< "$V2_LOG_TXT" \
  && pass || faild "c7e pending forever: the ERR_TIMEOUT line must name the thread's state" "$V2_LOG_TXT"
grep -q "diag: session.status=.* latestTurn.state=.* runs=\[" <<< "$V2_LOG_TXT" \
  && pass || faild "c7e pending forever: the log must carry a fresh summary of the thread (diag:)" "$V2_LOG_TXT"

# 7f. A session id as the target resolves through statev2.sqlite (never the V1 table) and the cycle then runs on
#     the thread it names; an ambiguous session is ERR_TARGET (3) naming the refusal; a missing V2 database is
#     ERR_T3API (6) saying it did not fall back, never a "thread not found"; a dead server is ERR_T3API too.
SID_HOME="$TMP/t3home-sid"; mkdir -p "$SID_HOME/userdata"
python3 - "$SID_HOME/userdata/statev2.sqlite" "$TARGET_THREAD" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1]); tid = sys.argv[2]
con.execute("""CREATE TABLE orchestration_v2_projection_provider_threads (
  provider_thread_id TEXT PRIMARY KEY, thread_id TEXT, owner_node_id TEXT, provider TEXT NOT NULL,
  provider_session_id TEXT, status TEXT NOT NULL, first_run_ordinal INTEGER, last_run_ordinal INTEGER,
  updated_at TEXT NOT NULL, payload_json TEXT NOT NULL, driver TEXT, provider_instance_id TEXT)""")
con.execute("""CREATE TABLE orchestration_v2_projection_threads (
  thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL, default_provider TEXT NOT NULL,
  runtime_mode TEXT NOT NULL, interaction_mode TEXT NOT NULL, active_provider_thread_id TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT,
  payload_json TEXT NOT NULL, provider_instance_id TEXT)""")
def thread(t, active):
    con.execute("INSERT INTO orchestration_v2_projection_threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (t, "p", "fixture", "claudeAgent", "full-access", "default", active, "2026-10-01T11:00:00.000Z",
                 "2026-10-01T12:00:00.000Z", None, None, "{}", "claudeAgent"))
def pthread(ptid, t, native):
    con.execute("INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (ptid, t, None, "claudeAgent", None, "idle", 1, 1, "2026-10-01T12:00:00.000Z",
                 json.dumps({"nativeThreadRef": {"driver": "claudeAgent", "nativeId": native}}), "claudeAgent", "claudeAgent"))
thread(tid, "pt-hit"); pthread("pt-hit", tid, "sess-cc-hit-0001")
thread("amb-1", "pt-a1"); thread("amb-2", "pt-a2"); pthread("pt-a1", "amb-1", "sess-cc-amb-0001"); pthread("pt-a2", "amb-2", "sess-cc-amb-0001")
con.commit(); con.close()
PY
export T3CODE_HOME="$SID_HOME"; V2_TARGET="sess-cc-hit-0001"; v2_case ok; V2_TARGET=""; export T3CODE_HOME="$TMP/t3home-empty"
v2_check "c7f session id target" 0 ok "native compaction verified"
v2_ws_is "c7f session id target" "$(printf "message.dispatch '/compact'\nmessage.dispatch %s" "$RESUME_Q")"
python3 - "$V2_WSLOG" "$TARGET_THREAD" <<'PY'
import json, sys
ws = [json.loads(l)["payload"] for l in open(sys.argv[1]) if '"kind": "ws"' in l]
assert [p["threadId"] for p in ws] == [sys.argv[2]] * 2, ws
PY
[ $? -eq 0 ] && pass || faild "c7f session id target: both dispatches must name the thread the session maps to"
v2_start ok "$TMP/v2case/spawn.ws" || exit 1
SP="$TMP/v2case/spawn-rd"; mkdir -p "$SP"
OUT="$(CC_CYCLE_RUNDIR="$SP" T3CODE_HOME="$SID_HOME" "$SCRIPT" --target sess-cc-amb-0001 --grace 0 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && grep -q "^ERR_TARGET: .*t3-api.sh exit 5" <<< "$OUT" && grep -q "refusing to guess" <<< "$OUT" \
  && pass || faild "c7f an ambiguous session id must be ERR_TARGET (3) naming the refusal, got $RC" "$OUT"
OUT="$(CC_CYCLE_RUNDIR="$SP" T3CODE_HOME="$TMP/t3home-empty" "$SCRIPT" --target sess-cc-hit-0001 --grace 0 2>&1)"; RC=$?
[ "$RC" -eq 6 ] && grep -q "^ERR_T3API: .*t3-api.sh exit 4" <<< "$OUT" && grep -q "not falling back to the V1 table" <<< "$OUT" \
  && ! grep -q "ERR_TARGET" <<< "$OUT" \
  && pass || faild "c7f a missing V2 database must be ERR_T3API (6), not a missing thread, got $RC" "$OUT"
v2_stop
OUT="$(OPS_T3_BASE="http://127.0.0.1:1" CC_CYCLE_RUNDIR="$SP" "$SCRIPT" --target "$TARGET_THREAD" --grace 0 2>&1)"; RC=$?
[ "$RC" -eq 6 ] && grep -q "^ERR_T3API: .*t3-api.sh exit 4" <<< "$OUT" && ! grep -q "OK compactor spawned" <<< "$OUT" \
  && pass || faild "c7f a dead server must be ERR_T3API (6) and spawn nothing, got $RC" "$OUT"

# 7g. An inherited OPS_T3_COMMAND_KEY is never passed on. t3-api.sh builds each command id
#     from the caller, the verb, the thread, a hash of the text and that key, and the server replays its receipt for an
#     id it has seen. With a fixed key in the environment a second cycle on the same thread would send the SAME
#     '/compact' ids and the same baton ids: the server replays cycle 1's receipt (no new run; the stub models this),
#     compact-status finds cycle 1's finished compaction under the id both cycles share, and the second cycle ends ok,
#     "verified", having compacted nothing and never delivered its baton. Two worker cycles with the key exported, on
#     one server, the same baton text both times (the worst case for a collision): all four commands must have their
#     own ids, none may be a replay, none may carry the key, and both cycles must still succeed (so the distinct ids
#     did not come from a failing run). The second cycle must also have started its own compaction (two /compact and
#     two resume dispatches reached the server).
K_KEY="inherited-intent-key-0001"
kd="$TMP/v2case/keyed"; mkdir -p "$kd/rd1" "$kd/rd2"
declare -a KRC KST
v2_start ok "$kd/ws.log" || exit 1
export OPS_T3_COMMAND_KEY="$K_KEY"
for n in 1 2; do
  printf '%s\n' "V2_RESUME_BATON_TEXT" > "$kd/baton$n.txt"
  CC_CYCLE_RUNDIR="$kd/rd$n" T3_POLL=0.05 T3_CONFIRM=2 timeout 120 "$SCRIPT" --worker --target "$TARGET_THREAD" \
    --grace 0 --idle-timeout 30 --timeout 30 --baton "$kd/baton$n.txt" >/dev/null 2>&1; KRC[$n]=$?
  KST[$n]="$(sed -n 's/.*result=\([^ ]*\).*/\1/p' "$kd/rd$n"/*.status 2>/dev/null | tail -1)"
done
unset OPS_T3_COMMAND_KEY
v2_stop
for n in 1 2; do
  [ "${KRC[$n]}" -eq 0 ] && [ "${KST[$n]}" = "ok" ] && pass || faild "c7g cycle $n with the key exported should end ok (exit 0), got exit ${KRC[$n]} status '${KST[$n]}'" "$(cat "$kd/rd$n"/*.log 2>/dev/null)"
  compgen -G "$kd/baton$n.txt.sent-*" >/dev/null && pass || faild "c7g cycle $n must have its baton consumed (delivered)"
done
python3 - "$kd/ws.log" "$K_KEY" <<'PY'
import json, sys
ws = [json.loads(l) for l in open(sys.argv[1]) if '"kind": "ws"' in l]
bad = []
if len(ws) != 4: bad.append("expected 4 dispatches (a /compact and a resume per cycle), got %d" % len(ws))
cids = [r["payload"]["commandId"] for r in ws]; mids = [r["payload"]["messageId"] for r in ws]
if len(set(cids)) != len(cids): bad.append("commandIds repeat: %d distinct of %d" % (len(set(cids)), len(cids)))
if len(set(mids)) != len(mids): bad.append("messageIds repeat: %d distinct of %d" % (len(set(mids)), len(mids)))
if any(r.get("replayed") for r in ws): bad.append("the server replayed a receipt: %s" % [r["payload"]["commandId"] for r in ws if r.get("replayed")])
if any(sys.argv[2] in c or sys.argv[2] in m for c, m in zip(cids, mids)): bad.append("an id carries the inherited key")
if [r["payload"].get("text") for r in ws].count("/compact") != 2: bad.append("expected two /compact dispatches")
if bad:
    sys.stderr.write("; ".join(bad) + "\n"); sys.exit(1)
PY
[ $? -eq 0 ] && pass || faild "c7g with OPS_T3_COMMAND_KEY exported, two cycles must send four commands with their own ids, none replayed (see above)"

# =============================================================================
# 8. COMPLETED MEANS DONE. A thread with background work is woken seconds after its
#    compaction and then runs for 15 to 25 minutes, so the cycle's old success test (a completed
#    compaction AND a thread idle for T3_CONFIRM polls) never passed: in the cycles that timed out
#    that way, the completed compaction item had landed 75 to 163 s after the request, and the baton
#    was never sent. A completed compaction is now success on its own; the resume is sent, queued behind
#    the busy run (V2 send is queue_after_active), and the log says the thread was busy.
# =============================================================================
# 8a. Against the fake t3-api.sh: the compaction completes at once, or after two pending answers, and
#     the thread reads busy from the moment /compact was sent until the end. --timeout 30 and the
#     20 s elapsed bound prove the cycle did not wait for an idle thread that never comes.
for step in busyafter busyafter-seq; do
  mx_run "$step" 0
  who="c8a $step"
  [ "$MX_RC" -eq 0 ] && pass || faild "$who: a completed compaction on a busy thread must end ok (exit 0), got $MX_RC" "$MX_LOG"
  [ "$MX_STATUS" = "ok" ] && pass || faild "$who: status result should be ok, got '$MX_STATUS'" "$MX_LOG"
  [ "$MX_SENDS" -eq 1 ] && pass || faild "$who: the resume must be sent once, got $MX_SENDS" "$MX_LOG"
  [ ! -f "$MX_BATON" ] && compgen -G "$MX_BATON.sent-*" >/dev/null && pass || faild "$who: the baton must be consumed" "$MX_LOG"
  grep -q "MX_RESUME_TEXT" "$TMP/mx/$MXN/sends.log" && pass || faild "$who: the baton text must be what was sent" "$(cat "$TMP/mx/$MXN/sends.log")"
  grep -q "thread busy again after the compaction (activeTurnId=turn-background-1 session.status=running)" <<< "$MX_LOG" \
    && pass || faild "$who: the log must say the thread was busy again, with what it saw" "$MX_LOG"
  grep -q "native compaction verified" <<< "$MX_LOG" && pass || faild "$who: the log must say the compaction was verified" "$MX_LOG"
  grep -q "ERR_\|raw-status:" <<< "$MX_LOG" && faild "$who: a success must log no ERR_ and no raw-status line" "$MX_LOG" || pass
  [ "$MX_ELAPSED" -le 20 ] && pass || faild "$who: took ${MX_ELAPSED}s, it must not wait for an idle thread" "$MX_LOG"
done
# The pending answers were polled before the success (the sequence ran, not just its last word).
[ "$(grep -c '^compact-status' "$TMP/mx/$MXN/fake.log")" -eq 3 ] && pass || faild "c8a busyafter-seq: expected three compact-status reads (pending, pending, completed)" "$(cat "$TMP/mx/$MXN/fake.log")"
# nothing-to-compact on a thread that is busy again is the same finished no-op: still ok, baton sent.
mx_run busyafter-noop 0
[ "$MX_RC" -eq 0 ] && [ "$MX_STATUS" = "ok-nothing-to-compact" ] && [ "$MX_SENDS" -eq 1 ] && [ ! -f "$MX_BATON" ] \
  && pass || faild "c8a nothing-to-compact on a busy thread must still finish ok-nothing-to-compact and send the baton (rc=$MX_RC status=$MX_STATUS sends=$MX_SENDS)" "$MX_LOG"
grep -q "no compaction needed (the thread is busy again: activeTurnId=turn-background-1" <<< "$MX_LOG" && pass || faild "c8a nothing-to-compact on a busy thread must say so" "$MX_LOG"
# --no-resume on a busy thread: success, nothing sent, baton kept.
rd="$TMP/mx/busy-nr"; mkdir -p "$rd"; : > "$rd/fake.log"; : > "$rd/sends.log"; printf 'KEEP\n' > "$rd/baton.txt"
env FAKE_LOG="$rd/fake.log" FAKE_DIR="$rd" FAKE_SENDS="$rd/sends.log" FAKE_THREAD="$TARGET_THREAD" FAKE_BUSY_AFTER_COMPACT=1 \
  T3_API="$FAKE" T3_POLL=0.02 CC_CYCLE_RUNDIR="$rd" timeout 60 "$SCRIPT" --worker --target "$TARGET_THREAD" --grace 0 --idle-timeout 20 --timeout 30 --baton "$rd/baton.txt" --no-resume >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ ! -s "$rd/sends.log" ] && [ -f "$rd/baton.txt" ] && grep -qh "result=ok-no-resume" "$rd"/*.status \
  && pass || faild "c8a --no-resume on a busy thread must end ok-no-resume, send nothing and keep the baton (rc=$RC)" "$(cat "$rd"/*.log 2>/dev/null)"
# A compaction that does NOT complete is still no success, busy or not: pending to the timeout ends
# ERR_TIMEOUT with no resume, and the log names what the thread was doing (the old log did not).
rd="$TMP/mx/busy-pending"; mkdir -p "$rd"; : > "$rd/fake.log"; : > "$rd/sends.log"; printf 'P\n' > "$rd/baton.txt"
env FAKE_LOG="$rd/fake.log" FAKE_DIR="$rd" FAKE_SENDS="$rd/sends.log" FAKE_THREAD="$TARGET_THREAD" FAKE_BUSY_AFTER_COMPACT=1 FAKE_EVIDENCE=pending \
  T3_API="$FAKE" T3_POLL=0.05 CC_CYCLE_RUNDIR="$rd" timeout 60 "$SCRIPT" --worker --target "$TARGET_THREAD" --grace 0 --idle-timeout 20 --timeout 2 --baton "$rd/baton.txt" >/dev/null 2>&1; RC=$?
BP_LOG="$(cat "$rd"/*.log 2>/dev/null)"
[ "$RC" -eq 5 ] && [ ! -s "$rd/sends.log" ] && [ -f "$rd/baton.txt" ] && grep -q "result=timeout" <<< "$BP_LOG" \
  && pass || faild "c8a a compaction that stays pending must end ERR_TIMEOUT with no resume and the baton kept, got $RC" "$BP_LOG"
grep -q "ERR_TIMEOUT: .*(last compact-status: pending; thread: activeTurnId=turn-background-1 session.status=running)" <<< "$BP_LOG" \
  && pass || faild "c8a the timeout line must carry the last compact-status and the thread's state" "$BP_LOG"
grep -q "raw-status: compact-status=pending messageId=fake-message-id; last thread read: activeTurnId=turn-background-1 session.status=running lastError=none (read [0-9]*s ago)" <<< "$BP_LOG" \
  && pass || faild "c8a the raw-status line must carry the raw answers it saw" "$BP_LOG"
grep -q "^[^ ]* diag: " <<< "$BP_LOG" && pass || faild "c8a a timeout must log a diag: line (here the fake has no thread read, which the line says)" "$BP_LOG"
# A thread that never goes idle BEFORE the compaction (nothing sent) names the thread's state too.
rd="$TMP/mx/neveridle"; mkdir -p "$rd"; : > "$rd/fake.log"; : > "$rd/sends.log"; printf 'N\n' > "$rd/baton.txt"
cat > "$TMP/fake-busy-snapshot.sh" <<'EOF3'
#!/usr/bin/env bash
if [ "${1:-}" = snapshot ]; then
  printf '{"threads":[{"id":"%s","session":{"status":"running","activeTurnId":"turn-bg-9","lastError":null}}]}\n' "$FAKE_THREAD"; exit 0
fi
exec "$FAKE_REAL" "$@"
EOF3
chmod +x "$TMP/fake-busy-snapshot.sh"
env FAKE_LOG="$rd/fake.log" FAKE_DIR="$rd" FAKE_SENDS="$rd/sends.log" FAKE_THREAD="$TARGET_THREAD" FAKE_REAL="$FAKE" \
  T3_API="$TMP/fake-busy-snapshot.sh" T3_POLL=0.05 CC_CYCLE_RUNDIR="$rd" timeout 60 "$SCRIPT" --worker --target "$TARGET_THREAD" --grace 0 --idle-timeout 1 --timeout 2 --baton "$rd/baton.txt" >/dev/null 2>&1; RC=$?
NI_LOG="$(cat "$rd"/*.log 2>/dev/null)"
[ "$RC" -eq 5 ] && [ ! -s "$rd/sends.log" ] && ! grep -q '^compact ' "$rd/fake.log" && pass || faild "c8a a thread that never goes idle must end ERR_BUSY with nothing sent (rc=$RC)" "$NI_LOG"
grep -q "ERR_BUSY: target still active after 1s (activeTurnId=turn-bg-9 session.status=running)" <<< "$NI_LOG" \
  && pass || faild "c8a the ERR_BUSY line must name what the thread was doing" "$NI_LOG"
grep -q "raw-status: compact-status=none-yet messageId=none; last thread read: activeTurnId=turn-bg-9 session.status=running" <<< "$NI_LOG" \
  && pass || faild "c8a the ERR_BUSY log must carry the raw status" "$NI_LOG"

# 8b. End to end on the protocol-2 stub with the real t3-api.sh and lib/t3_ws.py: busy for three shell
#     reads, /compact queues a run that is pending for two reads and then completes with its compaction
#     item, and from that read on a third run (a background notification) is running for good. The
#     baton must go out once, as a queue_after_active message.dispatch, and be consumed.
v2_case busy-after
v2_check "c8b busy after compaction" 0 ok "thread busy again after the compaction"
v2_ws_is "c8b busy after compaction" "$(printf "message.dispatch '/compact'\nmessage.dispatch %s" "$RESUME_Q")"
[ ! -f "$V2_BATON" ] && compgen -G "$V2_BATON.sent-*" >/dev/null && pass || faild "c8b busy after compaction: the baton must be consumed" "$V2_LOG_TXT"
grep -q "native compaction verified" <<< "$V2_LOG_TXT" && pass || faild "c8b busy after compaction: the compaction must be reported verified" "$V2_LOG_TXT"
grep -q "ERR_" <<< "$V2_LOG_TXT" && faild "c8b busy after compaction is not an error: no ERR_ line may appear" "$V2_LOG_TXT" || pass
python3 - "$V2_WSLOG" "$TARGET_THREAD" <<'PY'
import json, sys
ws = [json.loads(l)["payload"] for l in open(sys.argv[1]) if '"kind": "ws"' in l]
assert len(ws) == 2, ws
assert [p["text"] for p in ws][0] == "/compact" and ws[1]["text"] == "V2_RESUME_BATON_TEXT", ws
# The resume rides queue_after_active (starts at once on an idle thread, waits behind an active run on a
# busy one) and never deliveryIntent, which would inject into the live run.
assert ws[1]["dispatchMode"] == {"type": "queue_after_active"} and "deliveryIntent" not in ws[1], ws[1]
assert ws[1]["threadId"] == sys.argv[2], ws[1]
PY
[ $? -eq 0 ] && pass || faild "c8b busy after compaction: the resume must be a queue_after_active message.dispatch on the target thread"

echo "compact-cycle-t3-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
