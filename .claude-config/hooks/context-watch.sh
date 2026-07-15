#!/usr/bin/env bash
# context-watch.sh — Stop hook: when REAL context usage crosses a threshold,
# block the stop once and tell the agent to run the compact ritual
# (pre-compact-synthesis skill -> compact-cycle.sh self-compact).
#
# Registration: Stop hook in the Stage 1 settings.json template —
# settings.json is a Level 1 file owned by linuxploitacious, so a new deploy
# picks this up automatically; see DEPLOYMENT.md ("a new hook means
# registering it in the Stage 1 settings.json").
#
# Context is measured from the transcript's last assistant `usage` entry
# (input + cache_read + cache_creation tokens) — the actual API context, not a
# byte-size guess (transcripts run 20-160MB; bytes are meaningless).
#
# Growth-throttled: first nag at CC_COMPACT_NAG_TOKENS (default 650000 ≈ 65%
# of a 1M window — export 130000 on 200K-window machines), then re-nag only
# after another CC_COMPACT_RENAG_TOKENS (default 75000) of growth. State per
# session id under ~/.claude-compact-cycle/.
#
# Suppressed when:
#   - stop_hook_active (we already blocked this stop — loop guard)
#   - a fresh (<30 min) resume baton exists for this tmux session — the
#     ritual is already in flight and the agent is ending its turn ON PURPOSE
#     so the compactor can type /compact
#   - CC_CONTEXT_WATCH=0, not enough data, or no usable JSON parser
#   - no python3 (see limitation note below)
#
# Limitation (accepted, not a bug): the simple payload fields (session_id,
# transcript_path, stop_hook_active) go through hooklib.sh's hook_field, which
# falls back through jq/python/py same as every other hook. But the actual
# context measurement below re-reads the transcript file and scans its tail
# for the last `usage` entry — that byte-seek + JSONL scan stays python3-only,
# so hosts without python3 (e.g. Windows Git Bash) never get the nag. This is
# fail-open BY DESIGN, unlike git-guard/secrets-guard which fail CLOSED: a
# missed reminder just means the operator compacts manually instead of on
# this hook's cue — the compact ritual itself (pre-compact-synthesis skill)
# still works fine without this nag ever firing.
#
# A Stop hook must never break the session: every failure path exits 0 silently.
set -uo pipefail

[ "${CC_CONTEXT_WATCH:-1}" = "0" ] && exit 0
PAYLOAD=""
[ -t 0 ] || PAYLOAD="$(cat 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/hooklib.sh"

# Simple field reads use hook_field (jq-first, python3/python/py fallback) —
# only the transcript tail-scan further down is python3-only.
STOP_ACTIVE="$(printf '%s' "$PAYLOAD" | hook_field stop_hook_active)" || exit 0
[ "$STOP_ACTIVE" = "true" ] && exit 0
TRANSCRIPT="$(printf '%s' "$PAYLOAD" | hook_field transcript_path)" || exit 0
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
SID="$(printf '%s' "$PAYLOAD" | hook_field session_id)" || exit 0
SID="${SID:-unknown}"
SID="${SID:0:64}"

RUNDIR="${CC_CYCLE_RUNDIR:-$HOME/.claude-compact-cycle}"
mkdir -p "$RUNDIR" 2>/dev/null || exit 0

# Ritual-in-flight interlock: fresh baton for this tmux session => let the stop
# through untouched (the compactor needs the turn to end).
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  SNAME="$(tmux display-message -p '#S' 2>/dev/null | tr ':. ' '---' | tr -cd 'A-Za-z0-9-')"
  if [ -n "$SNAME" ] && [ -f "$RUNDIR/resume-$SNAME.txt" ]; then
    if [ -n "$(find "$RUNDIR/resume-$SNAME.txt" -mmin -30 2>/dev/null)" ]; then exit 0; fi
  fi
fi

NAG="${CC_COMPACT_NAG_TOKENS:-650000}"
RENAG="${CC_COMPACT_RENAG_TOKENS:-75000}"

# The transcript byte-tail scan (below) needs python3 specifically — jq has no
# clean way to seek N bytes from EOF in a multi-hundred-MB file and re-parse a
# JSONL tail. See the limitation note at the top of this file.
command -v python3 >/dev/null 2>&1 || exit 0

CW_TRANSCRIPT="$TRANSCRIPT" CW_SID="$SID" RUNDIR="$RUNDIR" NAG="$NAG" RENAG="$RENAG" IN_TMUX="${TMUX:+1}" python3 - <<'PY' 2>/dev/null || exit 0
import json, os, sys

tp = os.environ["CW_TRANSCRIPT"]
sid = os.environ["CW_SID"]

# Last usage entry from the transcript tail (context = what the last API call carried).
try:
    size = os.path.getsize(tp)
    with open(tp, "rb") as f:
        f.seek(max(0, size - 800_000))
        tail = f.read().decode("utf-8", "replace")
except Exception:
    sys.exit(0)
ctx = 0
for line in reversed(tail.splitlines()):
    if '"usage"' not in line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    u = (e.get("message") or {}).get("usage") or e.get("usage") or {}
    t = sum(int(u.get(k) or 0) for k in
            ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
    if t > 0:
        ctx = t
        break
nag, renag = int(os.environ["NAG"]), int(os.environ["RENAG"])
if ctx < nag:
    sys.exit(0)

state = os.path.join(os.environ["RUNDIR"], f"nag-{sid}")
last = 0
try:
    last = int(open(state).read().strip() or 0)
except Exception:
    pass
if last and ctx < last + renag:
    sys.exit(0)

# Record BEFORE blocking so a crash can never nag-spam.
try:
    with open(state, "w") as f:
        f.write(str(ctx))
except Exception:
    sys.exit(0)

how = ("run the pre-compact-synthesis skill in SELF-COMPACT mode: full synthesis, write the "
       "resume baton, spawn ~/OPS/.claude-config/bin/compact-cycle.sh --target <this tmux "
       "session>, then END YOUR TURN so the compactor can fire /compact"
       if os.environ.get("IN_TMUX")
       else "run the pre-compact-synthesis skill, then tell the operator the runway is clear "
            "for a manual /compact (this session is not in tmux, so no self-compact)")
reason = (f"[context-watch] Context is at ~{ctx//1000}K tokens (threshold {nag//1000}K). "
          f"If the work is at a natural break, {how}. If you are mid-critical-step, finish that "
          f"step first — this reminder returns after ~{renag//1000}K more tokens. Do not treat "
          f"this as a session boundary: synthesis then continue as one body of work.")
print(json.dumps({"decision": "block", "reason": reason}))
PY
exit 0
