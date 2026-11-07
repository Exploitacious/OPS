#!/usr/bin/env python3
"""Stop hook helper: send a foreman's over-long ask back for one rewrite.

Run by report-lint.sh with the Stop payload on stdin. Prints at most one line,
{"decision": "block", "reason": "..."}, always exits 0, and appends one JSON line to
${OPS_STATE_DIR:-~/.local/state/ops}/report-lint.jsonl for each Stop that had a message
long enough to judge (counts and hashes, never message text).

Why it exists: an Operator kept getting asks they could not act on, a long numbered
decision list full of bare IDs, a many-row decision table, a message that left them
asking what was wanted of them. The reporting rules existed in prose and the failure
recurred after each one, so this checks the shape of the message at the one point that
fires on its own. It judges SHAPE only: how many things the message asks the Operator to
decide, whether a decision table is in it, and whether the asks lean on bare IDs. It never
looks at deferral language: an agent that says "I will do this later" is not policed here,
and no rule reads for it.

What blocks (any one of these, in the turn's FINAL assistant message when it is at least
400 characters; the block says which). Only the final message is judged, never earlier
narration in the turn; the line is more than three asks, not more than four; a ticket
number with its title beside it is fine.
  asks    more than REPORT_LINT_MAX_ASKS (default 3) things that ask the Operator to decide:
          list items under a "Decisions" or "Needs you" heading, bold-led lines there,
          option lines ("Option 2", "(b)"), and any other list item or line that carries
          a question mark or a recommendation. The parser counts a little high (a finding
          listed under a "Decisions for you" heading is still counted), which the line
          accepts: a false block costs one rewrite. Items under a "Decided", "Handling",
          "Done", "FYI" or similar heading are the one-line-each bucket the ask card allows
          and never count. A heading that tells the agent to ask someone else ("Ask every
          seller:", "Questions for the seller") is not a list of asks for the Operator.
  table   a markdown decision table: three or more rows under a header that has a
          Decision, Recommendation, Your call, Approve or Question column.
  ids     three or more distinct IDs that stand alone (a commit SHA, #123, a tracker ID
          such as ENG-1042, or a 1.2.3 version string) inside the asks themselves, with two
          or more asks. An ID stands alone when no name sits right beside it in its
          sentence (the two nearest words each side, skipping articles, prepositions, kind
          words like "ticket" or "PR" and bare verbs like "approve"): "Seat expansion
          (ENG-1042)" is named, "Approve #1452 and 9b799c0?" is not. A status paragraph
          full of PR numbers is not an ask and is left alone.

The tracker-ID pattern is two to eight capital letters, a dash and two to six digits
(ENG-1042). A team whose tickets look different sets REPORT_LINT_TICKET_RE to its own
regular expression; an invalid one is ignored.

What never blocks: a message under 400 characters; a stop that is already the rewrite
(stop_hook_active); a lane (agent_id, or bin/lane-class saying t3-lane or agent-lane; a lane's
Stop is its brief's business); the same message twice (its hash is kept for 7 days per session,
or per transcript when the payload carries no session_id); anything the helper cannot read.
All failures exit 0 silently: this is advice, not a gate.
"""
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time
from pathlib import Path

MIN_CHARS = 400
STATE_TTL_S = 7 * 86400
LOG_MAX_BYTES = 256 * 1024
TAIL_BYTES = 4 * 1024 * 1024
TAIL_MAX_BYTES = 64 * 1024 * 1024
LANES = ("foreman", "t3-lane", "agent-lane")
LANE_CLASS_TIMEOUT_S = 0.4

FENCE = re.compile(r"```.*?(?:```|\Z)", re.S)
# Links and URLs carry question marks and hex runs that are not asks or IDs.
URL = re.compile(r"https?://\S+|t3-thread://\S+|\]\([^)]*\)")
ITEM = re.compile(r"^(?P<ind>\s{0,3})(?:(?P<num>\d{1,3})[.)]|[-*•])\s+(?P<body>\S.*)$")
BOLD_LEAD = re.compile(r"^\s{0,3}\*\*[^*\n]{2,80}\*\*[:.]?\s+\S")
HEADING = re.compile(r"^\s{0,3}(?:#{1,6}\s+(?P<h>.+?)|\*\*(?P<b>[^*\n]{2,90}?)\*\*:?|(?P<c>[A-Z][^\n]{2,70}?):)\s*$")
# A heading that says the section is for the Operator to answer. Anchored at the start of the
# label on purpose: "Decisions for you" and "Needs you (none of this blocks)" are asks, while
# "All of your decisions are now in motion" and "Decisions I made (veto any)" only mention the word.
ASK_HEADING = re.compile(
    r"\W*(?:(?:still|open|new things|new|things|anything|only)\s+)?"
    r"(decisions?\s+(?:for|from|i need|needed|waiting|that need)|decisions?\s*$|questions?\b|asks?\b"
    r"|approvals?\b|needs?\s+(?:you|your|a\s+(?:call|decision))|need\s+from\s+you|waiting\s+on\s+you"
    r"|(?:for|from)\s+you\b|your\s+(?:call|decisions?|answers?|approvals?|pick|go)\b|what\s+i\s+need"
    r"|calls?\s+for\s+you|open\s+items|for\s+your\s+decision)", re.I)
# A heading that tells the agent to put questions to someone else is not a list of asks for the
# Operator: "Ask every seller:" (an imperative), "Questions for the seller", "Questions to ask the
# dealer". "Asks for you", "Ask card" and "Questions for you" stay asks.
IMPERATIVE_ASK = re.compile(r"\W*ask\s+(?!for\s+(?:you|the\s+operator)\b|from\s+(?:you|the\s+operator)\b|card\b)\w", re.I)
THIRD_PARTY_TAIL = re.compile(r"\s*(?:for|to|about|of|from)\s+(?!you\b|your\b|the\s+operator\b|me\b)\w", re.I)
# A heading that says the section is the bucket: things the Operator does not have to answer.
BUCKET_LEAD = re.compile(
    r"\W*(done|decided|i decided|handled|handling|i.m handling|no action|fyi|completed|already|nothing)", re.I)
BUCKET_HEADING = re.compile(
    r"\b(decided|handling|handled|done|completed|no action|fyi|for information|nothing needed|no decision"
    r"|already|shipped|landed|closed|status|summary|what changed|checked|results?|findings?|verified"
    r"|rulings? recorded|recorded|i made|i decided|we decided|i took|in motion|are now|since)\b", re.I)
# Lead-ins of the lines that belong to an ask, not asks of their own.
SUB_LABEL = re.compile(
    r"^\*{0,2}(recommendation|recommend|risk|note|default|why|impact|cost|effort|if you say nothing|my read|what it)\b", re.I)
OPTION = re.compile(r"^\W*(?:option\s+(?:\d+|[A-Za-z])\b|\(?[a-d]\)\s)", re.I)
ASK_MARK = re.compile(
    r"\?|\b(approve|your call|should (?:i|we)|do you want|want me to|your pick|yes or no|yes/no"
    r"|recommend(?:ation|ed)?|veto|ok to|okay to|decide)\b", re.I)
TABLE_ROW = re.compile(r"^\s*\|.*\|\s*$")
TABLE_SEP = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)+\|?\s*$")
DECISION_COLUMN = re.compile(
    r"\b(decisions?|recommendations?|recommended|your call|your answer|approve|approval|asks?|questions?)\b", re.I)

SHA = re.compile(r"(?<![\w/#.-])(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}(?![\w-])")
PR_REF = re.compile(r"(?<![\w&])#\d{1,6}\b")
DEFAULT_TICKET = re.compile(r"\b[A-Z]{2,8}-\d{2,6}\b")
VERSION = re.compile(r"(?<![\w.])v?\d{1,3}\.\d{1,3}\.\d{1,3}(?:[-+][\w.]*\w)?(?![\w]|\.\d)")


DEFAULT_MAX_ASKS = 3  # more than three decision items goes back


def state_dir():
    return Path(os.environ.get("OPS_STATE_DIR") or Path.home() / ".local/state/ops")


def max_asks():
    try:
        value = int(os.environ.get("REPORT_LINT_MAX_ASKS", ""))
    except ValueError:
        return DEFAULT_MAX_ASKS
    return value if value >= 1 else DEFAULT_MAX_ASKS


def ticket_pattern():
    """REPORT_LINT_TICKET_RE when set and valid, else the default tracker-ID pattern."""
    custom = os.environ.get("REPORT_LINT_TICKET_RE", "")
    if custom:
        try:
            return re.compile(custom)
        except re.error:
            pass
    return DEFAULT_TICKET


# ---------------------------------------------------------------- the message


def clean(text):
    return URL.sub(" ", FENCE.sub(" ", text))


def ask_heading_kind(label):
    """"ask" when a heading says its list is for the Operator to answer, "third" when it tells the
    agent to put questions to someone else ("Ask every seller:"; its list is not the Operator's to
    decide, question marks and all), None when it is neither."""
    match = ASK_HEADING.match(label)
    if not match:
        return None
    if IMPERATIVE_ASK.match(label):
        return "third"
    if re.match(r"(?:asks?|questions?)\b", match.group(1), re.I) and THIRD_PARTY_TAIL.match(label, match.end()):
        return "third"
    return "ask"


# Words that sit beside an ID without naming it: articles, prepositions, conjunctions, auxiliaries,
# the kind words ("ticket", "PR", "commit") and the bare verbs an ask puts in front of a reference
# ("approve #1452"). Anything else of three letters or more, next to an ID, is a name or a description.
FILLER = frozenset("""
a an the and or but nor of in on at to for from with without by per via as into onto over under after before
until since about vs versus than then so if when while also too only just now today yet still both all each
every one two three another other this that these those i we you he she it its they them our your my me us
is are was were be been being am do does did done has have had will would should could can may might must shall
pr prs pull request requests ticket tickets commit commits sha issue issues version versions release releases
build builds id ids number numbers ref refs
approve approved merge merged close closed open opened ship shipped flip run check see review reviewed fix
fixed bump bumped deploy deployed land landed reopen cancel drop delete need needs want wants recommend
recommended yes yeah okay not please
move rotate publish enable disable start stop restart retire remove update upgrade apply send post file log
create add pause resume accept reject decline test try use pick take keep hold wait
""".split())
WORD = re.compile(r"[A-Za-z][A-Za-z']*")
NAME_WINDOW = 2  # naming words looked at on each side of an ID


def id_spans(text):
    """(start, end) of every ID in the text, overlapping matches merged."""
    patterns = (SHA, PR_REF, ticket_pattern(), VERSION)
    spans = sorted(m.span() for rx in patterns for m in rx.finditer(text))
    merged = []
    for start, end in spans:
        if start == end:
            continue  # a custom pattern that matches the empty string names nothing
        if merged and start < merged[-1][1]:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start, end))
    return merged


def names_beside(chunk, left_side):
    """True when the words next to an ID, within its sentence, include a name or description.
    chunk is the text between the ID and its neighbour (the previous or next ID, or the item's end);
    left_side says the ID follows it, so the nearest words are the last ones."""
    segment = re.split(r"[.?!;\n]", chunk)[-1 if left_side else 0]
    words = WORD.findall(segment)
    near = words[-NAME_WINDOW:] if left_side else words[:NAME_WINDOW]
    return any(len(w) >= 3 and w.lower() not in FILLER for w in near)


def bare_ids(asks):
    """Distinct IDs, across the ask items, that stand alone: no name or description right beside
    them. An ID named in one place and bare in another counts as named, so each is listed once."""
    named, bare = set(), []
    for parts in asks:
        text = "\n".join(parts)  # a newline ends a sentence, so a name never bleeds in from the next line
        spans = id_spans(text)
        for i, (start, end) in enumerate(spans):
            token = text[start:end]
            left_from = spans[i - 1][1] if i else 0
            right_to = spans[i + 1][0] if i + 1 < len(spans) else len(text)
            if names_beside(text[left_from:start], left_side=True) or names_beside(text[end:right_to], left_side=False):
                named.add(token)
            elif token not in bare:
                bare.append(token)
    return [token for token in bare if token not in named]


def analyze(text):
    """What the message asks of the reader: ask items (with the lines that belong to each),
    decision tables, and the IDs inside the asks that stand alone."""
    lines = clean(text).split("\n")
    kind = None
    asks, pending = [], None
    for line in lines:
        if not line.strip():
            continue
        heading = HEADING.match(line)
        item = ITEM.match(line)
        if heading and not item:
            label = heading.group("h") or heading.group("b") or heading.group("c") or ""
            heading_kind = ask_heading_kind(label)
            if BUCKET_LEAD.match(label) or BUCKET_HEADING.search(label) or heading_kind == "third":
                kind = "bucket"  # nothing under it is the Operator's to decide
            elif heading_kind == "ask":
                kind = "ask"
            else:
                kind = None
            pending = None
            continue
        if item:
            nested = len(item.group("ind")) >= 2 and not item.group("num")
            body = item.group("body")
            if nested:
                # A nested line belongs to the ask above it (its recommendation, its risk).
                if pending is not None:
                    pending.append(body)
                continue
            pending = None
            if SUB_LABEL.match(body) or kind == "bucket":
                continue
            if kind == "ask" or OPTION.match(body) or ASK_MARK.search(body):
                pending = [body]
                asks.append(pending)
            continue
        if kind == "ask" and BOLD_LEAD.match(line):
            pending = [line.strip()]
            asks.append(pending)
            continue
        stripped = line.strip()
        pending = None
        if stripped.endswith("?") and len(stripped) > 25 and kind != "bucket":
            asks.append([stripped])
    tables = decision_tables(lines)
    return {"asks": len(asks), "tables": tables, "ids": bare_ids(asks)}


def decision_tables(lines):
    """Row counts of markdown tables that have a decision-type column and at least three rows."""
    found, i = [], 0
    while i < len(lines) - 1:
        if TABLE_ROW.match(lines[i]) and TABLE_SEP.match(lines[i + 1]):
            j = i + 2
            while j < len(lines) and TABLE_ROW.match(lines[j]):
                j += 1
            cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
            rows = j - i - 2
            if rows >= 3 and any(DECISION_COLUMN.search(c) for c in cells):
                found.append(rows)
            i = j
        else:
            i += 1
    return found


def judge(text):
    """(kind, detail) when the message should go back, else None. kind is table, asks or ids."""
    a = analyze(text)
    if a["tables"]:
        return "table", {"rows": max(a["tables"]), "asks": a["asks"], "ids": len(a["ids"])}
    if a["asks"] > max_asks():
        return "asks", {"asks": a["asks"], "ids": len(a["ids"])}
    if a["asks"] >= 2 and len(a["ids"]) >= 3:
        return "ids", {"asks": a["asks"], "ids": len(a["ids"]), "examples": a["ids"][:4]}
    return None


def reason_for(kind, detail):
    """The block reason: short, names what tripped, and says how to fix it. Nothing here
    mentions deferral, and it never repeats message text beyond a few of the IDs."""
    if kind == "table":
        what = "it has a %d-row decision table" % detail["rows"]
    elif kind == "asks":
        what = "it asks the Operator for at least %d decisions" % detail["asks"]
    else:
        what = "its asks name things only by number (%s)" % ", ".join(detail["examples"])
    return (
        "Report shape check: %s. Post it again once as a short ask card, with no new work: at most three asks "
        "(a plain line each of what it is and why it matters, your recommendation, and what happens if the "
        "Operator says nothing); everything else as one-line 'Decided' or \"I'm handling\" items; say what each PR, "
        "ticket, commit or version is in words (a number may sit beside its name, never alone); no decision "
        "tables. If the Operator asked for everything, the bucket carries it." % what
    )


# ---------------------------------------------------------------- the transcript


def read_tail(path, size):
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        end = fh.tell()
        start = max(0, end - size)
        fh.seek(start)
        data = fh.read(end - start)
    return data, start == 0


def record_text(content):
    """Text blocks of one assistant record, in order."""
    if isinstance(content, str):
        return [content]
    out = []
    for block in content if isinstance(content, list) else []:
        if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
            out.append(block["text"])
    return out


def is_real_prompt(record):
    """A user record that starts a turn: text from a person or the harness, not a tool result."""
    if record.get("type") != "user" or record.get("isSidechain") or record.get("isMeta"):
        return False
    content = (record.get("message") or {}).get("content")
    if isinstance(content, str):
        return bool(content.strip())
    if isinstance(content, list):
        return any(isinstance(b, dict) and b.get("type") == "text" and (b.get("text") or "").strip() for b in content)
    return False


def turn_messages(path):
    """Every assistant text block since the last real prompt, oldest first. The tail of the
    transcript is read first and widened only when the prompt that opened the turn is not in it."""
    size = TAIL_BYTES
    while True:
        data, whole = read_tail(path, size)
        lines = data.split(b"\n")
        if not whole:
            lines = lines[1:]  # the first line is probably cut in half
        messages, found = [], False
        for raw in reversed(lines):
            if not raw.strip():
                continue
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(record, dict):
                continue
            if record.get("type") == "assistant" and not record.get("isSidechain"):
                messages = record_text((record.get("message") or {}).get("content")) + messages
            elif is_real_prompt(record):
                found = True
                break
        if found or whole or size >= TAIL_MAX_BYTES:
            return messages
        size *= 4


def final_message(payload):
    """The text of the turn's final assistant message, or None. The Stop payload's own
    last_assistant_message wins when it is there (the transcript can lag the hook by a write);
    otherwise the last text block of the turn in the transcript. Earlier narration in the turn is
    never judged: only the message the Operator reads last counts."""
    last = payload.get("last_assistant_message")
    if isinstance(last, str) and last.strip():
        return last
    path = payload.get("transcript_path")
    if isinstance(path, str) and path and os.path.isfile(path):
        try:
            messages = [m for m in turn_messages(path) if m.strip()]
        except OSError:
            return None
        if messages:
            return messages[-1]
    return None


# ---------------------------------------------------------------- state, lane, log


def state_scope(payload):
    """What the once-per-message record is kept under: the session id, else a hash of the
    transcript path (so a payload without a session id still blocks a message once), else one
    shared bucket. The block key itself is the message hash."""
    sid = payload.get("session_id")
    if isinstance(sid, str) and sid:
        return sid[:64]
    path = payload.get("transcript_path")
    if isinstance(path, str) and path:
        return "t-" + hashlib.sha256(path.encode("utf-8", "replace")).hexdigest()[:32]
    return "no-session"


def session_state_file(sid):
    name = sid if re.fullmatch(r"[A-Za-z0-9_-]{1,64}", sid) else "h-" + hashlib.sha256(sid.encode()).hexdigest()[:32]
    return state_dir() / "report-lint" / (name + ".json")


def blocked_before(sid, key):
    try:
        data = json.loads(session_state_file(sid).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return isinstance(data, dict) and key in (data.get("blocked") or [])


def remember_block(sid, key):
    path = session_state_file(sid)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    blocked = [k for k in (data.get("blocked") or []) if isinstance(k, str)][-19:] if isinstance(data, dict) else []
    blocked.append(key)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps({"blocked": blocked}), encoding="utf-8")
    os.replace(tmp, path)
    prune_state(path.parent)


def prune_state(root, now=None):
    """Delete state files untouched for 7 days, at most once a day."""
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


def lane_class_path():
    """bin/lane-class beside this hook's directory (.claude-config/hooks -> .claude-config/bin),
    or None when it is absent or not runnable (a box that has not received it yet)."""
    path = Path(__file__).resolve().parent.parent / "bin" / "lane-class"
    return path if path.is_file() and os.access(path, os.X_OK) else None


def lane_of(raw_payload):
    """The session's lane class from bin/lane-class, which takes the hook payload on stdin.
    Missing, slow or unrecognised means foreman, the contract's fallback. Asked only when a
    message is about to be sent back, so ordinary stops never pay for it."""
    path = lane_class_path()
    if path is None:
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
    path = state_dir() / "report-lint.jsonl"
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
        pass  # advice hook: a lost log line costs nothing


# ---------------------------------------------------------------- run


def main():
    if os.environ.get("REPORT_LINT") == "0":
        return
    raw = sys.stdin.buffer.read()
    try:
        payload = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        return
    if not isinstance(payload, dict) or payload.get("stop_hook_active") or payload.get("agent_id"):
        return
    event = payload.get("hook_event_name")
    if event not in (None, "Stop"):
        return
    sid = payload.get("session_id")
    sid = sid[:64] if isinstance(sid, str) and sid else None
    scope = state_scope(payload)
    text = final_message(payload)
    if text is None or len(text) < MIN_CHARS:
        return
    record = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "epoch": int(time.time()), "session": sid,
              "chars": len(text), "outcome": "pass"}
    verdict = judge(text)
    if verdict is None:
        append_log(record)
        return
    kind, detail = verdict
    key = hashlib.sha256(text.strip().encode("utf-8", "replace")).hexdigest()[:32]
    record.update(detail=detail, trigger=kind, key=key)
    if blocked_before(scope, key):
        append_log(dict(record, outcome="pass_already_blocked"))
        return
    lane = lane_of(raw)
    if lane != "foreman":
        append_log(dict(record, outcome="pass_lane", lane=lane))
        return
    try:
        remember_block(scope, key)
    except OSError:
        # Without the record a second stop could block the same message again;
        # stop_hook_active still covers the immediate one, so say nothing and let it pass.
        append_log(dict(record, outcome="pass_state_unwritable"))
        return
    append_log(dict(record, outcome="blocked"))
    sys.stdout.write(json.dumps({"decision": "block", "reason": reason_for(kind, detail)}) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except Exception:  # noqa: BLE001 - a lint must never break a stop
        pass
