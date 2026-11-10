#!/usr/bin/env bash
# session-briefing.sh: SessionStart briefing dashboard.
#
# Orients the operator the moment a session boots: the default worker model
# tier, the config posture (compaction / effort / model), the project-lessons
# pointer, the last pre-compact snapshot for this project, plus reminders,
# the asks waiting on this owner (only where a team-ask router is installed),
# a memory-health nudge, and the last nightly backup's problems, if any.
#
# COMPLEMENTARY to handoff-check.sh: that hook prints the pending-handoff
# banner (project-keyed); this one does NOT repeat it. Together they are the
# boot briefing. Read-only; exit 0 always (a surface, not a gate). If you run
# more than one profile via CLAUDE_CONFIG_DIR, this fires in each of them
# (settings.json is symlinked into every config dir).
#
# MUST stay quiet-when-empty: only the posture header is unconditional;
# reminders / snapshot / repo / memory lines print only when they have something to
# say, so the banner never becomes noise the operator learns to ignore. A line also
# stays off what nothing can act on (a throwaway or empty memory pool is not named as
# unadopted), and a lane gets one line instead of the briefing (see the lane gate).
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/hooklib.sh"

OPS_DIR="${OPS_DIR:-$HOME/OPS}"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CFG/settings.json"

# Encoded cwd: prefer Claude's OWN encoded path from transcript_path in the
# SessionStart payload (basename of its parent dir). The `pwd | sed` form is
# `-c-Users-...` on Windows Git Bash, never matching Claude's native
# `C--Users-...`, which left SNAP_DIR + the memory-health path wrong there.
# _src is the SessionStart `source` (startup|resume|compact|clear), read from the
# stdin payload the same way post-compact-resume.sh does; drives the Boot line.
_src=""
ENCODED_CWD="$(pwd | sed 's|/|-|g')"
if [[ ! -t 0 ]]; then
  _payload="$(cat 2>/dev/null || true)"
  if [[ -n "$_payload" ]]; then
    _tp="$(printf '%s' "$_payload" | hook_field transcript_path 2>/dev/null)" || _tp=""
    [[ -n "$_tp" ]] && ENCODED_CWD="$(basename "$(hook_pathnorm "$(dirname "$_tp")")")"
    _src="$(printf '%s' "$_payload" | hook_field source 2>/dev/null)" || _src=""
  fi
fi

# A lane is not a foreman. A T3-delegated lane is its own top-level session, so it
# boots through this hook like the main thread and used to get the whole briefing
# (memory flush queue, hygiene, update and backup lines), none of which it can act
# on: those lines are the foreman's. bin/lane-class says foreman, t3-lane or
# agent-lane; a lane gets one line and nothing else from here, and no state is
# written for it. A missing lane-class, a hung one (cut at 3 s) or any error in it
# is a foreman: the behavior before the gate existed. lane-rules.sh hands a lane its
# own shell rules at the same boot.
LANE_CLASS="foreman"
_lc="$HOOK_DIR/../bin/lane-class"
if [ -x "$_lc" ]; then
  _to="$(hook_timeout 2>/dev/null)" || _to=""
  if [ -n "$_to" ]; then LANE_CLASS="$("$_to" -k 1 3 "$_lc" <<<"${_payload:-}" 2>/dev/null)" || LANE_CLASS="foreman"
  else LANE_CLASS="$("$_lc" <<<"${_payload:-}" 2>/dev/null)" || LANE_CLASS="foreman"; fi
fi
case "$LANE_CLASS" in
  t3-lane|agent-lane)
    printf ' Briefing: %s session; the foreman briefing (memory flush queue, hygiene, backup and update lines) is not printed for lanes.\n' "$LANE_CLASS"
    exit 0 ;;
esac

# --- worker posture ---
gate="Sonnet 5.5 default lane · Opus 5.5 foreman and high-criticality lanes"

# --- config posture (parse flat keys from the resolved settings.json) ---
val() { grep -iE "\"$1\"[[:space:]]*:" "$SETTINGS" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*//; s/[",]//g; s/[[:space:]]*$//'; }
ac="$(val autoCompactEnabled)"; if [ "$ac" = "false" ]; then acs="OFF (manual /compact)"; else acs="ON"; fi
eff="$(val effortLevel)"; [ -n "$eff" ] || eff="default"
# Main-session (foreman) pin read from the shared stage-1 settings.json, not
# from $CFG/$SETTINGS: that file is the same for every profile, while the
# fallback below is a distinct env var rather than a settings.json key.
main_model="$(jq -r '.model // "default"' "$HOME/.claude/settings.json" 2>/dev/null)"
[ -n "$main_model" ] || main_model="default"
fallback_model="${ANTHROPIC_DEFAULT_OPUS_MODEL:-default}"

printf '============================================================\n'
printf ' SESSION BRIEFING\n'
printf '============================================================\n'
printf ' Worker:  %s\n' "$gate"
printf ' Config:  autocompact %s  ·  effort %s  ·  main=%s  ·  opus=%s\n' "$acs" "$eff" "$main_model" "$fallback_model"
printf ' Ultra:   ultracode is session-set via the alias (--settings); /effort to change\n'
# Boot surface: CONTEXT/core.md loads as the user rule ~/.claude/rules/ops-core.md
# (deploy.sh links it), on every launch path. Report whether that rule resolves
# to this checkout's core, so a session that booted without it says so at once
# instead of quietly running on defaults. An import file (deploy.ps1's fallback)
# counts when it names this core.
_core="$OPS_DIR/CONTEXT/core.md"
_rule="$CFG/rules/ops-core.md"
if hook_core_rule_matches "$_rule" "$_core"; then
  if [ -L "$_rule" ]; then
    _boot="core.md loaded via rules/ops-core.md"
  else
    _boot="core.md loaded via rules/ops-core.md (import)"
  fi
else
  _boot="core.md NOT linked (run .claude-config/deploy.sh)"
fi
printf ' Boot:    %s · source=%s\n' "$_boot" "${_src:-unknown}"

# --- project lessons pointer (two-tier memory: project knowledge lives on-demand here) ---
LESSONS_DIR="$OPS_DIR/CONTEXT/projects"
case "$(pwd)" in
  */OPS/PROJECTS/*)
    if ls "$LESSONS_DIR"/*-lessons.md >/dev/null 2>&1; then
      nles="$(ls -1 "$LESSONS_DIR"/*-lessons.md 2>/dev/null | wc -l | tr -d ' ')"
      printf ' Lessons: project knowledge in CONTEXT/projects/*-lessons.md (%s files); read the one for this project\n' "$nles"
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

# --- parked project root (quiet-when-clean) ---
# A thread that starts in a repo's MAIN checkout works on whatever that checkout has
# checked out. A checkout can sit on an old feature branch for weeks, many commits
# behind its default branch, and every new thread there then begins on that branch
# with nothing in the banner saying so. The line speaks when the checkout is on a
# branch other than the repo's default (origin/HEAD, else main, else master) or its
# commit is behind the remote-tracking default, and says nothing on the default
# branch when not behind. LOCAL refs only, no fetch and no network: "behind" means
# behind the last fetch, so a quiet line does not prove the repo is current. A linked
# worktree (its .git is a file) is parked on purpose, one branch per task, and a cwd
# under no repo has nothing to say, so neither runs git: the walk up to .git is pure
# bash. A main checkout pays three git calls (four when origin/HEAD names a branch
# other than main or master), each capped at 2 s by hook_timeout (gnutimeout, not
# uutils' 100 ms polling) when the host has a timeout binary; without one the calls
# run uncapped. GIT_OPTIONAL_LOCKS=0 keeps the probe from ever taking an index lock.
# A probe that fails or times out says so rather than printing nothing, because a
# silent probe would read as a clean checkout. No origin/HEAD and no main or master
# leaves nothing to compare against, which is the one silent case.
_RG_TO=""
_repo_git() {  # _repo_git <top> <git args...>: one read-only local probe, capped
  local top="$1"; shift
  if [ -n "$_RG_TO" ]; then GIT_OPTIONAL_LOCKS=0 "$_RG_TO" 2 git -C "$top" "$@" 2>/dev/null
  else GIT_OPTIONAL_LOCKS=0 git -C "$top" "$@" 2>/dev/null; fi
}
_repo_failed() {  # _repo_failed <repo name> <git exit code, or x for unreadable output>
  local why
  case "$2" in 124) why="timed out after 2s" ;; x) why="unreadable git output" ;; *) why="git exit $2" ;; esac
  printf ' Repo:    %s: branch check failed (%s); branch state unchecked\n' "$1" "$why"
}
parked_root_line() {
  local d="$PWD" top="" repo br="" dflt="" refs ref sym rc behind="" rhead="" rref="" have_remote="" msg=""
  local m_main="" m_master="" r_main="" r_master=""
  while [ -n "$d" ]; do
    if [ -e "$d/.git" ]; then [ -d "$d/.git" ] && top="$d"; break; fi
    d="${d%/*}"
  done
  [ -n "$top" ] || return 0
  repo="${top##*/}"
  # hook_timeout forks, so it runs only once a main checkout is in hand.
  _RG_TO="$(hook_timeout)" || _RG_TO=""
  # symbolic-ref -q exits 1 for a detached HEAD (a state, not an error) and 128 on failure.
  br="$(_repo_git "$top" symbolic-ref -q --short HEAD)"; rc=$?
  if [ "$rc" -gt 1 ]; then _repo_failed "$repo" "$rc"; return 0; fi
  refs="$(_repo_git "$top" for-each-ref --format='%(refname) %(symref)' \
    refs/remotes/origin/HEAD refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master)"; rc=$?
  if [ "$rc" -ne 0 ]; then _repo_failed "$repo" "$rc"; return 0; fi
  while read -r ref sym; do
    case "$ref" in
      refs/remotes/origin/HEAD) rhead="${sym#refs/remotes/origin/}" ;;
      refs/remotes/origin/main) r_main=1 ;;
      refs/remotes/origin/master) r_master=1 ;;
      refs/heads/main) m_main=1 ;;
      refs/heads/master) m_master=1 ;;
    esac
  done <<< "$refs"
  dflt="$rhead"
  if [ -z "$dflt" ]; then
    if [ -n "$m_main" ] || [ -n "$r_main" ]; then dflt=main
    elif [ -n "$m_master" ] || [ -n "$r_master" ]; then dflt=master; fi
  fi
  [ -n "$dflt" ] || return 0
  case "$dflt" in
    main) have_remote="$r_main" ;;
    master) have_remote="$r_master" ;;
    *) # origin/HEAD names some other branch: is its remote-tracking ref there?
      rref="$(_repo_git "$top" for-each-ref --format='%(refname)' "refs/remotes/origin/$dflt")"; rc=$?
      if [ "$rc" -ne 0 ]; then _repo_failed "$repo" "$rc"; return 0; fi
      [ -z "$rref" ] || have_remote=1 ;;
  esac
  # No remote-tracking default (never fetched, or no remote) means nothing to be behind.
  if [ -n "$have_remote" ]; then
    behind="$(_repo_git "$top" rev-list --count "HEAD..refs/remotes/origin/$dflt")"; rc=$?
    if [ "$rc" -ne 0 ]; then _repo_failed "$repo" "$rc"; return 0; fi
    case "$behind" in ''|*[!0-9]*) _repo_failed "$repo" x; return 0 ;; esac
    [ "$behind" -eq 0 ] || msg="$behind commit(s) behind origin/$dflt"
  fi
  if [ "$br" != "$dflt" ]; then
    printf ' Repo:    %s is on %s, not %s%s (local refs, no fetch)\n' "$repo" "${br:-a detached HEAD}" "$dflt" "${msg:+; $msg}"
  elif [ -n "$msg" ]; then
    printf ' Repo:    %s %s is %s (local refs, no fetch)\n' "$repo" "$dflt" "$msg"
  fi
  return 0
}
parked_root_line

# --- reminders (operator drops notes into this file; lines starting with # are headers) ---
REM="$OPS_DIR/.claude-reminders.md"
if [ -s "$REM" ]; then
  rems="$(grep -vE '^[[:space:]]*(#|$)' "$REM" 2>/dev/null | head -5)"
  if [ -n "$rems" ]; then
    printf ' Reminders:\n'
    printf '%s\n' "$rems" | sed 's/^/   - /'
  fi
fi

# --- team asks (quiet-when-clean): asks from a teammate's agent that wait on this owner ---
# A team that runs a local ask router installs `~/.local/bin/team-ask` on each owner's box.
# When a teammate's agent asks something only the owner can decide, the router opens an
# investigation thread on the owner's box (a session in the `~/team-asks` workspace, the
# "Team Asks" project). This line is the second surface: it lists the asks that still need
# the owner, so a thread that failed to open, or that nobody read, is never the only record.
# `team-ask pending --brief` prints one line or nothing from the router's local state (no
# network; the 3 s cap, with -k 1, keeps a stalled read from holding boot) and the line is
# shown as it prints it.
# Quiet when: the tool is absent (most copies: no router here); the box was turned off on
# purpose (the router's installer writes ~/.config/team-ask/disabled; the service link is not
# consulted); the session's folder is the Team asks workspace (the asks are the subject of
# that thread already); or the provider prints nothing. A lane never gets here: the lane
# gate above exits first.
# Never silent when broken: a link left pointing nowhere, a tool that is not executable, a
# provider that fails or times out, or no timeout command at all each print a line naming
# `team-ask pending`, because an empty line would read as "nobody is waiting on you".
# This hook has no resume short form (every start, resume included, prints the full
# briefing), so the one call below covers a resumed session too.
team_ask_line() {
  local tool="$HOME/.local/bin/team-ask" ws="$HOME/team-asks" wsr here out line to rc=0
  [ -e "$tool" ] || [ -L "$tool" ] || return 0
  [ -e "$HOME/.config/team-ask/disabled" ] && return 0
  wsr="$(cd "$ws" 2>/dev/null && pwd -P)" || wsr="$ws"
  here="$(pwd -P 2>/dev/null)" || here="$PWD"
  case "$PWD" in "$ws"|"$ws"/*) return 0 ;; esac
  case "$here" in "$wsr"|"$wsr"/*) return 0 ;; esac
  if [ ! -x "$tool" ]; then
    printf ' Team asks: %s is not executable (a broken install); run team-ask pending\n' "$tool"
    return 0
  fi
  if ! to="$(hook_timeout)"; then
    printf ' Team asks: pending reader unavailable (no timeout command); run team-ask pending\n'
    return 0
  fi
  # TERM alone does not bound a reader that catches it; kill it one grace second later.
  out="$("$to" -k 1 3 "$tool" pending --brief 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then printf ' Team asks: pending reader timed out after 3 s; run team-ask pending\n'
    else printf ' Team asks: pending reader failed (exit %s); run team-ask pending\n' "$rc"; fi
    return 0
  fi
  # One line, no control characters (an escape sequence in a name must not reach the screen).
  line="$(printf '%s\n' "$out" | head -n 1 | tr -d '\000-\010\013-\037\177' | cut -c1-400)"
  [ -n "$line" ] || return 0
  case "$line" in "Team asks:"*) ;; *) line="Team asks: $line" ;; esac
  printf ' %s\n' "$line"
  return 0
}
team_ask_line

# --- memory health (two-tier: soft flush budget, hard platform ceiling) ---
# Charter § Eviction: routine drainage happens at every closeout; the deep
# /memory-prune audit is for drift, not maintenance.
MEM="$CFG/projects/$ENCODED_CWD/memory/MEMORY.md"
if [ -f "$MEM" ]; then
  sz="$(wc -c < "$MEM" 2>/dev/null | tr -d ' ')"
  if [ "${sz:-0}" -gt 24576 ]; then
    printf ' Memory:  index ~%sKB OVER the 24KB platform ceiling (truncating NOW): closeout flush overdue\n' "$(( ${sz:-0} / 1024 ))"
  elif [ "${sz:-0}" -gt 16384 ]; then
    printf ' Memory:  flush debt: index ~%sKB > 16KB soft budget; next closeout evicts to budget\n' "$(( ${sz:-0} / 1024 ))"
  fi
fi

# Flush queue depth: pending fold-or-keep decisions the next closeout consumes
# (the read side of secrets-guard.sh's write-time nudge, which appends one
# "<ISO time><TAB><file><TAB><reason>" line per flagged memory entry). A queue
# nobody reads is decisions nobody makes, so say it at boot.
FQ="$HOME/.claude-compact-cycle/memory-flush-queue"
if [ -s "$FQ" ]; then
  fq_n="$(grep -c . "$FQ" 2>/dev/null)"
  fq_oldest="$(head -1 "$FQ" 2>/dev/null | cut -f1 | cut -dT -f1)"
  printf ' Memory:  flush queue %s line(s) pending (oldest %s); closeout hygiene step 2 consumes them\n' "${fq_n:-?}" "${fq_oldest:-?}"
fi

# --- hygiene (quiet-when-clean): dirty repos, drift-gate state, closeout age ---
STATE_DIR="${OPS_STATE_DIR:-$HOME/.local/state/ops}"
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
# work-tracking backstop: a session that did work but never ran session-close (so
# its reconciliation gate never fired) leaves a session-start stamp behind:
# session-close deletes it on reconcile. A leftover stamp is judged by evidence, not
# counted: it is flagged only when a repository it touched shows real commits in its
# own window (hooklib.sh, orphan_stamp_verdict). Skip this session's own key and any
# still-live tmux (paused / parallel sessions are not abandoned).
#
# THE SWEEP IS NOT ON THE BOOT PATH. A leftover stamp stays until session-close, and
# under T3 every thread that never closes leaves one, so judging them inline made boot
# grow with the set (126 stamps cost 49 s on one box, and every new session waits on
# this hook before its first model call). orphan_scan_spawn (hooklib.sh) starts the
# sweep detached, under a lock and a 30 min throttle (OPS_ORPHAN_SCAN_INTERVAL, in
# seconds); boot pays for a throttle check and a fork, then reports what the last scan
# left in the state dir. Flags can be up to one interval old, but a flagged stamp that
# session-close has since deleted stops counting at the next boot. A failed or vanished
# scan is named here every boot until a later scan passes. OPS_ORPHAN_SCAN=sync runs
# the sweep inline instead, with no throttle (tests, or a closeout that wants fresh
# flags). The sweep never removes or moves a stamp.
RUN="$HOME/.claude-compact-cycle"
CUR_KEY="$(work_session_key 2>/dev/null || echo)"
if [ -d "$RUN" ]; then
  orphan_scan_spawn "$RUN" "$STATE_DIR" "$CUR_KEY" "${OPS_ORPHAN_SCAN:-bg}"
  orphan_scan_report "$RUN" "$STATE_DIR" "$CUR_KEY"
  hyg="$hyg$ORPHAN_SCAN_HYG"
fi
# unadopted memory pools: real dirs (not symlinks) mean git-sync misses them. Not a
# pool worth adopting: a "-tmp*" project (a throwaway cwd), a T3 "No project" thread
# (cwd ~/.t3/scratch/<date>-<title>-<id>: each makes an empty memory/ dir and the line
# named it on every boot), or an EMPTY pool (git-sync has nothing in it to miss).
# Claude encodes every non-alphanumeric of a cwd as "-" (the dot of .t3 too), but a
# hook or older build that replaces only "/" leaves -home-<user>-.t3-scratch-, so both
# spellings are skipped; derived from $HOME, never a fixed user.
t3s_s="${HOME}/.t3/scratch/"; t3s_s="${t3s_s//\//-}"; t3s_d="${t3s_s//./-}"
for md in "$CFG"/projects/*/memory; do
  pk="${md%/memory}"; pk="${pk##*/}"
  case "$pk" in -tmp*|*-AppData-Local-Temp*|*claude-tmp*|*t3code-claude-title*|"$t3s_d"*|"$t3s_s"*) continue ;; esac
  [ -d "$md" ] && [ ! -L "$md" ] || continue
  pk_full=""
  # Match memory-init's empty-source rule: a generated index alone is no
  # content to adopt, so suggesting that command would never clear the nudge.
  for pk_f in "$md"/* "$md"/.[!.]*; do
    [ "$pk_f" = "$md/MEMORY.md" ] && continue
    [ -e "$pk_f" ] && { pk_full=1; break; }
  done
  [ -n "$pk_full" ] || continue
  hyg="$hyg unadopted memory pool ($pk): run .claude-config/bin/memory-init ·"
  break
done
if [ -n "$hyg" ]; then
  printf ' Hygiene:%s\n' "${hyg% ·}"
fi

# --- nightly backup (quiet-when-clean) ---
# daily-sync.sh exits 0 whatever its OPS stage did, and nothing else reads its
# log, so a push it skipped (origin not verified private) or a stage that
# failed (no git identity, a pull that failed every night) left the copy
# un-backed-up with no one the wiser. Read the LAST run's OPS-stage ERROR and
# WARN lines back from sync.log and say them here, with their continuation
# lines: each line already names its reason and its fix. Only the log's tail is
# read: a run is a few dozen lines, and the project stage adds one per repo.
# A copy with no origin remote logs "OPS: INFO no origin remote" instead: its
# commit stayed on this machine by design, so that run reads as "local only",
# never as a failure and never as quiet (quiet means backed up off the box).
# An ERROR or WARN in the same run still wins: that is the line to act on.
SYNC_LOG="$OPS_DIR/.claude-config/backup/sync.log"
if [ -f "$SYNC_LOG" ]; then
  bk="$(tail -n 3000 "$SYNC_LOG" 2>/dev/null | awk '
    /\] ===== daily-sync start =====/ { n = 0; cont = 0; local_only = 0; ts = substr($0, 2, 16); next }
    {
      msg = $0; sub(/^\[[^]]*\] /, "", msg)
      if (msg ~ /^OPS: (ERROR|WARN) /) { sub(/^OPS: /, "", msg); line[++n] = msg; cont = 1; next }
      if (cont && msg ~ /^     /) { sub(/^ +/, "", msg); line[n] = line[n] "; " msg; next }
      cont = 0
      if (msg ~ /^OPS: INFO no origin remote/) local_only = 1
    }
    END {
      if (n) { printf "fail|%s|", ts; for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? " / " : ""), line[i] }
      else if (local_only) printf "local|%s|", ts
    }')"
  if [ -n "$bk" ]; then
    bk_kind="${bk%%|*}"; bk="${bk#*|}"
    bk_ts="${bk%%|*}"; bk_msg="${bk#*|}"
    if [ "$bk_kind" = local ]; then
      printf ' Backup:  local only (no origin remote): the nightly run at %s kept the work in local commits, nothing pulled or pushed; to back it up off this machine, add a private origin (DEPLOYMENT.md step 8)\n' "$bk_ts"
    else
      [ "${#bk_msg}" -le 400 ] || bk_msg="${bk_msg:0:397}..."
      printf ' Backup:  the nightly backup at %s did not finish clean: %s (full log: %s)\n' "$bk_ts" "$bk_msg" "${SYNC_LOG/#$HOME/\~}"
    fi
  fi
fi

# --- window-ping health (quiet-when-clean): the cron dumb-pipe that opens the
# 5h usage window at fixed times (bin/claude-window-ping.sh). Silent when the
# feature isn't installed on this machine (no status file) or the last run was
# clean and recent; loud when a profile ping failed or cron stopped firing:
# either way the Operator's window never started and nobody was there to see.
WP="$HOME/.local/state/window-ping/last-status.tsv"
if [ -f "$WP" ]; then
  wpfail="$(awk -F'\t' '$2 != "0" {printf "%s rc=%s @ %s; ", $1, $2, $3}' "$WP" 2>/dev/null)"
  if [ -n "$wpfail" ]; then
    printf ' Ping:    last window-ping FAILED: %ssee ~/.local/state/window-ping/ping.log\n' "$wpfail"
  else
    wp_mt="$(stat -c %Y "$WP" 2>/dev/null || echo 0)"
    wp_age_h="$(( ( $(date +%s) - wp_mt ) / 3600 ))"
    wp_stale_h="${CC_WINDOW_PING_STALE_HOURS:-25}"   # >25h = no ping in a day; cron likely dead
    [ "$wp_mt" -gt 0 ] && [ "$wp_age_h" -ge "$wp_stale_h" ] && \
      printf ' Ping:    window-ping has not fired in %sh (cron dead?); check crontab + ping.log\n' "$wp_age_h"
  fi
fi
printf '============================================================\n'
exit 0
