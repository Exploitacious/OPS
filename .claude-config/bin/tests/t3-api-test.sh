#!/usr/bin/env bash
# t3-api-test.sh: behavior tests for t3-api.sh, the authenticated T3 Code
# orchestration client the Compactor's t3 backend calls.
#
# Why pin these: t3-api.sh mints and dispatches turn.start commands into the
# operator's live T3 sessions carrying a bearer token scoped orchestration:operate.
# Its two worst failures are a SILENT TOKEN LEAK (the token printed to stdout/stderr
# or written into a log/argv) and a MALFORMED dispatch (wrong command shape, wrong
# runtimeMode, non-uuid ids) that a live server would reject or misroute. Both need
# assertions, not trust. All calls hit a local python stub: nothing touches a live
# T3 server.
#
# Thread lifecycle: `settle` and `settle-when-idle` stop a thread's provider
# session, which kills its background lanes, so the cases below pin the refusals (a
# running turn, a pending request, backgroundLiveness working or monitoring), that the
# waiter settles only the one thread it was launched for, only after two consecutive
# idle reads, never after a new user message, and never past its timeout, and that it
# is really detached (own session) with the token nowhere on argv or in its log.
#
# Dual mode (T3 0.1.0): section 3c pins the protocol probe against the V1
# stub (1, an absent key and a 404 keep V1; HTML, a non-object or any other version fail
# closed) and the fail-loud rule (an HTML or non-JSON answer exits 6, where `snapshot`
# used to exit 0 on the SPA page). Section 3d runs a second stub that serves synthetic
# protocol-2 fixtures (fixtures/t3-v2/, built on the live 0.1.0 key lists, no live
# content) and pins the V1-shape translation of snapshot, shell, thread and active-turn,
# the pure idle verdict table (the PR-watch monitor case included), thread-for-session
# over a synthetic statev2.sqlite (zero, one and many rows, never the V1 table), and the
# exit-7 refusal of dispatch with zero POSTs. The V1 cases above stay as they were.
#
# V2 write path: section 3e runs a third stub that speaks HTTP and the /ws
# WebSocket on one loopback port. Its Exit frames are real frames recorded from a
# scratch 0.1.0 server by a write-path probe (fixtures/t3-v2/ws/) with the request's ids put
# in, and its thread states are real shell entries and /bounded answers captured from
# the sandboxed scratch 0.1.0 server (fixtures/t3-v2/write/scratch-states.json). It pins
# each write's happy path and command shape, the Success, Fail, Die and transport-loss
# classification, the one same-id retry on transport loss only, fresh ids after a
# refusal, the archived-thread and '/'-prefix guards, the settle refusals (active run,
# pending request, stale request, background task, held queue), archive's exit-7
# refusal with nothing dispatched, the compact-status evidence, the V2 settle waiter,
# server-busy, message-id (the id send mints, no request) and queued-cancel (only the queued run
# carrying the given message, never a person's message, the recorded a39 frame). Every stub is
# loopback only.
#
# Sandboxed, without a network. t3-api.sh dispatches turns into and
# settles threads on a real T3 server, so a defect in it or in this suite's base
# resolution must have nowhere to send. The suite refuses to run (exit 97) outside
# sandbox-run (the guard below) and with any route off the sandbox's own loopback
# (the check after it), and the gate runs it as sandbox-run --no-net
# (OPS CI runs every suite that way; verify-ops.sh lists it in OPS_SANDBOX_SUITES).
# Run it by hand the same way:
#   .claude-config/bin/sandbox-run --no-bind --no-net --ro-bind "$PWD" -- bash .claude-config/bin/tests/t3-api-test.sh
#
# Exit 0 = all pass. Any failure exits 1 and prints the offending case.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../t3-api.sh"
[ -x "$SCRIPT" ] || { echo "t3-api.sh missing or not executable: $SCRIPT" >&2; exit 1; }
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

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); }
faild() { FAIL=$((FAIL+1)); echo "FAIL: $1"; [ $# -gt 1 ] && echo "  $2"; }

TMP="$(mktemp -d)"
STUB_PID=""; STUB2_PID=""; STUB3_PID=""
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" >/dev/null 2>&1
  [ -n "$STUB2_PID" ] && kill "$STUB2_PID" >/dev/null 2>&1
  [ -n "$STUB3_PID" ] && kill "$STUB3_PID" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# A fake token; the token-leak assertions grep for this exact string and require it
# to appear NOWHERE except inside the (unrecorded) Authorization header.
SENTINEL="SENTINEL_T3_TOKEN_do_not_leak_9f3a1c"
TOKENF="$TMP/t3-harness.token"; printf '%s' "$SENTINEL" > "$TOKENF"; chmod 600 "$TOKENF"

# T3CODE_HOME layout so cmd_thread_for_session finds the SQLite; OPS_T3_BASE
# overrides base resolution so server-runtime.json is never consulted.
T3HOME="$TMP/t3"; mkdir -p "$T3HOME/userdata"
DB="$T3HOME/userdata/state.sqlite"
python3 - "$DB" <<'PY'
import sqlite3, sys, json
con = sqlite3.connect(sys.argv[1])
con.execute("""CREATE TABLE provider_session_runtime (
  thread_id TEXT PRIMARY KEY, provider_name TEXT NOT NULL, adapter_key TEXT NOT NULL,
  runtime_mode TEXT NOT NULL DEFAULT 'full-access', status TEXT NOT NULL,
  last_seen_at TEXT NOT NULL, resume_cursor_json TEXT, runtime_payload_json TEXT,
  provider_instance_id TEXT)""")
cur = json.dumps({"threadId": "thread-aaaa", "resume": "claude-sess-1", "turnCount": 3})
con.execute("INSERT INTO provider_session_runtime VALUES (?,?,?,?,?,?,?,?,?)",
            ("thread-aaaa", "claudeAgent", "claudeAgent", "auto-accept-edits", "running",
             "2026-09-05T00:00:00.000Z", cur, None, "claudeAgent"))
con.execute("INSERT INTO provider_session_runtime VALUES (?,?,?,?,?,?,?,?,?)",
            ("thread-codex", "codex", "codex", "full-access", "ready", "2026-09-10T00:00:00Z",
             json.dumps({"threadId":"codex-sess-1"}), None, "codex"))
con.commit(); con.close()
PY

# --- stub HTTP server ----------------------------------------------------------
# Serves canned snapshot / thread-detail / dispatch. Records every request as one
# JSON line {method, path, auth_present, auth_scheme, body} to $STUB_LOG. It records
# auth_scheme ("Bearer") and a boolean, NEVER the token bytes, so the log itself can
# be asserted token-free.
STUB_LOG="$TMP/requests.jsonl"; : > "$STUB_LOG"
PORTF="$TMP/port"
cat > "$TMP/stub.py" <<'PY'
import json, sys, http.server
LOG, PORTF = sys.argv[1], sys.argv[2]
SNAPSHOT = {
    "snapshotSequence": 1,
    "projects": [
        {"id": "proj-1", "title": "P1", "workspaceRoot": "/tmp/p1", "defaultModelSelection": {}},
        {"id": "proj-2", "title": "P2", "workspaceRoot": "/tmp/p2", "defaultModelSelection": {}},
    ],
    "threads": [
        {"id": "thread-aaaa", "title": "A", "projectId": "proj-1",
         "session": {"threadId": "thread-aaaa", "status": "running", "providerName": "claudeAgent",
                     "providerInstanceId": "claudeAgent", "runtimeMode": "auto-accept-edits",
                     "activeTurnId": "turn-active-1", "lastError": None,
                     "updatedAt": "2026-09-05T00:00:00.000Z"}},
        {"id": "thread-bbbb", "title": "B", "projectId": "proj-2",
         "session": {"threadId": "thread-bbbb", "status": "idle", "providerName": "claudeAgent",
                     "providerInstanceId": "claudeAgent", "runtimeMode": "full-access",
                     "activeTurnId": None, "lastError": None,
                     "updatedAt": "2026-09-05T00:00:00.000Z"}},
    ],
    "updatedAt": "2026-09-05T00:00:00.000Z",
}

# --- /api/orchestration/shell: scripted threads for the settle tests -----------------
# `n` counts shell reads since the last /__reset (every read advances every thread),
# so a program says what the thread looks like on its n-th read. The launcher's own
# foreground read is n=1; the waiter's first poll is n=2. Like the real endpoint this
# OMITS archived threads. A successful thread.settle marks the thread settled, and
# the stub refuses a settle on a running/starting session or a pending request the way
# T3 0.0.42 does, but NOT on backgroundLiveness (the server would kill those lanes,
# which is exactly why the client has to refuse).
STATE = {"n": 0, "settled": set(), "hang": 0, "env": "v1", "snapshot": "json"}
# The protocol probe (GET /.well-known/t3/environment) in each mode. "v1" is what T3
# 0.0.45 answers; "absent" (no key) and "404" (no route) are older servers; the rest
# must fail closed: HTML or a non-object exits 6, any other version exits 8.
ENV_ANSWERS = {
    "v1": (200, "application/json", {"serverVersion": "0.0.45", "orchestrationProtocolVersion": 1}),
    "absent": (200, "application/json", {"serverVersion": "0.0.40"}),
    "404": (404, "application/json", {"error": "not found"}),
    "html": (200, "text/html; charset=utf-8", "<!doctype html><html><body>app</body></html>"),
    "list": (200, "application/json", [1, 2]),
    "v3": (200, "application/json", {"orchestrationProtocolVersion": 3}),
    "bool": (200, "application/json", {"orchestrationProtocolVersion": True}),
    "string2": (200, "application/json", {"orchestrationProtocolVersion": "2"}),
    "null": (200, "application/json", {"orchestrationProtocolVersion": None}),
}
# The snapshot route in each mode, for the fail-loud cases: the SPA HTML that T3 0.1.0
# serves with 200, a non-JSON body labelled JSON, an empty body, and a JSON array.
SNAPSHOT_ANSWERS = {
    "html": (200, "text/html; charset=utf-8", "<!doctype html><html><head><title>T3</title></head></html>"),
    "badjson": (200, "application/json", "<!doctype html>"),
    "empty": (200, "application/json", ""),
    "array": (200, "application/json", "[]"),
}
SW_IDS = ("sw-idle", "sw-other", "sw-running", "sw-bg", "sw-mon", "sw-approval", "sw-input",
          "sw-starting", "sw-late", "sw-bgend", "sw-msg", "sw-flap", "sw-hold", "sw-settled",
          "sw-archived", "sw-timeout", "sw-error", "sw-edge", "sw-vanish")
def sw_thread(tid, n):
    t = {"id": tid, "title": tid, "projectId": "proj-1", "archivedAt": None, "settledAt": None,
         "latestUserMessageAt": "2026-09-30T10:00:00.000Z", "backgroundLiveness": None,
         "hasPendingApprovals": False, "hasPendingUserInput": False,
         "latestTurn": {"turnId": "turn-done", "state": "completed"},
         "session": {"threadId": tid, "status": "ready", "activeTurnId": None, "lastError": None,
                     "runtimeMode": "full-access"}}
    def busy():
        t["session"] = dict(t["session"], status="running", activeTurnId="turn-live")
        t["latestTurn"] = {"turnId": "turn-live", "state": "running"}
    if tid in ("sw-running", "sw-timeout"): busy()
    elif tid == "sw-bg": t["backgroundLiveness"] = "working"
    elif tid == "sw-mon": t["backgroundLiveness"] = "monitoring"
    elif tid == "sw-approval": t["hasPendingApprovals"] = True
    elif tid == "sw-input": t["hasPendingUserInput"] = True
    elif tid == "sw-starting": t["session"] = dict(t["session"], status="starting")
    elif tid == "sw-late" and n <= 3: busy()
    elif tid == "sw-hold" and n <= 4: busy()
    elif tid == "sw-vanish" and n <= 2: busy()
    elif tid == "sw-bgend" and n <= 4: t["backgroundLiveness"] = "working"
    elif tid == "sw-msg" and n >= 3: t["latestUserMessageAt"] = "2026-09-30T10:05:00.000Z"
    elif tid == "sw-flap" and n == 3: busy()
    if tid == "sw-settled" or tid in STATE["settled"]: t["settledAt"] = "2026-09-30T09:00:00.000Z"
    return t
def sw_shell():
    return {"snapshotSequence": 2, "projects": [], "updatedAt": "2026-09-05T00:00:00.000Z",
            "threads": [sw_thread(i, STATE["n"]) for i in SW_IDS
                        if i != "sw-archived" and not (i == "sw-vanish" and STATE["n"] >= 3)]}

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _record(self, body):
        auth = self.headers.get("Authorization", "")
        rec = {"method": self.command, "path": self.path,
               "auth_present": bool(auth), "auth_scheme": auth.split(" ", 1)[0] if auth else "",
               "proto": self.headers.get("x-t3-orchestration-protocol"),
               "body": body, "n": STATE["n"]}
        with open(LOG, "a") as f:
            f.write(json.dumps(rec) + "\n")
    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)
    def _send_raw(self, code, ctype, text):
        b = text.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        self._record("")
        if self.path == "/.well-known/t3/environment":
            code, ctype, obj = ENV_ANSWERS[STATE["env"]]
            return self._send_raw(code, ctype, obj if isinstance(obj, str) else json.dumps(obj))
        if self.path.startswith("/api/orchestration/snapshot"):
            if STATE["snapshot"] in SNAPSHOT_ANSWERS:
                return self._send_raw(*SNAPSHOT_ANSWERS[STATE["snapshot"]])
            self._send(SNAPSHOT)
        elif self.path.startswith("/api/orchestration/shell"):
            STATE["n"] += 1
            hung = STATE["hang"]
            if hung:
                import time; time.sleep(hung)   # a server that accepts and never answers in time
            try:
                self._send(sw_shell())
            except (BrokenPipeError, ConnectionResetError):
                # The hang case: the client timed out and closed while we slept, so the late
                # answer has nowhere to go. Expected there (the test asserts the client side), and
                # it printed a traceback on every run; any other early close still surfaces.
                if not hung:
                    raise
        elif self.path.startswith("/api/orchestration/threads/"):
            self._send({"page": {}, "snapshotSequence": 1, "thread": {"id": "x", "activities": []}})
        else:
            self._send({"error": "not found"}, 404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode() if n else ""
        if self.path == "/__reset":
            # Test control channel: unrecorded, unauthenticated, resets the shell programs.
            STATE["n"] = 0; STATE["settled"].clear(); STATE["hang"] = 0
            STATE["env"] = "v1"; STATE["snapshot"] = "json"
            return self._send({"ok": True})
        if self.path.startswith("/__hang/"):
            STATE["hang"] = int(self.path.rsplit("/", 1)[1])
            return self._send({"ok": True})
        if self.path.startswith("/__env/"):
            STATE["env"] = self.path.rsplit("/", 1)[1]
            return self._send({"ok": True})
        if self.path.startswith("/__snapshot/"):
            STATE["snapshot"] = self.path.rsplit("/", 1)[1]
            return self._send({"ok": True})
        self._record(body)
        if self.path.startswith("/api/orchestration/dispatch"):
            cmd = json.loads(body) if body else {}
            if cmd.get("type") == "thread.settle":
                t = sw_thread(cmd.get("threadId"), STATE["n"]) if cmd.get("threadId") in SW_IDS else None
                s_ = (t or {}).get("session") or {}
                if t is None or t["id"] == "sw-error":
                    return self._send({"error": "settle blocked"}, 500)
                if s_.get("status") in ("starting", "running") or t["hasPendingApprovals"] or t["hasPendingUserInput"]:
                    return self._send({"error": "settle blocked"}, 500)
                STATE["settled"].add(t["id"])
            self._send({"sequence": 1})
        else:
            self._send({"error": "not found"}, 404)

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
with open(PORTF, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$TMP/stub.py" "$STUB_LOG" "$PORTF" &
STUB_PID=$!
# Wait for the stub to publish its port.
for _ in $(seq 1 50); do [ -s "$PORTF" ] && break; sleep 0.1; done
[ -s "$PORTF" ] || { echo "stub failed to start" >&2; exit 1; }
PORT="$(cat "$PORTF")"

export OPS_T3_BASE="http://127.0.0.1:$PORT"
export OPS_T3_TOKEN_FILE="$TOKENF"
export T3CODE_HOME="$T3HOME"

# Aggregate of every command's stdout+stderr, for the token-leak sweep.
ALLOUT="$TMP/allout.txt"; : > "$ALLOUT"
run() {  # run the helper, echo combined output, tee into ALLOUT (file survives subshell)
  local out rc
  out="$("$SCRIPT" "$@" 2>&1)"; rc=$?
  printf '%s\n' "$out" >> "$ALLOUT"
  printf '%s' "$out"
  return $rc
}

# --- 1. thread-for-session -----------------------------------------------------
OUT="$(run thread-for-session claude-sess-1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$OUT" = "thread-aaaa" ] \
  && pass || faild "thread-for-session should map to thread-aaaa (rc=$rc)" "$OUT"

OUT="$(run thread-for-session no-such-session)"; rc=$?
[ "$rc" -eq 5 ] && pass || faild "unknown session should exit 5, got rc=$rc" "$OUT"

OUT="$(run thread-for-session codex-sess-1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$OUT" = "thread-codex" ] \
  && pass || faild "Codex cursor should map to thread-codex (rc=$rc)" "$OUT"

# 1b. AMBIGUOUS session (two rows share one resume) MUST fail closed (exit 5, no
# thread printed): dispatching /compact to a guessed thread is catastrophic.
AMBHOME="$TMP/t3amb"; mkdir -p "$AMBHOME/userdata"
python3 - "$AMBHOME/userdata/state.sqlite" <<'PYAMB'
import sqlite3, sys, json
con = sqlite3.connect(sys.argv[1])
con.execute("""CREATE TABLE provider_session_runtime (
  thread_id TEXT PRIMARY KEY, provider_name TEXT NOT NULL, adapter_key TEXT NOT NULL,
  runtime_mode TEXT NOT NULL DEFAULT 'full-access', status TEXT NOT NULL,
  last_seen_at TEXT NOT NULL, resume_cursor_json TEXT, runtime_payload_json TEXT,
  provider_instance_id TEXT)""")
for tid in ("thread-dup-1", "thread-dup-2"):
    cur = json.dumps({"threadId": tid, "resume": "dupe-sess", "turnCount": 1})
    con.execute("INSERT INTO provider_session_runtime VALUES (?,?,?,?,?,?,?,?,?)",
                (tid, "claudeAgent", "claudeAgent", "auto", "running",
                 "2026-09-05T00:00:00.000Z", cur, None, "claudeAgent"))
con.commit(); con.close()
PYAMB
OUT="$(T3CODE_HOME="$AMBHOME" "$SCRIPT" thread-for-session dupe-sess 2>/dev/null)"; rc=$?
[ "$rc" -eq 5 ] && [ -z "$OUT" ] \
  && pass || faild "ambiguous session must fail closed (exit 5, no thread), got rc=$rc" "$OUT"

# --- 2. active-turn ------------------------------------------------------------
OUT="$(run active-turn thread-aaaa)"; rc=$?
[ "$rc" -eq 0 ] && [ "$OUT" = "turn-active-1" ] \
  && pass || faild "active-turn thread-aaaa should print turn id (rc=$rc)" "$OUT"

OUT="$(run active-turn thread-bbbb)"; rc=$?
[ "$rc" -eq 0 ] && [ "$OUT" = "null" ] \
  && pass || faild "active-turn thread-bbbb should print null (rc=$rc)" "$OUT"

OUT="$(run active-turn thread-zzzz)"; rc=$?
[ "$rc" -eq 5 ] && pass || faild "active-turn on absent thread should exit 5, got rc=$rc" "$OUT"

# --- 3. send: dispatch body shape ---------------------------------------------
OUT="$(run send thread-aaaa "/compact hi there")"; rc=$?
[ "$rc" -eq 0 ] && pass || faild "send should exit 0 (rc=$rc)" "$OUT"

# Inspect the last recorded dispatch body.
python3 - "$STUB_LOG" <<'PY'
import json, sys, re, os
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
disp = [r for r in recs if r["method"] == "POST" and r["path"].startswith("/api/orchestration/dispatch")]
assert disp, "no dispatch recorded"
body = json.loads(disp[-1]["body"])
uuid_re = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
iso_re = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")
checks = {
    "type==thread.turn.start": body.get("type") == "thread.turn.start",
    "commandId uuid": bool(uuid_re.match(body.get("commandId", ""))),
    "messageId uuid": bool(uuid_re.match(body.get("message", {}).get("messageId", ""))),
    "role==user": body.get("message", {}).get("role") == "user",
    "text matches": body.get("message", {}).get("text") == "/compact hi there",
    "attachments==[]": body.get("message", {}).get("attachments") == [],
    "createdAt iso": bool(iso_re.match(body.get("createdAt", ""))),
    "runtimeMode copied": body.get("runtimeMode") == "auto-accept-edits",
    "interactionMode default": body.get("interactionMode") == "default",
}
bad = [k for k, v in checks.items() if not v]
if bad:
    sys.stderr.write("dispatch body checks failed: %s\nbody=%s\n" % (bad, json.dumps(body)))
    sys.exit(1)
PY
[ $? -eq 0 ] && pass || faild "send dispatch body malformed (see above)"

OUT="$(run compact thread-aaaa)"; rc=$?
python3 - "$STUB_LOG" "$OUT" "$rc" <<'PYCOMPACT'
import json,sys,uuid
assert sys.argv[3]=="0"
uuid.UUID(sys.argv[2])
b=json.loads(json.loads(open(sys.argv[1]).readlines()[-1])["body"])
assert b["message"]["text"]=="/compact"
assert b["message"]["messageId"]==sys.argv[2]
assert b["message"]["attachments"]==[]
assert b["runtimeMode"]=="auto-accept-edits"
PYCOMPACT
[ $? -eq 0 ] && pass || faild "native compact must send bare command and return its messageId"

# V1 archive is unchanged by the V2 refusal (section 3e): one thread.archive POST.
OUT="$(run archive thread-aaaa)"; rc=$?
python3 - "$STUB_LOG" "$rc" <<'PYARCHIVE'
import json, sys, uuid
assert sys.argv[2] == "0", sys.argv[2]
r = json.loads(open(sys.argv[1]).readlines()[-1])
assert r["method"] == "POST" and r["path"].startswith("/api/orchestration/dispatch"), r
b = json.loads(r["body"])
assert set(b) == {"type", "commandId", "threadId"} and b["type"] == "thread.archive" and b["threadId"] == "thread-aaaa", b
uuid.UUID(b["commandId"])
PYARCHIVE
[ $? -eq 0 ] && pass || faild "V1 archive must POST exactly thread.archive {type, commandId, threadId}" "$OUT"

# --- 3b. shell, settle, settle-when-idle ---------------------------------------------
# The stub's scripted threads (SW_IDS) advance one step per shell read; /__reset rewinds.
export OPS_STATE_DIR="$TMP/state"
# The scripted threads advance one step per shell read, so the poll interval is
# most of this section's wall time: at the production floor of 1 s the suite
# spent about 80 s waiting. OPS_T3_POLL_FLOOR_MS (honoured from 50 to 1000 ms)
# lets these cases poll every 100 ms; the bounds cases below run at the
# production floor, and sw-hold, which inspects a waiter mid-wait, keeps 1 s.
export OPS_T3_POLL_SECONDS=0.1 OPS_T3_POLL_FLOOR_MS=100
WLOG="$OPS_STATE_DIR/t3-settle-when-idle.log"
reset_stub() { curl -s -X POST "$OPS_T3_BASE/__reset" >/dev/null; }
# settle_posts <thread>: how many thread.settle dispatches the stub received for it.
settle_posts() {
  python3 - "$STUB_LOG" "$1" <<'PY'
import json, sys
n = 0
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["method"] == "POST" and r["body"]:
        b = json.loads(r["body"])
        if b.get("type") == "thread.settle" and b.get("threadId") == sys.argv[2]:
            n += 1
print(n)
PY
}
# settle_read_n <thread>: the shell-read count at the moment of the first settle POST.
settle_read_n() {
  python3 - "$STUB_LOG" "$1" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["method"] == "POST" and r["body"]:
        b = json.loads(r["body"])
        if b.get("type") == "thread.settle" and b.get("threadId") == sys.argv[2]:
            print(r["n"]); sys.exit(0)
print(-1)
PY
}
# wait_log <thread> <regex> [seconds]: poll the waiter log for one of that thread's lines.
wait_log() {
  local tid="$1" re="$2" secs="${3:-25}" i
  for i in $(seq 1 $((secs * 10))); do
    grep -Eq "thread=$tid .*($re)" "$WLOG" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# shell: raw JSON, bearer auth, the live thread list.
reset_stub
OUT="$(run shell)"; rc=$?
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert any(t["id"]=="sw-idle" for t in d["threads"])' \
  && [ "$rc" -eq 0 ] && pass || faild "shell should print the shell JSON (rc=$rc)" "$OUT"

# settle: refuses every non-idle shape with exit 9 and sends NOTHING.
for spec in "sw-running:session is running" "sw-starting:session is starting" "sw-approval:waiting for approval" \
            "sw-input:waiting for an answer" "sw-bg:background work is working" "sw-mon:background work is monitoring"; do
  tid="${spec%%:*}"; why="${spec#*:}"
  reset_stub
  OUT="$(run settle "$tid")"; rc=$?
  if [ "$rc" -eq 9 ] && printf '%s' "$OUT" | grep -q "refusing to settle thread $tid" && printf '%s' "$OUT" | grep -q "$why" \
     && [ "$(settle_posts "$tid")" = 0 ]; then pass
  else faild "settle on $tid must refuse (exit 9, names '$why', no POST), got rc=$rc posts=$(settle_posts "$tid")" "$OUT"; fi
done
reset_stub
OUT="$(run settle sw-missing-thread)"; rc=$?
[ "$rc" -eq 5 ] && pass || faild "settle on an unknown or archived thread should exit 5, got rc=$rc" "$OUT"
reset_stub
OUT="$(run settle sw-archived)"; rc=$?
[ "$rc" -eq 5 ] && [ "$(settle_posts sw-archived)" = 0 ] && pass || faild "settle on an archived thread (absent from the shell) should exit 5 with no POST, got rc=$rc" "$OUT"
reset_stub
OUT="$(run settle sw-settled)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'already settled' && [ "$(settle_posts sw-settled)" = 0 ] \
  && pass || faild "settle on an already-settled thread should be a no-op (exit 0, no POST), got rc=$rc" "$OUT"
rc=0; "$SCRIPT" settle >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass || faild "settle with no id should exit 2, got rc=$rc"

# settle on an idle thread: exactly one POST, exactly {type, commandId, threadId}.
reset_stub
OUT="$(run settle sw-idle)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(settle_posts sw-idle)" = 1 ] && pass || faild "settle on an idle thread should POST once (rc=$rc posts=$(settle_posts sw-idle))" "$OUT"
python3 - "$STUB_LOG" <<'PY'
import json, re, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
disp = [json.loads(r["body"]) for r in recs if r["method"] == "POST" and r["body"] and json.loads(r["body"]).get("threadId") == "sw-idle"]
assert disp, "no settle recorded"
b = disp[-1]
assert set(b) == {"type", "commandId", "threadId"}, sorted(b)
assert b["type"] == "thread.settle" and b["threadId"] == "sw-idle"
assert re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", b["commandId"]), b["commandId"]
PY
[ $? -eq 0 ] && pass || faild "settle body is not exactly {type, commandId(uuid4), threadId}"

# DRY: settle reads, judges, prints the body, sends nothing; settle-when-idle starts no waiter.
reset_stub
BEFORE="$(settle_posts sw-other)"
OUT="$(OPS_T3_DRY=1 "$SCRIPT" settle sw-other 2>&1)"; rc=$?
printf '%s\n' "$OUT" >> "$ALLOUT"
[ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q '"type": "thread.settle"' && [ "$(settle_posts sw-other)" = "$BEFORE" ] \
  && pass || faild "dry settle should print the body and POST nothing (rc=$rc)" "$OUT"
OUT="$(OPS_T3_DRY=1 "$SCRIPT" settle sw-bg 2>&1)"; rc=$?
[ "$rc" -eq 9 ] && pass || faild "dry settle on a busy thread must still refuse (exit 9), got rc=$rc" "$OUT"
rm -f "$WLOG"; reset_stub
OUT="$(OPS_T3_DRY=1 "$SCRIPT" settle-when-idle sw-late --timeout 5 2>&1)"; rc=$?
printf '%s\n' "$OUT" >> "$ALLOUT"
[ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q '^DRY settle-when-idle thread=sw-late timeout=5' && [ ! -e "$WLOG" ] && [ "$(settle_posts sw-late)" = 0 ] \
  && pass || faild "dry settle-when-idle should print the plan and start no waiter (rc=$rc)" "$OUT"

# settle-when-idle: argument and thread checks happen in the foreground, before any waiter.
rm -f "$WLOG"
for bad in "" "sw-late --timeout" "sw-late --timeout 0" "sw-late --timeout abc" "sw-late --timeout -5" "sw-late --bogus" "sw-late sw-other"; do
  rc=0; "$SCRIPT" settle-when-idle $bad >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && pass || faild "settle-when-idle '$bad' should be a usage error (exit 2), got rc=$rc"
done
reset_stub
OUT="$(run settle-when-idle sw-archived)"; rc=$?
[ "$rc" -eq 5 ] && [ ! -e "$WLOG" ] && pass || faild "settle-when-idle on a thread that is not live should exit 5 and start no waiter (rc=$rc)" "$OUT"
OUT="$(run settle-when-idle sw-settled)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'already settled' && [ ! -e "$WLOG" ] \
  && pass || faild "settle-when-idle on a settled thread should be a no-op, no waiter (rc=$rc)" "$OUT"

# The waiter: detached, returns at once, settles only after the turn ends and only the one thread.
reset_stub
START=$SECONDS
OUT="$(OPS_T3_POLL_SECONDS=1 OPS_T3_POLL_FLOOR_MS='' run settle-when-idle sw-hold --timeout 30)"; rc=$?
ELAPSED=$((SECONDS - START))
[ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'waiter launched for thread sw-hold' && [ "$ELAPSED" -le 3 ] \
  && pass || faild "settle-when-idle should launch and return at once (rc=$rc, ${ELAPSED}s)" "$OUT"
wait_log sw-hold 'started' 5 && pass || faild "the waiter never logged its start"
WPID="$(grep -E 'thread=sw-hold started' "$WLOG" | sed -n 's/.* pid=\([0-9][0-9]*\) .*/\1/p' | head -1)"
if [ -n "$WPID" ] && kill -0 "$WPID" 2>/dev/null; then
  WSID="$(ps -o sid= -p "$WPID" 2>/dev/null | tr -d ' ')"
  [ "$WSID" = "$WPID" ] && pass || faild "the waiter should lead its own session (setsid), pid=$WPID sid=$WSID"
  if ps -eo args 2>/dev/null | grep -F "$SENTINEL" | grep -v grep >/dev/null; then faild "TOKEN LEAK: sentinel on a process command line while the waiter ran"; else pass; fi
else faild "the waiter process should still be running after the launcher returned (pid='$WPID')"; fi
[ "$(settle_posts sw-hold)" = 0 ] && pass || faild "the waiter settled sw-hold while its turn was still running"
wait_log sw-hold 'settled after' 30 && pass || faild "the waiter never settled sw-hold after its turn ended" "$(cat "$WLOG" 2>/dev/null)"
[ "$(settle_posts sw-hold)" = 1 ] && [ "$(settle_read_n sw-hold)" = 6 ] && pass \
  || faild "sw-hold: expected one settle at read 6 (two idle reads after the turn ended), got posts=$(settle_posts sw-hold) read_n=$(settle_read_n sw-hold)"

# Two consecutive idle reads, never one: idle, busy, idle, idle settles at the 5th read.
reset_stub
run settle-when-idle sw-flap --timeout 30 >/dev/null
wait_log sw-flap 'settled after' 30 && [ "$(settle_read_n sw-flap)" = 5 ] && [ "$(settle_posts sw-flap)" = 1 ] \
  && pass || faild "sw-flap: a single idle read between busy ones must not settle (want 1 POST at read 5, got read_n=$(settle_read_n sw-flap) posts=$(settle_posts sw-flap))" "$(cat "$WLOG" 2>/dev/null)"

# Never a different thread: sw-other and sw-idle are idle the whole time.
reset_stub
BEFORE_OTHER="$(settle_posts sw-other)"; BEFORE_IDLE="$(settle_posts sw-idle)"
run settle-when-idle sw-late --timeout 30 >/dev/null
wait_log sw-late 'settled after' 30 && pass || faild "the waiter never settled sw-late" "$(cat "$WLOG" 2>/dev/null)"
[ "$(settle_posts sw-late)" = 1 ] && [ "$(settle_read_n sw-late)" = 5 ] && pass || faild "sw-late: expected one settle at read 5, got posts=$(settle_posts sw-late) read_n=$(settle_read_n sw-late)"
[ "$(settle_posts sw-other)" = "$BEFORE_OTHER" ] && [ "$(settle_posts sw-idle)" = "$BEFORE_IDLE" ] \
  && pass || faild "the waiter for sw-late settled a different thread (other=$(settle_posts sw-other) idle=$(settle_posts sw-idle))"

# Background lanes keep it waiting: backgroundLiveness working clears after the 4th read.
reset_stub
run settle-when-idle sw-bgend --timeout 30 >/dev/null
wait_log sw-bgend 'settled after' 30 && [ "$(settle_read_n sw-bgend)" = 6 ] && [ "$(settle_posts sw-bgend)" = 1 ] \
  && pass || faild "sw-bgend: must wait for backgroundLiveness to clear, then settle at read 6 (got read_n=$(settle_read_n sw-bgend) posts=$(settle_posts sw-bgend))" "$(cat "$WLOG" 2>/dev/null)"

# A thread with permanent background work is never settled; the waiter times out.
for tid in sw-bg sw-mon sw-timeout; do
  reset_stub
  rm -f "$WLOG"
  run settle-when-idle "$tid" --timeout 2 >/dev/null
  if wait_log "$tid" 'timed out after 2s without settling' 15 && [ "$(settle_posts "$tid")" = 0 ]; then pass
  else faild "$tid: the waiter should time out without settling" "$(cat "$WLOG" 2>/dev/null)"; fi
done

# A new user message after launch ends the wait without settling.
reset_stub
run settle-when-idle sw-msg --timeout 30 >/dev/null
wait_log sw-msg 'new user message' 15 && [ "$(settle_posts sw-msg)" = 0 ] \
  && pass || faild "sw-msg: a new user message after launch must end the wait unsettled" "$(cat "$WLOG" 2>/dev/null)"

# Poll interval bounds: a number is clamped into 1..60 s (0.001 would near-spin the server,
# 3600 would overshoot the timeout by up to an hour); anything that is not a number falls
# back to 5 s. The waiter logs the interval it actually uses, in ms.
for spec in "0.001:1000" "0:1000" "1:1000" "12.5:12500" "60:60000" "61:60000" "3600:60000" \
            "abc:5000" "-1:5000" "1e3:5000" ":5000"; do
  bp="${spec%%:*}"; want="${spec##*:}"
  reset_stub; rm -f "$WLOG"
  if [ -z "$bp" ]; then OPS_T3_POLL_FLOOR_MS="" OPS_T3_POLL_SECONDS="" "$SCRIPT" settle-when-idle sw-timeout --timeout 1 >/dev/null 2>&1
  else OPS_T3_POLL_FLOOR_MS="" OPS_T3_POLL_SECONDS="$bp" "$SCRIPT" settle-when-idle sw-timeout --timeout 1 >/dev/null 2>&1; fi
  wait_log sw-timeout 'timed out after 1s' 20 && grep -Eq "thread=sw-timeout started .*poll=${want}ms " "$WLOG" \
    && pass || faild "OPS_T3_POLL_SECONDS='$bp' should run at ${want}ms" "$(cat "$WLOG" 2>/dev/null)"
done

# The test-only floor: honoured from 50 to 1000 ms, anything else keeps the 1 s floor,
# so a stray value can neither spin the server nor raise the floor.
for spec in "100:0.001:100" "50:0:50" "49:0.001:1000" "1001:0.001:1000" "abc:0.001:1000" \
            ":0.001:1000" "100:7:7000"; do
  fl="${spec%%:*}"; rest="${spec#*:}"; bp="${rest%%:*}"; want="${rest##*:}"
  reset_stub; rm -f "$WLOG"
  OPS_T3_POLL_FLOOR_MS="$fl" OPS_T3_POLL_SECONDS="$bp" "$SCRIPT" settle-when-idle sw-timeout --timeout 1 >/dev/null 2>&1
  wait_log sw-timeout 'timed out after 1s' 20 && grep -Eq "thread=sw-timeout started .*poll=${want}ms " "$WLOG" \
    && pass || faild "OPS_T3_POLL_FLOOR_MS='$fl' with OPS_T3_POLL_SECONDS='$bp' should run at ${want}ms" "$(cat "$WLOG" 2>/dev/null)"
done

# Timeout overshoot: the deadline is honoured even when the poll is longer than the time left.
# A thread that is idle on every read, --timeout 1, poll 3 s: the old loop slept a full poll,
# read idle twice, and settled at about 3 s, past its deadline. It must exit unsettled.
reset_stub; rm -f "$WLOG"
T_START=$SECONDS
OPS_T3_POLL_SECONDS=3 "$SCRIPT" settle-when-idle sw-edge --timeout 1 >/dev/null 2>&1
if wait_log sw-edge 'timed out after 1s' 10 && [ "$(settle_posts sw-edge)" = 0 ] && ! grep -Eq 'thread=sw-edge .*settled after' "$WLOG"; then pass
else faild "sw-edge: --timeout 1 with a 3 s poll must exit unsettled, never settle past the deadline" "$(cat "$WLOG" 2>/dev/null) posts=$(settle_posts sw-edge)"; fi
# A long poll must not hold the waiter past its timeout either: --timeout 2 with a 60 s poll
# (the ceiling) on a busy thread ends at about 2 s, not after a 60 s nap.
reset_stub; rm -f "$WLOG"
T_START=$SECONDS
OPS_T3_POLL_SECONDS=60 "$SCRIPT" settle-when-idle sw-timeout --timeout 2 >/dev/null 2>&1
if wait_log sw-timeout 'timed out after 2s' 8 && [ $((SECONDS - T_START)) -le 6 ]; then pass
else faild "sw-timeout: a 60 s poll must not outlast --timeout 2 (took $((SECONDS - T_START))s)" "$(cat "$WLOG" 2>/dev/null)"; fi

# A thread that disappears from the shell (archived or deleted) while the waiter waits ends
# the wait, unsettled, with that said in the log (exit 5 path).
reset_stub; rm -f "$WLOG"
run settle-when-idle sw-vanish --timeout 30 >/dev/null
if wait_log sw-vanish 'thread is gone or archived; not settling' 15 && [ "$(settle_posts sw-vanish)" = 0 ] && ! grep -Eq 'thread=sw-vanish .*timed out' "$WLOG"; then pass
else faild "sw-vanish: a thread that leaves the shell must end the wait unsettled, at once" "$(cat "$WLOG" 2>/dev/null)"; fi

# http() carries a hard cap, so a hung server cannot hang a caller (a session that settles
# itself runs the launcher inside its last tool call). The cap is overridable for the tests.
reset_stub
curl -s -X POST "$OPS_T3_BASE/__hang/8" >/dev/null
H_START=$SECONDS
OUT="$(OPS_T3_HTTP_TIMEOUT=2 "$SCRIPT" shell 2>&1)"; rc=$?
H_ELAPSED=$((SECONDS - H_START))
printf '%s\n' "$OUT" >> "$ALLOUT"
[ "$rc" -eq 4 ] && [ "$H_ELAPSED" -le 5 ] && printf '%s' "$OUT" | grep -q 'transport error' \
  && pass || faild "a hung server must fail the call within the cap (rc=$rc, ${H_ELAPSED}s, cap 2s)" "$OUT"
# The default cap is 30 s (and a connect cap of 5 s): read it off the curl that is running.
curl -s -X POST "$OPS_T3_BASE/__hang/4" >/dev/null
"$SCRIPT" shell >/dev/null 2>&1 & HPID=$!
CURL_ARGS=""
for _ in $(seq 1 30); do
  # Only this run's curl: other suites (and other copies of this one) run curl too.
  CURL_ARGS="$(ps -eo args 2>/dev/null | grep -F 'curl ' | grep -F -- "127.0.0.1:$PORT/" | grep -v grep | head -1)"
  [ -n "$CURL_ARGS" ] && break; sleep 0.1
done
wait "$HPID" 2>/dev/null
printf '%s' "$CURL_ARGS" | grep -q -- '--max-time 30' && printf '%s' "$CURL_ARGS" | grep -q -- '--connect-timeout 5' \
  && pass || faild "the default curl cap should be --max-time 30 --connect-timeout 5" "$CURL_ARGS"
if printf '%s' "$CURL_ARGS" | grep -qF "$SENTINEL"; then faild "TOKEN LEAK: sentinel on the curl command line"; else pass; fi
reset_stub

# A server that rejects the settle does not end the wait or fake a success.
reset_stub
run settle-when-idle sw-error --timeout 2 >/dev/null
wait_log sw-error 'timed out after 2s' 15 && grep -Eq 'thread=sw-error .*settle was rejected' "$WLOG" && ! grep -Eq 'thread=sw-error .*settled after' "$WLOG" \
  && pass || faild "sw-error: a rejected settle must be logged and never reported as settled" "$(grep 'thread=sw-error' "$WLOG" 2>/dev/null)"

# Every settle the suite caused went to a thread it was supposed to settle.
python3 - "$STUB_LOG" <<'PY'
import json, sys
allowed = {"sw-idle", "sw-hold", "sw-flap", "sw-late", "sw-bgend", "sw-error"}
bad = set()
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r["method"] == "POST" and r["body"]:
        b = json.loads(r["body"])
        if b.get("type") == "thread.settle" and b["threadId"] not in allowed:
            bad.add(b["threadId"])
if bad:
    sys.stderr.write("unexpected settles: %s\n" % sorted(bad)); sys.exit(1)
PY
[ $? -eq 0 ] && pass || faild "a settle reached a thread that must never be settled (busy, background, pending, or another thread)"
# The waiter log is operator-readable and must never carry the token.
if grep -qF "$SENTINEL" "$WLOG" 2>/dev/null; then faild "TOKEN LEAK: sentinel in the waiter log"; else pass; fi
cat "$WLOG" >> "$ALLOUT" 2>/dev/null

# --- 3c. dual mode: the protocol probe, and fail loud, against the V1 stub --------------
# Every server subcommand reads GET /.well-known/t3/environment once per invocation.
set_env() { curl -s -X POST "$OPS_T3_BASE/__env/$1" >/dev/null; }
set_snapshot() { curl -s -X POST "$OPS_T3_BASE/__snapshot/$1" >/dev/null; }
# reqs_since <log> <line>: "METHOD PATH proto" for each request recorded after <line>.
reqs_since() {
  tail -n +"$(( $2 + 1 ))" "$1" | python3 -c '
import json, sys
for l in sys.stdin:
    r = json.loads(l); print(r["method"], r["path"], r.get("proto"))'
}
# split_run <args...>: run the helper with stdout to $OUT and stderr to $ERR (both swept
# for the token), so a case can assert that a refusal printed nothing on stdout.
split_run() {
  OUT="$("$SCRIPT" "$@" 2>"$TMP/split.err")"; SRC=$?
  ERR="$(cat "$TMP/split.err")"
  printf '%s\n%s\n' "$OUT" "$ERR" >> "$ALLOUT"
  return $SRC
}
V1_EXPECT="$(printf 'GET /.well-known/t3/environment None\nGET /api/orchestration/snapshot None')"
for mode in v1 absent 404; do
  reset_stub; set_env "$mode"; B="$(wc -l < "$STUB_LOG")"
  split_run snapshot; rc=$?
  REQS="$(reqs_since "$STUB_LOG" "$B")"
  if [ "$rc" -eq 0 ] && [ -z "$ERR" ] && [ "$REQS" = "$V1_EXPECT" ] \
     && printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "t3ApiCompat" not in d and d["threads"][0]["id"] == "thread-aaaa"'; then pass
  else faild "probe answer '$mode' must keep the unchanged V1 path (one probe, the V1 snapshot, no protocol header, nothing on stderr), rc=$rc" "$REQS | $ERR"; fi
done
# Answers that cannot say which protocol the server speaks fail closed, before any other
# request: HTML or a non-object exits 6, any version but the integers 1 and 2 exits 8.
for spec in "html:6:text/html" "list:6:not an object" "v3:8:orchestrationProtocolVersion 3;" \
            "bool:8:orchestrationProtocolVersion True;" "string2:8:orchestrationProtocolVersion '2';" \
            "null:8:orchestrationProtocolVersion None;"; do
  mode="${spec%%:*}"; rest="${spec#*:}"; want="${rest%%:*}"; why="${rest#*:}"
  reset_stub; set_env "$mode"; B="$(wc -l < "$STUB_LOG")"
  split_run snapshot; rc=$?
  REQS="$(reqs_since "$STUB_LOG" "$B")"
  if [ "$rc" -eq "$want" ] && [ -z "$OUT" ] && [ "$(printf '%s\n' "$ERR" | wc -l)" -eq 1 ] \
     && printf '%s' "$ERR" | grep -qF -- "$why" && [ "$REQS" = "GET /.well-known/t3/environment None" ]; then pass
  else faild "probe answer '$mode' must exit $want with one line naming '$why' and make no other request, got rc=$rc" "$ERR | $REQS"; fi
done
# A bad probe also stops a write before it is built.
reset_stub; set_env v3; B="$(wc -l < "$STUB_LOG")"
split_run send thread-aaaa "hello"; rc=$?
[ "$rc" -eq 8 ] && [ "$(reqs_since "$STUB_LOG" "$B")" = "GET /.well-known/t3/environment None" ] \
  && pass || faild "send behind an unsupported protocol must exit 8 with no POST, got rc=$rc" "$ERR"
# Fail loud: the V1 snapshot answering the SPA HTML with 200 (what T3 0.1.0 serves for the
# removed route) used to exit 0; any non-JSON or non-object answer now exits 6, one line,
# nothing on stdout. active-turn on that page used to die with a traceback (exit 1).
for spec in "html:answered text/html, not JSON" "badjson:a body that is not JSON (15 bytes" \
            "empty:a body that is not JSON (0 bytes" "array:JSON that is not an object (list)"; do
  mode="${spec%%:*}"; why="${spec#*:}"
  reset_stub; set_snapshot "$mode"
  split_run snapshot; rc=$?
  if [ "$rc" -eq 6 ] && [ -z "$OUT" ] && [ "$(printf '%s\n' "$ERR" | wc -l)" -eq 1 ] \
     && printf '%s' "$ERR" | grep -qF -- "$why" && printf '%s' "$ERR" | grep -qF 'GET /api/orchestration/snapshot (HTTP 200)'; then pass
  else faild "snapshot answering '$mode' must exit 6 with one line naming '$why', got rc=$rc" "out=$OUT err=$ERR"; fi
done
reset_stub; set_snapshot html
split_run active-turn thread-aaaa; rc=$?
[ "$rc" -eq 6 ] && [ -z "$OUT" ] && ! printf '%s' "$ERR" | grep -q Traceback \
  && pass || faild "active-turn on an HTML snapshot must exit 6 without a traceback, got rc=$rc" "$ERR"
reset_stub; set_snapshot html; B="$(wc -l < "$STUB_LOG")"
split_run send thread-aaaa "hello"; rc=$?
[ "$rc" -eq 6 ] && [ "$(reqs_since "$STUB_LOG" "$B")" = "$(printf 'GET /.well-known/t3/environment None\nGET /api/orchestration/snapshot None')" ] \
  && pass || faild "send whose runtimeMode read gets HTML must exit 6 before any POST, got rc=$rc" "$ERR | $(reqs_since "$STUB_LOG" "$B")"
reset_stub
# V1 requests never carry the protocol-2 header (V1 behavior unchanged).
python3 - "$STUB_LOG" <<'PY'
import json, sys
bad = [r["path"] for r in map(json.loads, open(sys.argv[1])) if r.get("proto") is not None]
if bad:
    sys.stderr.write("V1 requests carried x-t3-orchestration-protocol: %s\n" % bad[:5]); sys.exit(1)
PY
[ $? -eq 0 ] && pass || faild "a request to the V1 stub carried the protocol-2 header"

# --- 3d. protocol 2 (T3 0.1.0): V2 fixtures, V1-shaped output, refusals -------------------
FX="$HERE/fixtures/t3-v2"
for f in environment.json shell.json bounded.json; do
  [ -s "$FX/$f" ] || { echo "V2 fixture missing: $FX/$f" >&2; exit 1; }
done
# The V2 stub answers like the live 0.1.0 server where the client depends on it: the
# environment route is public; orchestration routes need the bearer, then the
# x-t3-orchestration-protocol: 2 header (else a bare 400 with an empty body); thread ids
# must be percent-encoded with quote(id, safe='') (a raw id is a 404); the removed V1
# routes (/snapshot, /dispatch) and anything unknown answer the web app's HTML with 200;
# there is no HTTP write route at all (every POST is a 404). It records every request
# like the V1 stub: the auth scheme and a boolean, never the token.
STUB2_LOG="$TMP/requests-v2.jsonl"; : > "$STUB2_LOG"
PORT2F="$TMP/port2"
cat > "$TMP/stub_v2.py" <<'PY'
import datetime, http.server, json, re, sys, urllib.parse
LOG, PORTF, FX = sys.argv[1:4]
ENV = json.load(open(FX + "/environment.json"))
SHELL = json.load(open(FX + "/shell.json"))
BOUNDED = json.load(open(FX + "/bounded.json"))
NOW_RE = re.compile(r"^@now-(\d+)s@$")
SPA = "<!doctype html><html><head><title>T3 Code</title></head><body><div id=\"root\"></div></body></html>"
MODE = {"shell": "json"}

def live(o):
    # Rewrite "@now-Ns@" to a UTC time N seconds before this answer.
    if isinstance(o, dict):
        return {k: live(v) for k, v in o.items()}
    if isinstance(o, list):
        return [live(v) for v in o]
    if isinstance(o, str):
        m = NOW_RE.match(o)
        if m:
            t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=int(m.group(1)))
            return t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (t.microsecond // 1000)
    return o

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _record(self, body=""):
        auth = self.headers.get("Authorization", "")
        rec = {"method": self.command, "path": self.path, "auth_present": bool(auth),
               "auth_scheme": auth.split(" ", 1)[0] if auth else "",
               "proto": self.headers.get("x-t3-orchestration-protocol"), "body": body}
        with open(LOG, "a") as f:
            f.write(json.dumps(rec) + "\n")
    def _raw(self, code, ctype, text):
        b = text.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)
    def _json(self, obj, code=200):
        self._raw(code, "application/json", json.dumps(obj))
    def do_GET(self):
        self._record()
        path = self.path.split("?", 1)[0]
        if path == "/.well-known/t3/environment":
            return self._json(ENV)
        if path.startswith("/api/orchestration/"):
            if not self.headers.get("Authorization", "").startswith("Bearer "):
                return self._json({"_tag": "EnvironmentAuthInvalidError", "code": "auth_invalid"}, 401)
            if path in ("/api/orchestration/snapshot", "/api/orchestration/dispatch"):
                return self._raw(200, "text/html; charset=utf-8", SPA)
            if self.headers.get("x-t3-orchestration-protocol") != "2":
                return self._raw(400, "text/plain", "")
            if path == "/api/orchestration/shell":
                if MODE["shell"] == "html":
                    return self._raw(200, "text/html; charset=utf-8", SPA)
                if MODE["shell"] == "nothreads":
                    return self._json({"schemaVersion": 1, "projects": [], "snapshotSequence": 1})
                return self._json(live(SHELL))
            m = re.match(r"^/api/orchestration/threads/([^/]+)/bounded$", path)
            if m:
                for tid, body in BOUNDED.items():
                    if m.group(1) == urllib.parse.quote(tid, safe=""):
                        return self._json(live(body))
                return self._json({"_tag": "EnvironmentResourceNotFoundError", "code": "not_found",
                                   "reason": "thread_not_found"}, 404)
        return self._raw(200, "text/html; charset=utf-8", SPA)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode() if n else ""
        if self.path.startswith("/__shell/"):
            # Test control channel: unrecorded, unauthenticated.
            MODE["shell"] = self.path.rsplit("/", 1)[1]
            return self._json({"ok": True})
        self._record(body)
        self._json({"_tag": "EnvironmentResourceNotFoundError", "code": "not_found"}, 404)

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
with open(PORTF, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$TMP/stub_v2.py" "$STUB2_LOG" "$PORT2F" "$FX" &
STUB2_PID=$!
for _ in $(seq 1 50); do [ -s "$PORT2F" ] && break; sleep 0.1; done
[ -s "$PORT2F" ] || { echo "V2 stub failed to start" >&2; exit 1; }
V2BASE="http://127.0.0.1:$(cat "$PORT2F")"
V2HOME="$TMP/t3v2"; mkdir -p "$V2HOME/userdata"
# v2 <args...>: run the helper against the V2 stub; stdout to $OUT, stderr to $ERR.
v2() {
  OUT="$(OPS_T3_BASE="$V2BASE" T3CODE_HOME="$V2HOME" "$SCRIPT" "$@" 2>"$TMP/v2.err")"; SRC=$?
  ERR="$(cat "$TMP/v2.err")"
  printf '%s\n%s\n' "$OUT" "$ERR" >> "$ALLOUT"
  return $SRC
}
v2_mark() { wc -l < "$STUB2_LOG"; }
v2_posts() { python3 -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if json.loads(l)["method"] == "POST"))' "$STUB2_LOG"; }
CHILD_ID='thread:provider:claudeAgent:native-thread:a%3Ab:child-1'
CHILD_BUSY='thread:provider:claudeAgent:native-thread:busy-child'
ENVREQ="GET /.well-known/t3/environment None"

# The dual-mode switch: protocol 2 reads the shell with the header, never /snapshot.
B="$(v2_mark)"; v2 shell; rc=$?
[ "$rc" -eq 0 ] && [ -z "$ERR" ] && [ "$(reqs_since "$STUB2_LOG" "$B")" = "$(printf '%s\nGET /api/orchestration/shell 2' "$ENVREQ")" ] \
  && pass || faild "V2 shell must probe once, then GET the shell with x-t3-orchestration-protocol: 2 (rc=$rc)" "$ERR | $(reqs_since "$STUB2_LOG" "$B")"
printf '%s' "$OUT" > "$TMP/v2-shell.out"
B="$(v2_mark)"; v2 snapshot; rc=$?
[ "$rc" -eq 0 ] && [ "$(reqs_since "$STUB2_LOG" "$B")" = "$(printf '%s\nGET /api/orchestration/shell 2' "$ENVREQ")" ] \
  && pass || faild "V2 snapshot must be built from the shell, never the removed /snapshot route (rc=$rc)" "$ERR"
printf '%s' "$OUT" > "$TMP/v2-snapshot.out"

# V1-shape translation of shell and snapshot: one row per root thread, every V2 key kept.
python3 - "$TMP/v2-shell.out" "$TMP/v2-snapshot.out" "$FX/shell.json" "$CHILD_ID" "$CHILD_BUSY" <<'PY'
import json, sys
shell, snap, fixture = (json.load(open(p)) for p in sys.argv[1:4])
child_id, child_busy = sys.argv[4:6]
fails = []
def check(cond, what):
    if not cond:
        fails.append(what)
check(shell.get("t3ApiCompat") == "v1-shell-from-v2-shell", "shell marker")
check(snap.get("t3ApiCompat") == "v1-snapshot-from-v2-shell", "snapshot marker")
check(shell.get("orchestrationProtocolVersion") == 2, "protocol key")
check([p["id"] for p in shell["projects"]] == ["proj-fixture-1"], "projects pass through")
check(shell["archivedThreads"] == [] and shell["schemaVersion"] == 1 and shell["snapshotSequence"] == 1000, "envelope keys kept")
roots = [t["id"] for t in fixture["threads"] if (t["lineage"] or {}).get("relationshipToParent") != "subagent"]
check([t["id"] for t in shell["threads"]] == roots, "threads are exactly the root threads in order")
check(sorted(t["id"] for t in shell["subagentThreads"]) == sorted([child_id, child_busy]), "subagent children kept aside")
check(child_id not in [t["id"] for t in shell["threads"]], "subagent child filtered out of threads")
by_id = {t["id"]: t for t in shell["threads"] + shell["subagentThreads"]}
for t in fixture["threads"]:
    out = by_id[t["id"]]
    lost = [k for k in t if k not in out or (k not in ("latestUserMessageAt", "latestUserAuthoredMessageAt", "latestRunRequestedAt") and out[k] != t[k])]
    check(not lost, "%s lost or changed V2 keys %s" % (t["id"], lost))
check("historyOrigin" not in by_id["v2-completed-idle"] and by_id["v2-idle-imported"]["historyOrigin"] == "v1_import",
      "optional historyOrigin stays absent where absent")
# id: (idle, session.status, activeTurnId, latestTurn.state, backgroundLiveness, approvals, input, reason fragment)
want = {
    "v2-idle-imported":         (True,  "idle",        None,     None,          None,         False, False, None),
    "v2-completed-idle":        (True,  "ready",       None,     "completed",   None,         False, False, None),
    "v2-completed-bg-subagent": (False, "ready",       None,     "completed",   "working",    False, False, "background work is pending (1 task: subagent)"),
    "v2-completed-bg-command":  (False, "ready",       None,     "completed",   "working",    False, False, "background work is pending (2 tasks: command)"),
    "v2-pr-watch":              (False, "ready",       None,     "completed",   "monitoring", False, False, "a pull-request watch is active (1 monitor task)"),
    "v2-running":               (False, "running",     "run-r1", "running",     None,         False, False, "a run is running"),
    "v2-question":              (False, "running",     "run-q1", "running",     None,         False, True,  "a question is waiting for an answer"),
    "v2-approval":              (False, "running",     "run-w1", "running",     None,         True,  False, "a request is waiting for approval (command_approval)"),
    "v2-queued":                (False, "starting",    "run-qd", "running",     None,         False, False, "the latest run is queued"),
    "v2-failed-limit":          (True,  "error",       None,     "error",       None,         False, False, None),
    "v2-fresh-message":         (False, "starting",    None,     "completed",   None,         False, False, "has no run yet"),
    "v2-adopted-message":       (True,  "ready",       None,     "completed",   None,         False, False, None),
    "v2-old-message":           (True,  "idle",        None,     None,          None,         False, False, None),
    "v2-unknown-status":        (False, "running",     "run-u1", "running",     None,         False, False, "is not one this client knows"),
    "v2-parent-busy-child":     (False, "ready",       None,     "completed",   "working",    False, False, "subagent thread %s is busy (a run is running)" % child_busy),
    child_id:                   (True,  "idle",        None,     None,          None,         False, False, None),
    child_busy:                 (False, "running",     "run-child", "running",  None,         False, False, "a run is running"),
}
for tid, (idle, st, atid, lts, bgl, appr, inp, frag) in want.items():
    t = by_id[tid]
    got = (t["idleVerdict"]["idle"], t["session"]["status"], t["session"]["activeTurnId"],
           (t["latestTurn"] or {}).get("state"), t["backgroundLiveness"], t["hasPendingApprovals"], t["hasPendingUserInput"])
    check(got == (idle, st, atid, lts, bgl, appr, inp), "%s: got %s" % (tid, got))
    reasons = t["idleVerdict"]["reasons"]
    check((not reasons) if frag is None else any(frag in r for r in reasons), "%s reasons %s" % (tid, reasons))
s = by_id["v2-failed-limit"]["session"]
check(s["providerInstanceId"] == "claudeAgent_claude_fixture" and s["runtimeMode"] == "full-access"
      and s["lastError"] == "fixture usage limit" and s["threadId"] == "v2-failed-limit", "session carries the top-level fields")
lt = by_id["v2-completed-idle"]["latestTurn"]
check(lt == {"turnId": "run-ci", "state": "completed", "requestedAt": "2026-10-01T11:00:00.000Z",
             "startedAt": "2026-10-01T11:00:00.000Z", "completedAt": "2026-10-01T12:00:00.000Z"}, "latestTurn fields %s" % lt)
sv = shell["serverIdleVerdict"]
busy = {"v2-completed-bg-subagent", "v2-completed-bg-command", "v2-pr-watch", "v2-running", "v2-question", "v2-approval",
        "v2-queued", "v2-fresh-message", "v2-unknown-status", "v2-parent-busy-child", child_busy}
check(sv["idle"] is False and set(sv["busyThreadIds"]) == busy and sv["threadsChecked"] == 17, "serverIdleVerdict %s" % sv)
check([(t["id"], t["idleVerdict"]["idle"]) for t in snap["threads"]] == [(t["id"], t["idleVerdict"]["idle"]) for t in shell["threads"]],
      "snapshot carries the same threads and verdicts as shell")
# What the existing callers read, replayed on this output (field names as in the callers):
# compact-cycle t3_poll, a dashboard's working set, a broadcast's error enumeration, a model readout.
def poll(t):
    s = t.get("session") or {}
    a = s.get("activeTurnId"); e = s.get("lastError")
    if a is None and s.get("status") in ("starting", "running"):
        a = "provider-busy"
    return (a if a is not None else "null") + "\t" + (e if e else "")
snap_by = {t["id"]: t for t in snap["threads"]}
check(poll(snap_by["v2-completed-idle"]) == "null\t", "compact-cycle poll idle")
check(poll(snap_by["v2-running"]) == "run-r1\t", "compact-cycle poll running")
check(poll(snap_by["v2-fresh-message"]) == "provider-busy\t", "compact-cycle poll unadopted message")
check(poll(snap_by["v2-failed-limit"]) == "null\tfixture usage limit", "compact-cycle poll error text")
working = [t["id"] for t in snap["threads"] if (t.get("session") or {}).get("activeTurnId") is not None]
check(child_busy not in working and "v2-running" in working, "the working set excludes subagent children")
errored = [t["id"] for t in snap["threads"] if (t.get("session") or {}).get("providerInstanceId") == "claudeAgent_claude_fixture"
           and (t.get("latestTurn") or {}).get("state") == "error" and (t.get("latestTurn") or {}).get("completedAt")]
check(errored == ["v2-failed-limit"], "errored enumeration %s" % errored)
check(all((t.get("modelSelection") or {}).get("model") == "fixture-model" for t in snap["threads"]), "modelSelection.model")
if fails:
    sys.stderr.write("V2 shape checks failed:\n  " + "\n  ".join(fails) + "\n"); sys.exit(1)
PY
[ $? -eq 0 ] && pass || faild "V2 shell/snapshot V1-shape translation (see above)"

# active-turn: the derived activeTurnId of a root thread; children and unknown ids exit 5.
for spec in "v2-running:run-r1" "v2-approval:run-w1" "v2-completed-idle:null" "v2-completed-bg-subagent:null"; do
  tid="${spec%%:*}"; want="${spec#*:}"
  v2 active-turn "$tid"; rc=$?
  [ "$rc" -eq 0 ] && [ "$OUT" = "$want" ] && pass || faild "V2 active-turn $tid should print $want (rc=$rc)" "$OUT $ERR"
done
for tid in "$CHILD_ID" no-such-thread; do
  v2 active-turn "$tid"; rc=$?
  [ "$rc" -eq 5 ] && [ -z "$OUT" ] && pass || faild "V2 active-turn on '$tid' (subagent child or unknown) should exit 5, got rc=$rc" "$OUT"
done

# thread: /bounded with a quoted id, the shell laid over it, V1-shaped.
B="$(v2_mark)"; v2 thread v2-completed-bg-subagent 1; rc=$?
REQS="$(reqs_since "$STUB2_LOG" "$B")"
printf '%s' "$OUT" > "$TMP/v2-thread.out"
[ "$rc" -eq 0 ] && [ "$REQS" = "$(printf '%s\nGET /api/orchestration/threads/v2-completed-bg-subagent/bounded 2\nGET /api/orchestration/shell 2' "$ENVREQ")" ] \
  && pass || faild "V2 thread must probe once, GET /bounded (turnLimit ignored), then the shell (rc=$rc)" "$REQS | $ERR"
B="$(v2_mark)"; v2 thread "$CHILD_ID"; rc=$?
REQS="$(reqs_since "$STUB2_LOG" "$B")"
[ "$rc" -eq 0 ] && printf '%s' "$REQS" | grep -qxF "GET /api/orchestration/threads/thread%3Aprovider%3AclaudeAgent%3Anative-thread%3Aa%253Ab%3Achild-1/bounded 2" \
  && printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["thread"]["id"] == sys.argv[1]' "$CHILD_ID" \
  && pass || faild "V2 thread must percent-encode ':' and '%' in the id (quote(id, safe=''))" "$REQS | $ERR"
v2 thread v2-archived; rc=$?
printf '%s' "$OUT" > "$TMP/v2-archived.out"
[ "$rc" -eq 0 ] && pass || faild "V2 thread for an archived thread (absent from the shell) should succeed (rc=$rc)" "$ERR"
v2 thread no-such-thread; rc=$?
[ "$rc" -eq 4 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q 'HTTP 404' \
  && pass || faild "V2 thread on an unknown id should exit 4 on the 404 (rc=$rc)" "$ERR"
python3 - "$TMP/v2-thread.out" "$TMP/v2-archived.out" <<'PY'
import json, sys
d, a = (json.load(open(p)) for p in sys.argv[1:3])
fails = []
def check(cond, what):
    if not cond:
        fails.append(what)
t = d["thread"]
check(d["t3ApiCompat"] == "v1-thread-from-v2-bounded" and d["orchestrationProtocolVersion"] == 2, "markers")
check(d["snapshotSequence"] == 1001 and d["page"]["hasMoreHistory"] is True and d["page"]["historyCursor"] == "cursor-v2-completed-bg-subagent", "page")
check(t["id"] == "v2-completed-bg-subagent" and t["runStateSource"] == "shell", "run state from the shell")
check(t["lineage"]["rootThreadId"] == "v2-completed-bg-subagent" and "pendingBackgroundTasks" in t, "projection and shell keys both present")
check(t["latestTurn"]["turnId"] == "run-a" and t["latestTurn"]["state"] == "completed" and t["latestTurn"]["assistantMessageId"] == "m-a2",
      "latestTurn %s" % t["latestTurn"])
check(t["session"]["status"] == "ready" and t["session"]["activeTurnId"] is None, "session")
check(t["backgroundLiveness"] == "working" and t["idleVerdict"]["idle"] is False, "background work from the shell")
check([(m["id"], m["turnId"]) for m in t["messages"]] == [("m-imported", None), ("m-u1", "run-a"), ("m-a1", "run-a"), ("m-a2", "run-a")],
      "messages turnId = runId")
check([r["id"] for r in t["runs"]] == ["run-old", "run-a"] and "activities" not in t, "runs kept, no invented activities")
# A caller that reads a thread's last error and nudges it reads exactly these keys.
lt = t.get("latestTurn") or {}
pick = next((m for m in t.get("messages") or [] if m.get("id") == lt.get("assistantMessageId")), None)
check((pick or {}).get("text") == "fixture final reply", "t3_error_head picks the run's final assistant message")
x = a["thread"]
check(x["runStateSource"] == "bounded-runs" and x["archivedAt"], "archived thread derives run state from runs")
check(x["latestTurn"]["turnId"] == "run-x2" and x["latestTurn"]["state"] == "error" and x["latestTurn"]["assistantMessageId"] == "m-x2",
      "archived latestTurn %s" % x["latestTurn"])
check(x["session"]["status"] == "error" and x["session"]["activeTurnId"] is None, "archived session %s" % x["session"])
check(x["idleVerdict"]["idle"] is False and any("background work is unknown" in r for r in x["idleVerdict"]["reasons"])
      and x["backgroundLiveness"] == "working", "archived: background work unknown reads busy")
if fails:
    sys.stderr.write("V2 thread checks failed:\n  " + "\n  ".join(fails) + "\n"); sys.exit(1)
PY
[ $? -eq 0 ] && pass || faild "V2 thread V1-shape translation (see above)"

# Fail loud on V2 too: a shell answering HTML, or JSON without a threads list, exits 6.
for spec in "html:answered text/html, not JSON" "nothreads:the shell answer has no threads list"; do
  mode="${spec%%:*}"; why="${spec#*:}"
  curl -s -X POST "$V2BASE/__shell/$mode" >/dev/null
  for sub in shell snapshot "active-turn v2-running"; do
    v2 $sub; rc=$?
    [ "$rc" -eq 6 ] && [ -z "$OUT" ] && [ "$(printf '%s\n' "$ERR" | wc -l)" -eq 1 ] && printf '%s' "$ERR" | grep -qF -- "$why" \
      && pass || faild "V2 $sub with a '$mode' shell must exit 6 naming '$why', got rc=$rc" "out=$OUT err=$ERR"
  done
  curl -s -X POST "$V2BASE/__shell/json" >/dev/null
done

# dispatch (a raw command) is the one write with no V2 form: exit 7 on protocol 2, DRY or
# not, after the probe and nothing else. The other writes are pinned in section 3e.
mkdir -p "$OPS_STATE_DIR"; rm -f "$WLOG"
POSTS_BEFORE="$(v2_posts)"
for dry in 0 1; do
  B="$(v2_mark)"
  OPS_T3_DRY="$dry" v2 dispatch '{}'; rc=$?
  if [ "$rc" -eq 7 ] && [ -z "$OUT" ] && [ "$(printf '%s\n' "$ERR" | wc -l)" -eq 1 ] \
     && printf '%s' "$ERR" | grep -qF "t3-api: dispatch refused on this T3 server (orchestration protocol 2): " \
     && printf '%s' "$ERR" | grep -qF "V2 rejects at decode" && printf '%s' "$ERR" | grep -qF "use send, compact, stop or settle" \
     && [ "$(reqs_since "$STUB2_LOG" "$B")" = "$ENVREQ" ]; then pass
  else faild "V2 dispatch (DRY=$dry) must exit 7 with the one-line refusal after the probe alone, got rc=$rc" "out=$OUT err=$ERR reqs=$(reqs_since "$STUB2_LOG" "$B")"; fi
done
[ "$(v2_posts)" = "$POSTS_BEFORE" ] && [ ! -e "$WLOG" ] && pass || faild "a V2 refusal POSTed or started a waiter (posts $POSTS_BEFORE -> $(v2_posts))"
# Usage errors still come first (exit 2, no request).
B="$(v2_mark)"; v2 settle-when-idle v2-completed-idle --timeout abc; rc=$?
[ "$rc" -eq 2 ] && [ "$(v2_mark)" = "$B" ] && pass || faild "V2 settle-when-idle usage error should exit 2 before any request, got rc=$rc"
# No V2 write ever POSTs: V2 has no HTTP write route (the slice-1 stub 404s every POST).
B="$(v2_mark)"; OPS_T3_DRY=1 v2 send v2-completed-bg-subagent hello; rc=$?
[ "$rc" -eq 0 ] && [ "$(v2_posts)" = "$POSTS_BEFORE" ] && printf '%s' "$OUT" | head -1 | grep -qx 'WS orchestration.dispatchCommand' \
  && pass || faild "a dry V2 send must print the WebSocket command and POST nothing, got rc=$rc" "out=$OUT err=$ERR"
rm -f "$WLOG"

# thread-for-session on V2: statev2.sqlite only, built on the live 0.1.0 columns. A V1
# state.sqlite with a mapping sits beside it and must never be read.
python3 - "$V2HOME/userdata/statev2.sqlite" "$V2HOME/userdata/state.sqlite" <<'PY'
import json, sqlite3, sys
v2, v1 = sys.argv[1:3]
con = sqlite3.connect(v2)
con.execute("""CREATE TABLE orchestration_v2_projection_provider_threads (
  provider_thread_id TEXT PRIMARY KEY, thread_id TEXT, owner_node_id TEXT, provider TEXT NOT NULL,
  provider_session_id TEXT, status TEXT NOT NULL, first_run_ordinal INTEGER, last_run_ordinal INTEGER,
  updated_at TEXT NOT NULL, payload_json TEXT NOT NULL, driver TEXT, provider_instance_id TEXT)""")
con.execute("CREATE INDEX orchestration_v2_projection_provider_threads_owner_idx ON orchestration_v2_projection_provider_threads(owner_node_id)")
con.execute("""CREATE TABLE orchestration_v2_projection_threads (
  thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL, default_provider TEXT NOT NULL,
  runtime_mode TEXT NOT NULL, interaction_mode TEXT NOT NULL, active_provider_thread_id TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT,
  payload_json TEXT NOT NULL, provider_instance_id TEXT)""")
def thread(tid, active):
    con.execute("INSERT INTO orchestration_v2_projection_threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (tid, "proj-fixture-1", "fixture " + tid, "claudeAgent", "full-access", "default", active,
                 "2026-10-01T11:00:00.000Z", "2026-10-01T12:00:00.000Z", None, None, "{}", "claudeAgent"))
def pthread(ptid, tid, native, owner=None, payload=None):
    p = payload if payload is not None else json.dumps({"id": ptid, "nativeThreadRef": {"driver": "claudeAgent", "nativeId": native, "strength": "strong"}})
    con.execute("INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (ptid, tid, owner, "claudeAgent", "ps-" + ptid, "idle", 1, 1, "2026-10-01T12:00:00.000Z", p, "claudeAgent", "claudeAgent"))
thread("v2-completed-idle", "pt-one"); pthread("pt-one", "v2-completed-idle", "sess-one")
# Two provider threads of one thread; the active one wins.
thread("v2-two-rows", "pt-two-new"); pthread("pt-two-old", "v2-two-rows", "sess-two"); pthread("pt-two-new", "v2-two-rows", "sess-two")
# Two threads; only X's row is its thread's active provider thread.
thread("v2-x", "pt-x"); thread("v2-y", "pt-y-other")
pthread("pt-x", "v2-x", "sess-xy"); pthread("pt-y", "v2-y", "sess-xy")
# Ambiguous: both rows active for their own threads, or neither.
thread("v2-p", "pt-p"); thread("v2-q", "pt-q"); pthread("pt-p", "v2-p", "sess-both"); pthread("pt-q", "v2-q", "sess-both")
thread("v2-m", "pt-m-other"); thread("v2-n", None); pthread("pt-m", "v2-m", "sess-none"); pthread("pt-n", "v2-n", "sess-none")
# A subagent's provider thread (owner_node_id set) is never the thread's own session.
pthread("pt-sub", "v2-completed-bg-subagent", "sess-subagent", owner="node-sub-1")
# One row with no thread id.
pthread("pt-orphan", None, "sess-orphan")
con.commit(); con.close()
con = sqlite3.connect(v1)
con.execute("""CREATE TABLE provider_session_runtime (
  thread_id TEXT PRIMARY KEY, provider_name TEXT NOT NULL, adapter_key TEXT NOT NULL,
  runtime_mode TEXT NOT NULL DEFAULT 'full-access', status TEXT NOT NULL,
  last_seen_at TEXT NOT NULL, resume_cursor_json TEXT, runtime_payload_json TEXT,
  provider_instance_id TEXT)""")
con.execute("INSERT INTO provider_session_runtime VALUES (?,?,?,?,?,?,?,?,?)",
            ("thread-v1-only", "claudeAgent", "claudeAgent", "full-access", "ready", "2026-10-01T00:00:00Z",
             json.dumps({"resume": "v1-only-sess"}), None, "claudeAgent"))
con.commit(); con.close()
PY
for spec in "sess-one:0:v2-completed-idle:" "sess-two:0:v2-two-rows:" "sess-xy:0:v2-x:" \
            "sess-both:5::refusing to guess" "sess-none:5::refusing to guess" "sess-orphan:5::no thread id" \
            "sess-subagent:5::" "no-such-session:5::" "v1-only-sess:5::"; do
  sid="${spec%%:*}"; rest="${spec#*:}"; want="${rest%%:*}"; rest="${rest#*:}"; tid="${rest%%:*}"; why="${rest#*:}"
  v2 thread-for-session "$sid"; rc=$?
  if [ "$rc" -eq "$want" ] && [ "$OUT" = "$tid" ] && { if [ -n "$why" ]; then printf '%s' "$ERR" | grep -qF "t3-api: session $sid " && printf '%s' "$ERR" | grep -qF "$why"; else [ -z "$ERR" ]; fi; }; then pass
  else faild "V2 thread-for-session $sid should exit $want printing '$tid'${why:+ and naming '$why'}, got rc=$rc" "out=$OUT err=$ERR"; fi
done
# No V2 db on a V2 server: exit 4, said plainly, and the V1 table beside it is not read.
NOV2HOME="$TMP/t3v2-nov2"; mkdir -p "$NOV2HOME/userdata"; cp "$V2HOME/userdata/state.sqlite" "$NOV2HOME/userdata/"
OUT="$(OPS_T3_BASE="$V2BASE" T3CODE_HOME="$NOV2HOME" "$SCRIPT" thread-for-session v1-only-sess 2>"$TMP/v2.err")"; rc=$?
ERR="$(cat "$TMP/v2.err")"
[ "$rc" -eq 4 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -qF 'not falling back to the V1 table' \
  && pass || faild "V2 thread-for-session without statev2.sqlite must exit 4 and never read the V1 table, got rc=$rc" "out=$OUT err=$ERR"
# A malformed payload fails the lookup loudly (exit 4) instead of being skipped.
BADHOME="$TMP/t3v2-bad"; mkdir -p "$BADHOME/userdata"; cp "$V2HOME/userdata/statev2.sqlite" "$BADHOME/userdata/"
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", ("pt-bad","v2-bad",None,"claudeAgent",None,"idle",1,1,"2026-10-01T12:00:00Z","{not json","claudeAgent","claudeAgent")); c.commit()' "$BADHOME/userdata/statev2.sqlite"
OUT="$(OPS_T3_BASE="$V2BASE" T3CODE_HOME="$BADHOME" "$SCRIPT" thread-for-session sess-one 2>"$TMP/v2.err")"; rc=$?
ERR="$(cat "$TMP/v2.err")"
[ "$rc" -eq 4 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -qF 'cannot read the V2 state db' \
  && pass || faild "V2 thread-for-session over a malformed payload must exit 4, got rc=$rc" "out=$OUT err=$ERR"

# The pure functions, pinned with a fixed clock (no stub, no network). -B: no bytecode
# cache in the repo (-I ignores PYTHONDONTWRITEBYTECODE), so a mutation run can never
# reuse a stale .pyc.
python3 -I -B - "$HERE/../lib" <<'PY'
import copy, datetime, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import t3_api_v2 as m
NOW = datetime.datetime(2026, 10, 17, 12, 0, 0, tzinfo=datetime.timezone.utc)
def ago(s):
    return (NOW - datetime.timedelta(seconds=s)).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
OLD = "2026-10-01T12:00:00.000Z"
def th(**over):
    t = {"id": "t", "status": "idle", "activityRunStatus": None, "activeRunId": None, "pendingRuntimeRequest": None,
         "pendingBackgroundTasks": [], "latestUserMessageAt": OLD, "latestUserAuthoredMessageAt": OLD,
         "latestRunRequestedAt": None, "lineage": {"parentThreadId": None, "relationshipToParent": None, "rootThreadId": "t"}}
    for k, v in over.items():
        if v is m:
            t.pop(k, None)
        else:
            t[k] = v
    return t
ABSENT = m
fails = []
def busy(t, frag, children=()):
    r = m.idle_verdict(t, NOW, children)
    if not r or (frag and not any(frag in x for x in r)):
        fails.append("expected busy (%s) for %s, got %s" % (frag, {k: v for k, v in t.items() if k != "lineage"}, r))
def idle(t, children=()):
    r = m.idle_verdict(t, NOW, children)
    if r:
        fails.append("expected idle for %s, got %s" % ({k: v for k, v in t.items() if k != "lineage"}, r))
idle(th())
for st in m.TERMINAL_RUN_STATUSES:
    idle(th(status=st, latestRunId="r", latestRunRequestedAt=OLD))           # completed with no tasks is idle
for st in m.ACTIVE_RUN_STATUSES:
    busy(th(status=st, latestRunId="r"), "the latest run is " + st)
for ars in ("preparing", "starting", "running", "waiting"):
    busy(th(status="completed", activityRunStatus=ars), "a run is " + ars)
busy(th(status="completed", activeRunId="r1"), "a run is active")
busy(th(status="paused-by-a-future-server"), "is not one this client knows")
busy(th(status=ABSENT), "is not one this client knows")
busy(th(pendingRuntimeRequest={"id": "q", "kind": "user_input"}), "a question is waiting for an answer")
busy(th(pendingRuntimeRequest={"id": "q", "kind": "auth_refresh"}), "waiting for approval (auth_refresh)")
busy(th(pendingRuntimeRequest="garbled"), "waiting for approval (unknown kind)")
# 'completed' with tasks is V1 ready + backgroundLiveness: busy, every kind counts.
for kind in ("subagent", "command", "background_task", "unknown"):
    busy(th(status="completed", pendingBackgroundTasks=[{"taskId": "x", "kind": kind}]), "background work is pending (1 task: %s)" % kind)
busy(th(status="completed", pendingBackgroundTasks=[{"taskId": "x"}]), "background work is pending (1 task: unknown)")
# PR watch: a lone monitor task is busy for settle, and says it is the PR watch.
busy(th(status="completed", pendingBackgroundTasks=[{"taskId": "w", "kind": "monitor"}]), "a pull-request watch is active (1 monitor task)")
busy(th(status="completed", pendingBackgroundTasks=[{"kind": "monitor"}, {"kind": "monitor"}]), "(2 monitor tasks)")
busy(th(status="completed", pendingBackgroundTasks=[{"kind": "monitor"}, {"kind": "command"}]), "background work is pending (2 tasks: command, monitor)")
busy(th(pendingBackgroundTasks=ABSENT), "background work is unknown")
busy(th(pendingBackgroundTasks={"kind": "command"}), "background work is unknown")
# A user message under 120 s old that no run has adopted.
busy(th(status="completed", latestUserMessageAt=ago(30), latestRunRequestedAt=OLD), "a user message from 30s ago has no run yet")
busy(th(status="completed", latestUserMessageAt=OLD, latestUserAuthoredMessageAt=ago(30)), "from 30s ago")
busy(th(latestUserMessageAt=ago(119)), "from 119s ago")
idle(th(latestUserMessageAt=ago(120), latestUserAuthoredMessageAt=None))
idle(th(status="completed", latestUserMessageAt=ago(30), latestUserAuthoredMessageAt=None, latestRunRequestedAt=ago(29)))
idle(th(status="completed", latestUserMessageAt=ago(30), latestUserAuthoredMessageAt=None, latestRunRequestedAt=ago(30)))
busy(th(status="completed", latestUserMessageAt=ago(30), latestUserAuthoredMessageAt=None, latestRunRequestedAt=ago(31)), "no run yet")
busy(th(latestUserMessageAt=(NOW + datetime.timedelta(seconds=90)).isoformat()), "no run yet")       # future-dated
busy(th(latestUserMessageAt="yesterday"), "unreadable latestUserMessageAt")
busy(th(latestUserMessageAt="2026-10-17T11:59:30"), "unreadable latestUserMessageAt")                  # no timezone
busy(th(latestUserMessageAt=ago(30), latestUserAuthoredMessageAt=None, latestRunRequestedAt="soon"), "unreadable latestRunRequestedAt")
idle(th(latestUserMessageAt=None, latestUserAuthoredMessageAt=None))
idle(th(latestUserMessageAt=ABSENT, latestUserAuthoredMessageAt=ABSENT))
# Children: a busy subagent child keeps its parent busy; an idle one does not.
kid_busy = th(id="k1", status="running", activityRunStatus="running", activeRunId="rk")
kid_idle = th(id="k2")
busy(th(status="completed"), "subagent thread k1 is busy (a run is running)", [kid_busy])
idle(th(status="completed"), [kid_idle])
# Pure: no mutation of the input, same answer twice.
t0 = th(status="completed", pendingBackgroundTasks=[{"kind": "monitor"}])
snap = copy.deepcopy(t0)
r1 = m.idle_verdict(t0, NOW); r2 = m.idle_verdict(t0, NOW); v = m.v1_thread(t0, NOW)
if t0 != snap or r1 != r2 or v["idleVerdict"]["reasons"] != r1:
    fails.append("idle_verdict or v1_thread is not pure")
if (v["backgroundLiveness"], v["session"]["status"]) != ("monitoring", "ready"):
    fails.append("PR-watch V1 shape %s" % ((v["backgroundLiveness"], v["session"]["status"]),))
# The session id picker.
P = m.pick_session_thread
cases = [
    ([], (None, "")),
    ([("t1", "p1", "p9")], ("t1", "")),
    ([("t1", "p1", "p1"), ("t1", "p0", "p1")], ("t1", "")),
    ([("t1", "p1", "p1"), ("t2", "p2", "p8")], ("t1", "")),
]
for rows, want in cases:
    if P(rows) != want:
        fails.append("pick_session_thread %s -> %s, want %s" % (rows, P(rows), want))
for rows in ([("t1", "p1", "p1"), ("t2", "p2", "p2")], [("t1", "p1", "p8"), ("t2", "p2", None)], [(None, "p1", "p1")], [("  ", "p1", None)]):
    if P(rows)[0] is not None or not P(rows)[1]:
        fails.append("pick_session_thread must refuse %s, got %s" % (rows, P(rows)))
# The protocol reader and the fail-loud check.
for env, want in (({}, 1), ({"orchestrationProtocolVersion": 1}, 1), ({"orchestrationProtocolVersion": 2}, 2)):
    if m.protocol_version(env) != want:
        fails.append("protocol_version %s" % env)
for env in ({"orchestrationProtocolVersion": 3}, {"orchestrationProtocolVersion": True}, {"orchestrationProtocolVersion": "2"},
            {"orchestrationProtocolVersion": None}, {"orchestrationProtocolVersion": 2.0}):
    try:
        m.protocol_version(env); fails.append("protocol_version must refuse %s" % env)
    except m.UnsupportedProtocol:
        pass
for raw, ct in ((b"<!doctype html>", "text/html; charset=utf-8"), (b'{"a": 1}', "text/html"), (b"", "application/json"),
                (b"[]", "application/json"), (b"\xff\xfe", "application/json"), (b"null", "")):
    try:
        m.check_json_body(raw, ct, "GET /x"); fails.append("check_json_body must refuse %r %r" % (raw, ct))
    except m.ShapeError:
        pass
if m.check_json_body(b'{"ok": true}', "application/json; charset=utf-8", "GET /x") != {"ok": True}:
    fails.append("check_json_body must accept a JSON object")
if fails:
    sys.stderr.write("pure-function checks failed:\n  " + "\n  ".join(fails) + "\n"); sys.exit(1)
PY
[ $? -eq 0 ] && pass || faild "V2 idle verdict, session picker, protocol reader and fail-loud tables (see above)"

# Every V2 request carried the bearer; every orchestration GET carried the protocol header.
python3 - "$STUB2_LOG" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert recs, "no V2 requests recorded"
bad = [r["path"] for r in recs if not (r["auth_present"] and r["auth_scheme"] == "Bearer")]
nohdr = [r["path"] for r in recs if r["path"].startswith("/api/orchestration/") and r.get("proto") != "2"]
probe_hdr = [r["path"] for r in recs if r["path"] == "/.well-known/t3/environment" and r.get("proto") is not None]
if bad or nohdr or probe_hdr:
    sys.stderr.write("V2 header checks: no bearer %s; no protocol header %s; probe with header %s\n" % (bad[:3], nohdr[:3], probe_hdr[:3]))
    sys.exit(1)
PY
[ $? -eq 0 ] && pass || faild "a V2 request lacked the bearer or the protocol header"
if grep -qF "$SENTINEL" "$STUB2_LOG"; then faild "TOKEN LEAK: sentinel in the V2 request log"; else pass; fi

# --- 3e. protocol 2 writes: WebSocket RPC against a stub replaying recorded frames ------------
WFX="$FX/write/scratch-states.json"; WSFX="$FX/ws"
[ -s "$WFX" ] && [ -d "$WSFX" ] || { echo "V2 write fixtures missing under $FX" >&2; exit 1; }
STUB3_LOG="$TMP/requests-v2w.jsonl"; : > "$STUB3_LOG"
PORT3F="$TMP/port3"
cat > "$TMP/stub_v2w.py" <<'PY'
# HTTP plus the /ws WebSocket on one loopback port, like T3 0.1.0. Thread states are the
# scratch server's real shell entries and /bounded answers (@TID@ becomes the scenario id);
# Exit frames are the recorded frames with the request's requestId, commandId and
# threadId put in. Records requests as JSON lines: never the token, only whether the
# bearer matched the expected token file.
import base64, copy, hashlib, http.server, json, socket, struct, sys, threading, time, urllib.parse
LOG, PORTF, FX, TOKENF = sys.argv[1:5]
TOKEN = open(TOKENF).read().strip()
ENV = json.load(open(FX + "/environment.json"))
STATES = json.load(open(FX + "/write/scratch-states.json"))["states"]
def frame(name):
    return json.load(open(FX + "/ws/" + name))
FR = {k: frame(v) for k, v in {
    "message": "a18-dispatch-message-queue-after-active.json", "settle": "a40-settle-ok-after-cancel.json",
    "archive": "a47-dispatch-thread-archive.json", "interrupt": "b07-run-interrupt-holdQueue-true.json",
    "fail": "b03-settle-refused-active-run.json", "fail-queued": "a37-settle-refused-queued-message.json",
    "rejected": "a42-settle-rejected-commandid-retried.json", "fail-interrupt": "a54-dispatch-run-interrupt-bogus-run.json",
    "die": "a27-dispatch-malformed-payload.json", "gate-401": "a04-ws-gate-bad-bearer.json",
    "gate-426": "a01-ws-gate-missing-protocol-param.json", "cancel": "a39-queued-run-cancel.json"}.items()}
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LOCK = threading.Lock()
STATE = {}
def reset():
    STATE.update(n=0, mode="ok", settled=set(), archived=set(), settles={}, drops=0, cancelled=set())
reset()
BASES = {"wt-idle": "idle", "wt-running": "running", "wt-approval": "approval", "wt-stale": "stale-request",
         "wt-held": "held-queue", "wt-bg": "idle", "wt-archived": "archived", "wt-compact-ok": "compact-ok",
         "wt-compact-empty": "compact-empty", "wt-compact-nocomp": "compact-ok", "wt-compact-pending": "compact-ok",
         "wt-compact-weird": "compact-ok", "wt-unknown-run": "idle", "ws-idle": "idle", "ws-hold": "running",
         "ws-held": "held-queue", "ws-harness": "idle", "ws-operator": "idle", "ws-refuse1": "idle",
         "ws-refuse3": "idle", "ws-stale": "stale-request", "wq-held": "held-queue", "wq-started": "held-queue",
         "wq-nomsg": "held-queue"}
def scenario(tid, n):
    """(shell entry or None, bounded or None) for thread tid at shell read n."""
    base = BASES.get(tid)
    if base is None:
        return None, None
    if tid == "ws-hold" and n > 3:
        base = "idle"
    s = copy.deepcopy(STATES[base])
    entry, bounded = s["entry"], s["bounded"]
    p = bounded["projection"]
    if tid == "wt-bg":
        entry["pendingBackgroundTasks"] = [{"taskId": "task-1", "kind": "subagent", "description": "fixture subagent task"}]
    if tid in ("wt-compact-nocomp", "wt-compact-pending", "wt-compact-weird"):
        run = [r for r in p["runs"] if r["userMessageId"] == s["compactMessageId"]][0]
        for key in ("turnItems", "visibleTurnItems"):
            p[key] = [i for i in p.get(key, []) if (i.get("item") or i).get("type") != "compaction"]
        run["status"] = {"wt-compact-nocomp": "completed", "wt-compact-pending": "running",
                         "wt-compact-weird": "paused-by-a-future-server"}[tid]
    if tid == "wt-unknown-run":
        p["runs"][-1]["status"] = "paused-by-a-future-server"
    if tid.startswith("wq-"):
        # queued-cancel: run 2 (queued, its message a harness send) stands for the broadcast's
        # held pause; run 3 is a person's message queued behind it (creationSource web), which
        # nothing here may cancel. wq-started: the pause's run already started. wq-nomsg:
        # /bounded does not show the queued run's message.
        own = p["runs"][1]
        mine = [m for m in p["messages"] if m["id"] == own["userMessageId"]][0]
        user_run = dict(own, id=own["id"].replace(":ordinal:2", ":ordinal:3"), ordinal=3, queuePosition=2,
                        userMessageId="@TID@-user-queued")
        p["runs"].append(user_run)
        p["messages"].append(dict(mine, id="@TID@-user-queued", runId=user_run["id"], text="typed while the queue was held",
                                  creationSource="web"))
        if tid == "wq-started":
            own["status"], own["queuePosition"] = "running", None
        if tid == "wq-nomsg":
            p["messages"] = [m for m in p["messages"] if m["id"] != own["userMessageId"]]
        for r in p["runs"]:
            if (tid, r["id"].replace("@TID@", tid)) in STATE["cancelled"]:
                r["status"], r["queuePosition"] = "cancelled", None
    if tid.startswith("ws-"):
        # The waiter compares user-message stamps across reads, and these states were captured
        # from different scratch threads; one fixed past stamp keeps a state switch from
        # looking like a new message. Past dates also keep the 120 s unadopted-message rule out.
        for m in p["messages"]:
            if m["role"] == "user":
                m["createdAt"] = m["updatedAt"] = "2026-10-01T12:00:00.000Z"
        entry["latestUserMessageAt"] = entry["latestUserAuthoredMessageAt"] = "2026-10-01T12:00:00.000Z"
    if tid in ("ws-harness", "ws-operator") and n >= 3:
        last = [m for m in p["messages"] if m["role"] == "user"][-1]
        late = dict(last, id="@TID@-late", text="a later message", createdAt="2026-10-01T12:30:00.000Z",
                    updatedAt="2026-10-01T12:30:00.000Z", creationSource="server" if tid == "ws-harness" else "web")
        p["messages"].append(late)
        entry["latestUserMessageAt"] = entry["latestUserAuthoredMessageAt"] = late["createdAt"]
    if tid in STATE["archived"]:
        entry = None
        p["thread"]["archivedAt"] = "2026-10-17T19:40:00.000Z"
    if entry is not None and tid in STATE["settled"]:
        entry["settledOverride"] = "settled"; entry["settledAt"] = "2026-10-17T19:40:00.000Z"
    out = json.loads(json.dumps([entry, bounded]).replace("@TID@", tid))
    return out[0], out[1]
def record(rec):
    rec["n"] = STATE["n"]
    with open(LOG, "a") as f:
        f.write(json.dumps(rec) + "\n")
def exit_from(name, payload, rid):
    d = FR[name]
    text = json.dumps([x for x in d["response"] if x.get("_tag") == "Exit"][0])
    req = d["request"]["payload"]
    for key in ("commandId", "threadId"):
        if req.get(key) and payload.get(key):
            text = text.replace(req[key], payload[key])
    ex = json.loads(text)
    ex["requestId"] = rid
    return ex
def ws_frame(opcode, data, fin=True):
    head = bytes([(0x80 if fin else 0) | opcode])
    n = len(data)
    head += bytes([n]) if n < 126 else (bytes([126]) + struct.pack(">H", n) if n < 65536 else bytes([127]) + struct.pack(">Q", n))
    return head + data
def read_frame(rf):
    h = rf.read(2)
    if len(h) < 2:
        return None
    opcode, masked, n = h[0] & 0x0F, h[1] & 0x80, h[1] & 0x7F
    if n == 126:
        n = struct.unpack(">H", rf.read(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", rf.read(8))[0]
    key = rf.read(4) if masked else b""
    data = rf.read(n)
    if masked:
        data = bytes(b ^ key[i % 4] for i, b in enumerate(data))
    return opcode, bool(masked), data
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def _raw(self, code, ctype, text):
        b = text.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _json(self, obj, code=200):
        self._raw(code, "application/json", json.dumps(obj))
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        if n:
            self.rfile.read(n)
        with LOCK:
            if self.path == "/__reset":
                reset()
            elif self.path.startswith("/__ws/"):
                STATE["mode"] = self.path.rsplit("/", 1)[1]; STATE["drops"] = 0
            else:
                record({"kind": "http", "method": "POST", "path": self.path})
                return self._json({"code": "not_found"}, 404)
        self._json({"ok": True})
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        auth = self.headers.get("Authorization", "")
        if path == "/ws":
            return self.websocket(auth)
        with LOCK:
            record({"kind": "http", "method": "GET", "path": self.path, "proto": self.headers.get("x-t3-orchestration-protocol"),
                    "auth_ok": auth == "Bearer " + TOKEN})
            if path == "/.well-known/t3/environment":
                return self._json(ENV)
            if auth != "Bearer " + TOKEN:
                return self._json({"code": "auth_invalid"}, 401)
            if self.headers.get("x-t3-orchestration-protocol") != "2":
                return self._raw(400, "text/plain", "")
            if path == "/api/orchestration/shell":
                STATE["n"] += 1
                threads = [e for e in (scenario(t, STATE["n"])[0] for t in BASES) if e is not None]
                return self._json({"schemaVersion": 1, "snapshotSequence": 2000 + STATE["n"], "archivedThreads": [],
                                   "projects": [{"id": "proj-write-lane", "title": "write-lane", "workspaceRoot": "/tmp/wl"}],
                                   "threads": threads})
            if path.startswith("/api/orchestration/threads/") and path.endswith("/bounded"):
                tid = urllib.parse.unquote(path[len("/api/orchestration/threads/"):-len("/bounded")])
                b = scenario(tid, STATE["n"])[1]
                if b is None:
                    return self._json({"code": "not_found", "reason": "thread_not_found"}, 404)
                return self._json(b)
        self._raw(200, "text/html; charset=utf-8", "<!doctype html><html></html>")
    def websocket(self, auth):
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        with LOCK:
            mode = STATE["mode"]
            record({"kind": "upgrade", "auth_ok": auth == "Bearer " + TOKEN, "protocol": q.get("orchestrationProtocol")})
        if mode == "upgrade401" or auth != "Bearer " + TOKEN:
            self.close_connection = True
            return self._raw(401, "application/json", FR["gate-401"]["response"]["body"])
        if q.get("orchestrationProtocol") != ["2"]:
            self.close_connection = True
            return self._raw(426, "application/json", FR["gate-426"]["response"]["body"])
        accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"] + GUID).encode()).digest()).decode()
        self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          "Sec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        self.close_connection = True
        while True:
            fr = read_frame(self.rfile)
            if fr is None:
                return
            opcode, masked, data = fr
            if opcode == 0x8:
                try:
                    self.wfile.write(ws_frame(0x8, data[:2]))
                except OSError:
                    pass
                return
            if opcode != 0x1:
                continue
            msg = json.loads(data)
            if msg.get("_tag") == "Ping":
                self.wfile.write(ws_frame(0x1, b'{"_tag":"Pong"}'))
                continue
            if msg.get("_tag") != "Request":
                continue
            if self.answer(msg, masked) == "close":
                try:
                    self.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                return
    def answer(self, msg, masked):
        payload, rid = msg.get("payload") or {}, msg.get("id")
        with LOCK:
            mode = STATE["mode"]
            record({"kind": "ws", "tag": msg.get("tag"), "masked": masked, "payload": payload})
            if mode == "drop-always" or (mode == "drop-once" and STATE["drops"] == 0):
                STATE["drops"] += 1
                return "close"
            if mode == "silent":
                return "hang"
            kind = payload.get("type")
            tid = payload.get("threadId")
            if mode in ("fail", "rejected", "die"):
                ex = exit_from(mode, payload, rid)
            elif kind == "thread.settle":
                count = STATE["settles"].get(tid, 0) + 1
                STATE["settles"][tid] = count
                if tid == "ws-refuse3" or (tid == "ws-refuse1" and count == 1):
                    ex = exit_from("fail-queued", payload, rid)
                else:
                    STATE["settled"].add(tid)
                    ex = exit_from("settle", payload, rid)
            elif kind == "thread.archive":
                STATE["archived"].add(tid)
                ex = exit_from("archive", payload, rid)
            elif kind == "run.interrupt":
                ex = exit_from("interrupt", payload, rid)
            elif kind == "queued-run.cancel":
                STATE["cancelled"].add((tid, payload.get("runId")))
                ex = exit_from("cancel", payload, rid)
            elif kind == "message.dispatch":
                ex = exit_from("message", payload, rid)
            else:
                ex = {"_tag": "Exit", "requestId": rid, "exit": {"_tag": "Failure", "cause": [{"_tag": "Die", "defect": "Expected { readonly \"type\": \"thread.create\", ... }"}]}}
        text = json.dumps(ex).encode()
        if mode == "ping":
            self.wfile.write(ws_frame(0x9, b"hb"))
        if mode == "frag":
            half = len(text) // 2
            self.wfile.write(ws_frame(0x1, text[:half], fin=False) + ws_frame(0x0, text[half:]))
        elif mode == "batch":
            self.wfile.write(ws_frame(0x1, json.dumps([{"_tag": "Pong"}, {"_tag": "Exit", "requestId": "other", "exit": {"_tag": "Success", "value": None}}, ex]).encode()))
        else:
            self.wfile.write(ws_frame(0x1, text))
        return "ok"
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
with open(PORTF, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$TMP/stub_v2w.py" "$STUB3_LOG" "$PORT3F" "$FX" "$TOKENF" &
STUB3_PID=$!
for _ in $(seq 1 50); do [ -s "$PORT3F" ] && break; sleep 0.1; done
[ -s "$PORT3F" ] || { echo "V2 write stub failed to start" >&2; exit 1; }
V3BASE="http://127.0.0.1:$(cat "$PORT3F")"
# w3 <args...>: the helper against the write stub; stdout to $OUT, stderr to $ERR.
w3() {
  OUT="$(OPS_T3_BASE="$V3BASE" T3CODE_HOME="$V2HOME" "$SCRIPT" "$@" 2>"$TMP/w3.err")"; SRC=$?
  ERR="$(cat "$TMP/w3.err")"
  printf '%s\n%s\n' "$OUT" "$ERR" >> "$ALLOUT"
  return $SRC
}
w3_reset() { curl -s -X POST "$V3BASE/__reset" >/dev/null; }
w3_mode() { curl -s -X POST "$V3BASE/__ws/$1" >/dev/null; }
w3_mark() { wc -l < "$STUB3_LOG"; }
# ws_since <mark>: one line per WebSocket request after <mark>: "type commandId threadId".
ws_since() {
  tail -n +"$(( $1 + 1 ))" "$STUB3_LOG" | python3 -c '
import json, sys
for l in sys.stdin:
    r = json.loads(l)
    if r["kind"] == "ws":
        p = r["payload"]; print(p.get("type"), p.get("commandId"), p.get("threadId"))'
}
ws_count() { ws_since "$1" | grep -c . ; }
# ws_payloads <mark>: the JSON payloads after <mark>, one per line.
ws_payloads() {
  tail -n +"$(( $1 + 1 ))" "$STUB3_LOG" | python3 -c '
import json, sys
for l in sys.stdin:
    r = json.loads(l)
    if r["kind"] == "ws":
        print(json.dumps(r["payload"]))'
}
CMID_OK="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["states"]["compact-ok"]["compactMessageId"])' "$WFX")"
CMID_EMPTY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["states"]["compact-empty"]["compactMessageId"])' "$WFX")"

# send: one message.dispatch with exactly the V2 shape; ids from the text hash and a fresh key.
w3_reset; B="$(w3_mark)"
w3 send wt-idle "hello from the suite"; rc=$?
ws_payloads "$B" > "$TMP/w3-send.json"
python3 - "$TMP/w3-send.json" "$OUT" "$rc" <<'PY'
import hashlib, json, re, sys
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
out, rc = sys.argv[2], sys.argv[3]
assert rc == "0", "rc %s" % rc
assert json.loads(out) == {"sequence": 569}, out           # a18's real Success value
assert len(lines) == 1, lines
p = lines[0]
h = hashlib.sha256("hello from the suite".encode()).hexdigest()[:12]
assert set(p) == {"type", "commandId", "threadId", "messageId", "text", "attachments", "createdBy", "creationSource", "dispatchMode"}, sorted(p)
assert p["type"] == "message.dispatch" and p["threadId"] == "wt-idle" and p["text"] == "hello from the suite"
assert p["dispatchMode"] == {"type": "queue_after_active"} and "deliveryIntent" not in p
assert p["createdBy"] == "user" and p["creationSource"] == "server" and p["attachments"] == []
m = re.match(r"^t3-api:send:wt-idle:([0-9a-f]{12}):(n[0-9a-f]{16})$", p["commandId"])
assert m and m.group(1) == h, p["commandId"]
assert p["messageId"] == "t3-api:msg:wt-idle:%s:%s" % (h, m.group(2)), p["messageId"]
PY
[ $? -eq 0 ] && pass || faild "V2 send: one message.dispatch, queue_after_active, no deliveryIntent, ids from the text hash" "out=$OUT err=$ERR"
# The reads before the send: the probe and /bounded (archived guard), with the protocol header.
[ "$(tail -n +"$((B + 1))" "$STUB3_LOG" | python3 -c '
import json, sys
print(" ".join("%s:%s" % (r["kind"], r.get("path", r.get("tag"))) for r in map(json.loads, sys.stdin)))')" \
  = "http:/.well-known/t3/environment http:/api/orchestration/threads/wt-idle/bounded upgrade:None ws:orchestration.dispatchCommand" ] \
  && pass || faild "V2 send must probe, read /bounded, then upgrade and send one request"

# compact: exact '/compact' through the same path; prints its messageId.
w3_reset; B="$(w3_mark)"
w3 compact wt-idle; rc=$?
P="$(ws_payloads "$B")"
[ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$P" | grep -c .)" = 1 ] \
  && [ "$OUT" = "$(printf '%s' "$P" | python3 -c 'import json,sys; print(json.load(sys.stdin)["messageId"])')" ] \
  && printf '%s' "$P" | python3 -c '
import hashlib, json, sys
p = json.load(sys.stdin)
h = hashlib.sha256(b"/compact").hexdigest()[:12]
assert p["text"] == "/compact" and p["dispatchMode"] == {"type": "queue_after_active"} and "deliveryIntent" not in p
assert p["commandId"].startswith("t3-api:compact:wt-idle:%s:" % h) and p["messageId"].startswith("t3-api:msg:wt-idle:%s:" % h)' \
  && pass || faild "V2 compact must send exact /compact queued and print its messageId (rc=$rc)" "out=$OUT err=$ERR"
# An exact '/compact' through send is allowed; it is the compact verb.
w3_reset; B="$(w3_mark)"; w3 send wt-idle /compact; rc=$?
[ "$rc" -eq 0 ] && ws_since "$B" | grep -q '^message.dispatch t3-api:compact:wt-idle:' && pass || faild "send of an exact /compact must go out (rc=$rc)" "$ERR"

# Guards that refuse before anything is sent (exit 10).
for text in "/logout" " /compact" "/compact now" "/COMPACT" "   " ""; do
  w3_reset; B="$(w3_mark)"
  w3 send wt-idle "$text"; rc=$?
  REQS="$(tail -n +"$((B + 1))" "$STUB3_LOG" | python3 -c 'import json,sys; print(" ".join(json.loads(l).get("path") or json.loads(l)["kind"] for l in sys.stdin))')"
  if [ "$rc" -eq 10 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q 'refused by guard' && [ "$REQS" = "/.well-known/t3/environment" ]; then pass
  else faild "V2 send of '$text' must be refused by the guard (exit 10) after the probe alone, got rc=$rc" "err=$ERR reqs=$REQS"; fi
done
w3_reset; B="$(w3_mark)"; w3 send wt-archived "wake up"; rc=$?
[ "$rc" -eq 10 ] && printf '%s' "$ERR" | grep -q 'thread wt-archived is archived' && [ "$(ws_count "$B")" = 0 ] \
  && pass || faild "V2 send to an archived thread must be refused (exit 10), nothing sent, got rc=$rc" "$ERR"
w3_reset; B="$(w3_mark)"; w3 send no-such-thread "hello"; rc=$?
[ "$rc" -eq 5 ] && printf '%s' "$ERR" | grep -q 'not found on the server' && [ "$(ws_count "$B")" = 0 ] \
  && pass || faild "V2 send to an unknown thread must exit 5, nothing sent, got rc=$rc" "$ERR"

# compact-status: the run that adopted the message, plus its compaction or error turn item.
for spec in "wt-compact-ok:$CMID_OK:0:completed" "wt-compact-empty:$CMID_EMPTY:0:nothing-to-compact" \
            "wt-compact-nocomp:$CMID_OK:0:failed" "wt-compact-pending:$CMID_OK:0:pending" \
            "wt-compact-ok:not-a-message:0:pending" "wt-compact-weird:$CMID_OK:6:"; do
  IFS=: read -r tid mid want state <<< "$spec"
  w3_reset; B="$(w3_mark)"
  w3 compact-status "$tid" "$mid"; rc=$?
  if [ "$rc" -eq "$want" ] && [ "$OUT" = "$state" ] && [ "$(ws_count "$B")" = 0 ]; then pass
  else faild "V2 compact-status $tid must print '$state' (exit $want), got rc=$rc" "out=$OUT err=$ERR"; fi
done
w3_reset; w3 compact-status wt-compact-empty "$CMID_EMPTY"
printf '%s' "$ERR" | grep -qF 'Start a conversation before compacting this thread.' && pass || faild "nothing-to-compact must name the server's text" "$ERR"
w3_reset; w3 compact-status wt-compact-nocomp "$CMID_OK"
printf '%s' "$ERR" | grep -q 'completed without a completed compaction item' && pass || faild "a completed compact run without its item must say so" "$ERR"

# stop: run.interrupt on the active run with holdQueue true; idle has nothing to stop.
w3_reset; B="$(w3_mark)"; w3 stop wt-running; rc=$?
P="$(ws_payloads "$B")"
[ "$rc" -eq 0 ] && [ "$OUT" = '{"sequence": 1505}' ] && printf '%s' "$P" | python3 -c '
import json, sys
p = json.load(sys.stdin)
assert set(p) == {"type", "commandId", "threadId", "runId", "reason", "holdQueue"}, sorted(p)
assert p["type"] == "run.interrupt" and p["runId"] == "run:thread:wt-running:ordinal:1" and p["holdQueue"] is True
assert p["commandId"].startswith("t3-api:stop:wt-running:")' \
  && pass || faild "V2 stop must interrupt the shell's activeRunId with holdQueue true (rc=$rc)" "out=$OUT err=$ERR p=$P"
w3_reset; B="$(w3_mark)"; w3 stop wt-bg; rc=$?
[ "$rc" -eq 0 ] && ws_payloads "$B" | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["runId"] == "run:thread:wt-bg:ordinal:1", p' \
  && pass || faild "V2 stop on a thread with background work must interrupt its latest run (rc=$rc)" "$ERR"
w3_reset; B="$(w3_mark)"; w3 stop wt-idle; rc=$?
[ "$rc" -eq 0 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q 'has nothing to stop' && [ "$(ws_count "$B")" = 0 ] \
  && pass || faild "V2 stop on an idle thread must send nothing and exit 0, got rc=$rc" "$ERR"
w3_reset; B="$(w3_mark)"; w3 stop wt-archived; rc=$?
[ "$rc" -eq 5 ] && [ "$(ws_count "$B")" = 0 ] && pass || faild "V2 stop on a thread absent from the shell must exit 5, got rc=$rc" "$ERR"

# settle refuses every busy shape (exit 9) and sends nothing. wt-held reads idle in the
# shell (status interrupted) but /bounded holds a queued run, which the shell cannot show.
for sub in settle; do
  for spec in "wt-running:a run is running" "wt-approval:waiting for approval" "wt-stale:waiting for approval (command)" \
              "wt-bg:background work is pending" "wt-held:queued run in the projection" "wt-unknown-run:does not know"; do
    tid="${spec%%:*}"; why="${spec#*:}"
    w3_reset; B="$(w3_mark)"
    w3 "$sub" "$tid"; rc=$?
    if [ "$rc" -eq 9 ] && printf '%s' "$ERR" | grep -q "refusing to $sub thread $tid" && printf '%s' "$ERR" | grep -qF "$why" \
       && [ "$(ws_count "$B")" = 0 ]; then pass
    else faild "V2 $sub on $tid must refuse (exit 9, names '$why', nothing sent), got rc=$rc" "$ERR"; fi
  done
done
# V2 archive refuses (exit 7) for every thread, idle, busy or archived, after the probe
# and before any other request: thread.archive has no server-side idle guard, so no
# client read can make it safe. Nothing may reach the server
# but the probe: no read, no upgrade, no frame, no POST.
for tid in wt-idle wt-running wt-approval wt-stale wt-bg wt-held wt-unknown-run wt-archived; do
  w3_reset; B="$(w3_mark)"
  w3 archive "$tid"; rc=$?
  REQS="$(tail -n +"$((B + 1))" "$STUB3_LOG" | python3 -c 'import json,sys; print(" ".join("%s:%s" % (r["kind"], r.get("path", r.get("tag"))) for r in map(json.loads, sys.stdin)))')"
  if [ "$rc" -eq 7 ] && [ -z "$OUT" ] && [ "$(printf '%s\n' "$ERR" | wc -l)" -eq 1 ] \
     && printf '%s' "$ERR" | grep -qF "t3-api: archive refused on this T3 server (orchestration protocol 2): thread.archive has no server-side idle guard" \
     && printf '%s' "$ERR" | grep -qF "use settle" && printf '%s' "$ERR" | grep -qF "Re-enabling waits on a server-side guard" \
     && [ "$REQS" = "http:/.well-known/t3/environment" ]; then pass
  else faild "V2 archive of $tid must refuse with exit 7 and dispatch nothing (probe only), got rc=$rc" "out=$OUT err=$ERR reqs=$REQS"; fi
done
w3_reset; B="$(w3_mark)"; w3 settle ws-idle; rc=$?
[ "$rc" -eq 0 ] && [ "$(ws_since "$B" | cut -d' ' -f1,3)" = "thread.settle ws-idle" ] \
  && ws_payloads "$B" | python3 -c 'import json,sys; p=json.load(sys.stdin); assert set(p) == {"type","commandId","threadId"}' \
  && pass || faild "V2 settle of an idle thread must send exactly thread.settle {type, commandId, threadId} (rc=$rc)" "out=$OUT err=$ERR"
B="$(w3_mark)"; w3 settle ws-idle; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q 'already settled' && [ "$(ws_count "$B")" = 0 ] \
  && pass || faild "V2 settle of a settled thread must be a no-op, got rc=$rc" "$OUT $ERR"

# Exit classification. Fail: refused by the server (exit 11), one request, never retried.
for spec in "fail:is still running. Stop it before settling." "rejected:was previously rejected"; do
  mode="${spec%%:*}"; why="${spec#*:}"
  w3_reset; w3_mode "$mode"; B="$(w3_mark)"
  w3 send wt-idle "a message the server refuses"; rc=$?
  if [ "$rc" -eq 11 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q 'refused by the server (OrchestrationV2DispatchCommandError)' \
     && printf '%s' "$ERR" | grep -qF "$why" && printf '%s' "$ERR" | grep -q 'this commandId is spent' && [ "$(ws_count "$B")" = 1 ]; then pass
  else faild "a Fail Exit ($mode) must exit 11 after one request, got rc=$rc requests=$(ws_count "$B")" "$ERR"; fi
done
# The recorded frame's thread id is replaced by the request's: the message names wt-idle.
printf '%s' "$ERR" | grep -q 'wt-idle\|t3-api:send:wt-idle' && pass || faild "the replayed Fail frame should carry the request's ids" "$ERR"
w3_reset; w3_mode die; B="$(w3_mark)"
w3 settle ws-idle; rc=$?
[ "$rc" -eq 12 ] && printf '%s' "$ERR" | grep -q 'could not decode thread.settle' && printf '%s' "$ERR" | grep -qF 'Missing key' \
  && [ "$(ws_count "$B")" = 1 ] && pass || faild "a Die Exit must exit 12 after one request, got rc=$rc" "$ERR"
# Transport loss: one retry with the identical frame (same commandId and messageId).
w3_reset; w3_mode drop-once; B="$(w3_mark)"
w3 send wt-idle "survives one drop"; rc=$?
P="$(ws_payloads "$B")"
[ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$P" | grep -c .)" = 2 ] && [ "$(printf '%s\n' "$P" | sort -u | grep -c .)" = 1 ] \
  && pass || faild "a dropped connection must be retried once with the identical frame (rc=$rc)" "err=$ERR payloads=$P"
w3_reset; w3_mode drop-always; B="$(w3_mark)"
w3 send wt-idle "lost twice"; rc=$?
P="$(ws_payloads "$B")"
[ "$rc" -eq 4 ] && printf '%s' "$ERR" | grep -q 'the retry with the same commandId also failed' \
  && [ "$(printf '%s\n' "$P" | grep -c .)" = 2 ] && [ "$(printf '%s\n' "$P" | sort -u | grep -c .)" = 1 ] \
  && pass || faild "two lost connections must exit 4 after exactly two identical requests (rc=$rc)" "err=$ERR payloads=$P"
w3_reset; w3_mode silent; B="$(w3_mark)"
T0=$SECONDS; OPS_T3_HTTP_TIMEOUT=1 w3 send wt-idle "never answered"; rc=$?
[ "$rc" -eq 4 ] && printf '%s' "$ERR" | grep -q 'no Exit within 1' && [ "$(ws_count "$B")" = 2 ] && [ $((SECONDS - T0)) -le 8 ] \
  && pass || faild "a silent server must time out, retry once, and exit 4 (rc=$rc, $((SECONDS - T0))s)" "$ERR"
w3_reset; w3_mode upgrade401; B="$(w3_mark)"
w3 send wt-idle "no upgrade"; rc=$?
UPG="$(tail -n +"$((B + 1))" "$STUB3_LOG" | grep -c '"kind": "upgrade"')"
[ "$rc" -eq 4 ] && printf '%s' "$ERR" | grep -q 'HTTP 401 on the WebSocket upgrade' && printf '%s' "$ERR" | grep -q 'auth_invalid' \
  && [ "$UPG" = 1 ] && [ "$(ws_count "$B")" = 0 ] \
  && pass || faild "a refused upgrade must exit 4 without a retry (rc=$rc, upgrades=$UPG)" "$ERR"
# Frames the client must read through: a server ping first, a fragmented Exit, a batch.
for mode in ping frag batch; do
  w3_reset; w3_mode "$mode"
  w3 send wt-idle "framing $mode"; rc=$?
  [ "$rc" -eq 0 ] && [ "$OUT" = '{"sequence": 569}' ] && pass || faild "the client must read the Exit through a '$mode' answer (rc=$rc)" "out=$OUT err=$ERR"
done

# Fresh ids: two refused settles in a row use two different commandIds; a caller key makes
# the same text replay one id; a new text under the same key changes both ids.
w3_reset; w3_mode fail; B="$(w3_mark)"
w3 settle ws-idle; r1=$?; w3 settle ws-idle; r2=$?
IDS="$(ws_since "$B" | cut -d' ' -f2)"
[ "$r1" -eq 11 ] && [ "$r2" -eq 11 ] && [ "$(printf '%s\n' "$IDS" | grep -c .)" = 2 ] && [ "$(printf '%s\n' "$IDS" | sort -u | grep -c .)" = 2 ] \
  && pass || faild "a settle after a refusal must use a fresh commandId (rc=$r1/$r2)" "$IDS"
w3_reset; B="$(w3_mark)"
OPS_T3_COMMAND_KEY=fire-20261019T1030 w3 send wt-idle "wake text"; r1=$?
OPS_T3_COMMAND_KEY=fire-20261019T1030 w3 send wt-idle "wake text"; r2=$?
OPS_T3_COMMAND_KEY=fire-20261019T1030 w3 send wt-idle "another wake text"; r3=$?
w3 send wt-idle "wake text"; r4=$?
ws_payloads "$B" > "$TMP/w3-keys.json"
python3 - "$TMP/w3-keys.json" <<'PY'
import json, sys
p = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(p) == 4, len(p)
assert p[0]["commandId"] == p[1]["commandId"] and p[0]["messageId"] == p[1]["messageId"], "a keyed resend must replay one id"
assert p[0]["commandId"].endswith(":fire-20261019T1030"), p[0]["commandId"]
assert p[2]["commandId"] != p[0]["commandId"] and p[2]["messageId"] != p[0]["messageId"], "a new text must change both ids"
assert p[3]["commandId"] != p[0]["commandId"] and p[3]["messageId"] != p[0]["messageId"], "no key must mean a fresh id"
PY
[ $? -eq 0 ] && [ "$r1$r2$r3$r4" = 0000 ] && pass || faild "command ids: keyed replay, new text, unkeyed fresh id"
w3_reset; B="$(w3_mark)"
OPS_T3_COMMAND_KEY='bad key!' w3 send wt-idle "x"; rc=$?
[ "$rc" -eq 2 ] && [ "$(ws_count "$B")" = 0 ] && pass || faild "an invalid command key must be a usage error with nothing sent, got rc=$rc" "$ERR"

# DRY on V2: the reads and guards run, the frame is printed, nothing is sent.
w3_reset; B="$(w3_mark)"
OPS_T3_DRY=1 w3 send wt-idle "dry text"; rc=$?
[ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | head -1)" = "WS orchestration.dispatchCommand" ] \
  && printf '%s\n' "$OUT" | tail -n +2 | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["type"] == "message.dispatch" and p["text"] == "dry text"' \
  && [ "$(ws_count "$B")" = 0 ] && pass || faild "a dry V2 send must print the command and send nothing (rc=$rc)" "$OUT"
B="$(w3_mark)"; OPS_T3_DRY=1 w3 archive wt-idle; rc=$?
[ "$rc" -eq 7 ] && [ -z "$OUT" ] && [ "$(tail -n +"$((B + 1))" "$STUB3_LOG" | grep -c .)" = 1 ] \
  && pass || faild "a dry V2 archive must refuse (exit 7), print no command and make only the probe, got rc=$rc" "out=$OUT err=$ERR"
B="$(w3_mark)"; OPS_T3_DRY=1 w3 settle ws-idle; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$OUT" | grep -q '"type": "thread.settle"' && [ "$(ws_count "$B")" = 0 ] \
  && pass || faild "a dry V2 settle must print the command and send nothing (rc=$rc)" "$OUT"

# The V2 settle waiter. Reads advance one step per shell read (n); the launcher's read is n=1.
rm -f "$WLOG"
w3_reset; w3 settle-when-idle ws-hold --timeout 30 >/dev/null
wait_log ws-hold 'settled after' 30 && [ "$(grep -c '"type": "thread.settle"' "$STUB3_LOG")" -ge 1 ] \
  && [ "$(tail -n +1 "$STUB3_LOG" | python3 -c '
import json, sys
s = [r for r in map(json.loads, sys.stdin) if r["kind"] == "ws" and r["payload"].get("threadId") == "ws-hold"]
print("%d %d %s" % (len(s), s[0]["n"], s[0]["payload"]["commandId"].endswith(":a1")) if s else "0")')" = "1 5 True" ] \
  && pass || faild "ws-hold: one settle at read 5 (two idle reads, confirmed by /bounded), attempt 1" "$(grep 'thread=ws-hold' "$WLOG" 2>/dev/null)"
w3_reset; w3 settle-when-idle ws-held --timeout 2 >/dev/null
wait_log ws-held 'timed out after 2s without settling' 15 && ! grep -q '"threadId": "ws-held"' "$STUB3_LOG" \
  && pass || faild "ws-held: a queue held behind a stopped run must keep the waiter from settling" "$(grep 'thread=ws-held' "$WLOG" 2>/dev/null)"
w3_reset; w3 settle-when-idle ws-stale --timeout 2 >/dev/null
wait_log ws-stale 'timed out after 2s without settling' 15 && ! grep -q '"threadId": "ws-stale"' "$STUB3_LOG" \
  && pass || faild "ws-stale: a stale pending request must keep the waiter from settling" "$(grep 'thread=ws-stale' "$WLOG" 2>/dev/null)"
w3_reset; w3 settle-when-idle ws-harness --timeout 30 >/dev/null
wait_log ws-harness 'settled after' 30 && grep -Eq "thread=ws-harness .*is the harness's \(1 harness message \(creationSource server\)\); still waiting" "$WLOG" \
  && pass || faild "ws-harness: a harness message after launch must not end the wait; the thread settles" "$(grep 'thread=ws-harness' "$WLOG" 2>/dev/null)"
w3_reset; w3 settle-when-idle ws-operator --timeout 30 >/dev/null
wait_log ws-operator 'still in use, not settling' 15 && grep -Eq 'thread=ws-operator .*creationSource web' "$WLOG" \
  && ! grep -q '"threadId": "ws-operator"' "$STUB3_LOG" \
  && pass || faild "ws-operator: a non-server message after launch must end the wait unsettled" "$(grep 'thread=ws-operator' "$WLOG" 2>/dev/null)"
w3_reset; w3 settle-when-idle ws-refuse1 --timeout 30 >/dev/null
wait_log ws-refuse1 'settled after' 30 && grep -q 'thread=ws-refuse1 .*refused by the server (attempt 1); re-reading, the next attempt uses a fresh commandId' "$WLOG" \
  && [ "$(grep '"threadId": "ws-refuse1"' "$STUB3_LOG" | python3 -c '
import json, sys
ids = [json.loads(l)["payload"]["commandId"] for l in sys.stdin]
print(len(ids), len(set(ids)), ids[0].endswith(":a1"), ids[-1].endswith(":a2"))')" = "2 2 True True" ] \
  && pass || faild "ws-refuse1: a refused settle is followed by a re-read and a fresh commandId" "$(grep 'thread=ws-refuse1' "$WLOG" 2>/dev/null)"
w3_reset; w3 settle-when-idle ws-refuse3 --timeout 30 >/dev/null
wait_log ws-refuse3 'refused by the server 3 times; giving up without settling' 30 \
  && [ "$(grep '"threadId": "ws-refuse3"' "$STUB3_LOG" | python3 -c 'import json,sys; ids=[json.loads(l)["payload"]["commandId"] for l in sys.stdin]; print(len(ids), len(set(ids)))')" = "3 3" ] \
  && pass || faild "ws-refuse3: the waiter must stop after three refusals, each with its own commandId" "$(grep 'thread=ws-refuse3' "$WLOG" 2>/dev/null)"
if grep -qF "$SENTINEL" "$WLOG" 2>/dev/null; then faild "TOKEN LEAK: sentinel in the V2 waiter log"; else pass; fi
cat "$WLOG" >> "$ALLOUT" 2>/dev/null

# message-id: the exact messageId `send` mints under the same caller and key, with no request at all;
# a missing key is a usage error (a random key would never match), a text send refuses is refused.
w3_reset; B="$(w3_mark)"
OUT="$(OPS_T3_CALLER=pause-sender OPS_T3_COMMAND_KEY=pause.0123456789abcdef OPS_T3_BASE="$V3BASE" T3CODE_HOME="$V2HOME" \
       "$SCRIPT" message-id wt-idle "pause text for the suite" 2>"$TMP/w3.err")"; rc=$?; ERR="$(cat "$TMP/w3.err")"
MID_PRINTED="$OUT"
[ "$rc" -eq 0 ] && [ "$(w3_mark)" = "$B" ] && [ -z "$ERR" ] \
  && [ "$MID_PRINTED" = "pause-sender:msg:wt-idle:$(printf '%s' "pause text for the suite" | sha256sum | cut -c1-12):pause.0123456789abcdef" ] \
  && pass || faild "message-id must print the send's messageId and make no request (rc=$rc)" "out=$OUT err=$ERR"
B="$(w3_mark)"
OUT="$(OPS_T3_CALLER=pause-sender OPS_T3_COMMAND_KEY=pause.0123456789abcdef OPS_T3_BASE="$V3BASE" T3CODE_HOME="$V2HOME" \
       "$SCRIPT" send wt-idle "pause text for the suite" 2>"$TMP/w3.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(ws_payloads "$B" | python3 -c 'import json,sys; print(json.load(sys.stdin)["messageId"])')" = "$MID_PRINTED" ] \
  && pass || faild "the send under the same caller and key must carry exactly the id message-id printed (rc=$rc)" "$(cat "$TMP/w3.err")"
B="$(w3_mark)"
OUT="$(env -u OPS_T3_COMMAND_KEY OPS_T3_BASE="$V3BASE" T3CODE_HOME="$V2HOME" "$SCRIPT" message-id wt-idle "pause text" 2>"$TMP/w3.err")"; rc=$?
[ "$rc" -eq 2 ] && [ -z "$OUT" ] && grep -q 'message-id needs OPS_T3_COMMAND_KEY' "$TMP/w3.err" && [ "$(w3_mark)" = "$B" ] \
  && pass || faild "message-id without a key must be a usage error with no request (rc=$rc)" "$(cat "$TMP/w3.err")"
OUT="$(OPS_T3_COMMAND_KEY=k1 OPS_T3_BASE="$V3BASE" T3CODE_HOME="$V2HOME" "$SCRIPT" message-id wt-idle "/logout" 2>"$TMP/w3.err")"; rc=$?
[ "$rc" -eq 10 ] && [ -z "$OUT" ] && [ "$(w3_mark)" = "$B" ] && pass || faild "message-id of a text send refuses must exit 10 (rc=$rc)" "$(cat "$TMP/w3.err")"
OUT="$(OPS_T3_COMMAND_KEY='bad key' OPS_T3_BASE="$V3BASE" T3CODE_HOME="$V2HOME" "$SCRIPT" message-id wt-idle "x" 2>"$TMP/w3.err")"; rc=$?
[ "$rc" -eq 2 ] && [ -z "$OUT" ] && pass || faild "message-id with a malformed key must exit 2 (rc=$rc)" "$(cat "$TMP/w3.err")"

# queued-cancel: removes ONLY the queued run whose userMessageId is the given id (the broadcast's held
# pause), with one queued-run.cancel of exactly the 0.1.0 shape; a person's message queued behind it is
# never touched; never queue.resume.
QOWN="ca230137-7f96-4404-8ec5-7342d9ebf809"   # the held-queue fixture's queued run's message (a harness send)
w3_reset; B="$(w3_mark)"
w3 queued-cancel wq-held "$QOWN"; rc=$?
P="$(ws_payloads "$B")"
[ "$rc" -eq 0 ] && [ "$OUT" = 'cancelled run:thread:wq-held:ordinal:2 {"sequence": 795}' ] && printf '%s' "$P" | python3 -c '
import json, sys
lines = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
assert len(lines) == 1, lines
p = lines[0]
assert set(p) == {"type", "commandId", "threadId", "runId"}, sorted(p)
assert p["type"] == "queued-run.cancel" and p["threadId"] == "wq-held" and p["runId"] == "run:thread:wq-held:ordinal:2", p
assert p["commandId"].startswith("t3-api:cancel:wq-held:"), p["commandId"]' \
  && pass || faild "queued-cancel must cancel exactly the run carrying the message (rc=$rc)" "out=$OUT err=$ERR p=$P"
# The reads before it: the probe and /bounded, then one upgrade and one request.
[ "$(tail -n +"$((B + 1))" "$STUB3_LOG" | python3 -c '
import json, sys
print(" ".join("%s:%s" % (r["kind"], r.get("path", r.get("tag"))) for r in map(json.loads, sys.stdin)))')" \
  = "http:/.well-known/t3/environment http:/api/orchestration/threads/wq-held/bounded upgrade:None ws:orchestration.dispatchCommand" ] \
  && pass || faild "queued-cancel must probe, read /bounded, then send one request"
# Once cancelled the run is no longer queued: a second call sends nothing and says so.
B="$(w3_mark)"; w3 queued-cancel wq-held "$QOWN"; rc=$?
[ "$rc" -eq 0 ] && [ "$OUT" = "not-queued run:thread:wq-held:ordinal:2 cancelled" ] && [ "$(ws_count "$B")" = 0 ] \
  && pass || faild "queued-cancel of a run no longer queued must send nothing (rc=$rc)" "out=$OUT err=$ERR"
# The person's queued message: refused by the guard, nothing sent, and it is still queued.
w3_reset; B="$(w3_mark)"; w3 queued-cancel wq-held wq-held-user-queued; rc=$?
[ "$rc" -eq 10 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q "creationSource 'web'" && [ "$(ws_count "$B")" = 0 ] \
  && pass || faild "queued-cancel of a message that is not a harness send must be refused (exit 10), nothing sent (rc=$rc)" "out=$OUT err=$ERR"
w3 thread wq-held
printf '%s' "$OUT" | python3 -c '
import json, sys
runs = {r["id"]: r["status"] for r in json.load(sys.stdin)["thread"]["runs"]}
assert runs["run:thread:wq-held:ordinal:3"] == "queued", runs' && pass || faild "the person's queued run must still be queued" "$OUT"
# The pause's run already started: left alone, nothing sent.
w3_reset; B="$(w3_mark)"; w3 queued-cancel wq-started "$QOWN"; rc=$?
[ "$rc" -eq 0 ] && [ "$OUT" = "not-queued run:thread:wq-started:ordinal:2 running" ] && [ "$(ws_count "$B")" = 0 ] \
  && pass || faild "queued-cancel must leave a started run alone (rc=$rc)" "out=$OUT err=$ERR"
# /bounded does not show the queued run's message: it cannot be confirmed as a harness send, so refused.
w3_reset; B="$(w3_mark)"; w3 queued-cancel wq-nomsg "$QOWN"; rc=$?
[ "$rc" -eq 10 ] && printf '%s' "$ERR" | grep -q 'cannot be confirmed as a harness send' && [ "$(ws_count "$B")" = 0 ] \
  && pass || faild "queued-cancel with the message missing from /bounded must refuse (rc=$rc)" "out=$OUT err=$ERR"
# No run carries the message (the pause never landed): "none", nothing sent.
w3_reset; B="$(w3_mark)"; w3 queued-cancel wt-idle "pause-sender:msg:wt-idle:000000000000:pause.ffffffffffffffff"; rc=$?
[ "$rc" -eq 0 ] && [ "$OUT" = "none" ] && [ "$(ws_count "$B")" = 0 ] && pass || faild "queued-cancel with no run carrying the message must print none (rc=$rc)" "out=$OUT err=$ERR"
# Unknown thread: 5, nothing sent. Usage: two non-empty arguments.
w3_reset; B="$(w3_mark)"; w3 queued-cancel no-such-thread "$QOWN"; rc=$?
[ "$rc" -eq 5 ] && [ "$(ws_count "$B")" = 0 ] && pass || faild "queued-cancel on an unknown thread must exit 5 (rc=$rc)" "$ERR"
for args in "wq-held" "wq-held '' " "'' $QOWN"; do
  B="$(w3_mark)"
  eval "w3 queued-cancel $args"; rc=$?
  [ "$rc" -eq 2 ] && [ "$(w3_mark)" = "$B" ] && pass || faild "queued-cancel $args must be a usage error before any request (rc=$rc)" "$ERR"
done
# A server refusal (the run left the queue between the read and the dispatch) exits 11 and claims nothing.
w3_reset; w3_mode fail; B="$(w3_mark)"; w3 queued-cancel wq-held "$QOWN"; rc=$?
w3_mode ok
[ "$rc" -eq 11 ] && [ -z "$OUT" ] && [ "$(ws_count "$B")" = 1 ] && pass || faild "a refused cancel must exit 11 and print no cancelled line (rc=$rc)" "out=$OUT err=$ERR"
# A lost response is retried once with the identical frame (same commandId), like every write.
w3_reset; w3_mode drop-once; B="$(w3_mark)"; w3 queued-cancel wq-held "$QOWN"; rc=$?
w3_mode ok
[ "$rc" -eq 0 ] && [ "$(ws_since "$B" | awk '{print $2}' | sort -u | grep -c .)" = 1 ] && [ "$(ws_count "$B")" = 2 ] \
  && pass || faild "a lost cancel must be retried once with the same commandId (rc=$rc)" "$(ws_since "$B")"
# Dry: the reads run, the command is printed, nothing is sent.
w3_reset; B="$(w3_mark)"
OUT="$(OPS_T3_DRY=1 OPS_T3_BASE="$V3BASE" T3CODE_HOME="$V2HOME" "$SCRIPT" queued-cancel wq-held "$QOWN" 2>"$TMP/w3.err")"; rc=$?
[ "$rc" -eq 0 ] && [ "$(ws_count "$B")" = 0 ] && [ "$(printf '%s\n' "$OUT" | head -1)" = "WS orchestration.dispatchCommand" ] \
  && printf '%s\n' "$OUT" | sed -n 2p | python3 -c 'import json,sys; p=json.load(sys.stdin); assert p["type"] == "queued-run.cancel" and p["runId"] == "run:thread:wq-held:ordinal:2"' \
  && pass || faild "a dry queued-cancel must print the command and send nothing (rc=$rc)" "out=$OUT"
# Nothing in this suite ever asks the server to release a queue.
grep -q '"type": "queue.resume"' "$STUB3_LOG" && faild "queue.resume was sent" || pass
# On a protocol-1 server there is no queue to cancel from: exit 8 before any thread read.
reset_stub; B="$(wc -l < "$STUB_LOG")"
split_run queued-cancel thread-aaaa "$QOWN"; rc=$?
[ "$rc" -eq 8 ] && [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q 'queued-cancel needs orchestration protocol 2' \
  && [ "$(reqs_since "$STUB_LOG" "$B")" = "GET /.well-known/t3/environment None" ] \
  && pass || faild "queued-cancel on a V1 server must exit 8 after the probe alone, got rc=$rc" "$ERR | $(reqs_since "$STUB_LOG" "$B")"

# server-busy: held queues count; the shell's serverIdleVerdict says it cannot see them.
w3_reset; w3 server-busy; rc=$?
printf '%s' "$OUT" > "$TMP/w3-busy.json"
w3 shell; printf '%s' "$OUT" > "$TMP/w3-shell.json"
python3 - "$TMP/w3-busy.json" "$TMP/w3-shell.json" "$rc" <<'PY'
import json, sys
b, s = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
assert sys.argv[3] == "0", sys.argv[3]
assert b["idle"] is False and b["heldQueuesChecked"] is True, b
assert "wt-held" in b["busyThreadIds"] and "ws-held" in b["busyThreadIds"], b["busyThreadIds"]
assert any("queued run in the projection" in r for r in b["reasons"]["wt-held"]), b["reasons"]["wt-held"]
assert "wt-idle" not in b["busyThreadIds"] and "wt-unknown-run" in b["busyThreadIds"], b["busyThreadIds"]
assert b["boundedReads"] >= 8 and b["threadsChecked"] == len(s["threads"]) + len(s["subagentThreads"]), b
sv = s["serverIdleVerdict"]
assert sv["heldQueuesChecked"] is False and "wt-held" not in sv["busyThreadIds"], sv
PY
[ $? -eq 0 ] && pass || faild "server-busy must count held queues; the shell's verdict must say it cannot"
reset_stub; B="$(wc -l < "$STUB_LOG")"
split_run server-busy; rc=$?
[ "$rc" -eq 8 ] && printf '%s' "$ERR" | grep -q 'server-busy reads orchestration protocol 2' && pass || faild "server-busy on a V1 server must exit 8, got rc=$rc" "$ERR"

# The write path's pure functions and the WebSocket client's retry rule (no network: the
# transport is a fake). -B: no bytecode cache, so a mutation run never reuses a stale .pyc.
python3 -I -B - "$HERE/../lib" "$WSFX" "$WFX" <<'PY'
import copy, datetime, hashlib, json, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import t3_api_v2 as m
import t3_ws as w
WSFX, WFX = sys.argv[2], sys.argv[3]
NOW = datetime.datetime(2026, 10, 18, 12, 0, 0, tzinfo=datetime.timezone.utc)
fails = []
def check(cond, what):
    if not cond:
        fails.append(what)
def exit_of(name):
    return [x for x in json.load(open(WSFX + "/" + name))["response"] if x.get("_tag") == "Exit"][0]["exit"]
# classify_exit on the recorded frames.
check(w.classify_exit(exit_of("a18-dispatch-message-queue-after-active.json")) == ("success", {"sequence": 569}), "a18 success")
k, v = w.classify_exit(exit_of("b03-settle-refused-active-run.json"))
check(k == "fail" and v["_tag"] == "OrchestrationV2DispatchCommandError" and "still running" in v["message"], "b03 fail")
k, v = w.classify_exit(exit_of("a27-dispatch-malformed-payload.json"))
check(k == "die" and v.startswith("Missing key"), "a27 die %r" % v)
for bad in ({"_tag": "Interrupt"}, {"_tag": "Failure", "cause": [{"_tag": "Interrupt"}]}, None, {"_tag": "Failure", "cause": []}):
    try:
        w.classify_exit(bad); fails.append("classify_exit must refuse %r" % (bad,))
    except w.BadFrame:
        pass
# The retry rule: transport loss once is retried with the identical payload; nothing else is.
def fake(script):
    calls = []
    def once(host, port, token, tag, payload, timeout):
        calls.append(payload)
        step = script[len(calls) - 1]
        if isinstance(step, Exception):
            raise step
        return step
    return once, calls
P = {"type": "thread.settle", "commandId": "c1", "threadId": "t"}
once, calls = fake([w.TransportLost("drop"), ("success", {"sequence": 1})])
check(w.call("http://127.0.0.1:1", "tok", "x", P, 5, pause=0, _once=once) == ("success", {"sequence": 1}, 2)
      and len(calls) == 2 and calls[0] is calls[1], "one retry with the identical payload")
once, calls = fake([w.TransportLost("a"), w.TransportLost("b")])
try:
    w.call("http://127.0.0.1:1", "tok", "x", P, 5, pause=0, _once=once); fails.append("two losses must raise")
except w.TransportLost as e:
    check(len(calls) == 2 and "also failed" in str(e), "two losses: two calls")
for first in (("fail", {"message": "no"}), ("die", "Missing key")):
    once, calls = fake([first, ("success", None)])
    check(w.call("http://127.0.0.1:1", "tok", "x", P, 5, pause=0, _once=once)[0] == first[0] and len(calls) == 1, "no retry on %s" % first[0])
once, calls = fake([w.UpgradeRefused("HTTP 401"), ("success", None)])
try:
    w.call("http://127.0.0.1:1", "tok", "x", P, 5, pause=0, _once=once); fails.append("a refused upgrade must raise")
except w.UpgradeRefused:
    check(len(calls) == 1, "no retry on a refused upgrade")
for base in ("https://127.0.0.1:3773", "ws://127.0.0.1:3773", "127.0.0.1:3773", ""):
    try:
        w.parse_base(base); fails.append("parse_base must refuse %r" % base)
    except ValueError:
        pass
check(w.parse_base("http://127.0.0.1:3790") == ("127.0.0.1", 3790), "parse_base")
# Keepalive: a call allowed to run past KEEPALIVE_AFTER_S sends an Effect-level Ping while it
# waits; a shorter one never does. A fake connection stays silent until it sees a Ping.
import socket as _socket, time as _time
class FakeSock:
    t = None
    def settimeout(self, t): self.t = t
    def close(self): pass
class FakeConn:
    def __init__(self): self.sock, self.sent = FakeSock(), []
    def send(self, op, data=b""): self.sent.append((op, data))
    def read_frame(self):
        if any(op == 1 and b'"Ping"' in d for op, d in self.sent):
            return 1, True, json.dumps({"_tag": "Exit", "requestId": "1", "exit": {"_tag": "Success", "value": {"sequence": 7}}}).encode()
        _time.sleep(min(self.sock.t, 0.2)); raise _socket.timeout()
saved = (w.handshake, w.KEEPALIVE_AFTER_S, w.KEEPALIVE_EVERY_S)
try:
    conn = FakeConn(); w.handshake = lambda *a: conn; w.KEEPALIVE_AFTER_S, w.KEEPALIVE_EVERY_S = 0.1, 0.3
    check(w.call_once("h", 1, "tok", "x", P, 2) == ("success", {"sequence": 7}), "keepalive call answered")
    check(any(op == 1 and b'"Ping"' in d for op, d in conn.sent), "a long call pings while it waits")
    conn = FakeConn(); w.handshake = lambda *a: conn; w.KEEPALIVE_AFTER_S = 5
    try:
        w.call_once("h", 1, "tok", "x", P, 0.3); fails.append("a short silent call must time out")
    except w.TransportLost:
        check(not any(b'"Ping"' in d for op, d in conn.sent), "a short call never pings")
finally:
    w.handshake, w.KEEPALIVE_AFTER_S, w.KEEPALIVE_EVERY_S = saved
for n in (0, 125, 126, 65535, 65536):
    f = w.encode_frame(1, b"x" * n)
    check(f[0] == 0x81 and f[1] & 0x80, "frame %d: fin, text, masked" % n)
    ln = f[1] & 0x7F
    check((ln == n) if n < 126 else (ln == 126 if n < 65536 else ln == 127), "frame %d length form" % n)
# The guards.
for text, ok in (("hello", True), ("/compact", True), ("a /slash inside", True), ("/logout", False), (" /compact", False),
                 ("/compact now", False), ("/COMPACT", False), ("", False), ("  \n", False), ("\t/x", False)):
    check((m.text_guard(text) is None) == ok, "text_guard %r" % text)
# Ids: the same intent and text replay; a new text or no key changes them.
a = m.command_ids("t3-api", "send", "t", "hello", "k1")
check(a == m.command_ids("t3-api", "send", "t", "hello", "k1"), "ids deterministic")
check(a[0] == "t3-api:send:t:%s:k1" % hashlib.sha256(b"hello").hexdigest()[:12], "commandId format %s" % a[0])
b = m.command_ids("t3-api", "send", "t", "hello!", "k1")
check(b[0] != a[0] and b[1] != a[1], "a new text changes both ids")
for caller, key in (("bad caller", "k"), ("ok", "bad key"), ("", "k"), ("ok", ""), ("x" * 41, "k"), ("ok", "k" * 81)):
    try:
        m.command_ids(caller, "send", "t", "x", key); fails.append("command_ids must refuse %r %r" % (caller, key))
    except ValueError:
        pass
c = m.build_command("message", "t", "t3-api", "k", text="hi")
check(c["dispatchMode"] == {"type": "queue_after_active"} and "deliveryIntent" not in c and c["creationSource"] == "server", "message shape")
check(m.build_command("message", "t", "t3-api", "k", text="/compact")["commandId"].startswith("t3-api:compact:"), "compact verb")
i = m.build_command("interrupt", "t", "t3-api", "k", run_id="r1")
check(i["holdQueue"] is True and i["runId"] == "r1" and i["type"] == "run.interrupt", "interrupt shape")
check(set(m.build_command("archive", "t", "t3-api", "k")) == {"type", "commandId", "threadId"}, "archive shape")
# The queue input on idle_verdict: shell-idle threads that /bounded shows busy.
OLD = "2026-10-01T12:00:00.000Z"
T = {"id": "t", "status": "interrupted", "activityRunStatus": None, "activeRunId": None, "pendingRuntimeRequest": None,
     "pendingBackgroundTasks": [], "latestUserMessageAt": OLD, "latestUserAuthoredMessageAt": OLD, "latestRunRequestedAt": OLD}
def proj(runs, requests=()):
    return {"thread": {"id": "t"}, "runs": [{"id": "r%d" % n, "status": s} for n, s in enumerate(runs)], "runtimeRequests": list(requests)}
check(m.idle_verdict(T, NOW) == [], "shell-only idle")
check(m.idle_verdict(T, NOW, (), proj(["interrupted", "completed"])) == [], "terminal runs only: idle")
for runs, requests, frag in ((["interrupted", "queued"], (), "1 queued run in the projection"),
                             (["failed", "queued", "queued"], (), "2 queued runs"),
                             (["completed", "running"], (), "the projection shows a run running"),
                             (["completed", "paused"], (), "does not know"),
                             (["completed"], ({"id": "q", "status": "pending"},), "runtime request pending"),
                             (["completed"], ({"id": "q"},), "runtime request pending"),
                             (["completed"], ({"id": "q", "status": "weird"},), "runtime request pending"),
                             (["completed"], ("garbled",), "runtime request pending")):
    r = m.idle_verdict(T, NOW, (), proj(runs, requests))
    check(any(frag in x for x in r), "projection %s %s -> %s" % (runs, requests, r))
for final in ("resolved", "expired", "cancelled"):
    check(m.idle_verdict(T, NOW, (), proj(["completed"], ({"id": "q", "status": final},))) == [], "request %s is final" % final)
check(any("no runs list" in x for x in m.idle_verdict(T, NOW, (), {"thread": {"id": "t"}})), "missing runs list is busy")
check(m.projection_busy_reasons(None) and m.projection_busy_reasons([]), "unreadable projection is busy")
# thread_verdict: idle only with /bounded; held queue busy; settled; missing.
shell = {"threads": [dict(T)], "projects": []}
bnd = {"projection": proj(["interrupted", "queued"])}
check(m.thread_verdict(shell, "t", NOW, "settle")[0] == "unconfirmed", "shell-only reads unconfirmed")
check(m.thread_verdict(shell, "t", NOW, "archive", bnd)[0] == "busy", "held queue busy")
check(m.thread_verdict(shell, "t", NOW, "archive", {"projection": proj(["interrupted"])})[0] == "idle", "idle with bounded")
check(m.thread_verdict(shell, "nope", NOW, "settle")[0] == "missing", "missing")
st = {"threads": [dict(T, settledOverride="settled")], "projects": []}
check(m.thread_verdict(st, "t", NOW, "settle")[0] == "settled" and m.thread_verdict(st, "t", NOW, "archive")[0] == "unconfirmed", "settled")
check(m.thread_verdict({"threads": [dict(T, settledOverride="active", settledAt=OLD)], "projects": []}, "t", NOW, "settle")[0] == "unconfirmed", "active override")
try:
    m.thread_verdict(shell, "t", NOW, "settle", {"projection": {"thread": {"id": "other"}, "runs": []}}); fails.append("wrong thread bounded")
except m.ShapeError:
    pass
# stop_target.
def sh(**kw):
    return {"threads": [dict(T, latestRunId="rl", **kw)], "projects": []}
check(m.stop_target(sh(activeRunId="ra"), "t")[0] == "ra", "activeRunId first")
check(m.stop_target(sh(activityRunStatus="waiting"), "t")[0] == "rl", "waiting run: latest")
check(m.stop_target(sh(pendingBackgroundTasks=[{"kind": "subagent"}]), "t")[0] == "rl", "background: latest")
check(m.stop_target(sh(), "t")[0] is None, "idle: nothing")
# compact_evidence and operator_check on the real scratch states.
S = json.load(open(WFX))["states"]
def real(name):
    s = copy.deepcopy(S[name])
    return json.loads(json.dumps(s).replace("@TID@", "t"))
ok = real("compact-ok")
check(m.compact_evidence(ok["bounded"], "t", ok["compactMessageId"])[0] == "completed", "real compact completed")
empty = real("compact-empty")
check(m.compact_evidence(empty["bounded"], "t", empty["compactMessageId"]) == ("nothing-to-compact", m.EMPTY_COMPACT_TEXT), "real empty")
op = real("operator")
check(m.operator_check(op["bounded"], "t", "2026-10-17T18:58:25.200Z")[0] == "operator", "web message is the operator")
check(m.operator_check(op["bounded"], "t", "2026-10-17T18:58:25.000Z")[0] == "operator", "web among server is the operator")
check(m.operator_check(op["bounded"], "t", "2026-10-17T18:58:25.442Z")[0] == "unseen", "nothing newer is unseen")
idle = real("idle")
check(m.operator_check(idle["bounded"], "t", "2026-10-01T00:00:00.000Z")[0] == "harness", "server messages are the harness")
check(m.operator_check(idle["bounded"], "t", "yesterday")[0] == "operator", "unreadable baseline is the operator")
if fails:
    sys.stderr.write("write-path pure checks failed:\n  " + "\n  ".join(fails) + "\n"); sys.exit(1)
PY
[ $? -eq 0 ] && pass || faild "V2 write path: retry rule, Exit classes, guards, ids, queue input, verdict, evidence (see above)"


# Every upgrade carried the right bearer and orchestrationProtocol=2, every client frame was
# masked, every HTTP read the protocol header; the stub log never holds the token.
python3 - "$STUB3_LOG" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
up = [r for r in recs if r["kind"] == "upgrade"]
assert up and all(r["auth_ok"] and r["protocol"] == ["2"] for r in up), [r for r in up if not (r["auth_ok"] and r["protocol"] == ["2"])][:2]
assert all(r["masked"] for r in recs if r["kind"] == "ws"), "an unmasked client frame"
http = [r for r in recs if r["kind"] == "http" and r["path"].startswith("/api/orchestration/")]
assert http and all(r["auth_ok"] and r["proto"] == "2" for r in http), [r["path"] for r in http if not (r["auth_ok"] and r["proto"] == "2")][:3]
assert not [r for r in recs if r["kind"] == "http" and r["method"] == "POST"], "a V2 write POSTed"
PY
[ $? -eq 0 ] && pass || faild "V2 writes: bearer on the upgrade, protocol 2, masked frames, no POST"
if grep -qF "$SENTINEL" "$STUB3_LOG"; then faild "TOKEN LEAK: sentinel in the V2 write log"; else pass; fi

# --- 4. Authorization header present on EVERY request --------------------------
python3 - "$STUB_LOG" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert recs, "no requests recorded"
missing = [r for r in recs if not (r["auth_present"] and r["auth_scheme"] == "Bearer")]
if missing:
    sys.stderr.write("requests missing Bearer auth: %s\n" % missing)
    sys.exit(1)
PY
[ $? -eq 0 ] && pass || faild "some request lacked a Bearer Authorization header"

# --- 5. token never leaks ------------------------------------------------------
if grep -qF "$SENTINEL" "$ALLOUT"; then
  faild "TOKEN LEAK: sentinel appeared in command stdout/stderr"
else pass; fi
if grep -qF "$SENTINEL" "$STUB_LOG"; then
  faild "TOKEN LEAK: sentinel appeared in the recorded request log"
else pass; fi
# `token` prints the PATH, not the bytes.
OUT="$(run token)"; rc=$?
[ "$rc" -eq 0 ] && [ "$OUT" = "$TOKENF" ] \
  && pass || faild "token should print the file path (rc=$rc)" "$OUT"

# --- 6. missing token exits 3 --------------------------------------------------
rc=0; OPS_T3_TOKEN_FILE="$TMP/does-not-exist.token" "$SCRIPT" snapshot >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && pass || faild "missing token should exit 3 on a read, got rc=$rc"
rc=0; OPS_T3_TOKEN_FILE="$TMP/does-not-exist.token" "$SCRIPT" send thread-aaaa hi >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && pass || faild "missing token should exit 3 on send, got rc=$rc"

# --- 7. dry send: prints body, makes no request but the protocol probe ----------
# The probe (one GET) is what lets a dry send predict the real one: on a protocol-2
# server both refuse (section 3d). It never POSTs and skips the runtimeMode read.
BEFORE="$(wc -l < "$STUB_LOG")"
OUT="$(OPS_T3_DRY=1 "$SCRIPT" send thread-aaaa "/compact dry" 2>&1)"; rc=$?
AFTER="$(wc -l < "$STUB_LOG")"
printf '%s\n' "$OUT" >> "$ALLOUT"
if [ "$rc" -eq 0 ] \
   && printf '%s' "$OUT" | grep -q 'POST /api/orchestration/dispatch' \
   && printf '%s' "$OUT" | grep -q '"type": "thread.turn.start"' \
   && printf '%s' "$OUT" | grep -q '"text": "/compact dry"'; then pass
else faild "dry send should print the body (rc=$rc)" "$OUT"; fi
LASTREQ="$(tail -n 1 "$STUB_LOG" | python3 -c 'import json,sys; r=json.loads(sys.stdin.read()); print(r["method"], r["path"])')"
[ "$((AFTER - BEFORE))" = 1 ] && [ "$LASTREQ" = "GET /.well-known/t3/environment" ] && pass \
  || faild "dry send must make exactly one request, the protocol probe (log grew $BEFORE -> $AFTER, last: $LASTREQ)"

echo "t3-api-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
