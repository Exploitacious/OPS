#!/usr/bin/env python3
"""Tell an agent that a rejected AskUserQuestion is not an answer from the Operator.

Run by askuser-cancel.sh with a hook payload on stdin. Prints at most one JSON object (an
additionalContext or a Stop block), always exits 0, and logs one line per time it speaks to
${OPS_STATE_DIR:-~/.local/state/ops}/askuser-cancel.jsonl (never message text).

The defect: in T3 Code a message or notification that arrives while an AskUserQuestion is
pending cancels the question. Claude Code hands the agent the stock rejection, "The user
doesn't want to proceed with this tool use ... STOP what you are doing and wait for the user",
and the agent reads that as the Operator declining. In one observed case a thread told the
Operator they had declined its question and put the work on hold 95 minutes after asking; the
Operator had not declined, another thread's message had cancelled it. The wrong text comes
from T3 Code and Claude Code, so the upstream fix is a better deny message there. This is the
local mitigation: put the fact in front of the agent. It reads a tool result and adds context;
it never judges what the agent wrote.

WHERE IT CAN FIRE. Probed on Claude Code 2.1.319, driving a real session as an SDK host
(stream-json, --permission-prompt-tool stdio) that denied an AskUserQuestion exactly the way T3
Code does: PostToolUse, PostToolUseFailure and PermissionDenied hooks (matcher AskUserQuestion
and ".*") all stayed silent, while the control run's PostToolUse for a Bash call fired, and the
model answered "you declined". A rejected tool never executes, so no post-tool event exists for
it. What does fire, in order of use:
  UserPromptSubmit  the message that cancelled the question is delivered right after the
                    rejection (a fraction of a second later), and this hook runs for it, before
                    the model's next call. The one event that arrives in time.
  Stop              the backstop for a cancel with no message behind it: the turn ends and
                    this blocks once, so the agent corrects itself before waiting.
  PostToolUse / PostToolUseFailure / PermissionDenied (tool AskUserQuestion)
                    handled too, so a Claude Code that starts firing them is covered with no
                    change here; today they never run for a rejection.
Both transcript events look for the latest AskUserQuestion whose result is the rejection
(is_error true, the stock text or "Tool permission request aborted"), not answered by a later
AskUserQuestion, newer than 30 minutes, and not yet reported (the tool_use id is kept per
session). The tool events go through the same gate (speak_once: fresh, not yet reported, not a
lane, then remembered by tool_use id), so one rejected question is reported once across every
event, whichever arrives first; a tool event's age is the rejection's age in the transcript when
the payload names one, else zero. Lanes are skipped (agent_id, or bin/lane-class saying t3-lane
or agent-lane; a box without bin/lane-class counts as a foreman). A rejection from the Operator
declining on purpose reads the same as a cancel, so the reminder says to treat it as no answer
unless they say they declined.
"""
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

TAIL_BYTES = 2 * 1024 * 1024
FRESH_S = 30 * 60
STATE_TTL_S = 7 * 86400
LOG_MAX_BYTES = 256 * 1024
LANES = ("foreman", "t3-lane", "agent-lane")
LANE_CLASS_TIMEOUT_S = 0.4
# Cheap byte test before a line is parsed: only lines that can matter are decoded.
MARKERS = (b"AskUserQuestion", b"want to proceed with this tool use", b"Tool permission request aborted")
REJECTION = re.compile(r"doesn't want to proceed with this tool use|Tool permission request aborted", re.I)
TOOL_EVENTS = ("PostToolUse", "PostToolUseFailure", "PermissionDenied")

MESSAGE = (
    "Your AskUserQuestion was rejected before the Operator answered. In T3 Code a message or notification "
    "that arrives while a question is pending cancels it, and the tool result then reads as if the user "
    "declined. Treat it as no answer unless they say they declined: do not record a decision as declined "
    "and do not tell the Operator they declined. Re-ask once (numbered prose, with your recommendation and what "
    "happens if they say nothing), or proceed on the stated default when the work is reversible. If the "
    "message that just arrived settles the question, use that."
)


def state_dir():
    return Path(os.environ.get("OPS_STATE_DIR") or Path.home() / ".local/state/ops")


def text_of(value):
    """Every string inside a tool result or error, joined: the rejection text can sit in a
    plain string, a text block or a nested object, depending on the event."""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return " ".join(text_of(v) for v in value.values())
    if isinstance(value, list):
        return " ".join(text_of(v) for v in value)
    return ""


def parse_time(stamp):
    try:
        return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def read_tail(path):
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            end = fh.tell()
            start = max(0, end - TAIL_BYTES)
            fh.seek(start)
            data = fh.read(end - start)
    except OSError:
        return []
    lines = data.split(b"\n")
    return lines[1:] if start else lines


def scan_cancelled(path):
    """(latest, ages) from the tail of the transcript. ages maps the tool_use id of every
    AskUserQuestion that was rejected to the age of the rejection in seconds. latest is
    (tool_use_id, age) for the most recent one not asked again since, or None."""
    asked, cancelled, ages = set(), None, {}
    for raw in read_tail(path):
        if not raw.strip() or not any(m in raw for m in MARKERS):
            continue
        try:
            record = json.loads(raw)
        except ValueError:
            continue
        content = (record.get("message") or {}).get("content") if isinstance(record, dict) else None
        if not isinstance(content, list) or record.get("isSidechain"):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use" and block.get("name") == "AskUserQuestion":
                asked.add(block.get("id"))
                cancelled = None  # asked again: any earlier cancellation was dealt with
            elif (block.get("type") == "tool_result" and block.get("is_error") and block.get("tool_use_id") in asked
                  and REJECTION.search(text_of(block.get("content")))):
                stamp = parse_time(record.get("timestamp"))
                age = (time.time() - stamp) if stamp else 0.0
                ages[block["tool_use_id"]] = age
                cancelled = (block["tool_use_id"], age)
    return cancelled, ages


def latest_cancelled_question(path):
    """(tool_use_id, age seconds) of the most recent AskUserQuestion that was rejected and not
    asked again since, or None."""
    return scan_cancelled(path)[0]


def state_scope(payload):
    """What the reported-ids record is kept under: the session id, else a hash of the transcript
    path, else None (nothing to key it by, so a repeat cannot be recognised)."""
    sid = payload.get("session_id")
    if isinstance(sid, str) and sid:
        return sid[:64]
    path = payload.get("transcript_path")
    if isinstance(path, str) and path:
        return "t-" + hashlib.sha256(path.encode("utf-8", "replace")).hexdigest()[:32]
    return None


def state_file(sid):
    name = sid if re.fullmatch(r"[A-Za-z0-9_-]{1,64}", sid) else "h-" + hashlib.sha256(sid.encode()).hexdigest()[:32]
    return state_dir() / "askuser-cancel" / (name + ".json")


def reported(sid, tool_use_id):
    try:
        data = json.loads(state_file(sid).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return isinstance(data, dict) and tool_use_id in (data.get("reported") or [])


def remember(sid, tool_use_id):
    path = state_file(sid)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    ids = [i for i in (data.get("reported") or []) if isinstance(i, str)][-19:] if isinstance(data, dict) else []
    ids.append(tool_use_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps({"reported": ids}), encoding="utf-8")
    os.replace(tmp, path)
    prune_state(path.parent)


def prune_state(root, now=None):
    now = time.time() if now is None else now
    marker = root / ".pruned"
    try:
        if now - marker.stat().st_mtime < 86400:
            return
    except OSError:
        pass
    try:
        for name in os.listdir(root):
            if name.endswith(".json") and now - (root / name).stat().st_mtime > STATE_TTL_S:
                os.unlink(root / name)
        marker.write_text("", encoding="utf-8")
    except OSError:
        pass


def lane_of(raw_payload):
    """bin/lane-class (beside this hook's directory), asked only when about to speak. Missing,
    slow or unrecognised means foreman, the contract's fallback."""
    path = Path(__file__).resolve().parent.parent / "bin" / "lane-class"
    if not (path.is_file() and os.access(path, os.X_OK)):
        return "foreman"
    try:
        proc = subprocess.Popen([str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                start_new_session=(os.name == "posix"))
    except OSError:
        return "foreman"
    try:
        out, _ = proc.communicate(raw_payload, timeout=LANE_CLASS_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        try:
            if os.name == "posix":
                os.killpg(proc.pid, 9)
            else:
                proc.kill()
        except OSError:
            pass
        proc.communicate()
        return "foreman"
    answer = out.decode("utf-8", "replace").strip()
    return answer if answer in LANES else "foreman"


def append_log(record):
    path = state_dir() / "askuser-cancel.jsonl"
    line = (json.dumps(record, separators=(",", ":"), ensure_ascii=True) + "\n").encode()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            if path.stat().st_size >= LOG_MAX_BYTES:
                os.replace(path, path.with_name(path.name + ".1"))
        except FileNotFoundError:
            pass
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NONBLOCK", 0), 0o600)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise OSError("not a regular log file")
            os.write(fd, line)
        finally:
            os.close(fd)
    except OSError:
        pass


def speak_once(raw, scope, record, tool_use_id, age, outcome):
    """The one gate every event goes through: a question older than FRESH_S or already reported
    in this session stays quiet, a lane stays quiet, and a report is remembered by tool_use id so
    the same rejected question is never reported again by another event. True means speak."""
    if age > FRESH_S or (scope and tool_use_id and reported(scope, tool_use_id)):
        return False
    if lane_of(raw) != "foreman":
        append_log(dict(record, outcome="pass_lane"))
        return False
    if scope and tool_use_id:
        try:
            remember(scope, tool_use_id)
        except OSError:
            # Without the record it would repeat on every prompt; say nothing instead.
            append_log(dict(record, outcome="pass_state_unwritable"))
            return False
    append_log(dict(record, outcome=outcome, age_s=int(age)))
    return True


def main():
    if os.environ.get("ASKUSER_CANCEL") == "0":
        return
    raw = sys.stdin.buffer.read()
    try:
        payload = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        return
    if not isinstance(payload, dict) or payload.get("agent_id"):
        return
    event = payload.get("hook_event_name") or "PostToolUse"
    sid = payload.get("session_id")
    sid = sid[:64] if isinstance(sid, str) and sid else None
    scope = state_scope(payload)
    record = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "epoch": int(time.time()), "session": sid, "event": event}
    path = payload.get("transcript_path")
    path = path if isinstance(path, str) and path and os.path.isfile(path) else None

    if event in TOOL_EVENTS:
        # The tool's own event: the rejection text is in the result or the error.
        if payload.get("tool_name") != "AskUserQuestion":
            return
        blob = " ".join(text_of(payload.get(k)) for k in ("tool_response", "tool_result", "error", "reason", "message"))
        if not REJECTION.search(blob):
            return
        tool_use_id = payload.get("tool_use_id")
        tool_use_id = tool_use_id if isinstance(tool_use_id, str) and tool_use_id else None
        age = scan_cancelled(path)[1].get(tool_use_id, 0.0) if path and tool_use_id else 0.0
        if speak_once(raw, scope, record, tool_use_id, age, "context"):
            sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": MESSAGE}}) + "\n")
        return

    if event not in ("UserPromptSubmit", "Stop"):
        return
    if event == "Stop" and payload.get("stop_hook_active"):
        return
    if path is None:
        return
    found = latest_cancelled_question(path)
    if not found:
        return
    tool_use_id, age = found
    if not speak_once(raw, scope, record, tool_use_id, age, "stop_block" if event == "Stop" else "context"):
        return
    if event == "Stop":
        out = {"decision": "block", "reason": MESSAGE}
    else:
        out = {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": MESSAGE}}
    sys.stdout.write(json.dumps(out) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 - advice only: a failure must not touch the session
        pass
