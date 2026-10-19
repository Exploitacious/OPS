#!/usr/bin/env bash
# model-probe.sh: report whether the models your Claude Code settings pin
# actually answer on this account. Report only: it never edits settings or
# chooses a model for you. Claude Code can update its own cache/auth state;
# policy-managed hooks still apply.
#
# Why report-only. The settings file it reads is, on a linuxploitacious host,
# a symlink into the tracked Stage-1 checkout shared by every profile. An
# earlier version rewrote the "model" line there on every deploy: it pinned
# retired tiers, left a diff in that public checkout, and made its next
# `git pull --ff-only` fail. Which tier to run is a policy decision
# (CONTEXT/model-roles.md); this script only tells you whether a pinned id
# works on your plan, so you can decide.
#
# Usage:
#   model-probe.sh           probe each distinct id the settings pin (one short
#                            headless request per id; spends a few tokens)
#   model-probe.sh --list    print the ids and where they are pinned; no API call
#   model-probe.sh -h        this help
#
# Ids read (jq): the top-level "model" pin and the env keys
# ANTHROPIC_DEFAULT_OPUS_MODEL, ANTHROPIC_DEFAULT_SONNET_MODEL,
# ANTHROPIC_DEFAULT_HAIKU_MODEL, CLAUDE_CODE_SUBAGENT_MODEL.
#
# Exit: 0 = every id answered (or --list) · 1 = at least one id was rejected or
# the probe was inconclusive (timeout, rate or usage limit) · 2 = usage or
# environment error (no settings, no jq, no claude CLI).
#
# Knobs / test hooks: OPS_MODEL_PROBE_SETTINGS (settings file to read),
# OPS_MODEL_PROBE_BIN (claude binary), OPS_MODEL_PROBE_TIMEOUT (seconds per
# probe, default 120).
set -uo pipefail

PROBE_TIMEOUT="${OPS_MODEL_PROBE_TIMEOUT:-120}"

log() { printf 'model-probe: %s\n' "$*"; }
usage() { echo "usage: model-probe.sh [--list | -h]"; }

MODE="probe"
case "${1:-}" in
  "")       ;;
  --list)   MODE="list" ;;
  -h|--help) usage; exit 0 ;;
  *)        log "unknown argument: $1"; usage >&2; exit 2 ;;
esac

# Honor the active profile. Only the default profile falls back to Stage 1;
# a missing custom profile says nothing about the default profile's pins.
SETTINGS="${OPS_MODEL_PROBE_SETTINGS:-}"
if [ -z "$SETTINGS" ]; then
  SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  if [ ! -f "$SETTINGS" ] && [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
    SETTINGS="$HOME/linuxploitacious/claude/.claude/settings.json"
  fi
fi
[ -f "$SETTINGS" ] || { log "settings.json not found at $SETTINGS (run the Stage 1 deploy first)"; exit 2; }
command -v jq >/dev/null 2>&1 || { log "jq not found; install jq and re-run"; exit 2; }
jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 || { log "$SETTINGS is not a JSON settings object"; exit 2; }

# "<id>\t<keys>": each distinct pinned id once, with every key that pins it,
# the session pin first. An env block that is not an object yields nothing.
PINS="$(jq -r '
  def envval($k): ((.env // {}) | if type == "object" then (.[$k] // "") else "" end) | tostring;
  [ ["model", ((.model // "") | tostring)],
    ["ANTHROPIC_DEFAULT_OPUS_MODEL",   envval("ANTHROPIC_DEFAULT_OPUS_MODEL")],
    ["ANTHROPIC_DEFAULT_SONNET_MODEL", envval("ANTHROPIC_DEFAULT_SONNET_MODEL")],
    ["ANTHROPIC_DEFAULT_HAIKU_MODEL",  envval("ANTHROPIC_DEFAULT_HAIKU_MODEL")],
    ["CLAUDE_CODE_SUBAGENT_MODEL",     envval("CLAUDE_CODE_SUBAGENT_MODEL")] ]
  | map(select(.[1] != "")) | group_by(.[1]) | sort_by(.[0][0] != "model")
  | .[] | [.[0][1], (map(.[0]) | join(", "))] | @tsv' "$SETTINGS")"

if [ -z "$PINS" ]; then
  log "no model ids pinned in $SETTINGS (sessions run on Claude Code's own defaults); nothing to probe"
  exit 0
fi

# Only a recognizable model id is ever passed to the CLI or echoed: a value in
# these keys that is not one may be a misplaced credential.
ID_SHAPE='^[A-Za-z0-9][A-Za-z0-9._:@/-]*(\[1m\])?$'

log "settings: $SETTINGS"
if [ "$MODE" = "list" ]; then
  while IFS=$'\t' read -r id keys; do
    if printf '%s\n' "$id" | grep -qE "$ID_SHAPE"; then
      log "pinned  $id  ($keys)"
    else
      log "pinned  <a value that is not a model id>  ($keys)"
    fi
  done <<< "$PINS"
  exit 0
fi

# cron and deploy shells carry a minimal PATH, so resolve the binary explicitly.
BIN="${OPS_MODEL_PROBE_BIN:-$HOME/.local/bin/claude}"
[ -x "$BIN" ] || BIN="$(command -v claude 2>/dev/null || true)"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  log "claude CLI not found; nothing probed"
  exit 2
fi

bad=0
while IFS=$'\t' read -r id keys; do
  if ! printf '%s\n' "$id" | grep -qE "$ID_SHAPE"; then
    log "SKIP    <a value that is not a model id>  ($keys): fix that key by hand"
    bad=1
    continue
  fi
  # Disable tools, user customizations and transcript persistence: a model
  # check must not run the user's startup hooks or plugin sync. Use safe-mode,
  # not bare: bare ignores subscription OAuth credentials. Managed hooks still
  # apply, and the CLI can update its own cache/auth state.
  out="$(cd "$HOME" && timeout "$PROBE_TIMEOUT" "$BIN" -p "Reply with exactly: ok" \
          --model "$id" \
          --safe-mode --no-session-persistence --tools '' \
          --mcp-config '{"mcpServers":{}}' --strict-mcp-config 2>&1 </dev/null)"
  rc=$?
  one_line="$(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-300)"
  if [ "$rc" -eq 0 ]; then
    log "ok      $id  ($keys)"
  elif [ "$rc" -eq 124 ] || printf '%s' "$out" | grep -qiE 'rate|limit|usage|quota|overloaded|exceeded|capacity'; then
    # A timeout or a quota-shaped refusal says nothing about entitlement.
    log "UNSURE  $id  ($keys): rc=$rc, timeout or usage limit; re-run later: $one_line"
    bad=1
  else
    log "FAIL    $id  ($keys): rc=$rc: $one_line"
    bad=1
  fi
done <<< "$PINS"

if [ "$bad" -ne 0 ]; then
  log "nothing was changed. To pin a different tier, see CONTEXT/model-roles.md (Settings, pins, and the shared Stage-1 file)."
  exit 1
fi
log "every pinned id answered"
exit 0
