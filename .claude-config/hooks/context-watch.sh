#!/usr/bin/env bash
# context-watch.sh: context-usage escalation ladder (Stop + PostToolUse), with a
# separate backstop for sub-agent lanes.
#
# Modes (first arg):
#   stop      (default) Stop hook: block the stop with an escalating nag telling
#             the agent to run the compact ritual (the pre-compact-synthesis
#             skill, then tell the Operator a manual /compact is clear to fire).
#   posttool  PostToolUse hook: once usage reaches URGENT, inject a matching
#             warning MID-TURN via additionalContext. Stop hooks only fire
#             between turns: a long tool-calling turn once ran from 65% to 98%
#             before its first Stop event and lost the room to synthesize. This
#             mode is the fix: the turn can no longer outrun the nag. It is also
#             the only mode that speaks inside a lane (below).
#   readout   UserPromptSubmit hook: a calm one-line context annotation, never a
#             block. Below the window ladder it is boundary-aware: a per-turn
#             weight plus a transcript-derived natural break (a closed task, a
#             landed push/merge, a returned workflow, a >2h idle gap, a branch
#             switch) pick which of three rest-stop texts it prints. The per-turn
#             numbers are noise filters on WHEN it speaks (see the readout
#             branch), never shown to the agent as a reason to act.
#
# Who compacts. OPS ships no self-compaction: under T3 Code the Operator fires
# /compact in the composer, in a terminal they type it, and Claude Code's own
# auto-compaction near the end of the window is the backstop. Sessions in tmux
# or herdr are run by hand and never self-compact. (The retired tmux typer,
# bin/compact-cycle.sh, could not tell a finished compaction from a failed one,
# and a resume sent after a failed compact resumed work on a thread whose
# history was never summarized.) So every route this hook prints ends with the
# Operator's /compact, after the synthesis.
#
# Registration: Stop hook (no arg) + PostToolUse hook (matcher ".*", arg
# `posttool`) + UserPromptSubmit hook (matcher ".*", arg `readout`) in the
# Stage 1 settings.json template. settings.json is a Level 1 file owned by
# linuxploitacious, so a new deploy picks them up automatically; see
# DEPLOYMENT.md ("a new hook means registering it in the Stage 1 settings.json").
# Hook config is session-cached: changes land at the next session launch.
#
# Context is measured from the transcript's last assistant `usage` entry
# (input + cache_read + cache_creation tokens): the actual API context, not a
# byte-size guess (transcripts run 20-160MB; bytes are meaningless).
#
# Escalation ladder for the main session, fractions of CC_CONTEXT_WINDOW
# (default 1000000; export 200000 on a 200K-window setup and every tier scales):
#   65%  NOTICE    re-nag after +75K growth
#   78%  WARNING   re-nag after +40K
#   86%  URGENT    re-nag after +20K    posttool active from here (+15K throttle)
#   92%  CRITICAL  every stop           posttool throttle tightens to +8K
# Crossing INTO a higher tier always fires immediately, growth gap or not.
# Legacy overrides still honored (tier 1 only): CC_COMPACT_NAG_TOKENS
# (threshold), CC_COMPACT_RENAG_TOKENS (re-nag gap); prefer CC_CONTEXT_WINDOW.
# State per session id under ~/.claude-compact-cycle/ (the session-state
# directory every hook shares; the name predates the retired typer), one line:
# "<last_stop_ctx> <last_stop_tier> <last_posttool_ctx>".
#
# Sub-agent (lane) awareness. A hook input carrying agent_id is running INSIDE a
# sub-agent lane, not the main session (the hooks docs: agent_id is "present
# only when the hook fires inside a subagent call"). A lane is not a session:
# it does not compact on purpose and has no early checkpoint. It runs as high
# as the work needs and returns a remainder the foreman respawns from
# (CONTEXT/how-i-work.md P12). An earlier 250K/400K lane ladder made lanes stop
# after one to three items, and every continuation lane re-paid its reading.
# What a lane gets is a two-stage backstop near its REAL window, sized from the
# lane transcript's model (LANE_WINDOWS below), not from CC_CONTEXT_WINDOW:
#   LANE_REMIND_PCT (60)  reminder: keep going, plan to finish, skip large reads
#                         you do not need; re-injected after +10% of window
#   LANE_WRAP_PCT   (80)  wrap up: at the next natural break commit what is
#                         green if the brief allows, write the precise
#                         handoff note, return; re-injected after +2.5% (10K floor)
# Crossing into wrap fires immediately, growth gap or not. LANE_WINDOW_OVERRIDE
# (tokens) replaces the model map for tests and emergencies. Auto-compaction is
# on in the Stage-1 settings (autoCompactEnabled true, DISABLE_AUTO_COMPACT "0")
# and reaches lanes too: a 1M lane would compact near 967K and lose the working
# detail its handoff note needs, so its backstop asks it to return first.
# A Haiku 5.5 lane is the exception (its LANE_CEILINGS row): Stage-1 pins it a
# 100K compaction window (modelSettings), so it compacts on its own well below
# the 100K long-context price and gets no reminder and no wrap, only one
# backstop at LANE_CEILING_BACKSTOP_PCT (95) of its ceiling, which fires only if
# compaction did not. Both stages ride PostToolUse (additionalContext): a lane's
# completion fires SubagentStop (which settings.json does not register), and
# blocking a SubagentStop would force the lane to CONTINUE rather than return,
# the opposite of a ceiling. So stop and readout invocations in a lane stay
# silent. The lane's context is read from its OWN transcript: the hook input's
# transcript_path is the MAIN transcript even in a lane, so the lane transcript
# is derived as <main without .jsonl>/subagents/agent-<agent_id>.jsonl (a
# recursive glob covers workflow lanes that nest under subagents/workflows/).
# Lane throttle state keys on agent_id, because session_id in a lane is the
# MAIN id and would collide across concurrent lanes. Main-session behaviour is
# unchanged: the lane branch is skipped whenever agent_id is absent.
#
# Suppressed when:
#   - stop_hook_active (we already blocked this stop; loop guard; stop mode)
#   - inside a lane, any mode but posttool (above)
#   - CC_CONTEXT_WATCH=0 (all), CC_CONTEXT_WATCH_POSTTOOL=0 (posttool only),
#     not enough data, or no usable JSON parser
#   - no python3 (see limitation note below)
#
# Limitation (accepted, not a bug): the simple payload fields (session_id,
# transcript_path, stop_hook_active, agent_id) go through hooklib.sh's
# hook_field, which falls back through jq/python/py same as every other hook.
# But the actual context measurement below re-reads the transcript file and
# scans its tail for the last `usage` entry: that byte-seek + JSONL scan stays
# python3-only, so hosts without python3 (e.g. Windows Git Bash) never get the
# nag, in ANY mode. This is fail-open BY DESIGN, unlike git-guard/secrets-guard
# which fail CLOSED: a missed reminder just means the Operator compacts on their
# own cue instead of this hook's; the compact ritual itself
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

# Simple field reads use hook_field (jq-first, python3/python/py fallback):
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
AGENT_ID="$(printf '%s' "$PAYLOAD" | hook_field agent_id)" || exit 0

RUNDIR="${CC_CYCLE_RUNDIR:-$HOME/.claude-compact-cycle}"
mkdir -p "$RUNDIR" 2>/dev/null || exit 0

# The transcript byte-tail scan (below) needs python3 specifically: jq has no
# clean way to seek N bytes from EOF in a multi-hundred-MB file and re-parse a
# JSONL tail. See the limitation note at the top of this file.
command -v python3 >/dev/null 2>&1 || exit 0

CW_TRANSCRIPT="$TRANSCRIPT" CW_SID="$SID" CW_AGENT_ID="$AGENT_ID" RUNDIR="$RUNDIR" MODE="$MODE" \
WINDOW="${CC_CONTEXT_WINDOW:-1000000}" \
LANE_WINDOW_OVERRIDE="${LANE_WINDOW_OVERRIDE:-}" LANE_REMIND_PCT="${LANE_REMIND_PCT:-}" LANE_WRAP_PCT="${LANE_WRAP_PCT:-}" \
NAG_OVERRIDE="${CC_COMPACT_NAG_TOKENS:-}" RENAG_OVERRIDE="${CC_COMPACT_RENAG_TOKENS:-}" \
python3 - <<'PY' 2>/dev/null || exit 0
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

# --- sub-agent (lane) branch: runs ONLY when agent_id is present -------------
# See the header: a lane runs as high as the work needs and returns a
# remainder; its only ceiling is the two-stage backstop near its real window,
# or one backstop for a ruled ceiling (LANE_CEILINGS). This branch fully
# handles and exits the lane case; main-thread inputs fall straight through.

# Context window per lane model, keyed on the transcript's message.model, the id
# the API answered with (Claude Code strips a [1m] suffix before sending, so a
# transcript does not carry one). Basis: the Claude Code model-config docs
# ("Extended context": Fable 5.1, Fable 5, Sonnet 5 and Opus 4.7 and later run
# with the 1M window on every plan; Opus 4.6 and Sonnet 4.6 reach 1M only
# through their [1m] variant, which the transcript cannot show, so their bare
# ids get the safe 200K, and LANE_WINDOW_OVERRIDE=1000000 covers a [1m] lane on
# them; Haiku 4.5 is 200K) and the Sonnet 5.5 release note (1M). Older ids are
# pinned nowhere in this harness (CONTEXT/model-roles.md); add a row before
# running a lane on one. Haiku 5.5's row is a PRICE ceiling, not its window: the
# model has a native 1M window, but every rate is 5x once a request's prompt
# passes 100K tokens, so the harness keeps Haiku lanes under 100K and Stage-1
# pins its compaction window there. LANE_CEILINGS marks such rows so the stage
# text names a ceiling, not a hard window.
LANE_WINDOWS = {
    "claude-fable-5-1": 1_000_000, "claude-fable-5": 1_000_000,
    "claude-sonnet-5-5": 1_000_000, "claude-sonnet-5": 1_000_000,
    "claude-opus-5-5": 1_000_000, "claude-opus-5": 1_000_000,
    "claude-opus-4-8": 1_000_000, "claude-opus-4-7": 1_000_000,
    "claude-opus-4-6": 200_000, "claude-sonnet-4-6": 200_000,
    "claude-haiku-4-5": 200_000,
    "claude-haiku-5-5": 100_000,
}
# Family fallbacks for an id the map does not list, checked in this order (the
# Haiku 5.5 snapshot prefix must precede the wider Haiku family).
LANE_FAMILY_WINDOWS = [("claude-haiku-5-5-", 100_000), ("claude-haiku-", 200_000),
                       ("claude-fable-", 1_000_000), ("claude-sonnet-", 1_000_000),
                       ("claude-opus-", 1_000_000)]
LANE_DEFAULT_WINDOW = 1_000_000
# Ids whose row is a ruled ceiling below the model's real window (Haiku 5.5).
LANE_CEILINGS = ("claude-haiku-5-5",)
# The one stage a ceiling lane gets, as a percentage of its ceiling: just under
# the 100K price edge, well above where its auto-compaction fires.
LANE_CEILING_BACKSTOP_PCT = 95


def lane_is_ceiling(model):
    """True when the lane's size comes from a ruled ceiling, not its window. A
    [1m] suffix does not lift a ruled ceiling: the price edge is per request."""
    m = (model or "").strip().replace("[1m]", "")
    return any(m == c or m.startswith(c + "-") for c in LANE_CEILINGS)


def lane_window(model):
    """Window for a lane's model id. A [1m] suffix, should a transcript ever carry
    one, is the 1M variant by definition. An unknown id falls to its family,
    else to 1M: every current lane model is 1M, so a new id is far more likely a
    newer 1M model than an older 200K one, and the two possible errors are not
    symmetric. Guessing low would silently bring back early wrap-ups (at 160K on
    a 1M lane, on every lane, until someone noticed); guessing high fails loudly
    once (that lane ends on "Prompt is too long", the foreman sees it, the map
    gains a row)."""
    m = (model or "").strip()
    if "[1m]" in m:
        if lane_is_ceiling(m):
            m = m.replace("[1m]", "")
        else:
            return 1_000_000
    if m in LANE_WINDOWS:
        return LANE_WINDOWS[m]
    for prefix, lw in LANE_FAMILY_WINDOWS:
        if m.startswith(prefix):
            return lw
    return LANE_DEFAULT_WINDOW


def lane_pct(name, default):
    """A stage percentage from the environment, 1-100, else the default."""
    try:
        v = int(os.environ.get(name) or default)
    except Exception:
        return default
    return v if 1 <= v <= 100 else default


agent_id = os.environ.get("CW_AGENT_ID") or ""
if agent_id:
    # A lane speaks ONLY mid-turn via PostToolUse. Its own end fires SubagentStop
    # (unregistered in settings.json), and blocking a stop would force the lane to
    # CONTINUE, not return; so stop/readout in a lane are silent.
    if mode != "posttool":
        sys.exit(0)
    import glob
    # The hook input's transcript_path is the MAIN transcript even here, so derive
    # the lane's own transcript to weigh the lane's context, not the session's.
    base = tp[:-6] if tp.endswith(".jsonl") else tp
    lane_tp = os.path.join(base, "subagents", "agent-%s.jsonl" % agent_id)
    if not os.path.isfile(lane_tp):
        lane_tp = next(iter(glob.glob(
            os.path.join(glob.escape(base), "subagents", "**", "agent-%s.jsonl" % glob.escape(agent_id)),
            recursive=True)), "")
    if not lane_tp or not os.path.isfile(lane_tp):
        sys.exit(0)  # cannot locate the lane transcript: fail open, stay silent
    lctx, lmodel = 0, ""
    try:
        lsize = os.path.getsize(lane_tp)
        with open(lane_tp, "rb") as f:
            f.seek(max(0, lsize - 800_000))
            ltail = f.read().decode("utf-8", "replace")
    except Exception:
        sys.exit(0)
    for line in reversed(ltail.splitlines()):
        if '"usage"' not in line:
            continue
        try:
            le = json.loads(line)
        except Exception:
            continue
        lu = (le.get("message") or {}).get("usage") or le.get("usage") or {}
        lt = sum(int(lu.get(k) or 0) for k in
                 ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
        if lt > 0:
            lctx = lt
            lmodel = str((le.get("message") or {}).get("model") or le.get("model") or "")
            break
    if lctx <= 0:
        sys.exit(0)
    # The lane's window: the override, else the model map. Stage thresholds are
    # percentages of it; an inverted pair (remind at or above wrap) is a typo, and
    # the defaults are safer than a one-stage ladder.
    try:
        lwin = int(os.environ.get("LANE_WINDOW_OVERRIDE") or 0)
    except Exception:
        lwin = 0
    ceiling = lane_is_ceiling(lmodel)
    if lwin <= 0:
        lwin = lane_window(lmodel)
    elif ceiling:
        # The emergency override may lower a ruled ceiling, never raise it.
        lwin = min(lwin, lane_window(lmodel))
    remind_pct, wrap_pct = lane_pct("LANE_REMIND_PCT", 60), lane_pct("LANE_WRAP_PCT", 80)
    if remind_pct >= wrap_pct:
        remind_pct, wrap_pct = 60, 80
    if ceiling:
        # A ceiling lane compacts by design below its ceiling, so the reminder
        # and wrap knobs do not apply: one backstop stage, reached only when its
        # auto-compaction did not fire.
        stage = 2 if lctx >= lwin * LANE_CEILING_BACKSTOP_PCT // 100 else 0
    else:
        remind_at, wrap_at = lwin * remind_pct // 100, lwin * wrap_pct // 100
        stage = 2 if lctx >= wrap_at else 1 if lctx >= remind_at else 0
    # Throttle per LANE: session_id in a lane is the MAIN id, so keying on it
    # would let concurrent lanes share one throttle. agent_id is unique per lane.
    # State: "<last injected ctx> <its stage>".
    lstate = os.path.join(os.environ["RUNDIR"], "lane-%s" % re.sub(r"[^A-Za-z0-9_-]", "", agent_id)[:64])
    last_l = last_stage = 0
    try:
        with open(lstate) as f:
            parts = (f.read().split() + ["0", "0"])[:2]
        last_l, last_stage = int(parts[0] or 0), int(parts[1] or 0)
    except Exception:
        last_l = last_stage = 0
    # Auto-compaction reuses the lane id. Forget its previous backstop after
    # the context falls, including quiet calls below the threshold: otherwise
    # a 95K -> 20K -> 95K refill stays throttled until 105K, past the ceiling.
    if stage == 0:
        if last_l:
            try:
                with open(lstate, "w") as f:
                    f.write("0 0")
            except OSError:
                pass
        sys.exit(0)
    if lctx < last_l:
        last_l = last_stage = 0
    # Re-inject on a first hit, on crossing into wrap, or after enough growth:
    # +10% of window in the reminder stage (one nudge per ~100K on a 1M lane)
    # and +2.5% with a 10K floor in wrap (25K on 1M: the lane must keep hearing
    # it as the edge nears).
    gap = lwin // 10 if stage == 1 else max(10_000, lwin // 40)
    if last_l and stage <= last_stage and lctx < last_l + gap:
        sys.exit(0)
    try:  # record before emitting so a crash can never inject-spam
        with open(lstate, "w") as f:
            f.write(f"{lctx} {stage}")
    except Exception:
        sys.exit(0)
    lk, lwk, lpct = lctx // 1000, lwin // 1000, lctx * 100 // lwin
    # A ceiling row (Haiku 5.5) is not the model's limit: the lane would run on
    # past it, so the text names the ruled ceiling instead of an API-error edge.
    of_what = (f"of the ~{lwk}K ceiling set for its model (~{lpct}%)" if ceiling
               else f"of its ~{lwk}K window (~{lpct}%)")
    # Wording note: verify-ops check 20 bans scarcity words in emitted strings,
    # so the doctrine's "remainder" is "handoff note" here.
    ret = ("At the next natural break, never mid-edit: "
           "commit what is green if your brief allows, write a precise handoff note (what is done, what "
           "is left, where the state lives) into your report, and return. ")
    if stage == 2 and ceiling:
        lmsg = (f"[context-watch lane] Backstop: this lane carries ~{lk}K {of_what}. This model's lanes "
                "auto-compact well below here, so compaction did not fire (auto-compaction is off, or Claude "
                "Code stopped it after rapid refills), and past the ceiling every request bills at 5x. " + ret +
                "A brief may set its own lower ceiling. A lane returns a handoff note.")
    elif stage == 2:
        lmsg = (f"[context-watch lane] Wrap up: this lane carries ~{lk}K {of_what}, near its context limit, "
                "where auto-compaction would summarize the lane and drop the working detail its handoff note "
                "needs. " + ret + "A brief may set its own lower ceiling. A lane returns a handoff note; it "
                "does not compact.")
    else:
        lmsg = (f"[context-watch lane] Reminder: this lane carries ~{lk}K {of_what}. "
                "Keep going and plan to finish from here: prefer targeted reads over large new ones you do "
                f"not need, and keep your handoff note current. Wrap-up guidance arrives at ~{wrap_pct}%; "
                "a brief may set its own lower ceiling.")
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PostToolUse", "additionalContext": lmsg}}))
    sys.exit(0)

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
# and the ladder nags below share one definition. One route on every host: OPS
# has no self-compaction (see the header), so the session synthesizes and the
# Operator fires /compact.
how = ("run the pre-compact-synthesis skill, then tell the Operator a manual /compact is clear "
       "to fire")

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
              "headroom, no action needed. A compact is pre-authorized at any milestone "
              "(synthesis, then the Operator's /compact); you never need to ask, and "
              "context is never a reason to wrap up or cut quality.")
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
    # below CRITICAL for the rest of the session: start a fresh epoch.
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
            f"{how}. Past ~86%, run the synthesis now; it needs room to work, so do not defer this "
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
