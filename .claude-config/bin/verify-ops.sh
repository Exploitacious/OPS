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
  echo "verify-ops: $OKS ok · $WARNS warn · $FAILS fail ($(date -Is))"
  [ "$FAILS" -eq 0 ]
}
main
