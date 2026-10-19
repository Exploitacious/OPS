#!/usr/bin/env bash
# verify-ops.sh: the OPS drift gate. Machine-checks the conventions that used
# to live only in prose (conventions are lint-enforced, not documented-and-hoped:
# a rule a machine cannot check is a rule that silently rots).
#
# Usage:
#   verify-ops.sh            full report (OK/WARN/FAIL per check)
#   verify-ops.sh --quiet    print only WARN/FAIL lines (for hooks/timers)
#
# The checkout is ~/OPS; set OPS_DIR to check another one (a worktree, a test
# install). Host checks (the deployed core link, settings.json) still read $HOME.
#
# Exit: 0 = no FAILs (WARNs allowed) · 1 = at least one FAIL
#
# Consumers: the pre-compact-synthesis closeout stage runs it before wrap-up;
# a nightly systemd --user timer (ops-verify) writes its output to
# ~/.local/state/ops/verify-last.txt which session-briefing.sh surfaces.
# Add new checks as functions + a line in main; keep each check independent.
set -uo pipefail

OPS="${OPS_DIR:-$HOME/OPS}"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
FAILS=0
WARNS=0
OKS=0

ok()   { OKS=$((OKS+1)); [ "$QUIET" = 1 ] || echo "OK:   $*"; }
warn() { WARNS=$((WARNS+1)); echo "WARN: $*"; }
fail() { FAILS=$((FAILS+1)); echo "FAIL: $*"; }

# 1. Root canonical files only (project-kata rule 1). LICENSE + BOOTSTRAP.md are
# canonical for this public template: the repo must carry a license, and
# BOOTSTRAP.md is the first-launch entry point the AGENTS.md startup gate reads.
# AGENTS.md is the repo's instruction file. A root CLAUDE.md is reported by
# check 1b with its own reason, not here.
# GENERALIZATION-RULES.md is deliberately absent from this list: it is a build
# marker and must fail here until it is removed (see check_ship_gate).
check_root() {
  local allowed="README.md AGENTS.md CHANGELOG.md IDEAS.md DEPLOYMENT.md BOOTSTRAP.md LICENSE CONTRIBUTING.md CLAUDE.md"
  local extras=""
  for f in "$OPS"/*; do
    [ -f "$f" ] || continue
    local b; b="$(basename "$f")"
    case " $allowed " in *" $b "*) ;; *) case "$b" in .*) ;; *) extras="$extras $b";; esac;; esac
  done
  [ -z "$extras" ] && ok "root holds only canonical files" || fail "non-canonical files at OPS root:$extras"
}

# 1b. Root instructions are AGENTS.md alone. Claude Code reads a repo's AGENTS.md
# only when no CLAUDE.md sits in the working directory or above it, so a root
# CLAUDE.md hides this repo's AGENTS.md and every AGENTS.md in the repos under
# PROJECTS/. Copies from before the core boot still carry one: FAIL with the
# migration pointer.
check_root_instructions() {
  if [ ! -f "$OPS/AGENTS.md" ]; then
    fail "AGENTS.md missing at the OPS root (the repo instructions and the first-launch gate)"
  elif [ -e "$OPS/CLAUDE.md" ]; then
    fail "root CLAUDE.md present: Claude Code then skips AGENTS.md here and under PROJECTS/; move anything of yours into AGENTS.md or standing-orders.md and delete it (DEPLOYMENT.md, \"Migrating to the core boot\")"
  else
    ok "root instructions are AGENTS.md alone"
  fi
}

# 2. Every top-level dir appears in README's tree.
check_readme_tree() {
  local missing=""
  for d in "$OPS"/*/ "$OPS"/.claude-config/ "$OPS"/.claude-memory/ "$OPS"/.claude-handoffs/; do
    [ -d "$d" ] || continue
    local b; b="$(basename "$d")"
    case "$b" in .git|.pytest_cache|.claude) continue;; esac
    grep -q "$b" "$OPS/README.md" || missing="$missing $b/"
  done
  [ -z "$missing" ] && ok "README tree covers all top-level dirs" || warn "dirs absent from README.md tree:$missing"
}

# 3. CHANGELOG freshness: doc-surface commits in last 24h need a CHANGELOG touch.
check_changelog() {
  local doc_commits changelog_commits
  doc_commits="$(git -C "$OPS" log --since='24 hours ago' --oneline -- CONTEXT/ AGENTS.md README.md DEPLOYMENT.md BOOTSTRAP.md .claude-config/ SKILLS/ 2>/dev/null | wc -l)"
  changelog_commits="$(git -C "$OPS" log --since='24 hours ago' --oneline -- CHANGELOG.md 2>/dev/null | wc -l)"
  if [ "$doc_commits" -gt 0 ] && [ "$changelog_commits" -eq 0 ]; then
    warn "CHANGELOG: $doc_commits doc-surface commit(s) in 24h with no CHANGELOG entry"
  else
    ok "CHANGELOG freshness"
  fi
}

# 4. Line-ref lint: core docs must not cite code by line number (drift class).
check_linerefs() {
  local hits
  hits="$(grep -rnE '(line ~?[0-9]{2,}|:[0-9]{3,}\))' \
    "$OPS/AGENTS.md" "$OPS/README.md" "$OPS/DEPLOYMENT.md" "$OPS/BOOTSTRAP.md" \
    "$OPS"/CONTEXT/*.md "$OPS"/SKILLS/*/SKILL.md 2>/dev/null | grep -v 'verify-ops' | grep -v '"~line' | head -20)" || true
  [ -z "$hits" ] && ok "no line-number refs in core docs" || warn "line-number refs in core docs (cite sections, not lines):"$'\n'"$hits"
}

# 5. Doctrine citation range: 'Principle N' / bare 'P<N>' must exist in
# how-i-work.md § Principles (headings "### P<N>. <title>").
check_citations() {
  local max n bad=""
  max="$(grep -cE '^### P[0-9]+\. ' "$OPS/CONTEXT/how-i-work.md" 2>/dev/null)" || max=0
  [ "$max" -gt 0 ] || { warn "could not count principles in how-i-work.md"; return; }
  while IFS= read -r n; do
    [ -n "$n" ] && [ "$n" -gt "$max" ] && bad="$bad P$n"
  done < <(grep -rhoE '([Pp]rinciple |P)[0-9]+' \
      "$OPS/AGENTS.md" "$OPS"/CONTEXT/*.md "$OPS"/SKILLS/*/SKILL.md 2>/dev/null \
      | grep -oE '[0-9]+' | sort -u)
  [ -z "$bad" ] && ok "doctrine citations in range (1..$max)" || fail "citations to nonexistent principles:$bad (doctrine has $max)"
}

# 6. Memory index size limits (binary truncates ~24.4KB).
check_memory_indexes() {
  local over=""
  while IFS= read -r idx; do
    local sz; sz="$(wc -c < "$idx")"
    [ "$sz" -gt 24576 ] && over="$over $(basename "$(dirname "$idx")")(${sz}B)"
  done < <(find "$OPS/.claude-memory" -maxdepth 2 -name MEMORY.md 2>/dev/null)
  [ -z "$over" ] && ok "all memory indexes under 24KB" || warn "memory index over 24KB limit (entries truncate; run /memory-prune):$over"
}

# 7. NOTES/ root holds only the MASTER/ vault.
check_notes_root() {
  local stray
  stray="$(find "$OPS/NOTES" -maxdepth 1 -type f 2>/dev/null | head -5)"
  [ -z "$stray" ] && ok "NOTES/ root clean (vault-only)" || fail "files misfiled at NOTES/ root (move into NOTES/MASTER/): $stray"
}

# 8. Secrets scan over memory pools + lessons files.
check_secrets() {
  local scan="$OPS/.claude-config/bin/secrets-scan.sh" out
  [ -x "$scan" ] || { warn "secrets-scan.sh missing/not executable"; return; }
  if out="$("$scan" "$OPS/.claude-memory" "$OPS/CONTEXT/projects" 2>/dev/null)"; then
    ok "no literal secrets in memory/lessons"
  else
    fail "literal secrets detected (sanitize to SOPS/.env pointers):"$'\n'"$(echo "$out" | head -10)"
  fi
}

# 9. SKILLS/README index covers every skill dir.
check_skills_index() {
  local missing=""
  for d in "$OPS"/SKILLS/*/; do
    local b; b="$(basename "$d")"
    grep -q "$b" "$OPS/SKILLS/README.md" || missing="$missing $b"
  done
  [ -z "$missing" ] && ok "SKILLS README indexes all entries" || warn "skills absent from SKILLS/README.md index:$missing"
}

# 10. projects-map covers every repo dir under every org cluster.
# Iterate whatever org clusters exist rather than hardcoding names: a public
# template ships zero repos, and each Operator invents their own cluster dirs.
check_projects_map() {
  local missing=""
  for org in "$OPS/PROJECTS"/*/; do
    [ -d "$org" ] || continue
    local orgname; orgname="$(basename "$org")"
    for d in "$org"*/; do
      [ -d "$d" ] || continue
      local b; b="$(basename "$d")"
      grep -qi "$b" "$OPS/PROJECTS/projects-map.md" || missing="$missing $orgname/$b"
    done
  done
  [ -z "$missing" ] && ok "projects-map covers all repo dirs" || warn "repos absent from projects-map.md:$missing"
}

# 11. Stale handoff batons (>7 days pending).
check_handoffs() {
  local stale
  stale="$(find "$OPS/.claude-handoffs/pending" -name '*.md' -mtime +7 2>/dev/null | head -5)"
  [ -z "$stale" ] && ok "no stale pending handoffs" || warn "pending handoff baton(s) older than 7 days: $stale"
}

# 12. Autonomy-critical settings must stay on: a blocked run notifies via
# push (charter § Full-autonomy); guard hooks must stay registered. Checks the
# DEPLOYED settings surface (~/.claude/settings.json, Stage-1-owned), falling
# back to the Stage-1 repo copy when the deploy has not run yet.
check_autonomy_settings() {
  local settings="$HOME/.claude/settings.json" bad=""
  [ -f "$settings" ] || settings="$HOME/linuxploitacious/claude/.claude/settings.json"
  [ -f "$settings" ] || { warn "settings.json not found (run Stage 1 deploy first)"; return; }
  grep -q '"agentPushNotifEnabled": true' "$settings" 2>/dev/null || bad="$bad agentPushNotifEnabled"
  grep -q 'git-guard.sh' "$settings" 2>/dev/null || bad="$bad git-guard-unregistered"
  grep -q 'secrets-guard.sh' "$settings" 2>/dev/null || bad="$bad secrets-guard-unregistered"
  [ -x "$OPS/.claude-config/hooks/git-guard.sh" ] || bad="$bad git-guard-not-executable"
  [ -z "$bad" ] && ok "autonomy-critical settings + guards intact" || fail "autonomy safety net degraded:$bad"
}

# 13. Ship gate for the public template: README must exist, and the build-time
# scrub contract must be gone. GENERALIZATION-RULES.md is the private-content
# denylist used to extract this template from the Operator's private harness:
# it names identities that must never ship, so its presence at ship time is a
# hard FAIL.
check_ship_gate() {
  local bad=""
  [ -f "$OPS/README.md" ] || bad="$bad README.md-missing"
  [ -f "$OPS/GENERALIZATION-RULES.md" ] && bad="$bad GENERALIZATION-RULES.md-present(build-marker-must-not-ship)"
  [ -z "$bad" ] && ok "ship gate: README present, no build markers" || fail "ship gate:$bad"
}

# 14. Session pin (CONTEXT/model-roles.md: Opus 5.5 is the foreman). The
# top-level "model" key is what boots. WARN, never FAIL: an Operator may pin
# another tier on purpose, and the pin lives in the Stage-1 file OPS never
# writes, so a different pin is a nudge, not a gate. The Haiku pin and every
# banned or retired id are FAILs in checks 15 and 15b. Same deployed-then-
# stage-1 settings fallback as check_autonomy_settings.
OPS_FOREMAN_PIN="claude-opus-5-5[1m]"
check_model_policy() {
  local settings="$HOME/.claude/settings.json" pin
  [ -f "$settings" ] || settings="$HOME/linuxploitacious/claude/.claude/settings.json"
  [ -f "$settings" ] || { warn "settings.json not found (run Stage 1 deploy first)"; return; }
  if command -v jq >/dev/null 2>&1 && jq -e . "$settings" >/dev/null 2>&1; then
    pin="$(jq -r 'if type == "object" and (.model | type) == "string" then .model else "" end' "$settings" 2>/dev/null)"
  else
    # Anchored at top-level indentation so a nested "model" in someone's custom
    # config cannot be mistaken for the session pin.
    pin="$(grep -oE '^  "model"[[:space:]]*:[[:space:]]*"[^"]*"' "$settings" | head -1 \
      | sed -E 's/^.*"([^"]*)"$/\1/')"
  fi
  if [ -z "$pin" ]; then
    ok "no top-level model pin (sessions boot on the ANTHROPIC_DEFAULT_* aliases)"
  elif [ "$pin" = "$OPS_FOREMAN_PIN" ]; then
    ok "session pin is the foreman tier ($OPS_FOREMAN_PIN)"
  else
    warn "session pin \"${pin:0:80}\" is not the foreman tier $OPS_FOREMAN_PIN (fine if deliberate; see CONTEXT/model-roles.md)"
  fi
}

# _ops_settings_files: every Claude settings file this host can boot from, one
# per line, deduped by realpath (Stage 1 is usually the symlink target of the
# deployed file, so the common case would otherwise report twice).
_ops_settings_files() {
  local f rp seen=""
  for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "$HOME/.claude/settings.json" \
           "$HOME/.claude-personal/settings.json" "$HOME/linuxploitacious/claude/.claude/settings.json"; do
    [ -f "$f" ] || continue
    rp="$(readlink -f "$f" 2>/dev/null || echo "$f")"
    case " $seen " in *" $rp "*) continue;; esac
    seen="$seen $rp"
    printf '%s\n' "$f"
  done
}

# Share the pin surfaces across the bans: skill workflows and project agents
# can select a model just as the top-level workflows and agents can.
_ops_pin_files() {
  find -L "$OPS/.claude-config/agents" "$OPS/.claude-config/workflows" \
       "$OPS/.claude-config/commands" "$OPS/.claude/agents" -type f -print0 2>/dev/null
  find -L "$OPS/SKILLS/" -type d -name node_modules -prune -o -type f -name '*.js' -print0 2>/dev/null
}

# JSON escapes do not change the selected model. Decode settings for every
# model ban, rather than letting an escaped digit evade a raw grep.
_ops_settings_text() {
  if command -v jq >/dev/null 2>&1 && jq -e . "$1" >/dev/null 2>&1; then
    jq -r '.. | if type == "object" then keys[] elif type == "string" then . else empty end' "$1" 2>/dev/null
  else
    cat "$1"
  fi
}

# YAML and JavaScript accept quoted keys and spaces before the colon;
# JavaScript also accepts template literals. These are real pin spellings.
OPS_MODEL_KEY="(^|[^[:alnum:]_])[\"'\`]?model[\"'\`]?[[:space:]]*:[[:space:]]*[\"'\`]?"

# 15. Opus 5 ban (Operator directive 2026-08-20). As a fan-out worker it burned
# disproportionate cache-write and round-trips for no quality edge. Enforced
# here rather than trusted to prose: a stale pin is invisible until it has
# already spent the budget. Scoped to PINS only (agent frontmatter, Workflow
# lane objects, the settings files), so the doctrine's own ban text, which must
# name the id to be readable, never trips its own gate. The id must END at
# `claude-opus-5` (then `[1m]`, a quote, whitespace, or EOL): Opus 5.5
# (`claude-opus-5-5[1m]`) is the foreman and allowed, and the earlier bare
# prefix match failed every fresh install against the current Stage-1 settings.
check_opus5_ban() {
  local hits="" f found
  while IFS= read -r -d '' f; do
    found="$(grep -nE "${OPS_MODEL_KEY}claude-opus-5(\[|[^A-Za-z0-9-]|$)" "$f" 2>/dev/null)"
    [ -n "$found" ] && hits="$hits"$'\n'"$f:$found"
  done < <(_ops_pin_files)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _ops_settings_text "$f" | grep -E 'claude-opus-5(\[|[^A-Za-z0-9-]|$)' >/dev/null && hits="$hits"$'\n'"$f references claude-opus-5"
  done < <(_ops_settings_files)
  hits="$(printf '%s' "$hits" | sed '/^$/d')"
  if [ -z "$hits" ]; then
    ok "no claude-opus-5 pins (Opus 5 ban intact)"
  else
    fail "claude-opus-5 is BANNED but still pinned (repin a foreman or high-criticality pin to $OPS_FOREMAN_PIN, a lane pin to claude-sonnet-5-5[1m]):"$'\n'"$hits"
  fi
}

# 15b. Retired ids stay unpinned, and Haiku 5.5 is the only Haiku a pin may
# name (CONTEXT/model-roles.md, Bans).
#
# Retired: Sonnet 5 and Opus 4.8. A retired id left in a pin does not fail
# loudly: lanes quietly keep running the retired model. Scope is live pins
# ONLY: `model:` lines in agent definitions, workflow scripts and the workflow
# scripts skills ship (SKILLS/**/*.js), and the Claude settings files (whole
# file). Not prose. The id must END at its last digit (then `[1m]`, a quote,
# whitespace, `}`, or EOL): `claude-sonnet-5` is a bare prefix of the live
# `claude-sonnet-5-5`, so a prefix match would ban the new default.
#
# Haiku: exactly `claude-haiku-5-5` is allowed; every other Haiku id is banned
# wherever a pin can live. The scan matches WHOLE TOKENS case-insensitively,
# not `model:` lines, because a pin can sit behind a constant, a JSON key, or a
# provider prefix. A token is claude-<...>haiku<...> or haiku-<digit><...>, with
# trailing punctuation trimmed; a token of letters and underscores only is an
# env var name (ANTHROPIC_DEFAULT_HAIKU_MODEL), not an id, and is skipped.
# `claude-haiku-5` is a bare prefix of the allowed id, so it and a dated 5.5
# stay banned. The bare `haiku` alias is refused as a value too: it resolves to
# Haiku 5.5 only while the Stage-1 pin is live on a recent Claude Code, and to
# Haiku 4.5 elsewhere.
#
# The pin: ANTHROPIC_DEFAULT_HAIKU_MODEL in the settings must be EXACTLY
# `claude-haiku-5-5`. The haiku alias and Claude Code's background requests
# resolve through it, and without it they fall back to Haiku 4.5. Read with jq
# from `.env`; a host without settings or jq cannot prove it, so that is a
# WARN, not a silent pass. Before this check, the gate FAILed on any Haiku id,
# the allowed one included, which failed every fresh install.
HAIKU_OK="claude-haiku-5-5"

# _haiku_banned: text on stdin -> "<line>:<token>" for each Haiku token other
# than HAIKU_OK. Detect case-insensitively but compare the exception exactly: a
# mixed-case look-alike is not the allowed API id.
_haiku_banned() {
  # Keep provider prefixes and context suffixes: neither a Bedrock spelling
  # nor claude-haiku-5-5[1m] is the one allowed exact id.
  grep -inoE '[a-z0-9][a-z0-9._:@/-]*(\[[^]]*\])?' \
    | grep -iE 'claude[-_][a-z0-9._@:-]*haiku|haiku[-_][0-9]' \
    | sed -E 's/[._@:-]+$//' \
    | grep -viE '^[0-9]+:[a-z_]+$' \
    | grep -vE "^[0-9]+:${HAIKU_OK}\$"
}

# _haiku_alias_lines: text on stdin -> the line number of each line whose value
# is the bare haiku alias: a quoted literal ('haiku', "haiku[1m]", `haiku`), an
# unquoted YAML `model: haiku`, a shell assignment, or a parameter fallback.
_haiku_alias_lines() {
  grep -niE "[\"'\`]haiku(\[1m\])?[\"'\`]|^[[:space:]]*model[[:space:]]*:[[:space:]]*haiku(\[1m\])?([[:space:]]+#.*)?[[:space:]]*\$|(^|[;[:space:]])[a-z_][a-z0-9_]*=haiku(\[1m\])?([;[:space:]]|\$)|\{[^}]*:-haiku(\[1m\])?\}" | cut -d: -f1
}

# Settings are decoded with jq before the Haiku scan (JSON escapes do not change
# the model Claude Code selects); the raw file is scanned when jq cannot read it.
_settings_haiku_banned() {
  _ops_settings_text "$1" | _haiku_banned
}

# 0 when a JSON string VALUE in settings file $1 is the bare haiku alias. Not
# grep -q: an early exit can SIGPIPE jq, and pipefail then reads a match as a miss.
_settings_alias() {
  if command -v jq >/dev/null 2>&1 && jq -e . "$1" >/dev/null 2>&1; then
    jq -r '.. | strings | @json' "$1" 2>/dev/null | grep -ixE '"haiku(\[1m\])?"' >/dev/null
  else
    grep -qiE '"haiku(\[1m\])?"[[:space:]]*($|[],}])' "$1" 2>/dev/null
  fi
}

check_retired_model_pins() {
  local retired="claude-sonnet-5 claude-opus-4-8" end='(\[|[^A-Za-z0-9-]|$)'
  local id found hits="" f line settings
  local -a surf=()

  # Pin surfaces: agent definitions, workflow scripts, commands, project agents,
  # and the workflow scripts skills ship.
  while IFS= read -r -d '' f; do surf+=("$f"); done < <(_ops_pin_files)

  for f in ${surf[@]+"${surf[@]}"}; do
    for id in $retired; do
      found="$(grep -nE "${OPS_MODEL_KEY}${id}${end}" "$f" 2>/dev/null)"
      [ -n "$found" ] && hits="$hits"$'\n'"$(printf '%s\n' "$found" | while IFS= read -r line; do printf '%s:%s\n' "$f" "$line"; done)"
    done
    while IFS= read -r line; do
      [ -n "$line" ] && hits="$hits"$'\n'"$f:${line%%:*}: banned Haiku ${line#*:}"
    done < <(_haiku_banned < "$f")
    while IFS= read -r line; do
      [ -n "$line" ] && hits="$hits"$'\n'"$f:$line: bare haiku alias (name $HAIKU_OK in full)"
    done < <(_haiku_alias_lines < "$f")
  done

  # Settings files, whole file, id only (a settings line can carry other values).
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for id in $retired; do
      _ops_settings_text "$f" | grep -E "${id}${end}" >/dev/null && hits="$hits"$'\n'"$f pins $id"
    done
    for id in $(_settings_haiku_banned "$f" | cut -d: -f2- | awk '!s[$0]++'); do
      hits="$hits"$'\n'"$f pins banned Haiku $id"
    done
    _settings_alias "$f" && hits="$hits"$'\n'"$f pins the bare haiku alias (name $HAIKU_OK in full)"
  done < <(_ops_settings_files)

  hits="$(printf '%s' "$hits" | sed '/^$/d')"
  if [ -z "$hits" ]; then
    ok "no live pin of a retired id (claude-sonnet-5, claude-opus-4-8) or of a Haiku other than $HAIKU_OK"
  else
    fail "retired or banned id still pinned (repin a retired lane id to claude-sonnet-5-5[1m] and a retired foreman id to $OPS_FOREMAN_PIN; the one allowed Haiku is $HAIKU_OK, named in full; for a Stage-1 settings file, pull linuxploitacious rather than editing it):"$'\n'"$hits"
  fi

  settings="$(_ops_settings_files)"
  if [ -z "$settings" ]; then
    warn "settings.json not found: the Haiku pin (ANTHROPIC_DEFAULT_HAIKU_MODEL = $HAIKU_OK) cannot be verified on this host"
    return
  fi
  # A healthy default profile cannot cover a missing pin in another profile:
  # CLAUDE_CONFIG_DIR selects that profile's settings independently.
  while IFS= read -r f; do _check_haiku_pin "$f"; done <<< "$settings"
}

_check_haiku_pin() {
  local settings="$1" pin shown
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not installed: the Haiku pin (ANTHROPIC_DEFAULT_HAIKU_MODEL = $HAIKU_OK) in $settings cannot be verified on this host"
  elif ! pin="$(jq -r '((.env // {}) | if type == "object" then (.ANTHROPIC_DEFAULT_HAIKU_MODEL // "" | tostring) else "" end) | @json' "$settings" 2>/dev/null)"; then
    fail "$settings does not parse as a JSON settings object: the Haiku pin (ANTHROPIC_DEFAULT_HAIKU_MODEL = $HAIKU_OK) cannot be read"
  else
    # Keep JSON escapes, drop the surrounding quotes: plain command substitution
    # strips trailing newlines and would accept a pin that merely starts with
    # the allowed id.
    pin="${pin#\"}"; pin="${pin%\"}"
    # Echo only a recognizable public Claude model slug, never an unknown value:
    # an arbitrary string in that key may be a misplaced credential.
    if printf '%s\n' "$pin" | grep -qiE '^(claude[-_][a-z0-9._@:-]*|haiku)(\[1m\])?$'; then
      shown="'${pin:0:80}'"
    else
      shown="a non-id value"
    fi
    if [ -z "$pin" ]; then
      fail "ANTHROPIC_DEFAULT_HAIKU_MODEL is missing or empty in $settings: it must be $HAIKU_OK; without it the haiku alias and background requests resolve to Haiku 4.5 (banned)"
    elif [ "$pin" = "$HAIKU_OK" ]; then
      ok "Haiku pin set (ANTHROPIC_DEFAULT_HAIKU_MODEL = $HAIKU_OK)"
    elif [ "${pin%%\[*}" = "$HAIKU_OK" ]; then
      fail "ANTHROPIC_DEFAULT_HAIKU_MODEL in $settings is $shown: drop the suffix; the pin must be exactly $HAIKU_OK (Haiku lanes stay under 100K tokens)"
    else
      fail "ANTHROPIC_DEFAULT_HAIKU_MODEL in $settings is $shown, not $HAIKU_OK (an older Stage-1 copy pointed it elsewhere; pull linuxploitacious)"
    fi
  fi
}

# 16. The always-loaded core. CONTEXT/core.md is the one file every session and
# lane loads: deploy.sh links it into ~/.claude/rules/ops-core.md, which Claude
# Code loads on every launch path (terminal, T3 Code, IDE, claude -p). FAIL when
# the core is missing or not under its byte budget (every session and lane pays
# for it on every turn), when deploy.sh no longer links it, or when the deployed
# rule is missing or resolves elsewhere: each of those boots sessions without
# the core, and nothing else would say so. The rule may also be a small file
# importing the core (`@<path>/CONTEXT/core.md`, deploy.ps1's fallback where a
# symlink needs Developer Mode). A ~/.<shell>rc.local still carrying the retired
# boot shim is a WARN: that shim fails open once the charter is gone, so it is a
# stale block until deploy heals it, not a broken boot.
OPS_CORE_MAX=15360
check_core_boot() {
  local core="$OPS/CONTEXT/core.md" dep="$OPS/.claude-config/deploy.sh"
  local rule="$HOME/.claude/rules/ops-core.md" sz bad="" f stale=""
  if [ ! -f "$core" ]; then
    fail "CONTEXT/core.md missing: sessions boot without the always-loaded core"
    return
  fi
  sz="$(wc -c < "$core" | tr -d ' ')"
  [ "$sz" -lt "$OPS_CORE_MAX" ] || bad="$bad; core.md is ${sz} bytes, the budget is under ${OPS_CORE_MAX}"
  grep -qF 'rules/ops-core.md' "$dep" 2>/dev/null || bad="$bad; deploy.sh no longer links the core into ~/.claude/rules"
  if [ -L "$rule" ]; then
    [ "$(readlink -f "$rule" 2>/dev/null)" = "$(readlink -f "$core")" ] \
      || bad="$bad; $rule resolves to $(readlink -f "$rule" 2>/dev/null || echo nothing), not $core (re-run deploy.sh)"
  elif [ -f "$rule" ]; then
    grep -qE "^@.*CONTEXT/core\.md[[:space:]]*$" "$rule" \
      || bad="$bad; $rule is neither a link to nor an import of $core (re-run deploy.sh)"
  else
    bad="$bad; $rule missing (run .claude-config/deploy.sh)"
  fi
  if [ -n "$bad" ]; then
    fail "always-loaded core broken${bad}"
  else
    ok "core.md (${sz}B) loads on every launch path through $rule"
  fi
  for f in "$HOME/.zshrc.local" "$HOME/.bashrc.local"; do
    [ -f "$f" ] && grep -qF -- '--append-system-prompt' "$f" 2>/dev/null && stale="$stale $f"
  done
  [ -z "$stale" ] || warn "retired boot shim (--append-system-prompt) still in:$stale (re-run deploy.sh to replace it with the ultracode-only shim)"
}

# 17. Retired SessionStart hooks unregistered. foreman-charter.sh (the old
# charter injection) and remote-session-register.sh (the old auto-register) are
# deleted. A Stage-1 entry for either is a silent no-op behind its `test -x`
# guard, but it is a dead line that suggests behavior OPS no longer has.
# settings.json is Stage-1-owned, so this WARNs, never FAILs.
check_retired_hooks() {
  local settings="$HOME/.claude/settings.json" hits="" h
  [ -f "$settings" ] || settings="$HOME/linuxploitacious/claude/.claude/settings.json"
  [ -f "$settings" ] || { warn "settings.json not found (run Stage 1 deploy first)"; return; }
  for h in foreman-charter.sh remote-session-register.sh; do
    grep -qF "$h" "$settings" 2>/dev/null && hits="$hits $h"
  done
  [ -z "$hits" ] \
    && ok "no retired SessionStart hooks registered" \
    || warn "settings.json still registers retired hook(s):$hits (remove the entries in your Stage-1 settings; see DEPLOYMENT.md)"
}

# 18. Source-scoped SessionStart matchers. A resume/compact must stop re-paying
# the full boot: the split adds a "resume|compact" matcher whose command list
# excludes the heavy startup-only hooks (memory-index, vault-inbox-check).
# session-work-init is NOT on that list: it stamps only when no stamp exists,
# and a revived session fires source=resume for its whole life, so keeping it
# off resume would never stamp that session (see its header). The current
# Stage-1 settings run it on resume|compact, and counting it as heavy WARNed on
# every fresh install. Tests the semantics: it collects the command list of every group whose matcher fires on
# source=compact and confirms none reference a heavy hook, and that a dedicated
# resume/compact matcher exists. Config-dependent: WARNs until the split lands.
check_sessionstart_matchers() {
  local settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || settings="$HOME/linuxploitacious/claude/.claude/settings.json"
  [ -f "$settings" ] || { warn "settings.json not found (run Stage 1 deploy first)"; return; }
  command -v jq >/dev/null 2>&1 || { warn "jq unavailable: cannot check SessionStart matchers"; return; }
  local heavy='memory-index\.sh|vault-inbox-check\.sh'
  local n i matcher cmds m dedicated=0 heavy_on_compact=0
  n="$(jq '.hooks.SessionStart | length' "$settings" 2>/dev/null)" || n=""
  [ -n "$n" ] || { warn "could not parse SessionStart from settings.json"; return; }
  for ((i=0; i<n; i++)); do
    matcher="$(jq -r ".hooks.SessionStart[$i].matcher // \"\"" "$settings" 2>/dev/null)"
    cmds="$(jq -r ".hooks.SessionStart[$i].hooks[].command" "$settings" 2>/dev/null || true)"
    m=0
    case "$matcher" in
      ""|"*"|".*") m=1 ;;                                       # match-all tokens fire on every source
      *) printf 'compact' | grep -qE "^($matcher)$" 2>/dev/null && m=1 ;;
    esac
    [ "$m" = 1 ] || continue
    case "$matcher" in *compact*|*resume*) dedicated=1 ;; esac
    printf '%s\n' "$cmds" | grep -qE "$heavy" && heavy_on_compact=1
  done
  if [ "$dedicated" = 1 ] && [ "$heavy_on_compact" = 0 ]; then
    ok "SessionStart resume|compact matcher excludes the heavy startup hooks"
  else
    warn "split SessionStart into source-scoped matchers (see DEPLOYMENT.md); heavy startup hooks still run on resume/compact"
  fi
}

# 19. Byte budget on SessionStart hook stdout. Hook stdout above ~8192B is
# truncated by the platform to a ~2KB preview, so a large file printed on
# SessionStart silently loses most of its content (fail loud beats silent loss).
# For every script the live settings.json registers on SessionStart, statically
# resolve its cat/awk file targets under CONTEXT/ or SKILLS/ (direct literals plus
# files behind a printed $VAR) and flag any over 8192B. (The core is not a hook
# payload: it loads as a user rule, which has no such cap; see check 16.)
check_hook_byte_budget() {
  local settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || settings="$HOME/linuxploitacious/claude/.claude/settings.json"
  [ -f "$settings" ] || { warn "settings.json not found: cannot check hook byte budget"; return; }
  command -v jq >/dev/null 2>&1 || { warn "jq unavailable: cannot check hook byte budget"; return; }
  local cmds scripts s base rel target sz fail_hits=""
  local catlines directlit vars v assignlit litset
  cmds="$(jq -r '.hooks.SessionStart[].hooks[].command' "$settings" 2>/dev/null)" \
    || { warn "could not parse SessionStart hooks from settings.json"; return; }
  # Resolve each registered hook script path ($H -> $OPS; absolute paths kept).
  scripts="$(printf '%s\n' "$cmds" \
    | grep -oE '(\$H/[A-Za-z0-9_./-]+|/[A-Za-z0-9_./-]+\.sh)' \
    | sed "s#^\\\$H#$OPS#" | sort -u)"
  for s in $scripts; do
    [ -f "$s" ] || continue
    base="$(basename "$s")"
    catlines="$(grep -nE '(^|[^A-Za-z])(cat|awk)([^A-Za-z]|$)' "$s" 2>/dev/null || true)"
    [ -n "$catlines" ] || continue
    directlit="$(printf '%s\n' "$catlines" | grep -oE '(CONTEXT|SKILLS)/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' || true)"
    vars="$(printf '%s\n' "$catlines" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' | tr -d '${}' | sort -u || true)"
    assignlit=""
    for v in $vars; do
      assignlit="$assignlit
$(grep -E "^[[:space:]]*$v=" "$s" 2>/dev/null | grep -oE '(CONTEXT|SKILLS)/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' || true)"
    done
    litset="$(printf '%s\n%s\n' "$directlit" "$assignlit" | grep -vE '^[[:space:]]*$' | grep -v '\*' | sort -u || true)"
    for rel in $litset; do
      target="$OPS/$rel"
      [ -f "$target" ] || continue
      sz="$(wc -c < "$target" 2>/dev/null | tr -d ' ')"
      [ "${sz:-0}" -gt 8192 ] || continue
      fail_hits="$fail_hits $rel(${sz}B via $base)"
    done
  done
  if [ -n "$fail_hits" ]; then
    fail "SessionStart hook stdout over 8192B budget (truncated to ~2KB preview):$fail_hits"
  else
    ok "SessionStart hook payloads within the 8192B stdout budget"
  fi
}

# 20. Anxiety-vocabulary gate. context-watch.sh is agent-facing: its readout and
# mid-turn/stop nags speak to the model every turn. Context is abundant (P13), so
# those strings must not carry scarcity/pressure vocabulary that reads as "hurry
# up and wrap". The bare informational number stays (ground truth); the pressure
# words go. Comment lines are skipped; the file's code uses none of these words as
# identifiers, so a surviving non-comment hit is always inside an emitted string.
check_anxiety_vocab() {
  local f="$OPS/.claude-config/hooks/context-watch.sh" hits
  [ -f "$f" ] || { warn "context-watch.sh missing: cannot check anxiety vocab"; return; }
  hits="$(grep -nvE '^[[:space:]]*#' "$f" 2>/dev/null \
    | grep -inE 'remain|stranded|impossible|mandatory|runway|hurry|budget|afford|spend|cost|deplet|running out|scarce' || true)"
  [ -z "$hits" ] \
    && ok "context-watch agent strings free of scarcity/pressure vocab" \
    || fail "scarcity/pressure vocab in context-watch agent strings:"$'\n'"$hits"
}

# 21. Identity canary. CONTEXT/USER.md ships as a template carrying the
# `USER-TEMPLATE: unfilled` canary and BOOTSTRAP fills it, so: missing => FAIL
# (the identity layer is gone; a copy from before the core boot has not migrated
# yet); still the template on a bootstrapped copy => FAIL (identity never
# authored); the template on a fresh, un-bootstrapped copy => OK, the shipped
# state. A public template ships zero real facts, so the canary asks "is it
# still the template", not "does it name person X".
check_identity_canary() {
  local u="$OPS/CONTEXT/USER.md"
  if [ ! -f "$u" ]; then
    fail "CONTEXT/USER.md missing: no identity layer (migrate per DEPLOYMENT.md, \"Migrating to the core boot\")"
  elif grep -q 'USER-TEMPLATE: unfilled' "$u" 2>/dev/null; then
    if [ -f "$OPS/CONTEXT/.bootstrapped" ]; then
      fail "USER.md is still the unfilled template on a bootstrapped copy (fill it per BOOTSTRAP.md Stage 1, then remove the canary line)"
    else
      ok "USER.md is the shipped template (fresh copy, not yet bootstrapped)"
    fi
  else
    ok "USER.md is filled (template canary removed)"
  fi
}

# 21b. Retired boot and fleet files gone. The charter, the digests, the old
# doctrine and identity files, and the fleet are replaced by core.md and its set;
# a copy that still carries them has content waiting to move. WARN, because the
# move is the Operator's (their identity lives in some of these files).
OPS_RETIRED_CONTEXT="about-me.md brand-voice.md working-preferences.md boot-digest.md foreman-charter.md worker-digest.md operating-doctrine.md fleet-doctrine.md"
check_retired_context() {
  local f left=""
  for f in $OPS_RETIRED_CONTEXT; do
    [ -e "$OPS/CONTEXT/$f" ] && left="$left CONTEXT/$f"
  done
  [ -e "$OPS/WORKFORCE" ] && left="$left WORKFORCE/"
  [ -z "$left" ] \
    && ok "no retired boot or fleet files left" \
    || warn "retired files still present:$left (move their content per DEPLOYMENT.md, \"Migrating to the core boot\", then delete them)"
}

# 22. Skills mirror in sync. SKILLS/<name> for a vendored row is a mirror of a
# source skill repo under PROJECTS/; skills-vendor.sh --check is the drift gate
# (rc 0 clean, 1 DRIFT = source edit not vendored, 2 MISSING = source repo not
# cloned). DRIFT FAILs; MISSING WARNs (a public template ships zero project repos,
# so the source not being cloned is the normal fresh-fork state).
check_skills_vendored() {
  local sv="$OPS/.claude-config/bin/skills-vendor.sh" out rc
  [ -x "$sv" ] || { warn "skills-vendor.sh missing/not executable"; return; }
  out="$(OPS_DIR="$OPS" "$sv" --check 2>&1)"; rc=$?
  case "$rc" in
    0) ok "skills mirror in sync with source repos" ;;
    1) fail "skills mirror DRIFT (source edit not vendored; run skills-vendor.sh sync):"$'\n'"$(printf '%s' "$out" | grep '^DRIFT' | head -10)" ;;
    2) warn "skills mirror source repo(s) not cloned (run skills-vendor.sh sync after cloning them):"$'\n'"$(printf '%s' "$out" | grep '^MISSING' | head -10)" ;;
    *) warn "skills-vendor.sh --check errored (rc=$rc):"$'\n'"$(printf '%s' "$out" | head -5)" ;;
  esac
}

# 23. Identity exclusion. The files BOOTSTRAP fills with the Operator's identity,
# rulings, people, and systems must never be overwritten by a template refresh,
# and the retired names must never be listed as REMOVED before their content has
# moved, so harness-update-scan.sh's is_excluded() must name every one of them
# (each matched with a trailing | or ) so this greps the case pattern, not a
# comment or the summary echo). A missing name means a sync could clobber a filled
# file or invite deleting one that was never migrated, so FAIL.
OPS_IDENTITY_FILES="USER.md voice.md standing-orders.md .bootstrapped work-tracking.md team.md tools.md about-me.md brand-voice.md working-preferences.md boot-digest.md"
check_identity_exclusion() {
  local scan="$OPS/.claude-config/bin/harness-update-scan.sh" f miss=""
  [ -f "$scan" ] || { fail "harness-update-scan.sh missing"; return; }
  for f in $OPS_IDENTITY_FILES; do
    grep -qE "CONTEXT/${f//./\\.}[|)]" "$scan" || miss="$miss CONTEXT/$f"
  done
  [ -z "$miss" ] \
    && ok "harness-update-scan is_excluded() lists every identity file, current and retired names" \
    || fail "harness-update-scan.sh is_excluded() does not list:$miss (a template sync could clobber a filled file, or list it as REMOVED before its content moved)"
}

main() {
  check_root
  check_root_instructions
  check_readme_tree
  check_changelog
  check_linerefs
  check_citations
  check_memory_indexes
  check_notes_root
  check_secrets
  check_skills_index
  check_projects_map
  check_handoffs
  check_autonomy_settings
  check_ship_gate
  check_model_policy
  check_opus5_ban
  check_retired_model_pins
  check_core_boot
  check_retired_hooks
  check_sessionstart_matchers
  check_hook_byte_budget
  check_anxiety_vocab
  check_identity_canary
  check_retired_context
  check_skills_vendored
  check_identity_exclusion
  echo "verify-ops: $OKS ok · $WARNS warn · $FAILS fail ($(date -Is))"
  [ "$FAILS" -eq 0 ]
}

# Run only when executed, so verify-ops-selftest.sh can source the checks and
# drive them one at a time against a throwaway HOME.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
