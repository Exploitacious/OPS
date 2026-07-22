#!/usr/bin/env bash
# context-watch.sh — context-usage escalation ladder (Stop + PostToolUse).
#
# Modes (first arg):
#   stop      (default) Stop hook: block the stop with an escalating nag telling
#             the agent to run the compact ritual (pre-compact-synthesis skill
#             -> compact-cycle.sh self-compact).
#   posttool  PostToolUse hook: once usage reaches URGENT, inject the same
#             warning MID-TURN via additionalContext. Stop hooks only fire
#             between turns — a long tool-calling turn once ran from 65% to 98%
#             before its first Stop event and lost the room to synthesize. This
#             mode is the fix: the turn can no longer outrun the nag.
#
# Registration: Stop hook (no arg) + PostToolUse hook (matcher ".*", arg
# `posttool`) in the Stage 1 settings.json template — settings.json is a
# Level 1 file owned by linuxploitacious, so a new deploy picks both up
# automatically; see DEPLOYMENT.md ("a new hook means registering it in the
# Stage 1 settings.json"). Hook config is session-cached: changes land at the
# next session launch.
#
# Context is measured from the transcript's last assistant `usage` entry
# (input + cache_read + cache_creation tokens) — the actual API context, not a
# byte-size guess (transcripts run 20-160MB; bytes are meaningless).
#
# Escalation ladder — fractions of CC_CONTEXT_WINDOW (default 1000000; export
# 200000 on 200K-window machines and every tier scales):
#   65%  NOTICE    re-nag after +75K growth
#   78%  WARNING   re-nag after +40K
#   86%  URGENT    re-nag after +20K    posttool active from here (+15K throttle)
#   92%  CRITICAL  every stop           posttool throttle tightens to +8K
# Crossing INTO a higher tier always fires immediately, growth gap or not.
# Legacy overrides still honored (tier 1 only): CC_COMPACT_NAG_TOKENS
# (threshold), CC_COMPACT_RENAG_TOKENS (re-nag gap) — prefer CC_CONTEXT_WINDOW.
# State per session id under ~/.claude-compact-cycle/, one line:
# "<last_stop_ctx> <last_stop_tier> <last_posttool_ctx>".
#
# Suppressed when:
#   - stop_hook_active (we already blocked this stop — loop guard; stop mode)
#   - a fresh (<30 min) resume baton exists for this tmux session — the
#     ritual is already in flight and the agent is ending its turn ON PURPOSE
#     so the compactor can type /compact
#   - CC_CONTEXT_WATCH=0 (all), CC_CONTEXT_WATCH_POSTTOOL=0 (posttool only),
#     not enough data, or no usable JSON parser
#   - no python3 (see limitation note below)
#
# Limitation (accepted, not a bug): the simple payload fields (session_id,
# transcript_path, stop_hook_active) go through hooklib.sh's hook_field, which
# falls back through jq/python/py same as every other hook. But the actual
# context measurement below re-reads the transcript file and scans its tail
# for the last `usage` entry — that byte-seek + JSONL scan stays python3-only,
# so hosts without python3 (e.g. Windows Git Bash) never get the nag, in
# EITHER mode. This is fail-open BY DESIGN, unlike git-guard/secrets-guard
# which fail CLOSED: a missed reminder just means the operator compacts
# manually instead of on this hook's cue — the compact ritual itself
# (pre-compact-synthesis skill) still works fine without this nag ever firing.
#
# A hook must never break the session: every failure path exits 0 silently.
set -uo pipefail

MODE="${1:-stop}"
[ "${CC_CONTEXT_WATCH:-1}" = "0" ] && exit 0
[ "$MODE" = "posttool" ] && [ "${CC_CONTEXT_WATCH_POSTTOOL:-1}" = "0" ] && exit 0
PAYLOAD=""
[ -t 0 ] || PAYLOAD="$(cat 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/hooklib.sh"

# Simple field reads use hook_field (jq-first, python3/python/py fallback) —
# only the transcript tail-scan further down is python3-only.
if [ "$MODE" = "stop" ]; then
  STOP_ACTIVE="$(printf '%s' "$PAYLOAD" | hook_field stop_hook_active)" || exit 0
  [ "$STOP_ACTIVE" = "true" ] && exit 0
fi
TRANSCRIPT="$(printf '%s' "$PAYLOAD" | hook_field transcript_path)" || exit 0
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
SID="$(printf '%s' "$PAYLOAD" | hook_field session_id)" || exit 0
SID="${SID:-unknown}"
SID="${SID:0:64}"

RUNDIR="${CC_CYCLE_RUNDIR:-$HOME/.claude-compact-cycle}"
mkdir -p "$RUNDIR" 2>/dev/null || exit 0

# Ritual-in-flight interlock: fresh baton for this tmux session => stay silent
# in both modes (the compactor needs the turn to end).
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  SNAME="$(tmux display-message -p '#S' 2>/dev/null | tr ':. ' '---' | tr -cd 'A-Za-z0-9-')"
  if [ -n "$SNAME" ] && [ -f "$RUNDIR/resume-$SNAME.txt" ]; then
    if [ -n "$(find "$RUNDIR/resume-$SNAME.txt" -mmin -30 2>/dev/null)" ]; then exit 0; fi
  fi
fi

# The transcript byte-tail scan (below) needs python3 specifically — jq has no
# clean way to seek N bytes from EOF in a multi-hundred-MB file and re-parse a
# JSONL tail. See the limitation note at the top of this file.
command -v python3 >/dev/null 2>&1 || exit 0

CW_TRANSCRIPT="$TRANSCRIPT" CW_SID="$SID" RUNDIR="$RUNDIR" MODE="$MODE" \
WINDOW="${CC_CONTEXT_WINDOW:-1000000}" \
NAG_OVERRIDE="${CC_COMPACT_NAG_TOKENS:-}" RENAG_OVERRIDE="${CC_COMPACT_RENAG_TOKENS:-}" \
IN_TMUX="${TMUX:+1}" python3 - <<'PY' 2>/dev/null || exit 0
import json, os, sys

mode = os.environ.get("MODE", "stop")
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
if ctx <= 0:
    sys.exit(0)

win = max(1, int(os.environ.get("WINDOW") or 1000000))
# (name, threshold, stop re-nag gap [0 = every stop], posttool gap [None = posttool silent])
tiers = [
    ["NOTICE",   int(win * 0.65), 75_000, None],
    ["WARNING",  int(win * 0.78), 40_000, None],
    ["URGENT",   int(win * 0.86), 20_000, 15_000],
    ["CRITICAL", int(win * 0.92), 0,      8_000],
]
try:
    if os.environ.get("NAG_OVERRIDE"):
        tiers[0][1] = int(os.environ["NAG_OVERRIDE"])
    if os.environ.get("RENAG_OVERRIDE"):
        tiers[0][2] = int(os.environ["RENAG_OVERRIDE"])
except Exception:
    pass

tier = 0  # 1-based index into tiers; 0 = below the ladder
for i, t in enumerate(tiers, 1):
    if ctx >= t[1]:
        tier = i
if tier == 0:
    sys.exit(0)
name, _thr, gap, pgap = tiers[tier - 1]

state = os.path.join(os.environ["RUNDIR"], f"nag-{sid}")
last_ctx = last_tier = last_post = 0
try:
    raw = open(state).read().split()
    parts = (raw + ["0", "0", "0"])[:3]
    last_ctx, last_tier, last_post = (int(p or 0) for p in parts)
    if len(raw) == 1 and last_ctx:
        # Pre-ladder state file (single int): infer the tier it nagged at so
        # the format upgrade alone doesn't count as a tier escalation.
        for i, t in enumerate(tiers, 1):
            if last_ctx >= t[1]:
                last_tier = i
except Exception:
    last_ctx = last_tier = last_post = 0

pct = ctx * 100 // win
left = max(0, win - ctx) // 1000
ctx_k, win_k = ctx // 1000, win // 1000

how = ("run the pre-compact-synthesis skill in SELF-COMPACT mode: full synthesis, write the "
       "resume baton, spawn ~/OPS/.claude-config/bin/compact-cycle.sh --target <this tmux "
       "session>, then END YOUR TURN so the compactor can fire /compact"
       if os.environ.get("IN_TMUX")
       else "run the pre-compact-synthesis skill, then tell the operator the runway is clear "
            "for a manual /compact (this session is not in tmux, so no self-compact)")

if mode == "posttool":
    if pgap is None:
        sys.exit(0)
    if last_post and ctx < last_post + pgap:
        sys.exit(0)
    # Record BEFORE emitting so a crash can never inject-spam.
    try:
        with open(state, "w") as f:
            f.write(f"{last_ctx} {last_tier} {ctx}")
    except Exception:
        sys.exit(0)
    if name == "CRITICAL":
        msg = (f"[context-watch mid-turn] CRITICAL — context ~{ctx_k}K/{win_k}K (~{pct}%). "
               f"MANDATORY: at the next safe point in THIS turn, stop — do not open new work — and {how}. "
               f"~{left}K tokens remain; at ~98% synthesis becomes impossible and this session's work "
               f"is stranded.")
    else:
        msg = (f"[context-watch mid-turn] URGENT — context ~{ctx_k}K/{win_k}K (~{pct}%). "
               f"Wrap the current step and move to the compact ritual within this turn or immediately "
               f"after it: {how}. Synthesis + compact needs ~40-60K of headroom; ~{left}K remains and "
               f"every further tool call spends it.")
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PostToolUse", "additionalContext": msg}}))
    sys.exit(0)

# stop mode: fire on tier escalation, on the every-stop tier, or after enough growth.
if not (tier > last_tier or gap == 0 or not last_ctx or ctx >= last_ctx + gap):
    sys.exit(0)

# Record BEFORE blocking so a crash can never nag-spam.
try:
    with open(state, "w") as f:
        f.write(f"{ctx} {tier} {last_post}")
except Exception:
    sys.exit(0)

core = f"[context-watch] {name} — context ~{ctx_k}K of {win_k}K (~{pct}%)."
if name == "NOTICE":
    body = (f" If the work is at a natural break, {how}. If you are mid-critical-step, finish that "
            f"step first — this reminder returns after ~{gap // 1000}K more tokens. Do not treat this "
            f"as a session boundary: synthesis then continue as one body of work.")
elif name == "WARNING":
    body = (f" Finish the current step, then run the compact ritual BEFORE starting anything new: "
            f"{how}. Past ~86% the room for a full synthesis starts disappearing — do not defer this "
            f"twice. This reminder returns after ~{gap // 1000}K more tokens. Not a session boundary: "
            f"synthesis then continue as one body of work.")
elif name == "URGENT":
    body = (f" STOP starting new work. Run the compact ritual NOW: {how}. Synthesis + compact needs "
            f"~40-60K of headroom; ~{left}K remains and every further tool call spends it. This "
            f"reminder returns after ~{gap // 1000}K more tokens and becomes unconditional at 92%.")
else:
    body = (f" MANDATORY COMPACT — do not start ANY new work and do not run further investigation. "
            f"Immediately {how}. ~{left}K tokens remain; at ~98% synthesis becomes impossible and the "
            f"session's work is stranded (this exact failure has already happened once). This warning "
            f"fires on EVERY stop until the ritual runs.")
print(json.dumps({"decision": "block", "reason": core + body}))
PY
exit 0
