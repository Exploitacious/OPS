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
chk "tier escalation overrides throttle"   'WARNING'  "$(run stop 785000 a)"
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
chk "stop state untouched by posttool"     'CRITICAL' "$(run stop 930000 c)"
# kill switches + scaling + legacy
chk "CC_CONTEXT_WATCH=0 silences all"      EMPTY "$(CC_CONTEXT_WATCH=0 run stop 990000 d)"
chk "POSTTOOL=0 silences posttool only"    EMPTY "$(CC_CONTEXT_WATCH_POSTTOOL=0 run posttool 990000 d2)"
chk "POSTTOOL=0 leaves stop alive"         'CRITICAL' "$(CC_CONTEXT_WATCH_POSTTOOL=0 run stop 990000 d3)"
chk "200K window scales tiers (70%)"       '] NOTICE' "$(CC_CONTEXT_WINDOW=200000 run stop 140000 e)"
chk "legacy CC_COMPACT_NAG_TOKENS honored" '] NOTICE' "$(CC_COMPACT_NAG_TOKENS=600000 run stop 610000 f)"
mkdir -p "$CC_CYCLE_RUNDIR"; echo "650000" > "$CC_CYCLE_RUNDIR/nag-g"
chk "old single-int state upgrades quiet"  EMPTY      "$(run stop 700000 g)"
chk "old state still re-fires on growth"   '] NOTICE'  "$(run stop 730000 g)"

if [ "$fails" -eq 0 ]; then
  echo "context-watch-selftest: LADDER BEHAVES"
  exit 0
else
  echo "context-watch-selftest: $fails case(s) failing — ladder defect, do not trust the nag"
  exit 1
fi
