#!/usr/bin/env bash
# context-watch-selftest.sh: prove the escalation ladder fires, throttles,
# escalates, and stays silent exactly where designed, for the main session and
# for sub-agent lanes (the agent_id backstop sized from the lane's model) and for T3
# delegated lanes (silence at Stop and the readout, the wrap-up text at PostToolUse, by
# the lane-class answer). Run after deploying the
# hooks and any time by hand. Companion to guard-selftest.sh, with one
# deliberate difference: context-watch is fail-OPEN (a dead nag costs a manual
# compact, not a security hole), so a missing python3 SKIPS with exit 0 here
# instead of failing: the hook itself is documented to go silent there.
#
# Exit 0 = every case behaves (or python3 absent => skip); 1 = ladder defect.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "context-watch-selftest: SKIP (no python3: hook is documented fail-open without it)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CC_CYCLE_RUNDIR="$WORK/rundir"
fails=0

# Hermetic lane-class (bin/lane-class). Answers LANE_STUB_CLASS (default foreman), logs one
# line per call to LANE_STUB_LOG and keeps the stdin it was given in LANE_STUB_STDIN, so a
# case can assert how often it is asked and what it is told. Exported for every case: the
# host's own classifier must never run against test payloads.
export LANE_STUB_LOG="$WORK/lane-class-calls" LANE_STUB_STDIN="$WORK/lane-class-stdin"
cat > "$WORK/lane-class-stub" <<'STUB'
#!/usr/bin/env bash
cat >> "$LANE_STUB_STDIN"; printf '\n' >> "$LANE_STUB_STDIN"
printf 'ask\n' >> "$LANE_STUB_LOG"
[ -z "${LANE_STUB_SLEEP:-}" ] || sleep "$LANE_STUB_SLEEP"
printf '%s\n' "${LANE_STUB_CLASS:-foreman}"
STUB
chmod +x "$WORK/lane-class-stub"
export LANE_CLASS="$WORK/lane-class-stub"

mk_transcript() { # $1=path $2=tokens
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
line = json.dumps({"message": {"usage": {"input_tokens": int(sys.argv[2]),
        "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}})
open(sys.argv[1], "w").write("junk not json\n" + line + "\n")
PYEOF
}

run() { # $1=mode $2=tokens $3=sid [$4=stop_hook_active]
  local tp="$WORK/t-$2-$3.jsonl"
  mk_transcript "$tp" "$2"
  printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":%s}' \
    "$3" "$tp" "${4:-false}" | env -u TMUX -u T3CODE_THREAD_ID -u T3CODE_HOME -u CLAUDE_CODE_SESSION_ID \
    bash "$DIR/context-watch.sh" "$1"
}

# Build a transcript that carries one boundary signal (task|push|merge|workflow|
# gap|branch) or none, plus a final usage entry of $2 tokens. Mirrors the real
# entry shapes: tool_use blocks in assistant messages, tool_result blocks in user
# messages, timestamp + branch on entries.
mk_boundary() { # $1=path $2=tokens $3=signal
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
path, tokens, signal = sys.argv[1], int(sys.argv[2]), sys.argv[3]
def usage(n): return {"input_tokens": n, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
rows = []
if signal == "task":
    # Trailing new prompt = the UserPromptSubmit moment; the closed task is the
    # turn BEFORE it, so this also exercises the last-turn lookback.
    rows.append({"type": "user", "message": {"role": "user", "content": "go"}})
    rows.append({"type": "assistant", "message": {"role": "assistant",
        "content": [{"type": "tool_use", "name": "TaskUpdate", "id": "t1",
                     "input": {"tasks": [{"id": "1", "status": "completed"}]}}],
        "usage": usage(tokens)}})
    rows.append({"type": "user", "message": {"role": "user", "content": "next"}})
elif signal in ("push", "merge"):
    cmd = "git push origin master" if signal == "push" else "gh pr merge 5 --squash --delete-branch"
    rows.append({"type": "user", "message": {"role": "user", "content": "go"}})
    rows.append({"type": "assistant", "message": {"role": "assistant",
        "content": [{"type": "tool_use", "name": "Bash", "id": "b1", "input": {"command": cmd}}]}})
    rows.append({"type": "user", "message": {"role": "user",
        "content": [{"type": "tool_result", "tool_use_id": "b1", "is_error": False, "content": "ok"}]}})
    rows.append({"type": "assistant", "message": {"role": "assistant",
        "content": [{"type": "text", "text": "done"}], "usage": usage(tokens)}})
elif signal == "workflow":
    rows.append({"type": "user", "message": {"role": "user", "content": "go"}})
    rows.append({"type": "assistant", "message": {"role": "assistant",
        "content": [{"type": "tool_use", "name": "Workflow", "id": "w1", "input": {}}],
        "usage": usage(tokens)}})
    rows.append({"type": "user", "message": {"role": "user",
        "content": [{"type": "tool_result", "tool_use_id": "w1", "is_error": False, "content": "result"}]}})
elif signal == "gap":
    rows.append({"type": "assistant", "timestamp": "2026-09-04T10:00:00.000Z",
        "message": {"role": "assistant", "content": [{"type": "text", "text": "work"}], "usage": usage(tokens)}})
    rows.append({"type": "user", "timestamp": "2026-09-04T13:30:00.000Z",
        "message": {"role": "user", "content": "back"}})
elif signal == "branch":
    rows.append({"type": "assistant", "gitBranch": "master",
        "message": {"role": "assistant", "content": [{"type": "text", "text": "work"}]}})
    rows.append({"type": "assistant", "gitBranch": "feature/x",
        "message": {"role": "assistant", "content": [{"type": "text", "text": "more"}], "usage": usage(tokens)}})
else:  # none
    rows.append({"message": {"usage": usage(tokens)}})
with open(path, "w") as f:
    f.write("junk not json\n")
    for r in rows:
        f.write(json.dumps(r) + "\n")
PYEOF
}

run_b() { # $1=tokens $2=sid $3=signal  (always readout mode; no tmux)
  local tp="$WORK/b-$3-$2.jsonl"
  mk_boundary "$tp" "$1" "$3"
  printf '{"session_id":"%s","transcript_path":"%s"}' "$2" "$tp" \
    | env -u TMUX -u T3CODE_THREAD_ID -u T3CODE_HOME -u CLAUDE_CODE_SESSION_ID \
        bash "$DIR/context-watch.sh" readout
}

chk_state() { # $1=label $2=sid $3=expected-literal-state-contents
  local got; got="$(cat "$CC_CYCLE_RUNDIR/nag-$2" 2>/dev/null || echo '<missing>')"
  if [ "$got" = "$3" ]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s (state "%s", want "%s")\n' "$1" "$got" "$3"; fails=$((fails + 1)); fi
}

chk() { # $1=label $2=expected-substr-or-EMPTY $3=actual-output
  if [ "$2" = "EMPTY" ]; then
    if [ -z "$3" ]; then printf '  PASS  %s\n' "$1"
    else printf '  FAIL  %s (expected silence, got: %.100s)\n' "$1" "$3"; fails=$((fails + 1)); fi
  else
    case "$3" in
      *"$2"*)
        if printf '%s' "$3" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
          printf '  PASS  %s\n' "$1"
        else printf '  FAIL  %s (matched but not valid JSON)\n' "$1"; fails=$((fails + 1)); fi ;;
      *) printf '  FAIL  %s (wanted "%s", got: %.100s)\n' "$1" "$2" "${3:-<silence>}"; fails=$((fails + 1)) ;;
    esac
  fi
}

echo "context-watch-selftest:"
# stop-mode ladder
chk "silent below the ladder (50%)"        EMPTY      "$(run stop 500000 a)"
chk "NOTICE fires at 66%"                  '] NOTICE'  "$(run stop 660000 a)"
chk "NOTICE growth-throttled (+40K<75K)"   EMPTY      "$(run stop 700000 a)"
chk "NOTICE re-fires after +80K"           '] NOTICE'  "$(run stop 740000 a)"
# escalation-override isolate: growth (+36K) is BELOW the new tier's own gap
# (WARNING +40K), so only the tier-crossing clause can fire this: removing
# `tier > last_tier` from the fire condition makes this case fail.
chk "NOTICE at 74% (escalation setup)"     '] NOTICE'  "$(run stop 745000 a2)"
chk "tier crossing beats throttle (+36K<40K)" 'WARNING' "$(run stop 781000 a2)"
chk "fresh session jumps straight URGENT"  'URGENT'   "$(run stop 870000 b)"
chk "URGENT growth-throttled (+5K<20K)"    EMPTY      "$(run stop 875000 b)"
chk "CRITICAL fires at 92%"                'CRITICAL' "$(run stop 925000 b)"
chk "CRITICAL fires on EVERY stop"         'CRITICAL' "$(run stop 925000 b)"
chk "stop_hook_active loop guard"          EMPTY      "$(run stop 930000 b true)"
# posttool mode
chk "posttool silent below 86%"            EMPTY               "$(run posttool 700000 c)"
chk "posttool injects URGENT mid-turn"     'mid-turn] URGENT'  "$(run posttool 870000 c)"
chk "posttool throttled (+2K<15K)"         EMPTY               "$(run posttool 872000 c)"
chk "posttool CRITICAL mid-turn"           'mid-turn] CRITICAL' "$(run posttool 930000 c)"
chk "posttool emits additionalContext"     'additionalContext' "$(run posttool 950000 c2)"
# posttool tier-crossing isolate: growth (+2K) is below CRITICAL's +8K
# throttle, so only the derived-tier override can fire this injection.
chk "posttool URGENT near tier top"        'mid-turn] URGENT'   "$(run posttool 919000 c3)"
chk "posttool tier crossing beats throttle (+2K<8K)" 'mid-turn] CRITICAL' "$(run posttool 921000 c3)"
# state-field integrity: posttool must write field 3 and preserve fields 1+2
# byte-for-byte: asserted on the literal state file, not message output.
chk "URGENT stop seeds state"              'URGENT'            "$(run stop 870000 s1)"
chk "posttool injects on top of stop state" 'mid-turn] URGENT' "$(run posttool 885000 s1)"
chk_state "posttool preserves stop fields exactly" s1 "870000 3 885000"
# kill switches + scaling + legacy
chk "CC_CONTEXT_WATCH=0 silences all"      EMPTY "$(CC_CONTEXT_WATCH=0 run stop 990000 d)"
chk "POSTTOOL=0 silences posttool only"    EMPTY "$(CC_CONTEXT_WATCH_POSTTOOL=0 run posttool 990000 d2)"
chk "POSTTOOL=0 leaves stop alive"         'CRITICAL' "$(CC_CONTEXT_WATCH_POSTTOOL=0 run stop 990000 d3)"
chk "200K window scales tiers (70%)"       '] NOTICE' "$(CC_CONTEXT_WINDOW=200000 run stop 140000 e)"
chk "legacy CC_COMPACT_NAG_TOKENS honored" '] NOTICE' "$(CC_COMPACT_NAG_TOKENS=600000 run stop 610000 f)"
chk "legacy RENAG throttles (+25K<30K)"    EMPTY      "$(CC_COMPACT_NAG_TOKENS=600000 CC_COMPACT_RENAG_TOKENS=30000 run stop 635000 f)"
chk "legacy RENAG re-fires (+35K)"         '] NOTICE'  "$(CC_COMPACT_NAG_TOKENS=600000 CC_COMPACT_RENAG_TOKENS=30000 run stop 645000 f)"
mkdir -p "$CC_CYCLE_RUNDIR"; echo "650000" > "$CC_CYCLE_RUNDIR/nag-g"
chk "old single-int state upgrades quiet"  EMPTY      "$(run stop 700000 g)"
chk "old state still re-fires on growth"   '] NOTICE'  "$(run stop 730000 g)"
# post-compact epoch reset: context SHRANK below the recorded high-water mark
#: without the reset, NOTICE..URGENT stay suppressed for the whole session.
echo "900000 3 900000" > "$CC_CYCLE_RUNDIR/nag-r1"
chk "context drop resets nag epoch"        '] NOTICE'  "$(run stop 700000 r1)"

# --- readout-mode helpers ---------------------------------------------------
# chk() asserts the output IS valid JSON (every nag payload is). A readout is the
# opposite: plain text that must NEVER be a block payload.
chk_plain() { # $1=label $2=expected-substr $3=actual-output
  case "$3" in
    *"$2"*)
      case "$3" in
        *'"decision"'*|*'"block"'*)
          printf '  FAIL  %s (readout emitted a BLOCK payload)\n' "$1"; fails=$((fails + 1)) ;;
        *) printf '  PASS  %s\n' "$1" ;;
      esac ;;
    *) printf '  FAIL  %s (wanted "%s", got: %.120s)\n' "$1" "$2" "${3:-<silence>}"; fails=$((fails + 1)) ;;
  esac
}

chk_no_nag_state() { # $1=label $2=sid: readout must never touch ladder state
  if [ -e "$CC_CYCLE_RUNDIR/nag-$2" ]; then
    printf '  FAIL  %s (readout wrote nag-%s, corrupting the Stop ladder throttle)\n' "$1" "$2"
    fails=$((fails + 1))
  else printf '  PASS  %s\n' "$1"; fi
}

chk_no_block() { # $1=label $2=actual-output: a readout is never a block payload
  case "$2" in
    *'"decision"'*|*'"block"'*) printf '  FAIL  %s (readout emitted a block payload)\n' "$1"; fails=$((fails + 1)) ;;
    *) printf '  PASS  %s\n' "$1" ;;
  esac
}

# --- readout mode ----------------------------------------------------------
# The readout branch lives before the ladder logic and must never block or write
# nag state. Below the window ladder it is boundary-aware, so these assert the
# three rest-stop texts (informational / natural break / long-session backstop).
chk_plain "readout fires below the ladder"   'Ample headroom'  "$(run readout 200000 ro1)"
chk       "readout growth-throttled (<100K)" EMPTY             "$(run readout 250000 ro1)"
chk_plain "readout re-fires after +100K"     '[context]'       "$(run readout 360000 ro1)"
chk_no_nag_state "readout never writes nag state" ro1

# Above the window ladder, no boundary: the long-session backstop, never a block.
chk_plain "readout at 70% -> long session, no block"  'has run long'  "$(run readout 700000 ro2)"
chk_no_nag_state "readout at 70% leaves ladder state alone" ro2
chk_plain "readout at 95% -> long session, no block"  'has run long'  "$(run readout 950000 ro3)"
chk_no_nag_state "readout at 95% leaves ladder state alone" ro3
# Above the ladder it must not claim headroom that is gone.
case "$(run readout 960000 ro4)" in
  *'Ample headroom'*) printf '  FAIL  readout above ladder must not claim headroom\n'; fails=$((fails + 1)) ;;
  *) printf '  PASS  readout above ladder does not claim headroom\n' ;;
esac

# Boundary detection: each of the five signals (plus the gh-pr-merge form of
# signal b) must, with a heavy-enough turn (>=250K), read out as a break point.
chk_plain "boundary a: task completed -> break point"   'Natural break point' "$(run_b 300000 bt task)"
chk_plain "boundary b: git push landed -> break point"  'Natural break point' "$(run_b 300000 bp push)"
chk_plain "boundary b: gh pr merge landed -> break point" 'Natural break point' "$(run_b 300000 bm merge)"
chk_plain "boundary c: workflow returned -> break point" 'Natural break point' "$(run_b 300000 bw workflow)"
chk_plain "boundary d: >2h idle gap -> break point"     'Natural break point' "$(run_b 300000 bg gap)"
chk_plain "boundary e: branch switched -> break point"  'Natural break point' "$(run_b 300000 bb branch)"

# Per-turn token tiers with NO boundary present.
chk_plain "180K no boundary -> informational"           'Ample headroom'     "$(run_b 180000 tk1 none)"
chk_plain "300K no boundary -> informational"           'Ample headroom'     "$(run_b 300000 tk2 none)"
chk_plain "450K no boundary -> long session backstop"   'has run long'       "$(run_b 450000 tk3 none)"

# A boundary readout, even above the ladder, is annotation and NEVER a block.
chk_no_block "readout at a boundary emits no block payload" "$(run_b 900000 nb task)"

# --- one compact route: synthesis, then the Operator's /compact ---------------
# OPS has no self-compaction (the tmux typer is retired), so no nag may tell the
# session to run a compactor or to self-compact, inside tmux or out.
for m in stop posttool; do
  out="$(printf '{"session_id":"rt-%s","transcript_path":"%s","stop_hook_active":false}' "$m" \
    "$(mk_transcript "$WORK/rt-$m.jsonl" 930000; printf '%s' "$WORK/rt-$m.jsonl")" \
    | TMUX=/tmp/fake-tmux-socket,1,0 bash "$DIR/context-watch.sh" "$m")"
  case "$out" in
    *compact-cycle*|*SELF-COMPACT*|*compactor*) printf '  FAIL  %s nag names a self-compact route: %.120s\n' "$m" "$out"; fails=$((fails + 1)) ;;
    *"manual /compact is clear to fire"*) printf '  PASS  %s nag routes to the Operator'"'"'s /compact, even with TMUX set\n' "$m" ;;
    *) printf '  FAIL  %s nag lacks the /compact route: %.120s\n' "$m" "$out"; fails=$((fails + 1)) ;;
  esac
done

# --- sub-agent (lane) backstop ----------------------------------------------
# A hook call carrying agent_id runs INSIDE a lane. The hook input's
# transcript_path is the MAIN transcript even there, so the lane's own context
# is read from a DERIVED path, <main w/o .jsonl>/subagents/agent-<agent_id>.jsonl.
# These fixtures reproduce that layout: a real main transcript the hook
# validates, plus a lane transcript under subagents/ whose last usage entry
# carries the lane's context AND its model, the key the hook sizes the lane's
# window from. A lane gets a reminder at 60% of its real window and a wrap-up at
# 80%, both PostToolUse additionalContext, never a block.
mk_lane_usage() { # $1=path $2=tokens $3=model ("-" = no model field at all)
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
msg = {"usage": {"input_tokens": int(sys.argv[2]),
                 "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}
if sys.argv[3] != "-":
    msg["model"] = sys.argv[3]
open(sys.argv[1], "w").write("junk not json\n" + json.dumps({"type": "assistant", "message": msg}) + "\n")
PYEOF
}

mk_lane() { # $1=main_tp $2=agent_id $3=lane_tokens $4=model
  local base="${1%.jsonl}"
  mkdir -p "$base/subagents"
  mk_transcript "$1" 999999            # main must exist; irrelevant to lane mode
  mk_lane_usage "$base/subagents/agent-$2.jsonl" "$3" "$4"
}

run_lane() { # $1=mode $2=lane_tokens $3=sid $4=agent_id $5=model [NAME=VAL ...]
  local mode="$1" ltok="$2" sid="$3" aid="$4" model="$5"; shift 5
  local main_tp="$WORK/lp-$sid/$sid.jsonl"
  mkdir -p "$WORK/lp-$sid"
  mk_lane "$main_tp" "$aid" "$ltok" "$model"
  printf '{"session_id":"%s","transcript_path":"%s","agent_id":"%s","agent_type":"general-purpose"}' \
    "$sid" "$main_tp" "$aid" | env -u TMUX -u LANE_WINDOW_OVERRIDE -u LANE_REMIND_PCT -u LANE_WRAP_PCT \
    "$@" bash "$DIR/context-watch.sh" "$mode"
}
M1=claude-sonnet-5-5   # the default lane model, a 1M window

# (1) A 1M lane is silent everywhere below the reminder.
chk "1M lane silent at 250K"                  EMPTY  "$(run_lane posttool 250000 l1 aid-1a $M1)"
chk "1M lane silent at 500K"                  EMPTY  "$(run_lane posttool 500000 l1 aid-1b $M1)"
chk "1M lane silent at 599K (just under 60%)" EMPTY  "$(run_lane posttool 599000 l1 aid-1c $M1)"
# (2) Reminder at 60%, throttled by +10% of window.
chk "1M lane reminder at 600K"                'lane] Reminder'    "$(run_lane posttool 600000 l2 aid-2 $M1)"
chk "reminder rides additionalContext"        'additionalContext' "$(run_lane posttool 600000 l2b aid-2b $M1)"
chk "reminder throttled at +50K (<100K)"      EMPTY               "$(run_lane posttool 650000 l2 aid-2 $M1)"
chk "reminder re-fires at +100K"              'lane] Reminder'    "$(run_lane posttool 700000 l2 aid-2 $M1)"
case "$(run_lane posttool 600000 l2c aid-2c $M1)" in
  *'Wrap up:'*|*'and return'*) printf '  FAIL  reminder must not tell the lane to return\n'; fails=$((fails + 1)) ;;
  *'Keep going'*) printf '  PASS  reminder tells the lane to keep going\n' ;;
  *) printf '  FAIL  reminder text missing "Keep going"\n'; fails=$((fails + 1)) ;;
esac
# (3) Wrap at 80%. Crossing beats the throttle: lane l2 last fired at 700K, and
# 800K is under 700K + 100K, so only the stage crossing can fire it.
chk "wrap fires at 800K (crossing beats throttle)" 'lane] Wrap up'  "$(run_lane posttool 800000 l2 aid-2 $M1)"
chk "wrap throttled at +10K (<25K)"           EMPTY                "$(run_lane posttool 810000 l2 aid-2 $M1)"
chk "wrap re-fires at +30K"                   'lane] Wrap up'      "$(run_lane posttool 830000 l2 aid-2 $M1)"
chk "fresh lane jumps straight to wrap"       'lane] Wrap up'      "$(run_lane posttool 900000 l3 aid-3 $M1)"
chk_no_block "wrap is never a block payload" "$(run_lane posttool 900000 l3b aid-3b $M1)"
case "$(run_lane posttool 900000 l3c aid-3c $M1)" in
  *'does not compact'*) printf '  PASS  wrap says a lane does not compact\n' ;;
  *) printf '  FAIL  wrap text missing "does not compact"\n'; fails=$((fails + 1)) ;;
esac
# (4) Stop and readout stay silent in a lane even past wrap: only PostToolUse
# fires in-lane, and a Stop block would force the lane to continue.
chk "lane stop mode stays silent"             EMPTY  "$(run_lane stop 900000 l4 aid-4 $M1)"
chk "lane readout mode stays silent"          EMPTY  "$(run_lane readout 900000 l4b aid-4b $M1)"
# (5) Throttle keys on agent_id, not the shared session_id.
chk "lane A fires (session sameS)"            'lane] Reminder'  "$(run_lane posttool 600000 sameS aidA $M1)"
chk "lane B same session still fires"         'lane] Reminder'  "$(run_lane posttool 600000 sameS aidB $M1)"
# (6) The model-to-window map: every 1M row is silent at 599K and wraps at 800K;
# the 200K rows remind at 120K and wrap at 160K.
for m in claude-fable-5-1 claude-sonnet-5-5 claude-opus-5-5 claude-opus-4-8; do
  chk "map: $m silent at 599K"   EMPTY           "$(run_lane posttool 599000 m-$m a-$m-s "$m")"
  chk "map: $m wraps at 800K"    'lane] Wrap up' "$(run_lane posttool 800000 m-$m a-$m-w "$m")"
done
for m in claude-opus-4-6 claude-sonnet-4-6 claude-haiku-4-5; do
  chk "map: $m (200K) silent at 119K"  EMPTY            "$(run_lane posttool 119000 m-$m a-$m-s "$m")"
  chk "map: $m (200K) reminds at 120K" 'lane] Reminder' "$(run_lane posttool 120000 m-$m a-$m-r "$m")"
  chk "map: $m (200K) wraps at 160K"   'lane] Wrap up'  "$(run_lane posttool 160000 m-$m a-$m-w "$m")"
done
chk "200K lane reports ~80% at 160K" '(~80%)' "$(run_lane posttool 160000 pct a-pct claude-haiku-4-5)"
# Haiku 5.5: a 100K price ceiling held by its own auto-compaction, so no reminder
# and no wrap, one backstop at 95K. The main transcript beside it carries 999,999
# tokens, so the stages prove the lane is sized from its own transcript.
m=claude-haiku-5-5
chk "map: $m silent at 60K (no reminder stage)"    EMPTY            "$(run_lane posttool 60000 m-$m a-$m-r "$m")"
chk "map: $m silent at 80K (no wrap stage)"        EMPTY            "$(run_lane posttool 80000 m-$m a-$m-w "$m")"
chk "map: $m silent at 94K (just under 95%)"       EMPTY            "$(run_lane posttool 94000 m-$m a-$m-94 "$m")"
chk "map: $m backstop at 95K"                      'lane] Backstop' "$(run_lane posttool 95000 m-$m a-$m-b "$m")"
chk "map: $m backstop names the ruled ceiling"     'ceiling set for its model' "$(run_lane posttool 95000 m-$m a-$m-c "$m")"
chk "map: $m backstop throttled at +5K"            EMPTY            "$(run_lane posttool 100000 m-$m a-$m-b "$m")"
chk "map: $m backstop re-fires at +10K"            'lane] Backstop' "$(run_lane posttool 105000 m-$m a-$m-b "$m")"
chk "ceiling refill: first 95K backstop"           'lane] Backstop' "$(run_lane posttool 95000 refill a-refill "$m")"
chk "ceiling refill: compacted lane quiet at 20K"  EMPTY            "$(run_lane posttool 20000 refill a-refill "$m")"
chk "ceiling refill: next 95K backstop fires"      'lane] Backstop' "$(run_lane posttool 95000 refill a-refill "$m")"
chk "LANE_REMIND/WRAP_PCT do not reach a ceiling lane (silent at 60K)" EMPTY \
  "$(run_lane posttool 60000 k10 a-k10 claude-haiku-5-5 LANE_REMIND_PCT=30 LANE_WRAP_PCT=50)"
chk "override cannot lift the Haiku 5.5 ceiling (backstop at 95K)" 'lane] Backstop' \
  "$(run_lane posttool 95000 k7 a-k7 claude-haiku-5-5 LANE_WINDOW_OVERRIDE=200000)"
chk "override can lower the Haiku 5.5 ceiling (backstop at 48K)" 'lane] Backstop' \
  "$(run_lane posttool 48000 k8 a-k8 claude-haiku-5-5 LANE_WINDOW_OVERRIDE=50000)"
chk "claude-haiku-5-5[1m] keeps the 100K ceiling (backstop at 95K)" 'lane] Backstop' \
  "$(run_lane posttool 95000 k9 a-k9 'claude-haiku-5-5[1m]')"
chk "dated claude-haiku-5-5-20261007 backstop at 95K" 'lane] Backstop' "$(run_lane posttool 95000 u6 a-u6 claude-haiku-5-5-20261007)"
# (7) Unknown ids: family prefix first, else the 1M default.
chk "unknown opus-family id wraps at 800K, not before" EMPTY "$(run_lane posttool 599000 u1 a-u1 claude-opus-7-2)"
chk "unknown haiku-family id is 200K (wraps 160K)" 'lane] Wrap up' "$(run_lane posttool 160000 u2 a-u2 claude-haiku-9)"
chk "unknown id outside any family wraps at 800K" 'lane] Wrap up' "$(run_lane posttool 800000 u3 a-u3 claude-zephyr-9-1)"
chk "[1m] suffix on a 200K-default id is 1M"      EMPTY           "$(run_lane posttool 599000 u4 a-u4 'claude-opus-4-6[1m]')"
chk "no model field: reminds at 600K (1M default)" 'lane] Reminder' "$(run_lane posttool 600000 u5 a-u5 -)"
# (8) Knobs.
chk "LANE_WINDOW_OVERRIDE=200000 wraps a 1M model at 160K" 'lane] Wrap up' \
  "$(run_lane posttool 160000 k1 a-k1 $M1 LANE_WINDOW_OVERRIDE=200000)"
chk "LANE_REMIND_PCT=30 reminds at 300K"      'lane] Reminder' "$(run_lane posttool 300000 k2 a-k2 $M1 LANE_REMIND_PCT=30)"
chk "30/50 pair wraps at 500K"                'lane] Wrap up'  "$(run_lane posttool 500000 k3 a-k3 $M1 LANE_REMIND_PCT=30 LANE_WRAP_PCT=50)"
chk "inverted pair (90/80) falls back to 60/80" 'lane] Reminder' "$(run_lane posttool 600000 k5 a-k5 $M1 LANE_REMIND_PCT=90 LANE_WRAP_PCT=80)"
chk "garbage LANE_WINDOW_OVERRIDE uses the map" 'lane] Wrap up'  "$(run_lane posttool 800000 k6 a-k6 $M1 LANE_WINDOW_OVERRIDE=lots)"
# (9) A missing lane transcript fails open (silent), never a crash or a false nag.
chk "lane with no derivable transcript is silent" EMPTY \
  "$(mk_transcript "$WORK/nx.jsonl" 900000; printf '{"session_id":"nx","transcript_path":"%s","agent_id":"ghost"}' "$WORK/nx.jsonl" | env -u TMUX bash "$DIR/context-watch.sh" posttool)"
# (10) A lane nested under subagents/workflows/ is found by the recursive glob.
mkdir -p "$WORK/lp-nest/nest/subagents/workflows/w1"
mk_transcript "$WORK/lp-nest/nest.jsonl" 999999
mk_lane_usage "$WORK/lp-nest/nest/subagents/workflows/w1/agent-deep.jsonl" 800000 "$M1"
chk "workflow lane under subagents/workflows/ wraps at 800K" 'lane] Wrap up' \
  "$(printf '{"session_id":"nest","transcript_path":"%s","agent_id":"deep"}' "$WORK/lp-nest/nest.jsonl" | env -u TMUX bash "$DIR/context-watch.sh" posttool)"
# (11) The main-session ladder is untouched: a main posttool (NO agent_id) at
# the lane's reminder and wrap weights stays silent.
chk "main posttool at 600K (no agent_id) silent" EMPTY "$(run posttool 600000 mainy)"
chk "main posttool at 800K (no agent_id) silent" EMPTY "$(run posttool 800000 mainz)"

# --- T3 delegated lanes (lane-class) ------------------------------------------------
# A T3 delegated lane is its own top-level claude process, so its hooks carry NO agent_id
# and it used to be nagged like a foreman, declined, and paid a full-context turn for the
# nag. Stop and the readout's compaction texts are now silent for a session lane-class
# calls a lane; PostToolUse gives it its wrap-up text. Silence needs positive evidence:
# a missing, garbled, slow or foreman answer keeps a foreman's nag. Every case uses its
# own session id (the lane-class answer is cached per session, and the throttle per session).
yes_no() { # $1=label $2=condition-exit-status
  if [ "$2" -eq 0 ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}
count_is() { # $1=label $2=want $3=got
  if [ "$3" = "$2" ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}
lane_asks() { if [ -s "$LANE_STUB_LOG" ]; then wc -l < "$LANE_STUB_LOG" | tr -d ' '; else echo 0; fi; }
run_t3() { # $1=mode $2=tokens $3=sid $4=signal [NAME=VALUE ...]: a T3 session (T3CODE_HOME set)
  local mode="$1" tokens="$2" sid="$3" signal="$4"; shift 4
  local tp="$WORK/e-$signal-$sid.jsonl"
  mk_boundary "$tp" "$tokens" "$signal"
  printf '{"session_id":"%s","transcript_path":"%s"}' "$sid" "$tp" \
    | env -u TMUX -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_DIR T3CODE_HOME=/tmp/t3x "$@" \
        bash "$DIR/context-watch.sh" "$mode"
}

# Large tool responses must not become environment variables: Linux refuses a
# single string past 128 KiB before Python even starts, hiding every warning.
tp="$WORK/large-response.jsonl"; mk_boundary "$tp" 880000 none
out="$(python3 - "$tp" <<'PYEOF' | env -u TMUX -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID \
    T3CODE_HOME=/tmp/t3x bash "$DIR/context-watch.sh" posttool
import json, sys
print(json.dumps({"session_id": "large-response", "transcript_path": sys.argv[1],
                  "tool_response": "x" * 300000}))
PYEOF
)"
chk "posttool: a large response still produces the foreman's warning" 'mid-turn] URGENT' "$out"
grep -q '"session_id":"large-response"' "$LANE_STUB_STDIN" && ! grep -q tool_response "$LANE_STUB_STDIN"
yes_no "lane-class receives only its three input fields, not the tool response" $?

# (1) STOP, lane-class says lane: silent at every tier, and it must not use up the throttle.
chk "stop: a t3-lane is not nagged at NOTICE" EMPTY "$(run_t3 stop 700000 ls1 none LANE_STUB_CLASS=t3-lane)"
chk "stop: a t3-lane is not nagged at CRITICAL" EMPTY "$(run_t3 stop 950000 ls1 none LANE_STUB_CLASS=t3-lane)"
chk_no_nag_state "stop: a silent lane writes no nag state" ls1
chk "stop: an agent-lane answer is not nagged either" EMPTY "$(run_t3 stop 700000 ls2 none LANE_STUB_CLASS=agent-lane)"
grep -q '"session_id":"ls1"' "$LANE_STUB_STDIN" && grep -q '"transcript_path"' "$LANE_STUB_STDIN"
yes_no "stop: lane-class receives the hook JSON on stdin" $?
grep -q ' stop sid=ls1 ctx=700K lane-class' "$CC_CYCLE_RUNDIR/context-watch-silenced.log" 2>/dev/null
yes_no "stop: a silenced nag is logged with its reason" $?

# (2) STOP, anything but a clean lane answer keeps the foreman's warnings.
chk "stop: a foreman answer keeps its NOTICE" '] NOTICE' "$(run_t3 stop 700000 ls3 none)"
chk "stop: a foreman answer keeps its CRITICAL" 'CRITICAL' "$(run_t3 stop 950000 ls3 none)"
chk "stop: no lane-class installed keeps the NOTICE" '] NOTICE' "$(run_t3 stop 700000 ls4 none LANE_CLASS=$WORK/no-such-lane-class)"
chk "stop: a garbled lane-class answer reads as foreman" '] NOTICE' "$(run_t3 stop 700000 ls9 none LANE_STUB_CLASS=banana)"
! grep -q ' stop sid=ls3 ' "$CC_CYCLE_RUNDIR/context-watch-silenced.log" 2>/dev/null
yes_no "stop: a foreman is never logged as silenced" $?
: > "$LANE_STUB_LOG"
t0="$(date +%s)"
chk "stop: a hung lane-class reads as foreman" '] NOTICE' "$(run_t3 stop 700000 ls10 none LANE_STUB_SLEEP=30 LANE_STUB_CLASS=t3-lane)"
t1="$(date +%s)"
# The stub forks a `sleep 30`: only a kill of the whole process group frees the hook at the
# cap (killing the stub alone leaves the sleep holding the output pipe for 30 s).
[ $((t1 - t0)) -le 8 ]; yes_no "stop: a hung lane-class (and its hung child) is cut off at 2 s ($((t1 - t0))s)" $?
chk "stop: a failed ask is cached (the next call does not wait again)" 'WARNING' \
  "$(run_t3 stop 790000 ls10 none LANE_STUB_SLEEP=30 LANE_STUB_CLASS=t3-lane)"
count_is "stop: a hung lane-class is asked once, not on every stop" 1 "$(lane_asks)"

# (3) STOP, outside T3 nothing is asked and the nag is as before.
: > "$LANE_STUB_LOG"
chk "stop: outside T3 the manual route still nags" 'manual /compact is clear' "$(run stop 700000 ls11)"
count_is "stop: outside T3 lane-class is never asked" 0 "$(lane_asks)"
chk "stop: below the ladder nothing is asked of lane-class" EMPTY "$(run_t3 stop 500000 ls12 none LANE_STUB_CLASS=t3-lane)"
count_is "stop: below the ladder lane-class is not asked" 0 "$(lane_asks)"
# asked once per session that would be nagged, then cached
: > "$LANE_STUB_LOG"
chk "stop: a foreman session is nagged at 66%" '] NOTICE' "$(run_t3 stop 660000 ls6 none)"
chk "stop: and again at CRITICAL" 'CRITICAL' "$(run_t3 stop 950000 ls6 none)"
count_is "stop: the lane-class answer is cached per session (one ask for two nags)" 1 "$(lane_asks)"
# the thread id alone is no lane evidence: T3CODE_THREAD_ID set, lane-class says foreman
chk "stop: T3CODE_THREAD_ID alone does not silence a foreman" '] NOTICE' "$(run_t3 stop 700000 ls13 none T3CODE_THREAD_ID=thread:delegated-task:x)"

# (4) POSTTOOL: a lane-class lane gets the lane text, not the foreman's compaction text.
chk "posttool: a t3-lane reminds at 600K" 'lane] Reminder' "$(run_t3 posttool 600000 lp1 none LANE_STUB_CLASS=t3-lane)"
chk "posttool: the t3-lane reminder rides additionalContext" 'additionalContext' "$(run_t3 posttool 600000 lp1b none LANE_STUB_CLASS=t3-lane)"
chk "posttool: a t3-lane reminder is throttled (+10K<100K)" EMPTY "$(run_t3 posttool 610000 lp1 none LANE_STUB_CLASS=t3-lane)"
chk "posttool: a t3-lane wraps up at 800K (crossing beats the throttle)" 'lane] Wrap up' "$(run_t3 posttool 800000 lp1 none LANE_STUB_CLASS=t3-lane)"
chk "posttool: a t3-lane at URGENT weight gets the wrap-up, not the foreman text" 'lane] Wrap up' "$(run_t3 posttool 880000 lp2 none LANE_STUB_CLASS=t3-lane)"
case "$(run_t3 posttool 880000 lp3 none LANE_STUB_CLASS=t3-lane)" in
  *'compact ritual'*|*'mid-turn'*|*'manual /compact'*) printf '  FAIL  posttool: a t3-lane must never be handed a compaction route\n'; fails=$((fails + 1)) ;;
  *) printf '  PASS  posttool: a t3-lane is never handed a compaction route\n' ;;
esac
[ -f "$CC_CYCLE_RUNDIR/lane-t3-lp1" ] && [ ! -e "$CC_CYCLE_RUNDIR/nag-lp1" ]
yes_no "posttool: a t3-lane keeps its own throttle file and writes no nag state" $?
chk "posttool: a t3-lane below its reminder is silent" EMPTY "$(run_t3 posttool 500000 lp4 none LANE_STUB_CLASS=t3-lane)"
chk_no_block "posttool: the t3-lane text is never a block payload" "$(run_t3 posttool 880000 lp5 none LANE_STUB_CLASS=t3-lane)"
: > "$LANE_STUB_LOG"
for i in 1 2 3; do run_t3 posttool 500000 lp6 none LANE_STUB_CLASS=foreman >/dev/null; done
count_is "posttool: lane-class is asked once for three tool calls (cached per session)" 1 "$(lane_asks)"
# A cached answer ages out after 30 minutes: a stale "foreman" is asked again.
printf 'foreman %d' "$(( $(date +%s) - 4000 ))" > "$CC_CYCLE_RUNDIR/laneclass-lp7"
: > "$LANE_STUB_LOG"
chk "posttool: a cache older than 30 minutes is asked again" 'lane] Wrap up' "$(run_t3 posttool 880000 lp7 none LANE_STUB_CLASS=t3-lane)"
count_is "posttool: the stale cache entry was refreshed (one ask)" 1 "$(lane_asks)"
# A foreman is untouched: the same weight with a foreman answer still gets the mid-turn text.
chk "posttool: a foreman at 87% still gets URGENT" 'mid-turn] URGENT' "$(run_t3 posttool 870000 lp9 none)"
# Outside T3 the lane check never runs and posttool is as before.
: > "$LANE_STUB_LOG"
chk "posttool: outside T3 the foreman text is unchanged" 'mid-turn] URGENT' "$(run posttool 870000 lp12)"
count_is "posttool: outside T3 lane-class is never asked" 0 "$(lane_asks)"

# (5) READOUT: the compaction routes are for foremen. A lane gets none; the plain headroom line stays.
chk "readout: a t3-lane at 450K is silent" EMPTY "$(run_t3 readout 450000 lr2 none LANE_STUB_CLASS=t3-lane)"
chk "readout: a t3-lane at a natural break is silent" EMPTY "$(run_t3 readout 300000 lr4 task LANE_STUB_CLASS=t3-lane)"
chk_plain "readout: a t3-lane still gets the plain headroom line at 200K" 'Ample headroom' "$(run_t3 readout 200000 lr5 none LANE_STUB_CLASS=t3-lane)"
chk_plain "readout: a foreman at 450K still gets the long-session text" 'has run long' "$(run_t3 readout 450000 lr6 none)"
grep -q ' readout sid=lr2 ctx=450K lane' "$CC_CYCLE_RUNDIR/context-watch-silenced.log" 2>/dev/null
yes_no "readout: a silenced readout is logged" $?

# (6) The harness root: the classifier is found through OPS_DIR, else the hook's own checkout.
ROOT="$(cd -P "$DIR/../.." && pwd)"
mkdir -p "$WORK/fake-root/.claude-config/bin"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho t3-lane\n' > "$WORK/fake-root/.claude-config/bin/lane-class"; chmod +x "$WORK/fake-root/.claude-config/bin/lane-class"
tp="$WORK/e-root.jsonl"; mk_boundary "$tp" 700000 none
out="$(printf '{"session_id":"rt1","transcript_path":"%s"}' "$tp" | env -u TMUX -u LANE_CLASS -u T3CODE_THREAD_ID T3CODE_HOME=/tmp/t3x OPS_DIR="$WORK/fake-root" bash "$DIR/context-watch.sh" stop)"
chk "root: OPS_DIR names the checkout whose lane-class is asked" EMPTY "$out"
out="$(printf '{"session_id":"rt2","transcript_path":"%s"}' "$tp" | env -u TMUX -u LANE_CLASS -u T3CODE_THREAD_ID T3CODE_HOME=/tmp/t3x OPS_DIR="$WORK/not-a-checkout" bash "$DIR/context-watch.sh" stop)"
if [ -x "$ROOT/.claude-config/bin/lane-class" ]; then
  chk "root: an OPS_DIR with no .claude-config falls back to the hook's own checkout (a real foreman)" '] NOTICE' "$out"
else
  printf '  SKIP  root fallback (no lane-class beside this hook)\n'
fi
ln -s "$DIR" "$WORK/linked-hooks"
out="$(printf '{"session_id":"rt3","transcript_path":"%s"}' "$tp" | env -u TMUX -u LANE_CLASS -u OPS_DIR -u T3CODE_THREAD_ID T3CODE_HOME=/tmp/t3x bash "$WORK/linked-hooks/context-watch.sh" stop)"
if [ -x "$ROOT/.claude-config/bin/lane-class" ]; then
  chk "root: a symlinked hooks dir resolves to the real checkout (a real foreman is nagged)" '] NOTICE' "$out"
fi

if [ "$fails" -eq 0 ]; then
  echo "context-watch-selftest: LADDER BEHAVES"
  exit 0
else
  echo "context-watch-selftest: $fails case(s) failing: ladder defect, do not trust the nag"
  exit 1
fi
