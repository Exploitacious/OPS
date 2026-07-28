#!/usr/bin/env bash
# model-probe.sh — decides which foreman model THIS machine pins, and writes
# that decision into the deployed settings.json.
#
# The harness names a foreman ROLE, not a fixed model: Fable 5 where the
# Operator's plan grants it, Opus 4.8 everywhere else — same charter either
# way. Whether a plan grants Fable cannot be read out of a config file, so it
# is probed: one throwaway headless round-trip against the Fable model id. A
# clean exit means this account can reach it; a clean rejection means it
# cannot, and the box pins the fallback foreman instead.
#
# Usage:
#   model-probe.sh                   probe + apply the verdict (same as --refresh)
#   model-probe.sh --refresh         probe + apply the verdict
#   model-probe.sh --status          print pin / last verdict / override / sticky
#   model-probe.sh --force fable     pin Fable and stop probing (Operator override)
#   model-probe.sh --force opus48    pin Opus 4.8 and stop probing
#   model-probe.sh --clear-override  drop the override, resume probing
#
# Exit: 0 = pin is in its intended state (a graceful skip counts) · 1 = could
# not apply the pin, settings left exactly as found · 2 = usage or state error.
#
# Runs unattended — Stage 1 calls it at deploy time, and an Operator who
# changes plans re-runs (or schedules) it later. No prompts, no stdin, one
# line of output per event, every line prefixed "model-probe:". Overlapping
# runs are serialized by a non-blocking flock; the second one exits quietly.
#
# State (~/.local/state/ops, every write tmp+mv so a killed run never leaves a
# half-file the next run would misread):
#   model-probe-result         last verdict + ISO timestamp
#   model-probe-override       Operator-forced verdict; --refresh obeys it blindly
#   model-probe-fable-capable  sticky: this box has probed Fable-positive before
#   model-probe-settings.bak   settings.json as it was before the last pin write
#
# The sticky marker is why one bad day cannot demote a Fable box. On a plan
# where Fable is available it is usage-capped, so a probe fired mid-cap gets a
# quota-shaped rejection that looks nothing like "your plan lacks Fable" —
# demoting on that would flip the pin every time the Operator worked hard.
# Once a machine has proven Fable access, a quota-shaped or timed-out probe
# leaves the pin alone; only a clean, non-quota failure demotes it.
#
# The pin is applied by rewriting an EXISTING top-level "model" line in place,
# never by re-emitting the file, so the Operator's formatting and key order
# survive. settings.json is resolved through readlink -f first: Stage 1
# symlinks ~/.claude/settings.json into its own repo, and an in-place edit of
# the symlink would replace it with a plain copy and silently detach the box
# from Stage 1. A settings.json with NO "model" key is left structurally
# alone — that Operator is running on the ANTHROPIC_DEFAULT_* aliases on
# purpose, and a probe has no business restructuring someone's JSON.
#
# Knobs / test hooks: OPS_MODEL_PROBE_SETTINGS (settings file to read+write),
# OPS_MODEL_PROBE_MODEL (model id to probe), OPS_MODEL_PROBE_BIN (claude
# binary), OPS_MODEL_PROBE_TIMEOUT (seconds, default 120),
# OPS_MODEL_PROBE_STATE_DIR (state dir).
set -uo pipefail

STATE_DIR="${OPS_MODEL_PROBE_STATE_DIR:-$HOME/.local/state/ops}"
PROBE_MODEL="${OPS_MODEL_PROBE_MODEL:-claude-fable-5}"
PROBE_TIMEOUT="${OPS_MODEL_PROBE_TIMEOUT:-120}"

FABLE_PIN="claude-fable-5[1m]"
OPUS48_PIN="claude-opus-4-8[1m]"

log() { printf 'model-probe: %s\n' "$*"; }
iso() { date -Is; }

mkdir -p "$STATE_DIR" 2>/dev/null || { log "cannot create state dir $STATE_DIR"; exit 2; }

RESULT="$STATE_DIR/model-probe-result"
OVERRIDE="$STATE_DIR/model-probe-override"
STICKY="$STATE_DIR/model-probe-fable-capable"
BACKUP="$STATE_DIR/model-probe-settings.bak"
LOCK="$STATE_DIR/.model-probe.lock"

# Settings target. Stage 1 owns ~/.claude/settings.json; before that deploy has
# run, its repo copy is the only settings file on the box.
SETTINGS="${OPS_MODEL_PROBE_SETTINGS:-}"
if [ -z "$SETTINGS" ]; then
  SETTINGS="$(readlink -f "$HOME/.claude/settings.json" 2>/dev/null)"
  [ -n "$SETTINGS" ] && [ -f "$SETTINGS" ] || SETTINGS="$HOME/linuxploitacious/claude/.claude/settings.json"
fi

usage() {
  echo "usage: model-probe.sh [--refresh | --status | --force fable|opus48 | --clear-override]"
}

# Serialize mutating runs (deploy + cron + an impatient Operator can collide).
take_lock() {
  exec 9>"$LOCK" || return 0
  flock -n 9 || { log "another run holds the lock — exiting"; exit 0; }
}

write_state() {
  local path="$1" content="$2" tmp="$1.tmp.$$"
  if printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
    mv -- "$tmp" "$path" && return 0
  fi
  rm -f "$tmp"
  log "could not write state file $path"
  return 1
}

record() { write_state "$RESULT" "$1 $(iso)"; }

pin_for() {
  case "$1" in
    fable)  printf '%s\n' "$FABLE_PIN" ;;
    opus48) printf '%s\n' "$OPUS48_PIN" ;;
    *)      return 1 ;;
  esac
}

# jq is the only thing standing between a sed edit and a corrupted settings.json,
# so a missing jq is a hard stop, checked before anything is probed or written.
require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  log "jq not found — cannot validate settings.json after an edit; install jq and re-run"
  return 1
}

apply_pin() {
  local want="$1" cur
  if [ ! -f "$SETTINGS" ]; then
    log "settings.json not found at $SETTINGS — pin unchanged (run the Stage 1 deploy first)"
    return 0
  fi
  if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    log "settings.json is not valid JSON ($SETTINGS) — refusing to edit it"
    return 1
  fi
  if [ "$(jq -r 'has("model")' "$SETTINGS")" != "true" ]; then
    log "no top-level \"model\" key in $SETTINGS — left alone; this box runs on the ANTHROPIC_DEFAULT_* aliases. Add \"model\": \"$want\" by hand to pin it."
    return 0
  fi
  cur="$(jq -r '.model' "$SETTINGS")"
  if [ "$cur" = "$want" ]; then
    log "pin already \"$want\" — no write"
    return 0
  fi
  if ! cp -- "$SETTINGS" "$BACKUP" 2>/dev/null; then
    log "could not back up $SETTINGS — refusing to edit it"
    return 1
  fi
  chmod 600 "$BACKUP" 2>/dev/null || true   # it is a copy of the Operator's settings
  # 0,/re/ bounds the substitution to the FIRST matching line; the trailing
  # capture keeps whatever followed the value (a comma, or nothing if "model"
  # is the last key).
  sed -E -i "0,/^([[:space:]]*)\"model\"([[:space:]]*):([[:space:]]*)\"[^\"]*\"(.*)\$/s//\\1\"model\"\\2:\\3\"$want\"\\4/" "$SETTINGS"
  # Re-read through jq rather than trusting the sed: this catches both a broken
  # edit and a correct-looking edit that landed on a NESTED "model" key.
  if ! jq -e . "$SETTINGS" >/dev/null 2>&1 || [ "$(jq -r '.model' "$SETTINGS")" != "$want" ]; then
    cp -- "$BACKUP" "$SETTINGS"
    log "pin write corrupted the file or missed the top-level key — restored $SETTINGS from $BACKUP"
    return 1
  fi
  log "pin \"$cur\" -> \"$want\" in $SETTINGS"
  return 0
}

run_probe() {
  local bin out rc one_line
  # cron and deploy shells carry a minimal PATH — resolve the binary explicitly.
  bin="${OPS_MODEL_PROBE_BIN:-$HOME/.local/bin/claude}"
  [ -x "$bin" ] || bin="$(command -v claude 2>/dev/null || true)"
  if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    log "claude CLI not found — probe skipped, pin unchanged"
    record "skipped"
    return 0
  fi

  # MCP stripped and run from $HOME so the probe is a bare text round-trip: no
  # servers spun up, no project context loaded, minimal tokens off the cap.
  out="$(cd "$HOME" && timeout "$PROBE_TIMEOUT" "$bin" -p "Reply with exactly: ok" \
          --model "$PROBE_MODEL" \
          --mcp-config '{"mcpServers":{}}' --strict-mcp-config 2>&1 </dev/null)"
  rc=$?
  one_line="$(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-300)"

  if [ "$rc" -eq 0 ]; then
    write_state "$STICKY" "probed-fable-capable $(iso)"
    record "fable"
    log "probe of $PROBE_MODEL succeeded — Fable available on this box"
    apply_pin "$FABLE_PIN"
    return $?
  fi

  # rc 124 is `timeout` giving up; a quota-shaped rejection is the other
  # failure that says nothing about entitlement. Neither demotes a proven box.
  if [ -f "$STICKY" ] && { [ "$rc" -eq 124 ] || printf '%s' "$out" \
      | grep -qiE 'rate|limit|usage|quota|overloaded|exceeded|capacity'; }; then
    log "fable-capable box, transient/quota failure — pin unchanged (rc=$rc): $one_line"
    record "unchanged"
    return 0
  fi

  log "probe of $PROBE_MODEL failed (rc=$rc) — pinning the fallback foreman: $one_line"
  record "opus48"
  apply_pin "$OPUS48_PIN"
  return $?
}

refresh() {
  local verdict pin
  require_jq || return 1
  if [ -f "$OVERRIDE" ]; then
    read -r verdict _ < "$OVERRIDE"
    if ! pin="$(pin_for "${verdict:-}")"; then
      log "override file holds an unknown verdict ('${verdict:-}') — fix $OVERRIDE or run --clear-override"
      return 2
    fi
    log "override active ($verdict) — enforcing its pin, not probing"
    apply_pin "$pin"
    return $?
  fi
  run_probe
}

status() {
  local pin verdict ov st
  if [ ! -f "$SETTINGS" ]; then
    pin="none ($SETTINGS missing)"
  elif command -v jq >/dev/null 2>&1; then
    pin="$(jq -r 'if has("model") then .model else "none (alias fallback)" end' "$SETTINGS" 2>/dev/null)"
    [ -n "$pin" ] || pin="unreadable (invalid JSON?)"
  else
    pin="unknown (jq not installed)"
  fi
  verdict="never probed"; [ -f "$RESULT" ] && verdict="$(cat "$RESULT")"
  ov="none";              [ -f "$OVERRIDE" ] && ov="$(cat "$OVERRIDE")"
  st="no";                [ -f "$STICKY" ] && st="yes ($(cat "$STICKY"))"
  log "settings:      $SETTINGS"
  log "pin:           $pin"
  log "last verdict:  $verdict"
  log "override:      $ov"
  log "fable-capable: $st"
}

main() {
  local verdict pin
  case "${1:---refresh}" in
    --refresh)
      take_lock
      refresh
      exit $?
      ;;
    --status)
      status
      exit 0
      ;;
    --force)
      verdict="${2:-}"
      if ! pin="$(pin_for "$verdict")"; then
        log "--force takes fable or opus48 (got '${verdict}')"
        usage >&2
        exit 2
      fi
      take_lock
      require_jq || exit 1
      write_state "$OVERRIDE" "$verdict $(iso)" || exit 2
      record "$verdict"
      log "override set to $verdict — probing is off until --clear-override"
      apply_pin "$pin"
      exit $?
      ;;
    --clear-override)
      take_lock
      rm -f "$OVERRIDE"
      log "override cleared — the next --refresh will probe again"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log "unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
}
main "$@"
