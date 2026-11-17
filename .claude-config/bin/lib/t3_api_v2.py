"""t3_api_v2.py: the body-reading half of t3-api.sh for T3 Code 0.1.0 (orchestration protocol 2).

t3-api.sh owns the CLI, the bearer token and the HTTP transport (curl with a 0600 -K
config, so the token never reaches argv); lib/t3_ws.py owns the WebSocket write transport.
This module owns everything that has to understand a response body or the V2 state
database, and builds the write commands. It never opens a network connection and never
writes anything; every database open is mode=ro with PRAGMA query_only=1. Run it as
`python3 -I t3_api_v2.py <op> ...`:

  check-json <file> <content-type> <label>    exit 6 unless the body is a JSON object and the
                                              content type is not HTML (the fail-loud rule)
  protocol <environment.json>                 print 1 or 2 (exit 6 bad answer, 8 unsupported)
  quote <thread-id>                           percent-encode for a route path, quote(id, safe='')
  v1-shell <shell.json> <shell|snapshot>      V1-shaped shell or snapshot built from the V2 shell
  v1-thread <bounded.json> <shell.json> <id>  V1-shaped thread detail from /bounded plus the shell
  active-turn <shell.json> <id>               the V1 activeTurnId, or "null" (exit 5 if absent)
  thread-for-session <statev2.sqlite> <sid>   Claude session id -> T3 thread id (exit 5 if none)
  verdict <shell.json> <id> <settle|archive> [<bounded.json>]
                                              "<verdict>|<reasons>|<stamp>", verdict idle, busy,
                                              settled, missing, or unconfirmed (idle by the shell,
                                              /bounded not read yet): thread_verdict
  text-guard <text-file>                      exit 10 unless the text may be sent (text_guard)
  target-check <bounded.json> <id>            exit 10 if the thread is archived or deleted
  stop-target <shell.json> <id>               "<run id or empty>|<why>" (exit 5 if absent)
  compact-status <bounded.json> <id> <mid>    pending | completed | failed | nothing-to-compact
  operator-check <bounded.json> <id> <stamp>  "operator|..." | "harness|..." | "unseen|...":
                                              who wrote the user messages after <stamp>
  command <kind> <id> [arg] [--attempt N]     print one dispatchCommand payload (build_command)
  server-busy <shell.json> <bounded-dir>      the server-wide verdict as JSON (server_busy)
  server-busy-plan <shell.json>               the thread ids whose /bounded server-busy needs

Exit codes match t3-api.sh: 0 ok, 2 usage, 4 local read error, 5 not found, 6 bad answer
(not JSON, HTML, or not the shape this client expects), 8 unsupported protocol, 10 refused
by a guard (archived or deleted thread, a text that may not be sent).

WHY V1-SHAPED OUTPUT: compact-cycle.sh, the settle verdict and other callers written for
protocol 1 read V1 keys (session, latestTurn, backgroundLiveness, hasPendingApprovals,
hasPendingUserInput) that V2 threads no longer carry. Translating here, in one place, keeps
every caller working while each is ported on its own. Every V2
key is passed through untouched, so a V2-aware reader loses nothing; the derived V1 keys
are added beside them. The mapping table, with the reason for each row, is in the
t3-api.sh header under V1-SHAPE MAPPING; the code below is the authority.

The pure functions (idle_verdict, v1_thread, v1_shell, v1_thread_detail,
pick_session_thread) take every input as an argument, the clock included, so the
suite pins them with a fixed `now`. Every optional V2 field is read with .get():
historyOrigin, branchPullRequest and activeOrderKey, among others, are absent on many
threads (checked against a live 0.1.0 server).

Frame ids in parentheses (a13, b27 and so on) name exchanges recorded by a write-path probe
against a scratch T3 0.1.0 server; tests/fixtures/t3-v2/ws/ holds the ones the suites replay.
"""
import datetime
import hashlib
import json
import os
import re
import sqlite3
import sys
import urllib.parse

EXIT_USAGE = 2
EXIT_UNREADABLE = 4
EXIT_NOT_FOUND = 5
EXIT_BAD_ANSWER = 6
EXIT_UNSUPPORTED = 8
EXIT_GUARD = 10

# Run statuses (T3 0.1.0 RunStatus literals). status on a shell thread is the latest
# unheld run's status, or 'idle' only when the thread has no runs, so 'completed' is
# the normal resting state, not a sign of activity.
STARTING_RUN_STATUSES = ("preparing", "queued", "starting")
ACTIVE_RUN_STATUSES = STARTING_RUN_STATUSES + ("running", "waiting")
TERMINAL_RUN_STATUSES = ("completed", "failed", "interrupted", "cancelled", "rolled_back")
KNOWN_STATUSES = ("idle",) + ACTIVE_RUN_STATUSES + TERMINAL_RUN_STATUSES
# Run statuses for a thread missing from the shell, derived from /bounded runs[] the way
# the server derives the shell: activeRunId covers interruptible runs, activityRunStatus
# adds waiting.
INTERRUPTIBLE_RUN_STATUSES = ("preparing", "starting", "running")
ACTIVITY_RUN_STATUSES = ("preparing", "starting", "running", "waiting")
KNOWN_RUN_STATUSES = ACTIVE_RUN_STATUSES + TERMINAL_RUN_STATUSES
# Runtime request statuses (T3 0.1.0 literal set: pending, resolved, expired, cancelled).
# Anything but the three final ones counts as pending: an unknown status must read busy.
FINAL_REQUEST_STATUSES = ("resolved", "expired", "cancelled")

# The server's own queued-start window (threadHasQueuedTurnStart, 120000 ms): a user
# message this young that no run has adopted yet is about to start a run.
UNADOPTED_MESSAGE_WINDOW_S = 120

# V1 turn states for terminal V2 run statuses. 'failed' is V1 'error' because a caller
# that resumes a thread after a usage limit keys on exactly that; cancelled and rolled_back
# never ran to completion, so they read as interrupted, never as an error to resume.
TURN_STATE_FOR_STATUS = {
    "completed": "completed",
    "failed": "error",
    "interrupted": "interrupted",
    "cancelled": "interrupted",
    "rolled_back": "interrupted",
}
SESSION_STATUS_FOR_STATUS = {
    "idle": "idle",
    "completed": "ready",
    "rolled_back": "ready",
    "failed": "error",
    "interrupted": "interrupted",
    "cancelled": "interrupted",
}
# Stands in for an active run whose id the shell did not give (activityRunStatus set but no
# activeRunId or latestRunId). Callers only test activeTurnId for null; this keeps the
# thread busy instead of reading idle.
UNIDENTIFIED_RUN = "unidentified-active-run"

# Claude session id -> thread id. Checked against a live 0.1.0 schema:
# orchestration_v2_projection_provider_threads(provider_thread_id PK, thread_id,
# owner_node_id, ..., payload_json) and orchestration_v2_projection_threads(thread_id PK,
# active_provider_thread_id, ...). payload_json $.nativeThreadRef.nativeId is the Claude
# session id; owner_node_id IS NULL selects the thread's own provider thread, not a
# subagent's. The plan uses the owner index and the threads primary key, so the query
# stays bounded; one extra row detects truncation before choosing a thread.
SESSION_ROW_LIMIT = 50
SESSION_SQL = (
    "SELECT pt.thread_id, pt.provider_thread_id, t.active_provider_thread_id "
    "FROM orchestration_v2_projection_provider_threads AS pt "
    "LEFT JOIN orchestration_v2_projection_threads AS t ON t.thread_id = pt.thread_id "
    "WHERE pt.owner_node_id IS NULL "
    "AND json_extract(pt.payload_json, '$.nativeThreadRef.nativeId') = ? "
    f"LIMIT {SESSION_ROW_LIMIT + 1}"
)


class ShapeError(Exception):
    """The answer is JSON but not the shape this client expects (exit 6)."""


class UnsupportedProtocol(Exception):
    """The server reports an orchestration protocol this client does not speak (exit 8)."""


class NotFound(Exception):
    """The thread is not in the answer (exit 5)."""


# ---- fail loud --------------------------------------------------------------------------

def check_json_body(raw, content_type, label):
    """Return the parsed JSON object, or raise ShapeError with a one-line reason.

    WHY: on T3 0.1.0 a route that no longer exists (/api/orchestration/snapshot, /dispatch)
    answers 200 with the web app's HTML. `snapshot` used to exit 0 on that page, and
    its callers (compact-cycle among them) trusted the exit code. A status code alone
    can never prove an answer, so the body must parse and the content
    type must not be HTML.
    """
    ct = (content_type or "").split(";", 1)[0].strip().lower()
    if "html" in ct:
        raise ShapeError(
            f"{label} answered {ct}, not JSON (T3 0.1.0 serves its web app's HTML for a route it does "
            "not have); refusing to treat it as data")
    try:
        text = raw.decode("utf-8")
        obj = json.loads(text)
    except (UnicodeDecodeError, ValueError):
        raise ShapeError(f"{label} answered a body that is not JSON ({len(raw)} bytes, content type {ct or 'none'}); refusing") from None
    if not isinstance(obj, dict):
        raise ShapeError(f"{label} answered JSON that is not an object ({type(obj).__name__}); refusing")
    return obj


def protocol_version(env):
    """1 or 2 from the /.well-known/t3/environment answer.

    T3 0.0.45 declares orchestrationProtocolVersion as an optional key with value 1, so an
    absent key is V1. Anything other than the integers 1 and 2 (a bool, a string, 3, null)
    is refused: guessing a protocol would send V1 requests to a V2 server or the reverse.
    """
    if not isinstance(env, dict):
        raise ShapeError("the environment answer is not a JSON object")
    if "orchestrationProtocolVersion" not in env:
        return 1
    v = env["orchestrationProtocolVersion"]
    if type(v) is int and v in (1, 2):
        return v
    raise UnsupportedProtocol(v)


# ---- time ---------------------------------------------------------------------------------

def parse_ts(value):
    """(ok, aware datetime or None). None and '' are ok-and-absent; anything else that does
    not parse to a timezone-aware time is not ok (callers treat that as busy)."""
    if value is None or value == "":
        return True, None
    if not isinstance(value, str):
        return False, None
    try:
        dt = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False, None
    if dt.tzinfo is None:
        return False, None
    return True, dt


def _unadopted_message_reason(thread, now):
    """A reason string when a user message under 120 s old has no run yet, else None.

    Both user-message stamps count (latestUserMessageAt includes server-created user
    messages, latestUserAuthoredMessageAt only authored ones; they differ on many
    threads), and the newer one is used, which is the busier reading. A run requested at
    or after that message adopted it.
    """
    latest, bad = None, []
    for key in ("latestUserMessageAt", "latestUserAuthoredMessageAt"):
        ok, dt = parse_ts(thread.get(key))
        if not ok:
            bad.append(key)
        elif dt is not None and (latest is None or dt > latest):
            latest = dt
    if bad:
        return "unreadable {} (treated as busy)".format(", ".join(bad))
    if latest is None:
        return None
    age = (now - latest).total_seconds()
    if age >= UNADOPTED_MESSAGE_WINDOW_S:
        return None
    ok, requested = parse_ts(thread.get("latestRunRequestedAt"))
    if not ok:
        return "unreadable latestRunRequestedAt (treated as busy)"
    if requested is not None and requested >= latest:
        return None
    return f"a user message from {max(0, int(age))}s ago has no run yet"


# ---- the idle verdict -------------------------------------------------------------------------

def projection_busy_reasons(projection, shell_saw_activity=False):
    """Busy reasons a /bounded projection shows and the shell cannot. Pure.

    WHY: after a run fails, or after a stop with holdQueue true, the runs
    queued behind it stay 'queued' and do not start; the shell entry then reports the
    terminal run (status failed or interrupted, activityRunStatus null) and has no queue
    field, so a shell-only verdict reads such a thread as idle. thread.settle refuses it
    (safe), but thread.archive has NO server guard and cancels the queued runs (probe b16,
    b17), and a wake queued there never fires. So:
      * any run with status 'queued' is busy (held or simply waiting its turn);
      * a run in an active status is busy (named only when the shell missed it);
      * a run whose status this client does not know, or a runs list that is missing, is
        busy (a schema change must not read as idle);
      * a runtime request that is not resolved, expired or cancelled is busy. One can stay
        pending after its run was interrupted (probe b23, b24): stale, but answering or
        cancelling it is a decision for a person, so it reads busy (the safe direction).
    """
    if not isinstance(projection, dict):
        return ["the thread projection is unreadable (treated as busy)"]
    runs = projection.get("runs")
    if not isinstance(runs, list):
        return ["the thread projection has no runs list (treated as busy)"]
    reasons = []
    queued, active, unknown = [], [], 0
    for r in runs:
        status = r.get("status") if isinstance(r, dict) else None
        if status == "queued":
            queued.append(r)
        elif status in ACTIVE_RUN_STATUSES:
            active.append(status)
        elif status not in TERMINAL_RUN_STATUSES:
            unknown += 1
    if queued:
        ids = ", ".join(str(r.get("id")) for r in queued[:3])
        reasons.append(f"{len(queued)} queued run{'' if len(queued) == 1 else 's'} in the projection "
                       f"(a queue held behind a failed or stopped run is invisible in the shell; an archive would cancel it): {ids}")
    if active and not shell_saw_activity:
        reasons.append(f"the projection shows a run {active[0]}")
    if unknown:
        reasons.append(f"{unknown} run{'' if unknown == 1 else 's'} with a status this client does not know (treated as busy)")
    requests = projection.get("runtimeRequests")
    if not isinstance(requests, list):
        reasons.append("the projection's runtimeRequests is not a list (treated as busy)")
    else:
        pending = [q for q in requests
                   if not isinstance(q, dict) or q.get("status") not in FINAL_REQUEST_STATUSES]
        if pending:
            reasons.append(f"{len(pending)} runtime request{'' if len(pending) == 1 else 's'} pending in the projection "
                           "(one can stay pending after its run was interrupted; answer or cancel it first)")
    return reasons


def idle_verdict(thread, now, children=(), projection=None):
    """Reasons a V2 shell thread is busy; an empty list means idle. Pure.

    Busy if ANY of:
      * activityRunStatus is non-null (a run is preparing, starting, running or waiting);
      * status is preparing, queued, starting, running or waiting, or not a status this
        client knows (a schema change must not read as idle);
      * activeRunId is set;
      * pendingRuntimeRequest is non-null (an approval, a question, an auth refresh; also
        a stale one left behind by an interrupt, the safe direction);
      * pendingBackgroundTasks is non-empty, of any kind, or missing or not a list;
      * a user message under 120 s old that no run has adopted (or an unreadable stamp);
      * a subagent child thread of this thread is busy by this same rule;
      * projection (the thread's /bounded projection, when the caller read it) shows a
        queued run, an active run, an unknown run status or a pending runtime request
        (projection_busy_reasons). The write path (settle, archive, the settle waiter,
        server-busy) always passes it; the read-only translation (shell, snapshot) does not,
        and its serverIdleVerdict says so.
    'completed' (or any terminal status) with tasks is V1's ready plus backgroundLiveness:
    busy. A settle or archive detaches the provider session, which ends background
    subagents, commands and monitors, and the server checks none of them, so this guard is
    deliberately stricter than the server.

    PR-watch case: a thread with a watched linked PR carries a kind 'monitor' task for as
    long as the watch lasts, so it reads busy for settle the whole time. That is the safe
    direction (a settle would end the watch); the reason says so, so an operator knows to
    unwatch the PR or settle in the T3 UI.
    """
    reasons = []
    ars = thread.get("activityRunStatus")
    status = thread.get("status")
    if ars is not None:
        reasons.append(f"a run is {ars}")
    if status in ACTIVE_RUN_STATUSES:
        if status != ars:
            reasons.append(f"the latest run is {status}")
    elif status not in KNOWN_STATUSES:
        reasons.append(f"thread status {status!r} is not one this client knows (treated as busy)")
    if thread.get("activeRunId") and ars is None and status not in ACTIVE_RUN_STATUSES:
        reasons.append("a run is active")
    prr = thread.get("pendingRuntimeRequest")
    if prr is not None:
        kind = prr.get("kind") if isinstance(prr, dict) else None
        if kind == "user_input":
            reasons.append("a question is waiting for an answer")
        else:
            reasons.append("a request is waiting for approval (%s)" % (kind or "unknown kind"))
    tasks = thread.get("pendingBackgroundTasks")
    if not isinstance(tasks, list):
        reasons.append("background work is unknown (pendingBackgroundTasks is missing or not a list)")
    elif tasks:
        kinds = [((t.get("kind") if isinstance(t, dict) else None) or "unknown") for t in tasks]
        if all(k == "monitor" for k in kinds):
            reasons.append(
                f"a pull-request watch is active ({len(kinds)} monitor task{'' if len(kinds) == 1 else 's'}): busy for settle, "
                "which would end the watch; unwatch the PR or settle in the T3 UI")
        else:
            reasons.append(f"background work is pending ({len(kinds)} task{'' if len(kinds) == 1 else 's'}: {', '.join(sorted(set(kinds)))})")
    msg = _unadopted_message_reason(thread, now)
    if msg:
        reasons.append(msg)
    for child in children:
        child_reasons = idle_verdict(child, now)
        if child_reasons:
            reasons.append("subagent thread {} is busy ({})".format(child.get("id"), child_reasons[0]))
    if projection is not None:
        saw = ars is not None or status in ACTIVE_RUN_STATUSES or bool(thread.get("activeRunId"))
        reasons.extend(projection_busy_reasons(projection, saw))
    return reasons


# ---- V1-shape translation -------------------------------------------------------------------

def is_subagent(thread):
    lineage = thread.get("lineage")
    return isinstance(lineage, dict) and lineage.get("relationshipToParent") == "subagent"


def children_index(subagents):
    """parent or root thread id -> {child id: child}. A nested child counts toward its
    parent and its root, so a busy grandchild keeps the root busy too."""
    index = {}
    for child in subagents:
        lineage = child.get("lineage") if isinstance(child.get("lineage"), dict) else {}
        for key in ("parentThreadId", "rootThreadId"):
            parent = lineage.get(key)
            if isinstance(parent, str) and parent and parent != child["id"]:
                index.setdefault(parent, {})[child["id"]] = child
    return index


def session_status(thread, now):
    ars = thread.get("activityRunStatus")
    status = thread.get("status")
    if ars in STARTING_RUN_STATUSES or status in STARTING_RUN_STATUSES:
        return "starting"
    if ars is not None or status in ("running", "waiting") or thread.get("activeRunId"):
        return "running"
    if status in SESSION_STATUS_FOR_STATUS:
        # A fresh user message with no run yet is V1's queued turn start: starting.
        if _unadopted_message_reason(thread, now) is not None:
            return "starting"
        return SESSION_STATUS_FOR_STATUS[status]
    return "running"   # unknown status: never read as idle


def active_turn_id(thread):
    rid = thread.get("activeRunId")
    if rid:
        return rid
    status = thread.get("status")
    if thread.get("activityRunStatus") is not None or status in ACTIVE_RUN_STATUSES or status not in KNOWN_STATUSES:
        return thread.get("latestRunId") or UNIDENTIFIED_RUN
    return None


def latest_turn(thread):
    rid = thread.get("latestRunId")
    if not rid:
        return None
    status = thread.get("status")
    if status in ACTIVE_RUN_STATUSES:
        state = "running"
    else:
        state = TURN_STATE_FOR_STATUS.get(status, "running")
    return {"turnId": rid, "state": state,
            "requestedAt": thread.get("latestRunRequestedAt"),
            "startedAt": thread.get("latestRunStartedAt"),
            "completedAt": thread.get("latestRunCompletedAt")}


def background_liveness(thread, busy_children):
    tasks = thread.get("pendingBackgroundTasks")
    if not isinstance(tasks, list):
        return "working"
    kinds = [((t.get("kind") if isinstance(t, dict) else None) or "unknown") for t in tasks]
    if busy_children or any(k != "monitor" for k in kinds):
        return "working"
    return "monitoring" if kinds else None


def _error_text(value):
    if value is None or isinstance(value, str):
        return value
    return json.dumps(value, sort_keys=True)[:500]


def v1_thread(thread, now, children=()):
    """A copy of a V2 thread with the V1 keys added beside the V2 ones. Pure."""
    children = list(children)
    reasons = idle_verdict(thread, now, children)
    busy_children = [c for c in children if idle_verdict(c, now)]
    prr = thread.get("pendingRuntimeRequest")
    kind = prr.get("kind") if isinstance(prr, dict) else None
    out = dict(thread)
    out["session"] = {
        "threadId": thread.get("id"),
        "status": session_status(thread, now),
        "activeTurnId": active_turn_id(thread),
        "runtimeMode": thread.get("runtimeMode"),
        "providerInstanceId": thread.get("providerInstanceId"),
        "lastError": _error_text(thread.get("lastError")),
        "updatedAt": thread.get("updatedAt"),
    }
    out["latestTurn"] = latest_turn(thread)
    out["backgroundLiveness"] = background_liveness(thread, busy_children)
    out["hasPendingApprovals"] = prr is not None and kind != "user_input"
    out["hasPendingUserInput"] = prr is not None and kind == "user_input"
    out["idleVerdict"] = {"idle": not reasons, "reasons": reasons}
    return out


def _shell_threads(shell):
    if not isinstance(shell, dict):
        raise ShapeError("the shell answer is not a JSON object")
    threads = shell.get("threads")
    if not isinstance(threads, list):
        raise ShapeError("the shell answer has no threads list")
    for t in threads:
        if not isinstance(t, dict) or not isinstance(t.get("id"), str) or not t.get("id"):
            raise ShapeError("a shell thread has no id")
    if not isinstance(shell.get("projects"), list):
        raise ShapeError("the shell answer has no projects list")
    return threads


def v1_shell(shell, now, kind="shell"):
    """V1-shaped shell (or snapshot) from a V2 shell answer. Pure.

    threads lists root threads only: subagent child threads (lineage.relationshipToParent
    'subagent') refuse messages and are not settle targets, and a caller enumerating
    threads to message or settle must never reach one. They are kept, V1-shaped, under
    subagentThreads, fold into their parent's verdict, and count in serverIdleVerdict,
    the server-wide busy reading. V2 has no snapshot route; `snapshot` is this same view
    (archived and deleted threads absent; every current snapshot caller skips those).
    """
    threads = _shell_threads(shell)
    roots = [t for t in threads if not is_subagent(t)]
    subagents = [t for t in threads if is_subagent(t)]
    kids = children_index(subagents)
    out = dict(shell)
    out["threads"] = [v1_thread(t, now, kids.get(t["id"], {}).values()) for t in roots]
    out["subagentThreads"] = [v1_thread(t, now, kids.get(t["id"], {}).values()) for t in subagents]
    busy = [t["id"] for t in out["threads"] + out["subagentThreads"] if not t["idleVerdict"]["idle"]]
    # heldQueuesChecked false: this verdict reads the shell only, which cannot show a queue
    # held behind a failed or stopped run. `t3-api.sh server-busy` is the
    # full server-wide check; it reads /bounded for every thread the shell calls idle.
    out["serverIdleVerdict"] = {"idle": not busy, "busyThreadIds": busy, "threadsChecked": len(threads),
                                "heldQueuesChecked": False}
    out["orchestrationProtocolVersion"] = 2
    out["t3ApiCompat"] = f"v1-{kind}-from-v2-shell"
    return out


def derive_run_state(projection):
    """Shell-style run state from /bounded runs[] and runtimeRequests[], for a thread the
    shell does not list (archived or deleted). pendingBackgroundTasks is left out on
    purpose: the server derives it from turn items and provider threads, so it cannot be
    rebuilt here, and its absence reads busy (unknown background work)."""
    runs = projection.get("runs")
    if not isinstance(runs, list):
        raise ShapeError("the bounded projection has no runs list")
    runs = [r for r in runs if isinstance(r, dict)]

    def ordinal(run):
        o = run.get("ordinal")
        return o if type(o) is int else -1

    latest = max(runs, key=ordinal) if runs else None
    interruptible = [r for r in runs if r.get("status") in INTERRUPTIBLE_RUN_STATUSES]
    activity = [r for r in runs if r.get("status") in ACTIVITY_RUN_STATUSES]
    requests = projection.get("runtimeRequests") or []
    if not isinstance(requests, list):
        raise ShapeError("the bounded projection runtimeRequests is not a list")
    # The element shape is unverified (no live server had one to read); a request with no
    # status counts as pending, the busier reading.
    pending = [q for q in requests if isinstance(q, dict) and q.get("status") in (None, "pending")]
    return {
        "status": (latest or {}).get("status") or "idle",
        "activeRunId": max(interruptible, key=ordinal).get("id") if interruptible else None,
        "activityRunStatus": max(activity, key=ordinal).get("status") if activity else None,
        "latestRunId": (latest or {}).get("id"),
        "latestRunRequestedAt": (latest or {}).get("requestedAt"),
        "latestRunStartedAt": (latest or {}).get("startedAt"),
        "latestRunCompletedAt": (latest or {}).get("completedAt"),
        "pendingRuntimeRequest": ({"id": pending[-1].get("id"), "kind": pending[-1].get("kind")}
                                  if pending else None),
    }


def v1_thread_detail(bounded, shell, thread_id, now):
    """V1-shaped thread detail ({thread, page, snapshotSequence}) from a V2 /bounded answer.

    /bounded's projection.thread carries no run state (no status, activeRunId,
    pendingBackgroundTasks, pendingRuntimeRequest, latestRun*), so the shell entry is laid
    over it when the shell lists the thread, which keeps `thread` and `shell` agreeing;
    otherwise run state comes from projection.runs. messages gain turnId = runId (V1
    messages carried turnId), and latestTurn.assistantMessageId is the last assistant
    message of the latest run. V2 has no activities list, so none is invented.
    """
    if not isinstance(bounded, dict):
        raise ShapeError("the bounded answer is not a JSON object")
    projection = bounded.get("projection")
    if not isinstance(projection, dict):
        raise ShapeError("the bounded answer has no projection")
    base = projection.get("thread")
    if not isinstance(base, dict):
        raise ShapeError("the bounded projection has no thread")
    if base.get("id") != thread_id:
        raise ShapeError("the bounded answer is for another thread")
    threads = _shell_threads(shell)
    entry = next((t for t in threads if t["id"] == thread_id), None)
    merged = dict(base)
    if entry is not None:
        merged.update(entry)
        source = "shell"
    else:
        merged.update(derive_run_state(projection))
        source = "bounded-runs"
    kids = children_index([t for t in threads if is_subagent(t)])
    out = v1_thread(merged, now, kids.get(thread_id, {}).values())
    messages = projection.get("messages")
    if not isinstance(messages, list) or not all(isinstance(m, dict) for m in messages):
        raise ShapeError("the bounded projection messages is not a list of objects")
    v1_messages = []
    for m in messages:
        d = dict(m)
        d.setdefault("turnId", m.get("runId"))
        v1_messages.append(d)
    out["messages"] = v1_messages
    runs = projection.get("runs")
    if not isinstance(runs, list):
        raise ShapeError("the bounded projection has no runs list")
    out["runs"] = runs
    lt = out["latestTurn"]
    if lt is not None:
        mid = None
        for m in v1_messages:
            if m.get("role") == "assistant" and m.get("runId") == lt["turnId"]:
                mid = m.get("id")
        lt["assistantMessageId"] = mid
    out["runStateSource"] = source
    return {
        "thread": out,
        "page": {k: bounded.get(k) for k in ("hasMoreHistory", "historyCursor", "payloadBudgetExceeded",
                                             "latestLocalTurnOrdinal")},
        "snapshotSequence": bounded.get("snapshotSequence"),
        "orchestrationProtocolVersion": 2,
        "t3ApiCompat": "v1-thread-from-v2-bounded",
    }


def active_turn(shell, thread_id, now):
    for t in v1_shell(shell, now)["threads"]:
        if t["id"] == thread_id:
            return t["session"]["activeTurnId"]
    raise NotFound(thread_id)


# ---- session id -> thread id -------------------------------------------------------------------

def pick_session_thread(rows):
    """(thread id or None, reason) from SESSION_SQL rows. Pure.

    One row maps. Several rows map only when exactly one of them is its thread's active
    provider thread; anything else is refused: compact-cycle and a settle act on the
    thread this returns, so a guessed thread is the failure that matters.
    """
    if not rows:
        return None, ""
    if len(rows) > SESSION_ROW_LIMIT:
        # Choosing from a partial result can hide another active match and direct a
        # compact or settle at the wrong thread. Refuse instead of guessing.
        return None, f"maps to more than {SESSION_ROW_LIMIT} provider threads; refusing to guess from a truncated lookup"
    if len(rows) == 1:
        chosen = rows[0]
    else:
        active = [r for r in rows if r[2] is not None and r[1] == r[2]]
        if len(active) != 1:
            threads = sorted({str(r[0]) for r in rows})
            return None, (f"maps to {len(rows)} provider threads (threads {','.join(threads)}) and {len(active)} of them "
                          "is its thread's active provider thread; refusing to guess")
        chosen = active[0]
    tid = chosen[0]
    if not isinstance(tid, str) or not tid.strip():
        return None, "matches a provider thread that has no thread id; refusing"
    return tid, ""


def thread_for_session(db, session_id):
    """Thread id for a Claude session id from statev2.sqlite, read-only. Raises NotFound
    (exit 5) for no mapping or ambiguity, OSError or sqlite3.Error (exit 4) for an
    unreadable database. Never falls back to the V1 state.sqlite table: on a V2 server that
    table is frozen and maps current sessions to nothing or to the wrong thread."""
    if not os.path.isfile(db):
        raise OSError(f"V2 state db not found: {db} (not falling back to the V1 table on a protocol-2 server)")
    con = sqlite3.connect(f"file:{urllib.parse.quote(db)}?mode=ro", uri=True, timeout=5)
    try:
        con.execute("PRAGMA query_only=1")
        rows = con.execute(SESSION_SQL, (session_id,)).fetchall()
    finally:
        con.close()
    tid, reason = pick_session_thread(rows)
    if tid is None:
        raise NotFound((f"session {session_id} {reason}") if reason else "")
    return tid


# ---- the write path ----------------------------------------------------------------------------
# Every write is one orchestration.dispatchCommand over the WebSocket (lib/t3_ws.py). The
# rules below come from the write-path probe against a scratch 0.1.0 server (frames named
# in each docstring); they are the client's guards, kept on top of the server's.

COMPACT_TEXT = "/compact"
# The text of the failure item a '/compact' run carries when the thread has no conversation
# yet (probe a30, a31; the turn item type 'error', failure.class validation_error).
EMPTY_COMPACT_TEXT = "Start a conversation before compacting this thread."
CALLER_RE = re.compile(r"^[A-Za-z0-9._-]{1,40}$")
KEY_RE = re.compile(r"^[A-Za-z0-9._:@+-]{1,80}$")


class GuardRefusal(Exception):
    """The client's own guard refuses this write (exit 10)."""


def text_guard(text):
    """None when the text may be sent, else the reason. Pure.

    Refused: an empty or whitespace-only text, and any text whose first non-space character
    is '/' unless the whole text is exactly '/compact'. WHY: the server offers a bare
    message starting with '/' to the provider's prompt-command handler first, and '/logout'
    there is a maintenance command. The probe found that handler inert for claudeAgent
    but did not test Codex, so the cheap rule stands: a
    harness text never starts with '/', and compaction is only ever the exact '/compact'.
    """
    if not isinstance(text, str) or not text.strip():
        return "the message is empty"
    if text.lstrip().startswith("/") and text != COMPACT_TEXT:
        return (f"the message starts with '/' ({text.strip()[:40]!r}): a slash command can reach the provider's command handler; "
                "only an exact '/compact' may be sent, through `compact`")
    return None


def _projection(bounded, thread_id):
    if not isinstance(bounded, dict):
        raise ShapeError("the bounded answer is not a JSON object")
    projection = bounded.get("projection")
    if not isinstance(projection, dict) or not isinstance(projection.get("thread"), dict):
        raise ShapeError("the bounded answer has no projection thread")
    if projection["thread"].get("id") != thread_id:
        raise ShapeError("the bounded answer is for another thread")
    return projection


def target_guard(bounded, thread_id):
    """None when a message may go to the thread, else the reason. Pure.

    WHY (probe a50, a51): a message to an ARCHIVED thread is accepted and starts a run, and
    the thread stays archived and out of the shell, so nobody sees the result. A stored
    thread id (a scheduled wake's mapping) can point at a thread archived since; the archived
    flag lives in /bounded (the shell omits archived threads)."""
    thread = _projection(bounded, thread_id)["thread"]
    if thread.get("deletedAt"):
        return "thread {} was deleted at {}".format(thread_id, thread.get("deletedAt"))
    if thread.get("archivedAt"):
        return ("thread {} is archived (since {}): a message would run there unseen; unarchive it in T3 first".format(thread_id, thread.get("archivedAt")))
    return None


def is_settled(entry):
    """settledOverride is settled, active (unsettled by hand) or null; with null, settledAt
    decides (an automatic settle). A message to a settled thread clears both (probe a44)."""
    override = entry.get("settledOverride")
    if override == "settled":
        return True
    return override is None and bool(entry.get("settledAt"))


def thread_verdict(shell, thread_id, now, mode, bounded=None):
    """(verdict, reasons, stamp) for settle, archive and the settle waiter. Pure.

    verdict: missing (absent from the shell, or archived), settled (mode settle only: a
    settle is then a no-op), busy, or idle. idle is only ever returned when the caller
    passed the thread's /bounded answer: the shell alone cannot show a held queue, so a
    shell-only idle reading comes back as 'unconfirmed' and the caller must read /bounded
    and ask again. stamp is the shell's latestUserMessageAt, the settle waiter's baseline.
    """
    if mode not in ("settle", "archive"):
        raise ValueError(mode)
    threads = _shell_threads(shell)
    entry = next((t for t in threads if t["id"] == thread_id), None)
    if entry is None or entry.get("archivedAt"):
        return "missing", [], ""
    stamp = entry.get("latestUserMessageAt") or ""
    if not isinstance(stamp, str):
        stamp = json.dumps(stamp)
    if mode == "settle" and is_settled(entry):
        return "settled", [], stamp
    kids = children_index([t for t in threads if is_subagent(t)]).get(thread_id, {}).values()
    projection = _projection(bounded, thread_id) if bounded is not None else None
    if projection is not None and (projection["thread"].get("archivedAt") or projection["thread"].get("deletedAt")):
        # /bounded is read after the shell: a concurrent archive/delete can leave a
        # stale live shell entry even though the server still serves its history.
        return "missing", [], stamp
    reasons = idle_verdict(entry, now, kids, projection)
    if reasons:
        return "busy", reasons, stamp
    return ("idle" if projection is not None else "unconfirmed"), [], stamp


def stop_target(shell, thread_id):
    """(run id or None, why) for run.interrupt. Pure. Raises NotFound when the thread is
    not in the shell.

    thread.stop is not accepted over the public RPC (probe a53: rejected at
    decode), so a stop names a run: the shell's activeRunId; else latestRunId while a run is
    active without an activeRunId (a waiting run) or while background work is pending (the
    server then interrupts that work too); else nothing, because run.interrupt on an idle
    thread or a finished run fails with 'Run <id> is not interruptible.' (a54, a55)."""
    threads = _shell_threads(shell)
    entry = next((t for t in threads if t["id"] == thread_id), None)
    if entry is None:
        raise NotFound(thread_id)
    rid = entry.get("activeRunId")
    if rid:
        return rid, "the active run"
    latest = entry.get("latestRunId")
    ars = entry.get("activityRunStatus")
    if ars is not None and latest:
        return latest, f"the latest run, which is {ars}"
    tasks = entry.get("pendingBackgroundTasks")
    if latest and (not isinstance(tasks, list) or tasks):
        return latest, "the latest run's background work"
    return None, "no run is active and no background work is pending"


def _turn_items(projection):
    """Flat turn items: projection.turnItems plus the item inside each visibleTurnItems entry."""
    items = []
    for key in ("turnItems", "visibleTurnItems"):
        value = projection.get(key) or []
        if not isinstance(value, list):
            raise ShapeError(f"the bounded projection {key} is not a list")
        for entry in value:
            item = entry.get("item") if key == "visibleTurnItems" and isinstance(entry, dict) else entry
            if isinstance(item, dict):
                items.append(item)
    return items


def compact_evidence(bounded, thread_id, message_id):
    """(state, detail) for a '/compact' message. Pure. state is one of:
      pending             no run has adopted the message yet, or its run is still active
      completed           the run whose userMessageId is the message completed AND a turn item
                          of type 'compaction' with status 'completed' belongs to that run
                          (probe b27: beforeTokenCount, afterTokenCount)
      failed              the run failed, was interrupted, cancelled or rolled back, or it
                          completed with no completed compaction item: run status alone is not
                          proof (probe a32, a65: an unauthenticated provider 'completed' a
                          /compact run with "Error during compaction" and no compaction item)
      nothing-to-compact  the run failed with "Start a conversation before compacting this
                          thread." (probe a30, a31): the thread has no conversation to compact
    Raises ShapeError for a run status this client does not know (fail loud)."""
    projection = _projection(bounded, thread_id)
    runs = projection.get("runs")
    if not isinstance(runs, list):
        raise ShapeError("the bounded projection has no runs list")
    mine = [r for r in runs if isinstance(r, dict) and r.get("userMessageId") == message_id]
    if not mine:
        return "pending", f"no run has adopted message {message_id} yet"
    # Several runs on one message happen only when a messageId was reused (probe c15); the
    # newest is the one that counts.
    run = max(mine, key=lambda r: r.get("ordinal") if type(r.get("ordinal")) is int else -1)
    run_id = run.get("id")
    if not isinstance(run_id, str) or not run_id.strip():
        # Missing ids on both a run and an unrelated item must never compare equal:
        # completed evidence authorizes the caller to resume after compaction.
        raise ShapeError(f"the run carrying message {message_id} has no valid id")
    status = run.get("status")
    items = [i for i in _turn_items(projection) if i.get("runId") == run_id]
    if status in ACTIVE_RUN_STATUSES:
        return "pending", "run {} is {}".format(run.get("id"), status)
    if status == "completed":
        done = [i for i in items if i.get("type") == "compaction" and i.get("status") == "completed"]
        if done:
            return "completed", "compacted {} -> {} tokens".format(done[-1].get("beforeTokenCount"),
                                                             done[-1].get("afterTokenCount"))
        return "failed", "run {} completed without a completed compaction item".format(run.get("id"))
    if status == "failed":
        texts = [str((i.get("failure") or {}).get("message") or "") for i in items
                 if i.get("type") == "error" and isinstance(i.get("failure"), dict)]
        if any(t.strip() == EMPTY_COMPACT_TEXT for t in texts):
            return "nothing-to-compact", EMPTY_COMPACT_TEXT
        return "failed", "run {} failed{}".format(run.get("id"), (": " + texts[0][:200]) if texts and texts[0] else "")
    if status in TERMINAL_RUN_STATUSES:
        return "failed", "run {} was {}".format(run.get("id"), status)
    raise ShapeError("run {} has status {!r}, which this client does not know".format(run.get("id"), status))


def operator_check(bounded, thread_id, baseline):
    """(who, detail) for the user messages created after baseline. Pure.

    WHY: the settle waiter stops without settling when the operator is still talking to
    the thread. On V2 the RPC forces createdBy to 'user' for every send (probe c24), so
    latestUserMessageAt moves for harness sends too; creationSource survives, and the
    harness sends with creationSource 'server'. who is:
      operator  a newer user message whose creationSource is not 'server' (the web UI, an
                agent through T3's MCP tools, anything unknown), or an unreadable time:
                not settling is the safe side
      harness   every newer user message has creationSource 'server' (a wake, a resume)
      unseen    no newer user message in /bounded. The waiter asks only after the shell's
                stamp moved, so this means the change cannot be explained; the waiter
                treats it like operator.
    """
    projection = _projection(bounded, thread_id)
    messages = projection.get("messages")
    if not isinstance(messages, list):
        raise ShapeError("the bounded projection messages is not a list")
    ok, base = parse_ts(baseline) if baseline else (True, None)
    if not ok:
        return "operator", f"the baseline {baseline!r} does not parse; not settling"
    newer = []
    for m in messages:
        if not isinstance(m, dict) or m.get("role") != "user":
            continue
        ok, created = parse_ts(m.get("createdAt"))
        if not ok or created is None:
            return "operator", "user message {} has an unreadable createdAt".format(m.get("id"))
        if base is None or created > base:
            newer.append(m)
    others = [m for m in newer if m.get("creationSource") != "server"]
    if others:
        m = others[-1]
        return "operator", "user message {} (creationSource {}, {})".format(m.get("id"), m.get("creationSource"),
                                                                        m.get("createdAt"))
    if newer:
        return "harness", f"{len(newer)} harness message{'' if len(newer) == 1 else 's'} (creationSource server)"
    return "unseen", "no user message newer than %s in /bounded" % (baseline or "the launch")


def command_ids(caller, verb, thread_id, content, key):
    """(commandId, messageId), deterministic from intent and content. Pure.

    '<caller>:<verb>:<thread>:<sha256(content)[:12]>:<key>' and the same with 'msg' for the
    messageId. WHY each part: the server keeps one receipt per commandId and replays it for
    the same id (probe a13, a22), so a transport retry must reuse both ids; but the same
    commandId with a CHANGED text returns the stored receipt and silently drops the new
    text (c14), and a new commandId that reuses a messageId overwrites the earlier message
    (c15). The content hash makes both ids change whenever the text does. The key says
    which intent this is: a caller that can fire twice for one intent (a wake on a
    timer) passes its own key (its fire time) through OPS_T3_COMMAND_KEY, so a double
    fire replays the receipt instead of sending twice; without one, every invocation gets a
    fresh random key, so a second '/compact' or a repeated resume text is a new command,
    never a silently dropped replay."""
    if not CALLER_RE.match(caller or ""):
        raise ValueError(f"OPS_T3_CALLER must match {CALLER_RE.pattern}, got {caller!r}")
    if not KEY_RE.match(key or ""):
        raise ValueError(f"the command key must match {KEY_RE.pattern}, got {key!r}")
    digest = hashlib.sha256(content.encode("utf-8")).hexdigest()[:12]
    return (f"{caller}:{verb}:{thread_id}:{digest}:{key}",
            f"{caller}:msg:{thread_id}:{digest}:{key}")


def build_command(kind, thread_id, caller, key, text=None, run_id=None):
    """One OrchestrationV2Command for dispatchCommand. Pure (the key is an argument).

    message:   message.dispatch, dispatchMode queue_after_active and no deliveryIntent: with
               a run active it queues behind it, idle it starts at once (probe b04, a18).
               deliveryIntent 'auto' injects the text into the live run (b30), and steering
               is refused for '/compact' (b29). createdBy 'user' (the RPC forces it anyway,
               c24), creationSource 'server' (the settle waiter's operator check reads it).
    settle:    thread.settle {commandId, threadId}.
    archive:   thread.archive {commandId, threadId}.
    interrupt: run.interrupt with holdQueue true, the UI's Stop (b07, b08): runs queued
               behind it are held, never started by the stop.
    cancel:    queued-run.cancel {commandId, threadId, runId} (a39; the 0.1.0 command schema has
               exactly these keys). The server refuses it for a run that is not queued ("Run
               <id> is not queued.", read from the 0.1.0 decider), so a run that started after
               the client's read is never touched. queued_cancel_plan picks the run."""
    if kind == "message":
        verb = "compact" if text == COMPACT_TEXT else "send"
        cid, mid = command_ids(caller, verb, thread_id, text, key)
        return {"type": "message.dispatch", "commandId": cid, "threadId": thread_id, "messageId": mid,
                "text": text, "attachments": [], "createdBy": "user", "creationSource": "server",
                "dispatchMode": {"type": "queue_after_active"}}
    if kind in ("settle", "archive"):
        cid, _ = command_ids(caller, kind, thread_id, "", key)
        return {"type": "thread." + kind, "commandId": cid, "threadId": thread_id}
    if kind == "interrupt":
        cid, _ = command_ids(caller, "stop", thread_id, run_id or "", key)
        return {"type": "run.interrupt", "commandId": cid, "threadId": thread_id, "runId": run_id,
                "reason": "t3-api stop", "holdQueue": True}
    if kind == "cancel":
        cid, _ = command_ids(caller, "cancel", thread_id, run_id or "", key)
        return {"type": "queued-run.cancel", "commandId": cid, "threadId": thread_id, "runId": run_id}
    raise ValueError(f"unknown command kind {kind!r}")


def queued_cancel_plan(bounded, thread_id, message_id):
    """[(run id, status, cancel)] for every run that carries message_id. Pure.

    WHY (probe a36, b08): a run queued behind one that fails, or that is stopped
    with holdQueue true, stays queued and never starts on its own. A fresh send starts at once
    and jumps it (a32, a45), so the thread goes back to work with the old message still
    queued, invisible in the shell, and queue.resume (a38) or any later release would deliver
    it then. queued-run.cancel {runId} removes one queued run (a39).

    Which run is the caller's own is proven by an exact id, never by text or queue position:
    a run's userMessageId is the messageId its message.dispatch carried (b27), and the caller
    passes the messageId it minted for that send. /bounded lists every run (its runs array is
    the full control-plane list, not the paged history window) and keeps the user message of
    every queued run (buildBoundedThreadProjection and messagesForBoundedProjection in the
    0.1.0 server). cancel is True only for status 'queued': a run that started or ended, or
    whose status this client does not know, is left alone.

    Raises GuardRefusal when a run to cancel carries a message that is not a harness send
    (creationSource other than 'server'), or whose message /bounded does not show: a person's
    or an agent's queued message is never this client's to remove, whatever id it is handed.
    Raises ShapeError for a runs or messages list, or a matching run, it cannot read."""
    projection = _projection(bounded, thread_id)
    runs = projection.get("runs")
    if not isinstance(runs, list):
        raise ShapeError("the bounded projection has no runs list")
    messages = projection.get("messages")
    if not isinstance(messages, list):
        raise ShapeError("the bounded projection messages is not a list")
    plan = []
    for run in runs:
        if not isinstance(run, dict) or run.get("userMessageId") != message_id:
            continue
        rid, status = run.get("id"), run.get("status")
        if not isinstance(rid, str) or not rid:
            raise ShapeError(f"a run carrying message {message_id} has no id")
        cancel = status == "queued"
        if cancel:
            message = next((m for m in messages if isinstance(m, dict) and m.get("id") == message_id), None)
            if message is None:
                raise GuardRefusal(f"run {rid} is queued but /bounded does not show its message {message_id}, so it "
                                   "cannot be confirmed as a harness send")
            if message.get("creationSource") != "server":
                raise GuardRefusal(f"run {rid} carries message {message_id} with creationSource "
                                   f"{message.get('creationSource')!r}: only a harness send (creationSource 'server') "
                                   "is cancelled here")
        plan.append((rid, status if isinstance(status, str) else json.dumps(status), cancel))
    return plan


def server_busy_plan(shell, now):
    """Thread ids (roots and subagent children) the shell calls idle: the threads whose
    /bounded the server-wide check must read. Pure."""
    threads = _shell_threads(shell)
    kids = children_index([t for t in threads if is_subagent(t)])
    return [t["id"] for t in threads if not idle_verdict(t, now, kids.get(t["id"], {}).values())]


def server_busy(shell, bounded_by_id, now):
    """The server-wide busy verdict over every shell thread, held queues included. Pure.

    bounded_by_id maps each planned thread id to its /bounded answer, or to None when the
    thread left the shell between the reads (it is then not counted). A planned thread with
    no entry at all reads busy: the caller did not look."""
    threads = _shell_threads(shell)
    kids = children_index([t for t in threads if is_subagent(t)])
    plan = set(server_busy_plan(shell, now))
    busy, reasons, reads = [], {}, 0
    for t in threads:
        tid = t["id"]
        projection = None
        if tid in plan:
            if tid not in bounded_by_id:
                busy.append(tid)
                reasons[tid] = ["its /bounded was not read (treated as busy)"]
                continue
            if bounded_by_id[tid] is None:
                continue
            projection = _projection(bounded_by_id[tid], tid)
            reads += 1
        r = idle_verdict(t, now, kids.get(tid, {}).values(), projection)
        if r:
            busy.append(tid)
            reasons[tid] = r
    return {"idle": not busy, "busyThreadIds": busy, "reasons": reasons, "threadsChecked": len(threads),
            "boundedReads": reads, "heldQueuesChecked": True, "orchestrationProtocolVersion": 2}


# ---- CLI ---------------------------------------------------------------------------------

def _read(path):
    with open(path, "rb") as fh:
        return fh.read()


def _load(path, label):
    return check_json_body(_read(path), "application/json", label)


def _err(msg):
    if msg:
        sys.stderr.write(msg.rstrip("\n") + "\n")


def _field(text):
    """One '|'-separated output field: no '|' and no newline inside."""
    return str(text).replace("|", "/").replace("\n", " ")


def _read_text(path):
    try:
        return _read(path).decode("utf-8")
    except UnicodeDecodeError:
        raise GuardRefusal("the message is not valid UTF-8") from None


def _command(args):
    """command <message|settle|archive|interrupt|cancel> <thread> [<text-file>|<run-id>] [--attempt N]"""
    attempt = None
    if len(args) >= 2 and args[-2] == "--attempt":
        attempt, args = args[-1], args[:-2]
        if not re.match(r"^[1-9][0-9]{0,3}$", attempt):
            raise ValueError(f"--attempt must be a whole number from 1 to 9999, got {attempt!r}")
    if not args or args[0] not in ("message", "settle", "archive", "interrupt", "cancel"):
        raise ValueError("command kind must be message, settle, archive, interrupt or cancel")
    kind = args[0]
    want = 3 if kind in ("message", "interrupt", "cancel") else 2
    if len(args) != want:
        raise ValueError(f"command {kind} takes {want - 1} argument(s)")
    caller = os.environ.get("OPS_T3_CALLER") or "t3-api"
    key = os.environ.get("OPS_T3_COMMAND_KEY") or ("n" + os.urandom(8).hex())
    text = run_id = None
    if kind == "message":
        text = _read_text(args[2])
        why = text_guard(text)
        if why:
            raise GuardRefusal(why)
    elif kind in ("interrupt", "cancel"):
        run_id = args[2]
    command = build_command(kind, args[1], caller, key, text=text, run_id=run_id)
    if attempt is not None:
        # A refused commandId is spent (probe a42, a46). Suffix the validated ids,
        # rather than the input key, so an allowed 80-character key still works.
        for field in ("commandId", "messageId"):
            if field in command:
                command[field] += f":a{attempt}"
    return command


def main(argv):
    if len(argv) < 2:
        _err("t3_api_v2: no operation")
        return EXIT_USAGE
    op, args = argv[1], argv[2:]
    now = datetime.datetime.now(datetime.timezone.utc)
    arity = {"check-json": (3,), "protocol": (1,), "quote": (1,), "v1-shell": (2,), "v1-thread": (3,),
             "active-turn": (2,), "thread-for-session": (2,), "verdict": (3, 4), "text-guard": (1,),
             "target-check": (2,), "stop-target": (2,), "compact-status": (3,), "operator-check": (3,),
             "command": (2, 3, 4, 5), "server-busy": (2,), "server-busy-plan": (1,),
             "queued-cancel-plan": (3,)}
    if op not in arity or len(args) not in arity[op]:
        _err("t3_api_v2: usage: %s" % (op if op in arity else f"unknown operation {op!r}"))
        return EXIT_USAGE
    try:
        if op == "check-json":
            check_json_body(_read(args[0]), args[1], args[2])
        elif op == "protocol":
            print(protocol_version(_load(args[0], "GET /.well-known/t3/environment")))
        elif op == "quote":
            print(urllib.parse.quote(args[0], safe=""))
        elif op == "v1-shell":
            if args[1] not in ("shell", "snapshot"):
                _err("t3_api_v2: v1-shell kind must be shell or snapshot")
                return EXIT_USAGE
            print(json.dumps(v1_shell(_load(args[0], "GET /api/orchestration/shell"), now, args[1])))
        elif op == "v1-thread":
            print(json.dumps(v1_thread_detail(_load(args[0], "GET thread bounded"),
                                              _load(args[1], "GET /api/orchestration/shell"), args[2], now)))
        elif op == "active-turn":
            atid = active_turn(_load(args[0], "GET /api/orchestration/shell"), args[1], now)
            print(atid if atid is not None else "null")
        elif op == "thread-for-session":
            print(thread_for_session(args[0], args[1]))
        elif op == "verdict":
            if args[2] not in ("settle", "archive"):
                _err("t3_api_v2: verdict mode must be settle or archive")
                return EXIT_USAGE
            bounded = _load(args[3], "GET thread bounded") if len(args) == 4 else None
            verdict, reasons, stamp = thread_verdict(_load(args[0], "GET /api/orchestration/shell"), args[1], now,
                                                     args[2], bounded)
            print("{}|{}|{}".format(verdict, _field("; ".join(reasons)), _field(stamp)))
        elif op == "text-guard":
            why = text_guard(_read_text(args[0]))
            if why:
                raise GuardRefusal(why)
        elif op == "target-check":
            why = target_guard(_load(args[0], "GET thread bounded"), args[1])
            if why:
                raise GuardRefusal(why)
        elif op == "stop-target":
            rid, why = stop_target(_load(args[0], "GET /api/orchestration/shell"), args[1])
            print("{}|{}".format(_field(rid or ""), _field(why)))
        elif op == "compact-status":
            state, detail = compact_evidence(_load(args[0], "GET thread bounded"), args[1], args[2])
            print(state)
            if detail and state != "pending":
                _err(f"t3-api: compact {state}: {detail}")
        elif op == "operator-check":
            who, detail = operator_check(_load(args[0], "GET thread bounded"), args[1], args[2])
            print(f"{who}|{_field(detail)}")
        elif op == "command":
            print(json.dumps(_command(args)))
        elif op == "queued-cancel-plan":
            if not args[2]:
                raise ValueError("queued-cancel-plan needs a message id")
            # One line per run that carries the message: "cancel|<run id>|queued" or
            # "leave|<run id>|<status>". No line: no run carries it.
            for rid, status, cancel in queued_cancel_plan(_load(args[0], "GET thread bounded"), args[1], args[2]):
                print("{}|{}|{}".format("cancel" if cancel else "leave", _field(rid), _field(status)))
        elif op == "server-busy-plan":
            for tid in server_busy_plan(_load(args[0], "GET /api/orchestration/shell"), now):
                print(tid)
        elif op == "server-busy":
            shell = _load(args[0], "GET /api/orchestration/shell")
            bounded_by_id = {}
            index = os.path.join(args[1], "index.tsv")
            if os.path.exists(index):
                with open(index, "r", encoding="utf-8") as fh:
                    for line in fh:
                        n, _, tid = line.rstrip("\n").partition("\t")
                        path = os.path.join(args[1], n + ".json")
                        bounded_by_id[tid] = _load(path, "GET thread bounded") if os.path.exists(path) else None
            print(json.dumps(server_busy(shell, bounded_by_id, now)))
    except GuardRefusal as e:
        _err(f"t3-api: refused by guard: {e}; nothing sent")
        return EXIT_GUARD
    except ShapeError as e:
        _err(f"t3-api: {e}")
        return EXIT_BAD_ANSWER
    except UnsupportedProtocol as e:
        _err(f"t3-api: the server reports orchestrationProtocolVersion {e.args[0]!r}; this client speaks 1 and 2 "
             "only; refusing")
        return EXIT_UNSUPPORTED
    except NotFound as e:
        # Zero rows stay silent, as the V1 lookup was; an ambiguity names itself.
        if op == "thread-for-session" and e.args and e.args[0]:
            _err(f"t3-api: {e.args[0]}")
        elif op == "stop-target":
            _err(f"t3-api: thread {args[1]} is not in the shell (archived, deleted, or unknown); nothing sent")
        return EXIT_NOT_FOUND
    except ValueError as e:
        _err(f"t3-api: {e}")
        return EXIT_USAGE
    except sqlite3.Error as e:
        _err(f"t3-api: cannot read the V2 state db {args[0]}: {e}")
        return EXIT_UNREADABLE
    except OSError as e:
        _err(f"t3-api: {e}")
        return EXIT_UNREADABLE
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
