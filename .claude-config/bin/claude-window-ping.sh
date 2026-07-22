#!/usr/bin/env bash
# claude-window-ping.sh — cron-fired dumb pipe that opens the Claude 5-hour
# usage window on one or more Claude Code profiles by sending one headless
# "ping" to a brand-new session per profile. The window countdown starts at
# times the Operator chooses, with nobody at the keyboard — useful when your
# working day has predictable blocks and you want the shared window clock
# already running when you sit down.
#
# Install (machine-local; cron times are system-local; pick times that fit
# your day — e.g. one ping per 5-hour block you want pre-armed):
#   crontab -e
#   45 5  * * * $HOME/OPS/.claude-config/bin/claude-window-ping.sh
#   0  11 * * * $HOME/OPS/.claude-config/bin/claude-window-ping.sh
#   15 16 * * * $HOME/OPS/.claude-config/bin/claude-window-ping.sh
#
# Profiles: CC_WINDOW_PING_PROFILES, space-separated "name=config_dir" pairs.
# Default is the single default profile. An Operator running a second profile
# (e.g. a personal account via CLAUDE_CONFIG_DIR) lists both:
#   CC_WINDOW_PING_PROFILES="default=$HOME/.claude personal=$HOME/.claude-personal"
# (set it on the crontab line or in a wrapper — cron does not read your shell
# rc). A pair without "=" is a config typo: it is skipped, logged, and lands
# in last-status.tsv with rc=2 so the briefing flags it.
#
# Knobs: CC_WINDOW_PING_MODEL (default "sonnet" — the cheapest real round-trip
# opens the window exactly the same), CC_WINDOW_PING_TIMEOUT (seconds per
# profile, default 180; worst-case wall time is N_profiles x timeout).
# Test hooks (used by claude-window-ping-selftest.sh, harmless otherwise):
# CC_WINDOW_PING_BIN (binary override), CC_WINDOW_PING_STATE_DIR.
#
# MCP is stripped (--strict-mcp-config + empty config) so the ping is a pure
# text round-trip: no servers spun up, minimal tokens, fast exit. Runs from
# $HOME so no project context loads. Cron runs outside tmux, so
# remote-session-register.sh's tmux guard keeps ping sessions out of the
# reboot-resume registry. A non-blocking flock serializes overlapping
# invocations (second run exits quietly).
#
# Surfaces: appends ~/.local/state/window-ping/ping.log; rewrites
# last-status.tsv (profile <TAB> rc <TAB> timestamp) atomically, which
# session-briefing.sh reads to flag a failed or stale ping at the next
# session start. rc conventions: ping rc verbatim (124 = timeout), 127 =
# claude binary not found, 2 = configuration error (malformed pair / no
# usable profiles).
set -uo pipefail

STATE_DIR="${CC_WINDOW_PING_STATE_DIR:-$HOME/.local/state/window-ping}"
LOG="$STATE_DIR/ping.log"
STATUS="$STATE_DIR/last-status.tsv"
mkdir -p "$STATE_DIR"

# Serialize overlapping invocations; second runner exits quietly.
exec 9>"$STATE_DIR/.lock"
flock -n 9 || exit 0

# Sweep tmp litter from runs killed mid-write (OOM, reboot, cron timeout).
find "$STATE_DIR" -maxdepth 1 -name "last-status.tsv.tmp.*" -mmin +60 -delete 2>/dev/null || true

TMP_STATUS="$STATUS.tmp.$$"
trap 'rm -f "$TMP_STATUS"' EXIT
: > "$TMP_STATUS"

PROFILES="${CC_WINDOW_PING_PROFILES:-default=$HOME/.claude}"
MODEL="${CC_WINDOW_PING_MODEL:-sonnet}"
PING_TIMEOUT="${CC_WINDOW_PING_TIMEOUT:-180}"

now() { date '+%F %H:%M'; }
ts()  { date '+%F %T %Z'; }

# cron PATH is minimal — resolve the binary explicitly, PATH as fallback.
CLAUDE_BIN="${CC_WINDOW_PING_BIN:-$HOME/.local/bin/claude}"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
  echo "$(ts)  ERROR  claude binary not found" >> "$LOG"
  for pair in $PROFILES; do
    printf '%s\t127\t%s\n' "${pair%%=*}" "$(now)" >> "$TMP_STATUS"
  done
  [ -s "$TMP_STATUS" ] || printf 'config\t127\t%s\n' "$(now)" >> "$TMP_STATUS"
  mv "$TMP_STATUS" "$STATUS"
  trap - EXIT
  exit 0
fi

pinged=0
for pair in $PROFILES; do
  case "$pair" in
    *=*) ;;
    *)
      echo "$(ts)  ERROR  malformed profile pair (want name=config_dir): $pair" >> "$LOG"
      printf '%s\t2\t%s\n' "$pair" "$(now)" >> "$TMP_STATUS"
      continue
      ;;
  esac
  profile="${pair%%=*}"
  cfg="${pair#*=}"
  out="$(cd "$HOME" && CLAUDE_CONFIG_DIR="$cfg" timeout "$PING_TIMEOUT" "$CLAUDE_BIN" \
          -p "ping" --model "$MODEL" \
          --mcp-config '{"mcpServers":{}}' --strict-mcp-config 2>&1 </dev/null)"
  rc=$?
  one_line="$(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-300)"
  echo "$(ts)  $profile  rc=$rc  $one_line" >> "$LOG"
  printf '%s\t%s\t%s\n' "$profile" "$rc" "$(now)" >> "$TMP_STATUS"
  pinged=$((pinged + 1))
done

if [ "$pinged" -eq 0 ] && [ ! -s "$TMP_STATUS" ]; then
  # Zero usable pairs (e.g. whitespace-only CC_WINDOW_PING_PROFILES): loud,
  # never a silently-fresh empty status the briefing would read as clean.
  echo "$(ts)  ERROR  no usable profile pairs in CC_WINDOW_PING_PROFILES" >> "$LOG"
  printf 'config\t2\t%s\n' "$(now)" >> "$TMP_STATUS"
fi

mv "$TMP_STATUS" "$STATUS"
trap - EXIT
exit 0
