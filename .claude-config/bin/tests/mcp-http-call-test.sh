#!/usr/bin/env bash
# mcp-http-call-test.sh: behavior tests for bin/mcp-http-call.py, the script-side
# MCP client (list, call, batch), with no network and no real key.
#
# Why each case exists. A hand-rolled client that opens a session per call and
# never closes it leaks live sessions against a per-key cap; the first versions of
# this client had gaps a review found, and each case below pins one:
#   (a) a configured endpoint: --server fills OPS_MCP_URL_TEMPLATE, and every
#       request and the closing DELETE go to that URL; without --server the fixed
#       OPS_MCP_URL is used; with neither, the run refuses before any session
#   (b) nothing defaults: --server without a template, an odd --server name, and a
#       URL that is not http or https (file:, ftp:) are all refused before any
#       request
#   (c) batch runs N calls on ONE initialize and closes once; out files are 0600,
#       and on Windows (no owner-only mode) an out file is refused before dispatch
#   (d) a failed call stops the batch, exits 1, records the line, still closes
#   (e) an isError answer, an unknown tool and in-band refusals ({"success":false},
#       {"error":...}, {"status":"failed"}, {"partial":true}, {"error_code":...})
#       all stop the batch
#   (f) an interrupted call (a network error or a termination signal) is recorded
#       as state unknown and the session is still closed
#   (g) a bad calls file opens no session and clears a stale out file
#   (h) the key is scrubbed from server text die() prints; a key with whitespace
#       is refused without printing it; the key comes from the environment, a
#       custom variable name, or $OPS_DIR/.env
#   (i) a truncated tool name does not resolve; non-object JSON answers do not crash
#   (j) the HTTP layer (urllib, no package): headers, the DELETE, a 3xx is refused
#       and never followed (the bearer key must not follow a redirect), a 401 is
#       reported with its status and the key scrubbed, a dropped connection is a
#       one-line error, and an SSE body decodes as UTF-8 even without a charset
#   (k) server text is redacted before it is clipped: a key echoed across each
#       cutoff leaves no prefix, a JSON-escaped key is still found, `list` output
#       and the call preview are redacted, and server text never starts a line
#   (l) a refusal code named in OPS_MCP_REFUSAL_CODES gets exactly one NOTE line
#       (key source, at most the last four characters, connector), read from
#       structured fields only; quoted output gets none; exit codes are unchanged
# A stub HTTP session or a stubbed opener stands in for the network.
#
# Exit 0 = all pass. Any failure exits non-zero and names the case.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../mcp-http-call.py"
[ -f "$CLI" ] || { echo "cannot find CLI at $CLI" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# (a)/(b) the refusals that need no session. A dead local proxy: if a regression
# ever lets one of these reach the network, the request fails here instead of
# reaching a real server.
DEAD=(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY= OPS_MCP_API_KEY=dummy-not-real)
refuse() {  # refuse <label> <expected stderr text> <env assignments...> -- <args...>
  local label="$1" want="$2" out rc; shift 2
  local envs=(); while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  out="$(env -u OPS_MCP_URL -u OPS_MCP_URL_TEMPLATE "${DEAD[@]}" "${envs[@]}" python3 "$CLI" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne 1 ] || ! grep -q -- "$want" <<<"$out"; then
    echo "FAIL: (b) $label: rc=$rc out=$out"; exit 1
  fi
}
refuse "no endpoint configured" "no endpoint configured" -- list
refuse "no endpoint configured for call" "no endpoint configured" -- call tool x.json
refuse "--server without a template" "needs OPS_MCP_URL_TEMPLATE" -- --server billing list
refuse "a template without {server}" "needs OPS_MCP_URL_TEMPLATE" OPS_MCP_URL_TEMPLATE=https://example.invalid/mcp -- --server billing list
refuse "a file: URL" "must be an http or https URL" OPS_MCP_URL=file:///etc/passwd -- list
refuse "an ftp: URL" "must be an http or https URL" OPS_MCP_URL=ftp://example.invalid/mcp -- list
refuse "a template that builds a file: URL" "must be an http or https URL" OPS_MCP_URL_TEMPLATE=file:///{server} -- --server billing list
refuse "a URL with whitespace" "must be an http or https URL" "OPS_MCP_URL=https://example.invalid/a b" -- list
refuse "no key" "no API key" OPS_MCP_URL=https://example.invalid/mcp OPS_MCP_API_KEY= OPS_DIR="$TMP/no-such-dir" -- list

CLI="$CLI" TMP="$TMP" python3 - <<'PY'
import contextlib, importlib.util, io, json, os, sys, types, urllib.error

KEY = "test-dummy-key-7f3a91-not-real"
URL = "https://example.invalid/mcp"
TEMPLATE = "https://example.invalid/gw/{server}/mcp"
os.environ["OPS_MCP_API_KEY"] = KEY
os.environ["OPS_MCP_URL_TEMPLATE"] = TEMPLATE
for name in ("OPS_MCP_URL", "OPS_MCP_KEY_VAR", "OPS_MCP_CLIENT_NAME"):
    os.environ.pop(name, None)
TMP = os.environ["TMP"]
PASS = FAIL = 0


def check(label, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        print("FAIL: %s\n  %s" % (label, detail or "condition false"))


def load():
    sys.argv = ["mcp-http-call.py"]
    spec = importlib.util.spec_from_file_location("mhc_%d" % len(sys.modules), os.environ["CLI"])
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Resp:
    def __init__(self, payload, sid=None, status=200):
        self.status_code = status
        self.headers = {"Content-Type": "application/json"}
        if sid:
            self.headers["mcp-session-id"] = sid
        self.content = (json.dumps(payload) if payload is not None else "").encode()


TOOLS = ["billing__invoice_query", "billing__catalog", "billing__write"]


class StubSession:
    """A fake server. answers maps a tool name to one of:
    ("rpc_error",) | ("is_error",) | ("raise", exc) | ("struct", obj) | ("text", str) |
    ("http_error", status, bytes) | ("raw", bytes) | ("raw_ctype", content_type, bytes) |
    ("rpc_error_obj", error_obj) | ("is_error_text", str) | ("is_error_res", result_obj).
    tools, when given, is the tools/list answer (a list of tool objects)."""

    def __init__(self, answers=None, tools=None):
        self.headers = {}
        self.posts, self.deletes = [], []
        self.answers = answers or {}
        self.tools = tools

    def post(self, url, json=None, headers=None, timeout=None):
        import json as J
        self.posts.append({"url": url, "method": json.get("method"), "params": json.get("params"),
                           "sid": (headers or {}).get("mcp-session-id")})
        m, rid = json.get("method"), json.get("id")
        if m == "initialize":
            return Resp({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": "2025-06-18"}}, sid="sess-1")
        if m == "notifications/initialized":
            return Resp(None, status=202)
        if m == "tools/list":
            tools = self.tools if self.tools is not None else [{"name": n} for n in TOOLS]
            return Resp({"jsonrpc": "2.0", "id": rid, "result": {"tools": tools}})
        if m == "tools/call":
            name = json["params"]["name"]
            a = self.answers.get(name, ("text", J.dumps({"ok": True, "tool": name})))
            if a[0] in ("http_error", "raw"):
                response = Resp(None, status=a[1] if a[0] == "http_error" else 200)
                response.content = a[2] if a[0] == "http_error" else a[1]
                return response
            if a[0] == "raw_ctype":
                response = Resp(None)
                response.headers["Content-Type"] = a[1]
                response.content = a[2]
                return response
            if a[0] == "rpc_error":
                return Resp({"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": "boom"}})
            if a[0] == "rpc_error_obj":
                return Resp({"jsonrpc": "2.0", "id": rid, "error": a[1]})
            if a[0] == "is_error":
                return Resp({"jsonrpc": "2.0", "id": rid, "result": {"isError": True, "content": [{"type": "text", "text": "nope"}]}})
            if a[0] == "is_error_text":
                return Resp({"jsonrpc": "2.0", "id": rid, "result": {"isError": True, "content": [{"type": "text", "text": a[1]}]}})
            if a[0] == "is_error_res":
                return Resp({"jsonrpc": "2.0", "id": rid, "result": a[1]})
            if a[0] == "raise":
                raise a[1]
            if a[0] == "struct":
                return Resp({"jsonrpc": "2.0", "id": rid, "result": {"structuredContent": a[1]}})
            return Resp({"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": a[1]}]}})
        raise AssertionError("unexpected method %r" % m)

    def delete(self, url, headers=None, timeout=None):
        self.deletes.append({"url": url, "sid": (headers or {}).get("mcp-session-id")})
        return types.SimpleNamespace(status_code=200)


def run(mod, argv, stub):
    """Run main() with a stubbed session; return (exit code, stderr, exception)."""
    real_init = mod.Client.__init__

    def init(self):
        real_init(self)
        self.session = stub
    mod.Client.__init__ = init
    sys.argv = argv
    code, exc, err = 0, None, io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
        try:
            mod.main()
        except SystemExit as e:
            code = e.code
        except BaseException as e:  # noqa: BLE001 - interrupted paths propagate on purpose
            exc = e
    return code, err.getvalue(), exc


def calls_file(name, tools):
    p = os.path.join(TMP, name)
    with open(p, "w") as fh:
        for t in tools:
            fh.write((t if t == "" else json.dumps({"tool": t, "args": {}})) + "\n")
    return p


def rows(p):
    return [json.loads(l) for l in open(p) if l.strip()]


tcalls = lambda s: [p for p in s.posts if p["method"] == "tools/call"]
WANT = "https://example.invalid/gw/billing/mcp"
three = calls_file("three.jsonl", ["catalog", "invoice_query", "", "catalog"])

# (a) and (c): endpoint, one session, one close, one row per call
m = load(); stub = StubSession(); out = os.path.join(TMP, "a.jsonl")
code, _, exc = run(m, ["mcp-http-call.py", "--server", "billing", "batch", three, out], stub)
check("(a) batch exits 0", code in (0, None) and exc is None, "code=%r exc=%r" % (code, exc))
check("(a) every POST goes to the --server endpoint", all(p["url"] == WANT for p in stub.posts), str({p["url"] for p in stub.posts}))
check("(a) the DELETE goes to the --server endpoint", [d["url"] for d in stub.deletes] == [WANT], str(stub.deletes))
check("(c) exactly one initialize", len([p for p in stub.posts if p["method"] == "initialize"]) == 1)
check("(c) one tools/list for the whole batch", len([p for p in stub.posts if p["method"] == "tools/list"]) == 1)
check("(c) three tools/call on the one session", [p["sid"] for p in tcalls(stub)] == ["sess-1"] * 3, str(tcalls(stub)))
check("(c) exactly one DELETE", [d["sid"] for d in stub.deletes] == ["sess-1"], str(stub.deletes))
check("(c) one ok row per call, in order", [(r["line"], r["ok"]) for r in rows(out)] == [(1, True), (2, True), (4, True)], str(rows(out)))
check("(c) batch out file is mode 0600", oct(os.stat(out).st_mode & 0o777) == "0o600", oct(os.stat(out).st_mode & 0o777))

# the fixed endpoint, with no --server
os.environ["OPS_MCP_URL"] = URL
m = load(); stub = StubSession()
code, _, exc = run(m, ["mcp-http-call.py", "list"], stub)
check("(a) OPS_MCP_URL serves a run with no --server", code in (0, None) and exc is None
      and all(p["url"] == URL for p in stub.posts) and [d["url"] for d in stub.deletes] == [URL], str(stub.posts))
m = load(); stub = StubSession()
code, _, exc = run(m, ["mcp-http-call.py", "--server", "billing", "list"], stub)
check("(a) --server wins over OPS_MCP_URL", all(p["url"] == WANT for p in stub.posts), str({p["url"] for p in stub.posts}))
del os.environ["OPS_MCP_URL"]

pre = os.path.join(TMP, "pre.json")
open(pre, "w").write("old")
os.chmod(pre, 0o644)
m = load(); stub = StubSession()
args_json = os.path.join(TMP, "args.json")
with open(args_json, "w") as fh:
    fh.write("{}")
code, _, _ = run(m, ["mcp-http-call.py", "--server", "billing", "call", "catalog", args_json, pre], stub)
check("(c) call out.json rewritten as 0600 even when it existed as 0644",
      oct(os.stat(pre).st_mode & 0o777) == "0o600" and json.load(open(pre)).get("tool") == "billing__catalog", oct(os.stat(pre).st_mode & 0o777))

# Older Python builds can lack os.fchmod. Refuse output explicitly rather than
# crashing or silently substituting permissions with different guarantees.
m = load()
m.os = types.SimpleNamespace(**{name: getattr(os, name) for name in
                              ("open", "fdopen", "close", "chmod", "O_WRONLY", "O_CREAT", "O_TRUNC")})
portable_out = os.path.join(TMP, "portable-output.json")
open(portable_out, "w").write("stale")
os.chmod(portable_out, 0o644)
portable_error = None
try:
    with m.private_open(portable_out) as fh:
        fh.write("fresh")
except Exception as exc:
    portable_error = exc
check("(c) output without os.fchmod fails with a controlled permission error",
      isinstance(portable_error, OSError) and open(portable_out).read() == "", repr(portable_error))

opened_fds = []


def record_open(*args):
    fd = os.open(*args)
    opened_fds.append(fd)
    return fd


def deny_mode(*args):
    raise PermissionError("mode change refused")


m.os.open, m.os.fchmod = record_open, deny_mode
mode_error = None
try:
    m.private_open(portable_out)
except OSError as exc:
    mode_error = exc
fd_closed = False
try:
    os.fstat(opened_fds[-1])
except OSError:
    fd_closed = True
check("(c) a failed permission change refuses output and closes the descriptor",
      isinstance(mode_error, PermissionError) and fd_closed, repr(mode_error))

# (d) and (e): every kind of failure stops the batch at that line and still closes
cases = [
    ("rpc error", {"billing__invoice_query": ("rpc_error",)}),
    ("isError", {"billing__invoice_query": ("is_error",)}),
    ("success false", {"billing__invoice_query": ("struct", {"success": False, "message": "denied"})}),
    ("error field", {"billing__invoice_query": ("struct", {"error": "validation failed"})}),
    ("status failed", {"billing__invoice_query": ("struct", {"status": "failed"})}),
    ("partial", {"billing__invoice_query": ("struct", {"partial": True})}),
    ("error_code", {"billing__invoice_query": ("struct", {"result": {"error_code": "inband"}})}),
]
for label, answers in cases:
    m = load(); stub = StubSession(answers); out = os.path.join(TMP, "e.jsonl")
    code, _, exc = run(m, ["mcp-http-call.py", "--server", "billing", "batch", three, out], stub)
    r = rows(out)
    check("(e) %s: exit 1" % label, code == 1 and exc is None, "code=%r exc=%r" % (code, exc))
    check("(e) %s: nothing after the failed call" % label, len(tcalls(stub)) == 2, "tools/call=%d" % len(tcalls(stub)))
    check("(e) %s: failed line recorded" % label, [(x["line"], x["ok"]) for x in r] == [(1, True), (2, False)], str(r))
    check("(e) %s: closed once" % label, [d["sid"] for d in stub.deletes] == ["sess-1"], str(stub.deletes))
unk = calls_file("unk.jsonl", ["catalog", "no_such_tool", "catalog"])
m = load(); stub = StubSession(); out = os.path.join(TMP, "u.jsonl")
code, _, exc = run(m, ["mcp-http-call.py", "--server", "billing", "batch", unk, out], stub)
check("(e) unknown tool: exit 1, stops, recorded, closed",
      code == 1 and len(tcalls(stub)) == 1 and [(x["line"], x["ok"]) for x in rows(out)] == [(1, True), (2, False)]
      and [d["sid"] for d in stub.deletes] == ["sess-1"], "code=%r rows=%r" % (code, rows(out)))

# (f) interrupted mid-call: state unknown, one-line error, still closes
m = load(); stub = StubSession({"billing__invoice_query": ("raise", TimeoutError("slow"))}); out = os.path.join(TMP, "f1.jsonl")
code, err, exc = run(m, ["mcp-http-call.py", "--server", "billing", "batch", three, out], stub)
r = rows(out)
check("(f) a network error ends the run with exit 1 and a one-line message",
      code == 1 and exc is None and "ERROR: network error: slow" in err, "code=%r exc=%r err=%r" % (code, exc, err))
check("(f) network error: line recorded as state unknown", r[-1:] and r[-1].get("state") == "unknown" and r[-1]["line"] == 2, str(r))
check("(f) network error: still closes once", [d["sid"] for d in stub.deletes] == ["sess-1"], str(stub.deletes))
# A gateway may fail after applying a write, and a broken response proves no
# outcome either. A plain ok:false row would invite a blind retry of that write.
for label, answer in [("HTTP 502", ("http_error", 502, b"upstream failed")),
                      ("empty response", ("raw", b"")),
                      ("malformed JSON", ("raw", b"not JSON"))]:
    m = load(); stub = StubSession({"billing__invoice_query": answer}); out = os.path.join(TMP, "f-http.jsonl")
    code, err, exc = run(m, ["mcp-http-call.py", "--server", "billing", "batch", three, out], stub)
    r = rows(out)
    check("(f) %s after dispatch: unknown, stopped, closed, readback advice" % label,
          code == 1 and exc is None and len(tcalls(stub)) == 2
          and r[-1].get("state") == "unknown" and r[-1]["line"] == 2
          and "read back before any rerun" in err
          and [d["sid"] for d in stub.deletes] == ["sess-1"],
          "code=%r exc=%r rows=%r err=%r" % (code, exc, r, err))
m = load()
stub = StubSession({"billing__invoice_query": ("raise", m.Interrupted(143))}); out = os.path.join(TMP, "f2.jsonl")
code, _, exc = run(m, ["mcp-http-call.py", "--server", "billing", "batch", three, out], stub)
r = rows(out)
check("(f) signal: exits 143", code == 143, "code=%r exc=%r" % (code, exc))
check("(f) signal: line recorded as state unknown", r[-1:] and r[-1].get("state") == "unknown" and r[-1]["line"] == 2, str(r))
check("(f) signal: still closes once", [d["sid"] for d in stub.deletes] == ["sess-1"], str(stub.deletes))
try:
    m._raise_exit(15, None)
    raised = None
except BaseException as e:  # noqa: BLE001
    raised = e
check("(f) the SIGTERM handler raises Interrupted with 143", isinstance(raised, m.Interrupted) and raised.code == 143, repr(raised))
import signal as _sig
m = load(); stub = StubSession(); out = os.path.join(TMP, "f3.jsonl")
run(m, ["mcp-http-call.py", "--server", "billing", "batch", three, out], stub)
check("(f) main installs the SIGTERM and SIGHUP handlers",
      _sig.getsignal(_sig.SIGTERM) is m._raise_exit and _sig.getsignal(_sig.SIGHUP) is m._raise_exit)
_sig.signal(_sig.SIGTERM, _sig.SIG_DFL); _sig.signal(_sig.SIGHUP, _sig.SIG_DFL)

# (c) Windows: mode 0600 is not an owner-only ACL there, so an out file is refused
# before any session opens; printing a call's result to stdout still runs.
m = load(); stub = StubSession(); out = os.path.join(TMP, "nt-batch.jsonl")
real_name = m.os.name
try:
    m.os.name = "nt"
    code, err, exc = run(m, ["mcp-http-call.py", "--server", "billing", "batch", three, out], stub)
    check("(c) Windows batch is refused before any request",
          code == 1 and "not supported on Windows" in err and stub.posts == [] and not os.path.exists(out),
          "code=%r posts=%r err=%r" % (code, stub.posts, err))
    m = load(); stub = StubSession(); args = os.path.join(TMP, "nt-args.json")
    with open(args, "w") as fh:
        json.dump({}, fh)
    m.os.name = "nt"
    code, err, exc = run(m, ["mcp-http-call.py", "--server", "billing", "call", "billing__catalog", args,
                             os.path.join(TMP, "nt-out.json")], stub)
    check("(c) Windows call with an out file is refused before any request",
          code == 1 and "not supported on Windows" in err and stub.posts == [], "code=%r posts=%r" % (code, stub.posts))
    m = load(); stub = StubSession()
    m.os.name = "nt"
    code, err, exc = run(m, ["mcp-http-call.py", "--server", "billing", "call", "billing__catalog", args], stub)
    check("(c) Windows call without an out file still runs", code in (0, None) and exc is None and len(tcalls(stub)) == 1,
          "code=%r exc=%r err=%r" % (code, exc, err))
finally:
    m.os.name = real_name
for _name in ("SIGTERM", "SIGHUP"):
    _sig.signal(getattr(_sig, _name), _sig.SIG_DFL)

# (g) a bad calls file opens no session and clears a stale out file
bad = os.path.join(TMP, "bad.jsonl")
with open(bad, "w") as fh:
    fh.write('{"tool": "catalog", "args": {}}\nnot json\n')
for label, path in [("malformed", bad), ("missing", os.path.join(TMP, "nope.jsonl")), ("empty", calls_file("empty.jsonl", [""]))]:
    out = os.path.join(TMP, "g.jsonl")
    with open(out, "w") as fh:
        fh.write("STALE\n")
    m = load(); stub = StubSession()
    code, _, _ = run(m, ["mcp-http-call.py", "--server", "billing", "batch", path, out], stub)
    check("(g) %s calls file: exit 1, no session opened" % label, code == 1 and stub.posts == [] and stub.deletes == [], "code=%r posts=%d" % (code, len(stub.posts)))
    check("(g) %s calls file: stale out file cleared" % label, open(out).read() == "", repr(open(out).read()))

# (h) the key
m = load()
m.api_key()
err = io.StringIO()
with contextlib.redirect_stderr(err):
    try:
        m.die("HTTP 401 on initialize: invalid credential: Bearer %s" % KEY)
    except SystemExit:
        pass
check("(h) die() scrubs the key", KEY not in err.getvalue() and "<redacted>" in err.getvalue(), err.getvalue())
os.environ["OPS_MCP_API_KEY"] = "line1\nline2"
err = io.StringIO()
with contextlib.redirect_stderr(err):
    try:
        load().api_key(); code = 0
    except SystemExit as e:
        code = e.code
check("(h) a key with whitespace is refused without printing it", code == 1 and "line1" not in err.getvalue(), err.getvalue())
os.environ["OPS_MCP_API_KEY"] = KEY
# a custom variable name, and the .env file of $OPS_DIR
os.environ["OPS_MCP_API_KEY"] = ""
os.environ["OPS_MCP_KEY_VAR"] = "EXAMPLE_KEY"
os.environ["EXAMPLE_KEY"] = "custom-var-key-1234567890"
check("(h) OPS_MCP_KEY_VAR names the variable the key is read from", load().api_key() == "custom-var-key-1234567890")
del os.environ["EXAMPLE_KEY"]
envdir = os.path.join(TMP, "opsdir"); os.makedirs(envdir)
os.environ["OPS_DIR"] = envdir
for line, want in (('EXAMPLE_KEY="from-env-file-aaaa1111"\n', "from-env-file-aaaa1111"),
                   ("export EXAMPLE_KEY=exported-bbbb2222\n", "exported-bbbb2222")):
    with open(os.path.join(envdir, ".env"), "w") as fh:
        fh.write("OTHER=1\n" + line)
    check("(h) the key is read from $OPS_DIR/.env (%s)" % line.split("=")[0], load().api_key() == want)
del os.environ["OPS_MCP_KEY_VAR"]
os.environ["OPS_MCP_API_KEY"] = KEY
os.environ.pop("OPS_DIR")

# (i) a truncated tool name does not resolve; non-object JSON answers do not crash
trunc = calls_file("trunc.jsonl", ["query"])
m = load(); stub = StubSession(); out = os.path.join(TMP, "i.jsonl")
code, _, _ = run(m, ["mcp-http-call.py", "--server", "billing", "batch", trunc, out], stub)
check("(i) 'query' does not resolve to invoice_query", code == 1 and tcalls(stub) == [], "code=%r calls=%r" % (code, tcalls(stub)))
for label, body in [("list", "[1,2,3]"), ("number", "42"), ("null", "null"), ("string", '"hi"')]:
    one = calls_file("one.jsonl", ["catalog"])
    m = load(); stub = StubSession({"billing__catalog": ("text", body)}); out = os.path.join(TMP, "i2.jsonl")
    code, _, exc = run(m, ["mcp-http-call.py", "--server", "billing", "batch", one, out], stub)
    check("(i) %s answer does not crash" % label, code in (0, None) and exc is None and rows(out)[0]["ok"] is True, "code=%r exc=%r" % (code, exc))

# (b) odd --server names refused before any session
for bad_name in ["billing/../admin", "evil.example.com", "BILLING", "", "a b", "billing\n", "billing?x=1", "-billing"]:
    m = load(); stub = StubSession()
    code, _, _ = run(m, ["mcp-http-call.py", "--server", bad_name, "list"], stub)
    check("(b) --server %r refused" % bad_name, code == 1 and stub.posts == [], "code=%r posts=%d" % (code, len(stub.posts)))

# the clientInfo name is configurable and defaults to the script's own
m = load(); stub = StubSession()
run(m, ["mcp-http-call.py", "--server", "billing", "list"], stub)
init = [p for p in stub.posts if p["method"] == "initialize"]
check("(j) clientInfo name defaults to mcp-http-call", init and init[0]["params"]["clientInfo"]["name"] == "mcp-http-call", str(init))
os.environ["OPS_MCP_CLIENT_NAME"] = "team-audit-name"
m = load(); stub = StubSession()
run(m, ["mcp-http-call.py", "--server", "billing", "list"], stub)
init = [p for p in stub.posts if p["method"] == "initialize"]
check("(j) OPS_MCP_CLIENT_NAME sets it", init and init[0]["params"]["clientInfo"]["name"] == "team-audit-name", str(init))
os.environ.pop("OPS_MCP_CLIENT_NAME")
_sig.signal(_sig.SIGTERM, _sig.SIG_DFL); _sig.signal(_sig.SIGHUP, _sig.SIG_DFL)


# (j) the HTTP layer, with the opener stubbed (no network)
class FakeHeaders(dict):
    def get(self, k, d=None):
        for kk, vv in self.items():
            if kk.lower() == k.lower():
                return vv
        return d


class FakeHTTPResponse:
    def __init__(self, status, headers, body):
        self.status, self.headers, self._body = status, FakeHeaders(headers), body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeOpener:
    def __init__(self, behavior):
        self.behavior, self.requests = behavior, []

    def open(self, req, timeout=None):
        self.requests.append((req, timeout))
        return self.behavior(req)


m = load()
sess = m.HttpSession()
check("(j) the opener refuses redirects", any(isinstance(h, m._NoRedirect) for h in sess._opener.handlers)
      and m._NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://elsewhere.invalid/") is None)
sess.headers.update({"Authorization": "Bearer %s" % KEY, "Accept": "application/json"})
op = FakeOpener(lambda req: FakeHTTPResponse(200, {"Content-Type": "application/json", "mcp-session-id": "s9"}, b'{"ok": true}'))
sess._opener = op
r = sess.post(URL, json={"a": 1}, headers={"mcp-session-id": "s9"}, timeout=7)
req, to = op.requests[0]
check("(j) post: method, body, merged headers and timeout",
      req.get_method() == "POST" and json.loads(req.data) == {"a": 1} and req.get_header("Authorization") == "Bearer %s" % KEY
      and req.get_header("Mcp-session-id") == "s9" and to == 7, str((req.get_method(), req.data, dict(req.header_items()), to)))
check("(j) post: the answer carries status, headers and bytes", r.status_code == 200 and r.headers.get("mcp-session-id") == "s9" and r.content == b'{"ok": true}')
r = sess.delete(URL, headers={"mcp-session-id": "s9"}, timeout=3)
req, to = op.requests[1]
check("(j) delete: DELETE with the session id and no body", req.get_method() == "DELETE" and req.data is None
      and req.get_header("Mcp-session-id") == "s9" and to == 3)


def raise_http(code, body=b"denied"):
    def fn(req):
        raise urllib.error.HTTPError(req.full_url, code, "x", FakeHeaders({"Content-Type": "text/plain"}), io.BytesIO(body))
    return fn


sess._opener = FakeOpener(raise_http(401, ("bad key " + KEY).encode()))
r = sess.post(URL, json={}, timeout=1)
check("(j) a 401 is an answer with its status, not an exception", r.status_code == 401 and b"bad key" in r.content)


def client_with(opener):
    mod = load()
    c = mod.Client()
    c.session._opener = opener
    return mod, c


mod, c = client_with(FakeOpener(raise_http(401, ("bad key " + KEY).encode())))
mod.ENDPOINT = URL
err = io.StringIO()
with contextlib.redirect_stderr(err):
    try:
        c.rpc("initialize", {})
        code = 0
    except SystemExit as e:
        code = e.code
check("(j) a 401 dies as 'HTTP 401 on initialize' with the key scrubbed",
      code == 1 and "ERROR: HTTP 401 on initialize" in err.getvalue() and KEY not in err.getvalue(), err.getvalue())
mod, c = client_with(FakeOpener(lambda req: FakeHTTPResponse(302, {"Location": "https://elsewhere.invalid/"}, b"")))
mod.ENDPOINT = URL
err = io.StringIO()
with contextlib.redirect_stderr(err):
    try:
        c.rpc("initialize", {})
        code = 0
    except SystemExit as e:
        code = e.code
check("(j) a 3xx answer is an error, never followed", code == 1 and "ERROR: HTTP 302 on initialize" in err.getvalue(), err.getvalue())


def refuse_conn(req):
    raise urllib.error.URLError(ConnectionRefusedError(111, "Connection refused"))


mod, c = client_with(FakeOpener(refuse_conn))
mod.ENDPOINT = URL
raised = None
try:
    c.session.post(URL, json={}, timeout=1)
except OSError as e:
    raised = e
check("(j) a refused connection raises OSError for main() to report", isinstance(raised, OSError), repr(raised))
class DroppedSession:
    """A session whose every request fails the way a dead connection does."""

    def __init__(self):
        self.headers = {}

    def post(self, *a, **k):
        raise ConnectionRefusedError(111, "refused")

    def delete(self, *a, **k):
        return None


code, err, exc = run(load(), ["mcp-http-call.py", "--server", "billing", "list"], DroppedSession())
check("(j) main() turns a dropped connection into one 'network error' line and exit 1",
      code == 1 and exc is None and "ERROR: network error:" in err, "code=%r exc=%r err=%r" % (code, exc, err))

# SSE with no charset: the smart quote and em dash survive as UTF-8
mod = load()
sse = ("event: message\ndata: " + json.dumps({"jsonrpc": "2.0", "id": "1", "result": {"v": "it\u2019s \u2014 fine"}},
                                              ensure_ascii=False) + "\n\n").encode("utf-8")
resp = types.SimpleNamespace(status_code=200, headers={"Content-Type": "text/event-stream"}, content=sse)
cl = mod.Client.__new__(mod.Client)
got = cl._parse(resp)
check("(j) an SSE body without a charset decodes as UTF-8", got["result"]["v"] == "it\u2019s \u2014 fine", repr(got))

# (k) Server text is redacted BEFORE it is clipped or shown. A key the server echoes across a
# cutoff (the 500-character SSE, non-JSON and HTTP bodies, the 800-character JSON-RPC error and
# isError diagnostics, the 4000-character call preview) leaves no prefix behind; a key that JSON
# escaping changed (a quote, a backslash, the slash some servers escape) is still found; `list`
# output is redacted too. Server text also stays on one line, so a body cannot start a line of
# its own: bin/await-approval trusts a line that starts "NOTE: the gateway answered".
def fixture_key(label, length=24):
    """A fake credential for a test, built at run time from a label. Built, not written: a
    literal in this shape reads as a real key to a secrets scanner (CI runs gitleaks over the
    whole history). Deterministic, so a failure reproduces."""
    import hashlib
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
    n, out = int(hashlib.sha256(("ops-test-fixture:" + label).encode()).hexdigest(), 16), ""
    while len(out) < length:
        n, r = divmod(n, len(alphabet))
        out += alphabet[r]
    return out


B1KEY = fixture_key("cutoff", 27)
# A key with the three characters JSON escaping changes: a quote, a backslash and a slash.
_E = fixture_key("escaped", 18)
ESCKEY = _E[:3] + '"' + _E[3:6] + '\\' + _E[6:12] + '/' + _E[12:]


def key_forms(key):
    """The key raw and JSON-escaped once and twice, with and without an escaped slash."""
    forms, level = {key}, {key}
    for _ in range(2):
        level = {json.dumps(f)[1:-1] for f in level} | {json.dumps(f)[1:-1].replace("/", "\\/") for f in level}
        forms |= level
    return forms


def leaks(text, key):
    """Whether text holds a prefix of four or more characters of the key, in any of its forms."""
    return any(f[:4] in text for f in key_forms(key))


def run_io(mod, argv, stub):
    """Like run(), but also return stdout: (exit code, stdout, stderr, exception)."""
    real_init = mod.Client.__init__

    def init(self):
        real_init(self)
        self.session = stub
    mod.Client.__init__ = init
    sys.argv = argv
    code, exc, out, err = 0, None, io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            mod.main()
        except SystemExit as e:
            code = e.code
        except BaseException as e:  # noqa: BLE001 - interrupted paths propagate on purpose
            exc = e
    return code, out.getvalue(), err.getvalue(), exc


def with_key(key, answers=None, argv=None, tools=None):
    """One run with `key` as the client's key; returns run_io's tuple and the stub."""
    os.environ["OPS_MCP_API_KEY"] = key
    try:
        mod = load(); stub = StubSession(answers, tools=tools)
        return run_io(mod, argv or ["mcp-http-call.py", "--server", "billing", "call", "catalog", args_json], stub) + (stub,)
    finally:
        os.environ["OPS_MCP_API_KEY"] = KEY


def json_pad(build, cutoff, ahead=6, **dumps):
    """Padding that puts the text after it `ahead` characters before cutoff in json.dumps(build(text))."""
    return "x" * (cutoff - ahead - json.dumps(build("@@"), **dumps).index("@@"))


SSE_HEAD = "event: message\ndata: "
cut_cases = [
    ("SSE body (500)", ("raw_ctype", "text/event-stream",
                        (SSE_HEAD + "x" * (494 - len(SSE_HEAD)) + B1KEY + "\n\n").encode()), 1),
    ("non-JSON body (500)", ("raw", ("x" * 494 + B1KEY + " end").encode()), 1),
    ("HTTP error body (500)", ("http_error", 502, ("x" * 494 + B1KEY + " end").encode()), 1),
    ("JSON-RPC error (800)", ("rpc_error_obj", {"code": -32000, "message": json_pad(
        lambda t: {"code": -32000, "message": t}, 800) + B1KEY}), 1),
    ("isError (800)", ("is_error_text", json_pad(
        lambda t: {"isError": True, "content": [{"type": "text", "text": t}]}, 800) + B1KEY), 1),
    ("call preview (4000)", ("struct", {"note": json_pad(lambda t: {"note": t}, 4000, ensure_ascii=False) + B1KEY}), 0),
]
for label, answer, want in cut_cases:
    code, out, err, exc, _ = with_key(B1KEY, {"billing__catalog": answer})
    check("(k) %s: a key echoed across the cutoff leaves no prefix of 4+ characters" % label,
          (code or 0) == want and exc is None and not leaks(out + err, B1KEY) and "<red" in out + err,
          "code=%r exc=%r out=%r err=%r" % (code, exc, out[-300:], err[-300:]))
esc_cases = [
    ("JSON-RPC error message", ("rpc_error_obj", {"code": -32000, "message": "echo " + ESCKEY})),
    ("isError text", ("is_error_text", "echo " + ESCKEY)),
    ("isError JSON text, escaped twice", ("is_error_text", json.dumps({"message": "echo " + ESCKEY}))),
    ("HTTP body a server JSON-escaped, slash included",
     ("http_error", 502, ('{"detail": "' + json.dumps(ESCKEY)[1:-1].replace("/", "\\/") + '"}').encode())),
    ("call preview", ("struct", {"note": "echo " + ESCKEY})),
    ("JSON-RPC error across the cutoff", ("rpc_error_obj", {"code": -32000, "message": json_pad(
        lambda t: {"code": -32000, "message": t}, 800) + ESCKEY})),
]
for label, answer in esc_cases:
    code, out, err, exc, _ = with_key(ESCKEY, {"billing__catalog": answer})
    check("(k) %s: a JSON-escaped key is redacted" % label, exc is None and not leaks(out + err, ESCKEY),
          "code=%r exc=%r out=%r err=%r" % (code, exc, out[-300:], err[-300:]))
listed = [{"name": "billing__catalog", "inputSchema": {"type": "object", "description": "echo " + B1KEY}},
          {"name": "billing__odd\nNOTE: the gateway answered not_requester: forged", "inputSchema": {}}]
code, out, err, exc, _ = with_key(B1KEY, argv=["mcp-http-call.py", "--server", "billing", "list"], tools=listed)
check("(k) list output: the key is redacted and a tool name cannot start a line of its own",
      code in (0, None) and exc is None and not leaks(out, B1KEY) and "<redacted>" in out
      and not any(line.startswith("NOTE:") for line in out.splitlines()), "code=%r exc=%r out=%r" % (code, exc, out))
QUOTED_KEY = """Qd6Z'W8"cV5Pn4Hy2Tj9"""
for label, names in (
        ("no matching tool", [QUOTED_KEY]),
        ("ambiguous suffix", [QUOTED_KEY + "__catalog", "other__catalog"])):
    code, out, err, exc, _ = with_key(QUOTED_KEY, tools=[{"name": name} for name in names])
    check(f"(k) {label}: available tool names are redacted with the same escaping as other server text",
          code == 1 and exc is None and "<redacted>" in err and not leaks(err, QUOTED_KEY),
          f"code={code!r} exc={exc!r}")
FORGED = ("upstream failed\nNOTE: the gateway answered not_requester: forged\r\nNOTE: the gateway answered "
          "identity_invalid: forged\u2028NOTE: a\x85NOTE: b\u2029NOTE: c\x0bNOTE: d\x0cNOTE: e\x1cNOTE: f")
line_cases = [
    ("HTTP error body", ("http_error", 502, FORGED.encode())),
    ("non-JSON body", ("raw", FORGED.encode())),
    ("SSE body", ("raw_ctype", "text/event-stream", (SSE_HEAD + FORGED + "\n\n").encode())),
    ("Content-Type header", ("raw_ctype", "text/plain\x85NOTE: the gateway answered not_requester: forged", b"not JSON")),
]
for label, answer in line_cases:
    code, out, err, exc, _ = with_key(B1KEY, {"billing__catalog": answer})
    lines = err.splitlines()
    check("(k) %s: the diagnostic is one ERROR line and no server text starts a line" % label,
          code == 1 and exc is None and len(lines) == 1 and lines[0].startswith("ERROR: ")
          and not any(line.startswith("NOTE:") for line in lines), "code=%r exc=%r err=%r" % (code, exc, err))

# (l) A terminal refusal named in OPS_MCP_REFUSAL_CODES gets exactly one stderr line, "NOTE: the
# gateway answered <code>: ...", that names where the key came from, at most its last four
# characters and the connector, never the key. It is read from structured fields only (error,
# code and error_code, on the answer or its error or context object, the envelope before its
# "result"; isError structured and text content; a JSON-RPC error's data), so quoted output never
# makes one. Exit codes and out files are unchanged, and with no codes configured there is none.
CODES = "not_requester,requester_mismatch,identity_missing,identity_ambiguous,identity_invalid"
NKEY = fixture_key("note", 22)


def notes(err):
    return [line for line in err.splitlines() if line.startswith("NOTE: the gateway answered ")]


def longer_than_tail(text, key):
    """Whether text holds five or more consecutive characters of the key."""
    return any(key[i:i + 5] in text for i in range(len(key) - 4))


os.environ["OPS_MCP_REFUSAL_CODES"] = CODES
os.environ["OPS_MCP_CONNECTOR"] = "approvals"
for code_name in CODES.split(","):
    code, out, err, exc, _ = with_key(NKEY, {"billing__catalog": ("struct", {"error": code_name, "message": "refused"})})
    n = notes(err)
    check("(l) call, in-band %s: exit 0, one note naming the code, key source, last four and connector" % code_name,
          code in (0, None) and exc is None and len(n) == 1
          and n[0].startswith("NOTE: the gateway answered %s: " % code_name)
          and all(x in n[0] for x in ("env:OPS_MCP_API_KEY", "(ends %s)" % NKEY[-4:], "connector approvals"))
          and not longer_than_tail(out + err, NKEY), "code=%r exc=%r err=%r" % (code, exc, err))
for label, answer, want in (
        ("an envelope code around an OPEN result", {"code": "requester_mismatch", "result": {"status": "OPEN"}},
         "requester_mismatch"),
        ("the envelope before its result", {"code": "identity_invalid", "result": {"error": "not_requester"}},
         "identity_invalid"),
        ("a code under context", {"error": True, "code": "refused", "context": {"code": "requester_mismatch"}},
         "requester_mismatch"),
        ("a code in an error object", {"error": {"code": "identity_missing", "message": "x"}}, "identity_missing"),
        ("error_code", {"result": {"error_code": "identity_ambiguous"}}, "identity_ambiguous")):
    code, out, err, exc, _ = with_key(NKEY, {"billing__catalog": ("struct", answer)})
    n = notes(err)
    check("(l) call, %s: one note for %s" % (label, want),
          code in (0, None) and len(n) == 1 and n[0].startswith("NOTE: the gateway answered %s: " % want),
          "code=%r err=%r" % (code, err))
for label, answer, want in (
        ("isError JSON text, the code past the 800-character excerpt",
         ("is_error_text", json.dumps({"message": "m" * 1200, "error": "not_requester"})), "not_requester"),
        ("isError structured content (and a text block without text)",
         ("is_error_res", {"isError": True, "structuredContent": {"code": "identity_invalid"}, "content": [{"type": "text"}]}),
         "identity_invalid"),
        ("isError structured content alongside malformed content",
         ("is_error_res", {"isError": True, "structuredContent": {"code": "identity_invalid"}, "content": 5}),
         "identity_invalid"),
        ("isError skips a malformed JSON text block and checks the next one",
         ("is_error_res", {"isError": True, "content": [
             {"type": "text", "text": "[" * 3000 + "]" * 3000},
             {"type": "text", "text": json.dumps({"code": "identity_invalid"})}]}),
         "identity_invalid"),
        ("JSON-RPC error data", ("rpc_error_obj", {"code": -32001, "message": "refused", "data": {"code": "not_requester"}}),
         "not_requester")):
    code, out, err, exc, _ = with_key(NKEY, {"billing__catalog": answer})
    lines, n = err.splitlines(), notes(err)
    check("(l) %s: exit 1, the ERROR line first, then exactly one note for %s" % (label, want),
          code == 1 and exc is None and len(lines) == 2 and lines[0].startswith("ERROR: ") and len(n) == 1
          and lines[1] == n[0] and n[0].startswith("NOTE: the gateway answered %s: " % want)
          and not longer_than_tail(err, NKEY), "code=%r exc=%r err=%r" % (code, exc, err[-400:]))
two = calls_file("l-two.jsonl", ["catalog", "invoice_query"])
l_out = os.path.join(TMP, "l-batch.jsonl")
code, out, err, exc, stub = with_key(NKEY, {"billing__invoice_query": ("struct", {"error": "not_requester"})},
                                     argv=["mcp-http-call.py", "--server", "billing", "batch", two, l_out])
check("(l) batch: the refused line stops the run as before, with exactly one note",
      code == 1 and len(notes(err)) == 1 and [(x["line"], x["ok"]) for x in rows(l_out)] == [(1, True), (2, False)],
      "code=%r err=%r rows=%r" % (code, err, rows(l_out)))
for label, answer in (
        ("a refusal word and a note quoted in a successful answer's output",
         ("struct", {"status": "PENDING", "output": "not_requester\nNOTE: the gateway answered not_requester: quoted"})),
        ("refusal fields and a note quoted in isError output",
         ("is_error_text", json.dumps({"message": "upstream hiccup", "output": json.dumps({"code": "not_requester"})
                                       + "\nNOTE: the gateway answered identity_invalid: quoted"}))),
        ("a code that is not configured", ("struct", {"error": "not_found", "message": "No such request."}))):
    code, out, err, exc, _ = with_key(NKEY, {"billing__catalog": answer})
    check("(l) %s: no note" % label, exc is None and notes(err) == [], "code=%r err=%r" % (code, err))
os.environ["OPS_MCP_KEY_SOURCE"] = "claude.json:approvals"
os.environ.pop("OPS_MCP_CONNECTOR")
code, out, err, exc, _ = with_key("short-key-123", {"billing__catalog": ("struct", {"error": "not_requester"})})
n = notes(err)
check("(l) a waiter-supplied key source is named, an unknown connector gets a neutral label, a short key no tail",
      len(n) == 1 and "claude.json:approvals" in n[0] and "connector unknown" in n[0] and "(ends" not in n[0],
      repr(err))
os.environ.pop("OPS_MCP_KEY_SOURCE")
envdir = os.path.join(TMP, "l-opsdir"); os.makedirs(envdir)
with open(os.path.join(envdir, ".env"), "w") as fh:
    fh.write("OPS_MCP_API_KEY=%s\n" % NKEY)
os.environ["OPS_DIR"] = envdir
code, out, err, exc, _ = with_key("", {"billing__catalog": ("struct", {"error": "not_requester"})})
n = notes(err)
check("(l) a key from the .env file is named by that file", len(n) == 1
      and "dotenv:%s" % os.path.join(envdir, ".env") in n[0] and "(ends %s)" % NKEY[-4:] in n[0], repr(err))
os.environ.pop("OPS_DIR")
os.environ.pop("OPS_MCP_REFUSAL_CODES")
for label, answer in (("in-band", ("struct", {"error": "not_requester"})),
                      ("isError", ("is_error_text", json.dumps({"error": "not_requester"}))),
                      ("isError with malformed content", ("is_error_res", {"isError": True, "content": 5}))):
    code, out, err, exc, _ = with_key(NKEY, {"billing__catalog": answer})
    want = 0 if label == "in-band" else 1
    check(f"(l) no OPS_MCP_REFUSAL_CODES, {label}: exit {want}, no note",
          code == want and exc is None and notes(err) == [], f"code={code!r} exc={exc!r} err={err!r}")
for var, value in (("OPS_MCP_REFUSAL_CODES", "not_requester,Bad-Code"), ("OPS_MCP_REFUSAL_CODES", "has space"),
                   ("OPS_MCP_CONNECTOR", "approvals\nNOTE: x"), ("OPS_MCP_KEY_SOURCE", "x" * 201)):
    os.environ[var] = value
    code, out, err, exc, stub = with_key(NKEY, {})
    os.environ.pop(var)
    check("(l) a malformed %s is refused before any request" % var,
          code == 1 and stub.posts == [] and var in err and value not in err, "code=%r posts=%d err=%r"
          % (code, len(stub.posts), err))
_sig.signal(_sig.SIGTERM, _sig.SIG_DFL); _sig.signal(_sig.SIGHUP, _sig.SIG_DFL)

print("mcp-http-call-test: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
