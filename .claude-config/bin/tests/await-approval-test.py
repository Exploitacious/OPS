#!/usr/bin/env python3
"""await-approval-test.py: behavior tests for bin/await-approval.

Why this exists: the waiter is what wakes an idle thread when an approve link is clicked
on a host that has no webhook callback. A waiter that exits 0 on a state that is not OPEN
lets the agent act on an approval it was never given; one that exits non-zero on OPEN
leaves the operator typing "Approved" again; one that loops tight hammers the server; one
that dies on SIGTERM without passing it on leaks a server-side session. Each is pinned here
against a stub of bin/mcp-http-call.py (no network, no real key, no real HOME). The answer
shapes are the status contract the script documents, in two kinds a configuration file
names: a flat record ("session") and a record under a key with a per-caller usable flag
("grant").

Cases: (1) open after pending polls, call shape and one masked line; (2) expired; (3) closed
after approval; (4) denied (status CLOSED, reason "denied", and a bare DENIED); (5) in-band
error; (6) timeout, with the wait clamped to the time left; (7) transient failures retried
then success, and five in a row fail; (8) fatal errors stop at once; (9) the record kind: open
usable, OPEN but not usable by this caller (exit 3, never 0), expired, closed, denied, an
answer without the usable flag; (10) a wrapped answer; (11) SIGTERM, SIGINT and SIGHUP reach
the poll and the waiter exits 128+signal; (12) the ~/.claude.json key fallback through
key_connectors, the key never printed, never in argv; (13) usage and configuration errors and
a missing caller; (14) pacing of an instant PENDING; (15) no temp directory left behind; (16)
the real mcp-http-call.py accepts the argument shape (offline, refuses before any network
call); (17) the default timeout is 1860 s, read from the script's own constant; (18)
classify_failure reads the HTTP status where the client puts it, and an isError is retried,
not fatal; (19) the scrub list is seeded from the key in $OPS_DIR/.env and ~/OPS/.env; (20)
every exit code is documented in the header and in bin/README.md; (21) the built-in default
kind and the configuration file's checks.

Exit 0 = all pass. Any failure exits non-zero and names the case.
"""
import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.join(HERE, "..")
SCRIPT = os.path.join(BIN, "await-approval")
ID = "3f2a91bc-1d2e-4f60-9a3b-5c6d7e8f9a0b"
GID = "8c1d44e0-0b1a-4c2d-8e3f-a4b5c6d7e8f9"
KEY = "test-dummy-key-7f3a91-not-real"
PASS = 0
FAIL = 0

CONFIG = {
    "default_kind": "session",
    "key_connectors": ["approvals"],
    "kinds": {
        "session": {"server": "approvals", "tool": "session_status",
                    "args": {"session_id": "{id}", "wait_s": "{wait}"}},
        "grant": {"server": "approvals", "tool": "grant",
                  "args": {"mode": "status", "grant_id": "{id}", "wait_s": "{wait}"},
                  "record": "grant", "usable_field": "usable_by_this_caller"},
        "local": {"server": None, "tool": "local_status", "args": {"id": "{id}", "wait_s": "{wait}", "fixed": "x"}},
    },
}

STUB = r'''#!/usr/bin/env python3
import json, os, signal, sys, time
argv = sys.argv[1:]
d = os.environ["STUB_DIR"]
server = None
if argv and argv[0] == "--server":
    server, argv = argv[1], argv[2:]
tool, args_path, out_path = argv[1], argv[2], argv[3]
scenario = json.load(open(os.path.join(d, "scenario.json")))
cp = os.path.join(d, "count")
n = int(open(cp).read()) if os.path.exists(cp) else 0
open(cp, "w").write(str(n + 1))
step = scenario[min(n, len(scenario) - 1)]
rec = {"argv": sys.argv[1:], "server": server, "tool": tool, "args": json.load(open(args_path)),
       "key": os.environ.get("OPS_MCP_API_KEY"), "args_mode": oct(os.stat(args_path).st_mode & 0o777), "n": n}
open(os.path.join(d, "calls.jsonl"), "a").write(json.dumps(rec) + "\n")
if step.get("needs_key") and not os.environ.get("OPS_MCP_API_KEY"):
    sys.stderr.write("ERROR: no API key: set OPS_MCP_API_KEY in the environment or in /nonexistent/OPS/.env\n")
    sys.exit(1)
if step.get("hang"):
    def term(sig, frm):
        open(os.path.join(d, "got-sigterm"), "w").write("1")
        sys.exit(143)
    signal.signal(signal.SIGTERM, term)
    open(os.path.join(d, "started"), "w").write("1")
    time.sleep(60)
    sys.exit(0)
if "err" in step:
    err = step["err"]
    if step.get("echo_key"):
        err += " token=" + os.environ.get("OPS_MCP_API_KEY", "")
    if step.get("echo_bearer"):
        err += " Authorization: Bearer " + step["echo_bearer"]
    if step.get("echo_literal"):
        err += " token=" + step["echo_literal"]
    sys.stderr.write(err + "\n")
    sys.exit(step.get("rc", 1))
fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    json.dump(step["out"], fh)
print("wrote " + out_path)
'''


def check(label, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        print("FAIL: %s" % label)
        if detail:
            print("  %s" % detail)


def session(status, **kw):
    d = {"session_id": ID, "status": status, "idle_seconds_remaining": None, "close_reason": None}
    d.update(kw)
    return {"out": d}


NO_USABLE = object()  # the answer carries no usable_by_this_caller key at all


def grant(status, usable=False, reason=None):
    view = {"grant_id": GID, "status": status, "requester": "someone", "closed_reason": reason}
    out = {"success": True, "grant": view}
    if usable is not NO_USABLE:
        out["usable_by_this_caller"] = usable
    return {"out": out}


def fail_step(err, rc=1, **kw):
    d = {"err": err, "rc": rc}
    d.update(kw)
    return d


class Case:
    """One run of await-approval against a stub scenario, in its own HOME and TMPDIR."""

    def __init__(self, root, name, config=CONFIG):
        self.dir = os.path.join(root, name)
        self.home = os.path.join(self.dir, "home")
        self.tmpdir = os.path.join(self.dir, "tmp")
        self.stub_dir = os.path.join(self.dir, "stub")
        for p in (self.home, self.tmpdir, self.stub_dir):
            os.makedirs(p)
        self.stub = os.path.join(self.stub_dir, "mcp-http-call.py")
        with open(self.stub, "w") as fh:
            fh.write(STUB)
        os.chmod(self.stub, 0o755)
        self.config_path = os.path.join(self.dir, "await-approval.json")
        if config is not None:
            with open(self.config_path, "w") as fh:
                json.dump(config, fh)

    def env(self, extra=None):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home, "TMPDIR": self.tmpdir,
               "STUB_DIR": self.stub_dir, "AWAIT_APPROVAL_MCP_CALL": self.stub,
               "AWAIT_APPROVAL_CONFIG": self.config_path, "AWAIT_APPROVAL_PACE_S": "0.05"}
        env.update(extra or {})
        return {k: v for k, v in env.items() if v is not None}

    def scenario(self, steps):
        with open(os.path.join(self.stub_dir, "scenario.json"), "w") as fh:
            json.dump(steps, fh)

    def run(self, steps, argv, env=None, timeout=60):
        self.scenario(steps)
        t0 = time.monotonic()
        p = subprocess.run([SCRIPT] + argv, env=self.env(env), capture_output=True, text=True, timeout=timeout)
        self.elapsed = time.monotonic() - t0
        self.rc, self.out, self.err = p.returncode, p.stdout, p.stderr
        return self

    @property
    def calls(self):
        path = os.path.join(self.stub_dir, "calls.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def leftover_tmp(self):
        return os.listdir(self.tmpdir)


def load_script():
    """await-approval as a module (it has no .py suffix), without writing a bytecode file
    beside it. Importing runs no main(), installs no signal handler and reads no key."""
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("await_approval_under_test", SCRIPT)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def one_line(case):
    lines = case.out.splitlines()
    return lines[0] if len(lines) == 1 else None


def main():
    root = tempfile.mkdtemp(prefix="await-approval-test-")
    try:
        run_cases(root)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("await-approval-test: %d passed, %d failed" % (PASS, FAIL))
    return 1 if FAIL else 0


def run_cases(root):
    # (1) PENDING twice, then OPEN. One masked line, the right call shape, exit 0.
    c = Case(root, "open").run(
        [session("PENDING", pending_seconds_remaining=1500), session("PENDING", pending_seconds_remaining=1460),
         session("OPEN", idle_seconds_remaining=900)], [ID])
    check("1 open: exit 0", c.rc == 0, "rc=%s out=%r err=%r" % (c.rc, c.out, c.err))
    check("1 open: one line with the state", bool(one_line(c)) and re.fullmatch(
        r"await-approval: session 3f2a91bc state=open exit=0 waited=\d+s idle_left=900s", one_line(c)), repr(c.out))
    check("1 open: the full id is never printed", ID not in c.out + c.err, repr(c.out))
    check("1 open: three polls", len(c.calls) == 3, str(len(c.calls)))
    first = c.calls[0]
    check("1 open: endpoint and tool", first["argv"][:4] == ["--server", "approvals", "call", "session_status"],
          str(first["argv"]))
    check("1 open: long poll of 40 s, the wait an integer", first["args"] == {"session_id": ID, "wait_s": 40}
          and isinstance(first["args"]["wait_s"], int), str(first["args"]))
    check("1 open: args file is owner-only", first["args_mode"] == "0o600", first["args_mode"])
    check("1 open: nothing left in TMPDIR", c.leftover_tmp() == [], str(c.leftover_tmp()))

    # (2) expired: a lapsed PENDING request reads as CLOSED with reason pending_expired.
    c = Case(root, "expired").run(
        [session("PENDING", pending_seconds_remaining=3), session("CLOSED", close_reason="pending_expired")], [ID])
    check("2 expired: exit 3", c.rc == 3, "rc=%s out=%r" % (c.rc, c.out))
    check("2 expired: state and reason", bool(one_line(c)) and "state=expired exit=3" in c.out
          and "reason=pending_expired" in c.out, repr(c.out))

    # (3) closed after an approval (the idle window ran out before the waiter looked).
    c = Case(root, "closed").run([session("CLOSED", close_reason="idle")], [ID])
    check("3 closed: exit 3 and the reason", c.rc == 3 and "state=closed" in c.out and "reason=idle" in c.out,
          "rc=%s out=%r" % (c.rc, c.out))

    # (4) denied: the Deny button closes a PENDING request, so the status is CLOSED and the reason
    # is "denied". It must read as denied and exit 3, never as a plain close and never as 0.
    c = Case(root, "denied").run(
        [session("PENDING", pending_seconds_remaining=1700), session("CLOSED", close_reason="denied")], [ID])
    check("4 denied (CLOSED, reason denied): exit 3", c.rc == 3, "rc=%s out=%r" % (c.rc, c.out))
    check("4 denied: state=denied with the reason, one line",
          bool(one_line(c)) and re.fullmatch(
              r"await-approval: session 3f2a91bc state=denied exit=3 waited=\d+s reason=denied", one_line(c)), repr(c.out))
    c = Case(root, "closed-other").run([session("CLOSED", close_reason="operator_disconnect")], [ID])
    check("4 a close that is not a denial stays closed",
          c.rc == 3 and "state=closed" in c.out and "state=denied" not in c.out, repr(c.out))
    c = Case(root, "denied-status").run([session("DENIED")], [ID])
    check("4 a bare DENIED status is read as denied", c.rc == 3 and "state=denied" in c.out, "rc=%s out=%r" % (c.rc, c.out))

    # (5) in-band error (an id the server never had, or forgot in a restart).
    c = Case(root, "notfound").run(
        [{"out": {"error": "not_found", "session_id": ID, "message": "No such session."}}], [ID])
    check("5 error answer: exit 2 after one call", c.rc == 2 and len(c.calls) == 1, "rc=%s calls=%d" % (c.rc, len(c.calls)))
    check("5 error answer: state=error and the code", "state=error exit=2" in c.out and "not_found" in c.out, repr(c.out))

    # (6) timeout: PENDING forever; the first wait is clamped to the time left.
    c = Case(root, "timeout").run([session("PENDING", pending_seconds_remaining=90)], [ID, "--timeout", "2"])
    check("6 timeout: exit 124", c.rc == 124, "rc=%s out=%r err=%r" % (c.rc, c.out, c.err))
    check("6 timeout: state and last", "state=timeout exit=124" in c.out and "last=pending" in c.out
          and "pending_left=90s" in c.out, repr(c.out))
    check("6 timeout: first wait is the whole seconds left (1 or 2 of 2), not 40",
          bool(c.calls) and c.calls[0]["args"]["wait_s"] in (1, 2), str(c.calls[:1]))
    check("6 timeout: ended on time", 1.5 <= c.elapsed < 8, "%.1fs" % c.elapsed)
    check("6 timeout: nothing left in TMPDIR", c.leftover_tmp() == [])

    # (7a) transient failures are retried; (7b) five in a row end it; the retry count shows.
    c = Case(root, "transient").run([fail_step("ERROR: HTTP 502 on tools/call: Bad Gateway"),
                                     fail_step("Traceback ... OSError: connection reset"),
                                     session("OPEN", idle_seconds_remaining=1800)], [ID])
    check("7a transient: recovers to exit 0 with retries=2", c.rc == 0 and "retries=2" in c.out and len(c.calls) == 3,
          "rc=%s out=%r calls=%d" % (c.rc, c.out, len(c.calls)))
    c = Case(root, "persistent").run([fail_step("ERROR: HTTP 503 on tools/call: unavailable")], [ID])
    check("7b persistent: exit 2 after exactly 5 calls", c.rc == 2 and len(c.calls) == 5, "rc=%s calls=%d" % (c.rc, len(c.calls)))
    check("7b persistent: the last error is in the line", "state=error" in c.out and "503" in c.out, repr(c.out))

    # (8) fatal errors stop at once, with a reason that names the fix.
    c = Case(root, "http401").run([fail_step("ERROR: HTTP 401 on initialize: unauthorized")], [ID])
    check("8 http 401: exit 2 after one call", c.rc == 2 and len(c.calls) == 1, "rc=%s calls=%d" % (c.rc, len(c.calls)))
    check("8 http 401: names the key", "401" in c.out and "API key" in c.out, repr(c.out))
    c = Case(root, "notool").run([fail_step("ERROR: no tool matching 'session_status'; available: ['x']")], [ID])
    check("8 no such tool: exit 2 after one call", c.rc == 2 and len(c.calls) == 1, "rc=%s" % c.rc)
    c = Case(root, "noendpoint").run([fail_step("ERROR: no endpoint configured: set OPS_MCP_URL for one endpoint")], [ID])
    check("8 no endpoint configured: exit 2 after one call, says so",
          c.rc == 2 and len(c.calls) == 1 and "endpoint configuration" in c.out, "rc=%s out=%r" % (c.rc, c.out))

    # (9) the record kind: the call shape, OPEN with usable yes and no, EXPIRED, CLOSED, errors.
    c = Case(root, "grant-open").run([grant("PENDING"), grant("OPEN", usable=True)], [GID, "--kind", "grant"])
    check("9 grant open: exit 0 with usable=yes", c.rc == 0 and "state=open" in c.out and "usable=yes" in c.out
          and one_line(c) and one_line(c).startswith("await-approval: grant 8c1d44e0 "), "rc=%s out=%r" % (c.rc, c.out))
    call = c.calls[0]
    check("9 grant: endpoint, tool and args", call["argv"][:4] == ["--server", "approvals", "call", "grant"]
          and call["args"] == {"mode": "status", "grant_id": GID, "wait_s": 40}, str(call))
    # An OPEN request this caller did not make (usable false) opens nothing for it: acting on it is
    # refused. Exit 0 would tell the agent to act, so it exits 3 as not_usable.
    c = Case(root, "grant-open-other").run([grant("OPEN", usable=False)], [GID, "--kind", "grant"])
    check("9 OPEN but not usable by this caller: exit 3, never 0", c.rc == 3, "rc=%s out=%r" % (c.rc, c.out))
    check("9 not usable: one line, state=not_usable, usable=no and why",
          bool(one_line(c)) and re.fullmatch(
              r"await-approval: grant 8c1d44e0 state=not_usable exit=3 waited=\d+s usable=no "
              r"reason=requested_by_another_caller", one_line(c)), repr(c.out))
    c = Case(root, "grant-open-nousable").run([grant("OPEN", usable=NO_USABLE)], [GID, "--kind", "grant"])
    check("9 OPEN with no usable flag in the answer: exit 2, never 0",
          c.rc == 2 and "state=error" in c.out and "usable_by_this_caller" in c.out, "rc=%s out=%r" % (c.rc, c.out))
    c = Case(root, "grant-pending-not-usable").run(
        [grant("PENDING", usable=False), grant("OPEN", usable=True)], [GID, "--kind", "grant"])
    check("9 PENDING reads usable=false but keeps waiting (only OPEN is judged)",
          c.rc == 0 and len(c.calls) == 2 and "usable=yes" in c.out, "rc=%s out=%r" % (c.rc, c.out))
    c = Case(root, "grant-denied").run([grant("PENDING"), grant("CLOSED", reason="denied")], [GID, "--kind", "grant"])
    check("9 denied (CLOSED, closed_reason denied): exit 3 and state=denied",
          c.rc == 3 and bool(one_line(c)) and re.fullmatch(
              r"await-approval: grant 8c1d44e0 state=denied exit=3 waited=\d+s reason=denied", one_line(c)),
          "rc=%s out=%r" % (c.rc, c.out))
    c = Case(root, "grant-expired").run([grant("EXPIRED", reason="pending_expired")], [GID, "--kind", "grant"])
    check("9 expired: exit 3", c.rc == 3 and "state=expired" in c.out and "reason=pending_expired" in c.out, repr(c.out))
    c = Case(root, "grant-closed").run([grant("CLOSED", reason="closed")], [GID, "--kind", "grant"])
    check("9 closed: exit 3", c.rc == 3 and "state=closed" in c.out and "reason=closed" in c.out, repr(c.out))
    c = Case(root, "grant-norecord").run([{"out": {"success": True}}], [GID, "--kind", "grant"])
    check("9 an answer without the record key: exit 2 and it says which key",
          c.rc == 2 and "state=error" in c.out and "no grant record" in c.out, "rc=%s out=%r" % (c.rc, c.out))
    c = Case(root, "grant-inband-error").run(
        [{"out": {"error": True, "code": "grant_refused", "message": "No such grant."}}], [GID, "--kind", "grant"])
    check("9 an in-band error answer stops at once: exit 2 after one call",
          c.rc == 2 and len(c.calls) == 1 and "state=error" in c.out, "rc=%s out=%r calls=%d" % (c.rc, c.out, len(c.calls)))
    # the kind with no server name uses the configured endpoint: no --server flag, a fixed arg passes through
    c = Case(root, "local").run([{"out": {"status": "OPEN"}}], [ID, "--kind", "local"])
    check("9 a kind with server null calls with no --server and passes fixed args through",
          c.rc == 0 and c.calls[0]["server"] is None and c.calls[0]["argv"][:2] == ["call", "local_status"]
          and c.calls[0]["args"] == {"id": ID, "wait_s": 40, "fixed": "x"}, str(c.calls[:1]))

    # (10) an answer wrapped in {"result": ...} reads the same, for both record shapes.
    c = Case(root, "wrapped").run([{"out": {"result": session("OPEN", idle_seconds_remaining=600)["out"]}}], [ID])
    check("10 wrapped flat answer: exit 0", c.rc == 0 and "state=open" in c.out, "rc=%s out=%r" % (c.rc, c.out))
    c = Case(root, "wrapped-grant").run([{"out": {"result": grant("OPEN", usable=True)["out"]}}], [GID, "--kind", "grant"])
    check("10 wrapped record answer: exit 0", c.rc == 0 and "usable=yes" in c.out, "rc=%s out=%r" % (c.rc, c.out))

    # (11) A stop signal is passed to the poll in flight as SIGTERM (so its session closes) and the
    # waiter exits 128 plus the signal: 143, 130, 129.
    for sig, name, want in ((signal.SIGTERM, "SIGTERM", 143), (signal.SIGINT, "SIGINT", 130),
                            (signal.SIGHUP, "SIGHUP", 129)):
        c = Case(root, "sig-" + name.lower())
        c.scenario([{"hang": True}])
        p = subprocess.Popen([SCRIPT, ID], env=c.env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        started = os.path.join(c.stub_dir, "started")
        end = time.monotonic() + 15
        while not os.path.exists(started) and time.monotonic() < end:
            time.sleep(0.05)
        check("11 %s: the poll started" % name, os.path.exists(started))
        p.send_signal(sig)
        try:
            out, err = p.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            p.kill()
            out, err = p.communicate()
            check("11 %s: the waiter ends promptly" % name, False, "had to kill it")
        check("11 %s: exit %d with state=interrupted" % (name, want),
              p.returncode == want and "state=interrupted exit=%d" % want in out,
              "rc=%s out=%r err=%r" % (p.returncode, out, err))
        check("11 %s: the poll got SIGTERM (its session can close)" % name,
              os.path.exists(os.path.join(c.stub_dir, "got-sigterm")))
        check("11 %s: nothing left in TMPDIR" % name, c.leftover_tmp() == [])

    # (12) the key. A box with no env key and no .env: the poll reports no key, and the waiter reads
    # a literal Bearer entry named in key_connectors from ~/.claude.json and passes it on via env.
    c = Case(root, "keyfb")
    with open(os.path.join(c.home, ".claude.json"), "w") as fh:
        json.dump({"mcpServers": {
            "other": {"type": "http", "headers": {"Authorization": "Bearer ${OPS_MCP_API_KEY}"}},
            "approvals": {"type": "http", "headers": {"Authorization": "Bearer " + KEY}}}}, fh)
    c.run([{"needs_key": True, **session("OPEN", idle_seconds_remaining=900)}], [ID])
    check("12 key fallback: exit 0 after the retry with the key", c.rc == 0 and len(c.calls) == 2, "rc=%s out=%r calls=%d"
          % (c.rc, c.out, len(c.calls)))
    check("12 key fallback: the poll received the key in its environment",
          len(c.calls) == 2 and c.calls[1]["key"] == KEY and c.calls[0]["key"] is None)
    check("12 key fallback: the key is in no argv, no args file, no output",
          all(KEY not in json.dumps(x["argv"]) + json.dumps(x["args"]) for x in c.calls) and KEY not in c.out + c.err)
    check("12 key fallback: not counted as a retry", "retries=" not in c.out, repr(c.out))
    c = Case(root, "keyfb-unnamed")
    with open(os.path.join(c.home, ".claude.json"), "w") as fh:
        json.dump({"mcpServers": {"unlisted": {"headers": {"Authorization": "Bearer " + KEY}}}}, fh)
    c.run([{"needs_key": True, **session("OPEN")}], [ID])
    check("12 a connector the configuration does not name is never read: exit 2 after one call",
          c.rc == 2 and len(c.calls) == 1, "rc=%s calls=%d" % (c.rc, len(c.calls)))
    c = Case(root, "keyfb-skipped").run([session("OPEN", idle_seconds_remaining=900)], [ID], env={"OPS_MCP_API_KEY": KEY})
    check("12 env key: used as it is", c.rc == 0 and c.calls[0]["key"] == KEY)
    c = Case(root, "nokey")
    with open(os.path.join(c.home, ".claude.json"), "w") as fh:
        json.dump({"mcpServers": {"approvals": {"headers": {"Authorization": "Bearer ${OPS_MCP_API_KEY}"}}}}, fh)
    c.run([{"needs_key": True, **session("OPEN")}], [ID])
    check("12 no key anywhere: exit 2 after one call, says how to fix it",
          c.rc == 2 and len(c.calls) == 1 and "OPS_MCP_API_KEY" in c.out, "rc=%s out=%r calls=%d"
          % (c.rc, c.out, len(c.calls)))
    c = Case(root, "scrub").run([fail_step("ERROR: HTTP 500 on tools/call: boom", echo_key=True)], [ID],
                                env={"OPS_MCP_API_KEY": KEY})
    check("12 scrub: a key echoed by server text is redacted", c.rc == 2 and KEY not in c.out + c.err
          and "<redacted>" in c.out, repr(c.out))
    other = "some-other-token-0123456789abcdef"
    c = Case(root, "scrub-bearer").run([fail_step("ERROR: HTTP 500 on tools/call: boom", echo_bearer=other)], [ID])
    check("12 scrub: a bearer token in server text is redacted even when it is not the known key",
          c.rc == 2 and other not in c.out + c.err and "Bearer <redacted>" in c.out, repr(c.out))

    # A wrapper refusal must survive unwrapping: OPEN in the nested record is
    # insufficient when the server says the status lookup failed.
    for label, answer in (
        ("outer-error", {"error": "not_authorized", "result": {"status": "OPEN"}}),
        ("outer-false", {"success": False, "result": {"status": "OPEN"}}),
        ("flat-false", {"success": False, "status": "OPEN"}),
        ("inner-false", {"result": {"success": False, "status": "OPEN"}}),
    ):
        c = Case(root, "refusal-" + label).run([{"out": answer}], [ID])
        check("5 %s: refusal wins over OPEN, never approves" % label,
              c.rc == 2 and "state=error" in c.out, "rc=%s out=%r" % (c.rc, c.out))
    c = Case(root, "refusal-grant").run(
        [{"out": {"error": "not_authorized", "result": grant("OPEN", True)["out"]}}],
        [GID, "--kind", "grant"])
    check("5 a grant envelope's refusal wins over OPEN and usable=true",
          c.rc == 2 and "state=error" in c.out, "rc=%s out=%r" % (c.rc, c.out))

    # A request id can itself authorize the follow-up call. Servers echo it in
    # failures and close reasons, so every server-controlled result field must
    # be scrubbed, quoted when needed, and kept on the one result line.
    approval_url = "https://example.invalid/approve/other-credential-1234567890"
    c = Case(root, "scrub-close-reason").run(
        [session("CLOSED", close_reason="revoked " + KEY + "\n" + ID + " " + approval_url)],
        [ID], env={"OPS_MCP_API_KEY": KEY})
    check("12 close reason: one line, no key, full request id or approval URL",
          c.rc == 3 and one_line(c) is not None and KEY not in c.out + c.err
          and ID not in c.out + c.err and approval_url not in c.out + c.err
          and 'reason="' in c.out, repr(c.out))
    c = Case(root, "scrub-request-id").run(
        [{"out": {"error": "not_found", "message": "No such request: " + ID}}], [ID])
    check("12 error detail: a server-echoed request id is masked too",
          c.rc == 2 and ID not in c.out + c.err and "<redacted>" in c.out, repr(c.out))

    # (13) usage and configuration errors, and a missing caller.
    c = Case(root, "usage")
    for label, argv in (("no id", []), ("bad kind", [ID, "--kind", "bogus"]), ("zero timeout", [ID, "--timeout", "0"]),
                        ("text timeout", [ID, "--timeout", "soon"]), ("huge timeout", [ID, "--timeout", "99999"]),
                        ("path-like id", ["../x/y/z/w"]), ("short id", ["ab"]), ("unknown flag", [ID, "--wat"])):
        c.run([session("OPEN")], argv)
        check("13 usage (%s): exit 2, usage on stderr, nothing on stdout, no call" % label,
              c.rc == 2 and "usage:" in c.err and c.out == "" and c.calls == [], "rc=%s err=%r" % (c.rc, c.err))
    c.run([session("OPEN")], [ID, "--kind", "bogus"])
    check("13 a bad kind lists the configured ones", "grant" in c.err and "session" in c.err, repr(c.err))
    c.run([session("OPEN")], ["-h"])
    check("13 help: exit 0, the default timeout and what a box needs", c.rc == 0 and "1860" in c.out and "box needs" in c.out)
    c = Case(root, "nocaller").run([session("OPEN")], [ID], env={"AWAIT_APPROVAL_MCP_CALL": "/nonexistent/mcp-http-call.py"})
    check("13 missing caller: exit 2 and what a box needs",
          c.rc == 2 and "state=error" in c.out and "box needs" in c.out, "rc=%s out=%r" % (c.rc, c.out))
    for label, content in (("invalid JSON", "{not json"), ("no kinds", '{"kinds": {}}'), ("kinds not an object", '{"kinds": []}'),
                           ("unknown default_kind", '{"default_kind": "x", "kinds": {"a": {"tool": "t"}}}'),
                           ("kind without a tool", '{"kinds": {"a": {"args": {}}}}'),
                           ("a server name that is a path", '{"kinds": {"a": {"tool": "t", "server": "a/../b"}}}'),
                           ("a bad kind name", '{"kinds": {"a b": {"tool": "t"}}}'),
                           ("key_connectors not a list", '{"kinds": {"a": {"tool": "t"}}, "key_connectors": "x"}')):
        c = Case(root, "cfg-" + re.sub(r"\W+", "-", label), config=None)
        with open(c.config_path, "w") as fh:
            fh.write(content)
        c.run([session("OPEN")], [ID])
        check("13 configuration (%s): exit 2, a message, no call" % label,
              c.rc == 2 and "usage:" in c.err and c.out == "" and c.calls == [], "rc=%s err=%r" % (c.rc, c.err))
    c = Case(root, "cfg-missing", config=None).run([session("OPEN")], [ID])
    check("13 an AWAIT_APPROVAL_CONFIG that does not exist is an error, not a silent default",
          c.rc == 2 and "does not exist" in c.err and c.calls == [], "rc=%s err=%r" % (c.rc, c.err))
    c = Case(root, "cfg-help", config=None)
    with open(c.config_path, "w") as fh:
        fh.write("{not json")
    c.run([session("OPEN")], ["--help"])
    check("13 help works even when the configuration is broken", c.rc == 0 and "1860" in c.out)

    # (14) pacing: an instant PENDING answer is not polled in a tight loop.
    c = Case(root, "pacing").run([session("PENDING")], [ID, "--timeout", "2"], env={"AWAIT_APPROVAL_PACE_S": "0.5"})
    check("14 pacing: about 4 polls in 2 s at a 0.5 s pace, never a tight loop",
          c.rc == 124 and 2 <= len(c.calls) <= 6, "rc=%s calls=%d" % (c.rc, len(c.calls)))

    # (16) the real mcp-http-call.py takes the argument shape and refuses before any network call:
    # first with no endpoint configured, then with an endpoint but no key (the dummy HOME has no
    # .env and the env has no key), so this proves the contract with the real client offline.
    real_call = os.path.join(BIN, "mcp-http-call.py")
    c = Case(root, "realcall")
    args = os.path.join(c.dir, "a.json")
    with open(args, "w") as fh:
        json.dump({"session_id": ID, "wait_s": 0}, fh)
    env = c.env()
    env.pop("AWAIT_APPROVAL_MCP_CALL")
    env.update({"HTTPS_PROXY": "http://127.0.0.1:9", "HTTP_PROXY": "http://127.0.0.1:9", "NO_PROXY": ""})
    p = subprocess.run([sys.executable, real_call, "call", "session_status", args, os.path.join(c.dir, "o.json")],
                       env=env, capture_output=True, text=True, timeout=30)
    check("16 real client: no endpoint means a refusal in its own words, exit 1",
          p.returncode == 1 and p.stderr.startswith("ERROR: no endpoint configured"), "rc=%s err=%r" % (p.returncode, p.stderr))
    env["OPS_MCP_URL"] = "https://example.invalid/mcp"
    env["OPS_DIR"] = os.path.join(c.dir, "no-ops-dir")
    p = subprocess.run([sys.executable, real_call, "call", "session_status", args, os.path.join(c.dir, "o.json")],
                       env=env, capture_output=True, text=True, timeout=30)
    check("16 real client: no key means a refusal in its own words, exit 1",
          p.returncode == 1 and p.stderr.startswith("ERROR: no API key"), "rc=%s err=%r" % (p.returncode, p.stderr))
    c.run([session("OPEN")], [ID, "--kind", "local"], env={"AWAIT_APPROVAL_MCP_CALL": real_call, "OPS_MCP_URL": "https://example.invalid/mcp",
                                                          "OPS_DIR": os.path.join(c.dir, "no-ops-dir")})
    check("16 real client through await-approval with no key: exit 2 and the fix",
          c.rc == 2 and "no API key" in c.out, "rc=%s out=%r err=%r" % (c.rc, c.out, c.err))
    c.run([session("OPEN")], [ID, "--kind", "local"], env={"AWAIT_APPROVAL_MCP_CALL": real_call})
    check("16 real client through await-approval with no endpoint: exit 2 and the fix",
          c.rc == 2 and "endpoint configuration" in c.out, "rc=%s out=%r err=%r" % (c.rc, c.out, c.err))

    # (17) the default --timeout is 1860 s: a 1800 s pending window plus a 60 s margin, so the
    # server's own expiry lands before the waiter's deadline and the last poll reads it. Read from
    # the script's constant and from the parser, not from the help text.
    mod = load_script()
    check("17 DEFAULT_TIMEOUT_S is 1860", mod.DEFAULT_TIMEOUT_S == 1860, repr(mod.DEFAULT_TIMEOUT_S))
    check("17 no --timeout parses to that default", mod.parse([ID]).timeout == 1860.0, repr(mod.parse([ID]).timeout))
    check("17 an explicit --timeout still wins", mod.parse([ID, "--timeout", "90"]).timeout == 90.0)

    # (18) classify_failure reads the HTTP status where mcp-http-call.py puts it (the first
    # "ERROR: HTTP <status> on <method>:" line), not anywhere in the text. The client prints up to
    # 500 characters of the response body after that header, so a 5xx whose body quotes "HTTP 403"
    # must not read as a refused key. An isError answer is retried (up to the poll limit), not fatal.
    iserr = ('ERROR: tool billing__write returned isError: {"content": [{"type": "text", "text": "upstream timed out"}], '
             '"isError": true}')
    table = (
        ("401 at the status position", 'ERROR: HTTP 401 on initialize: {"error":"invalid_credentials"}', True, "HTTP 401"),
        ("403 at the status position", "ERROR: HTTP 403 on tools/call: forbidden", True, "HTTP 403"),
        ("404 at the status position", "ERROR: HTTP 404 on initialize: not found", True, "HTTP 404"),
        ("401 after unrelated noise lines", "UserWarning: something\nERROR: HTTP 401 on initialize: x", True, "HTTP 401"),
        ("502 whose body quotes HTTP 403", "ERROR: HTTP 502 on tools/call: upstream replied HTTP 403 forbidden", False, None),
        ("500 whose body has a line quoting HTTP 401", "ERROR: HTTP 500 on tools/call: <html>\nHTTP 401 Unauthorized\n</html>",
         False, None),
        ("502 whose body has a line that looks like a client error line",
         "ERROR: HTTP 502 on tools/call: x\nERROR: HTTP 403 on initialize: y", False, None),
        ("503 whose body says no tool matching", "ERROR: HTTP 503 on tools/call: no tool matching 'x'", False, None),
        ("no tool matching at the message position", "ERROR: no tool matching 'session_status'; available: ['x']", True,
         "no such tool"),
        ("no endpoint configured", "ERROR: no endpoint configured: set OPS_MCP_URL", True, "endpoint configuration"),
        ("--server without a template", "ERROR: --server needs OPS_MCP_URL_TEMPLATE, a URL with {server} in it", True,
         "endpoint configuration"),
        ("isError", iserr, False, None),
        ("a network error line", "ERROR: network error: [Errno 111] Connection refused", False, None),
        ("a dropped connection traceback", "Traceback (most recent call last):\n  OSError: reset", False, None),
        ("nothing on stderr", "", False, None),
    )
    for label, text, want_fatal, want_text in table:
        poll = mod.classify_failure(text)
        check("18 classify_failure (%s): fatal=%s" % (label, want_fatal), poll.fatal is want_fatal and not poll.no_key,
              "fatal=%r no_key=%r err=%r" % (poll.fatal, poll.no_key, poll.err))
        if want_text:
            check("18 classify_failure (%s): the reason names it" % label, want_text in poll.err, repr(poll.err))
    check("18 no key at the message position is no_key",
          mod.classify_failure("ERROR: no API key: set OPS_MCP_API_KEY in the environment or in /h/OPS/.env").no_key)
    check("18 a 5xx body that mentions the missing key is not no_key",
          not mod.classify_failure("ERROR: HTTP 502 on tools/call: no API key: x").no_key)
    # end to end: a 502 whose body quotes HTTP 403 is retried, not ended at once; an isError is retried
    # and recovers, and when it never recovers it stops at the poll limit (5 in a row) with its text.
    c = Case(root, "quoted403").run([fail_step("ERROR: HTTP 502 on tools/call: upstream replied HTTP 403 forbidden"),
                                     session("OPEN", idle_seconds_remaining=900)], [ID])
    check("18 a 502 quoting HTTP 403 is retried: exit 0 after 2 calls, retries=1",
          c.rc == 0 and len(c.calls) == 2 and "retries=1" in c.out, "rc=%s out=%r calls=%d" % (c.rc, c.out, len(c.calls)))
    c = Case(root, "iserror-recover").run([fail_step(iserr), session("OPEN", idle_seconds_remaining=900)], [ID])
    check("18 an isError is retried: exit 0 after 2 calls, retries=1",
          c.rc == 0 and len(c.calls) == 2 and "retries=1" in c.out, "rc=%s out=%r calls=%d" % (c.rc, c.out, len(c.calls)))
    c = Case(root, "iserror-persist").run([fail_step(iserr)], [ID])
    check("18 an isError that never clears ends at the poll limit: exit 2 after exactly 5 calls",
          c.rc == 2 and len(c.calls) == 5 and "state=error" in c.out and "isError" in c.out,
          "rc=%s out=%r calls=%d" % (c.rc, c.out, len(c.calls)))

    # (19) the scrub list is seeded from the key the poll would read from $OPS_DIR/.env or ~/OPS/.env,
    # read in this process and never printed. The waiter's own layer matters when the poll's text
    # reaches it unscrubbed (a traceback, a proxy page that echoes a header): the bearer pattern
    # does not catch a bare token.
    for label, rel, line, extra_env in (
            ("OPS/.env", "OPS/.env", "OPS_MCP_API_KEY=%s\n", {}),
            ("OPS/.env, quoted", "OPS/.env", 'OPS_MCP_API_KEY="%s"\n', {}),
            ("OPS/.env, export form", "OPS/.env", "export OPS_MCP_API_KEY=%s\n", {}),
            ("a custom variable name", "OPS/.env", "EXAMPLE_KEY=%s\n", {"OPS_MCP_KEY_VAR": "EXAMPLE_KEY"})):
        envkey = "envfile-key-%s-0123456789abcdef" % re.sub(r"\W+", "", label).lower()
        c = Case(root, "scrub-" + re.sub(r"\W+", "-", label))
        os.makedirs(os.path.dirname(os.path.join(c.home, rel)))
        with open(os.path.join(c.home, rel), "w") as fh:
            fh.write("OTHER=1\n" + line % envkey)
        c.run([fail_step("ERROR: HTTP 500 on tools/call: upstream echoed", echo_literal=envkey)], [ID], env=extra_env)
        check("19 scrub from %s: exit 2, the key redacted, never printed" % label,
              c.rc == 2 and envkey not in c.out + c.err and "<redacted>" in c.out, "rc=%s out=%r err=%r" % (c.rc, c.out, c.err))
    c = Case(root, "scrub-both")
    other_dir = os.path.join(c.dir, "ops-elsewhere")
    for path, key in ((os.path.join(c.home, "OPS", ".env"), "home-ops-env-key-aaaaaaaa1111"),
                      (os.path.join(other_dir, ".env"), "dir-ops-env-key-bbbbbbbb2222")):
        os.makedirs(os.path.dirname(path))
        with open(path, "w") as fh:
            fh.write("OPS_MCP_API_KEY=%s\n" % key)
    c.run([fail_step("ERROR: HTTP 500 on tools/call: first home-ops-env-key-aaaaaaaa1111 then dir-ops-env-key-bbbbbbbb2222")],
          [ID], env={"OPS_DIR": other_dir})
    check("19 scrub: $OPS_DIR/.env and ~/OPS/.env both seed the list",
          c.rc == 2 and "home-ops-env-key-aaaaaaaa1111" not in c.out and "dir-ops-env-key-bbbbbbbb2222" not in c.out, repr(c.out))
    c = Case(root, "scrub-noenvfile").run([fail_step("ERROR: HTTP 500 on tools/call: plain text")], [ID])
    check("19 no .env file anywhere: nothing breaks, text is kept", c.rc == 2 and "plain text" in c.out, repr(c.out))

    # (20) every exit code the waiter can return is documented in its header (-h) and in the
    # bin/README.md section: 0 open, 2 error, 3 not approved (expired, closed, denied, not_usable),
    # 124 timeout, 128 plus the signal (143 SIGTERM, 130 SIGINT, 129 SIGHUP).
    c = Case(root, "docs")
    c.run([session("OPEN")], ["-h"])
    header = c.out
    for code, word in ((0, "approved"), (2, "error"), (3, "expired"), (124, "timeout")):
        check("20 header documents exit %d" % code, re.search(r"^\s+%d\s" % code, header, re.M) is not None
              and word in header, "no line for %d" % code)
    check("20 header documents 128+signal with 143, 130 and 129 and state=interrupted",
          re.search(r"^\s+128\+", header, re.M) is not None and all(x in header for x in ("143", "130", "129", "interrupted")))
    check("20 header names the not-approved states: denied, expired, closed, not_usable",
          all(x in header for x in ("denied", "expired", "closed", "not_usable")))
    with open(os.path.join(BIN, "README.md")) as fh:
        readme = fh.read()
    para = [ln for ln in readme.splitlines() if ln.startswith("`await-approval <id>")]
    check("20 README has the await-approval section", len(para) == 1, str(len(para)))
    if para:
        section = para[0]
        check("20 README documents 0, 2, 3, 124 and 128+signal (143, 130, 129)",
              all(x in section for x in ("0", "2", "3", "124", "128+", "143", "130", "129")), section[:300])
        check("20 README names denied, closed, expired and not_usable",
              all(x in section for x in ("denied", "closed", "expired", "not_usable")), section[:300])

    # (21) with no configuration file the built-in kind applies: neutral tool, no server name.
    c = Case(root, "builtin", config=None)
    c.run([session("OPEN", idle_seconds_remaining=900)], [ID], env={"AWAIT_APPROVAL_CONFIG": None})
    check("21 built-in kind: exit 0, called as `call approval_status` with no --server, args id and wait_s",
          c.rc == 0 and c.calls[0]["server"] is None and c.calls[0]["tool"] == "approval_status"
          and c.calls[0]["args"] == {"id": ID, "wait_s": 40} and one_line(c).startswith("await-approval: default 3f2a91bc state=open"),
          "rc=%s out=%r calls=%r" % (c.rc, c.out, c.calls[:1]))
    check("21 built-in kind: the answer reads as a flat record", "idle_left=900s" in c.out, repr(c.out))
    check("21 the built-in configuration names no server", mod.DEFAULT_CONFIG["kinds"]["default"]["server"] is None
          and mod.DEFAULT_CONFIG["key_connectors"] == [])
    check("21 fill_args substitutes only the two placeholders, wait as an integer",
          mod.fill_args({"a": "{id}", "b": "{wait}", "c": "{id}x", "d": 7}, "idid", 12) == {"a": "idid", "b": 12, "c": "{id}x", "d": 7})


if __name__ == "__main__":
    sys.exit(main())
