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
  OPS_MCP_REFUSAL_CODES comma-separated refusal codes ([a-z][a-z0-9_]*) that mean the
                        server refused THIS caller (bin/await-approval passes its
                        terminal_refusals here). Unset or empty: no notes, as before.
  OPS_MCP_CONNECTOR     the connector name a refusal note names (default "unknown").
  OPS_MCP_KEY_SOURCE    the label a note gives a key that is in the environment
                        (default "env:<variable>"; bin/await-approval sets
                        "claude.json:<entry>" when it supplied the key).
  A malformed value of the last three is refused before any request.

Refusal notes: when an answer carries one of OPS_MCP_REFUSAL_CODES in a structured
field (error, code or error_code, on the answer or its "error" or "context" object;
the envelope is read before its "result"; for isError, the structured content and
each JSON text block; for a JSON-RPC error, the error and its data), `call` (and
`batch`, on the call that stops it) adds exactly one stderr line, "NOTE: the gateway
answered <code>: ...", on a line of its own after any ERROR line, that
names where the key came from (env:<variable>, dotenv:<file>, or the label above),
its last four characters when it is at least 16 long, and the connector; never the
key. Free text is never read for it. Exit codes and out files are unchanged.

Server text this client shows (an error body, a tool answer, the call preview, the
list output) has every form of the key redacted first (raw and JSON-escaped), then
each line break escaped so it stays on one line, and only then is it clipped. WHY
the order: clipping first leaves the start of a key that straddles the cut, and a
line break in a body could start a line that reads as the client's own NOTE.

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
# Where the key came from (a label such as "env:OPS_MCP_API_KEY" or "dotenv:<file>")
# and its last four characters when it is long enough that four give little away.
# api_key() captures both when it reads the credential.
KEY_ORIGIN = {"source": None, "tail": None}
MIN_TAIL_KEY_LEN = 16
# The refusal codes that get a note (OPS_MCP_REFUSAL_CODES), set by refusal_settings().
REFUSAL_CODES = frozenset()
CODE_RE = re.compile(r"[a-z][a-z0-9_]{0,63}")
NOTE_PREFIX = "NOTE: the gateway answered "
# Every character str.splitlines() breaks on. bin/await-approval splits this client's
# stderr into lines and trusts one that starts with NOTE_PREFIX, so server text must
# never contain one raw.
LINE_BREAKS = re.compile("[\n\r\x0b\x0c\x1c\x1d\x1e\x85\u2028\u2029]")


def _key_forms(secret):
    """The secret as it can appear in text: raw, and JSON-escaped once and twice (a key
    inside a JSON string, and a JSON text carried inside another JSON string), each also
    with "/" escaped as some servers write it. Longest first, so no form is cut short."""
    forms, level = {secret}, {secret}
    for _ in range(2):
        escaped = set()
        for form in level:
            for ascii_only in (True, False):
                quoted = json.dumps(form, ensure_ascii=ascii_only)[1:-1]
                escaped.update((quoted, quoted.replace("/", "\\/")))
        forms |= escaped
        level = escaped
    return sorted(forms, key=len, reverse=True)


def scrub(text):
    text = str(text)
    for s in _SECRETS:
        if s:
            for form in _key_forms(s):
                text = text.replace(form, "<redacted>")
    return text


def _escape_break(match):
    char = match.group(0)
    return {"\n": "\\n", "\r": "\\r"}.get(char) or "\\u%04x" % ord(char)


def shown(text, limit=None):
    """Server text as this client may display it: every form of the key redacted, then
    each line break escaped (so it stays on one line), then clipped to limit.

    The one place server text is clipped. WHY this order: clipping before redacting
    leaves the start of a key that straddles the cut, and an escaped form of the key
    is a different string from the key. The escapes are valid inside a JSON string,
    so a JSON text stays valid JSON.
    """
    text = LINE_BREAKS.sub(_escape_break, scrub(text))
    return text if limit is None else text[:limit]


def die(msg, code=None):
    print("ERROR: %s" % scrub(msg), file=sys.stderr)
    print_refusal_note(code)
    sys.exit(1)


def is_label(value):
    """A connector or key-source label: one printable line of at most 200 characters."""
    return isinstance(value, str) and 0 < len(value) <= 200 and value.isprintable() and value.strip() == value


def refusal_settings():
    """Read and check OPS_MCP_REFUSAL_CODES, OPS_MCP_CONNECTOR and OPS_MCP_KEY_SOURCE before
    any request; a malformed value is refused (and not printed), never guessed at."""
    global REFUSAL_CODES
    raw = os.environ.get("OPS_MCP_REFUSAL_CODES") or ""
    codes = [c.strip() for c in raw.split(",") if c.strip()]
    if not all(CODE_RE.fullmatch(c) for c in codes):
        die("OPS_MCP_REFUSAL_CODES must be comma-separated codes of lowercase letters, digits and '_' "
            "(the value is not printed)")
    REFUSAL_CODES = frozenset(codes)
    for var in ("OPS_MCP_CONNECTOR", "OPS_MCP_KEY_SOURCE"):
        value = os.environ.get(var)
        if value and not is_label(value):
            die("%s must be one printable line of at most 200 characters (the value is not printed)" % var)


class UnknownOutcome(SystemExit):
    """A dispatched call returned no trustworthy outcome; read back before retrying."""


def env_file():
    return os.path.join(os.environ.get("OPS_DIR") or os.path.expanduser("~/OPS"), ".env")


def api_key():
    k = os.environ.get(KEY_VAR)
    path = env_file()
    source = os.environ.get("OPS_MCP_KEY_SOURCE") or "env:%s" % KEY_VAR
    if not k:
        source = "dotenv:%s" % path
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
    KEY_ORIGIN["source"] = source
    KEY_ORIGIN["tail"] = k[-4:] if len(k) >= MIN_TAIL_KEY_LEN else None
    return k


def refusal_code(obj):
    """The configured refusal code a tool answer carries, or None.

    Reads only structured fields: error, code and error_code, on the object and on its
    "error" and "context" objects, the envelope first and then its "result" (a refusal
    around an OPEN-looking result is still a refusal). Free text is never read, so a
    command's output that merely quotes a code is not a refusal.
    """
    if not REFUSAL_CODES:
        return None
    layers = [obj]
    if isinstance(obj, dict) and isinstance(obj.get("result"), dict):
        layers.append(obj["result"])
    for layer in layers:
        if not isinstance(layer, dict):
            continue
        for holder in (layer, layer.get("error"), layer.get("context")):
            if not isinstance(holder, dict):
                continue
            for field in ("error", "code", "error_code"):
                value = holder.get(field)
                if isinstance(value, str) and value in REFUSAL_CODES:
                    return value
    return None


def first_refusal(candidates):
    for obj in candidates:
        code = refusal_code(obj)
        if code:
            return code
    return None


def iserror_code(res):
    """The refusal code in an isError result: the result, its structured content, then each
    text block that holds JSON (a block with no text is skipped, not a crash)."""
    if not REFUSAL_CODES:
        return None
    code = first_refusal((res, res.get("structuredContent")))
    if code:
        return code
    content = res.get("content")
    if not isinstance(content, list):
        return None
    for block in content:
        if isinstance(block, dict) and block.get("type") == "text":
            try:
                payload = json.loads(block.get("text"))
            except (TypeError, ValueError, RecursionError):
                continue
            code = refusal_code(payload)
            if code:
                return code
    return None


def print_refusal_note(code):
    """Print one NOTE line for a configured refusal code.

    Keep the provenance that api_key() captured in a JSON suffix for await-approval.
    The dotenv file can change while a long poll is waiting for its answer.
    """
    if not code or code not in REFUSAL_CODES:
        return
    source = shown(KEY_ORIGIN["source"] or "unknown")
    tail = shown(KEY_ORIGIN["tail"]) if KEY_ORIGIN["tail"] else None
    connector = shown(os.environ.get("OPS_MCP_CONNECTOR") or "unknown")
    used = f"the key from {source}"
    if tail:
        used += f" (ends {tail})"
    origin = json.dumps({"key_source": source, "key_tail": tail}, separators=(",", ":"))
    print(f"{NOTE_PREFIX}{shown(code)}: the server refused this caller. This call used {used}, "
          f"connector {connector}. Use the key or login that made the request.\t{origin}", file=sys.stderr)


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
                die("no JSON-RPC payload in SSE body: %s" % shown(body, 500))
            return out
        if not body.strip():
            return None
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            die("non-JSON response (HTTP %s, %s): %s" % (resp.status_code, shown(ctype, 200), shown(body, 500)))

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
                die("HTTP %s on %s: %s" % (resp.status_code, method, shown(resp.content.decode("utf-8", "replace"), 500)))
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
            err = msg["error"]
            data = err.get("data") if isinstance(err, dict) else None
            die(f"JSON-RPC error on {method}: {shown(json.dumps(err), 800)}",
                first_refusal((msg, err, data)))
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
            die(f"no tool matching {suffix!r}; available: {shown(json.dumps(names))}")
        die(f"ambiguous tool suffix {suffix!r}: {shown(json.dumps(hits))}")

    def call(self, suffix, args):
        name = self.resolve(suffix)
        res = self.rpc("tools/call", {"name": name, "arguments": args})
        if res.get("isError"):
            die(f"tool {shown(name)} returned isError: {shown(json.dumps(res), 800)}", iserror_code(res))
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
                reply = c.call(tool, args)
                res = unwrap(reply)
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
                die(f"line {n} ({tool}) refused in-band ({shown(why)}); stopped after {done} ok",
                    first_refusal((reply, res)))
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
    refusal_settings()  # before any session opens: a malformed setting sends nothing
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
                    print(shown(t["name"]))
                    print("   inputSchema: %s" % shown(json.dumps(t.get("inputSchema", {}))))
                return

            if cmd == "call":
                if len(sys.argv) < 4:
                    die("call <tool> <args.json> [out.json]")
                try:
                    with open(sys.argv[3]) as fh:
                        args = json.load(fh)
                except (OSError, ValueError) as exc:
                    die("cannot read the args file %s: %s" % (sys.argv[3], exc))
                reply = c.call(sys.argv[2], args)
                res = unwrap(reply)
                out = sys.argv[4] if len(sys.argv) > 4 else None
                if out:
                    with private_open(out) as fh:
                        json.dump(res, fh, ensure_ascii=False, indent=1)
                    print("wrote %s" % out)
                else:
                    print(shown(json.dumps(res, ensure_ascii=False), 4000))
                # Read the tool wrapper first. Unwrap can discard a refusal alongside
                # structuredContent, which may contain a status from another caller.
                print_refusal_note(first_refusal((reply, res)))
                return

            if cmd == "batch":
                run_batch(c, calls, sys.argv[3])
                return

            die("unknown subcommand %r" % cmd)
        except OSError as exc:
            # A refused, reset or timed-out connection. A batch has already marked
            # the call in flight "unknown" before this point.
            die("network error: %s" % shown(exc))
    finally:
        c.close()


if __name__ == "__main__":
    main()
