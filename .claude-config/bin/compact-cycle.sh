#!/usr/bin/env bash
# compact-cycle.sh — automated /compact cycle for a Claude Code session in tmux.
#
# A Claude session cannot fire /compact on itself (it is a UI command). This
# script is the deterministic "compactor": it types /compact into the target
# pane, waits for compaction to finish, then types a resume message (the baton)
# so the session continues autonomously. Plain bash — no Claude tokens, no
# nondeterminism. Pairs with the pre-compact-synthesis skill (which does the
# thoughtful synthesis + writes the baton BEFORE spawning this).
#
# Usage:
#   compact-cycle.sh --target <Session|Session:win.pane> [options]
#
# Modes:
#   (default)  spawn a detached tmux session "Compactor-<Key>" running the
#              worker, print one status line, return immediately. The CALLER
#              MUST END ITS TURN right after spawning — the worker waits for
#              the target pane to go idle before typing anything.
#   --worker   run the cycle inline (what the spawned session executes).
#
# Options:
#   --baton <file>     resume text file. Default: $RUNDIR/resume-<Key>.txt if
#                      present. Renamed to *.sent-<ts> after typing (one-shot).
#   --resume "<text>"  inline resume text (overrides --baton).
#   --no-resume        fire + wait only; never type a resume. Fleet mode —
#                      fleet agents re-wake via their /loop cron.
#   --grace <s>        initial wait so the caller's turn can end. Default 20.
#   --idle-timeout <s> max wait for the target to go idle before firing.
#                      Default 300. Past it, fire anyway (Claude Code queues
#                      typed input; same precedent as ac-compact-peer).
#   --timeout <s>      max wait for compaction to complete. Default 900.
#
# Runtime dir: ~/.claude-compact-cycle/  (locks, logs, status files, batons).
# On failure/timeout the resume is NEVER typed — the session stays paused with
# synthesis already on disk; a pane snapshot lands in the log.
#
# Exit codes: 0 ok · 2 usage · 3 target/claude missing · 4 lock held · 5 compact failed
set -uo pipefail

RUNDIR="${CC_CYCLE_RUNDIR:-$HOME/.claude-compact-cycle}"
mkdir -p "$RUNDIR"

TARGET="" BATON="" RESUME_TEXT="" NO_RESUME=0 WORKER=0
GRACE=20 IDLE_TIMEOUT=300 TIMEOUT=900

while [ $# -gt 0 ]; do
  case "$1" in
    --target)       TARGET="$2"; shift 2 ;;
    --baton)        BATON="$2"; shift 2 ;;
    --resume)       RESUME_TEXT="$2"; shift 2 ;;
    --no-resume)    NO_RESUME=1; shift ;;
    --grace)        GRACE="$2"; shift 2 ;;
    --idle-timeout) IDLE_TIMEOUT="$2"; shift 2 ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    --worker)       WORKER=1; shift ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "compact-cycle: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TARGET" ] || { echo "compact-cycle: --target required" >&2; exit 2; }

# KEY: filesystem/tmux-safe identity for lock, log, compactor session name.
KEY="$(printf '%s' "$TARGET" | tr ':. ' '---' | tr -cd 'A-Za-z0-9-')"
# Exact-match tmux target — bare names unique-prefix-match (a bare "Alpha"
# also hits "Alpha2"). Pane-level commands (capture-pane, send-keys) reject a
# bare "=Name"; the "=Name:" form (exact session, current window, active pane)
# works for every command, so normalize to it when the caller gave a bare
# session name.
case "$TARGET" in *:*) T="=$TARGET" ;; *) T="=$TARGET:" ;; esac
LOCK="$RUNDIR/$KEY.lock"
LOG="$RUNDIR/$KEY-$(date +%Y%m%dT%H%M%S).log"
STATUS="$RUNDIR/$KEY.status"
[ -n "$BATON" ] || { [ -f "$RUNDIR/resume-$KEY.txt" ] && BATON="$RUNDIR/resume-$KEY.txt"; } || true

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }
say() { echo "$*"; log "$*"; }

# Target pane must exist and actually host a claude process. pane_current_command
# is unreliable (shows the shell), so walk the pane PID's descendants.
pane_pid() { tmux list-panes -t "$T" -F '#{pane_active} #{pane_pid}' 2>/dev/null | awk '$1==1{print $2; exit}'; }
claude_in_pane() {
  local root; root="$(pane_pid)"; [ -n "$root" ] || return 1
  ps -eo pid=,ppid=,args= | awk -v r="$root" '
    { pid[$1]=$2; a[$1]=$0 }
    END {
      for (p in pid) {
        q=p; hops=0
        while (q in pid && hops<6) { if (pid[q]==r) { if (a[p] ~ /claude/) { found=1 }; break }; q=pid[q]; hops++ }
      }
      exit found?0:1
    }'
}
capture() { tmux capture-pane -p -t "$T" 2>/dev/null | tail -40; }
# Busy = the definitive run indicator, or a spinner line STARTING with
# "Compacting" — never a bare word-match ("compacting" can appear in normal
# conversation text and would wedge the detector).
busy()    { capture | grep -qiE '(esc to interrupt)|^[^a-z]{0,4}compacting'; }

# ---------------- spawner ----------------
if [ "$WORKER" -eq 0 ]; then
  tmux list-panes -t "$T" >/dev/null 2>&1 || { echo "ERR_TARGET: '$TARGET' not found in tmux" >&2; exit 3; }
  if [ -d "$LOCK" ]; then
    echo "ERR_LOCK: a compactor for '$TARGET' is already running ($LOCK)" >&2; exit 4
  fi
  CSESS="Compactor-$KEY"
  tmux kill-session -t "=$CSESS" 2>/dev/null || true   # stale finished shell, never a live worker (lock gates that)
  SELF="$(readlink -f "$0")"
  CMD="$(printf '%q --worker --target %q --grace %q --idle-timeout %q --timeout %q' "$SELF" "$TARGET" "$GRACE" "$IDLE_TIMEOUT" "$TIMEOUT")"
  [ -n "$BATON" ]       && CMD="$CMD $(printf -- '--baton %q' "$BATON")"
  [ -n "$RESUME_TEXT" ] && CMD="$CMD $(printf -- '--resume %q' "$RESUME_TEXT")"
  [ "$NO_RESUME" -eq 1 ] && CMD="$CMD --no-resume"
  tmux new-session -d -s "$CSESS" "$CMD" || { echo "ERR_SPAWN: could not start $CSESS" >&2; exit 3; }
  echo "OK compactor spawned session=$CSESS target=$TARGET grace=${GRACE}s log=$RUNDIR/$KEY-*.log"
  echo "   (caller: END YOUR TURN NOW — the worker waits for idle, fires /compact, then types the resume)"
  exit 0
fi

# ---------------- worker ----------------
mkdir "$LOCK" 2>/dev/null || { say "ERR_LOCK: lock held, exiting"; exit 4; }
finish() { rm -rf "$LOCK"; }
trap finish EXIT
# Operator abort = tmux kill-session on the compactor -> SIGHUP. Without these
# traps the EXIT trap never runs on signal death and the lock leaks.
trap 'result aborted; finish; exit 1' HUP INT TERM

result() { printf '%s result=%s target=%s\n' "$(date -Is)" "$1" "$TARGET" >"$STATUS"; log "result=$1"; }

say "compact-cycle worker start target=$TARGET grace=${GRACE}s idle-timeout=${IDLE_TIMEOUT}s timeout=${TIMEOUT}s baton=${BATON:-none} no-resume=$NO_RESUME"
sleep "$GRACE"

tmux list-panes -t "$T" >/dev/null 2>&1 || { result gone; say "ERR_TARGET gone"; exit 3; }
if ! claude_in_pane; then
  result no-claude; say "ERR_NO_CLAUDE: no claude process in target pane — refusing to type into it"
  exit 3
fi

# Wait for idle: 3 consecutive not-busy polls (UI flickers between tool calls).
DEADLINE=$(( $(date +%s) + IDLE_TIMEOUT )); IDLE=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if busy; then IDLE=0; else IDLE=$((IDLE+1)); fi
  [ "$IDLE" -ge 3 ] && break
  sleep 2
done
[ "$IDLE" -ge 3 ] && say "target idle — firing /compact" \
                  || say "WARN: target still busy after ${IDLE_TIMEOUT}s — firing anyway (/compact will queue)"

tmux send-keys -t "$T" "/compact"
sleep 0.6                       # let the slash-command menu settle before submit
tmux send-keys -t "$T" Enter
log "/compact sent"

# Completion: busy (or 'Compacting') must clear and STAY clear for 3 polls.
# Errors: known failure strings in the tail — then we do NOT resume.
DEADLINE=$(( $(date +%s) + TIMEOUT )); CLEAR=0; OK=0
sleep 5
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  TAIL="$(capture)"
  if printf '%s' "$TAIL" | tail -15 | grep -qiE 'error (during|while) compact|compaction failed|not enough messages|conversation too small|api error'; then
    result compact-error
    say "ERR_COMPACT: failure marker in pane — no resume typed. Pane tail follows:"
    printf '%s\n' "$TAIL" >>"$LOG"
    exit 5
  fi
  if printf '%s' "$TAIL" | grep -qiE '(esc to interrupt)|^[^a-z]{0,4}compacting'; then CLEAR=0; else CLEAR=$((CLEAR+1)); fi
  if [ "$CLEAR" -ge 3 ]; then OK=1; break; fi
  sleep 4
done
if [ "$OK" -ne 1 ]; then
  result timeout
  say "ERR_TIMEOUT: compaction not confirmed within ${TIMEOUT}s — no resume typed. Pane tail follows:"
  capture >>"$LOG"
  exit 5
fi
say "compaction complete"

if [ "$NO_RESUME" -eq 1 ]; then result ok-no-resume; say "done (fleet mode, no resume)"; exit 0; fi

# Resume: baton file > inline text > default continuation nudge.
TMPMSG="$(mktemp)"
if [ -n "$RESUME_TEXT" ]; then
  printf '%s\n' "$RESUME_TEXT" >"$TMPMSG"
elif [ -n "$BATON" ] && [ -f "$BATON" ]; then
  cat "$BATON" >"$TMPMSG"
else
  printf '%s\n' "Continue the standing work. Read the freshest durable anchor (SESSION_HANDOFF.md / fleet journal / handoff baton) and the task list, then execute NEXT ACTION. This is a continuation of one body of work, not a new session." >"$TMPMSG"
fi
BUF="cc-resume-$KEY-$$"
tmux load-buffer -b "$BUF" "$TMPMSG"
tmux paste-buffer -b "$BUF" -t "$T"
sleep 1
tmux send-keys -t "$T" Enter    # confirm paste-preview pill (multi-line)
sleep 0.6
tmux send-keys -t "$T" Enter    # submit (no-op if already submitted)
tmux delete-buffer -b "$BUF" 2>/dev/null || true
rm -f "$TMPMSG"
[ -n "$BATON" ] && [ -f "$BATON" ] && mv "$BATON" "$BATON.sent-$(date +%Y%m%dT%H%M%S)"
result ok
say "resume typed — cycle complete. Compactor self-destructs now."
exit 0
