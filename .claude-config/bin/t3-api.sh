#!/usr/bin/env bash
# t3-api.sh: thin authenticated client for the T3 Code orchestration HTTP API.
#
# WHY THIS EXISTS: a session cannot fire /compact on itself, and a T3 Code thread
# has no pane to type into. T3 exposes an authenticated orchestration API; this
# helper is the client for it. compact-cycle.sh calls it to wait for idle, request
# native compaction, verify it and send the resume; context-watch.sh maps its
# session to the thread's baton through thread-for-session. It is also usable on
# its own for read-only inspection (snapshot / thread / active-turn).
#
# SUPPORT: Linux only (settle-when-idle detaches with setsid, and the suites run in
# bin/sandbox-run). It needs python3, curl, a T3 Code server on this box, and the
# harness token below. Without the token every subcommand that talks to the server
# exits 3 with one line on stderr and sends nothing.
#
# PROTOCOL (dual mode): T3 0.1.0 speaks orchestration protocol 2 (V2) and
# removed every V1 route this client used. Each invocation that talks to the server
# first reads GET /.well-known/t3/environment once and caches the answer for that
# invocation: orchestrationProtocolVersion 2 is V2; 1, an absent key, or a 404 for the
# whole route (a server older than the endpoint, and the suites' stubs) is V1, whose
# behavior is unchanged apart from the fail-loud rule below. Any other value exits 8;
# an HTML or non-JSON answer exits 6. On V2:
#   * every orchestration GET carries the header x-t3-orchestration-protocol: 2 (without
#     it the server answers a bare 400);
#   * thread ids are percent-encoded with quote(id, safe='') in route paths (subagent
#     child ids carry ':' and literal '%' sequences; a raw id is a 404);
#   * snapshot, shell, thread and active-turn print V1-shaped JSON built from the V2
#     answer (V1-SHAPE MAPPING below), so existing callers keep working;
#   * thread-for-session reads statev2.sqlite, never the frozen V1 table;
#   * every write is one orchestration.dispatchCommand Effect-RPC call over a WebSocket at
#     ws://<host:port>/ws?orchestrationProtocol=2 (V2 has no HTTP write route): lib/t3_ws.py
#     opens it with the bearer in the Authorization header (read in-process from the token
#     file), sends one Request, reads until its Exit and closes. See WRITES ON V2;
#   * dispatch (a raw command) and archive refuse with exit 7, see SUBCOMMANDS;
#   * server-busy and queued-cancel exist only here (exit 8 on V1).
# The V2 body handling and the write commands live in lib/t3_api_v2.py beside this script
# (pure functions, no network, read-only database opens); lib/t3_ws.py is the WebSocket
# client; this script keeps the CLI, the token file and curl for the reads.
#
# WRITES ON V2 (from a write-path probe against a scratch 0.1.0 server; frame ids such as
# a13 or b27 below name its recorded exchanges, and tests/fixtures/t3-v2/ws/ holds the ones
# the suites replay):
#   * An Exit is classified: Success (exit 0, the value printed as JSON); Failure with a
#     Fail cause, a domain refusal from the server (exit 11: the commandId is spent, so
#     re-read state and mint a fresh id, never loop on it); Failure with a Die cause, the
#     server could not decode the command, no receipt (exit 12, a client defect); transport
#     loss before the Exit, retried ONCE with the identical frame, same commandId and
#     messageId, which the server replays from its receipt (exit 4 if the retry is lost too).
#     A refused upgrade (401, 426) is not retried (exit 4).
#   * Ids: commandId '<caller>:<verb>:<thread>:<sha256(text)[:12]>:<key>', messageId the
#     same with 'msg' (lib/t3_api_v2.py command_ids). The text hash changes both ids with the
#     text: the same commandId with a new text is silently dropped by the server, and a
#     reused messageId overwrites the earlier message. The key is OPS_T3_COMMAND_KEY when
#     the caller sets it (a timer wake passes its fire time, so a double fire replays the
#     receipt instead of sending twice), else a fresh random key per invocation.
#   * Guards this client keeps on top of the server: no text that starts with '/' except
#     an exact '/compact', and no empty text (exit 10); no message to an archived or
#     deleted thread, read from /bounded (exit 10: the server accepts it and the run happens
#     unseen); no settle unless the idle verdict, with the thread's /bounded runs, says idle
#     (exit 9); queued-run.cancel only for a queued run whose message this caller names by id
#     and that is a harness send (exit 10 otherwise), never queue.resume. archive is refused
#     outright (exit 7): thread.archive has NO server guard at all (it ends the live run as
#     failed and cancels every queued run), and no client read can close the window between
#     its last read and the dispatch.
#   * OPS_T3_DRY=1 prints "WS orchestration.dispatchCommand" and the command JSON instead
#     of sending; the reads and guards before it still run.
#
# FAIL LOUD: every JSON answer, in both modes and for every method, must be a JSON
# object with a content type that is not HTML, or the call exits 6 with a one-line
# reason. WHY: on T3 0.1.0 GET /api/orchestration/snapshot answers 200 with the web
# app's HTML, and `snapshot` used to exit 0 on it, a false ok its callers (compact-cycle
# among them) trusted. A status code alone never proves an answer.
#
# V1-SHAPE MAPPING (protocol 2 only). V2 threads have no session, latestTurn,
# backgroundLiveness or pending-request flags; the V1 keys below are ADDED to each
# thread (every V2 key passes through untouched). lib/t3_api_v2.py is the authority.
#   session.status       starting if activityRunStatus or status is preparing, queued or
#                        starting, or a user message under 120 s old has no run yet;
#                        running if activityRunStatus is set otherwise, status is running
#                        or waiting, or activeRunId is set; else idle (idle: no runs),
#                        ready (completed, rolled_back), error (failed), interrupted
#                        (interrupted, cancelled); any unknown status reads running.
#                        WHY: callers test status for starting/running to mean busy, so an
#                        unknown value must land on the busy side.
#   session.activeTurnId activeRunId; else latestRunId while a run is active or the status
#                        is unknown (activeRunId omits waiting runs, V1 counted them); else
#                        null. "unidentified-active-run" stands in when no id exists.
#   session.runtimeMode, session.providerInstanceId, session.updatedAt
#                        the thread's top-level runtimeMode, providerInstanceId, updatedAt
#                        (V2 moved them off the session).
#   session.lastError    lastError (a non-string value is JSON-encoded).
#   latestTurn           null with no latestRunId; else {turnId: latestRunId, state,
#                        requestedAt, startedAt, completedAt from latestRun*At}. state is
#                        running for an active status, completed, error for failed (a
#                        caller that resumes after a usage limit keys on it), interrupted for interrupted,
#                        cancelled and rolled_back, running for anything unknown. `thread`
#                        adds assistantMessageId (the latest run's last assistant message).
#   backgroundLiveness   working if any pendingBackgroundTasks entry is not kind monitor,
#                        if the list is missing or malformed, or if a subagent child of
#                        the thread is busy; monitoring if every task is a monitor (a
#                        pull-request watch); else null. 'completed' plus tasks is V1's
#                        ready plus backgroundLiveness.
#   hasPendingUserInput  pendingRuntimeRequest.kind is user_input.
#   hasPendingApprovals  any other pendingRuntimeRequest, auth_refresh and unknown kinds
#                        included (something is waiting either way).
#   idleVerdict          {idle, reasons}: the one V2 idle verdict (IDLE below).
# The envelope adds orchestrationProtocolVersion 2, t3ApiCompat (which translation ran),
# subagentThreads (child threads, V1-shaped, never in `threads`: they refuse messages and
# are not settle targets), and serverIdleVerdict {idle, busyThreadIds, threadsChecked}
# over root AND child threads, the server-wide busy reading. `thread` adds messages[]
# with turnId = runId, runs[], runStateSource (shell, or bounded-runs for a thread the
# shell does not list), and page {hasMoreHistory, historyCursor, payloadBudgetExceeded,
# latestLocalTurnOrdinal}.
#
# SECURITY (non-negotiable): the bearer token is NEVER printed, logged, or placed
# on a command line: argv is world-readable through ps, so a token on it leaks a
# credential with orchestration:operate scope on the operator's live sessions.
# The token is read into a variable and handed to curl ONLY through a mode-0600
# --config (-K) file inside a private mktemp -d dir that is removed on EXIT. The
# `token` subcommand prints the token FILE PATH, never its bytes. No eval anywhere.
# On a V2 write, lib/t3_ws.py gets the token FILE PATH on its argv, reads the token
# in-process, and sends it only in the WebSocket upgrade's Authorization header; its
# error lines never echo request headers.
#
# TOKEN: file $OPS_T3_TOKEN_FILE (default ~/.config/ops/t3-harness.token), owned by the
# account that runs the sessions, mode 0600. Issue it on the box that runs T3 Code:
#     mkdir -p ~/.config/ops && chmod 700 ~/.config/ops
#     ( umask 077; t3 auth session issue --ttl 365d --label <box>-ops-harness --token-only \
#         --scope orchestration:read --scope orchestration:operate \
#         > ~/.config/ops/t3-harness.token )
# That these two scopes cover thread.settle on a freshly issued token is UNVERIFIED: if
# the server refuses a request, its error (printed here) names what is missing. The
# header sent is "Authorization: Bearer <token>"; an
# unauthenticated request returns 401. Without the file, every subcommand that talks to
# the server exits 3 ("t3-api: token file not found: <path>") and sends nothing.
#
# BASE URL: $OPS_T3_BASE if set, else the .origin field of
# $T3CODE_HOME/userdata/server-runtime.json (T3CODE_HOME default ~/.t3).
#
# SUBCOMMANDS:
#   token                     print the token FILE PATH        (exit 3 if missing)
#   base                      print the resolved server origin
#   snapshot                  V1: GET /api/orchestration/snapshot (raw JSON). V2: the
#                             V1-shaped shell (V2 has no snapshot route over HTTP), so
#                             archived and deleted threads are absent; every current
#                             snapshot caller skips those anyway.
#   thread <id> [turnLimit]   V1: GET /api/orchestration/threads/<id>?turnLimit=N. V2: GET
#                             /api/orchestration/threads/<quoted id>/bounded plus the shell
#                             for run state, V1-shaped; turnLimit is ignored (the server
#                             bounds the answer; paged history is not fetched, no caller
#                             needs more than the latest run).
#   thread-for-session <sid>  map a Claude or Codex session id -> T3 thread id (exit 5 if
#                             none or ambiguous). V1: the SQLite provider_session_runtime
#                             table. V2: statev2.sqlite
#                             orchestration_v2_projection_provider_threads where
#                             payload_json $.nativeThreadRef.nativeId is the session id and
#                             owner_node_id IS NULL; several rows resolve only to the one
#                             whose provider_thread_id is its thread's
#                             active_provider_thread_id. A missing or unreadable V2 db
#                             exits 4; it never falls back to the frozen V1 table. The
#                             Codex mapping on V2 is unverified (no Codex row existed).
#   active-turn <id>          print session.activeTurnId, or the literal "null" when
#                             no turn runs (exit 5 if the thread is absent from the
#                             snapshot; on V2, from the shell's root threads)
#   send <id> <text...>       V1: dispatch a thread.turn.start carrying <text>.
#                             runtimeMode is copied from the thread's current
#                             session.runtimeMode in the snapshot, else "full-access";
#                             interactionMode "default"; attachments []; fresh UUID
#                             commandId + messageId; UTC ISO-8601 createdAt.
#                             V2: message.dispatch, dispatchMode queue_after_active (queues
#                             behind an active run, starts at once on an idle one), no
#                             deliveryIntent (it would inject into the live run),
#                             creationSource server. Refused (exit 10) for an empty text, a
#                             text starting with '/' (unless exactly '/compact'), or a thread
#                             that /bounded shows archived or deleted; exit 5 for an unknown
#                             thread. Prints the server's {"sequence":N}: accepted, not done.
#   compact <id>             dispatch exact /compact; print its messageId. V2: the same
#                             message.dispatch as send, as its own queued run (steering it
#                             into an active run is refused by the server).
#   compact-status <id> <mid> print pending|completed|failed, matching that request. V2 reads
#                             /bounded: completed only when the run whose userMessageId is
#                             <mid> completed AND a turn item of type compaction with status
#                             completed belongs to it; failed when the run failed, was
#                             interrupted or cancelled, or completed without that item (run
#                             status alone is not proof); and a fourth answer,
#                             nothing-to-compact, when the run failed with "Start a
#                             conversation before compacting this thread." Unknown run
#                             status exits 6.
#   stop <id>                 V1: dispatch thread.session.stop. V2: run.interrupt with
#                             holdQueue true (the UI's Stop: runs queued behind it are held,
#                             not started) on the shell's activeRunId, else latestRunId while
#                             a run is active without one or background work is pending.
#                             thread.stop is not accepted over the public RPC. An idle thread
#                             has nothing to stop: one line on stderr, exit 0, nothing sent.
#                             Exit 5 if the thread is not in the shell.
#   archive <id>              V1: dispatch thread.archive. V2: refused (exit 7) after the probe
#                             and before any other request: thread.archive has no server-side
#                             idle guard (it ends a live run as failed and cancels queued runs,
#                             probe b16, b17), and a run or wake landing after the client's last
#                             read would meet it unguarded. Use settle, which the server itself
#                             refuses while a run is active, a message is queued or an approval
#                             is pending. Re-enabling waits on a server-side guard.
#   dispatch <json>           V1: POST a raw ClientOrchestrationCommand JSON. V2: refused
#                             (exit 7). Its only callers are V1 procedures (thread.create plus
#                             thread.turn.start, project.create) whose shapes V2 rejects at
#                             decode, and a raw pass-through would skip the archived-thread,
#                             idle and '/' guards. Use send, compact, stop or settle.
#   message-id <id> <text...> print the messageId a V2 `send` of <text> to <id> mints under the
#                             current OPS_T3_CALLER and OPS_T3_COMMAND_KEY, from the same
#                             function send uses (lib/t3_api_v2.py command_ids). No request, no
#                             protocol probe. OPS_T3_COMMAND_KEY is required (exit 2): without
#                             it send mints a random key, so no id printed here could match. A
#                             text send would refuse exits 10. WHY: a caller that must later find
#                             its own message (a pause, cancelled from the queue at resume) mints
#                             a fresh key, records this id, then sends with the
#                             same key; the id is known even when the send's outcome is not (exit
#                             4). A V1 send mints a random UUID instead, which nothing can predict.
#   queued-cancel <id> <message-id>
#                             V2 only (exit 8 on V1). Remove from <id>'s queue the run that carries
#                             <message-id> (its userMessageId), and nothing else: reads /bounded
#                             (exit 5 for an unknown thread), then for each run carrying that
#                             message whose status is queued, dispatches queued-run.cancel {runId}
#                             (probe a39) with a fresh commandId, like stop and settle. A run that
#                             already started or ended is left alone, and the server refuses the
#                             cancel for a run that is not queued (exit 11), so one that starts
#                             between the read and the dispatch is not touched either. Refused
#                             (exit 10, nothing sent) when that queued message is not a harness send
#                             (creationSource other than 'server') or /bounded does not show it:
#                             a person's queued message is never removed here. Never queue.resume.
#                             Prints one line per run carrying the message, "cancelled <run-id>
#                             <server answer>" or "not-queued <run-id> <status>", or "none" when no
#                             run carries it (the message never landed). Stops at the first failed
#                             cancel with its code. WHY: a pause queued behind a run that then fails
#                             stays held after the resume (probe a36, a32, a45),
#                             and only its sender can prove which queued run is its own, by the
#                             messageId it minted (message-id above).
#   server-busy               V2 only (exit 8 on V1): the server-wide busy verdict as JSON
#                             {idle, busyThreadIds, reasons, threadsChecked, boundedReads,
#                             heldQueuesChecked}: the shell verdict of every root and subagent
#                             thread, plus /bounded for each thread the shell calls idle, so a
#                             held queue counts. The shell's serverIdleVerdict cannot see one
#                             (it says heldQueuesChecked false).
#   shell                     GET /api/orchestration/shell: the live thread list with
#                             per-thread session, backgroundLiveness and pending-request
#                             flags (raw JSON on V1, V1-shaped on V2). It OMITS archived
#                             and deleted threads (only the V1 `snapshot` lists those), so
#                             a thread absent here is archived, deleted, or never existed.
#   settle <id>               dispatch thread.settle, but ONLY when the thread is idle
#                             (see IDLE below); otherwise print a refusal and exit 9.
#                             An already-settled thread is a no-op (exit 0, nothing sent).
#   settle-when-idle <id> [--timeout <sec>]
#                             launch a detached waiter (setsid, so it outlives the
#                             caller) and return at once. The waiter polls `shell` until
#                             the thread has been idle on two consecutive reads, then
#                             dispatches thread.settle, and logs every decision to
#                             ${OPS_STATE_DIR:-~/.local/state/ops}/t3-settle-when-idle.log.
#                             Default timeout 1800s; at the deadline it exits WITHOUT
#                             settling. It also exits without settling when the thread
#                             gets a new user message after the waiter started (the
#                             operator is still talking to it, so it is not done), or
#                             when the thread is gone. It only ever names the one id it
#                             was launched with. Refuses (exit 5) when the thread is not
#                             live at launch. A session that closes itself uses this on
#                             its OWN thread, then ends its turn; the settle lands after.
#                             V2: an idle shell read is confirmed against /bounded before it
#                             counts; "a new user message" means one whose creationSource is
#                             not 'server' (read from /bounded, because the RPC records every
#                             send as createdBy user): a harness send (a wake, a resume) does
#                             not end the wait, it only resets the idle count. Each settle
#                             attempt has a fresh commandId; after three server refusals the
#                             waiter stops without settling (exit 11 in its log).
#                             Any other settle failure (transport after the one same-id
#                             retry, a bad answer, a decode defect, no token) ends the
#                             waiter without minting another commandId (exit 4, 6, 12, 3).
#
# IDLE: a thread is idle only when ALL hold: session status is not starting/running,
# no activeTurnId, latestTurn is not running, no pending approval or user-input
# request, and backgroundLiveness is empty. The last clause is the one that matters:
# a session `ready` with backgroundLiveness `working` or `monitoring` has background
# lanes or monitors alive, and a settle stops the provider session, which KILLS them.
# What the server itself blocks (T3 0.0.42's thread.settle decider, read from its
# bundle): a session starting or running, a pending request, and a queued
# turn start. It never looks at backgroundLiveness, and it ALLOWS a settle while a
# message-mode user-input request is pending. So it would happily kill those lanes
# and monitors or cut off an open question; this client is the guard, and it is
# deliberately stricter than the server.
#
# IDLE on V2 (lib/t3_api_v2.py idle_verdict, one pure function over a V2 shell thread):
# busy if activityRunStatus is non-null, status is preparing, queued, starting, running
# or waiting (or a status this client does not know), activeRunId is set,
# pendingRuntimeRequest is non-null, pendingBackgroundTasks is non-empty (any kind) or
# unreadable, a user message under 120 s old has no run yet, or a subagent child thread
# of it is busy. status is the latest run's status, so 'completed' is normal and only
# the other fields say whether background work is alive. T3 0.1.0's thread.settle
# refuses only an active run, a queued message or a pending approval; it never reads
# pendingBackgroundTasks, and settle and archive both detach the provider session. A
# pull-request watch puts a kind 'monitor' task in pendingBackgroundTasks for as long
# as the watch lasts, so a watched thread reads busy for settle the whole time: the
# safe direction, and its reason names the watch.
# The write path (settle, the settle waiter, server-busy) adds the thread's
# /bounded projection to the same function: busy for any run with status queued, a run
# in an active status, a run status this client does not know, or a runtime request that
# is not resolved, expired or cancelled. WHY: after a run fails or is stopped with
# holdQueue true, the runs behind it stay queued and never start, and the shell then shows
# only the terminal run (status failed or interrupted) with no queue field; settle refuses
# such a thread but archive cancels its queue silently. A runtime request can stay pending
# after an interrupt (stale): it still reads busy, the safe direction. An idle shell
# reading is never acted on until /bounded confirms it.
#
# ENV OVERRIDES:
#   OPS_T3_TOKEN_FILE  token path       (default ~/.config/ops/t3-harness.token)
#   OPS_T3_BASE        server origin    (default from server-runtime.json .origin)
#   T3CODE_HOME           T3 state root    (default ~/.t3)
#   OPS_T3_DRY=1       print the METHOD, PATH and JSON body of any MUTATING
#                         request (POST /dispatch) to stdout and send NOTHING;
#                         `send` also SKIPS its runtimeMode snapshot read in dry mode
#                         (defaults to full-access), so a dry send makes no request
#                         beyond the one protocol probe (a GET). On V2 a dry write prints
#                         "WS orchestration.dispatchCommand" and the command JSON, and
#                         still makes the reads its guards need (/bounded for send and
#                         compact, the shell and /bounded for settle, the shell for stop);
#                         archive refuses before any of them.
#                         Read subcommands still execute. Used by the tests and by
#                         Read subcommands still execute. Used by the tests.
#                         `settle` still reads the shell to
#                         checks the thread, prints what it would launch, and starts
#                         no waiter.
#   OPS_T3_CALLER      V2 command ids: the caller name, default t3-api ([A-Za-z0-9._-],
#                         at most 40 characters).
#   OPS_T3_COMMAND_KEY V2 command ids: the intent key ([A-Za-z0-9._:@+-], at most 80),
#                         default a fresh random key per invocation. Set it when one
#                         intent can fire twice (a timer wake: its fire time), so the
#                         second fire replays the first's receipt instead of sending again.
#                         A refused command's id is spent: after a refusal, use a new key.
#   OPS_STATE_DIR      state root for the waiter log (default ~/.local/state/ops)
#   OPS_T3_POLL_SECONDS  waiter poll interval in seconds: default 5, a number is clamped
#                         into 1..60 (0.001 would near-spin the server; 3600 would hold the
#                         waiter far past its timeout), a non-number falls back to 5
#   OPS_T3_POLL_FLOOR_MS the clamp's lower bound in ms, for tests: default 1000; whole
#                         ms from 50 to 1000 are honoured, anything else keeps 1000, so a
#                         stray setting can never raise the floor or spin the server. The
#                         settle tests drive scripted threads that advance one step per
#                         read, and at a 1 s floor that suite spent about 80 s waiting.
#   OPS_T3_HTTP_TIMEOUT  hard cap per request, seconds (default 30), and
#   OPS_T3_CONNECT_TIMEOUT  connect cap (default 5). Every call here is a short
#                         request and response (a snapshot read or one dispatch); nothing
#                         streams or long-polls, so nothing is exempt. A hung server fails
#                         the call (exit 4, "transport error") instead of hanging the
#                         caller, which matters to a session that settles itself: its
#                         launcher runs inside that session's last tool call. On V2 the
#                         WebSocket call has the
#                         same cap per attempt (two attempts at most, 1 s apart).
#
# EXIT CODES: 0 ok | 2 usage | 3 no token | 4 HTTP/transport error (status + first
#   300 bytes of the body to stderr), a refused WebSocket upgrade, a WebSocket call lost
#   twice, or a local read error (the V2 state db, the lib/ helpers) | 5 not found | 6 bad
#   answer: not JSON, HTML, or not the shape this client expects (one line to stderr) |
#   7 dispatch or archive refused on a protocol-2 server | 8 the server reports an
#   orchestration protocol this client does not speak, or one a V2-only subcommand
#   (server-busy, queued-cancel) cannot use | 9 refused by guard, the thread is
#   not idle (settle; the V1 code, kept) | 10 refused by guard, a write this client never
#   sends (an archived or deleted thread, an empty text, a text starting with '/', a cancel
#   of a queued message that is not a harness send) |
#   11 refused by server: an Exit Failure with a Fail cause (the commandId is spent) |
#   12 the server could not decode the command: an Exit Failure with a Die cause (no
#   receipt; a client defect).
#
# ID FORMAT: makeEntityId in the 0.0.38 server bundle is
# TrimmedNonEmptyString.pipe(brand(...)): it accepts any non-empty trimmed
# string, and every real entity id in T3 (threads, sessions, resume cursors) is a
# UUID, so this helper mints UUIDs for commandId and messageId on V1. On V2 the ids are
# deterministic strings (WRITES ON V2); 0.1.0 accepts non-UUID ids (probe c11, c13).
set -uo pipefail

T3CODE_HOME="${T3CODE_HOME:-$HOME/.t3}"
TOKEN_FILE="${OPS_T3_TOKEN_FILE:-$HOME/.config/ops/t3-harness.token}"
RUNTIME_JSON="$T3CODE_HOME/userdata/server-runtime.json"
STATE_SQLITE="$T3CODE_HOME/userdata/state.sqlite"
STATEV2_SQLITE="$T3CODE_HOME/userdata/statev2.sqlite"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
LIB="$(dirname "$SELF")/lib/t3_api_v2.py"
WSLIB="$(dirname "$SELF")/lib/t3_ws.py"
STATE_DIR="${OPS_STATE_DIR:-$HOME/.local/state/ops}"
WAITER_LOG="$STATE_DIR/t3-settle-when-idle.log"
ENV_PATH="/.well-known/t3/environment"
# The server's orchestration protocol, probed once per invocation (detect_protocol).
T3_PROTO=""
# The status code of the last http_to call in this shell (the probe reads it for 404).
HTTP_CODE=""

# Private scratch dir for the curl -K token config + response bodies. mktemp -d is
# 0700; the config file inside is 0600. Removed on EXIT so the token never lingers.
_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$_TMPDIR"' EXIT

die_usage() { echo "t3-api: $*" >&2; exit 2; }

resolve_base() {
  if [ -n "${OPS_T3_BASE:-}" ]; then printf '%s\n' "$OPS_T3_BASE"; return 0; fi
  [ -f "$RUNTIME_JSON" ] || { echo "t3-api: no server-runtime.json at $RUNTIME_JSON and OPS_T3_BASE unset" >&2; return 4; }
  python3 - "$RUNTIME_JSON" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1]))["origin"])
except Exception as e:
    sys.stderr.write("t3-api: cannot read origin from server-runtime.json: %s\n" % e)
    sys.exit(4)
PY
}

# http_to FILE METHOD PATH [BODY] -> one request; the response body lands in FILE and
# nothing goes to stdout. Sets HTTP_CODE in the calling shell. The token is written ONLY
# into the 0600 -K config file, never onto argv or stdout. Every 2xx answer must pass
# the fail-loud check (a JSON object, not HTML; see FAIL LOUD in the header). On a V2
# server every request except the protocol probe carries x-t3-orchestration-protocol: 2.
# HTTP_QUIET_404=1 suppresses the error line for a 404 (the probe expects one from a
# server older than the environment endpoint).
# Returns: 3 no token, 4 HTTP/transport error, 6 not a JSON object or HTML.
http_to() {
  local file="$1" method="$2" path="$3" body="${4:-}"
  HTTP_CODE=""
  [ -f "$TOKEN_FILE" ] || { echo "t3-api: token file not found: $TOKEN_FILE" >&2; return 3; }
  local base; base="$(resolve_base)" || return 4
  local cfg="$_TMPDIR/curl.cfg" bodyfile="" rc=0
  chmod 700 "$_TMPDIR"
  # curl config-file form of --header keeps the token out of argv (ps-visible).
  # umask 077 so the config file is 0600 from creation (no pre-chmod window); the
  # parent _TMPDIR is already 0700.
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TOKEN_FILE")" > "$cfg" )
  # -w prints the status and the content type, tab-separated, for the fail-loud check.
  local -a args=( -sS -K "$cfg" -o "$file" -w '%{http_code}\t%{content_type}' -X "$method"
                  --max-time "${OPS_T3_HTTP_TIMEOUT:-30}" --connect-timeout "${OPS_T3_CONNECT_TIMEOUT:-5}" )
  if [ "$T3_PROTO" = 2 ] && [ "$path" != "$ENV_PATH" ]; then
    args+=( -H 'x-t3-orchestration-protocol: 2' )
  fi
  if [ "$method" = "POST" ]; then
    bodyfile="$_TMPDIR/req.body"
    printf '%s' "$body" > "$bodyfile"
    args+=( -H 'Content-Type: application/json' --data-binary "@$bodyfile" )
  fi
  local w code ctype
  if w="$(curl "${args[@]}" "$base$path" 2>/dev/null)"; then
    code="${w%%$'\t'*}"; ctype=""; [[ "$w" == *$'\t'* ]] && ctype="${w#*$'\t'}"
    HTTP_CODE="$code"
    if ! [[ "$code" =~ ^[0-9]+$ ]] || [ "$code" -ge 400 ]; then
      if ! { [ "${HTTP_QUIET_404:-0}" = 1 ] && [ "$code" = 404 ]; }; then
        # A refusal can echo the bearer. Mask its value before printing, including
        # one that crosses the 300-byte diagnostic boundary, without exposing the
        # token on argv or reading an unbounded error body into memory.
        python3 -I - "$TOKEN_FILE" "$file" "$method" "$path" "${code:-none}" <<'PY' >&2
import sys
try:
    with open(sys.argv[1], "rb") as f:
        token = f.read().rstrip(b"\n")  # same trailing-newline rule as $(cat ...)
    with open(sys.argv[2], "rb") as f:
        body = f.read(300 + len(token))
except OSError:
    print("t3-api: HTTP %s (response withheld: cannot read diagnostic safely)" % sys.argv[5])
else:
    # Keep lookahead out of the output. Merely replacing then truncating can
    # expose an incomplete token at the end of that lookahead after replacements
    # shorten a response containing several copies of the token.
    crossing = body.find(token, max(0, 301 - len(token))) if token else -1
    body = body[:crossing] + b"[redacted]" if 0 <= crossing < 300 else body[:300]
    output = ("t3-api: HTTP %s for %s %s\n" % (sys.argv[5], sys.argv[3], sys.argv[4])).encode() + body + b"\n"
    if token:
        output = output.replace(token, b"[redacted]")
    sys.stdout.buffer.write(output)
PY
      fi
      rc=4
    elif ! python3 -I "$LIB" check-json "$file" "$ctype" "$method $path (HTTP $code)"; then
      rc=6
    fi
  else
    echo "t3-api: transport error calling $method $path (server down, or no answer within ${OPS_T3_HTTP_TIMEOUT:-30}s)" >&2
    rc=4
  fi
  rm -f "$cfg"
  return $rc
}

# http METHOD PATH [BODY] -> response body on stdout for reads. Mutations (POST)
# under OPS_T3_DRY=1 print "METHOD PATH\n<body>" and send nothing.
# Returns: 3 no token, 4 HTTP/transport error, 6 not a JSON object or HTML.
http() {
  local method="$1" path="$2" body="${3:-}" out="$_TMPDIR/resp.body" rc
  if [ "$method" = "POST" ] && [ "${OPS_T3_DRY:-0}" = "1" ]; then
    printf '%s %s\n' "$method" "$path"
    printf '%s\n' "$body"
    return 0
  fi
  http_to "$out" "$method" "$path" "$body"; rc=$?
  [ "$rc" -eq 0 ] && cat "$out"
  return $rc
}

# detect_protocol: read the server's orchestration protocol once per invocation into
# T3_PROTO (1 or 2). A 404 for the whole route is a server older than the endpoint,
# which is V1 by the "absent means V1" rule (T3 0.0.45 declares the key optional and
# sends 1). Returns the probe's error code otherwise: 3, 4, 6, or 8 for a protocol this
# client does not speak. Must run in the main shell so the cache sticks.
detect_protocol() {
  [ -n "$T3_PROTO" ] && return 0
  [ -f "$LIB" ] || { echo "t3-api: helper missing: $LIB (it ships beside this script, in lib/)" >&2; return 4; }
  local f="$_TMPDIR/environment.json" rc v
  HTTP_QUIET_404=1 http_to "$f" GET "$ENV_PATH"; rc=$?
  if [ "$rc" -eq 4 ] && [ "$HTTP_CODE" = 404 ]; then T3_PROTO=1; return 0; fi
  [ "$rc" -eq 0 ] || return "$rc"
  v="$(python3 -I "$LIB" protocol "$f")" || return $?
  case "$v" in
    1|2) T3_PROTO="$v" ;;
    *) echo "t3-api: protocol probe printed '$v'" >&2; return 6 ;;
  esac
}

need_protocol() { detect_protocol || exit $?; }

# refuse_on_v2 <subcommand> <why>: exit 7 on a protocol-2 server, for a subcommand this
# client does not send on V2 (dispatch, archive; see SUBCOMMANDS). OPS_T3_DRY=1 does not
# change this.
refuse_on_v2() {
  [ "$T3_PROTO" = 2 ] || return 0
  echo "t3-api: $1 refused on this T3 server (orchestration protocol 2): $2" >&2
  exit 7
}

# ---- protocol 2 writes (WRITES ON V2 in the header) ------------------------------------------

# v2_bounded <thread-id> <file> [quiet]: GET the thread's /bounded into <file>. Returns 5
# when the server does not know the thread (one line on stderr unless quiet), else
# http_to's code.
v2_bounded() {
  local q rc
  q="$(python3 -I "$LIB" quote "$1")" || return 4
  HTTP_QUIET_404=1 http_to "$2" GET "/api/orchestration/threads/$q/bounded"; rc=$?
  if [ "$rc" -eq 4 ] && [ "$HTTP_CODE" = 404 ]; then
    [ -n "${3:-}" ] || echo "t3-api: thread $1 not found on the server (GET /bounded answered 404); nothing sent" >&2
    return 5
  fi
  return "$rc"
}

# v2_dispatch <command.json>: send one command over the WebSocket (lib/t3_ws.py), or under
# OPS_T3_DRY=1 print it and send nothing. Prints the Success value; returns t3_ws.py's
# code (0, 3, 4, 6, 11, 12).
v2_dispatch() {
  if [ "${OPS_T3_DRY:-0}" = "1" ]; then
    printf 'WS orchestration.dispatchCommand\n'; cat "$1"; printf '\n'
    return 0
  fi
  [ -f "$TOKEN_FILE" ] || { echo "t3-api: token file not found: $TOKEN_FILE" >&2; return 3; }
  [ -f "$WSLIB" ] || { echo "t3-api: helper missing: $WSLIB (it ships beside this script, in lib/)" >&2; return 4; }
  local base; base="$(resolve_base)" || return 4
  # The token FILE path is on argv; the token itself is read inside the helper.
  python3 -I "$WSLIB" call "$base" "$TOKEN_FILE" orchestration.dispatchCommand "$1"
}

# v2_message <thread-id> <text>: the guarded message.dispatch behind send and compact. The
# text guard runs before any read; the archived guard reads /bounded.
v2_message() {
  local id="$1" tf="$_TMPDIR/message.txt" bf="$_TMPDIR/bounded.json" pf="$_TMPDIR/command.json"
  printf '%s' "$2" > "$tf"
  python3 -I "$LIB" text-guard "$tf" || return $?
  v2_bounded "$id" "$bf" || return $?
  python3 -I "$LIB" target-check "$bf" "$id" || return $?
  python3 -I "$LIB" command message "$id" "$tf" > "$pf" || return $?
  v2_dispatch "$pf"
}

# v2_verdict <thread-id> <settle|archive> -> "<verdict>|<reasons>|<stamp>" (verdict idle,
# busy, settled, missing). The shell is read first; an idle shell reading is only
# "unconfirmed" until the thread's /bounded runs say no queue is held behind a failed or
# stopped run, so /bounded is read only then (it can be half a megabyte on a long thread).
v2_verdict() {
  local sf="$_TMPDIR/shell.json" bf="$_TMPDIR/bounded.json" v rc
  http_to "$sf" GET /api/orchestration/shell || return $?
  v="$(python3 -I "$LIB" verdict "$sf" "$1" "$2")" || return $?
  case "$v" in unconfirmed\|*) ;; *) printf '%s\n' "$v"; return 0 ;; esac
  v2_bounded "$1" "$bf" quiet; rc=$?
  if [ "$rc" -eq 5 ]; then printf 'missing||\n'; return 0; fi   # gone between the two reads
  [ "$rc" -eq 0 ] || return "$rc"
  python3 -I "$LIB" verdict "$sf" "$1" "$2" "$bf"
}

cmd_token() {
  [ -f "$TOKEN_FILE" ] || { echo "t3-api: token file not found: $TOKEN_FILE" >&2; return 3; }
  printf '%s\n' "$TOKEN_FILE"
}

cmd_base() { resolve_base; }

# v2_shell_as <shell|snapshot>: the V2 shell, V1-shaped (see V1-SHAPE MAPPING).
v2_shell_as() {
  local sf="$_TMPDIR/shell.json"
  http_to "$sf" GET /api/orchestration/shell || return $?
  python3 -I "$LIB" v1-shell "$sf" "$1"
}

cmd_snapshot() {
  if [ "$T3_PROTO" = 2 ]; then v2_shell_as snapshot; return $?; fi
  local b; b="$(http GET /api/orchestration/snapshot)" || return $?
  printf '%s\n' "$b"
}

cmd_thread() {
  local id="$1" lim="${2:-}" path
  if [ "$T3_PROTO" = 2 ]; then
    # /bounded carries no run state, so the shell is read too and laid over it.
    local q bf="$_TMPDIR/bounded.json" sf="$_TMPDIR/shell.json"
    q="$(python3 -I "$LIB" quote "$id")" || return 4
    http_to "$bf" GET "/api/orchestration/threads/$q/bounded" || return $?
    http_to "$sf" GET /api/orchestration/shell || return $?
    python3 -I "$LIB" v1-thread "$bf" "$sf" "$id"
    return $?
  fi
  path="/api/orchestration/threads/$id"
  [ -n "$lim" ] && path="$path?turnLimit=$lim"
  local b; b="$(http GET "$path")" || return $?
  printf '%s\n' "$b"
}

# Provider session id -> T3 thread id. The read-only SQLite runtime table stores
# Claude IDs in resume_cursor_json.resume and Codex IDs in .threadId. Match the
# provider as well as the field, and refuse ambiguous mappings. On V2 the lookup is
# lib/t3_api_v2.py thread-for-session over statev2.sqlite (see SUBCOMMANDS).
cmd_thread_for_session() {
  local sid="$1"
  if [ "$T3_PROTO" = 2 ]; then
    python3 -I "$LIB" thread-for-session "$STATEV2_SQLITE" "$sid"
    return $?
  fi
  [ -f "$STATE_SQLITE" ] || { echo "t3-api: state db not found: $STATE_SQLITE" >&2; return 5; }
  python3 - "$STATE_SQLITE" "$sid" <<'PY'
import json, sys, sqlite3
db, sid = sys.argv[1], sys.argv[2]
con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
try:
    matches = set()
    for tid, provider, cur in con.execute("SELECT thread_id, provider_name, resume_cursor_json FROM provider_session_runtime"):
        if not cur:
            continue
        try:
            rc = json.loads(cur)
        except Exception:
            continue
        if not isinstance(rc, dict):
            continue
        if (provider == "claudeAgent" and rc.get("resume") == sid) or (provider == "codex" and rc.get("threadId") == sid):
            matches.add(tid)
finally:
    con.close()
# Fail closed on ambiguity: dispatching /compact to the wrong live thread is
# catastrophic, so more than one match must never silently resolve to one.
if len(matches) > 1:
    sys.stderr.write("t3-api: session %s maps to %d threads (%s); refusing to guess\n" % (sid, len(matches), ",".join(sorted(matches))))
    sys.exit(5)
if len(matches) == 1:
    print(next(iter(matches)))
    sys.exit(0)
sys.exit(5)
PY
}

cmd_active_turn() {
  local id="$1"
  if [ "$T3_PROTO" = 2 ]; then
    local sf="$_TMPDIR/shell.json"
    http_to "$sf" GET /api/orchestration/shell || return $?
    python3 -I "$LIB" active-turn "$sf" "$id"
    return $?
  fi
  local b; b="$(http GET /api/orchestration/snapshot)" || return $?
  # Pass the snapshot as a file (not a pipe): `python3 -` reads its program from
  # the heredoc on stdin, so a piped body would be swallowed as program source.
  local snapf="$_TMPDIR/snapshot.json"; printf '%s' "$b" > "$snapf"
  python3 - "$snapf" "$id" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tid = sys.argv[2]
for t in d.get("threads", []):
    if t.get("id") == tid:
        s = t.get("session") or {}
        atid = s.get("activeTurnId")
        print(atid if atid is not None else "null")
        sys.exit(0)
sys.exit(5)
PY
}

cmd_start() {
  local id="$1" text="$2" message_id="${3:-}"
  # runtimeMode = the thread's current session.runtimeMode from the snapshot, else
  # full-access. Skipped in dry mode so a dry send issues zero requests.
  local rmode="full-access"
  if [ "${OPS_T3_DRY:-0}" != "1" ]; then
    local snap; snap="$(http GET /api/orchestration/snapshot)" || return $?
    # File, not pipe: see cmd_active_turn: `python3 -` reads its program from stdin.
    local snapf="$_TMPDIR/snapshot.json"; printf '%s' "$snap" > "$snapf"
    rmode="$(python3 - "$snapf" "$id" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tid = sys.argv[2]
rmode = "full-access"
for t in d.get("threads", []):
    if t.get("id") == tid:
        s = t.get("session") or {}
        v = s.get("runtimeMode")
        if v:
            rmode = v
        break
print(rmode)
PY
)"
  fi
  local body
  body="$(python3 - "$id" "$rmode" "$text" "$message_id" <<'PY'
import json, sys, uuid, datetime
tid, rmode, text, message_id = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc)
created = now.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (now.microsecond // 1000)
cmd = {
    "type": "thread.turn.start",
    "commandId": str(uuid.uuid4()),
    "threadId": tid,
    "message": {"messageId": message_id or str(uuid.uuid4()), "role": "user", "text": text, "attachments": []},
    "runtimeMode": rmode,
    "interactionMode": "default",
    "createdAt": created,
}
print(json.dumps(cmd))
PY
)"
  http POST /api/orchestration/dispatch "$body"
}

cmd_send() {
  local id="$1"; shift
  if [ "$T3_PROTO" = 2 ]; then v2_message "$id" "$*"; return $?; fi
  cmd_start "$id" "$*"
}

cmd_compact() {
  local mid response
  if [ "$T3_PROTO" = 2 ]; then
    response="$(v2_message "$1" "/compact")" || return $?
    if [ "${OPS_T3_DRY:-0}" = "1" ]; then printf '%s\n' "$response"; return 0; fi
    # The messageId is the one compact-status matches; it was minted into the command.
    python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["messageId"])' "$_TMPDIR/command.json" || return 4
    return 0
  fi
  mid="$(python3 -c 'import uuid; print(uuid.uuid4())')" || return 4
  response="$(cmd_start "$1" "/compact" "$mid")" || return $?
  if [ "${OPS_T3_DRY:-0}" = "1" ]; then printf '%s\n' "$response"; else printf '%s\n' "$mid"; fi
}

cmd_compact_status() {
  local detail
  if [ "$T3_PROTO" = 2 ]; then
    local bf="$_TMPDIR/bounded.json"
    v2_bounded "$1" "$bf" || return $?
    python3 -I "$LIB" compact-status "$bf" "$1" "$2"
    return $?
  fi
  detail="$(cmd_thread "$1")" || return $?
  printf '%s' "$detail" | python3 -c '
import json,sys
d=json.load(sys.stdin); thread=d.get("thread") or {}
if thread.get("id") != sys.argv[1]: sys.exit(5)
matched=[a for a in thread.get("activities", []) if (a.get("payload") or {}).get("requestId")==sys.argv[2]]
if any(a.get("kind")=="provider.turn.start.failed" for a in matched): print("failed")
elif any(a.get("kind")=="context-compaction" and (a.get("payload") or {}).get("state")=="compacted" for a in matched): print("completed")
else: print("pending")
' "$1" "$2"
}

cmd_stop() {
  local id="$1"
  local body
  if [ "$T3_PROTO" = 2 ]; then
    local sf="$_TMPDIR/shell.json" pf="$_TMPDIR/command.json" out run why
    http_to "$sf" GET /api/orchestration/shell || return $?
    out="$(python3 -I "$LIB" stop-target "$sf" "$id")" || return $?
    run="${out%%|*}"; why="${out#*|}"
    if [ -z "$run" ]; then
      echo "t3-api: thread $id has nothing to stop ($why); nothing sent" >&2
      return 0
    fi
    python3 -I "$LIB" command interrupt "$id" "$run" > "$pf" || return $?
    v2_dispatch "$pf"
    return $?
  fi
  body="$(python3 - "$id" <<'PY'
import json, sys, uuid, datetime
tid = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
created = now.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (now.microsecond // 1000)
print(json.dumps({"type": "thread.session.stop", "commandId": str(uuid.uuid4()), "threadId": tid, "createdAt": created}))
PY
)"
  http POST /api/orchestration/dispatch "$body"
}

cmd_archive() {
  local id="$1"
  local body
  # V2: refused (exit 7) before any read or dispatch. WHY: thread.archive has NO server
  # guard. It ends the live run as failed, cancels every queued run and detaches the
  # session, which ends background work (probe b16, b17). A client-side idle verdict cannot
  # close that gap: a run or a timer wake that lands after the last read and before the
  # dispatch meets an unguarded archive. thread.settle is refused by the server itself for
  # an active run, a queued message or a pending approval, so settle is the V2 way to put a
  # thread down. Re-enable only when the server guards archive; the idle verdict and the
  # archive command shape in lib/t3_api_v2.py stay, the verdict because settle and its
  # waiter use it.
  refuse_on_v2 archive "thread.archive has no server-side idle guard (it ends a live run as failed and cancels queued runs, and a run or wake that lands after this client's last read would meet it unguarded); use settle, which the server refuses while a run is active, a message is queued or an approval is pending. Re-enabling waits on a server-side guard"
  body="$(python3 - "$id" <<'PY'
import json, sys, uuid
tid = sys.argv[1]
print(json.dumps({"type": "thread.archive", "commandId": str(uuid.uuid4()), "threadId": tid}))
PY
)"
  http POST /api/orchestration/dispatch "$body"
}

cmd_shell() {
  if [ "$T3_PROTO" = 2 ]; then v2_shell_as shell; return $?; fi
  local b; b="$(http GET /api/orchestration/shell)" || return $?
  printf '%s\n' "$b"
}

# shell_verdict <thread-id> -> "<verdict>|<reason>|<latestUserMessageAt>" on stdout.
# verdict: idle | busy | settled | missing. See IDLE in the header for the rule and
# why backgroundLiveness is part of it. The shell omits archived and deleted threads,
# so `missing` covers them too. The third field is the user-message stamp the
# waiter compares against its launch baseline.
shell_verdict() {
  # V2: the shell plus, when the shell reads idle, the thread's /bounded runs (v2_verdict).
  if [ "$T3_PROTO" = 2 ]; then v2_verdict "$1" settle; return $?; fi
  local b; b="$(http GET /api/orchestration/shell)" || return $?
  # File, not pipe: `python3 -` reads its program from the heredoc on stdin.
  local f="$_TMPDIR/shell.json"; printf '%s' "$b" > "$f"
  python3 - "$f" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
t = next((x for x in d.get("threads", []) if x.get("id") == sys.argv[2]), None)
if t is None:
    print("missing||"); sys.exit(0)
stamp = t.get("latestUserMessageAt") or ""
if t.get("archivedAt"):
    print("missing||" + stamp); sys.exit(0)
if t.get("settledAt"):
    print("settled||" + stamp); sys.exit(0)
s = t.get("session") or {}
why = []
if t.get("hasPendingApprovals"): why.append("a request is waiting for approval")
if t.get("hasPendingUserInput"): why.append("a question is waiting for an answer")
if s.get("status") in ("starting", "running"): why.append("the session is %s" % s["status"])
if s.get("activeTurnId"): why.append("a turn is active")
if (t.get("latestTurn") or {}).get("state") == "running": why.append("the latest turn is running")
if t.get("backgroundLiveness"): why.append("background work is %s" % t["backgroundLiveness"])
print(("busy|" + "; ".join(why) if why else "idle|") + "|" + stamp)
PY
}

# settle_dispatch <thread-id> [<attempt>]: T3 0.0.42's thread.settle is exactly {type,
# commandId, threadId}, no createdAt. On V2 the same three
# keys go over the WebSocket; <attempt> (the waiter's count) makes every attempt's commandId
# new, because a refused settle's id is spent (probe a42, a46).
settle_dispatch() {
  local body
  if [ "$T3_PROTO" = 2 ]; then
    local pf="$_TMPDIR/command.json"
    python3 -I "$LIB" command settle "$1" ${2:+--attempt "$2"} > "$pf" || return $?
    v2_dispatch "$pf"
    return $?
  fi
  body="$(python3 - "$1" <<'PY'
import json, sys, uuid
print(json.dumps({"type": "thread.settle", "commandId": str(uuid.uuid4()), "threadId": sys.argv[1]}))
PY
)" || return 4
  http POST /api/orchestration/dispatch "$body"
}

cmd_settle() {
  local id="$1" v verdict reason
  v="$(shell_verdict "$id")" || return $?
  IFS='|' read -r verdict reason _ <<< "$v"
  case "$verdict" in
    idle) settle_dispatch "$id" ;;   # V2: a server refusal exits 11
    settled) echo "t3-api: thread $id is already settled; nothing sent"; return 0 ;;
    missing) echo "t3-api: thread $id is not in the shell snapshot (archived, deleted, or unknown); nothing sent" >&2; return 5 ;;
    busy)
      echo "t3-api: refusing to settle thread $id: $reason. A settle stops the thread's session and kills any background lanes; nothing sent. Settle it when it is idle, or run: t3-api.sh settle-when-idle $id" >&2
      return 9 ;;
    *) echo "t3-api: unreadable shell verdict for thread $id: $v" >&2; return 4 ;;
  esac
}

waiter_log() {  # waiter_log <thread-id> <message...>; one line, UTC stamp, pid, thread
  local id="$1"; shift
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s pid=%s thread=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$id" "$*" >> "$WAITER_LOG"
}

cmd_settle_when_idle() {
  local id="" timeout=1800
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) [ $# -ge 2 ] || die_usage "--timeout needs a value"; timeout="$2"; shift 2 ;;
      -*) die_usage "settle-when-idle: unknown option $1" ;;
      *) [ -z "$id" ] || die_usage "settle-when-idle <thread-id> [--timeout <sec>]"; id="$1"; shift ;;
    esac
  done
  [ -n "$id" ] || die_usage "settle-when-idle <thread-id> [--timeout <sec>]"
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die_usage "--timeout must be a positive whole number of seconds, got: $timeout"
  # Usage errors first, then the server: the probe.
  need_protocol
  # Judge the thread now, in the foreground, so a bad id fails loudly to the caller
  # instead of inside a detached process nobody is reading. The user-message stamp
  # read here is the baseline the waiter compares against.
  local v verdict reason baseline
  v="$(shell_verdict "$id")" || return $?
  IFS='|' read -r verdict reason baseline <<< "$v"
  case "$verdict" in
    missing) echo "t3-api: thread $id is not live in the shell snapshot (archived, deleted, or unknown); no waiter started" >&2; return 5 ;;
    settled) echo "t3-api: thread $id is already settled; no waiter started"; return 0 ;;
  esac
  if [ "${OPS_T3_DRY:-0}" = "1" ]; then
    printf 'DRY settle-when-idle thread=%s timeout=%s state=%s baseline=%s (no waiter started)\n' "$id" "$timeout" "$verdict${reason:+ ($reason)}" "${baseline:--}"
    return 0
  fi
  mkdir -p "$STATE_DIR" || { echo "t3-api: cannot create $STATE_DIR" >&2; return 4; }
  # setsid -f: a new session, so the waiter survives the caller's exit and the
  # closing of its terminal or T3 turn. The token is never on this command line;
  # the worker reads the token file itself.
  setsid -f bash "$SELF" _settle-waiter "$id" "$timeout" "$baseline" >> "$WAITER_LOG" 2>&1 < /dev/null \
    || { echo "t3-api: could not start the waiter (setsid -f failed)" >&2; return 4; }
  printf 't3-api: waiter launched for thread %s (timeout %ss, now %s); log: %s\n' "$id" "$timeout" "$verdict" "$WAITER_LOG"
}

# now_ms: wall-clock milliseconds. EPOCHREALTIME (bash 5) keeps the deadline exact to the
# millisecond; SECONDS is the coarse fallback. The decimal separator is locale-dependent.
now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local t="${EPOCHREALTIME/[.,]/}"; echo $((t / 1000))
  else
    echo $((SECONDS * 1000))
  fi
}

# poll_ms <value>: the waiter's poll interval in ms. A number is clamped into 1..60 s
# (the lower bound is OPS_T3_POLL_FLOOR_MS when that is 50 to 1000); anything that
# is not a number is the 5 s default. Integer-only arithmetic: a huge value is capped
# by its length before it can overflow.
poll_ms() {
  local v="$1" ip fp ms floor="${OPS_T3_POLL_FLOOR_MS:-1000}"
  if ! [[ "$floor" =~ ^[0-9]{2,4}$ ]] || [ "$((10#$floor))" -lt 50 ] || [ "$((10#$floor))" -gt 1000 ]; then
    floor=1000
  fi
  floor=$((10#$floor))
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo 5000; return; }
  ip="${v%%.*}"; fp=""; [[ "$v" == *.* ]] && fp="${v#*.}"
  ip="${ip#"${ip%%[!0]*}"}"
  [ "${#ip}" -gt 3 ] && { echo 60000; return; }
  fp="${fp}000"; fp="${fp:0:3}"
  ms=$(( 10#${ip:-0} * 1000 + 10#$fp ))
  [ "$ms" -lt "$floor" ] && ms="$floor"
  [ "$ms" -gt 60000 ] && ms=60000
  echo "$ms"
}

# v2_operator_check <thread-id> <baseline> -> "operator|..." | "harness|..." | "unseen|..." |
# "none|": who wrote the user messages after <baseline> (lib/t3_api_v2.py operator_check).
v2_operator_check() {
  local bf="$_TMPDIR/bounded-operator.json"
  v2_bounded "$1" "$bf" quiet || return $?
  python3 -I "$LIB" operator-check "$bf" "$1" "$2"
}

# The detached worker. Exit: 0 settled or already settled | 4 gave up after repeated
# read failures, or (V2) a settle whose transport failed after its one same-id retry |
# 5 thread gone | 10 superseded by a new user message | 11 the server refused three
# settles (V2) | 2/3/6/12 (V2) a settle that failed on a bad caller or key, a missing
# token file, a bad RPC answer or a decode defect | 124 timeout.
# Every exit other than 0 leaves the thread unsettled; the log says why.
cmd_settle_waiter() {
  local id="$1" timeout="$2" baseline="$3"
  local poll; poll="$(poll_ms "${OPS_T3_POLL_SECONDS:-5}")"
  local need=2 idle=0 fails=0 v verdict="" reason="" stamp rc nap left oc detail attempt=0 refusals=0
  local deadline; deadline=$(( $(now_ms) + timeout * 1000 ))
  waiter_log "$id" "started timeout=${timeout}s poll=${poll}ms baseline=${baseline:--}"
  while :; do
    v="$(shell_verdict "$id")"; rc=$?
    if [ "$rc" -ne 0 ]; then
      idle=0  # Two idle reads separated by a failed read are not consecutive.
      fails=$((fails + 1))
      waiter_log "$id" "shell read failed (rc=$rc, $fails of 5 in a row)"
      if [ "$fails" -ge 5 ]; then waiter_log "$id" "giving up without settling: the shell endpoint kept failing"; return 4; fi
    else
      IFS='|' read -r verdict reason stamp <<< "$v"
      case "$verdict" in
        missing) waiter_log "$id" "thread is gone or archived; not settling"; return 5 ;;
        settled) waiter_log "$id" "already settled; done"; return 0 ;;
      esac
      # A user message after launch means the operator is still working in the
      # thread, so it is not done, whatever its session state says right now.
      # V2: the RPC records every send as createdBy user, so the stamp moves for harness
      # sends too; /bounded's creationSource tells them apart. Only creationSource
      # 'server' (this harness) is let through, and it restarts the idle count.
      if [ "$stamp" != "$baseline" ]; then
        if [ "$T3_PROTO" = 2 ]; then
          oc="$(v2_operator_check "$id" "$baseline")"; rc=$?
          if [ "$rc" -ne 0 ]; then
            fails=$((fails + 1))
            waiter_log "$id" "message read failed (rc=$rc, $fails of 5 in a row)"
            if [ "$fails" -ge 5 ]; then waiter_log "$id" "giving up without settling: the thread reads kept failing"; return 4; fi
            oc="retry|"
          fi
        else
          oc="operator|"
        fi
        detail="${oc#*|}"
        case "$oc" in
          harness\|*)
            waiter_log "$id" "new user message at ${stamp:--} is the harness's ($detail); still waiting"
            baseline="$stamp"; idle=0 ;;
          retry\|*) idle=0 ;;
          *)   # operator, unseen (a stamp change nothing explains), and every V1 change
            waiter_log "$id" "new user message at ${stamp:--} since launch (baseline ${baseline:--}${detail:+; $detail}); the thread is still in use, not settling"
            return 10 ;;
        esac
        verdict=busy
      fi
      # A successful shell read cannot erase a failed /bounded message read.
      # Reset only after every read required for this iteration has succeeded.
      [ "$rc" -eq 0 ] && fails=0
      if [ "$verdict" = idle ]; then idle=$((idle + 1)); else idle=0; fi
      # Never settle once the deadline has passed. The deadline is checked here, at the
      # last moment before the dispatch, because the read that got us here can land after
      # it: the old loop slept a whole poll, read idle twice, and settled at about 3 s on
      # a 1 s timeout.
      if [ "$idle" -ge "$need" ] && [ "$(now_ms)" -lt "$deadline" ]; then
        attempt=$((attempt + 1))
        settle_dispatch "$id" "$attempt" >/dev/null; rc=$?
        if [ "$rc" -eq 0 ]; then
          waiter_log "$id" "settled after $idle consecutive idle reads"
          return 0
        fi
        idle=0
        if [ "$T3_PROTO" = 2 ] && [ "$rc" -eq 11 ]; then
          # The server refused (its stderr line is in this log). That commandId is spent:
          # re-read state, and the next attempt has a fresh id. Never loop on refusals.
          refusals=$((refusals + 1))
          if [ "$refusals" -ge 3 ]; then
            waiter_log "$id" "settle was refused by the server $refusals times; giving up without settling"
            return 11
          fi
          waiter_log "$id" "settle was refused by the server (attempt $attempt); re-reading, the next attempt uses a fresh commandId"
        elif [ "$T3_PROTO" = 2 ]; then
          # The transport helper has already retried loss once with the same id.
          # An ambiguous outcome or a client defect must not mint another command.
          waiter_log "$id" "settle failed (rc=$rc); giving up without another commandId"
          return "$rc"
        else
          # The server disagreed with our read (for example a turn started between
          # the read and the dispatch). Keep waiting rather than exit.
          waiter_log "$id" "settle was rejected; still waiting"
        fi
      fi
    fi
    left=$(( deadline - $(now_ms) ))
    if [ "$left" -le 0 ]; then
      waiter_log "$id" "timed out after ${timeout}s without settling (last state: ${verdict:-unknown}${reason:+, $reason})"
      return 124
    fi
    # Nap the poll interval or the time left, whichever is shorter, so a long poll
    # cannot carry the waiter past its deadline.
    nap=$poll; [ "$left" -lt "$nap" ] && nap=$left
    sleep "$(printf '%d.%03d' $((nap / 1000)) $((nap % 1000)))"
  done
}

cmd_dispatch() { http POST /api/orchestration/dispatch "$1"; }

# message-id <thread-id> <text...>: the messageId `send` would mint (see SUBCOMMANDS). Pure:
# the same lib call send makes (v2_message), so the two can never disagree, and no request.
cmd_message_id() {
  local id="$1"; shift
  local tf="$_TMPDIR/message.txt" pf="$_TMPDIR/command.json"
  [ -n "${OPS_T3_COMMAND_KEY:-}" ] || die_usage "message-id needs OPS_T3_COMMAND_KEY: without it send mints a random key, so no id printed here could match the send"
  [ -f "$LIB" ] || { echo "t3-api: helper missing: $LIB (it ships beside this script, in lib/)" >&2; return 4; }
  printf '%s' "$*" > "$tf"
  python3 -I "$LIB" command message "$id" "$tf" > "$pf" || return $?
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["messageId"])' "$pf" || return 4
}

# queued-cancel <thread-id> <message-id> (V2): cancel the queued run(s) carrying that message,
# and nothing else (see SUBCOMMANDS). The /bounded read comes right before the dispatches; the
# plan (lib/t3_api_v2.py queued_cancel_plan) picks runs by exact userMessageId, queued only, and
# refuses a message that is not a harness send. Never sends queue.resume.
cmd_queued_cancel() {
  local id="$1" mid="$2"
  if [ "$T3_PROTO" != 2 ]; then
    echo "t3-api: queued-cancel needs orchestration protocol 2 (queued runs and queued-run.cancel); this server speaks protocol $T3_PROTO, which holds no queue" >&2
    return 8
  fi
  local bf="$_TMPDIR/bounded.json" pf="$_TMPDIR/command.json" plan act run status out rc
  v2_bounded "$id" "$bf" || return $?
  plan="$(python3 -I "$LIB" queued-cancel-plan "$bf" "$id" "$mid")" || return $?
  if [ -z "$plan" ]; then
    printf 'none\n'
    return 0
  fi
  while IFS='|' read -r act run status; do
    [ -n "$run" ] || continue
    if [ "$act" != cancel ]; then
      printf 'not-queued %s %s\n' "$run" "$status"
      continue
    fi
    # stdin is the plan this loop reads: no child may inherit it.
    python3 -I "$LIB" command cancel "$id" "$run" > "$pf" < /dev/null || return $?
    if [ "${OPS_T3_DRY:-0}" = "1" ]; then v2_dispatch "$pf" < /dev/null; continue; fi
    out="$(v2_dispatch "$pf" < /dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf 'cancelled %s %s\n' "$run" "$out"
  done <<< "$plan"
}

# server-busy (V2): the shell's verdict for every thread, plus /bounded for each thread the
# shell calls idle (the held-queue input). A thread that 404s between the two reads has
# left and is not counted; any other read failure fails the whole check (no partial ok).
cmd_server_busy() {
  if [ "$T3_PROTO" != 2 ]; then
    echo "t3-api: server-busy reads orchestration protocol 2 fields; this server speaks protocol $T3_PROTO (read the V1 shell instead)" >&2
    return 8
  fi
  local sf="$_TMPDIR/shell.json" dir="$_TMPDIR/server-busy" n=0 tid rc
  http_to "$sf" GET /api/orchestration/shell || return $?
  mkdir -p "$dir" && : > "$dir/index.tsv" || return 4
  local plan; plan="$(python3 -I "$LIB" server-busy-plan "$sf")" || return $?
  while IFS= read -r tid; do
    [ -n "$tid" ] || continue
    n=$((n + 1))
    printf '%s\t%s\n' "$n" "$tid" >> "$dir/index.tsv"
    v2_bounded "$tid" "$dir/$n.json" quiet; rc=$?
    if [ "$rc" -eq 5 ]; then rm -f "$dir/$n.json"; continue; fi
    [ "$rc" -eq 0 ] || return "$rc"
  done <<< "$plan"
  python3 -I "$LIB" server-busy "$sf" "$dir"
}

# The detached waiter probes on its own (it is a new process), and logs a failed probe
# instead of exiting silently into its log.
settle_waiter_entry() {
  local rc
  detect_protocol; rc=$?
  if [ "$rc" -ne 0 ]; then waiter_log "$1" "protocol probe failed (rc=$rc); not settling"; return "$rc"; fi
  cmd_settle_waiter "$@"
}

# Every subcommand except token, base, message-id and help talks to the server: usage errors exit 2
# before any request, then need_protocol probes once, then a write refuses on V2.
[ $# -ge 1 ] || die_usage "no subcommand (token|base|snapshot|shell|thread|thread-for-session|active-turn|send|message-id|compact|compact-status|stop|archive|settle|settle-when-idle|dispatch|server-busy|queued-cancel)"
sub="$1"; shift
case "$sub" in
  token)               cmd_token ;;
  base)                cmd_base ;;
  snapshot)            need_protocol; cmd_snapshot ;;
  thread)              [ $# -ge 1 ] || die_usage "thread <thread-id> [turnLimit]"; need_protocol; cmd_thread "$@" ;;
  thread-for-session)  [ $# -eq 1 ] || die_usage "thread-for-session <provider-session-id>"; need_protocol; cmd_thread_for_session "$1" ;;
  active-turn)         [ $# -eq 1 ] || die_usage "active-turn <thread-id>"; need_protocol; cmd_active_turn "$1" ;;
  compact)             [ $# -eq 1 ] || die_usage "compact <thread-id>"; need_protocol; cmd_compact "$1" ;;
  compact-status)      [ $# -eq 2 ] || die_usage "compact-status <thread-id> <message-id>"; need_protocol; cmd_compact_status "$1" "$2" ;;
  send)                [ $# -ge 2 ] || die_usage "send <thread-id> <text...>"; need_protocol; cmd_send "$@" ;;
  stop)                [ $# -eq 1 ] || die_usage "stop <thread-id>"; need_protocol; cmd_stop "$1" ;;
  archive)             [ $# -eq 1 ] || die_usage "archive <thread-id>"; need_protocol; cmd_archive "$1" ;;
  shell)               [ $# -eq 0 ] || die_usage "shell takes no arguments"; need_protocol; cmd_shell ;;
  settle)              [ $# -eq 1 ] || die_usage "settle <thread-id>"; need_protocol; cmd_settle "$1" ;;
  settle-when-idle)    cmd_settle_when_idle "$@" ;;
  _settle-waiter)      [ $# -eq 3 ] || die_usage "_settle-waiter is internal: settle-when-idle launches it"; settle_waiter_entry "$@" ;;
  dispatch)            [ $# -eq 1 ] || die_usage "dispatch <json>"; need_protocol
                       refuse_on_v2 dispatch "a raw command is not ported to V2: its callers send V1 shapes (thread.create plus thread.turn.start, project.create) that V2 rejects at decode, and a raw pass-through would skip the archived-thread, idle and '/' guards; use send, compact, stop or settle"
                       cmd_dispatch "$1" ;;
  server-busy)         [ $# -eq 0 ] || die_usage "server-busy takes no arguments"; need_protocol; cmd_server_busy ;;
  # message-id makes no request (no probe): it only prints the id send would mint.
  message-id)          [ $# -ge 2 ] || die_usage "message-id <thread-id> <text...>"; cmd_message_id "$@" ;;
  queued-cancel)       { [ $# -eq 2 ] && [ -n "$1" ] && [ -n "$2" ]; } || die_usage "queued-cancel <thread-id> <message-id>"
                       need_protocol; cmd_queued_cancel "$1" "$2" ;;
  # The header block is the help text: everything from line 2 to the first non-comment line.
  -h|--help)           awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
  *)                   die_usage "unknown subcommand: $sub" ;;
esac
exit $?
