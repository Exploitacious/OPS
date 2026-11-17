"""t3_ws.py: the one-shot WebSocket RPC client t3-api.sh uses for T3 0.1.0 writes.

T3 0.1.0 (orchestration protocol 2) has no HTTP write route: every write is one Effect-RPC
call over a WebSocket at GET /ws?orchestrationProtocol=2 on the server's port. This module
sends exactly one Request frame per call and reads until that request's Exit. Standard
library only (a team box need not have websocket-client); it is a minimal RFC 6455 client,
one call per connection and one thread.

Frame ids in parentheses (a13, c16 and so on) name exchanges recorded by a write-path probe
against a scratch T3 0.1.0 server; tests/fixtures/t3-v2/ws/ holds the ones the suites replay.

    python3 -I t3_ws.py call <base-url> <token-file> <rpc-tag> <payload.json> [--expect receipt|launch|object]

prints the Success value as JSON on stdout. --expect says what a Success must carry (default
receipt): receipt is dispatchCommand's {sequence}; launch is orchestration.launchThread's
{threadId, projection, resumed} (probe a56, c16); object is any JSON object (a read RPC such
as server.getConfig). A Success without it is exit 6: a Success tag alone never proves that
a command was accepted. Exit codes match t3-api.sh:
  0  Success carrying what --expect names
  3  the token file is missing or empty
  4  transport: the upgrade was refused (401, 426, any status but 101), or the connection
     was lost before the Exit arrived and the retry could not confirm its outcome (see RETRY)
  6  bad answer: a frame for this request that is not JSON or not a known Exit shape
  11 refused by the server: Exit Failure whose cause is a Fail (a domain error from the
     decider, for example "Thread <id> is still running. Stop it before settling."). The
     commandId is spent: re-read state and mint a fresh id; never retry it in a loop.
  12 the server could not decode the command: Exit Failure whose cause is a Die (schema
     decode or a defect). No receipt exists; this is a client defect, so fix the payload.

RETRY: transport loss (connect refused or reset, the socket closed or went silent before
the Exit) is retried ONCE, after a 1 s pause, on a fresh connection with the identical
frame: the same commandId and messageId. The server keeps a receipt per commandId, so a
replay of an accepted command returns the stored {sequence} and never applies it twice
(probe a13, a22). Nothing else is retried: a refused upgrade, a Fail and a Die are final.
If the retry's upgrade is refused, the first command may still have been accepted; only
a refused initial upgrade proves that nothing was sent. Socket deadlines cap the whole
upgrade and frame, including a response that arrives a byte at a time.

TOKEN: read in-process from the token file and sent only in the Authorization header of
the upgrade request. It is never printed, never logged and never on argv (the argv carries
the file path). Error text never echoes request headers.

KEEPALIVE: the server sent no WebSocket pings and closed nothing in 51 s of idle (probe
c22), so a call whose timeout is 20 s or less sends none. A longer call sends an
Effect-level {"_tag":"Ping"} every 15 s while it waits; the server answers {"_tag":"Pong"},
which is ignored. WebSocket ping frames from the server are answered with pong frames.
A one-shot call opens, sends, waits and closes. WHY not one long-lived socket: each
invocation of t3-api.sh is its own process; a long-lived socket suits a resident client.
Every 0-to-1 connection writes auth_sessions.last_connected_at (probe a08), which is
acceptable at the harness's write rate.
"""
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time
import urllib.parse

EXIT_NO_TOKEN = 3
EXIT_TRANSPORT = 4
EXIT_BAD_ANSWER = 6
EXIT_USAGE = 2
EXIT_SERVER_REFUSED = 11
EXIT_DECODE_DEFECT = 12

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WS_PATH = "/ws?orchestrationProtocol=2"
MAX_MESSAGE = 64 * 1024 * 1024     # a single Exit is small; cap a hostile or broken stream
MAX_HEADER = 64 * 1024
KEEPALIVE_AFTER_S = 20             # only a call that can last longer than this pings
KEEPALIVE_EVERY_S = 15
RETRY_PAUSE_S = 1.0


class TransportLost(Exception):
    """The connection failed or ended before the Exit arrived (retryable once)."""


class UpgradeRefused(Exception):
    """The server answered the upgrade with a status other than 101 (final)."""


class BadFrame(Exception):
    """A frame for this request is not JSON or not a known Exit shape (final)."""


def parse_base(base):
    """(host, port) from an http:// origin. Anything else is refused: the harness talks to a
    loopback server over plain HTTP, and guessing a scheme could send the bearer elsewhere."""
    u = urllib.parse.urlsplit(base)
    if u.scheme != "http" or not u.hostname:
        raise ValueError(f"base URL must be http://host:port, got {base!r}")
    if u.path not in ("", "/") or "?" in base or "#" in base or u.username is not None or u.password is not None:
        # HTTP guards use the complete base; the WebSocket uses the root /ws route.
        # Dropping a routing prefix here could guard one server and write to another.
        raise ValueError("base URL must be an http://host:port origin without a path, query, fragment or userinfo")
    return u.hostname, u.port or 80


def read_token(path):
    try:
        with open(path, "r") as fh:
            tok = fh.read().strip()
    except OSError:
        return None
    return tok or None


def redact(text, token):
    """Scrub a response before shortening it. A caller cannot match a bearer that we
    already cut in half, and raw JSON can hide it behind Unicode escapes."""
    def scrub(value):
        if isinstance(value, str):
            return value.replace(token, "<redacted>")
        if isinstance(value, list):
            return [scrub(v) for v in value]
        if isinstance(value, dict):
            return {scrub(k): scrub(v) for k, v in value.items()}
        return value

    try:
        value = json.loads(text)
    except ValueError:
        return scrub(text)
    return json.dumps(scrub(value))


# ---- framing --------------------------------------------------------------------------------

def _mask(payload, key):
    # bytes.translate cannot XOR with a rotating key; a per-byte loop is fine for frames this small.
    return bytes(b ^ key[i % 4] for i, b in enumerate(payload))


def encode_frame(opcode, payload=b""):
    """A masked client frame (RFC 6455 5.3: every client frame is masked)."""
    head = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    key = os.urandom(4)
    return head + key + _mask(payload, key)


def _remaining(deadline):
    left = deadline - time.monotonic()
    if left <= 0:
        raise TransportLost("the request deadline expired before the Exit arrived")
    return left


class Conn:
    def __init__(self, sock, pending):
        self.sock = sock
        self.buf = pending
        self.deadline = None

    def _fill(self, n):
        """Buffer at least n bytes without consuming any. A socket timeout here leaves the
        buffer intact, so the caller can wait again and the frame is parsed whole later."""
        while len(self.buf) < n:
            if self.deadline is not None:
                # A socket timeout caps each recv, not the whole frame: a trickle of
                # bytes must not extend the call indefinitely beyond its deadline.
                wait = self.sock.gettimeout()
                left = _remaining(self.deadline)
                self.sock.settimeout(left if wait is None else min(wait, left))
            chunk = self.sock.recv(max(4096, n - len(self.buf)))
            if not chunk:
                raise TransportLost("the server closed the connection before the Exit arrived")
            self.buf += chunk

    def send(self, opcode, payload=b""):
        self.sock.sendall(encode_frame(opcode, payload))

    def read_frame(self):
        """(opcode, fin, payload) of the next frame, consumed only once it is complete."""
        self._fill(2)
        b1, b2 = self.buf[0], self.buf[1]
        fin, opcode = bool(b1 & 0x80), b1 & 0x0F
        masked, n = b2 & 0x80, b2 & 0x7F
        pos = 2
        if n == 126:
            self._fill(4)
            n = struct.unpack(">H", self.buf[2:4])[0]
            pos = 4
        elif n == 127:
            self._fill(10)
            n = struct.unpack(">Q", self.buf[2:10])[0]
            pos = 10
        if n > MAX_MESSAGE:
            raise BadFrame(f"a frame of {n} bytes exceeds the {MAX_MESSAGE} byte cap")
        klen = 4 if masked else 0
        self._fill(pos + klen + n)
        key = self.buf[pos:pos + klen] if masked else None
        data = self.buf[pos + klen:pos + klen + n]
        self.buf = self.buf[pos + klen + n:]
        if key:
            data = _mask(data, key)
        return opcode, fin, data


def handshake(host, port, token, timeout):
    """Open the socket and upgrade. Returns a Conn. Raises UpgradeRefused or TransportLost."""
    deadline = time.monotonic() + timeout
    try:
        sock = socket.create_connection((host, port), timeout=timeout)
    except OSError as e:
        raise TransportLost(f"cannot connect to {host}:{port} ({e.__class__.__name__})") from None
    key = base64.b64encode(os.urandom(16)).decode()
    req = (f"GET {WS_PATH} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {token}\r\n\r\n")
    try:
        sock.settimeout(_remaining(deadline))
        sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            sock.settimeout(_remaining(deadline))
            chunk = sock.recv(4096)
            if not chunk:
                raise TransportLost("the server closed the connection during the upgrade")
            buf += chunk
            if len(buf) > MAX_HEADER:
                raise TransportLost(f"the upgrade answer has no end of headers within {MAX_HEADER} bytes")
    except OSError as e:
        sock.close()
        raise TransportLost(f"the upgrade failed ({e.__class__.__name__})") from None
    except TransportLost:
        sock.close()
        raise
    head, _, rest = buf.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    status = lines[0]
    headers = {}
    for ln in lines[1:]:
        if ":" in ln:
            k, v = ln.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    parts = status.split(" ", 2)
    code = parts[1] if len(parts) > 1 else "?"
    if code != "101":
        body = rest
        try:
            clen = int(headers.get("content-length", "0") or 0)
        except ValueError:
            clen = 0
        body_deadline = min(deadline, time.monotonic() + 2)
        try:
            while len(body) < min(clen, 4096):
                left = body_deadline - time.monotonic()
                if left <= 0:
                    break
                sock.settimeout(left)
                c = sock.recv(4096)
                if not c:
                    break
                body += c
        except OSError:
            pass
        sock.close()
        detail = redact(body.decode("utf-8", "replace"), token)
        raise UpgradeRefused(f"HTTP {code} on the WebSocket upgrade: {detail[:300]}")
    expect = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    if headers.get("sec-websocket-accept") != expect:
        sock.close()
        raise UpgradeRefused("the upgrade answer carries a wrong Sec-WebSocket-Accept")
    return Conn(sock, rest)


def receipt_problem(value):
    """None when value is a dispatchCommand receipt, else why not. dispatchCommand accepts a
    command by returning its receipt sequence; a Success tag alone (or a null or garbled
    value) cannot prove the wake was accepted."""
    if not isinstance(value, dict) or type(value.get("sequence")) is not int or value["sequence"] < 0:
        return "the Exit Success carries no valid dispatch receipt sequence"
    return None


def launch_problem(value):
    """None when value is an orchestration.launchThread result {threadId, projection, resumed}
    (probe a56, c16), else why not. It is not a receipt: launchThread returns the thread."""
    if (not isinstance(value, dict) or not isinstance(value.get("threadId"), str) or not value["threadId"]
            or type(value.get("resumed")) is not bool or not isinstance(value.get("projection"), dict)):
        return "the Exit Success carries no launch result (threadId, projection, resumed)"
    return None


def object_problem(value):
    """None when value is a JSON object (a read RPC such as server.getConfig), else why not."""
    if not isinstance(value, dict):
        return "the Exit Success value is not a JSON object"
    return None


EXPECT = {"receipt": receipt_problem, "launch": launch_problem, "object": object_problem}


def classify_exit(exit_obj, validate=receipt_problem):
    """('success', value) | ('fail', error dict) | ('die', defect text). Raises BadFrame.
    validate(value) names what a Success must carry (EXPECT); a value it rejects is BadFrame."""
    if not isinstance(exit_obj, dict):
        raise BadFrame("the Exit carries no exit object")
    tag = exit_obj.get("_tag")
    if tag == "Success":
        value = exit_obj.get("value")
        problem = validate(value)
        if problem:
            raise BadFrame(problem)
        return "success", value
    if tag == "Failure":
        cause = exit_obj.get("cause")
        causes = cause if isinstance(cause, list) else [cause]
        first = causes[0] if causes and isinstance(causes[0], dict) else {}
        if first.get("_tag") == "Fail":
            err = first.get("error")
            return "fail", err if isinstance(err, dict) else {"message": str(err)}
        if first.get("_tag") == "Die":
            return "die", str(first.get("defect"))
        raise BadFrame("the Exit Failure has an unknown cause {!r}".format(first.get("_tag")))
    raise BadFrame(f"the Exit has an unknown tag {tag!r}")


def call_once(host, port, token, tag, payload, timeout, request_id="1", validate=receipt_problem):
    """One connection, one Request, read until its Exit. Returns classify_exit's tuple."""
    deadline = time.monotonic() + timeout
    conn = handshake(host, port, token, min(timeout, 10))
    conn.deadline = deadline
    keepalive = timeout > KEEPALIVE_AFTER_S
    try:
        frame = {"_tag": "Request", "id": request_id, "tag": tag, "payload": payload, "headers": []}
        try:
            conn.sock.settimeout(_remaining(deadline))
            conn.send(0x1, json.dumps(frame).encode())
        except OSError as e:
            raise TransportLost(f"sending the request failed ({e.__class__.__name__})") from None
        msg_op, msg_buf = None, b""
        last_ping = time.monotonic()
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TransportLost(f"no Exit within {timeout}s")
            wait = min(left, KEEPALIVE_EVERY_S) if keepalive else left
            conn.sock.settimeout(wait)
            try:
                opcode, fin, data = conn.read_frame()
            # Keep socket.timeout for Python versions where it is not a TimeoutError alias.
            except socket.timeout:  # noqa: UP041
                # Before OSError: a timeout here is only "nothing yet".
                if keepalive and time.monotonic() - last_ping >= KEEPALIVE_EVERY_S - 0.5:
                    try:
                        conn.send(0x1, json.dumps({"_tag": "Ping"}).encode())
                    except OSError as e:
                        raise TransportLost(f"the keepalive ping failed ({e.__class__.__name__})") from None
                    last_ping = time.monotonic()
                continue
            except OSError as e:
                raise TransportLost(f"reading failed ({e.__class__.__name__})") from None
            if opcode == 0x9:                      # ping -> pong
                try:
                    conn.send(0xA, data)
                except OSError as e:
                    raise TransportLost(f"answering a ping failed ({e.__class__.__name__})") from None
                continue
            if opcode == 0xA:
                continue
            if opcode == 0x8:
                code = struct.unpack(">H", data[:2])[0] if len(data) >= 2 else None
                raise TransportLost(f"the server closed the socket (code {code}) before the Exit arrived")
            if opcode in (0x1, 0x2):
                msg_op, msg_buf = opcode, data
            elif opcode == 0x0 and msg_op is not None:
                msg_buf += data
                if len(msg_buf) > MAX_MESSAGE:
                    raise BadFrame(f"a message exceeds the {MAX_MESSAGE} byte cap")
            else:
                continue
            if not fin:
                continue
            text, msg_op, msg_buf = msg_buf, None, b""
            try:
                msg = json.loads(text.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                raise BadFrame(f"a frame is not JSON ({len(text)} bytes)") from None
            for m in (msg if isinstance(msg, list) else [msg]):
                if not isinstance(m, dict) or m.get("requestId") != request_id:
                    continue                       # Pong, other requests: not ours
                if m.get("_tag") == "Chunk":
                    # Not expected for a non-stream call; ack so a stream can never stall.
                    try:
                        conn.send(0x1, json.dumps({"_tag": "Ack", "requestId": request_id}).encode())
                    except OSError as e:
                        raise TransportLost(f"acknowledging a chunk failed ({e.__class__.__name__})") from None
                    continue
                if m.get("_tag") == "Exit":
                    return classify_exit(m.get("exit"), validate)
    finally:
        try:
            # Closing is best effort and must not add another full socket timeout.
            conn.sock.settimeout(max(0, min(0.1, deadline - time.monotonic())))
            conn.send(0x8, struct.pack(">H", 1000))
        except OSError:
            pass
        try:
            conn.sock.close()
        except OSError:
            pass


def call(base, token, tag, payload, timeout=30, pause=RETRY_PAUSE_S, _once=call_once, validate=None):
    """call_once, retried once on TransportLost with the identical payload (same ids).
    Returns (kind, value, attempts). Raises TransportLost if the retry loses its answer
    or its upgrade is refused after the first call's ambiguous outcome. validate is
    classify_exit's (default: a dispatch receipt); None keeps _once's own default."""
    host, port = parse_base(base)
    extra = {} if validate is None else {"validate": validate}
    try:
        kind, value = _once(host, port, token, tag, payload, timeout, **extra)
        return kind, value, 1
    except TransportLost as first:
        time.sleep(pause)
        try:
            kind, value = _once(host, port, token, tag, payload, timeout, **extra)
            return kind, value, 2
        except TransportLost as second:
            raise TransportLost(f"{first}; the retry with the same commandId also failed: {second}") from None
        except UpgradeRefused as second:
            # Only a refused FIRST upgrade proves nothing was sent. The first call
            # here lost its result, so it may have applied before this retry failed.
            raise TransportLost(f"{first}; the retry upgrade was refused: {second}; "
                                "the first command may already have been accepted") from None


def _err(msg):
    sys.stderr.write(msg.rstrip("\n") + "\n")


def describe(payload):
    if isinstance(payload, dict):
        return "{} (commandId {})".format(payload.get("type") or "command", payload.get("commandId") or "none")
    return "request"


def main(argv):
    expect = "receipt"
    if len(argv) == 8 and argv[6] == "--expect" and argv[7] in EXPECT:
        expect, argv = argv[7], argv[:6]
    if len(argv) != 6 or argv[1] != "call":
        _err("t3_ws: usage: call <base-url> <token-file> <rpc-tag> <payload.json> [--expect receipt|launch|object]")
        return EXIT_USAGE
    base, token_file, tag, payload_file = argv[2:6]
    token = read_token(token_file)
    if token is None:
        _err(f"t3-api: token file not found or empty: {token_file}")
        return EXIT_NO_TOKEN
    try:
        with open(payload_file, "rb") as fh:
            payload = json.loads(fh.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as e:
        _err(f"t3_ws: cannot read the payload file {payload_file}: {e.__class__.__name__}")
        return EXIT_USAGE
    try:
        timeout = float(os.environ.get("OPS_T3_HTTP_TIMEOUT") or 30)
    except ValueError:
        timeout = 30.0
    what = redact(describe(payload), token)
    try:
        kind, value, _attempts = call(base, token, tag, payload, timeout, validate=EXPECT[expect])
    except ValueError as e:
        _err(f"t3-api: {e}")
        return EXIT_TRANSPORT
    except UpgradeRefused as e:
        _err(f"t3-api: {what} refused at the WebSocket upgrade, nothing sent: {e}")
        return EXIT_TRANSPORT
    except TransportLost as e:
        _err(f"t3-api: transport error sending {what} over {tag}: {e}")
        return EXIT_TRANSPORT
    except BadFrame as e:
        _err(f"t3-api: bad answer to {what}: {e}")
        return EXIT_BAD_ANSWER
    if kind == "success":
        print(json.dumps(value))
        return 0
    if kind == "fail":
        etag = value.get("_tag") or "error"
        msg = str(value.get("message") or value.get("detail") or "no message")
        # Refusals can echo request data just as upgrade errors can; scrub their
        # decoded values before any part is printed.
        _err(redact(f"t3-api: {what} refused by the server ({etag}): {msg.splitlines()[0] if msg else msg}; this commandId is spent: re-read the thread and use a "
                    "fresh id", token))
        return EXIT_SERVER_REFUSED
    first = redact(value, token).splitlines()[0] if value else ""
    _err(f"t3-api: the server could not decode {what} (Die, no receipt): {first[:300]}; a client defect, not retried")
    return EXIT_DECODE_DEFECT


if __name__ == "__main__":
    sys.exit(main(sys.argv))
