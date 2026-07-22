#!/usr/bin/env bash
# claude-window-ping-selftest.sh — prove the window-ping pipe handles every
# path it can hit unattended: good profiles, config typos, missing binary,
# nonzero/timeout rcs, empty config, overlap locking, and tmp hygiene. Runs
# entirely against a MOCK claude binary and a scratch state dir (the
# CC_WINDOW_PING_BIN / CC_WINDOW_PING_STATE_DIR test hooks) — no real API
# usage, no touch of the real ~/.local/state/window-ping.
#
# Exit 0 = every case behaves; 1 = defect.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/claude-window-ping.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0

# Mock claude: records CLAUDE_CONFIG_DIR + argv, honors MOCK_RC / MOCK_SLEEP.
MOCK="$WORK/mock-claude"
cat > "$MOCK" <<'MOCKEOF'
#!/usr/bin/env bash
[ -n "${MOCK_SLEEP:-}" ] && sleep "$MOCK_SLEEP"
echo "${CLAUDE_CONFIG_DIR:-<none>}|$*" >> "${MOCK_RECORD:?}"
echo "Pong."
exit "${MOCK_RC:-0}"
MOCKEOF
chmod +x "$MOCK"

STATE="$WORK/state"
export CC_WINDOW_PING_BIN="$MOCK" CC_WINDOW_PING_STATE_DIR="$STATE"
export MOCK_RECORD="$WORK/record.txt"

reset() { rm -rf "$STATE" "$MOCK_RECORD"; unset MOCK_RC MOCK_SLEEP CC_WINDOW_PING_PROFILES CC_WINDOW_PING_MODEL CC_WINDOW_PING_TIMEOUT 2>/dev/null || true; }

chk() { # $1=label $2=condition-result (0=pass)
  if [ "$2" -eq 0 ]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

echo "claude-window-ping-selftest:"

# 1. Two good profiles: both pinged with the right config dirs, rc=0 rows, default model.
reset
CC_WINDOW_PING_PROFILES="alpha=$WORK/cfg-a beta=$WORK/cfg-b" bash "$SCRIPT"
chk "two profiles -> two rc=0 status rows" "$([ "$(awk -F'\t' '$2=="0"' "$STATE/last-status.tsv" | wc -l)" = 2 ]; echo $?)"
chk "mock saw both config dirs"            "$(grep -q "^$WORK/cfg-a|" "$MOCK_RECORD" && grep -q "^$WORK/cfg-b|" "$MOCK_RECORD"; echo $?)"
chk "default model sonnet passed"          "$(grep -q -- "--model sonnet" "$MOCK_RECORD"; echo $?)"
chk "no tmp litter after clean run"        "$([ -z "$(ls "$STATE"/last-status.tsv.tmp.* 2>/dev/null)" ]; echo $?)"

# 2. Malformed pair: skipped loud (rc=2 row + log line), good pair still pinged.
reset
CC_WINDOW_PING_PROFILES="nameonly good=$WORK/cfg-g" bash "$SCRIPT"
chk "malformed pair -> rc=2 status row"    "$(awk -F'\t' '$1=="nameonly" && $2=="2"' "$STATE/last-status.tsv" | grep -q .; echo $?)"
chk "malformed pair logged as ERROR"       "$(grep -q "ERROR  malformed profile pair" "$STATE/ping.log"; echo $?)"
chk "good pair still pinged (rc=0)"        "$(awk -F'\t' '$1=="good" && $2=="0"' "$STATE/last-status.tsv" | grep -q .; echo $?)"
chk "mock never saw the malformed value"   "$(! grep -q "^nameonly|" "$MOCK_RECORD"; echo $?)"

# 3. Nonzero rc propagates verbatim.
reset
MOCK_RC=7 CC_WINDOW_PING_PROFILES="p=$WORK/cfg-p" bash "$SCRIPT"
chk "mock rc=7 propagates to status"       "$(awk -F'\t' '$1=="p" && $2=="7"' "$STATE/last-status.tsv" | grep -q .; echo $?)"

# 4. Timeout knob: slow mock + 1s budget -> rc=124.
reset
MOCK_SLEEP=3 CC_WINDOW_PING_TIMEOUT=1 CC_WINDOW_PING_PROFILES="slow=$WORK/cfg-s" bash "$SCRIPT"
chk "timeout -> rc=124 in status"          "$(awk -F'\t' '$1=="slow" && $2=="124"' "$STATE/last-status.tsv" | grep -q .; echo $?)"

# 5. Custom model knob reaches the CLI.
reset
CC_WINDOW_PING_MODEL="custommodel" CC_WINDOW_PING_PROFILES="m=$WORK/cfg-m" bash "$SCRIPT"
chk "CC_WINDOW_PING_MODEL passed through"  "$(grep -q -- "--model custommodel" "$MOCK_RECORD"; echo $?)"

# 6. Missing binary: one rc=127 row PER configured profile, complete atomic file.
# PATH mimics cron's minimal /usr/bin:/bin — coreutils work, claude is absent.
reset
CC_WINDOW_PING_BIN="$WORK/does-not-exist" PATH="/usr/bin:/bin" CC_WINDOW_PING_PROFILES="a=$WORK/x b=$WORK/y" bash "$SCRIPT"
chk "missing binary -> 2 rc=127 rows"      "$([ "$(awk -F'\t' '$2=="127"' "$STATE/last-status.tsv" | wc -l)" = 2 ]; echo $?)"
chk "missing binary logged as ERROR"       "$(grep -q "ERROR  claude binary not found" "$STATE/ping.log"; echo $?)"
chk "missing-binary path leaves no tmp"    "$([ -z "$(ls "$STATE"/last-status.tsv.tmp.* 2>/dev/null)" ]; echo $?)"

# 7. Whitespace-only profiles: loud config row, never a silently-fresh empty status.
reset
CC_WINDOW_PING_PROFILES="   " bash "$SCRIPT"
chk "empty config -> config rc=2 row"      "$(awk -F'\t' '$1=="config" && $2=="2"' "$STATE/last-status.tsv" | grep -q .; echo $?)"
chk "status file non-empty"                "$([ -s "$STATE/last-status.tsv" ]; echo $?)"

# 8. Overlap lock: a held lock makes the second run exit quietly, status untouched.
reset
mkdir -p "$STATE"
printf 'sentinel\t0\tKEEP\n' > "$STATE/last-status.tsv"
( flock 8; sleep 3 ) 8>"$STATE/.lock" &
LOCKER=$!
sleep 0.3
CC_WINDOW_PING_PROFILES="l=$WORK/cfg-l" bash "$SCRIPT"
chk "locked run leaves status untouched"   "$(grep -q "^sentinel" "$STATE/last-status.tsv"; echo $?)"
chk "locked run pings nothing"             "$([ ! -f "$MOCK_RECORD" ]; echo $?)"
wait "$LOCKER" 2>/dev/null || true

# 9. Stale tmp sweep: >60min-old tmp removed on next run.
reset
mkdir -p "$STATE"
touch "$STATE/last-status.tsv.tmp.99999"
touch -d "2 hours ago" "$STATE/last-status.tsv.tmp.99999"
CC_WINDOW_PING_PROFILES="s=$WORK/cfg-s2" bash "$SCRIPT"
chk "stale tmp swept on next run"          "$([ ! -e "$STATE/last-status.tsv.tmp.99999" ]; echo $?)"

if [ "$fails" -eq 0 ]; then
  echo "claude-window-ping-selftest: PIPE BEHAVES"
  exit 0
else
  echo "claude-window-ping-selftest: $fails case(s) failing — do not trust the cron pipe"
  exit 1
fi
