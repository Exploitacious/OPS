#!/usr/bin/env python3
"""model-fallback-watch: flag a session or lane that Claude Code moved to another model.

Called by model-fallback-watch.sh on every Stop with the hook payload on stdin. Prints
nothing, or one JSON line {"decision": "block", "reason": ..., "systemMessage": ...}.

Why: when a request is refused, Claude Code can answer it on a fallback model by itself,
and the only trace is a system record in a transcript:

  {"type": "system", "subtype": "model_refusal_fallback", "apiRefusalCategory": "...",
   "originalModel": ..., "fallbackModel": ..., "requestId": ..., "uuid": ..., ...}

Work that ran on the fallback model deserves a second look, so this hook makes the drop
visible instead of leaving it in a file nobody reads. Field names and the first subtype
below were seen in real transcripts. The other two subtypes were NOT observed on a real
installation: they are known only from the names Claude Code ships, and they are read with
the same fields on that assumption (UNVERIFIED).

  model_refusal_fallback   seen on real installations
  model_fallback           UNVERIFIED, never seen on a real installation
  model_consent_fallback   UNVERIFIED, never seen on a real installation

A hard refusal with no fallback ("model_refusal_no_fallback") is not a model change and
stops the work visibly, so it is not flagged here. A record whose "scope" is "local" means
one response came from the fallback model and the session model did not change; any other
scope is reported as a switch from that point on.

What it reads: the session transcript (transcript_path) and every lane transcript under
<transcript dir>/<session_id>/subagents/, at any depth (workflow lanes sit in
subagents/workflows/wf_<id>/), with each lane's description from its agent-*.meta.json.
A delegated child that is a session of its own runs this hook on its own Stop. Only a
parsed record whose type is "system" and whose subtype is one of the three counts: the
words quoted in a message, a tool result or a raw file do not. A per-session offset file
remembers how far each transcript was read. A Stop reads complete lines appended since
then, or starts at the beginning if the file was replaced or its checkpoint changed.

What it does with a new event: under one exclusive lock it reads the ledger
${OPS_STATE_DIR:-~/.local/state/ops}/model-fallbacks.tsv and appends one row per new event
(the key is the requestId, which a provisional and a final record share, else the uuid).
It discards an unterminated tail from an interrupted append under the same lock. After
syncing new rows, it saves the offsets (write to a temp file, then replace) and blocks the
stop once so the agent tells the Operator which work came from the fallback model and
re-verifies or reruns it. It never blocks a stop that is already a continuation (stop_hook_active), so it
cannot loop. If the lock cannot be taken within 5 seconds or the ledger cannot be written,
it still blocks, says so, and keeps its read offsets where they were, so the flag repeats
until the state directory is fixed. An unexpected error blocks too, naming the traceback
file, so a broken check is loud rather than silent.

Privacy: the ledger, the offsets and the error log hold transcript paths and lane
descriptions. Every file this hook creates is mode 0600 and every directory it creates is
mode 0700, whatever the umask; a directory that already exists is left as it is.

Platform behavior: the lock is fcntl.flock, which Windows Python lacks. There the ledger
is written without a lock, so concurrent Stops can flag and log the same event twice.
An incomplete ledger row requires manual repair in this mode. File modes are advisory
on Windows. On a POSIX host a flock that fails for any reason other than waiting is
treated as a ledger failure (blocks, offsets kept).

Off switch: MODEL_FALLBACK_WATCH=0. Tests: model-fallback-watch-selftest.sh.
"""
import glob
import hashlib
import json
import os
import re
import sys
import time

SUBTYPES = ("model_refusal_fallback", "model_fallback", "model_consent_fallback")
MARK = b'_fallback"'
CHECKPOINT_BYTES = 512
COLUMNS = ["logged_at", "session_id", "where", "event_key", "event_time", "category",
           "original_model", "fallback_model", "scope", "transcript"]
LABEL_MAX = 80
LOCK_WAIT = 5.0  # seconds; under the wrapper's 8 s bound so a stuck lock is reported, not killed
STATE = os.environ.get("OPS_STATE_DIR") or os.path.expanduser("~/.local/state/ops")
CONTINUATION = [False]


def clean(v, limit=None):
    s = " ".join(str(v if v is not None else "").split())
    s = s.encode("utf-8", "replace").decode("utf-8")
    if limit and len(s) > limit:
        s = s[:limit - 3] + "..."
    return s


def private_dir(path):
    """Create `path` as an owner-only directory. An existing one is not ours to chmod."""
    os.makedirs(path, mode=0o700, exist_ok=True)


def lock_exclusive(f):
    """Return True if locked, False on a platform without fcntl, or raise on lock failure."""
    try:
        import fcntl
    except ImportError:
        return False
    deadline = time.monotonic() + LOCK_WAIT
    while True:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise OSError("ledger lock not acquired within %d seconds" % LOCK_WAIT)
            time.sleep(0.05)


def events_in(path, cursor):
    """Read complete lines through the size observed on open, then return the new cursor."""
    found = []
    try:
        with open(path, "rb") as f:
            stat = os.fstat(f.fileno())
            identity = [stat.st_dev, stat.st_ino]
            end, head, tail = 0, b"", b""
            # A replacement can be larger than the old file. A rewrite on the
            # same inode can preserve the last few lines, so sample the head too.
            if isinstance(cursor, dict) and cursor.get("file") == identity:
                offset = cursor.get("offset")
                if isinstance(offset, int) and 0 < offset <= stat.st_size:
                    length = min(offset, CHECKPOINT_BYTES)
                    first = f.read(length)
                    f.seek(offset - length)
                    last = f.read(length)
                    if hashlib.sha256(first + last).hexdigest() == cursor.get("checkpoint"):
                        end, head, tail = offset, first, last
            f.seek(end)
            # Buffered reads also tolerate a concurrent truncate, which can
            # kill a process that has the truncated file memory-mapped.
            while end < stat.st_size:
                raw = f.readline(stat.st_size - end)
                if not raw.endswith(b"\n"):
                    break
                end += len(raw)
                if len(head) < CHECKPOINT_BYTES:
                    head += raw[:CHECKPOINT_BYTES - len(head)]
                tail = (tail + raw[-CHECKPOINT_BYTES:])[-CHECKPOINT_BYTES:]
                if MARK not in raw:
                    continue
                try:
                    rec = json.loads(raw)
                except (ValueError, RecursionError):
                    continue
                if isinstance(rec, dict) and rec.get("type") == "system" and rec.get("subtype") in SUBTYPES:
                    found.append(rec)
            return found, {"file": identity, "offset": end, "checkpoint": hashlib.sha256(head + tail).hexdigest()}
    except (OSError, ValueError):
        return found, cursor


def lane_label(path):
    meta = path[:-len(".jsonl")] + ".meta.json"
    try:
        with open(meta, encoding="utf-8", errors="replace") as f:
            m = json.load(f)
        desc = clean(m.get("description"), LABEL_MAX)
        kind = clean(m.get("agentType"), 40)
        if desc and kind:
            return "lane '%s' (%s)" % (desc, kind)
        if desc or kind:
            return "lane '%s'" % (desc or kind)
    except Exception:
        pass
    return "lane %s" % clean(os.path.basename(path)[len("agent-"):-len(".jsonl")], LABEL_MAX)


def event_key(rec):
    for k in ("requestId", "uuid"):
        v = clean(rec.get(k), 200)
        if v:
            return v
    return clean("ts:%s:%s:%s" % (rec.get("timestamp"), rec.get("originalModel"),
                                  rec.get("fallbackModel")), 200)


def field(rec, *names):
    for n in names:
        v = rec.get(n)
        if v not in (None, ""):
            return clean(v, 120)
    return ""


def offsets_path(sid):
    return os.path.join(STATE, "model-fallback-scan", re.sub(r"[^A-Za-z0-9._-]", "_", sid) + ".json")


def write_private(path, text):
    """Write text to path as a 0600 file."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", errors="replace") as f:
        f.write(text)
    os.chmod(path, 0o600)  # a pre-existing file keeps its old mode through O_CREAT


def main():
    if os.environ.get("MODEL_FALLBACK_WATCH", "1") == "0":
        return
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    if not isinstance(payload, dict):
        return
    if payload.get("stop_hook_active") in (True, "true", 1):
        CONTINUATION[0] = True
        return
    tp = payload.get("transcript_path")
    if not isinstance(tp, str) or not tp.endswith(".jsonl") or not os.path.isfile(tp):
        return
    sid = payload.get("session_id")
    if not isinstance(sid, str) or not sid:
        sid = os.path.basename(tp)[:-len(".jsonl")]

    sources = [("this session", tp)]
    lanes = os.path.join(glob.escape(os.path.dirname(tp)), glob.escape(sid), "subagents")
    for p in sorted(glob.glob(os.path.join(lanes, "**", "agent-*.jsonl"), recursive=True)):
        sources.append((lane_label(p), p))

    opath = offsets_path(sid)
    try:
        with open(opath, encoding="utf-8") as f:
            offsets = json.load(f)
        if not isinstance(offsets, dict):
            offsets = {}
    except Exception:
        offsets = {}
    new_offsets = dict(offsets)
    events = []
    for where, path in sources:
        found, cursor = events_in(path, offsets.get(path))
        new_offsets[path] = cursor
        for rec in found:
            events.append((where, path, rec))

    def save_offsets():
        # Atomic: a reader never sees half a file. A failure here is not reported: the
        # events are already in the ledger, which dedups them when the next Stop rereads.
        tmp = opath + ".tmp.%d" % os.getpid()
        try:
            private_dir(STATE)
            private_dir(os.path.dirname(opath))
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(new_offsets, f)
            os.replace(tmp, opath)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass

    if not events:
        save_offsets()
        return

    # One line per event key, even when the same record shows in two files this Stop.
    uniq, keys = [], set()
    for e in events:
        k = event_key(e[2])
        if k not in keys:
            keys.add(k)
            uniq.append(e)

    ledger = os.path.join(STATE, "model-fallbacks.tsv")
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    new, write_error = [], None
    try:
        private_dir(STATE)
        fd = os.open(ledger, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a+b") as f:
            os.chmod(ledger, 0o600)
            locked = lock_exclusive(f)
            f.seek(0)
            seen = set()
            end = 0
            for raw in f:
                if not raw.endswith(b"\n"):
                    # A failed append can leave the event ID in an incomplete
                    # row. Trim that tail so the event is written on retry.
                    if not locked:
                        raise OSError("incomplete ledger row requires manual repair without a lock")
                    f.truncate(end)
                    break
                end += len(raw)
                cols = raw.decode("utf-8", "replace").rstrip("\r\n").split("\t")
                if len(cols) == len(COLUMNS):
                    seen.add((cols[1], cols[3]))
            new = [e for e in uniq if (clean(sid), event_key(e[2])) not in seen]
            if new:
                f.seek(0, os.SEEK_END)
                if f.tell() == 0:
                    f.write(("\t".join(COLUMNS) + "\n").encode("utf-8"))
                for where, path, rec in new:
                    row = "\t".join((
                        now, clean(sid), clean(where), event_key(rec), field(rec, "timestamp"),
                        field(rec, "apiRefusalCategory", "category"),
                        field(rec, "originalModel", "fromModel"),
                        field(rec, "fallbackModel", "toModel"), field(rec, "scope"),
                        clean(path)))
                    f.write((row + "\n").encode("utf-8"))
                f.flush()
                os.fsync(f.fileno())
    except OSError as exc:
        write_error = clean(exc, 160)
        new = uniq
    if write_error is None:
        save_offsets()
    if not new:
        return

    lines, short = [], []
    for where, _path, rec in new:
        frm = field(rec, "originalModel", "fromModel") or "the chosen model"
        to = field(rec, "fallbackModel", "toModel") or "another model"
        cat = field(rec, "apiRefusalCategory", "category")
        why = ("after a %s refusal" % cat) if cat else (
            "after a refusal" if rec.get("subtype") == "model_refusal_fallback" else
            "(%s)" % clean(rec.get("subtype")))
        at = field(rec, "timestamp") or "an unknown time"
        if rec.get("scope") == "local":
            span = "one response in it came from %s; its own model did not change" % to
        else:
            span = "from that point on it ran on %s" % to
        lines.append("- %s: %s moved to %s %s at %s; %s." % (where, frm, to, why, at, span))
        short.append("%s: %s to %s" % (where, frm, to))
    if write_error is None:
        note = f"Logged in {ledger}."
    else:
        note = (f"Could not write the ledger at {ledger} ({write_error}), so this flag repeats until the "
                "state directory is fixed; say that too.")
    reason = ("Model fallback (the session or a lane was moved to another model; every drop "
              "is flagged so it can be scrutinized and followed up):\n" + "\n".join(lines)
              + "\nBefore you end this turn, tell the Operator in plain words which work "
              "came from the fallback model, then re-verify its specifics or rerun that part "
              "on the intended model. " + note)
    print(json.dumps({"decision": "block", "reason": reason,
                      "systemMessage": "Model fallback: " + "; ".join(short)}))


if __name__ == "__main__":
    # makedirs applies its mode to the leaf only. Constrain newly created
    # parent directories too, even when the caller uses a permissive umask.
    os.umask(0o077)
    try:
        main()
    except Exception:
        # Never break a session, never fail silently: keep the traceback (appended, the
        # last 200 lines kept) and, outside a continuation, block once naming it.
        import traceback
        err = os.path.join(STATE, "model-fallback-watch.err")
        kept = True
        try:
            private_dir(STATE)
            old = []
            try:
                with open(err, encoding="utf-8", errors="replace") as f:
                    old = f.readlines()[-150:]
            except OSError:
                pass
            write_private(err, "".join(old) + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                          + "\n" + traceback.format_exc())
        except OSError:
            kept = False
        if not CONTINUATION[0]:
            where = ("traceback in %s" % err) if kept else (
                "the traceback could not be saved to %s" % err)
            print(json.dumps({"decision": "block", "reason": (
                "model-fallback-watch could not finish its check this turn (%s). "
                "Tell the Operator the model-fallback check is not working until it is "
                "fixed." % where),
                "systemMessage": "Model-fallback check failed; %s" % where}))
