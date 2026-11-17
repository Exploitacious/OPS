"""Focused, network-free regressions for the V2 write guards and settle waiter.

Sandboxed, without a network: these drive t3-api.sh's V2 client,
which can dispatch to and settle threads on a real T3 server, so the suite
refuses to run (exit 97) outside sandbox-run and with any interface but the
sandbox's own loopback; OPS CI runs it inside sandbox-run --no-net, and
verify-ops.sh lists it in OPS_SANDBOX_SUITES.
"""
import os, runpy; runpy.run_path(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "sandbox_guard.py"))["require"]()
import socket
import sys


def _require_no_route_to_t3():
    """t3-api-test.sh's rule: loopback is the only interface (read before any
    socket opens), and 127.0.0.1:3773, T3 Code's default port, refuses.
    Anything else prints the refusal and exits 97."""
    def refuse(why):
        sys.stderr.write("refusing to run with a route to a live T3 server: %s\n" % why)
        raise SystemExit(97)
    try:
        with open("/proc/net/dev", encoding="ascii", errors="replace") as f:
            ifaces = sorted(l.split(":", 1)[0].strip() for l in f.read().splitlines()[2:] if ":" in l)
    except OSError as e:
        refuse("cannot read /proc/net/dev (%s)" % e)
    if ifaces != ["lo"]:
        refuse("interfaces %s, not loopback only; run it through sandbox-run --no-net" % (" ".join(ifaces) or "none"))
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(2)
    try:
        s.connect(("127.0.0.1", 3773))
    except ConnectionRefusedError:
        return
    except OSError as e:
        refuse("127.0.0.1:3773 did not refuse (%s: %s)" % (type(e).__name__, e))
    finally:
        s.close()
    refuse("something accepted a connection on 127.0.0.1:3773")


_require_no_route_to_t3()
import copy
import datetime
import http.server
import io
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "lib"))
import t3_api_v2 as api
import t3_ws as ws


class VerdictTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.datetime(2026, 10, 18, tzinfo=datetime.timezone.utc)
        self.shell = {"projects": [], "threads": [{
            "id": "t", "status": "completed", "activityRunStatus": None,
            "activeRunId": None, "pendingRuntimeRequest": None, "pendingBackgroundTasks": [],
        }]}
        self.bounded = {"projection": {
            "thread": {"id": "t", "archivedAt": None, "deletedAt": None},
            "runs": [], "runtimeRequests": [],
        }}

    def test_missing_request_list_never_confirms_idle(self):
        for value in (None, "absent"):
            with self.subTest(value=value):
                bounded = copy.deepcopy(self.bounded)
                if value == "absent":
                    del bounded["projection"]["runtimeRequests"]
                else:
                    bounded["projection"]["runtimeRequests"] = value
                self.assertEqual(api.thread_verdict(self.shell, "t", self.now, "archive", bounded)[0], "busy")

    def test_bounded_tombstone_overrides_an_older_live_shell(self):
        for key in ("archivedAt", "deletedAt"):
            with self.subTest(key=key):
                bounded = copy.deepcopy(self.bounded)
                bounded["projection"]["thread"][key] = "2026-10-18T00:00:00Z"
                for mode in ("archive", "settle"):
                    self.assertEqual(api.thread_verdict(self.shell, "t", self.now, mode, bounded)[0], "missing")

    def test_session_lookup_does_not_choose_from_a_truncated_result(self):
        # The second active match used to lie just beyond SQL's LIMIT 50, so the client
        # selected the first thread even though the session mapped to two live threads.
        with tempfile.TemporaryDirectory() as td:
            db = str(Path(td) / "statev2.sqlite")
            with sqlite3.connect(db) as con:
                con.execute("CREATE TABLE orchestration_v2_projection_provider_threads "
                            "(thread_id TEXT, provider_thread_id TEXT, owner_node_id TEXT, payload_json TEXT)")
                con.execute("CREATE TABLE orchestration_v2_projection_threads "
                            "(thread_id TEXT, active_provider_thread_id TEXT)")
                for n in range(51):
                    tid, ptid = f"t{n}", f"pt{n}"
                    con.execute("INSERT INTO orchestration_v2_projection_provider_threads VALUES (?, ?, NULL, ?)",
                                (tid, ptid, json.dumps({"nativeThreadRef": {"nativeId": "session"}})))
                    con.execute("INSERT INTO orchestration_v2_projection_threads VALUES (?, ?)",
                                (tid, ptid if n in (0, 50) else None))
            with self.assertRaises(api.NotFound):
                api.thread_for_session(db, "session")

    def test_waiter_attempt_accepts_the_documented_maximum_key(self):
        with mock.patch.dict(os.environ, {"OPS_T3_COMMAND_KEY": "k" * 80}):
            first = api._command(["settle", "t", "--attempt", "1"])
            second = api._command(["settle", "t", "--attempt", "2"])
        self.assertNotEqual(first["commandId"], second["commandId"])


class QueuedCancelPlanTests(unittest.TestCase):
    """queued_cancel_plan picks runs by exact userMessageId, cancels only queued ones, and never
    a message that is not a harness send (a sender cancelling its own held pause)."""
    OWN = "pause-sender:msg:t:abcdefabcdef:pause.0123456789abcdef"

    def setUp(self):
        def run(n, status, mid, pos=None):
            return {"id": f"run:thread:t:ordinal:{n}", "ordinal": n, "status": status, "queuePosition": pos,
                    "userMessageId": mid}
        def msg(mid, source):
            return {"id": mid, "role": "user", "creationSource": source, "createdBy": "user", "text": "x"}
        self.bounded = {"projection": {
            "thread": {"id": "t", "archivedAt": None, "deletedAt": None},
            "runs": [run(1, "failed", "m-first"), run(2, "queued", self.OWN, 1), run(3, "queued", "m-user", 2)],
            "messages": [msg("m-first", "server"), msg(self.OWN, "server"), msg("m-user", "web")],
        }}

    def test_only_the_run_carrying_the_exact_id_is_cancelled(self):
        self.assertEqual(api.queued_cancel_plan(self.bounded, "t", self.OWN),
                         [("run:thread:t:ordinal:2", "queued", True)])

    def test_a_prefix_or_a_neighbour_never_matches(self):
        for mid in (self.OWN[:-1], self.OWN + "0", "pause-sender:msg:t", "", "m-first-x"):
            with self.subTest(mid=mid):
                self.assertEqual(api.queued_cancel_plan(self.bounded, "t", mid), [])

    def test_only_queued_runs_are_cancelled(self):
        for status in ("running", "starting", "preparing", "waiting", "completed", "failed", "interrupted",
                       "cancelled", "paused-by-a-future-server", None):
            with self.subTest(status=status):
                bounded = copy.deepcopy(self.bounded)
                bounded["projection"]["runs"][1]["status"] = status
                (rid, _, cancel), = api.queued_cancel_plan(bounded, "t", self.OWN)
                self.assertEqual(rid, "run:thread:t:ordinal:2")
                self.assertFalse(cancel)

    def test_a_queued_message_that_is_not_a_harness_send_is_refused(self):
        with self.assertRaises(api.GuardRefusal):
            api.queued_cancel_plan(self.bounded, "t", "m-user")
        bounded = copy.deepcopy(self.bounded)
        bounded["projection"]["messages"][1]["creationSource"] = "mcp"
        with self.assertRaises(api.GuardRefusal):
            api.queued_cancel_plan(bounded, "t", self.OWN)

    def test_a_queued_run_whose_message_is_not_shown_is_refused(self):
        bounded = copy.deepcopy(self.bounded)
        del bounded["projection"]["messages"][1]
        with self.assertRaises(api.GuardRefusal):
            api.queued_cancel_plan(bounded, "t", self.OWN)

    def test_unreadable_shapes_fail_loud(self):
        for key, value in (("runs", None), ("runs", {}), ("messages", None)):
            with self.subTest(key=key, value=value):
                bounded = copy.deepcopy(self.bounded)
                bounded["projection"][key] = value
                with self.assertRaises(api.ShapeError):
                    api.queued_cancel_plan(bounded, "t", self.OWN)
        bounded = copy.deepcopy(self.bounded)
        bounded["projection"]["runs"][1]["id"] = None
        with self.assertRaises(api.ShapeError):
            api.queued_cancel_plan(bounded, "t", self.OWN)
        with self.assertRaises(api.ShapeError):
            api.queued_cancel_plan(self.bounded, "another-thread", self.OWN)

    def test_cancel_command_has_exactly_the_server_shape(self):
        with mock.patch.dict(os.environ, {"OPS_T3_COMMAND_KEY": "k1"}):
            cmd = api._command(["cancel", "t", "run:thread:t:ordinal:2"])
        self.assertEqual(set(cmd), {"type", "commandId", "threadId", "runId"})
        self.assertEqual((cmd["type"], cmd["threadId"], cmd["runId"]),
                         ("queued-run.cancel", "t", "run:thread:t:ordinal:2"))
        self.assertTrue(cmd["commandId"].startswith("t3-api:cancel:t:") and cmd["commandId"].endswith(":k1"))
        with self.assertRaises(ValueError):
            api._command(["cancel", "t"])


class ReceiptTests(unittest.TestCase):
    def test_malformed_success_is_not_acceptance(self):
        for value in (None, [], {}, "ok", {"sequence": None}, {"sequence": True},
                      {"sequence": "9"}, {"sequence": -1}, {"sequence": 1.5}):
            with self.subTest(value=value), self.assertRaises(ws.BadFrame):
                ws.classify_exit({"_tag": "Success", "value": value})
        with self.assertRaises(ws.BadFrame):
            ws.classify_exit({"_tag": "Success"})

    def test_valid_receipt(self):
        self.assertEqual(ws.classify_exit({"_tag": "Success", "value": {"sequence": 9}}),
                         ("success", {"sequence": 9}))

    def test_lost_response_then_refused_upgrade_remains_ambiguous(self):
        once = mock.Mock(side_effect=[ws.TransportLost("lost response"), ws.UpgradeRefused("HTTP 401")])
        with self.assertRaises(ws.TransportLost) as raised:
            ws.call("http://127.0.0.1:1", "fixture", "orchestration.dispatchCommand",
                    {"commandId": "intent"}, pause=0, _once=once)
        self.assertIn("may already have been accepted", str(raised.exception))
        self.assertEqual(once.call_count, 2)

    def test_a_server_refusal_never_echoes_the_bearer_in_error_details_or_ids(self):
        token = "fixture-websocket-bearer-0123456789abcdef"
        with tempfile.TemporaryDirectory() as td:
            token_file, payload_file = Path(td) / "token", Path(td) / "payload.json"
            token_file.write_text(token)
            payload_file.write_text(json.dumps({"type": "thread.settle", "threadId": "t", "commandId": token}))
            failure = {"_tag": "Refusal:" + token, "message": "permission denied: " + token}
            stderr = io.StringIO()
            with mock.patch.object(ws, "call", return_value=("fail", failure, 1)), \
                    mock.patch.object(sys, "stderr", stderr):
                rc = ws.main(["t3_ws", "call", "http://127.0.0.1:1", str(token_file),
                              "orchestration.dispatchCommand", str(payload_file)])
        self.assertEqual(rc, 11)
        self.assertNotIn(token, stderr.getvalue())
        self.assertIn("permission denied", stderr.getvalue())


class CompactEvidenceTests(unittest.TestCase):
    def test_a_run_without_an_id_cannot_borrow_unattributed_compaction_evidence(self):
        for missing, run_id in ((True, None), (False, None), (False, ""), (False, " \t"), (False, 7)):
            with self.subTest(missing=missing, run_id=run_id):
                run = {"userMessageId": "compact-message", "ordinal": 1, "status": "completed"}
                item = {"type": "compaction", "status": "completed"}
                if not missing:
                    run["id"] = item["runId"] = run_id
                bounded = {"projection": {"thread": {"id": "t"}, "runs": [run], "turnItems": [item]}}
                with self.assertRaises(api.ShapeError):
                    api.compact_evidence(bounded, "t", "compact-message")

    def test_only_a_compaction_attributed_to_the_selected_run_proves_completion(self):
        run = {"id": "compact-run", "userMessageId": "compact-message", "ordinal": 1, "status": "completed"}
        item = {"type": "compaction", "status": "completed"}
        bounded = {"projection": {"thread": {"id": "t"}, "runs": [run], "turnItems": [item]}}
        self.assertEqual(api.compact_evidence(bounded, "t", "compact-message")[0], "failed")
        item["runId"] = run["id"]
        self.assertEqual(api.compact_evidence(bounded, "t", "compact-message")[0], "completed")


class TransportBaseTests(unittest.TestCase):
    def test_a_non_origin_base_never_dispatches_at_the_root_route(self):
        for base in ("http://127.0.0.1:1/other-server", "http://127.0.0.1:1?server=other",
                     "http://127.0.0.1:1#other-server", "http://user:pass@127.0.0.1:1",
                     "http://127.0.0.1:1?", "http://127.0.0.1:1#"):
            with self.subTest(base=base):
                once = mock.Mock(return_value=("success", {"sequence": 1}))
                with self.assertRaises(ValueError):
                    ws.call(base, "fixture", "orchestration.dispatchCommand",
                            {"type": "thread.settle", "commandId": "intent", "threadId": "t"}, _once=once)
                once.assert_not_called()

    def test_an_origin_with_a_root_slash_keeps_its_host_and_port(self):
        self.assertEqual(ws.parse_base("http://127.0.0.1:3790/"), ("127.0.0.1", 3790))


class HTTPErrorRedactionTests(unittest.TestCase):
    TOKEN = "fixture-http-bearer-0123456789abcdef"

    def run_failure(self, error_body, args=("snapshot",)):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/.well-known/t3/environment":
                    status, body = 200, '{"orchestrationProtocolVersion": 2}'
                else:
                    status, body = 401, error_body
                encoded = body.encode()
                self.send_response(status)
                self.send_header("Content-Type", "text/plain" if status == 401 else "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def log_message(self, *_args):
                pass

        # The module's guard already proved that the sandbox has only loopback and
        # cannot reach a live T3 server. The real CLI talks only to this local stub.
        with http.server.HTTPServer(("127.0.0.1", 0), Handler) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                with tempfile.TemporaryDirectory() as td:
                    token_file = Path(td) / "token"
                    token_file.write_text(self.TOKEN)
                    env = dict(os.environ, OPS_T3_BASE=f"http://127.0.0.1:{server.server_port}",
                               OPS_T3_TOKEN_FILE=str(token_file), T3CODE_HOME=td,
                               OPS_STATE_DIR=td, OPS_T3_HTTP_TIMEOUT="2")
                    return subprocess.run(["bash", str(HERE.parent / "t3-api.sh"), *args], env=env,
                                          capture_output=True, text=True, timeout=5)
            finally:
                server.shutdown()
                worker.join(timeout=5)

    def assert_safe_failure(self, result):
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertNotIn(self.TOKEN, result.stdout + result.stderr)
        # At byte 290 the old 300-byte preview exposed just the bearer prefix.
        self.assertNotIn(self.TOKEN[:10], result.stdout + result.stderr)
        self.assertIn("HTTP 401", result.stderr)
        self.assertIn("permission denied", result.stderr)

    def test_an_echoed_bearer_at_the_start_of_an_error_body_is_hidden(self):
        self.assert_safe_failure(self.run_failure(self.TOKEN + ": permission denied"))

    def test_an_echoed_bearer_is_hidden_before_cutting_the_error_preview(self):
        prefix = "permission denied: "
        body = prefix + "x" * (290 - len(prefix)) + self.TOKEN + " tail"
        self.assert_safe_failure(self.run_failure(body))

    def test_a_bearer_in_the_failed_request_path_is_hidden(self):
        self.assert_safe_failure(self.run_failure("permission denied", ("thread", self.TOKEN)))


class TrickleSocket:
    """Each byte arrives before the socket timeout, but the whole frame takes much longer."""
    def __init__(self, data, clock, timeout=1):
        self.data = bytearray(data)
        self.clock = clock
        self.timeout = timeout

    def recv(self, _n):
        delay = 0.4
        if self.timeout < delay:
            self.clock[0] += self.timeout
            raise TimeoutError
        self.clock[0] += delay
        if not self.data:
            return b""
        return bytes([self.data.pop(0)])

    def sendall(self, _data):
        pass

    def settimeout(self, timeout):
        self.timeout = timeout

    def gettimeout(self):
        return self.timeout

    def close(self):
        pass


class DeadlineTests(unittest.TestCase):
    def test_trickled_frame_cannot_extend_the_call_deadline(self):
        clock = [0.0]
        payload = json.dumps({"_tag": "Exit", "requestId": "1",
                              "exit": {"_tag": "Success", "value": {"sequence": 9}}}).encode()
        sock = TrickleSocket(bytes([0x81, len(payload)]) + payload, clock)
        with mock.patch.object(ws, "handshake", return_value=ws.Conn(sock, b"")), \
                mock.patch.object(ws.time, "monotonic", side_effect=lambda: clock[0]), \
                self.assertRaises(ws.TransportLost):
            ws.call_once("h", 1, "fixture", "orchestration.dispatchCommand", {}, timeout=1)
        self.assertLessEqual(clock[0], 1.01)

    def test_trickled_upgrade_cannot_extend_the_handshake_deadline(self):
        clock = [0.0]
        sock = TrickleSocket(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n", clock)
        with mock.patch.object(ws.socket, "create_connection", return_value=sock), \
                mock.patch.object(ws.time, "monotonic", side_effect=lambda: clock[0]), \
                self.assertRaises(ws.TransportLost):
            ws.handshake("h", 1, "fixture", timeout=1)
        self.assertLessEqual(clock[0], 1.01)


class WaiterTests(unittest.TestCase):
    @staticmethod
    def function(name):
        # Execute the actual production function, with only its IO dependencies faked.
        # Extracting it avoids the script's CLI and any token, network or detached process.
        source = (HERE.parent / "t3-api.sh").read_text()
        match = re.search(r"^" + name + r"\(\) \{.*?^\}", source, re.MULTILINE | re.DOTALL)
        if match is None:
            raise AssertionError("production function missing: " + name)
        return match.group()

    def run_waiter(self, shell_body, operator_body="printf 'harness|wake\\n'", dispatch_code=0):
        with tempfile.TemporaryDirectory() as td:
            script = "\n".join((
                "set -uo pipefail", "T3_PROTO=2", "STEP_FILE=$1/steps", "CLOCK_FILE=$1/clock",
                "printf '0\\n' > \"$STEP_FILE\"", "printf '0\\n' > \"$CLOCK_FILE\"",
                "poll_ms() { echo 0; }", "sleep() { :; }",
                "now_ms() { local n; read -r n < \"$CLOCK_FILE\"; echo \"$((n + 100))\" > \"$CLOCK_FILE\"; echo \"$n\"; }",
                "waiter_log() { printf '%s\\n' \"$*\"; }",
                "shell_verdict() { local n; read -r n < \"$STEP_FILE\"; n=$((n + 1)); echo \"$n\" > \"$STEP_FILE\"; " + shell_body + "; }",
                "v2_operator_check() { " + operator_body + "; }",
                "settle_dispatch() { printf 'dispatch at %s\\n' \"$(cat \"$STEP_FILE\")\" >&2; return " + str(dispatch_code) + "; }",
                self.function("cmd_settle_waiter"),
                "cmd_settle_waiter t 2 old; rc=$?; printf 'result=%s\\n' \"$rc\"",
            ))
            result = subprocess.run(["bash", "-c", script, "waiter-test", td], capture_output=True,
                                    text=True, timeout=5, check=True)
        return result.stdout, result.stderr

    def test_read_failure_breaks_consecutive_idle_reads(self):
        out, err = self.run_waiter("case $n in 2) return 4 ;; 4) printf 'busy|run|old\\n' ;; "
                                   "*) printf 'idle||old\\n' ;; esac")
        self.assertIn("result=0", out)
        self.assertIn("dispatch at 6", err)
        self.assertNotIn("dispatch at 3", err)

    def test_five_failed_message_reads_end_the_wait(self):
        out, err = self.run_waiter("printf 'busy|run|new\\n'", operator_body="return 4")
        self.assertIn("message read failed (rc=4, 5 of 5 in a row)", out)
        self.assertIn("result=4", out)
        self.assertNotIn("dispatch at", err)

    def test_final_rpc_errors_do_not_get_fresh_command_ids(self):
        for rc in (4, 6, 12):
            with self.subTest(rc=rc):
                out, err = self.run_waiter("printf 'idle||old\\n'", dispatch_code=rc)
                self.assertIn(f"result={rc}", out)
                self.assertEqual(err.count("dispatch at"), 1)

    def test_domain_refusals_still_get_three_attempts(self):
        out, err = self.run_waiter("printf 'idle||old\\n'", dispatch_code=11)
        self.assertIn("result=11", out)
        self.assertEqual(err.count("dispatch at"), 3)


if __name__ == "__main__":
    unittest.main()
