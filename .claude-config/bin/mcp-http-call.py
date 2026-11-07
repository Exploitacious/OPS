#!/usr/bin/env python3
"""mcp-http-call: a minimal MCP client for scripts (Streamable HTTP, standard library only).

Use it, never a hand-rolled client, whenever one tool call has to go over HTTP
instead of through a Claude session: a payload too big to send through a turn
(the content must travel from DISK to the API without passing through token
re-emission, where unchanged sections can drift), a timed one-shot, or a loop
over many items.

Usage:
  mcp-http-call.py [--server NAME] list
  mcp-http-call.py [--server NAME] call <tool-suffix> <args.json> [out.json]
  mcp-http-call.py [--server NAME] batch <calls.jsonl> <out.jsonl>

batch runs every line of calls.jsonl ({"tool": "<suffix>", "args": {...}}) in ONE
session and writes one result line per call; it stops at the first failed call
(exit 1) with the results so far written. call prints the answer as it is (or
writes it to out.json) and does not judge in-band refusals: check the body.

Configuration (environment; nothing is built in, so a copy that sets none of it
refuses to run and says what is missing):
  OPS_MCP_URL           the full URL of one MCP endpoint.
  OPS_MCP_URL_TEMPLATE  a URL with {server} in it, for a gateway that serves many
                        endpoints; --server NAME fills it in. NAME is checked
                        against [a-z0-9][a-z0-9-]{0,40}, so it cannot rewrite the
                        host or the path. With --server the template is used; without
                        it OPS_MCP_URL is. Only http and https URLs are accepted.
  OPS_MCP_API_KEY       the bearer key. If it is not in the environment, the
                        OPS_MCP_API_KEY= line of $OPS_DIR/.env (default ~/OPS/.env)
                        is used. The key is never printed.
  OPS_MCP_KEY_VAR       the NAME of the variable (and of the .env key) that holds the
                        key, when it is not OPS_MCP_API_KEY.
  OPS_MCP_CLIENT_NAME   clientInfo.name sent at initialize (default mcp-http-call);
                        a server-side audit log groups calls by it.

Exit status: 0 ok, 1 any failure (a message on stderr starting "ERROR: "), 128+N
when SIGTERM or SIGHUP stopped it.

WHY batch and the close: a server counts live sessions per key and reaps an idle
one only after a timeout, so a client that opens a session per call and never
sends the HTTP DELETE leaks one live session per call and a per-item loop soon
hits the cap. One session per run, closed in a finally (also on SIGTERM and
SIGHUP), keeps a loop at one. Only SIGKILL skips it.

WHY results are 0600: they can carry secrets (a password lookup, a note with
credentials), and the default umask leaves files group or world readable.

Writes: pass an idempotency key where the tool takes one, and never re-run a call
that timed out; read back instead. A batch records an interrupted call as
"state": "unknown" for exactly that reason.
"""
import http.client
import json
import os
import re
import signal
import sys
import urllib.error
import urllib.request
import uuid

KEY_VAR = os.environ.get("OPS_MCP_KEY_VAR") or "OPS_MCP_API_KEY"
CLIENT_NAME = os.environ.get("OPS_MCP_CLIENT_NAME") or "mcp-http-call"
# The endpoint this run talks to, set by select_server() before any request.
ENDPOINT = None
TIMEOUT = 180
# Session teardown is best-effort and off the critical path; cap it short so a
# slow or hung DELETE can never stall the caller behind the full TIMEOUT.
CLOSE_TIMEOUT = 10
# The key, once read, so die() can scrub it from server text it prints (a 401
# body or a proxy error page can echo the Authorization header back).
_SECRETS = []


def scrub(text):
    text = str(text)
    for s in _SECRETS:
        if s:
            text = text.replace(s, "<redacted>")
    return text


def die(msg):
    print("ERROR: %s" % scrub(msg), file=sys.stderr)
    sys.exit(1)


class UnknownOutcome(SystemExit):
    """A dispatched call returned no trustworthy outcome; read back before retrying."""


def env_file():
    return os.path.join(os.environ.get("OPS_DIR") or os.path.expanduser("~/OPS"), ".env")


def api_key():
    k = os.environ.get(KEY_VAR)
    path = env_file()
    if not k:
        try:
            with open(path) as fh:
                for line in fh:
                    m = re.fullmatch(r"(?:export\s+)?%s=(.*)" % re.escape(KEY_VAR), line.strip())
                    if m:
                        k = m.group(1).strip().strip('"').strip("'")
                        break
        except OSError:
            pass  # no .env is the ordinary case on a box that keeps the key in its environment
    k = (k or "").strip()
    if not k:
        die("no API key: set %s in the environment or in %s" % (KEY_VAR, path))
    # A key with whitespace inside would make the HTTP library raise with the
    # whole value in the traceback; refuse it without printing it.
    if re.search(r"\s", k):
        die("%s contains whitespace; fix the value (not printed)" % KEY_VAR)
    _SECRETS.append(k)
    return k


class Response:
    """What HttpSession.post and .delete return: status_code, headers, content (bytes)."""

    def __init__(self, status_code, headers, content):
        self.status_code = status_code
        self.headers = headers
        self.content = content


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse every redirect.

    WHY: urllib copies the Authorization header onto the redirected request, even to
    another host, so a redirect from an endpoint would hand the bearer key to
    whoever the Location names. An MCP endpoint has no reason to redirect; a 3xx
    answer is an error (rpc() reports it as one).
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class HttpSession:
    """The two requests this client makes, on urllib so no package is needed.

    A test stubs an instance's post and delete instead of the network. A 3xx, 4xx
    or 5xx answer is returned like any other (the caller reads status_code), and a
    transport failure (refused, reset, timed out) raises OSError.
    """

    def __init__(self):
        self.headers = {}
        self._opener = urllib.request.build_opener(_NoRedirect)

    def _send(self, method, url, data, headers, timeout):
        merged = dict(self.headers)
        merged.update(headers or {})
        req = urllib.request.Request(url, data=data, method=method, headers=merged)
        try:
            with self._opener.open(req, timeout=timeout) as resp:
                return Response(resp.status, resp.headers, resp.read())
        except urllib.error.HTTPError as exc:
            try:
                body = exc.read()
            except (OSError, http.client.HTTPException):
                body = b""
            return Response(exc.code, exc.headers, body)
        except http.client.HTTPException as exc:
            raise OSError("HTTP protocol error: %s" % exc) from exc

    def post(self, url, json=None, headers=None, timeout=None):
        import json as _json
        return self._send("POST", url, _json.dumps(json).encode("utf-8"), headers, timeout)

    def delete(self, url, headers=None, timeout=None):
        return self._send("DELETE", url, None, headers, timeout)


class Client:
    def __init__(self):
        self.session = HttpSession()
        self.session.headers.update(
            {
                "Authorization": "Bearer %s" % api_key(),
                # streamable HTTP servers may answer either shape; accept both
                "Accept": "application/json, text/event-stream",
                "Content-Type": "application/json",
                "MCP-Protocol-Version": "2025-06-18",
            }
        )
        self.mcp_session_id = None

    def _parse(self, resp):
        ctype = resp.headers.get("Content-Type", "") or ""
        # A server may send text/event-stream with NO charset parameter, and an
        # HTTP library that follows the legacy RFC 2616 default would decode any
        # text/* body as ISO-8859-1, silently mojibaking every smart quote and em
        # dash, which reads as content drift on a hash compare. MCP is UTF-8 by
        # spec, so decode the raw bytes as UTF-8, always.
        body = resp.content.decode("utf-8")
        if "text/event-stream" in ctype:
            # SSE frames: keep the last `data:` payload that carries a JSON-RPC result
            out = None
            for line in body.splitlines():
                if line.startswith("data:"):
                    chunk = line[5:].strip()
                    if not chunk:
                        continue
                    try:
                        obj = json.loads(chunk)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(obj, dict) and ("result" in obj or "error" in obj):
                        out = obj
            if out is None:
                die("no JSON-RPC payload in SSE body: %s" % body[:500])
            return out
        if not body.strip():
            return None
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            die("non-JSON response (HTTP %s, %s): %s" % (resp.status_code, ctype, body[:500]))

    def rpc(self, method, params=None, notify=False):
        payload = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        if not notify:
            payload["id"] = str(uuid.uuid4())
        headers = {}
        if self.mcp_session_id:
            headers["mcp-session-id"] = self.mcp_session_id
        resp = self.session.post(ENDPOINT, json=payload, headers=headers, timeout=TIMEOUT)
        sid = resp.headers.get("mcp-session-id")
        if sid:
            self.mcp_session_id = sid
        try:
            if resp.status_code >= 300:
                die("HTTP %s on %s: %s" % (resp.status_code, method, resp.content.decode("utf-8", "replace")[:500]))
            if notify:
                return None
            msg = self._parse(resp)
            if msg is None:
                die("empty response on %s" % method)
        except SystemExit as exc:
            # A gateway error or broken reply can arrive after a write applied.
            # Preserve that uncertainty in a batch instead of inviting a retry.
            if method == "tools/call":
                raise UnknownOutcome(exc.code) from None
            raise
        if "error" in msg:
            die("JSON-RPC error on %s: %s" % (method, json.dumps(msg["error"])[:800]))
        return msg["result"]

    def initialize(self):
        self.rpc(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": CLIENT_NAME, "version": "1.0"},
            },
        )
        self.rpc("notifications/initialized", {}, notify=True)

    def close(self):
        """Terminate the MCP session server-side once work is done.

        WHY: each initialize() opens a session the server counts against a
        per-key cap, and an idle one is reaped only after a timeout, so a
        never-closed session leaks until the cap is hit and every initialize is
        refused. Per the Streamable HTTP transport spec a client releases its
        session with an HTTP DELETE carrying mcp-session-id; a server that does
        not support explicit termination answers 405. Swallow that and any error
        so teardown never changes the script's exit code or output. Auth headers
        ride on self.session, same as rpc().
        """
        if not self.mcp_session_id:
            return
        try:
            self.session.delete(
                ENDPOINT,
                headers={"mcp-session-id": self.mcp_session_id},
                timeout=CLOSE_TIMEOUT,
            )
        except Exception:
            # Best-effort teardown: catch everything so no failure on session
            # release can alter the script's exit code.
            pass

    def tools(self):
        return self.rpc("tools/list", {}).get("tools", [])

    def resolve(self, suffix):
        """A server may namespace tool names, so match by name suffix.

        The list is read once per run: a batch resolves every call against the
        same session's list instead of re-listing before each call.
        """
        if getattr(self, "_names", None) is None:
            self._names = [t["name"] for t in self.tools()]
        names = self._names
        exact = [n for n in names if n == suffix]
        if exact:
            return exact[0]
        # A suffix matches only at the namespace boundary: a truncated name must
        # not resolve to whichever tool happens to end with it (a write tool).
        hits = [n for n in names if n.endswith("__" + suffix)]
        if len(hits) == 1:
            return hits[0]
        if not hits:
            die("no tool matching %r; available: %s" % (suffix, names))
        die("ambiguous tool suffix %r: %s" % (suffix, hits))

    def call(self, suffix, args):
        name = self.resolve(suffix)
        res = self.rpc("tools/call", {"name": name, "arguments": args})
        if res.get("isError"):
            die("tool %s returned isError: %s" % (name, json.dumps(res)[:800]))
        return res


def inband_failure(payload):
    """Return why a tool answer is a refusal, or None.

    WHY (batch only): tools often refuse in-band, with isError false and a body
    such as {"error": ...}, {"success": false}, {"status": "failed"} or
    {"partial": true}. A batch that treated them as success would run the next
    call after a failed write. Checks the payload and its "result" object.
    """
    for obj in (payload, payload.get("result") if isinstance(payload, dict) else None):
        if not isinstance(obj, dict):
            continue
        if obj.get("success") is False:
            return "success is false"
        if obj.get("error") not in (None, False, "", {}, []):
            return "error field set"
        if str(obj.get("error_code") or "").strip():
            return "error_code set"
        if str(obj.get("status") or "").lower() in ("failed", "partial", "error"):
            return "status %s" % obj.get("status")
        if obj.get("partial") is True:
            return "partial is true"
    return None


def unwrap(res):
    """tools/call results wrap payloads in content blocks; return parsed JSON."""
    if isinstance(res.get("structuredContent"), dict):
        return res["structuredContent"]
    for block in res.get("content", []):
        if block.get("type") == "text":
            try:
                return json.loads(block["text"])
            except json.JSONDecodeError:
                return {"text": block["text"]}
    return res


def select_server(argv):
    """Strip a leading `--server <name>` and point ENDPOINT at the configured URL.

    With --server the endpoint is OPS_MCP_URL_TEMPLATE with {server} filled in;
    without it, OPS_MCP_URL. Nothing defaults: a call that could go to the wrong
    system because a name was left out is refused instead. The name is checked
    against the URL path shape so it cannot rewrite the host or path, and only
    http and https URLs are accepted (urllib would also open file: and ftp:).
    """
    global ENDPOINT
    url = None
    if len(argv) >= 3 and argv[1] == "--server":
        name = argv[2]
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,40}", name):
            die("bad --server %r (an endpoint name such as billing or inventory)" % name)
        template = os.environ.get("OPS_MCP_URL_TEMPLATE", "")
        if "{server}" not in template:
            die("--server needs OPS_MCP_URL_TEMPLATE, a URL with {server} in it")
        url = template.replace("{server}", name)
        argv = [argv[0]] + argv[3:]
    else:
        url = os.environ.get("OPS_MCP_URL", "")
        if not url:
            die("no endpoint configured: set OPS_MCP_URL for one endpoint, or "
                "OPS_MCP_URL_TEMPLATE with {server} in it and pass --server NAME")
    if not re.match(r"https?://[^\s/]+", url) or re.search(r"\s", url):
        die("the endpoint URL must be an http or https URL")
    ENDPOINT = url
    return argv


def refuse_file_output_without_private_mode():
    """Refuse an out file, before any session opens, where mode 0600 is not owner-only.

    Results can carry credentials. On Windows, os.fchmod exists from Python 3.13
    but mode bits do not set an owner-only ACL, so a file written there can inherit
    shared access. The check runs before dispatch so a refused run never loses the
    result of a call that already applied; printing to stdout still works.
    """
    if os.name == "nt":
        die("file output is not supported on Windows: results can carry credentials "
            "and this tool cannot set an owner-only ACL there; omit the out file to "
            "print the result instead")


def private_open(path):
    """Open path for writing as mode 0600 (owner only), truncating it.

    An existing file is chmod'ed to 0600 before it is rewritten.
    """
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        if not hasattr(os, "fchmod"):
            raise OSError("this Python build cannot enforce private output with os.fchmod")
        os.fchmod(fd, 0o600)
    except OSError:
        os.close(fd)
        raise
    return os.fdopen(fd, "w")


def load_calls(in_path, out_path):
    """Read and check the calls file BEFORE any session opens.

    The out file is truncated first, so a rejected run never leaves an older
    run's results looking current.
    """
    try:
        private_open(out_path).close()
    except OSError as exc:
        die("cannot write %s: %s" % (out_path, exc))
    calls = []
    try:
        fh = open(in_path)
    except OSError as exc:
        die("cannot read %s: %s" % (in_path, exc))
    with fh:
        for n, line in enumerate(fh, 1):
            if not line.strip():
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError as exc:
                die("%s line %d is not JSON: %s" % (in_path, n, exc))
            if not isinstance(item, dict) or not isinstance(item.get("tool"), str) or not isinstance(item.get("args", {}), dict):
                die("%s line %d needs {\"tool\": str, \"args\": object}" % (in_path, n))
            calls.append((n, item["tool"], item.get("args", {})))
    if not calls:
        die("%s has no calls" % in_path)
    return calls


class Interrupted(SystemExit):
    """A termination signal arrived; a call in flight may or may not have applied."""


def run_batch(c, calls, out_path):
    """Run the checked calls in the one session c holds; stop at the first failure.

    Every line ends up in the out file: ok true with the result, ok false when
    the call failed or was refused in-band, and state "unknown" when the call
    was interrupted (a timeout, a signal, a crash) and may or may not have
    applied. A later call may depend on an earlier one, and blind continuation
    after a failed write is how batches double-act, so the run stops there.
    """
    done = 0
    with private_open(out_path) as out:
        for n, tool, args in calls:
            try:
                res = unwrap(c.call(tool, args))
            except (Interrupted, UnknownOutcome) as exc:
                why = "terminated by signal" if isinstance(exc, Interrupted) else "unconfirmed response"
                out.write(json.dumps({"line": n, "tool": tool, "ok": False, "state": "unknown",
                                      "error": why}) + "\n")
                out.flush()
                print("%s at line %d (%s) after %d ok: outcome unknown, read back before any rerun"
                      % (why, n, tool, done), file=sys.stderr)
                raise
            except SystemExit:
                # die() already printed why; the call did not complete.
                out.write(json.dumps({"line": n, "tool": tool, "ok": False}) + "\n")
                print("stopped at line %d (%s) after %d ok" % (n, tool, done), file=sys.stderr)
                raise
            except BaseException as exc:
                # Interrupted mid-call: the tool may have run. Mark it so nobody
                # re-runs a write blind (read back instead), then let it propagate.
                out.write(json.dumps({"line": n, "tool": tool, "ok": False, "state": "unknown",
                                      "error": scrub(type(exc).__name__)}) + "\n")
                out.flush()
                print("interrupted at line %d (%s) after %d ok: outcome unknown, read back before any rerun"
                      % (n, tool, done), file=sys.stderr)
                raise
            why = inband_failure(res)
            if why:
                out.write(json.dumps({"line": n, "tool": tool, "ok": False, "refused": why, "result": res},
                                     ensure_ascii=False) + "\n")
                die("line %d (%s) refused in-band (%s); stopped after %d ok" % (n, tool, why, done))
            out.write(json.dumps({"line": n, "tool": tool, "ok": True, "result": res}, ensure_ascii=False) + "\n")
            out.flush()
            done += 1
    print("wrote %s (%d calls, one session)" % (out_path, done))


def _raise_exit(signum, frame):
    """SIGTERM and SIGHUP become SystemExit, so main()'s finally still closes the session.

    WHY: timeout(1) and most harness timeouts send SIGTERM; without this the
    process dies without the DELETE and the session lingers until the server
    reaps it, the exact leak this client exists to stop. SIGKILL cannot be caught.
    """
    raise Interrupted(128 + signum)


def main():
    sys.argv = select_server(sys.argv)
    if len(sys.argv) < 2:
        die(__doc__)
    cmd = sys.argv[1]
    calls = None
    if cmd == "batch" or (cmd == "call" and len(sys.argv) > 4):
        refuse_file_output_without_private_mode()
    if cmd == "batch":
        if len(sys.argv) < 4:
            die("batch <calls.jsonl> <out.jsonl>")
        calls = load_calls(sys.argv[2], sys.argv[3])
    # SIGHUP does not exist on Windows; install what the platform has.
    for name in ("SIGTERM", "SIGHUP"):
        sig = getattr(signal, name, None)
        if sig is not None:
            signal.signal(sig, _raise_exit)
    c = Client()
    # finally: c.close() releases the MCP session on every exit path (including
    # the SystemExit die() raises) so repeated invocations stop leaking sessions.
    try:
        try:
            c.initialize()

            if cmd == "list":
                for t in c.tools():
                    print(t["name"])
                    print("   inputSchema: %s" % json.dumps(t.get("inputSchema", {})))
                return

            if cmd == "call":
                if len(sys.argv) < 4:
                    die("call <tool> <args.json> [out.json]")
                try:
                    with open(sys.argv[3]) as fh:
                        args = json.load(fh)
                except (OSError, ValueError) as exc:
                    die("cannot read the args file %s: %s" % (sys.argv[3], exc))
                res = unwrap(c.call(sys.argv[2], args))
                out = sys.argv[4] if len(sys.argv) > 4 else None
                if out:
                    with private_open(out) as fh:
                        json.dump(res, fh, ensure_ascii=False, indent=1)
                    print("wrote %s" % out)
                else:
                    print(json.dumps(res, ensure_ascii=False)[:4000])
                return

            if cmd == "batch":
                run_batch(c, calls, sys.argv[3])
                return

            die("unknown subcommand %r" % cmd)
        except OSError as exc:
            # A refused, reset or timed-out connection. A batch has already marked
            # the call in flight "unknown" before this point.
            die("network error: %s" % exc)
    finally:
        c.close()


if __name__ == "__main__":
    main()
