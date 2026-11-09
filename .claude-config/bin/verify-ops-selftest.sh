#!/usr/bin/env bash
# verify-ops-selftest.sh: prove the model-policy checks of verify-ops.sh
# (14 session pin, 15 Opus 5 ban, 15b retired ids and Haiku), the
# SessionStart matcher check (18), the boot checks (1b root instructions, 5
# citations, 16 the always-loaded core, 17 retired hooks, 21 and 21b the
# identity layer), the identity-exclusion check (23), the sandbox guards (24),
# dangling memory links (25), the memory digest fit and pool cap (6, 6b), and
# the skill index and size checks (9, 9b), and the secrets scan exits (8) pass the shipped tree
# against current Stage-1-shaped settings, and fail on each class they exist to
# catch. It also pins the shipped .gitattributes rule that merges pool
# MEMORY.md indexes with the union driver, and the shipped .gitignore rules
# that keep SKILLS/synced and SKILLS/.trash out of the repo.
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
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/sandbox-guard.sh" && sandbox_guard || exit 97
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

# 9. The always-loaded core (16): the shipped core linked into the rules dir
# passes; a missing link, a link aimed elsewhere, and an oversized core FAIL;
# deploy.ps1's import-file form passes; a leftover boot shim WARNs only.
core_case() {
  new_case "$1"
  mkdir -p "$OPS/CONTEXT" "$HOME/.claude/rules"
  cp "$SRC_OPS/CONTEXT/core.md" "$OPS/CONTEXT/"
  cp "$SRC_OPS/.claude-config/deploy.sh" "$OPS/.claude-config/"
}
core_case core-linked
ln -s "$OPS/CONTEXT/core.md" "$HOME/.claude/rules/ops-core.md"
run check_core_boot
chk "shipped core linked into ~/.claude/rules -> OK" "$([ "$FAILS" = 0 ] && [ "$WARNS" = 0 ] && [ "$OKS" = 1 ]; echo $?)"
core_case core-unlinked
run check_core_boot
chk "rules link missing -> FAIL" "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -q 'ops-core.md missing'; echo $?)"
core_case core-elsewhere
printf '# Core\n' > "$HOME/other-core.md"
ln -s "$HOME/other-core.md" "$HOME/.claude/rules/ops-core.md"
run check_core_boot
chk "rules link aimed elsewhere -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
core_case core-import
printf '@%s\n' "$OPS/CONTEXT/core.md" > "$HOME/.claude/rules/ops-core.md"
run check_core_boot
chk "rules import file (deploy.ps1 fallback) -> OK" "$([ "$FAILS" = 0 ]; echo $?)"
core_case core-import-missing
printf '@%s\n' "$HOME/missing/CONTEXT/core.md" > "$HOME/.claude/rules/ops-core.md"
run check_core_boot
chk "import of a nonexistent core -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
core_case core-import-other
mkdir -p "$HOME/other/CONTEXT"
printf '# Other core\n' > "$HOME/other/CONTEXT/core.md"
printf '@%s\n' "$HOME/other/CONTEXT/core.md" > "$HOME/.claude/rules/ops-core.md"
run check_core_boot
chk "import of another checkout's core -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
core_case 'core import spaces'
printf '@%s\n' "$OPS/CONTEXT/core.md" > "$HOME/.claude/rules/ops-core.md"
run check_core_boot
chk "unescaped spaces truncate an import -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
printf '@%s\n' "${OPS// /\\ }/CONTEXT/core.md" > "$HOME/.claude/rules/ops-core.md"
run check_core_boot
chk "escaped spaces in an import -> OK" "$([ "$FAILS" = 0 ]; echo $?)"
core_case core-import-code
printf '```\n@%s\n```\n' "$OPS/CONTEXT/core.md" > "$HOME/.claude/rules/ops-core.md"
run check_core_boot
chk "an import inside a code fence is not loaded -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
core_case core-profile
ln -s "$OPS/CONTEXT/core.md" "$HOME/.claude/rules/ops-core.md"
CLAUDE_CONFIG_DIR="$HOME/other-profile" run check_core_boot
chk "active profile without its own core rule -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
mkdir -p "$HOME/other-profile/rules"
ln -s "$OPS/CONTEXT/core.md" "$HOME/other-profile/rules/ops-core.md"
CLAUDE_CONFIG_DIR="$HOME/other-profile" run check_core_boot
chk "active profile with a valid core rule -> OK" "$([ "$FAILS" = 0 ]; echo $?)"
core_case core-oversized
ln -s "$OPS/CONTEXT/core.md" "$HOME/.claude/rules/ops-core.md"
head -c 15360 /dev/zero | tr '\0' 'x' >> "$OPS/CONTEXT/core.md"
run check_core_boot
chk "core.md over 15,360 bytes -> FAIL" "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -q 'budget'; echo $?)"
core_case core-missing
rm -f "$OPS/CONTEXT/core.md"
run check_core_boot
chk "core.md missing -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
core_case core-oldshim
ln -s "$OPS/CONTEXT/core.md" "$HOME/.claude/rules/ops-core.md"
printf 'claude() { command claude --append-system-prompt "$boot" "$@"; }\n' > "$HOME/.zshrc.local"
run check_core_boot
chk "retired boot shim in .zshrc.local -> WARN, not FAIL" "$([ "$FAILS" = 0 ] && [ "$WARNS" = 1 ]; echo $?)"

# 10. Root instructions (1b), principle citations (5), retired hooks (17).
new_case root-shipped
cp "$SRC_OPS/AGENTS.md" "$OPS/"
run check_root_instructions
chk "AGENTS.md alone -> OK" "$([ "$FAILS" = 0 ] && [ "$OKS" = 1 ]; echo $?)"
printf '# old startup sequence\n' > "$OPS/CLAUDE.md"
run check_root_instructions
chk "root CLAUDE.md present -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
rm -f "$OPS/AGENTS.md" "$OPS/CLAUDE.md"
run check_root_instructions
chk "AGENTS.md missing -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
new_case citations
mkdir -p "$OPS/CONTEXT"
cp "$SRC_OPS/CONTEXT/how-i-work.md" "$SRC_OPS/CONTEXT/core.md" "$OPS/CONTEXT/"
run check_citations
chk "shipped doctrine: citations in range (1..15)" "$([ "$FAILS" = 0 ] && printf '%s' "$OUT" | grep -q 'in range (1..15)'; echo $?)"
printf 'see P16\n' >> "$OPS/CONTEXT/core.md"
run check_citations
chk "citation to P16 -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
new_case citations-project-number
mkdir -p "$OPS/CONTEXT"
cp "$SRC_OPS/CONTEXT/how-i-work.md" "$SRC_OPS/CONTEXT/core.md" "$OPS/CONTEXT/"
printf 'Billed to project P20260101.0001; see P2.\n' > "$OPS/CONTEXT/work-tracking.md"
run check_citations
chk "a PSA project number is not a principle -> OK" "$([ "$FAILS" = 0 ] && [ "$OKS" = 1 ]; echo $?)"
printf 'Also P16. applies, after P20260101.0001.\n' >> "$OPS/CONTEXT/work-tracking.md"
run check_citations
chk "out-of-range P16 beside a project number -> FAIL naming P16 only" \
  "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -q 'P16' && ! printf '%s' "$OUT" | grep -q 'P20260101'; echo $?)"
mkdir -p "$HOME/elsewhere/linked-skill"
printf 'see P99\n' > "$HOME/elsewhere/linked-skill/SKILL.md"
sed -i '/P16/d' "$OPS/CONTEXT/work-tracking.md"
ln -s "$HOME/elsewhere/linked-skill" "$OPS/SKILLS/linked-skill"
run check_citations
chk "a symlinked skill another repo owns is not cited here -> OK" "$([ "$FAILS" = 0 ]; echo $?)"
new_case retired-hook
run check_retired_hooks
chk "Stage-1-shaped settings: no retired hook -> OK" "$([ "$WARNS" = 0 ] && [ "$OKS" = 1 ]; echo $?)"
set_settings '.hooks.SessionStart[0].hooks += [{"type":"command","command":"\"$H/.claude-config/hooks/foreman-charter.sh\""}]'
run check_retired_hooks
chk "foreman-charter.sh still registered -> WARN" "$([ "$WARNS" = 1 ] && [ "$FAILS" = 0 ]; echo $?)"

# 11. The identity layer (21, 21b): template on a fresh copy passes; the
# template on a bootstrapped copy and a missing USER.md FAIL; a filled USER.md
# passes; retired files left behind WARN.
new_case identity
mkdir -p "$OPS/CONTEXT"
cp "$SRC_OPS/CONTEXT/USER.md" "$OPS/CONTEXT/"
run check_identity_canary
chk "USER.md template on a fresh copy -> OK" "$([ "$FAILS" = 0 ] && [ "$OKS" = 1 ]; echo $?)"
printf 'stage=1\n' > "$OPS/CONTEXT/.bootstrapped"
run check_identity_canary
chk "USER.md template on a bootstrapped copy -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
sed -i '/USER-TEMPLATE: unfilled/d' "$OPS/CONTEXT/USER.md"
run check_identity_canary
chk "filled USER.md (canary removed) -> OK" "$([ "$FAILS" = 0 ]; echo $?)"
rm -f "$OPS/CONTEXT/USER.md"
run check_identity_canary
chk "USER.md missing -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
run check_retired_context
chk "no retired files -> OK" "$([ "$WARNS" = 0 ] && [ "$OKS" = 1 ]; echo $?)"
printf 'old\n' > "$OPS/CONTEXT/about-me.md"
mkdir -p "$OPS/WORKFORCE"
run check_retired_context
chk "about-me.md and WORKFORCE/ left behind -> WARN naming both" "$([ "$WARNS" = 1 ] && printf '%s' "$OUT" | grep -q 'about-me.md' && printf '%s' "$OUT" | grep -q 'WORKFORCE/'; echo $?)"

# 12. Line-ref lint (4) skips mounted skills: a line number in a mirror listed
# in VENDORED.tsv is not fixable here; the same text in a local skill WARNs.
new_case linerefs
mkdir -p "$OPS/SKILLS/mountedx" "$OPS/SKILLS/localx"
printf 'a finding at line 702 was wrong\n' > "$OPS/SKILLS/mountedx/SKILL.md"
printf 'mountedx\tsrc/skills/mountedx\n' >> "$OPS/SKILLS/VENDORED.tsv"
run check_linerefs
chk "line ref in a mounted skill -> OK" "$([ "$WARNS" = 0 ] && [ "$OKS" = 1 ]; echo $?)"
printf 'a finding at line 702 was wrong\n' > "$OPS/SKILLS/localx/SKILL.md"
run check_linerefs
chk "line ref in a local skill -> WARN" "$([ "$WARNS" = 1 ] && printf '%s' "$OUT" | grep -q 'localx'; echo $?)"

# A gate cannot return green when its mirror verifier cannot run or encounters
# an unsafe manifest or filesystem error. MISSING sources retain their WARN.
new_case vendored-error
mkdir -p "$OPS/.claude-config/bin"
printf '#!/usr/bin/env bash\necho "skills-vendor: unsafe mirror destination" >&2\nexit 3\n' \
  > "$OPS/.claude-config/bin/skills-vendor.sh"
chmod +x "$OPS/.claude-config/bin/skills-vendor.sh"
run check_skills_vendored
chk "mirror verifier error -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"
chmod -x "$OPS/.claude-config/bin/skills-vendor.sh"
run check_skills_vendored
chk "mirror verifier not executable -> FAIL" "$([ "$FAILS" = 1 ]; echo $?)"

# 24. Sandbox guards: the shipped suites pass; a fixture suite that names a
# destructive tool without the guard FAILs, and missing tooling FAILs.
new_case sandbox
mkdir -p "$OPS/.claude-config/bin/tests"
for f in sandbox-run sandbox-lint sandbox-guard.sh sandbox_guard.py; do cp -p "$SRC_OPS/.claude-config/bin/$f" "$OPS/.claude-config/bin/"; done
printf '#!/usr/bin/env bash\n%s\nbash "$HERE/../branch-gc" --dry-run\n' \
  '. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97' \
  > "$OPS/.claude-config/bin/tests/guarded-test.sh"
run check_sandbox_guards
chk "guarded destructive suite -> OK" "$([ "$FAILS" = 0 ] && [ "$OKS" = 1 ]; echo $?)"
printf '#!/usr/bin/env bash\nbash "$HERE/../branch-gc" --apply\n' > "$OPS/.claude-config/bin/tests/bare-test.sh"
run check_sandbox_guards
chk "destructive suite without the guard -> FAIL naming it" "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -q 'bare-test.sh'; echo $?)"
rm -f "$OPS/.claude-config/bin/sandbox-lint"
run check_sandbox_guards
chk "sandbox-lint missing -> FAIL" "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -q 'sandbox-lint'; echo $?)"
new_case sandbox-real
OPS="$SRC_OPS"
run check_sandbox_guards
chk "shipped suites all carry the guard -> OK" "$([ "$FAILS" = 0 ] && [ "$OKS" = 1 ]; echo $?)"

# 25. Dangling memory links WARN and name memory-init; a resolving link and a
# real directory stay quiet.
new_case memlinks
mkdir -p "$HOME/.claude/projects/-ok/" "$HOME/.claude/projects/-dir/memory" "$HOME/pool-ok" "$HOME/.claude/projects/-gone"
ln -s "$HOME/pool-ok" "$HOME/.claude/projects/-ok/memory"
run check_memory_links
chk "resolving link and real dir -> OK" "$([ "$WARNS" = 0 ] && [ "$OKS" = 1 ]; echo $?)"
ln -s "$HOME/pool-removed" "$HOME/.claude/projects/-gone/memory"
run check_memory_links
chk "dangling memory link -> WARN naming memory-init" "$([ "$WARNS" = 1 ] && printf '%s' "$OUT" | grep -q -- '-gone' && printf '%s' "$OUT" | grep -q 'memory-init'; echo $?)"

# 26. SKILLS/synced (Claude Code's claude.ai skill sync) is gitignored and not an OPS skill: the
# index check skips it, and a copy already committed WARNs with the untrack command. The same
# sync moves a skill it drops into SKILLS/.trash/, which is gitignored too, so the daily
# backup's `git add -A` never commits it.
new_case skills-synced
mkdir -p "$OPS/SKILLS/synced/org-skill" "$OPS/SKILLS/.trash/old-org-skill"
printf -- '---\nname: org-skill\n---\n' > "$OPS/SKILLS/synced/org-skill/SKILL.md"
printf -- '---\nname: old-org-skill\n---\n' > "$OPS/SKILLS/.trash/old-org-skill/SKILL.md"
cp "$SRC_OPS/.gitignore" "$OPS/.gitignore"
# The index check is a substring match and the shipped README says "un-synced"; reword it so
# only the skip, not that word, can keep the synced dir out of the index.
sed -i 's/synced/sync-ed/g' "$OPS/SKILLS/README.md"
git -C "$OPS" init -q
run check_skills_index
chk "untracked synced and .trash dirs -> no WARN" "$([ "$WARNS" = 0 ]; echo $?)"
chk "the shipped .gitignore ignores SKILLS/synced" "$(git -C "$OPS" check-ignore -q SKILLS/synced/org-skill/SKILL.md; echo $?)"
chk "the shipped .gitignore ignores SKILLS/.trash" "$(git -C "$OPS" check-ignore -q SKILLS/.trash/old-org-skill/SKILL.md; echo $?)"
git -C "$OPS" add -f SKILLS/synced/org-skill/SKILL.md
git -C "$OPS" -c user.name=selftest -c user.email=selftest@example.invalid commit -q -m fixture
run check_skills_index
chk "committed synced dir -> WARN with the untrack command" "$([ "$WARNS" = 1 ] && printf '%s' "$OUT" | grep -q 'rm -r --cached --quiet SKILLS/synced'; echo $?)"
# A symlinked SKILLS entry is a skill another repo owns and indexes; a real
# directory the README does not name still WARNs.
new_case skills-index-link
mkdir -p "$HOME/elsewhere/other-skill"
printf -- '---\nname: other-skill\n---\n' > "$HOME/elsewhere/other-skill/SKILL.md"
ln -s "$HOME/elsewhere/other-skill" "$OPS/SKILLS/linked-other-skill"
run check_skills_index
chk "symlinked skill entry -> no WARN" "$([ "$WARNS" = 0 ]; echo $?)"
mkdir -p "$OPS/SKILLS/unindexed-local-skill"
run check_skills_index
chk "real unindexed skill dir -> WARN naming it" "$([ "$WARNS" = 1 ] && printf '%s' "$OUT" | grep -q 'unindexed-local-skill'; echo $?)"

# 27. Memory pool entry cap (6b): WARN only, never FAIL (a pool is the
# Operator's content). The shipped memory-index counts the entries, so the cap
# and the --check exit codes come from the real indexer, never a stub, except
# where a broken indexer is the case under test.
mk_pool() {  # pool_name n_entries
  local d="$OPS/.claude-memory/$1" i
  mkdir -p "$d"
  for ((i = 1; i <= $2; i++)); do
    printf -- '---\nname: e%03d\ndescription: entry %d\nmetadata:\n  type: reference\n---\nbody\n' "$i" "$i" > "$d/e$(printf '%03d' "$i").md"
  done
}
cap_case() {
  new_case "$1"
  mkdir -p "$OPS/.claude-config/bin" "$OPS/.claude-memory"
  cp "$SRC_OPS/.claude-config/bin/memory-index" "$OPS/.claude-config/bin/memory-index"
}
cap_case cap-none
run check_memory_pool_cap
chk "no pools -> OK" "$([ "$FAILS" = 0 ] && [ "$WARNS" = 0 ] && printf '%s' "$OUT" | grep -q 'no memory pools to cap'; echo $?)"
cap_case cap-at
mk_pool host-a-home-op-OPS 60; mk_pool host-a-home-op-OPS-PROJECTS-ExampleOrg-app 3
run check_memory_pool_cap
chk "a pool at exactly 60 entries -> OK naming the cap and pool count" \
  "$([ "$FAILS" = 0 ] && [ "$WARNS" = 0 ] && printf '%s' "$OUT" | grep -qF 'within the 60-entry cap (2 pools)'; echo $?)"
cap_case cap-over
mk_pool host-a-home-op-OPS 61
run check_memory_pool_cap
chk "a pool at 61 entries -> WARN naming pool and count, no FAIL" \
  "$([ "$FAILS" = 0 ] && [ "$WARNS" = 1 ] && printf '%s' "$OUT" | grep -qF 'host-a-home-op-OPS(61)'; echo $?)"
mk_pool host-b-home-op-OPS 65
run check_memory_pool_cap
chk "two pools over the cap -> one WARN naming both" \
  "$([ "$FAILS" = 0 ] && [ "$WARNS" = 1 ] && printf '%s' "$OUT" | grep -qF 'host-a-home-op-OPS(61)' && printf '%s' "$OUT" | grep -qF 'host-b-home-op-OPS(65)'; echo $?)"
cap_case cap-backfill
mk_pool host-a-home-op-OPS 3
printf 'no frontmatter\n' > "$OPS/.claude-memory/host-a-home-op-OPS/bad.md"
run check_memory_pool_cap
chk "an entry needing a backfill is not a cap finding -> OK" "$([ "$FAILS" = 0 ] && [ "$WARNS" = 0 ]; echo $?)"
cap_case cap-broken
mk_pool host-a-home-op-OPS 3
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(1)\n' > "$OPS/.claude-config/bin/memory-index"
run check_memory_pool_cap
chk "an indexer that cannot read a pool -> FAIL, never a pass" \
  "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -qF 'host-a-home-op-OPS(exit 1)'; echo $?)"
rm -f "$OPS/.claude-config/bin/memory-index"
run check_memory_pool_cap
chk "memory-index missing -> FAIL" "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -q 'memory-index missing'; echo $?)"

# 28. Memory digest fit (6). A stub memory-index with --digest-fit prints the
# fit line each fixture pool carries in fit.txt; one without it keeps the native
# MEMORY.md size check. The shipped indexer on a small pool passes either way.
fit_stub() {  # writes a --digest-fit stub that exits with $1
  cat > "$OPS/.claude-config/bin/memory-index" <<PY
#!/usr/bin/env python3
import os, sys
DIGEST_CAP = 9000
if len(sys.argv) > 2 and sys.argv[1] == "--digest-fit":
    for p in sys.argv[2:]:
        f = os.path.join(p, "fit.txt")
        if os.path.exists(f):
            print(p + "\t" + open(f).read().strip())
    sys.exit($1)
sys.exit(1)
PY
}
fit_case() {
  new_case "$1"
  mkdir -p "$OPS/.claude-config/bin" "$OPS/.claude-memory/pool-a" "$OPS/.claude-memory/pool-b"
}
fit_case fit-ok
fit_stub 0
printf '12\t12\t0\t0\n' > "$OPS/.claude-memory/pool-a/fit.txt"
printf '3\t3\t0\t0\n' > "$OPS/.claude-memory/pool-b/fit.txt"
run check_memory_indexes
chk "every pool fits the digest -> OK naming the budget" \
  "$([ "$FAILS" = 0 ] && [ "$WARNS" = 0 ] && printf '%s' "$OUT" | grep -qF '9000-character digest'; echo $?)"
printf '80\t50\t25\t5\n' > "$OPS/.claude-memory/pool-a/fit.txt"
run check_memory_indexes
chk "a pool past the digest budget -> WARN naming it, no FAIL" \
  "$([ "$FAILS" = 0 ] && [ "$WARNS" = 1 ] && printf '%s' "$OUT" | grep -qF 'pool-a(25 by name only, 5 not shown, of 80)'; echo $?)"
printf 'error\tOSError: unreadable\n' > "$OPS/.claude-memory/pool-a/fit.txt"
fit_stub 1
run check_memory_indexes
chk "a pool the indexer cannot measure -> FAIL" "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -q 'pool-a(OSError'; echo $?)"
printf '80\t50\t25\t5\n' > "$OPS/.claude-memory/pool-a/fit.txt"
rm -f "$OPS/.claude-memory/pool-b/fit.txt"
run check_memory_indexes
chk "a run that measures 1 of 2 pools -> FAIL, even with an over-budget row" \
  "$([ "$FAILS" = 1 ] && [ "$WARNS" = 0 ] && printf '%s' "$OUT" | grep -qF '(1/2 pools measured)'; echo $?)"
printf '3\t2\t2\t0\n' > "$OPS/.claude-memory/pool-b/fit.txt"
fit_stub 0
run check_memory_indexes
chk "a fit line whose counts do not add up -> FAIL" "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -q 'unreadable fit line'; echo $?)"
fit_case fit-native
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$OPS/.claude-config/bin/memory-index"
head -c 25000 /dev/zero | tr '\0' 'x' > "$OPS/.claude-memory/pool-a/MEMORY.md"
run check_memory_indexes
chk "no --digest-fit: MEMORY.md over 24KB -> WARN (the native-load check)" \
  "$([ "$FAILS" = 0 ] && [ "$WARNS" = 1 ] && printf '%s' "$OUT" | grep -q 'over 24KB'; echo $?)"
cap_case fit-shipped
mk_pool host-a-home-op-OPS 3
memory_checks() { check_memory_indexes; check_memory_pool_cap; }
run memory_checks
chk "the shipped memory-index on a small pool -> no FAIL, no WARN" "$([ "$FAILS" = 0 ] && [ "$WARNS" = 0 ]; echo $?)"

# 29. Skill size (9b): 16,384 bytes and 1,500 characters a line, both
# inclusive; WARN only. Mounted, synced and symlinked skills are skipped, and the
# shipped skills pass.
mk_skill() {  # name bytes [longest_line_chars]
  local d="$OPS/SKILLS/$1"; mkdir -p "$d"
  python3 - "$d/SKILL.md" "$2" "${3:-60}" <<'PY'
import sys
path, size, line = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
out = "---\nname: x\n---\n"
while len(out.encode()) + line + 1 <= size:
    out += "a" * line + "\n"
out += "b" * (size - len(out.encode()))
open(path, "w").write(out)
PY
}
size_case() { new_case "$1"; rm -rf "${OPS:?}/SKILLS"; mkdir -p "$OPS/SKILLS"; : > "$OPS/SKILLS/VENDORED.tsv"; }
new_case size-shipped
run check_skill_size
chk "shipped skills within 16 KB and 1,500 characters a line -> OK" "$([ "$FAILS" = 0 ] && [ "$WARNS" = 0 ] && [ "$OKS" = 1 ]; echo $?)"
size_case size-small; mk_skill small 800
run check_skill_size
chk "a small skill -> OK" "$([ "$FAILS" = 0 ] && [ "$WARNS" = 0 ]; echo $?)"
size_case size-edge; mk_skill edge 16384
run check_skill_size
chk "exactly 16,384 bytes -> OK" "$([ "$FAILS" = 0 ] && [ "$WARNS" = 0 ]; echo $?)"
size_case size-big; mk_skill big 16385
run check_skill_size
chk "16,385 bytes -> WARN naming skill and size, no FAIL" \
  "$([ "$FAILS" = 0 ] && [ "$WARNS" = 1 ] && printf '%s' "$OUT" | grep -qF 'big (16385 bytes)'; echo $?)"
size_case size-wide-edge; mk_skill wide 3000 1500
run check_skill_size
chk "a 1,500-character line -> OK" "$([ "$FAILS" = 0 ] && [ "$WARNS" = 0 ]; echo $?)"
size_case size-wide; mk_skill wide 3000 1501
run check_skill_size
chk "a 1,501-character line -> WARN naming the line and its length" \
  "$([ "$FAILS" = 0 ] && [ "$WARNS" = 1 ] && printf '%s' "$OUT" | grep -qE 'wide \(line [0-9]+ is 1501 characters\)'; echo $?)"
size_case size-skipped
mk_skill mountedx 40000; printf 'mountedx\tsrc/skills/mountedx\n' > "$OPS/SKILLS/VENDORED.tsv"
mk_skill synced 40000
mk_skill linked 40000; mv "$OPS/SKILLS/linked" "$HOME/linked-target"; ln -s "$HOME/linked-target" "$OPS/SKILLS/linked"
run check_skill_size
chk "mounted, synced and symlinked skills are skipped -> OK" "$([ "$FAILS" = 0 ] && [ "$WARNS" = 0 ]; echo $?)"
rm -rf "${OPS:?}/SKILLS"
run check_skill_size
chk "no SKILLS dir -> FAIL, not a pass" "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -q 'could not run'; echo $?)"

# 30. The shipped .gitattributes merges pool MEMORY.md indexes with the union
# driver. Two machines that share a pool (an Operator who gives both the same
# host key) each regenerate its index; without union, an entry each added
# between the same two lines stops the daily sync's pull --rebase on a conflict.
# The fixture replays that rebase.
new_case gitattributes
cp "$SRC_OPS/.gitattributes" "$OPS/.gitattributes"
mkdir -p "$OPS/.claude-memory/host-a-home-op-OPS"
g() { git -C "$OPS" -c user.name=selftest -c user.email=selftest@example.invalid "$@"; }
g init -q -b main
chk "pool MEMORY.md has merge=union" \
  "$(git -C "$OPS" check-attr merge -- .claude-memory/host-a-home-op-OPS/MEMORY.md | grep -q ': merge: union$'; echo $?)"
printf -- '- [A](a.md)\n- [C](c.md)\n' > "$OPS/.claude-memory/host-a-home-op-OPS/MEMORY.md"
g add -A; g commit -q -m base
g checkout -q -b other
printf -- '- [A](a.md)\n- [B1](b1.md)\n- [C](c.md)\n' > "$OPS/.claude-memory/host-a-home-op-OPS/MEMORY.md"
g commit -q -am other
g checkout -q main
printf -- '- [A](a.md)\n- [B2](b2.md)\n- [C](c.md)\n' > "$OPS/.claude-memory/host-a-home-op-OPS/MEMORY.md"
g commit -q -am main
g checkout -q other
g rebase -q main >/dev/null 2>&1; rc=$?
chk "a rebase of two index edits between the same lines applies clean" \
  "$([ "$rc" = 0 ] && grep -qF 'b1.md' "$OPS/.claude-memory/host-a-home-op-OPS/MEMORY.md" && grep -qF 'b2.md' "$OPS/.claude-memory/host-a-home-op-OPS/MEMORY.md" && ! grep -q '^<<<<<<<' "$OPS/.claude-memory/host-a-home-op-OPS/MEMORY.md"; echo $?)"

# 31. Secrets scan (8). secrets-scan.sh exits 1 on a hit and 2 when grep could
# not scan a line; the check reports the two apart and keeps the scanner's
# stderr, so an unreadable line is never called a found secret with no detail.
scan_stub() {  # writes a secrets-scan.sh stub: stdout $1, stderr $2, exit $3
  mkdir -p "$OPS/.claude-config/bin"
  printf '#!/usr/bin/env bash\nprintf "%%s" "%s"\nprintf "%%s" "%s" >&2\nexit %s\n' "$1" "$2" "$3" \
    > "$OPS/.claude-config/bin/secrets-scan.sh"
  chmod +x "$OPS/.claude-config/bin/secrets-scan.sh"
}
new_case secrets-scan
scan_stub "" "" 0
run check_secrets
chk "secrets scan clean -> OK" "$([ "$FAILS" = 0 ] && [ "$OKS" = 1 ]; echo $?)"
scan_stub "pool/a.md:3: aws-key" "" 1
run check_secrets
chk "secrets scan hit (exit 1) -> FAIL naming the hit" \
  "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -q 'literal secrets detected' && printf '%s' "$OUT" | grep -qF 'pool/a.md:3: aws-key'; echo $?)"
scan_stub "" "secrets-scan: pool/b.md:9: grep failed on aws-key (exit 2); line not scanned" 2
run check_secrets
chk "secrets scan could not read a line (exit 2) -> FAIL with its reason, not a hit" \
  "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -q 'could not read some lines' && printf '%s' "$OUT" | grep -qF 'pool/b.md:9' && ! printf '%s' "$OUT" | grep -q 'literal secrets detected'; echo $?)"
scan_stub "" "usage: secrets-scan.sh" 64
run check_secrets
chk "secrets scan did not run (exit 64) -> FAIL naming the exit" \
  "$([ "$FAILS" = 1 ] && printf '%s' "$OUT" | grep -qF 'did not run (exit 64)'; echo $?)"

if [ "$fails" -eq 0 ]; then
  echo "verify-ops-selftest: all cases pass"
  exit 0
fi
echo "verify-ops-selftest: $fails case(s) failed"
exit 1
