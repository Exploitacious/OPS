#!/usr/bin/env bash
# context-watch-selftest.sh — prove the escalation ladder fires, throttles,
# escalates, and stays silent exactly where designed. Run after deploying the
# hooks and any time by hand. Companion to guard-selftest.sh, with one
# deliberate difference: context-watch is fail-OPEN (a dead nag costs a manual
# compact, not a security hole), so a missing python3 SKIPS with exit 0 here
# instead of failing — the hook itself is documented to go silent there.
#
# Exit 0 = every case behaves (or python3 absent => skip); 1 = ladder defect.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "context-watch-selftest: SKIP (no python3 — hook is documented fail-open without it)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CC_CYCLE_RUNDIR="$WORK/rundir"
fails=0

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
    "$3" "$tp" "${4:-false}" | env -u TMUX bash "$DIR/context-watch.sh" "$1"
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
    | env -u TMUX bash "$DIR/context-watch.sh" readout
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
# (WARNING +40K), so only the tier-crossing clause can fire this — removing
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
# byte-for-byte — asserted on the literal state file, not message output.
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
# — without the reset, NOTICE..URGENT stay suppressed for the whole session.
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

chk_no_nag_state() { # $1=label $2=sid — readout must never touch ladder state
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

if [ "$fails" -eq 0 ]; then
  echo "context-watch-selftest: LADDER BEHAVES"
  exit 0
else
  echo "context-watch-selftest: $fails case(s) failing — ladder defect, do not trust the nag"
  exit 1
fi
