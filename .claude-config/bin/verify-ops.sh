#!/usr/bin/env bash
# verify-ops.sh — the OPS drift gate. Machine-checks the conventions that used
# to live only in prose (conventions are lint-enforced, not documented-and-hoped:
# a rule a machine cannot check is a rule that silently rots).
#
# Usage:
#   verify-ops.sh            full report (OK/WARN/FAIL per check)
#   verify-ops.sh --quiet    print only WARN/FAIL lines (for hooks/timers)
#
# Exit: 0 = no FAILs (WARNs allowed) · 1 = at least one FAIL
#
# Consumers: the pre-compact-synthesis closeout stage runs it before wrap-up;
# a nightly systemd --user timer (ops-verify) writes its output to
# ~/.local/state/ops/verify-last.txt which session-briefing.sh surfaces.
# Add new checks as functions + a line in main; keep each check independent.
set -uo pipefail

OPS="$HOME/OPS"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
FAILS=0
WARNS=0
OKS=0

ok()   { OKS=$((OKS+1)); [ "$QUIET" = 1 ] || echo "OK:   $*"; }
warn() { WARNS=$((WARNS+1)); echo "WARN: $*"; }
fail() { FAILS=$((FAILS+1)); echo "FAIL: $*"; }

# 1. Root canonical files only (project-kata rule 1). LICENSE + BOOTSTRAP.md are
# canonical for this public template — the repo must carry a license, and
# BOOTSTRAP.md is the first-launch entry point CLAUDE.md's startup gate reads.
# GENERALIZATION-RULES.md is deliberately absent from this list: it is a build
# marker and must fail here until it is removed (see check_ship_gate).
check_root() {
  local allowed="README.md CLAUDE.md CHANGELOG.md IDEAS.md DEPLOYMENT.md BOOTSTRAP.md LICENSE CONTRIBUTING.md"
  local extras=""
  for f in "$OPS"/*; do
    [ -f "$f" ] || continue
    local b; b="$(basename "$f")"
    case " $allowed " in *" $b "*) ;; *) case "$b" in .*) ;; *) extras="$extras $b";; esac;; esac
  done
  [ -z "$extras" ] && ok "root holds only canonical files" || fail "non-canonical files at OPS root:$extras"
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
  doc_commits="$(git -C "$OPS" log --since='24 hours ago' --oneline -- CONTEXT/ CLAUDE.md README.md DEPLOYMENT.md .claude-config/ SKILLS/ 2>/dev/null | wc -l)"
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
    "$OPS/CLAUDE.md" "$OPS/README.md" "$OPS/DEPLOYMENT.md" \
    "$OPS"/CONTEXT/*.md "$OPS"/SKILLS/*/SKILL.md "$OPS"/WORKFORCE/README.md \
    "$OPS"/WORKFORCE/personalities/*.md "$OPS"/WORKFORCE/protocol/*.md 2>/dev/null | grep -v 'verify-ops' | grep -v '"~line' | head -20)" || true
  [ -z "$hits" ] && ok "no line-number refs in core docs" || warn "line-number refs in core docs (cite sections, not lines):"$'\n'"$hits"
}

# 5. Doctrine citation range: 'Principle N' / bare 'P<N>' must exist in operating-doctrine.
check_citations() {
  local max n bad=""
  max="$(grep -cE '^### [0-9]+\.' "$OPS/CONTEXT/operating-doctrine.md" 2>/dev/null || echo 0)"
  [ "$max" -gt 0 ] || { warn "could not count principles in operating-doctrine.md"; return; }
  while IFS= read -r n; do
    [ -n "$n" ] && [ "$n" -gt "$max" ] && bad="$bad P$n"
  done < <(grep -rhoE '([Pp]rinciple |P)[0-9]+' \
      "$OPS/CLAUDE.md" "$OPS"/CONTEXT/*.md "$OPS"/WORKFORCE/personalities/*.md \
      "$OPS"/WORKFORCE/protocol/*.md "$OPS"/SKILLS/*/SKILL.md 2>/dev/null \
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
  [ -z "$over" ] && ok "all memory indexes under 24KB" || warn "memory index over 24KB limit (entries truncate — run /memory-prune):$over"
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
# Iterate whatever org clusters exist rather than hardcoding names — a public
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
# denylist used to extract this template from the Operator's private harness —
# it names identities that must never ship, so its presence at ship time is a
# hard FAIL.
check_ship_gate() {
  local bad=""
  [ -f "$OPS/README.md" ] || bad="$bad README.md-missing"
  [ -f "$OPS/GENERALIZATION-RULES.md" ] && bad="$bad GENERALIZATION-RULES.md-present(build-marker-must-not-ship)"
  [ -z "$bad" ] && ok "ship gate: README present, no build markers" || fail "ship gate:$bad"
}

# 14. Model policy. Two rules, two severities. FAIL: no real haiku model id may
# be the VALUE of a model key — haiku is banned harness-wide, and one haiku
# value silently downgrades every lane that resolves through that key. Only
# values are inspected, never key names: ANTHROPIC_DEFAULT_HAIKU_MODEL is a
# deliberate tripwire that must keep pointing at a non-haiku model, so the key
# existing is the healthy state. WARN: the session pin should be one of the two
# foreman tiers model-probe.sh manages, but an Operator may pin something else
# on purpose, so a different pin is a nudge and not a gate. Same deployed-then-
# stage-1 settings fallback as check_autonomy_settings.
check_model_policy() {
  local settings="$HOME/.claude/settings.json" haiku pin
  [ -f "$settings" ] || settings="$HOME/linuxploitacious/claude/.claude/settings.json"
  [ -f "$settings" ] || { warn "settings.json not found (run Stage 1 deploy first)"; return; }
  haiku="$(grep -oE '"(ANTHROPIC_DEFAULT_[A-Z0-9_]+_MODEL|model)"[[:space:]]*:[[:space:]]*"[^"]*"' "$settings" \
    | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"(.*)"$/\1/' | grep -i haiku | tr '\n' ' ')"
  # Anchored at top-level indentation so a nested "model" in someone's custom
  # config cannot be mistaken for the session pin. No match = no WARN: a file
  # formatted differently is not evidence of a bad pin.
  pin="$(grep -oE '^  "model"[[:space:]]*:[[:space:]]*"[^"]*"' "$settings" | head -1 \
    | sed -E 's/^.*"([^"]*)"$/\1/')"
  if [ -n "$haiku" ]; then
    fail "haiku model id(s) in settings.json (haiku is banned harness-wide): $haiku"
  elif [ -n "$pin" ] && [ "$pin" != "claude-fable-5[1m]" ] && [ "$pin" != "claude-opus-4-8[1m]" ]; then
    warn "session pin \"$pin\" is not a managed foreman tier (model-probe.sh sets claude-fable-5[1m] or claude-opus-4-8[1m])"
  else
    ok "model policy: pin + haiku tripwire sane"
  fi
}

# 15. Opus 5 ban (Operator directive 2026-08-20). Opus 4.8 is the default
# build/review/audit worker; claude-opus-5 is banned harness-wide the same way
# haiku is, because as a fan-out worker it burned disproportionate cache-write
# and round-trips for no quality edge. Enforced here rather than trusted to
# prose: a stale pin is invisible until it has already spent the budget.
# Scoped to SPAWN PINS only — agent frontmatter, Workflow lane objects, and the
# settings the gate already resolves — so the doctrine's own ban text (which
# must name the banned id to be readable) never trips its own gate.
check_opus5_ban() {
  local hits settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || settings="$HOME/linuxploitacious/claude/.claude/settings.json"
  hits="$(grep -rnE "model:[[:space:]]*['\"]?claude-opus-5" \
    "$OPS/.claude-config/agents" "$OPS/.claude-config/workflows" 2>/dev/null)"
  if [ -f "$settings" ] && grep -qE 'claude-opus-5' "$settings" 2>/dev/null; then
    hits="$hits"$'\n'"settings.json references claude-opus-5"
  fi
  hits="$(printf '%s' "$hits" | sed '/^$/d')"
  if [ -z "$hits" ]; then
    ok "no claude-opus-5 spawn pins (Opus 5 ban intact)"
  else
    fail "claude-opus-5 is BANNED but still pinned (repin to claude-opus-4-8[1m]):"$'\n'"$hits"
  fi
}

# 16. Boot shim (native-first boot). The claude() launch shim in deploy.sh must
# ride the foreman charter + identity boot-digest in the CACHED system prompt via
# --append-system-prompt, pinned with --system-prompt-snapshot on so the standing
# orders LAND every launch and survive resume/compact verbatim without a
# SessionStart hook re-forcing the reads. A missing source or flag silently
# degrades the boot surface, so this FAILs. OPS ships no operating-model body, so
# the append is two files, charter + digest.
check_boot_shim() {
  local dep="$OPS/.claude-config/deploy.sh" miss=""
  [ -f "$dep" ] || { fail "deploy.sh missing — cannot verify boot shim"; return; }
  grep -qF -- '--append-system-prompt'      "$dep" || miss="$miss --append-system-prompt"
  grep -qF 'foreman-charter.md'             "$dep" || miss="$miss foreman-charter.md"
  grep -qF 'boot-digest.md'                 "$dep" || miss="$miss boot-digest.md"
  grep -qF -- '--system-prompt-snapshot on' "$dep" || miss="$miss --system-prompt-snapshot-on"
  [ -z "$miss" ] \
    && ok "deploy.sh claude() shim rides charter+digest in the cached system prompt" \
    || fail "deploy.sh boot shim missing:$miss"
}

# 17. Charter hook retired (double-inject guard). The charter rides the launch
# shim (check 16), so foreman-charter.sh must be unregistered from the live
# settings.json SessionStart block; leaving it there re-emits the whole charter
# through truncated hook stdout AND duplicates what the system prompt carries.
# settings.json is Stage-1-owned, so this WARNs (remove it) until the forker
# does, never FAILs.
check_charter_hook_retired() {
  local settings="$HOME/.claude/settings.json" hit=""
  [ -f "$settings" ] || settings="$HOME/linuxploitacious/claude/.claude/settings.json"
  [ -f "$settings" ] || { warn "settings.json not found (run Stage 1 deploy first)"; return; }
  if command -v jq >/dev/null 2>&1; then
    jq -r '.hooks.SessionStart[].hooks[].command' "$settings" 2>/dev/null \
      | grep -q 'foreman-charter\.sh' && hit=1
  else
    grep -q 'foreman-charter\.sh' "$settings" 2>/dev/null && hit=1
  fi
  [ -z "$hit" ] \
    && ok "foreman-charter.sh unregistered from SessionStart (charter rides the launch shim)" \
    || warn "remove foreman-charter.sh from the SessionStart matcher (charter rides the launch shim); see DEPLOYMENT.md"
}

# 18. Source-scoped SessionStart matchers. A resume/compact must stop re-paying
# the full boot: the split adds a "resume|compact" matcher whose command list
# excludes the heavy startup-only hooks (memory-index, session-work-init). Tests
# the semantics — collects the command list of every group whose matcher fires on
# source=compact and confirms none reference a heavy hook, and that a dedicated
# resume/compact matcher exists. Config-dependent: WARNs until the split lands.
check_sessionstart_matchers() {
  local settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || settings="$HOME/linuxploitacious/claude/.claude/settings.json"
  [ -f "$settings" ] || { warn "settings.json not found (run Stage 1 deploy first)"; return; }
  command -v jq >/dev/null 2>&1 || { warn "jq unavailable — cannot check SessionStart matchers"; return; }
  local heavy='memory-index\.sh|session-work-init\.sh'
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
# SessionStart silently loses most of its content — fail-loud-beats-silent-loss.
# For every script the live settings.json registers on SessionStart, statically
# resolve its cat/awk file targets under CONTEXT/ or SKILLS/ (direct literals plus
# files behind a printed $VAR) and flag any over 8192B. foreman-charter.sh is
# removed from SessionStart by the matcher split, so an oversized target reached
# only through it WARNs (do the split) instead of FAILing.
check_hook_byte_budget() {
  local settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || settings="$HOME/linuxploitacious/claude/.claude/settings.json"
  [ -f "$settings" ] || { warn "settings.json not found — cannot check hook byte budget"; return; }
  command -v jq >/dev/null 2>&1 || { warn "jq unavailable — cannot check hook byte budget"; return; }
  local patch_removes=" foreman-charter.sh "
  local cmds scripts s base is_removed rel target sz fail_hits="" warn_hits=""
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
    case "$patch_removes" in *" $base "*) is_removed=1 ;; *) is_removed=0 ;; esac
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
      if [ "$is_removed" = 1 ]; then
        warn_hits="$warn_hits $rel(${sz}B via $base)"
      else
        fail_hits="$fail_hits $rel(${sz}B via $base)"
      fi
    done
  done
  if [ -n "$fail_hits" ]; then
    fail "SessionStart hook stdout over 8192B budget (truncated to ~2KB preview):$fail_hits"
  elif [ -n "$warn_hits" ]; then
    warn "oversized SessionStart payload still on stdout (do the matcher split):$warn_hits"
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
  [ -f "$f" ] || { warn "context-watch.sh missing — cannot check anxiety vocab"; return; }
  hits="$(grep -nvE '^[[:space:]]*#' "$f" 2>/dev/null \
    | grep -inE 'remain|stranded|impossible|mandatory|runway|hurry|budget|afford|spend|cost|deplet|running out|scarce' || true)"
  [ -z "$hits" ] \
    && ok "context-watch agent strings free of scarcity/pressure vocab" \
    || fail "scarcity/pressure vocab in context-watch agent strings:"$'\n'"$hits"
}

# 21. Identity-digest canary, generalized. CONTEXT/boot-digest.md is the cold-
# start alignment surface the boot shim appends. It ships as a slot TEMPLATE and
# BOOTSTRAP fills it, so: missing => FAIL (the shim has nothing to append); still
# the unfilled template on a bootstrapped copy => FAIL (identity never authored);
# unfilled on a fresh (un-bootstrapped) copy => OK, that is the shipped state.
# Generalized from the private harness's fixed-fact canary: a public template
# ships zero real facts, so the canary is "is it still the template", not "does it
# name person X".
check_digest_canary() {
  local dg="$OPS/CONTEXT/boot-digest.md"
  [ -f "$dg" ] || { fail "CONTEXT/boot-digest.md missing (the identity surface the boot shim appends)"; return; }
  if grep -q 'BOOT-DIGEST-TEMPLATE: unfilled' "$dg" 2>/dev/null; then
    if [ -f "$OPS/CONTEXT/.bootstrapped" ]; then
      fail "boot-digest.md is still the unfilled template on a bootstrapped copy (author it from the slot guidance, then remove the canary line)"
    else
      ok "boot-digest.md is the shipped template (fresh copy, not yet bootstrapped)"
    fi
  else
    ok "boot-digest.md is filled (template canary removed)"
  fi
}

# 22. Skills mirror in sync. SKILLS/<name> for a vendored row is a mirror of a
# source skill repo under PROJECTS/; skills-vendor.sh --check is the drift gate
# (rc 0 clean, 1 DRIFT = source edit not vendored, 2 MISSING = source repo not
# cloned). DRIFT FAILs; MISSING WARNs (a public template ships zero project repos,
# so the source not being cloned is the normal fresh-fork state).
check_skills_vendored() {
  local sv="$OPS/.claude-config/bin/skills-vendor.sh" out rc
  [ -x "$sv" ] || { warn "skills-vendor.sh missing/not executable"; return; }
  out="$("$sv" --check 2>&1)"; rc=$?
  case "$rc" in
    0) ok "skills mirror in sync with source repos" ;;
    1) fail "skills mirror DRIFT (source edit not vendored — run skills-vendor.sh sync):"$'\n'"$(printf '%s' "$out" | grep '^DRIFT' | head -10)" ;;
    2) warn "skills mirror source repo(s) not cloned (run skills-vendor.sh sync after cloning them):"$'\n'"$(printf '%s' "$out" | grep '^MISSING' | head -10)" ;;
    *) warn "skills-vendor.sh --check errored (rc=$rc):"$'\n'"$(printf '%s' "$out" | head -5)" ;;
  esac
}

# 23. Digest identity-exclusion. boot-digest.md is the Operator's identity
# surface; a template refresh via harness-update must NEVER clobber a filled copy,
# so harness-update-scan.sh's is_excluded() must name CONTEXT/boot-digest.md
# (matched by a trailing | or ) so this greps the case pattern, not a comment or
# the summary echo). Missing => the filled digest could be overwritten on a sync,
# so FAIL.
check_digest_exclusion() {
  local scan="$OPS/.claude-config/bin/harness-update-scan.sh"
  [ -f "$scan" ] || { fail "harness-update-scan.sh missing"; return; }
  grep -qE 'CONTEXT/boot-digest\.md[|)]' "$scan" \
    && ok "harness-update-scan is_excluded() lists CONTEXT/boot-digest.md (identity guard)" \
    || fail "harness-update-scan.sh is_excluded() does not list CONTEXT/boot-digest.md (a template sync could clobber the filled digest)"
}

main() {
  check_root
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
  check_boot_shim
  check_charter_hook_retired
  check_sessionstart_matchers
  check_hook_byte_budget
  check_anxiety_vocab
  check_digest_canary
  check_skills_vendored
  check_digest_exclusion
  echo "verify-ops: $OKS ok · $WARNS warn · $FAILS fail ($(date -Is))"
  [ "$FAILS" -eq 0 ]
}
main
