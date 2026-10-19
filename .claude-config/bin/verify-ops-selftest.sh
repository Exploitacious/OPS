#!/usr/bin/env bash
# verify-ops-selftest.sh: prove the model-policy checks of verify-ops.sh
# (14 session pin, 15 Opus 5 ban, 15b retired ids and Haiku), the
# SessionStart matcher check (18), and the identity-exclusion check (23) pass
# the shipped tree against current Stage-1-shaped settings, and fail on each
# class they exist to catch.
#
# Sources verify-ops.sh (its main runs only when executed) and drives single
# checks against fixture trees under a throwaway HOME made by mktemp. It never
# reads or writes the real ~/.claude, ~/OPS, or ~/linuxploitacious: HOME and
# OPS point into the scratch dir for every case, and CLAUDE_CONFIG_DIR is unset.
#
# Exit 0 = every case behaves; 1 = defect.
# Assertions capture the immediately preceding condition's status as chk's
# argument; no command intervenes to overwrite it.
# shellcheck disable=SC2319
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_OPS="$(cd "$DIR/../.." && pwd)"

# Resolved before any case reassigns HOME; read only (copied into a case).
REAL_STAGE1="${OPS_SELFTEST_STAGE1:-$HOME/linuxploitacious/claude/.claude/settings.json}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unset CLAUDE_CONFIG_DIR
fails=0

# shellcheck source=verify-ops.sh
. "$DIR/verify-ops.sh"
command -v jq >/dev/null 2>&1 || { echo "verify-ops-selftest: jq is required"; exit 1; }

# Settings shaped like the current Stage-1 file: the model keys, the
# source-scoped SessionStart matchers, and the Haiku compaction window.
stage1_settings() {
  cat <<'JSON'
{
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-5-5[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5-5[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-5-5",
    "CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-5-5[1m]"
  },
  "model": "claude-opus-5-5[1m]",
  "hooks": {
    "SessionStart": [
      { "matcher": "startup|clear", "hooks": [
        { "type": "command", "command": "\"$H/.claude-config/hooks/session-briefing.sh\"" },
        { "type": "command", "command": "\"$H/.claude-config/hooks/memory-index.sh\"" },
        { "type": "command", "command": "\"$H/.claude-config/hooks/session-work-init.sh\"" } ] },
      { "matcher": "resume|compact", "hooks": [
        { "type": "command", "command": "\"$H/.claude-config/hooks/post-compact-resume.sh\"" },
        { "type": "command", "command": "\"$H/.claude-config/hooks/session-work-init.sh\"" } ] }
    ]
  },
  "modelSettings": { "claude-haiku-5-5": { "autoCompactWindow": 100000 } }
}
JSON
}

# new_case NAME: a fresh HOME holding a copy of the shipped agents, workflows,
# commands and skill scripts, plus Stage-1-shaped settings. Sets HOME and OPS.
new_case() {
  HOME="$WORK/$1"
  OPS="$HOME/OPS"
  mkdir -p "$OPS/.claude-config" "$HOME/.claude"
  cp -r "$SRC_OPS/.claude-config/agents" "$SRC_OPS/.claude-config/workflows" \
        "$SRC_OPS/.claude-config/commands" "$OPS/.claude-config/"
  cp -r "$SRC_OPS/SKILLS" "$OPS/SKILLS"
  stage1_settings > "$HOME/.claude/settings.json"
}

# set_settings JQ_FILTER: rewrite the case's settings through a jq filter.
set_settings() {
  local f="$HOME/.claude/settings.json"
  jq "$1" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# run CHECK...: run checks with fresh counters; output in $OUT, counts in
# FAILS / WARNS / OKS.
run() {
  FAILS=0; WARNS=0; OKS=0
  OUT="$("$@"; printf 'COUNTS %s %s %s\n' "$OKS" "$WARNS" "$FAILS")"
  read -r _ OKS WARNS FAILS < <(printf '%s\n' "$OUT" | grep '^COUNTS ')
}

chk() { # $1=label $2=condition-result (0=pass)
  if [ "$2" -eq 0 ]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/        | /'; fails=$((fails + 1)); fi
}

model_checks() { check_model_policy; check_opus5_ban; check_retired_model_pins; }

echo "verify-ops-selftest:"

# 1. The shipped tree against Stage-1-shaped settings: no FAIL, no WARN.
new_case shipped
run model_checks
chk "shipped tree + Stage-1 settings: 0 fail" "$([ "$FAILS" = 0 ]; echo $?)"
chk "shipped tree + Stage-1 settings: 0 warn" "$([ "$WARNS" = 0 ]; echo $?)"
chk "Opus 5.5 pins do not trip the Opus 5 ban" "$(printf '%s' "$OUT" | grep -q 'OK:   no claude-opus-5 pins'; echo $?)"
chk "exact Haiku 5.5 pin accepted"             "$(printf '%s' "$OUT" | grep -q 'OK:   Haiku pin set'; echo $?)"
run check_sessionstart_matchers
chk "session-work-init on resume|compact is not heavy" "$([ "$WARNS" = 0 ] && [ "$FAILS" = 0 ]; echo $?)"

# 2. The real Stage-1 file, when this host has one: copied into the case, never
# edited in place. Skipped (and said so) on a host without it.
if [ -f "$REAL_STAGE1" ]; then
  new_case realstage1
  cp "$REAL_STAGE1" "$HOME/.claude/settings.json"
  run model_checks
  chk "real Stage-1 settings ($REAL_STAGE1): 0 fail" "$([ "$FAILS" = 0 ]; echo $?)"
  run check_sessionstart_matchers
  chk "real Stage-1 matchers: no heavy hook on resume|compact" "$([ "$WARNS" = 0 ]; echo $?)"
else
  echo "  SKIP  real Stage-1 settings not found at $REAL_STAGE1 (set OPS_SELFTEST_STAGE1)"
fi

# 3. Opus 5 exact id: in settings, in agent frontmatter, in a workflow lane.
new_case opus5-settings
set_settings '.model = "claude-opus-5"'
run check_opus5_ban
chk "settings model claude-opus-5 -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
new_case opus5-agent
printf -- '---\nname: x\nmodel: claude-opus-5[1m]\n---\n' > "$OPS/.claude-config/agents/x.md"
run check_opus5_ban
chk "agent model claude-opus-5[1m] -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
new_case opus5-workflow
printf "await agent('x', { label: 'x', model: 'claude-opus-5' })\n" > "$OPS/.claude-config/workflows/x.js"
run check_opus5_ban
chk "workflow model 'claude-opus-5' -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"

# 4. Retired ids: agent, workflow, skill workflow, settings; the live 5.5 ids pass.
new_case retired-agent
printf -- '---\nname: x\nmodel: claude-opus-4-8[1m]\n---\n' > "$OPS/.claude-config/agents/x.md"
run check_retired_model_pins
chk "agent model claude-opus-4-8[1m] -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
new_case retired-workflow
printf "await agent('x', { model: 'claude-sonnet-5' })\n" > "$OPS/.claude-config/workflows/x.js"
run check_retired_model_pins
chk "workflow model 'claude-sonnet-5' -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
new_case retired-skilljs
mkdir -p "$OPS/SKILLS/x"
printf "const s = { model: 'claude-sonnet-5[1m]' }\n" > "$OPS/SKILLS/x/w.js"
run check_retired_model_pins
chk "skill workflow model claude-sonnet-5[1m] -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
new_case retired-settings
set_settings '.model = "claude-opus-4-8[1m]"'
run model_checks
chk "settings model claude-opus-4-8[1m] -> FAIL (15b) + WARN (14)" "$([ "$FAILS" = 1 ] && [ "$WARNS" = 1 ]; echo $?)"
new_case live-sonnet
printf -- '---\nname: x\nmodel: claude-sonnet-5-5[1m]\n---\n' > "$OPS/.claude-config/agents/x.md"
run check_retired_model_pins
chk "agent model claude-sonnet-5-5[1m] passes (boundary match)" "$([ "$FAILS" = 0 ]; echo $?)"

# 5. Haiku: the earlier tripwire value, a missing key, a suffix, a banned id,
# and the bare alias all FAIL; the exact id on a workflow stage passes.
new_case haiku-old-tripwire
set_settings '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-sonnet-5"'
run check_retired_model_pins
chk "Haiku pin on the retired redirect -> FAIL (retired id + pin)" "$([ "$FAILS" = 2 ]; echo $?)"
new_case haiku-missing
set_settings 'del(.env.ANTHROPIC_DEFAULT_HAIKU_MODEL)'
run check_retired_model_pins
chk "Haiku pin missing -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
new_case haiku-suffix
set_settings '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-5-5[1m]"'
run check_retired_model_pins
chk "Haiku pin with [1m] -> FAIL (banned token + pin)" "$([ "$FAILS" = 2 ]; echo $?)"
new_case haiku-banned
set_settings '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4-5"'
run check_retired_model_pins
chk "Haiku pin claude-haiku-4-5 -> FAIL (banned token + pin)" "$([ "$FAILS" = 2 ]; echo $?)"
new_case haiku-alias
printf "await agent('x', { model: 'haiku' })\n" > "$OPS/.claude-config/workflows/x.js"
run check_retired_model_pins
chk "workflow bare 'haiku' alias -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
new_case haiku-exact
printf "await agent('x', { model: 'claude-haiku-5-5' })\n" > "$OPS/.claude-config/workflows/x.js"
run check_retired_model_pins
chk "workflow model 'claude-haiku-5-5' passes" "$([ "$FAILS" = 0 ]; echo $?)"

# 6. A different session pin is a nudge (WARN), never a gate.
new_case other-pin
set_settings '.model = "claude-sonnet-5-5[1m]"'
run check_model_policy
chk "non-foreman session pin -> WARN, not FAIL" "$([ "$WARNS" = 1 ] && [ "$FAILS" = 0 ]; echo $?)"

# 7. A heavy startup hook on resume|compact still WARNs.
new_case heavy-on-resume
set_settings '.hooks.SessionStart[1].hooks += [{"type":"command","command":"\"$H/.claude-config/hooks/memory-index.sh\""}]'
run check_sessionstart_matchers
chk "memory-index on resume|compact -> WARN" "$([ "$WARNS" = 1 ]; echo $?)"

# Equivalent YAML/JS pin spellings and JSON escapes must not evade the gate.
for spelling in '"model": "claude-sonnet-5"' 'model : claude-sonnet-5' 'model: `claude-sonnet-5`'; do
  new_case alternate-retired
  printf '%s\n' "$spelling" > "$OPS/.claude-config/workflows/x.js"
  run check_retired_model_pins
  chk "retired pin $spelling -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
done
new_case escaped-retired
printf '%s\n' '{"env":{"ANTHROPIC_DEFAULT_HAIKU_MODEL":"claude-haiku-5-5"},"model":"claude-sonnet-\u0035"}' > "$HOME/.claude/settings.json"
run check_retired_model_pins
chk "JSON-escaped retired id -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
new_case escaped-opus
printf '%s\n' '{"model":"claude-opus-\u0035"}' > "$HOME/.claude/settings.json"
run check_opus5_ban
chk "JSON-escaped Opus 5 id -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
for surface in '.claude-config/commands/x.md' 'SKILLS/x.js' '.claude/agents/x.md'; do
  new_case opus-surfaces
  mkdir -p "$(dirname "$OPS/$surface")"
  printf '%s\n' '{"model": "claude-opus-5"}' > "$OPS/$surface"
  run check_opus5_ban
  chk "Opus 5 in $surface -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
done
for id in 'claude-haiku-5-5[1m]' 'anthropic.claude-haiku-5-5' 'claude-haiku-5-5-20261001' 'CLAUDE-HAIKU-5-5'; do
  new_case haiku-lookalike
  printf "const lane = {model: '%s'};\n" "$id" > "$OPS/.claude-config/workflows/x.js"
  run check_retired_model_pins
  chk "Haiku look-alike $id -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
done
new_case profile-missing-pin
mkdir -p "$HOME/other-profile"
printf '%s\n' '{}' > "$HOME/other-profile/settings.json"
CLAUDE_CONFIG_DIR="$HOME/other-profile" run check_retired_model_pins
chk "active profile missing its Haiku pin -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"

# 8. Identity exclusion (23): the shipped scan names every identity file, and
# dropping any one of them, current or retired, FAILs.
new_case exclusion-shipped
mkdir -p "$OPS/.claude-config/bin"
cp "$SRC_OPS/.claude-config/bin/harness-update-scan.sh" "$OPS/.claude-config/bin/"
run check_identity_exclusion
chk "shipped scan lists every identity file" "$([ "$FAILS" = 0 ] && [ "$OKS" = 1 ]; echo $?)"
for name in USER.md standing-orders.md .bootstrapped about-me.md; do
  new_case exclusion-missing
  mkdir -p "$OPS/.claude-config/bin"
  sed "s#CONTEXT/$name|##; s#|CONTEXT/$name)#)#" "$SRC_OPS/.claude-config/bin/harness-update-scan.sh" \
    > "$OPS/.claude-config/bin/harness-update-scan.sh"
  run check_identity_exclusion
  chk "scan without CONTEXT/$name -> FAIL" "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -qF "CONTEXT/$name"; echo $?)"
done

if [ "$fails" -eq 0 ]; then
  echo "verify-ops-selftest: all cases pass"
  exit 0
fi
echo "verify-ops-selftest: $fails case(s) failed"
exit 1
