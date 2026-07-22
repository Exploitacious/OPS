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
#   export CC_WINDOW_PING_PROFILES="default=$HOME/.claude personal=$HOME/.claude-personal"
# (put the export in the crontab line or a wrapper — cron does not read your
# shell rc).
#
# Model: CC_WINDOW_PING_MODEL (default "sonnet") — the ping only needs the
# cheapest real round-trip; it opens the window exactly the same.
#
# MCP is stripped (--strict-mcp-config + empty config) so the ping is a pure
# text round-trip: no servers spun up, minimal tokens, fast exit. Runs from
# $HOME so no project context loads. Cron runs outside tmux, so
# remote-session-register.sh's tmux guard keeps ping sessions out of the
# reboot-resume registry.
#
# Surfaces: appends ~/.local/state/window-ping/ping.log; rewrites
# last-status.tsv (profile <TAB> rc <TAB> timestamp), which session-briefing.sh
# reads to flag a failed or stale ping at the next session start.
set -uo pipefail

STATE_DIR="$HOME/.local/state/window-ping"
LOG="$STATE_DIR/ping.log"
STATUS="$STATE_DIR/last-status.tsv"
mkdir -p "$STATE_DIR"

PROFILES="${CC_WINDOW_PING_PROFILES:-default=$HOME/.claude}"
MODEL="${CC_WINDOW_PING_MODEL:-sonnet}"

# cron PATH is minimal — resolve the binary explicitly, PATH as fallback.
CLAUDE_BIN="$HOME/.local/bin/claude"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude || true)"
if [ -z "$CLAUDE_BIN" ]; then
  echo "$(date '+%F %T %Z')  ERROR  claude binary not found" >> "$LOG"
  now="$(date '+%F %H:%M')"
  for pair in $PROFILES; do
    printf '%s\t127\t%s\n' "${pair%%=*}" "$now"
  done > "$STATUS"
  exit 0
fi

TMP_STATUS="$STATUS.tmp.$$"
: > "$TMP_STATUS"

for pair in $PROFILES; do
  profile="${pair%%=*}"
  cfg="${pair#*=}"
  out="$(cd "$HOME" && CLAUDE_CONFIG_DIR="$cfg" timeout 180 "$CLAUDE_BIN" \
          -p "ping" --model "$MODEL" \
          --mcp-config '{"mcpServers":{}}' --strict-mcp-config 2>&1 </dev/null)"
  rc=$?
  one_line="$(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-300)"
  echo "$(date '+%F %T %Z')  $profile  rc=$rc  $one_line" >> "$LOG"
  printf '%s\t%s\t%s\n' "$profile" "$rc" "$(date '+%F %H:%M')" >> "$TMP_STATUS"
done

mv "$TMP_STATUS" "$STATUS"
exit 0
