#!/usr/bin/env bash
# context-watch.sh — context-usage escalation ladder (Stop + PostToolUse).
#
# Modes (first arg):
#   stop      (default) Stop hook: block the stop with an escalating nag telling
#             the agent to run the compact ritual (pre-compact-synthesis skill
#             -> compact-cycle.sh self-compact).
#   posttool  PostToolUse hook: once usage reaches URGENT, inject a matching
#             warning MID-TURN via additionalContext. Stop hooks only fire
#             between turns — a long tool-calling turn once ran from 65% to 98%
#             before its first Stop event and lost the room to synthesize. This
#             mode is the fix: the turn can no longer outrun the nag.
#   readout   UserPromptSubmit hook: a calm one-line context annotation, never a
#             block. Below the window ladder it is boundary-aware: a per-turn
#             weight plus a transcript-derived natural break (a closed task, a
#             landed push/merge, a returned workflow, a >2h idle gap, a branch
#             switch) pick which of three rest-stop texts it prints. The per-turn
#             numbers are noise filters on WHEN it speaks (see the readout
#             branch), never shown to the agent as a reason to act.
#
# Registration: Stop hook (no arg) + PostToolUse hook (matcher ".*", arg
# `posttool`) + UserPromptSubmit hook (matcher ".*", arg `readout`) in the
# Stage 1 settings.json template — settings.json is a Level 1 file owned by
# linuxploitacious, so a new deploy picks them up automatically; see
# DEPLOYMENT.md ("a new hook means registering it in the Stage 1 settings.json").
# Hook config is session-cached: changes land at the next session launch.
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
import json, os, re, sys


def _parse_ts(s):
    # Transcript timestamps are ISO-8601 UTC like "2026-09-01T20:34:34.485Z".
    from datetime import datetime, timezone
    if not s:
        return None
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1]
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except Exception:
            pass
    return None


def detect_boundary(tp):
    # Read the transcript tail (last ~300 parseable entries is enough) for a
    # NATURAL BREAK: (a) a TaskUpdate marked completed in the last turn, (b) a
    # `gh pr merge` / `git push` that landed without an error result, (c) a
    # Workflow return in the last turn, (d) >2h between the newest entry and the
    # assistant entry before it, (e) a branch switch across the window.
    # Returns (bool, reason). Fail-safe: any trouble yields (False, "") so a
    # readout still prints the plain informational line.
    try:
        size = os.path.getsize(tp)
        with open(tp, "rb") as f:
            f.seek(max(0, size - 3_000_000))
            chunk = f.read().decode("utf-8", "replace")
    except Exception:
        return (False, "")
    entries = []
    for ln in chunk.splitlines()[-300:]:
        # A byte-seek can slice the first line mid-JSON; json.loads just skips it.
        try:
            entries.append(json.loads(ln))
        except Exception:
            continue
    if not entries:
        return (False, "")

    def blocks(e):
        c = (e.get("message") or {}).get("content")
        return c if isinstance(c, list) else []

    def is_user_prompt(e):
        if e.get("type") != "user":
            return False
        c = (e.get("message") or {}).get("content")
        if isinstance(c, list):
            # A tool_result-only user entry is the tail of a turn, not a prompt.
            return any(isinstance(b, dict) and b.get("type") != "tool_result" for b in c)
        return True  # string content (or absent) is a genuine typed prompt

    # tool_use_id -> is_error, from every tool_result block in the window.
    results = {}
    for e in entries:
        for c in blocks(e):
            if isinstance(c, dict) and c.get("type") == "tool_result":
                results[c.get("tool_use_id")] = bool(c.get("is_error"))

    # (e) branch switched between the first and last entries that carry a branch.
    bkey = "g" + "itBranch"
    branches = [e.get(bkey) for e in entries if e.get(bkey)]
    if len(branches) >= 2 and branches[0] != branches[-1]:
        return (True, "branch switched")

    # (d) operator stepped away: the newest timestamped entry sits >2h after the
    # most recent assistant entry before it (the readout fires at UserPromptSubmit,
    # so the newest entry is the just-typed prompt).
    ts = [(_parse_ts(e.get("timestamp")), e.get("type")) for e in entries if e.get("timestamp")]
    ts = [(t, ty) for (t, ty) in ts if t]
    if len(ts) >= 2:
        latest = ts[-1][0]
        prev_assist = next((t for t, ty in reversed(ts[:-1]) if ty == "assistant"), ts[-2][0])
        if (latest - prev_assist).total_seconds() > 7200:
            return (True, "returned after a break")

    # Last turn (signals a and c are last-turn only). At UserPromptSubmit the
    # newest entry is a fresh prompt, so the just-finished turn is the span
    # BEFORE it; otherwise the tail itself is the current turn.
    prompts = [i for i, e in enumerate(entries) if is_user_prompt(e)]
    if prompts:
        last_p = prompts[-1]
        if last_p == len(entries) - 1 and len(prompts) >= 2:
            last_turn = entries[prompts[-2]:last_p]
        else:
            last_turn = entries[last_p:]
    else:
        last_turn = entries

    for e in last_turn:
        for c in blocks(e):
            if not isinstance(c, dict) or c.get("type") != "tool_use":
                continue
            name = c.get("name")
            if name == "TaskUpdate" and re.search(  # (a) a task closed this turn
                    r'"status"\s*:\s*"completed"', json.dumps(c.get("input") or {})):
                return (True, "task closed")
            if name == "Workflow" and c.get("id") in results:  # (c) workflow returned
                return (True, "workflow returned")

    # (b) a push or PR merge that landed cleanly (whole window, not just last turn).
    for e in entries:
        for c in blocks(e):
            if not isinstance(c, dict) or c.get("type") != "tool_use" or c.get("name") != "Bash":
                continue
            cmd = str((c.get("input") or {}).get("command") or "")
            if ("gh pr merge" in cmd) or ("git push" in cmd):
                cid = c.get("id")
                if cid in results and not results[cid]:
                    return (True, "change landed")
    return (False, "")


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

# Per-turn boundary tiers, read only by the readout below and always BELOW the
# window ladder. These absolute token counts are NOISE FILTERS on WHEN the
# readout speaks, not a cost model: carrying context is cheap per turn here (a
# small cache-read multiple, not a fresh charge), so the number never means
# "act". A rest-stop nudge only earns attention once a turn is genuinely heavy.
BREAK_TURN = 250_000   # this heavy AND a real boundary -> "natural break point"
LONG_TURN  = 400_000   # this heavy regardless of a boundary -> "run long" backstop

# how = the compact route. Defined here, above the readout, so the readout texts
# and the ladder nags below share one definition.
how = ("run the pre-compact-synthesis skill in SELF-COMPACT mode: full synthesis, write the "
       "resume baton, spawn ~/OPS/.claude-config/bin/compact-cycle.sh --target <this tmux "
       "session>, then END YOUR TURN so the compactor can fire /compact"
       if os.environ.get("IN_TMUX")
       else "run the pre-compact-synthesis skill, then tell the operator a manual /compact is clear "
            "to fire (this session is not in tmux, so no self-compact)")

# --- readout mode: ALWAYS handled here, at EVERY tier, and always exits. ---
# This branch must come before any ladder logic. A readout is a passive
# annotation and must never block or touch ladder state, so it uses its own
# readout-<sid> state file and prints plain text, never a block payload.
if mode == "readout":
    rstate = os.path.join(os.environ["RUNDIR"], f"readout-{sid}")
    last_r = 0
    try:
        with open(rstate) as f:
            last_r = int((f.read().strip() or "0").split()[0])
    except Exception:
        last_r = 0
    # One line per ~100K of growth: enough to stay oriented, rare enough to ignore.
    if ctx - last_r < int(os.environ.get("READOUT_GAP") or 100_000):
        sys.exit(0)
    try:
        with open(rstate, "w") as f:
            f.write(str(ctx))
    except Exception:
        sys.exit(0)
    pct0 = int(round(100.0 * ctx / win))
    at_boundary, _why = detect_boundary(tp)
    if at_boundary and ctx >= BREAK_TURN:
        # A real break AND a turn heavy enough to be worth the nudge. Rest-stop
        # framing, never pressure: a compact here is hygiene, not scarcity.
        print("[context] Natural break point. A compact here hands the next stretch "
              "a clean desk, pre-authorized, no ask. Run pre-compact-synthesis, then "
              f"{how}. Or keep rolling if you'd rather; nothing is at risk either "
              "way. Pick the next clean seam.")
    elif ctx >= LONG_TURN:
        # Long-session backstop (replaces the old scarcity nag). Still calm: the
        # four artifacts carry the work across a reset, so nothing is at stake.
        print("[context] This session has run long; a clean handoff is the kind thing "
              f"for the next stretch. Run pre-compact-synthesis, then {how}. Nothing is "
              "lost either way: git, memory, the task list, and the baton carry the work "
              "forward as one body.")
    else:
        # Below the floor. The bare number is the operator's ground truth (added
        # 2026-07-25 after a session substituted "this feels long" for data and
        # pushed toward closeout at ~20%), not a call to act.
        print(f"[context] ~{ctx // 1000}K of {win // 1000}K in play (~{pct0}%). Ample "
              "headroom, no action needed. Self-compact is pre-authorized at any "
              "milestone; you never need to ask, and context is never a reason to wrap "
              "up or cut quality.")
    sys.exit(0)

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

if ctx < last_ctx or ctx < last_post:
    # Context SHRANK since the last nag (a /compact ran mid-session under the
    # same session id): the stale high-water marks would suppress every re-nag
    # below CRITICAL for the rest of the session — start a fresh epoch.
    last_ctx = last_tier = last_post = 0

pct = ctx * 100 // win
left = max(0, win - ctx) // 1000
ctx_k, win_k = ctx // 1000, win // 1000

if mode == "posttool":
    if pgap is None:
        sys.exit(0)
    # Tier crossing fires immediately here too (the ladder-wide guarantee):
    # derive the tier the last injection happened at from its recorded ctx.
    last_ptier = 0
    for i, t in enumerate(tiers, 1):
        if last_post >= t[1]:
            last_ptier = i
    if last_post and tier <= last_ptier and ctx < last_post + pgap:
        sys.exit(0)
    # Record BEFORE emitting so a crash can never inject-spam.
    try:
        with open(state, "w") as f:
            f.write(f"{last_ctx} {last_tier} {ctx}")
    except Exception:
        sys.exit(0)
    if name == "CRITICAL":
        msg = (f"[context-watch mid-turn] CRITICAL: context ~{ctx_k}K/{win_k}K (~{pct}%). "
               f"At the next safe point in THIS turn, wrap what is open, do not start new work, and {how}. "
               f"About {left}K of window headroom is left and a full synthesis wants ~40-60K, so move to "
               f"it now rather than opening more.")
    else:
        msg = (f"[context-watch mid-turn] URGENT: context ~{ctx_k}K/{win_k}K (~{pct}%). "
               f"Wrap the current step, then move to the compact ritual within this turn or right after "
               f"it: {how}. About {left}K of window headroom is left and a full synthesis wants ~40-60K, so "
               f"moving now keeps the next stretch clean; nothing is at risk.")
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

core = f"[context-watch] {name}: context ~{ctx_k}K of {win_k}K (~{pct}%)."
if name == "NOTICE":
    body = (f" If the work is at a natural break, {how}. If you are mid-critical-step, finish that "
            f"step first; this reminder returns after ~{gap // 1000}K more tokens. Do not treat this "
            f"as a session boundary: synthesis then continue as one body of work.")
elif name == "WARNING":
    body = (f" Finish the current step, then run the compact ritual BEFORE starting anything new: "
            f"{how}. Past ~86%, run the synthesis now; the compactor needs room to work, so do not defer this "
            f"twice. This reminder returns after ~{gap // 1000}K more tokens. Not a session boundary: "
            f"synthesis then continue as one body of work.")
elif name == "URGENT":
    body = (f" Stop starting new work and run the compact ritual now: {how}. About {left}K of window "
            f"headroom is left and a full synthesis wants ~40-60K, so running it now keeps the next "
            f"stretch clean; nothing is at risk. This reminder returns after ~{gap // 1000}K more "
            f"tokens and becomes unconditional at 92%.")
else:
    body = (f" Compact now: do not start any new work and do not open further investigation. "
            f"Immediately {how}. About {left}K of window headroom is left and a full synthesis wants "
            f"~40-60K, so running it now keeps the next stretch clean (a late compact once lost a "
            f"session's synthesis). This reminder fires on every stop until the ritual runs.")
print(json.dumps({"decision": "block", "reason": core + body}))
PY
exit 0
