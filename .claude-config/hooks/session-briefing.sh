#!/usr/bin/env bash
# session-briefing.sh — SessionStart briefing dashboard.
#
# Orients the operator the moment a session boots: the default worker model
# tier, the config posture (compaction / effort / model), the project-lessons
# pointer, the last pre-compact snapshot for this project, plus reminders +
# a memory-health nudge.
#
# COMPLEMENTARY to handoff-check.sh: that hook prints the pending-handoff
# banner (project-keyed); this one does NOT repeat it. Together they are the
# boot briefing. Read-only; exit 0 always (a surface, not a gate). If you run
# more than one profile via CLAUDE_CONFIG_DIR, this fires in each of them
# (settings.json is symlinked into every config dir).
#
# MUST stay quiet-when-empty: only the posture header is unconditional;
# reminders / snapshot / memory lines print only when they have something to
# say, so the banner never becomes noise the operator learns to ignore.
set -uo pipefail

OPS_DIR="${OPS_DIR:-$HOME/OPS}"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CFG/settings.json"
ENCODED_CWD="$(pwd | sed 's|/|-|g')"

# --- worker posture ---
gate="Sonnet 5 1M default worker"

# --- config posture (parse flat keys from the resolved settings.json) ---
val() { grep -iE "\"$1\"[[:space:]]*:" "$SETTINGS" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*//; s/[",]//g; s/[[:space:]]*$//'; }
ac="$(val autoCompactEnabled)"; if [ "$ac" = "false" ]; then acs="OFF (manual /compact)"; else acs="ON"; fi
eff="$(val effortLevel)"; [ -n "$eff" ] || eff="default"
model="${ANTHROPIC_DEFAULT_OPUS_MODEL:-default}"

printf '============================================================\n'
printf ' SESSION BRIEFING\n'
printf '============================================================\n'
printf ' Worker:  %s\n' "$gate"
printf ' Config:  autocompact %s  ·  effort %s  ·  opus=%s\n' "$acs" "$eff" "$model"
printf ' Ultra:   ultracode is session-set via the alias (--settings); /effort to change\n'

# --- project lessons pointer (two-tier memory: project knowledge lives on-demand here) ---
LESSONS_DIR="$OPS_DIR/CONTEXT/projects"
case "$(pwd)" in
  */OPS/PROJECTS/*)
    if ls "$LESSONS_DIR"/*-lessons.md >/dev/null 2>&1; then
      nles="$(ls -1 "$LESSONS_DIR"/*-lessons.md 2>/dev/null | wc -l | tr -d ' ')"
      printf ' Lessons: project knowledge in CONTEXT/projects/*-lessons.md (%s files) — read the one for this project\n' "$nles"
    fi
    ;;
esac

# --- last pre-compact snapshot for this project (handoff banner is handoff-check.sh's job) ---
SNAP_DIR="$CFG/projects/$ENCODED_CWD"
if ls "$SNAP_DIR"/pre-compact-*.md >/dev/null 2>&1; then
  latest="$(ls -1t "$SNAP_DIR"/pre-compact-*.md 2>/dev/null | head -1)"
  ts="$(basename "$latest" 2>/dev/null | sed -E 's/^pre-compact-(.*)\.md$/\1/')"
  printf ' Snapshot: last pre-compact for this project @ %s\n' "$ts"
fi

# --- reminders (operator drops notes into this file; lines starting with # are headers) ---
REM="$OPS_DIR/.claude-reminders.md"
if [ -s "$REM" ]; then
  rems="$(grep -vE '^[[:space:]]*(#|$)' "$REM" 2>/dev/null | head -5)"
  if [ -n "$rems" ]; then
    printf ' Reminders:\n'
    printf '%s\n' "$rems" | sed 's/^/   - /'
  fi
fi

# --- memory health (nudge until the index is back under the binary's limit) ---
MEM="$CFG/projects/$ENCODED_CWD/memory/MEMORY.md"
if [ -f "$MEM" ]; then
  sz="$(wc -c < "$MEM" 2>/dev/null | tr -d ' ')"
  if [ "${sz:-0}" -gt 24576 ]; then
    printf ' Memory:  index ~%sKB > 24KB limit (entries truncated) — run /memory-prune\n' "$(( ${sz:-0} / 1024 ))"
  fi
fi

# --- hygiene (quiet-when-clean): dirty repos, drift-gate state, closeout age ---
STATE_DIR="$HOME/.local/state/ops"
hyg=""
for repo in "$OPS_DIR" "$HOME/linuxploitacious"; do
  [ -d "$repo/.git" ] || continue
  n="$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  [ "${n:-0}" -gt 0 ] && hyg="$hyg $(basename "$repo") dirty($n) ·"
done
VLAST="$STATE_DIR/verify-last.txt"
if [ -f "$VLAST" ]; then
  vline="$(tail -1 "$VLAST" 2>/dev/null)"
  case "$vline" in
    *" 0 fail"*) ;;  # clean gate stays quiet
    *fail*) hyg="$hyg drift-gate: ${vline#verify-ops: } ·" ;;
  esac
fi
CLOSE="$STATE_DIR/last-closeout"
if [ -f "$CLOSE" ]; then
  age_days="$(( ( $(date +%s) - $(date -d "$(cat "$CLOSE")" +%s 2>/dev/null || echo 0) ) / 86400 ))"
  [ "${age_days:-0}" -ge 3 ] && hyg="$hyg last closeout ${age_days}d ago ·"
fi
# unadopted memory pools: real dirs (not symlinks) mean git-sync misses them
for md in "$CFG"/projects/*/memory; do
  [ -d "$md" ] && [ ! -L "$md" ] && hyg="$hyg unadopted memory pool ($(basename "$(dirname "$md")")) — run ac-memory-init ·" && break
done
if [ -n "$hyg" ]; then
  printf ' Hygiene:%s\n' "${hyg% ·}"
fi
printf '============================================================\n'
exit 0
