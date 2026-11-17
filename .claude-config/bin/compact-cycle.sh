#!/usr/bin/env bash
# compact-cycle.sh: proactive self-compaction for a T3 Code thread.
#
# A Claude session cannot fire /compact on itself (it is a UI command). This
# script is the deterministic "compactor": it waits for the target thread to go
# idle, requests native compaction through t3-api.sh (T3's orchestration API, V1
# over HTTP or V2 over a WebSocket: t3-api.sh picks the protocol), verifies it
# finished, then dispatches a resume message (the baton) so the session continues
# autonomously. Plain bash, no Claude tokens, no nondeterminism. Pairs with the
# pre-compact-synthesis skill (which does the thoughtful synthesis and writes the
# baton BEFORE spawning this).
#
# T3 is the only backend. The tmux, herdr and pane backends were removed: those sessions
# are run by hand and compacted with a manual /compact, so nothing needs to type into a pane.
#
# Usage:
#   compact-cycle.sh --target <session-or-thread-id> [--backend t3] [options]
#
# Modes:
#   (default)  spawn a detached background compactor process running the worker,
#              print one status line, return immediately. The CALLER MUST END ITS
#              TURN right after spawning: the worker waits for the thread to go
#              idle before dispatching anything. An HTTP client needs no pane to
#              host it, so the compactor is just a setsid process.
#   --worker   run the cycle inline (what the spawned process executes).
#
# Options:
#   --target <id>      a Claude or Codex session id (mapped to a thread via
#                      t3-api.sh thread-for-session) or a T3 thread id. Pass the
#                      thread id: the lock, status, log and default baton key on
#                      the literal --target string, and resume-<thread id>.txt is
#                      the baton the skill writes and context-watch.sh honors.
#   --backend t3       accepted for existing callers; t3 is the default and the
#                      only value. The cycle talks to the sibling t3-api.sh: it
#                      waits for the provider to be idle, sends bare /compact,
#                      waits for t3-api.sh compact-status to say completed for THAT
#                      request (V1: the matching context-compaction activity; V2: the
#                      run of that message completed AND a completed compaction turn
#                      item), then dispatches the resume. That answer is the proof:
#                      the thread need NOT be idle again (see COMPLETED MEANS DONE).
#   --baton <file>     resume text file. Default: $RUNDIR/resume-<Key>.txt if
#                      present. Renamed to *.sent-<ts> after dispatch (one-shot).
#   --resume "<text>"  inline resume text (overrides --baton).
#   --no-resume        compact + verify only; never dispatch a resume.
#   --grace <s>        initial wait so the caller's turn can end. Default 20.
#   --idle-timeout <s> max wait for the thread to go idle. Default 300. Past it,
#                      abort without compacting (a queued /compact is invisible
#                      over the API, so it is never fired into a busy thread).
#   --timeout <s>      max wait for the compaction to complete (the compact-status
#                      answer, not an idle thread). Default 900.
#
# Runtime dir: ~/.claude-compact-cycle/  (locks, logs, status files, batons); CC_CYCLE_RUNDIR
# overrides. Nothing here names a checkout: the sibling t3-api.sh is found from this script's
# own location (SELF_DIR below), so the same file runs from ~/OPS, a worktree or another clone.
# The box also needs Linux (setsid), T3's protocol 2 (T3 0.1.0 or later) and the harness token
# t3-api.sh reads (TOKEN in its header; DEPLOYMENT.md, "T3 Code hosts"). Without the token
# t3-api.sh exits 3 on its first call, so the cycle stops with ERR_T3API (exit 6) before it
# spawns a worker or sends anything.
#
# KNOWN LIMIT: the target must be a top-level thread. A T3 delegated child thread (an id that
# starts thread:delegated-task:) is not among the shell's root threads, so active-turn and
# thread-for-session both answer exit 5 and the cycle stops with ERR_TARGET (exit 3) before
# anything is sent. A delegated lane checkpoints and returns a remainder instead; the
# context-watch hook never hands such a thread this command.
# On failure/timeout the resume is NEVER dispatched: the session stays paused
# with synthesis already on disk; the reason lands in the log and status file.
#
# COMPLETED MEANS DONE. The cycle used to demand a completed compaction AND a thread idle for
# T3_CONFIRM polls, bounded by --timeout. A thread with background work is woken seconds after
# its compaction (a finished background task posts a notification, which starts a run of 15 to
# 25 minutes), so it never read idle: in the cycles that timed out that way, the completed
# compaction item had landed 75 to 163 s after the request, and the resume baton was never
# sent. Now the compact-status answer `completed` (V2: the run of the /compact message completed
# and a completed compaction turn item belongs to it) ends the wait. One thread read follows, only
# to refuse the resume when the session recorded an error, and to log whether the thread is busy
# again; busy is not an error. The baton goes out either way: on V2 t3-api.sh send uses
# dispatchMode queue_after_active, so it starts at once on an idle thread and queues behind the
# active run on a busy one, and the caller (who ended its turn to wait for it) is woken by it.
# This relies on a send to a busy thread queueing, which t3-api.sh's header states for V2 (T3
# 0.1.0 and later); a protocol-1 server is legacy here and its turn.start behavior on a busy
# thread has not been exercised by this script. A compaction that did NOT complete still sends
# nothing: pending runs to --timeout, failed and every unknown answer end the cycle at once.
#
# EVERY FAILURE LOG CARRIES THE RAW STATUS IT SAW. compact-status prints one word, so the log of
# any non-ok result gets a `raw-status:` line with the last compact-status answer, the last thread
# read (activeTurnId, session status, lastError, how long ago) and the request's message id; a
# timeout, a busy refusal and a compact error also get a `diag:` line, one fresh best-effort read
# of the thread (session, latest turn, background liveness, the last four runs with their status
# and message ids). The timeout cause used to be inferred, because none of this was logged.
#
# NOTHING TO COMPACT (V2). compact-status answers nothing-to-compact when T3 refused the
# request with "Start a conversation before compacting this thread." (the provider session
# has no conversation yet). That is a finished no-op, not a failure and not still pending:
# the cycle says so loudly (and whether the thread is idle), and STILL sends the resume baton,
# because the caller ended its turn to wait for it and nothing else will wake the thread.
# Polling it as pending ran to --timeout and ended ERR_TIMEOUT with no resume, stranding the
# thread. Any answer this script does not know is ERR_COMPACT at once (never a poll to the
# timeout).
#
# T3-API EXIT CODES. Only 0 is success. t3-api.sh's header is the source of truth for the list
# (2 usage, 3 no token, 4 transport or local read error or a refused or lost WebSocket, 5 not
# found, 6 bad answer, 7 refused on a protocol-2 server, 8 unsupported protocol, 9 guard: not
# idle, 10 guard: write refused, 11 refused by the server, 12 server could not decode); the
# test suite derives that list from the header and runs every code through every step, so a new
# code with no phrase in t3_rc_reason fails there. What each step does with a nonzero code:
#   resolve the target, read the session, wait for idle (nothing sent yet):
#       5 -> ERR_TARGET, exit 3; any other code -> ERR_T3API, exit 6
#   the /compact request and the resume (writes): any code -> ERR_DISPATCH, exit 5. Code 4 adds
#       that the outcome is unknown (a lost WebSocket call may have been accepted), so check the
#       thread before sending anything again. The baton is kept.
#   compact status read (after the request went out): any code -> ERR_COMPACT, exit 5; the thread
#       may be compacting or compacted, so check it
#   the idle read after compaction: 5 -> ERR_TARGET, exit 3; any other code -> ERR_T3API, exit 6
# None of them retries or waits out the timeout, except that a transport blip (code 4) on a
# read is retried three times first. No failure ever sends the resume.
#
# Exit codes: 0 ok · 2 usage · 3 target/session missing · 4 lock held · 5 compact or dispatch
#   failed · 6 T3 API unusable (no token, unreachable, bad answer, unsupported protocol)
set -uo pipefail

RUNDIR="${CC_CYCLE_RUNDIR:-$HOME/.claude-compact-cycle}"
mkdir -p "$RUNDIR"

TARGET="" BATON="" RESUME_TEXT="" NO_RESUME=0 WORKER=0
GRACE=20 IDLE_TIMEOUT=300 TIMEOUT=900
BACKEND="t3"

# The sibling helper, resolved relative to THIS script so a checkout or worktree
# uses its own copy. t3-api.sh carries the auth + JSON; this script only
# sequences the cycle. The tuning knobs are env-overridable (the test shrinks
# them): a few-second poll and a stay-idle confirm count. Native completion is
# verified separately through an activity correlated to the dispatched message ID.
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
T3_API="${T3_API:-$SELF_DIR/t3-api.sh}"
# Never inherit OPS_T3_COMMAND_KEY. On a protocol-2 server t3-api.sh builds each
# command id from the caller, the verb, the thread, a hash of the text and this key, and the server REPLAYS
# its receipt for an id it has seen. A fixed key in the environment therefore makes the ids deterministic: a
# second cycle on the same thread sends the same '/compact' (and, with the same baton, the same resume) as the
# first, the server replays cycle 1's receipt and starts nothing, and compact-status then finds cycle 1's
# finished compaction under the id both cycles share: a "verified" compaction with nothing compacted, and a
# baton the thread never received. Every write here is a new intent (no t3-api.sh call is ever repeated to
# retry one; t3-api.sh's own single transport retry reuses its frame inside one call), so the right key is the
# fresh random one t3-api.sh mints per call when none is set. Unset rather than pinned per cycle: nothing here
# wants a deterministic key, and one shared per-cycle key would make the two writes of a cycle collide as soon
# as their texts matched (a baton that is exactly '/compact').
unset OPS_T3_COMMAND_KEY
T3_POLL="${T3_POLL:-3}"
T3_CONFIRM="${T3_CONFIRM:-2}"
T3_THREAD=""   # resolved once per process by t3_resolve, then cached

while [ $# -gt 0 ]; do
  case "$1" in
    --target)       TARGET="$2"; shift 2 ;;
    --backend)      BACKEND="$2"; shift 2 ;;
    --baton)        BATON="$2"; shift 2 ;;
    --resume)       RESUME_TEXT="$2"; shift 2 ;;
    --no-resume)    NO_RESUME=1; shift ;;
    --grace)        GRACE="$2"; shift 2 ;;
    --idle-timeout) IDLE_TIMEOUT="$2"; shift 2 ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    --worker)       WORKER=1; shift ;;
    -h|--help)      sed -n '2,/^set -uo pipefail$/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "compact-cycle: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TARGET" ] || { echo "compact-cycle: --target required" >&2; exit 2; }
# A removed backend fails loud rather than silently compacting some other way:
# a stale caller learns the route is gone instead of waiting on a compactor.
case "$BACKEND" in
  t3) : ;;
  tmux|herdr|pane) echo "compact-cycle: --backend $BACKEND was removed (those sessions compact by hand: fire /compact yourself); only t3 remains" >&2; exit 2 ;;
  *) echo "compact-cycle: --backend must be t3 (got '$BACKEND')" >&2; exit 2 ;;
esac
[ -x "$T3_API" ] || { echo "compact-cycle: needs an executable t3-api.sh at $T3_API" >&2; exit 3; }

# KEY: filesystem-safe identity for lock, log, status and the default baton.
KEY="$(printf '%s' "$TARGET" | tr ':. ' '---' | tr -cd 'A-Za-z0-9-')"
LOCK="$RUNDIR/$KEY.lock"
LOG="$RUNDIR/$KEY-$(date +%Y%m%dT%H%M%S).log"
STATUS="$RUNDIR/$KEY.status"
[ -n "$BATON" ] || { [ -f "$RUNDIR/resume-$KEY.txt" ] && BATON="$RUNDIR/resume-$KEY.txt"; } || true

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }
say() { echo "$*"; log "$*"; }

# What the cycle last saw, for the log of a failure. compact-status prints one word, so on its
# own the log of a timeout could not say what the thread was doing (the timeout cause was INFERRED
# from DB run times until this was added). P_* are the fields of the last thread read
# (poll_fields), P_AT its time; LAST_EVIDENCE the last compact-status answer; LAST_MID the
# request's message id.
LAST_EVIDENCE="" LAST_MID="" P_ATID="" P_LERR="" P_STATUS="" P_AT=""
raw_state() {
  local thread="none taken"
  [ -n "$P_AT" ] && thread="activeTurnId=${P_ATID:-?} session.status=${P_STATUS:-unknown} lastError=${P_LERR:-none} (read $(( $(date +%s) - P_AT ))s ago)"
  printf 'compact-status=%s messageId=%s; last thread read: %s' "${LAST_EVIDENCE:-none-yet}" "${LAST_MID:-none}" "$thread"
}

# result <code>: write the status file and the log line; every non-ok result also logs the raw
# status it saw (above), and the ones whose cause the status words cannot show (a timeout, a
# thread that never went idle, a compaction error) take one fresh read of the thread (t3_diag).
result() {
  printf '%s result=%s target=%s\n' "$(date -Is)" "$1" "$TARGET" >"$STATUS"; log "result=$1"
  case "$1" in
    ok|ok-*) ;;
    *) log "raw-status: $(raw_state)" ;;
  esac
  case "$1" in timeout|busy|compact-error) t3_diag ;; esac
}

# The lastError T3 0.1.0 leaves on a thread whose /compact found nothing to compact (probe a30).
EMPTY_COMPACT_TEXT="Start a conversation before compacting this thread."

# ---- the cycle (orchestration through t3-api.sh; no pane) ----
# Wait for idle, dispatch bare /compact, require the completion evidence matching
# that messageId, then resume. An ordinary finished turn is never proof of
# compaction.
t3api() { "$T3_API" "$@"; }

# t3_rc_reason <t3-api.sh exit code>: what it means, one phrase (see T3-API EXIT CODES above).
t3_rc_reason() {
  case "$1" in
    2)  printf 'usage error: this script called t3-api.sh wrongly, or OPS_T3_CALLER or OPS_T3_COMMAND_KEY is malformed' ;;
    3)  printf 'no harness token file' ;;
    4)  printf 'T3 unreachable, the WebSocket upgrade refused or lost, or a local read failed' ;;
    5)  printf 'not found: the thread is absent from the live shell, or the session maps to no thread or to more than one' ;;
    6)  printf 'T3 answered something this client does not understand (HTML, not JSON, or an unexpected shape)' ;;
    7)  printf 'refused on a protocol-2 server: that command is not ported to V2' ;;
    8)  printf 'the server speaks an orchestration protocol this client does not' ;;
    9)  printf 'refused by a guard: the thread is not idle' ;;
    10) printf 'refused by a guard: archived or deleted thread, empty text, or a text starting with /' ;;
    11) printf 'refused by the server: the command was rejected and its id is spent' ;;
    12) printf 'the server could not decode the command: a client defect, no receipt' ;;
    *)  printf 'an exit code t3-api.sh does not document' ;;
  esac
}

# t3_read_err <what> <rc> <consequence>: the ERR line for a failed READ before or after the
# dispatch. Sets T3_ERR_RESULT (status file), T3_ERR_EXIT (this script's exit) and T3_ERR_LINE.
t3_read_err() {
  if [ "$2" -eq 5 ]; then
    T3_ERR_RESULT=gone; T3_ERR_EXIT=3
    T3_ERR_LINE="ERR_TARGET: $1: t3-api.sh exit 5 ($(t3_rc_reason 5)); $3"
  else
    T3_ERR_RESULT=t3-api-error; T3_ERR_EXIT=6
    T3_ERR_LINE="ERR_T3API: $1 failed: t3-api.sh exit $2 ($(t3_rc_reason "$2")); $3"
  fi
}

# t3_read_fail <what> <rc> <consequence>: worker form of t3_read_err: record, say, return the exit.
t3_read_fail() {
  t3_read_err "$@"
  result "$T3_ERR_RESULT"; say "$T3_ERR_LINE"
  return "$T3_ERR_EXIT"
}

# t3_write_fail <what> <rc> <consequence>: the ERR_DISPATCH line for a failed WRITE (the /compact
# request or the resume). Code 4 is the one write failure whose outcome is unknown: a WebSocket
# call lost twice may have been accepted, so the line says to look before sending again.
t3_write_fail() {
  local note=""
  [ "$2" -eq 4 ] && note="; unless t3-api's line above says nothing was sent, the outcome is UNKNOWN (a lost WebSocket call may have been accepted): check the thread before sending anything again"
  result compact-error
  say "ERR_DISPATCH: $1 failed: t3-api.sh exit $2 ($(t3_rc_reason "$2"))$note; $3"
  return 5
}

# Resolve --target to a T3 thread id and cache it in T3_THREAD. Accept it as a
# thread id when it is present in the snapshot (active-turn exits 0), else treat it
# as a provider session id and map it through t3-api.sh thread-for-session (V1: the
# SQLite runtime table; V2: statev2.sqlite). Returns 0 ok, or the t3-api.sh exit code
# of the step that failed: 5 not found (or an ambiguous session), and every other code
# (3 no token, 4 transport or an unreadable V2 db, 6, 8, ...) as itself, so a dead
# server is never reported as a missing thread. MUST be called un-subshelled so the
# cache lands in this process.
t3_resolve() {
  [ -n "$T3_THREAD" ] && return 0
  local rc out
  t3api active-turn "$TARGET" >/dev/null; rc=$?
  if [ "$rc" -eq 0 ]; then T3_THREAD="$TARGET"; return 0; fi
  [ "$rc" -eq 5 ] || return "$rc"
  out="$(t3api thread-for-session "$TARGET")"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$out" ] || return 5
  T3_THREAD="$out"
}

# One snapshot read -> "<activeTurnId/provider-busy/null>\t<lastError-or-empty>\t<session.status>"
# for T3_THREAD (poll_fields splits it). All fields from a single GET so a poll is one request
# (keeps the completion error-check and the idle detection on the same snapshot). Exit 5 if the
# thread has left the snapshot.
t3_poll() {
  local snap rc
  snap="$(t3api snapshot)"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$snap" | python3 -c '
import json, sys
d = json.load(sys.stdin)
tid = sys.argv[1]
def flat(v, n=300):   # one line, no tab: the fields below are tab separated
    return " ".join(str(v).split())[:n]
for t in d.get("threads", []):
    if t.get("id") == tid:
        s = t.get("session") or {}
        a = s.get("activeTurnId"); e = s.get("lastError"); st = s.get("status")
        if a is None and st in ("starting", "running"):
            a = "provider-busy"
        print((a if a is not None else "null") + "\t" + (flat(e) if e else "") + "\t" + (flat(st, 40) if st else ""))
        sys.exit(0)
sys.exit(5)' "$T3_THREAD"; rc=$?
  # The parser's own failure (an answer that is not the snapshot shape) is a bad answer, 6.
  case "$rc" in 0|5) return "$rc" ;; *) return 6 ;; esac
}

# Retry a transient poll blip (t3_poll rc 4 = HTTP/transport) a few times before it
# aborts a cycle; rc 0 and rc 5 (thread genuinely absent) pass straight through.
t3_poll_retry() {
  local out rc i
  for i in 1 2 3; do
    out="$(t3_poll)"; rc=$?
    [ "$rc" -ne 4 ] && { printf '%s' "$out"; return "$rc"; }
    sleep "$T3_POLL"
  done
  printf '%s' "$out"; return "$rc"
}

# t3_session_present: prints yes or no, whether the thread has a live provider session
# (session != null). Refuse to dispatch into a thread with no session: a turn.start there
# would spawn a fresh provider instead of compacting the one the caller meant. Returns the
# t3-api.sh exit code of the snapshot read when that fails (5 when the thread is absent).
# On V2 the translated snapshot always carries a session object, so this is a V1 guard;
# V2's "no conversation yet" case is the nothing-to-compact answer.
t3_session_present() {
  local snap rc
  snap="$(t3api snapshot)"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$snap" | python3 -c '
import json, sys
d = json.load(sys.stdin)
tid = sys.argv[1]
for t in d.get("threads", []):
    if t.get("id") == tid:
        print("yes" if t.get("session") else "no")
        sys.exit(0)
sys.exit(5)' "$T3_THREAD"; rc=$?
  case "$rc" in 0|5) return "$rc" ;; *) return 6 ;; esac
}

# t3_status_retry <message-id>: compact-status, retrying a transport blip (exit 4) three
# times like t3_poll_retry: the read is idempotent, and one lost read must not abandon a
# compaction that is already running.
t3_status_retry() {
  local out rc i
  for i in 1 2 3; do
    out="$(t3api compact-status "$T3_THREAD" "$1")"; rc=$?
    [ "$rc" -ne 4 ] && { printf '%s' "$out"; return "$rc"; }
    sleep "$T3_POLL"
  done
  printf '%s' "$out"; return "$rc"
}

# poll_fields <t3_poll line>: split it into P_ATID, P_LERR and P_STATUS (tab separated; t3_poll
# flattens lastError to one line with no tab) and stamp P_AT. Call it in this shell, never in a
# command substitution, or the fields are lost.
poll_fields() {
  local r
  P_ATID="${1%%$'\t'*}"; r="${1#*$'\t'}"
  P_LERR="${r%%$'\t'*}"; P_STATUS="${r#*$'\t'}"
  [ "$P_STATUS" = "$r" ] && P_STATUS=""
  P_AT="$(date +%s)"
}

# t3_diag: one best-effort read of the thread for the log of a failure: its session, latest turn,
# background liveness and last four runs (status and message id). Never fails the cycle and never
# retries; a read that fails is logged as such. Capped at 20 s so a dead server cannot hold the
# lock. T3_DIAG=0 turns it off.
t3_diag() {
  local out rc
  [ "${T3_DIAG:-1}" = 0 ] && return 0
  [ -n "$T3_THREAD" ] || return 0
  out="$(timeout 20 "$T3_API" thread "$T3_THREAD" 1 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then log "diag: thread read failed: t3-api.sh exit $rc"; return 0; fi
  log "diag: $(printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("thread read was not JSON"); sys.exit(0)
t = d.get("thread") if isinstance(d.get("thread"), dict) else d
def one(v, n=120):
    return " ".join(str(v).split())[:n]
s = t.get("session") or {}
lt = t.get("latestTurn") or {}
runs = [r for r in (t.get("runs") or []) if isinstance(r, dict)][-4:]
print("session.status=%s activeTurnId=%s lastError=%s latestTurn.state=%s backgroundLiveness=%s runs=[%s]" % (
    one(s.get("status")), one(s.get("activeTurnId")), one(s.get("lastError") or "none"), one(lt.get("state")),
    one(t.get("backgroundLiveness")),
    ", ".join("%s:%s:%s" % (one(r.get("id"), 40)[-24:], one(r.get("status"), 20), one(r.get("userMessageId"), 8)) for r in runs)))
' 2>/dev/null || echo "thread read could not be summarized")"
}

# The full worker cycle. Sets the STATUS via result() and returns an exit code
# on the script's scale (0 ok, 3 target gone, 5 compact or dispatch failed, 6 T3 API unusable).
t3_worker_cycle() {
  local rc has
  t3_resolve; rc=$?
  if [ "$rc" -ne 0 ]; then t3_read_fail "resolving '$TARGET' to a T3 thread" "$rc" "nothing was sent"; return $?; fi
  has="$(t3_session_present)"; rc=$?
  if [ "$rc" -ne 0 ]; then t3_read_fail "reading the session of thread $T3_THREAD" "$rc" "nothing was sent"; return $?; fi
  if [ "$has" != "yes" ]; then
    result no-claude; say "ERR_NO_CLAUDE: thread has no live provider session, refusing to dispatch into it"
    return 3
  fi

  # (1) Wait for idle: activeTurnId null and STAYS null for T3_CONFIRM polls, bounded
  # by --idle-timeout. If still busy, abort without dispatching.
  # This deliberately does NOT adopt T3 V2's idleVerdict (lib/t3_api_v2.py idle_verdict).
  # That verdict reads a queued run in the thread's /bounded projection and any
  # pendingBackgroundTasks as busy, which is right for settle and archive and wrong here,
  # for two reasons. (a) A queue held behind a failed or stopped run does not delay a
  # /compact: a later /compact started and completed at once while an earlier run stayed
  # queued (probe a32, a45, recorded against a scratch 0.1.0 server), so refusing on a held
  # queue only blocks a compaction that would have worked. (b) A thread watching a PR carries
  # a 'monitor' background task for as long as the watch lasts (idle_verdict's docstring
  # names this case), so the verdict would call it busy and its compaction would never run.
  # The probe did not exercise a PR-watch monitor, so (b) rests on idle_verdict, not on a
  # recorded exchange.
  local deadline idle=0 poll atid lerr
  deadline=$(( $(date +%s) + IDLE_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    poll="$(t3_poll_retry)"; rc=$?
    if [ "$rc" -ne 0 ]; then t3_read_fail "waiting for thread $T3_THREAD to go idle" "$rc" "nothing was sent"; return $?; fi
    poll_fields "$poll"; atid="$P_ATID"
    if [ "$atid" = "null" ]; then idle=$((idle+1)); else idle=0; fi
    [ "$idle" -ge "$T3_CONFIRM" ] && break
    sleep "$T3_POLL"
  done
  if [ "$idle" -lt "$T3_CONFIRM" ]; then
    # Never dispatch /compact into a busy thread. Over the API a queued turn is
    # invisible, so the gap between the running turn ending and a queued /compact
    # starting would read as "compaction done" and fire the resume early. Only a
    # confirmed-idle thread is compacted; otherwise abort untouched.
    result busy; say "ERR_BUSY: target still active after ${IDLE_TIMEOUT}s (activeTurnId=${P_ATID:-?} session.status=${P_STATUS:-unknown}); not dispatching /compact"; return 5
  fi
  say "target idle: requesting native compaction"

  # T3 recognizes ONLY bare /compact. Arguments become ordinary model input.
  # Preservation instructions belong in the synthesis/baton, not this command.
  local mid evidence cdeadline ok=0 noop=0 busy_after=0
  mid="$(t3api compact "$T3_THREAD")"; rc=$?
  [ "$rc" -eq 0 ] && [ -z "$mid" ] && rc=6   # accepted but no message id to verify against
  if [ "$rc" -ne 0 ]; then t3_write_fail "native /compact request" "$rc" "no resume"; return $?; fi
  LAST_MID="$mid"
  log "native compact requested messageId=$mid"
  cdeadline=$(( $(date +%s) + TIMEOUT ))
  while [ "$(date +%s)" -lt "$cdeadline" ]; do
    evidence="$(t3_status_retry "$mid")"; rc=$?
    if [ "$rc" -ne 0 ]; then
      result compact-error
      say "ERR_COMPACT: cannot verify request $mid: t3-api.sh exit $rc ($(t3_rc_reason "$rc")); no resume. The request was already sent, so the thread may be compacting or compacted: check it"
      return 5
    fi
    LAST_EVIDENCE="${evidence:0:60}"
    case "$evidence" in
      pending) : ;;
      failed)
        result compact-error; say "ERR_COMPACT: provider rejected request $mid; no resume"; return 5 ;;
      completed|nothing-to-compact)
        # A native compact need not set activeTurnId at all. Its matching completion
        # evidence is required; an old event or an ordinary reply can never satisfy it.
        # nothing-to-compact is the V2 finished no-op (see NOTHING TO COMPACT above).
        if [ "$evidence" = "nothing-to-compact" ]; then
          noop=1
          say "nothing to compact: T3 says the thread has no conversation yet (request $mid); nothing was compacted, and the resume is still sent so the thread continues"
        fi
        # One thread read, for two things and nothing else: refuse the resume when the session
        # recorded an error, and log whether the thread is busy again. This answer is the proof
        # (see COMPLETED MEANS DONE); an idle thread is NOT required, because a thread with
        # background work is woken seconds after its compaction and may stay busy for the rest
        # of --timeout, and the resume queues behind that run.
        poll="$(t3_poll_retry)"; rc=$?
        if [ "$rc" -ne 0 ]; then t3_read_fail "reading thread $T3_THREAD after the compact request" "$rc" "no resume"; return $?; fi
        poll_fields "$poll"; atid="$P_ATID"; lerr="$P_LERR"
        if [ -n "$lerr" ]; then
          # The refusal itself is the thread's lastError after a nothing-to-compact answer, and only
          # that exact text is expected there: any other session error still blocks the resume.
          if [ "$evidence" != "nothing-to-compact" ] || [ "$lerr" != "$EMPTY_COMPACT_TEXT" ]; then
            result compact-error; say "ERR_COMPACT: session error after compaction (lastError: $lerr); no resume"; return 5
          fi
        fi
        [ "$atid" = "null" ] || busy_after=1
        ok=1; break ;;
      *)
        # Unknown answer (a newer t3-api.sh, a damaged helper): fail now, do not poll it to the timeout.
        result compact-error; say "ERR_COMPACT: compact-status answered '${evidence:0:60}' for request $mid, which this script does not know; no resume"; return 5 ;;
    esac
    sleep "$T3_POLL"
  done
  if [ "$ok" -ne 1 ]; then
    # Still pending at the deadline: say what the thread was doing (the status word alone cannot).
    poll="$(t3_poll_retry)" && poll_fields "$poll"
    result timeout; say "ERR_TIMEOUT: no completed compaction for request $mid within ${TIMEOUT}s (last compact-status: ${LAST_EVIDENCE:-none}; thread: activeTurnId=${P_ATID:-unread} session.status=${P_STATUS:-unknown}); no resume"
    return 5
  fi
  if [ "$noop" -eq 1 ]; then
    if [ "$busy_after" -eq 1 ]; then say "no compaction needed (the thread is busy again: activeTurnId=$P_ATID session.status=${P_STATUS:-unknown}) messageId=$mid"
    else say "no compaction needed, thread idle messageId=$mid"; fi
  else
    say "native compaction verified messageId=$mid"
    [ "$busy_after" -eq 1 ] && say "thread busy again after the compaction (activeTurnId=$P_ATID session.status=${P_STATUS:-unknown}), as a thread with background work is: the compaction is done, so the resume is sent now and queues behind the active run"
  fi

  # (4) Resume unless --no-resume. Precedence: inline --resume text, then baton
  # file, then the default continuation nudge.
  if [ "$NO_RESUME" -eq 1 ]; then result ok-no-resume; say "done (no resume)"; return 0; fi
  local msg
  if [ -n "$RESUME_TEXT" ]; then
    msg="$RESUME_TEXT"
  elif [ -n "$BATON" ] && [ -f "$BATON" ]; then
    msg="$(cat "$BATON")"
  else
    msg="Continue the standing work. Read the freshest durable anchor (SESSION_HANDOFF.md / handoff baton) and the task list, then execute NEXT ACTION. This is a continuation of one body of work, not a new session."
  fi
  t3api send "$T3_THREAD" "$msg" >/dev/null; rc=$?
  if [ "$rc" -ne 0 ]; then t3_write_fail "resume dispatch" "$rc" "the baton is kept, no resume was recorded"; return $?; fi
  [ -n "$BATON" ] && [ -f "$BATON" ] && mv "$BATON" "$BATON.sent-$(date +%Y%m%dT%H%M%S)"
  if [ "$noop" -eq 1 ]; then result ok-nothing-to-compact; else result ok; fi
  say "resume dispatched: cycle complete"
  return 0
}

# ---------------- spawner ----------------
if [ "$WORKER" -eq 0 ]; then
  t3_resolve; rc=$?
  if [ "$rc" -ne 0 ]; then
    t3_read_err "resolving '$TARGET' to a T3 thread" "$rc" "no compactor was spawned"
    echo "$T3_ERR_LINE" >&2; exit "$T3_ERR_EXIT"
  fi
  if [ -d "$LOCK" ]; then
    echo "ERR_LOCK: a compactor for '$TARGET' is already running ($LOCK)" >&2; exit 4
  fi
  SELF="$(readlink -f "$0")"
  CMD="$(printf '%q --worker --backend t3 --target %q --grace %q --idle-timeout %q --timeout %q' "$SELF" "$TARGET" "$GRACE" "$IDLE_TIMEOUT" "$TIMEOUT")"
  [ -n "$BATON" ]       && CMD="$CMD $(printf -- '--baton %q' "$BATON")"
  [ -n "$RESUME_TEXT" ] && CMD="$CMD $(printf -- '--resume %q' "$RESUME_TEXT")"
  [ "$NO_RESUME" -eq 1 ] && CMD="$CMD --no-resume"
  # setsid so the worker outlives the caller's turn ending; it holds its own lock
  # and self-cleans via finish(). Its output goes to the log.
  setsid bash -c "$CMD" </dev/null >>"$LOG" 2>&1 &
  disown 2>/dev/null || true
  CSESS="detached-pid-$!"
  echo "OK compactor spawned session=$CSESS backend=t3 target=$TARGET grace=${GRACE}s log=$RUNDIR/$KEY-*.log"
  echo "   (caller: END YOUR TURN NOW; worker waits for idle, compacts, resumes unless --no-resume)"
  exit 0
fi

# ---------------- worker ----------------
mkdir "$LOCK" 2>/dev/null || { say "ERR_LOCK: lock held, exiting"; exit 4; }
finish() { rm -rf "$LOCK"; }
trap finish EXIT
# Operator abort = killing the compactor process -> SIGHUP/TERM. Without these
# traps the EXIT trap never runs on signal death and the lock leaks.
trap 'result aborted; finish; exit 1' HUP INT TERM

say "compact-cycle worker start target=$TARGET grace=${GRACE}s idle-timeout=${IDLE_TIMEOUT}s timeout=${TIMEOUT}s baton=${BATON:-none} no-resume=$NO_RESUME"
sleep "$GRACE"

t3_worker_cycle; e=$?
exit "$e"
