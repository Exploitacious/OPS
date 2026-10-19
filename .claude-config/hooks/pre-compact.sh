#!/usr/bin/env bash
# pre-compact.sh: PreCompact hook for Claude Code.
#
# Fires before every auto- or manual-compaction. Reads the PreCompact
# JSON payload on stdin ({trigger, reason, estimated_tokens_removed}).
# Captures the MECHANICAL session state to a durable file under
# $CLAUDE_CONFIG_DIR/projects/<workspace>/pre-compact-<ts>.md (CLAUDE_CONFIG_DIR
# defaults to ~/.claude; a different dir if you run a second profile via that
# env var) so post-compact self-recovery has something to read.
#
# This is the SAFETY-NET layer: fires no matter what, even if the
# user never says "compact". The thoughtful AI synthesis lives in the
# `pre-compact-synthesis` skill (~/OPS/SKILLS/), which Claude
# invokes when the user signals wrap-up.
#
# Implements how-i-work.md P2 ("Compaction is a pause, not death") as
# automation. Pairs with the post-compact-resume.sh SessionStart hook for
# post-compact re-anchoring. (The retired fleet's journal dispatch is gone
# with the fleet.)
#
# Exit semantics (per Claude Code hook spec):
# - Stdout JSON `{"decision": "allow"}` allows the compaction to
#   proceed. We never block; the hook is for record-keeping, not
#   policy.
# - Stderr is shown to the operator if exit code 2; we exit 0 on
#   success and on any internal failure (best-effort: a hook crash
#   must not block the user's /compact).
#
# Branch and worktree GC: the last step starts `branch-gc --apply` for the repo
# holding the cwd, detached, and appends its result line to the snapshot (see
# that section for which repos qualify and why it runs detached).
#
# Diagnostic env vars:
#   PRE_COMPACT_DEBUG=1   verbose logging to stderr
#   PRE_COMPACT_BRANCH_GC=0   skip the branch-gc step

set -uo pipefail
# Note: NO `set -e`: we want partial-success behavior. A failed
# subcommand should log + continue, not abort the whole hook.

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_LOCAL="$(date -Iseconds)"
CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECTS_ROOT="$CLAUDE_CFG/projects"
WORKSPACE_KEY="$(pwd | sed 's|/|-|g')"  # claude encodes cwd this way
SNAPSHOT_DIR="$PROJECTS_ROOT/$WORKSPACE_KEY"
SNAPSHOT_TS="$(date -u +%Y%m%d-%H%M%S)"
SNAPSHOT_FILE="$SNAPSHOT_DIR/pre-compact-${SNAPSHOT_TS}.md"

dbg() {
  [[ "${PRE_COMPACT_DEBUG:-0}" == "1" ]] && printf 'pre-compact: %s\n' "$*" >&2
  return 0
}

# Read the PreCompact JSON payload on stdin (non-blocking: if the
# payload is missing or malformed, treat the hook as a manual probe).
PAYLOAD=""
if [[ ! -t 0 ]]; then
  PAYLOAD="$(cat 2>/dev/null || true)"
fi

# Best-effort payload parse via the portable extractor (jq -> python). The old
# `python3 -c` never ran on Windows Git Bash (no python3 shim), leaving
# TRIGGER/REASON stuck at their defaults. This is telemetry, not a gate:
# degrade quietly when no parser exists.
TRIGGER="unknown"
REASON="-"
EST_TOKENS="-"
AGENT_ID=""
if [[ -n "$PAYLOAD" ]]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hooklib.sh"
  _t="$(printf '%s' "$PAYLOAD" | hook_field trigger)"                   && [[ -n "$_t" ]] && TRIGGER="$_t"
  _r="$(printf '%s' "$PAYLOAD" | hook_field reason)"                    && [[ -n "$_r" ]] && REASON="$(printf '%s' "$_r" | tr '\n' ' ' | cut -c1-200)"
  _e="$(printf '%s' "$PAYLOAD" | hook_field estimated_tokens_removed)"  && [[ -n "$_e" ]] && EST_TOKENS="$_e"
  _a="$(printf '%s' "$PAYLOAD" | hook_field agent_id)"                  && AGENT_ID="$_a"
fi

dbg "trigger=$TRIGGER reason=$REASON est_tokens=$EST_TOKENS"

# ── Local snapshot (always) ─────────────────────────────────────────────
mkdir -p "$SNAPSHOT_DIR" 2>/dev/null || true

# Detect git state. Defensive on the "not in a repo" case.
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
GIT_BRANCH="-"
GIT_AHEAD_BEHIND="-"
GIT_STATUS="(not a git repo)"
GIT_LAST_COMMITS="(not a git repo)"
GIT_DIFFSTAT="(not a git repo)"

if [[ -n "$GIT_ROOT" ]]; then
  GIT_BRANCH="$(git -C "$GIT_ROOT" branch --show-current 2>/dev/null || echo '(detached)')"
  # ahead/behind vs upstream: quietly degrade if no upstream tracked
  GIT_AHEAD_BEHIND="$(git -C "$GIT_ROOT" rev-list --left-right --count '@{upstream}'...HEAD 2>/dev/null | awk '{print "behind="$1" ahead="$2}' || echo '(no upstream)')"
  GIT_STATUS="$(git -C "$GIT_ROOT" status --short 2>/dev/null | head -40 || echo '(unavailable)')"
  [[ -z "$GIT_STATUS" ]] && GIT_STATUS="(clean)"
  GIT_LAST_COMMITS="$(git -C "$GIT_ROOT" log --oneline -10 2>/dev/null || echo '(unavailable)')"
  GIT_DIFFSTAT="$(git -C "$GIT_ROOT" diff --stat HEAD 2>/dev/null | tail -15 || echo '(unavailable)')"
  [[ -z "$GIT_DIFFSTAT" ]] && GIT_DIFFSTAT="(no working-tree changes)"
fi

# Write the snapshot.
{
  echo "# Pre-compact snapshot: $NOW"
  echo ""
  echo "Captured by \`~/OPS/.claude-config/hooks/pre-compact.sh\` (PreCompact hook)."
  echo "Local time: $NOW_LOCAL"
  echo ""
  echo "## Compaction context"
  echo ""
  echo "- trigger: \`$TRIGGER\`"
  echo "- reason: $REASON"
  echo "- estimated_tokens_removed: $EST_TOKENS"
  echo "- cwd: \`$(pwd)\`"
  echo ""
  echo "## Git state"
  echo ""
  echo "- root: \`${GIT_ROOT:-(no repo)}\`"
  echo "- branch: \`$GIT_BRANCH\`"
  echo "- vs upstream: \`$GIT_AHEAD_BEHIND\`"
  echo ""
  echo "### Working tree (\`git status --short\`)"
  echo ""
  echo '```'
  printf '%s\n' "$GIT_STATUS"
  echo '```'
  echo ""
  echo "### Recent commits (\`git log --oneline -10\`)"
  echo ""
  echo '```'
  printf '%s\n' "$GIT_LAST_COMMITS"
  echo '```'
  echo ""
  echo "### Working-tree diffstat (\`git diff --stat HEAD\`)"
  echo ""
  echo '```'
  printf '%s\n' "$GIT_DIFFSTAT"
  echo '```'
  echo ""
  echo "## Post-compact reading order"
  echo ""
  echo "1. This snapshot (you are here)."
  echo "2. \`SESSION_HANDOFF.md\` at the project root if present: the durable narrative anchor."
  echo "3. \`MEMORY.md\` under \`$CLAUDE_CFG/projects/<workspace>/memory/\`: saved lessons."
  echo "4. \`git log --oneline -20\` if more context is needed."
  echo ""
  echo "Per how-i-work.md P2 (Compaction is a pause, not death):"
  echo "continuity is not a handoff to a new entity: it is self-recovery via durable storage."
} > "$SNAPSHOT_FILE" 2>/dev/null

dbg "snapshot written: $SNAPSHOT_FILE"

# ── Session work-log (feeds the session-close reconciliation gate) ──────────
# Append a compact-time segment so a multi-compact session's full activity is
# reconstructable at CLOSE for time entry. This is the MECHANICAL spine (git
# delta + elapsed since session start); the pre-compact-synthesis skill adds a
# narrative line separately. Best-effort: a failure here never blocks the
# compact. NOTE: this only records; it never reconciles. WIP/work-tracking
# reconciliation is a session-CLOSE act (session-close skill), never a compact.
command -v work_session_key >/dev/null 2>&1 \
  || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hooklib.sh" 2>/dev/null || true
WORK_KEY="$(work_session_key 2>/dev/null || true)"
if [[ -n "$WORK_KEY" ]]; then
  RUNDIR="$HOME/.claude-compact-cycle"
  mkdir -p "$RUNDIR" 2>/dev/null || true
  WORKLOG="$RUNDIR/work-log-$WORK_KEY"
  START_STAMP="$RUNDIR/session-start-$WORK_KEY"
  STARTED="-"; ELAPSED="-"
  if [[ -f "$START_STAMP" ]]; then
    STARTED="$(grep -m1 '^started_at=' "$START_STAMP" 2>/dev/null | cut -d= -f2-)"
    if [[ -n "$STARTED" ]]; then
      _s0="$(date -d "$STARTED" +%s 2>/dev/null || echo 0)"
      if [[ "$_s0" -gt 0 ]]; then
        _d=$(( $(date +%s) - _s0 )); (( _d < 0 )) && _d=0
        ELAPSED="$(printf '%dh%02dm' $(( _d/3600 )) $(( (_d%3600)/60 )))"
      fi
    fi
  fi
  {
    echo "## segment $NOW_LOCAL: trigger=$TRIGGER elapsed=$ELAPSED"
    echo "repo=${GIT_ROOT:--} branch=$GIT_BRANCH cwd=$(pwd)"
    echo "recent_commits:"
    printf '%s\n' "$GIT_LAST_COMMITS" | sed 's/^/  /'
    echo "diffstat:"
    printf '%s\n' "$GIT_DIFFSTAT" | sed 's/^/  /'
    echo ""
  } >> "$WORKLOG" 2>/dev/null || true
  # Cap the log so a pause-forever session can't grow it unbounded (mirrors the
  # snapshot retention below). Newest ~500 lines is many segments' worth.
  wl_lines="$(wc -l < "$WORKLOG" 2>/dev/null || echo 0)"
  if [[ "${wl_lines:-0}" -gt 500 ]]; then
    tail -n 500 "$WORKLOG" > "$WORKLOG.tmp" 2>/dev/null && mv "$WORKLOG.tmp" "$WORKLOG" 2>/dev/null || rm -f "$WORKLOG.tmp" 2>/dev/null
  fi
  dbg "work-log segment appended: $WORKLOG"
fi

# ── Retention ───────────────────────────────────────────────────────────
# Long-running workspaces accumulate one snapshot per compaction
# forever. Cap at the newest N so the projects dir doesn't grow
# unbounded across weeks of use. Newest 10 is plenty for any sane
# recovery scenario: the resume hook only reads the latest.
RETENTION_KEEP="${PRE_COMPACT_RETENTION:-10}"
if [[ "$RETENTION_KEEP" =~ ^[0-9]+$ ]] && (( RETENTION_KEEP > 0 )); then
  # Sort by mtime, skip the newest N, delete the rest. Defensive on
  # the no-match case (ls returns nothing → tail returns nothing →
  # xargs is a no-op).
  ls -1t "$SNAPSHOT_DIR"/pre-compact-*.md 2>/dev/null \
    | tail -n +$((RETENTION_KEEP + 1)) \
    | xargs -r rm -f 2>/dev/null || true
  dbg "retention applied (keep=$RETENTION_KEEP)"
fi

# ── Branch and worktree GC ──────────────────────────────────────────────
# Closeout and pre-compaction run `branch-gc --apply` on the repos the session
# touched (CONTEXT/core.md, Rhythm); this is the pre-compaction half, for the
# repo holding the cwd. It runs detached under a timeout, so the compact never
# waits on GitHub or git, and appends one result line to this snapshot when it
# finishes. Only repos branch-gc manages by default qualify (~/OPS,
# ~/linuxploitacious, ~/OPS/PROJECTS/*/*, compared by realpath under the
# CURRENT $HOME) with a github.com origin: a test harness that points HOME at a
# fixture must never reach a real repo with a fixture trash and no T3 state.
# Everything that can remove anything is branch-gc's own fail-closed checks;
# worktrees go to its 7-day trash. A payload carrying agent_id is a sub-agent
# lane's compaction, not the session's, so it is skipped: a lane that compacts
# every few minutes must not start a sweep each time. Known limit: some Claude
# Code builds send a lane's PreCompact without agent_id (with the parent's
# session id and cwd), so such a compaction still starts a run; branch-gc's own
# skip window (BRANCH_GC_SKIP_SECONDS, 600 s on unchanged refs) then turns the
# repeats into a cheap no-op.
#
# The timeout. A kill can land inside a quarantine (the worktree moved, its
# manifest not yet written) or inside a deletion, so the worker passes branch-gc
# a soft deadline at two thirds of the hard timeout (600 s of 900 s), including
# discovery. branch-gc stops before the next branch once it passes, never
# inside one, and the hard kill is left for a hang; the KILL waits 30 s after
# the TERM so its traps can drop their locks on a loaded box. The worker passes
# BRANCH_GC_TRASH_DAYS=0: the trash is shared across repos, and purging it is
# the nightly sweep's job (backup/daily-sync.sh), not this hook's.
# PRE_COMPACT_BRANCH_GC=0 turns this off; PRE_COMPACT_BRANCH_GC_BIN,
# PRE_COMPACT_BRANCH_GC_TIMEOUT and PRE_COMPACT_BRANCH_GC_KILL_AFTER exist for tests.
command -v hook_timeout >/dev/null 2>&1 \
  || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hooklib.sh" 2>/dev/null || true
bgc_note() { printf -- '- branch-gc (pre-compact): %s\n' "$*" 2>/dev/null >> "$SNAPSHOT_FILE" || true; }
if [[ "${PRE_COMPACT_BRANCH_GC:-1}" != "0" && -n "$GIT_ROOT" && -z "$AGENT_ID" ]]; then
  BGC_BIN="${PRE_COMPACT_BRANCH_GC_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" 2>/dev/null && pwd)/branch-gc}"
  BGC_TIMEOUT="${PRE_COMPACT_BRANCH_GC_TIMEOUT:-900}"
  BGC_KILL_AFTER="${PRE_COMPACT_BRANCH_GC_KILL_AFTER:-30}"
  BGC_TO="$(hook_timeout 2>/dev/null)" || BGC_TO=""
  if [[ ! -x "$BGC_BIN" ]] || [[ -z "$BGC_TO" ]] \
      || ! command -v python3 >/dev/null 2>&1 || ! [[ "$BGC_TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
      || ! [[ "$BGC_KILL_AFTER" =~ ^[1-9][0-9]*$ ]]; then
    bgc_note "not run: branch-gc, timeout, python3, or a positive timeout is missing"
  else
    # Discovery can block too (a disconnected worktree volume, say): every new
    # git query stays inside the detached worker's timeout.
    _bgc_worker='
      IFS= read -r -d "" first < <(git -C "$2" worktree list --porcelain -z 2>/dev/null)
      case "$first" in "worktree "*) main="${first#worktree }" ;; *) echo "not run: cannot resolve main worktree"; exit 0 ;; esac
      main="$(realpath -e -- "$main" 2>/dev/null)" || exit 1
      managed_home="$(realpath -e -- "$HOME" 2>/dev/null)" || exit 1
      managed=0
      case "$main" in
        "$managed_home/OPS"|"$managed_home/linuxploitacious") managed=1 ;;
        "$managed_home/OPS/PROJECTS/"*/*)
          rest="${main#"$managed_home/OPS/PROJECTS/"}"
          [[ "$rest" != */*/* ]] && managed=1 ;;
      esac
      if [[ "$managed" != 1 ]]; then
        echo "not run: $main is not a repo branch-gc manages"; exit 0
      fi
      origin="$(git -C "$main" config --get-all remote.origin.url 2>/dev/null)" || origin=""
      case "$origin" in
        git@github.com:*) path="${origin#git@github.com:}" ;;
        ssh://git@github.com/*) path="${origin#ssh://git@github.com/}" ;;
        https://github.com/*) path="${origin#https://github.com/}" ;;
        *) path="" ;;
      esac
      path="${path%.git}"
      if ! [[ "$path" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        echo "not run: $main has no github.com origin (or multiple origins)"; exit 0
      fi
      printf -- "--apply %s: " "$main"
      out="$(BRANCH_GC_TRASH_DAYS=0 BRANCH_GC_DEADLINE="$3" "$1" --apply "$main" 2>&1)"; rc=$?
      sum="$(printf "%s\n" "$out" | awk "/^Summary/ {f=1; next} f && NF {\$1=\$1; print; exit}")"
      printf "exit %s; %s (log ~/.local/state/ops/branch-gc.log)\n" "$rc" "${sum:-no summary}"
    '
    _bgc_supervisor='
      # Start both clocks together: slow discovery must not move the soft stop
      # beyond the hard timeout and let another quarantine start there.
      deadline=$(( $(date +%s) + $3 * 2 / 3 ))
      out="$("$6" -k "$7" "$3" bash -c "$5" branch-gc-worker "$1" "$2" "$deadline" 2>&1)"; rc=$?
      case "$rc" in
        0) ;;
        124|137) out="${out:-discovery: }timed out after ${3}s; no summary" ;;
        *) out="${out:-discovery: }exit $rc" ;;
      esac
      # Resume picks snapshots by mtime. A late result must not promote an
      # older snapshot, or recreate one that retention already removed.
      python3 - "$4" "$out" <<"PY_NOTE"
import os, sys
try:
    fd = os.open(sys.argv[1], os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
except FileNotFoundError:
    raise SystemExit(0)
with os.fdopen(fd, "a") as snapshot:
    before = os.fstat(snapshot.fileno())
    snapshot.write("- branch-gc (pre-compact): " + sys.argv[2].replace("\n", " ") + "\n")
    snapshot.flush()
    os.utime(snapshot.fileno(), ns=(before.st_atime_ns, before.st_mtime_ns))
PY_NOTE
    '
    if command -v setsid >/dev/null 2>&1; then
      setsid -f bash -c "$_bgc_supervisor" branch-gc-supervisor "$BGC_BIN" "$GIT_ROOT" "$BGC_TIMEOUT" "$SNAPSHOT_FILE" "$_bgc_worker" "$BGC_TO" "$BGC_KILL_AFTER" \
        </dev/null >/dev/null 2>&1 || bgc_note "could not start"
    else
      ( bash -c "$_bgc_supervisor" branch-gc-supervisor "$BGC_BIN" "$GIT_ROOT" "$BGC_TIMEOUT" "$SNAPSHOT_FILE" "$_bgc_worker" "$BGC_TO" "$BGC_KILL_AFTER" \
          </dev/null >/dev/null 2>&1 & ) || bgc_note "could not start"
    fi
    dbg "branch-gc started in the background for $GIT_ROOT"
  fi
fi

# Always allow the compaction. The hook is record-keeping, never policy.
# Per the Claude Code hook schema, PreCompact has no documented
# "allow" channel: `decision` only accepts "approve"|"block", and
# the canonical pass-through is to exit 0 with no JSON. Empty exit
# lets Claude Code proceed with the compaction.
exit 0
