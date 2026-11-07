#!/usr/bin/env bash
# orphan-gate-test.sh: behavior tests for the leftover-stamp judgment and the scan
# that runs it off the boot path (hooks/hooklib.sh: orphan_stamp_verdict,
# orphan_scan_spawn / _main / _run / _report), with the briefing as the one caller.
#
# Why the scan exists: a leftover session-start stamp stays until session-close, and
# under T3 every thread that never closes leaves one, so judging them inline made
# boot grow with the set. The briefing now only starts a detached scan and reports
# what the last one left in the state dir.
#
# Pinned:
#   verdicts   a stamp with nothing attributable, a repo that is a linked worktree,
#              only housekeeping commits, or commits outside its window is quiet; a
#              repo with real commits in the window (named by the stamp or by its
#              work-log) is flagged; a transcript extends the window of a session
#              that never compacted, and one older than t0 does not; an unreadable
#              record is an error, never a quiet guess
#   the scan   a sync run writes the status and the flags; a stamp whose tmux
#              session is alive, the running session's own stamp and a stamp under
#              18h are not judged; no stamp is ever deleted or moved
#   boot       a detached scan leaves the boot path at once (a slow git does not hold
#              it), the throttle keeps a second boot from starting another scan, a
#              stampede of boots runs one scan, and no stamp at all starts nothing
#   locks      a held flock and a held mkdir lock skip the scan, a dead mkdir owner
#              is recovered, a live one never is
#   failures   an unwritable state dir, an unwritable status and a scan that died
#              are each named at boot until a later scan passes
#   report     a flagged stamp that session-close has since removed stops counting
#              at once, and the running session's own stamp never counts
#
# Every path is under a temp dir; HOME is a fixture. The suite refuses to run
# outside the sandbox because the code under test writes and moves state files.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOKS="$HERE/../../hooks"
[ -r "$HOOKS/hooklib.sh" ] || { echo "cannot read hooklib.sh" >&2; exit 1; }
command -v git >/dev/null || { echo "git required" >&2; exit 1; }
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
chmod u+w "$TMP" 2>/dev/null

fails=0
pass(){ printf '  PASS  %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1: wanted '$2' in '$3'" ;; esac; }
lacks() { case "$3" in *"$2"*) fail "$1: found '$2' in '$3'" ;; *) pass "$1" ;; esac; }

printf 'orphan-gate-test:\n'

export HOME="$TMP/home"; mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR OPS_ORPHAN_SCAN OPS_ORPHAN_SCAN_INTERVAL OPS_ORPHAN_LOCK ORPHAN_WINDOW_CAP TMUX
RUN="$HOME/.claude-compact-cycle"; STATE="$HOME/.local/state/ops"; mkdir -p "$RUN"
BASH_BIN="$(command -v bash)"
STUB="$TMP/stub"; mkdir -p "$STUB"
# tmux stub: has-session answers by STUB_TMUX_ALIVE (1 = alive), nothing else is needed.
printf '#!/bin/sh\ncase "$1" in has-session) [ "${STUB_TMUX_ALIVE:-0}" = 1 ] ;; *) exit 1 ;; esac\n' > "$STUB/tmux"; chmod +x "$STUB/tmux"

# --- fixtures ------------------------------------------------------------------
mkrepo() { git -C "$1" init -q . 2>/dev/null || { mkdir -p "$1" && git -C "$1" init -q . ; }; }
commit_at() { # repo when subject
  GIT_AUTHOR_DATE="$(date -d "$2" -Is)" GIT_COMMITTER_DATE="$(date -d "$2" -Is)" \
    git -C "$1" -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false \
    commit -q --allow-empty -m "$3" >/dev/null 2>&1
}
mkstamp() { # key when boot_repo [cwd] [tmux]: a stamp whose t0 and mtime are WHEN
  printf 'started_at=%s\ncwd=%s\nboot_repo=%s\nboot_head=-\ntmux=%s\nsource=startup\n' \
    "$(date -d "$2" -Is)" "${4:-$TMP/cwd}" "$3" "${5:--}" > "$RUN/session-start-$1"
  touch -d "$2" "$RUN/session-start-$1"
}
reset_state() { rm -rf "$RUN" "$STATE"; mkdir -p "$RUN"; }
# The code under test runs with set -u, like the briefing that calls it: an unset variable in
# any branch is a crash there, so every helper below exercises it that way.
verdict() { ( set -u; . "$HOOKS/hooklib.sh"; orphan_stamp_verdict "$RUN/session-start-$1" ); }
vword() { verdict "$1" | cut -f1; }

REPO="$TMP/repo-real"; mkrepo "$REPO"; commit_at "$REPO" '30 hours ago' 'feat(example): real work'
HK="$TMP/repo-housekeeping"; mkrepo "$HK"; commit_at "$HK" '30 hours ago' 'chore(memory): sync'; commit_at "$HK" '30 hours ago' 'chore(close): wrap up'
LATE="$TMP/repo-late"; mkrepo "$LATE"; commit_at "$LATE" '1 day ago' 'feat(example): later work'
WT="$TMP/repo-worktree"; mkdir -p "$WT"; printf 'gitdir: %s/.git/worktrees/x\n' "$REPO" > "$WT/.git"

# --- 1. verdicts ---------------------------------------------------------------
reset_state
mkstamp nothing '30 hours ago' '-'
eq "no boot repo and no work-log: quiet (nothing attributable)" quiet "$(vword nothing)"
mkstamp real '30 hours ago' "$REPO"
v="$(verdict real)"; eq "a repo with real commits in the window: flag" flag "${v%%$'\t'*}"
has "the flag names the repo" repo-real "$v"
mkstamp housekeeping '30 hours ago' "$HK"
eq "only housekeeping commits in the window: quiet" quiet "$(vword housekeeping)"
mkstamp worktree '30 hours ago' "$WT"
eq "a linked worktree (a .git file) is not judged: quiet" quiet "$(vword worktree)"
mkstamp gone '30 hours ago' "$TMP/no-such-repo"
eq "a boot repo that no longer exists: quiet" quiet "$(vword gone)"
mkstamp outside '5 days ago' "$LATE"
eq "commits after the stamp's window: quiet" quiet "$(vword outside)"
# the work-log names a repo the boot did not
mkstamp wl '30 hours ago' '-'
printf '## segment: trigger=manual elapsed=0h10m\nrepo=%s branch=main cwd=/x\n' "$REPO" > "$RUN/work-log-wl"
eq "no boot repo but a work-log naming a repo with real commits: flag" flag "$(vword wl)"
mkstamp wl2 '30 hours ago' '-'
printf '## segment: trigger=manual elapsed=0h10m\nrepo=- branch=- cwd=/x\n' > "$RUN/work-log-wl2"
eq "a work-log naming no repo: quiet" quiet "$(vword wl2)"
# a missing stamp is quiet, not an error
eq "a stamp that is gone: quiet" quiet "$( set -u; . "$HOOKS/hooklib.sh"; orphan_stamp_verdict "$RUN/session-start-nope" | cut -f1 )"

# --- 1b. the window: a transcript extends it for a session that never compacted ---
reset_state
TXC="$TMP/cwd-tx"; mkdir -p "$TXC"
ENC="${TXC//\//-}"; mkdir -p "$HOME/.claude/projects/$ENC"
mkrepo "$TMP/repo-tx"; commit_at "$TMP/repo-tx" '3 days ago' 'feat(example): long session work'
mkstamp tx '5 days ago' "$TMP/repo-tx" "$TXC"
eq "commit three days into a five-day-old stamp with no transcript: quiet" quiet "$(vword tx)"
: > "$HOME/.claude/projects/$ENC/s.jsonl"; touch -d '3 days ago' "$HOME/.claude/projects/$ENC/s.jsonl"
eq "a transcript last written at the commit extends the window: flag" flag "$(vword tx)"
touch -d '6 days ago' "$HOME/.claude/projects/$ENC/s.jsonl"
eq "a transcript older than t0 belongs to an earlier session: quiet" quiet "$(vword tx)"
touch -d '3 days ago' "$HOME/.claude/projects/$ENC/s.jsonl"
printf '## segment: trigger=manual elapsed=0h10m\nrepo=- branch=- cwd=/x\n' > "$RUN/work-log-tx"
touch -d '5 days ago' "$RUN/work-log-tx"    # as old as the stamp, so its own mtime does not widen the window
eq "a work-log wins outright: the shared transcript directory is not consulted" quiet "$(vword tx)"
rm -f "$RUN/work-log-tx"
v="$( ORPHAN_WINDOW_CAP=3600 bash -c 'set -u; . "$1"; orphan_stamp_verdict "$2"' _ "$HOOKS/hooklib.sh" "$RUN/session-start-tx" | cut -f1 )"
eq "ORPHAN_WINDOW_CAP bounds the window: a one-hour cap leaves the transcript out of reach" quiet "$v"

# --- 1c. an unreadable record is an error, never a quiet guess ----------------------
if [ "$(id -u)" -ne 0 ]; then
  reset_state
  mkstamp locked '30 hours ago' "$REPO"; chmod 000 "$RUN/session-start-locked"
  eq "an unreadable stamp: error" error "$(vword locked)"
  chmod 600 "$RUN/session-start-locked"
else
  printf '  SKIP  unreadable stamp (running as root)\n'
fi

# --- 2. the scan (inline) ----------------------------------------------------------
reset_state
mkstamp s-flag '30 hours ago' "$REPO"
mkstamp s-quiet '30 hours ago' '-'
mkstamp s-young '2 hours ago' "$REPO"
mkstamp s-self '30 hours ago' "$REPO"
mkstamp s-alive '30 hours ago' "$REPO" "$TMP/cwd" 'live-session'
mkstamp s-dead '30 hours ago' "$REPO" "$TMP/cwd" 'dead-session'
scan_sync() { # CUR [VAR=value...]: one inline scan
  local cur="$1"; shift
  env "$@" "$BASH_BIN" -c 'set -u; . "$1"; orphan_scan_spawn "$2" "$3" "$4" sync' _ "$HOOKS/hooklib.sh" "$RUN" "$STATE" "$cur"
}
# tmux stub answers "alive" for every session: a stamp that names one is not abandoned
scan_sync s-self PATH="$STUB:$PATH" STUB_TMUX_ALIVE=1
st="$(cat "$STATE/orphan-scan.status" 2>/dev/null)"
has "the scan records state=ok" 'state=ok' "$st"
has "the scan counts one run" 'runs=1' "$st"
eq "the flags hold the abandoned stamp, not the live-tmux, young, quiet or own stamp: s-flag only" "s-flag" "$(cat "$STATE/orphan-flags" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
has "the status counts one flagged stamp" 'flagged=1' "$st"
# the same scan with tmux dead: the stamp that named a session is judged too
scan_sync s-self PATH="$STUB:$PATH" STUB_TMUX_ALIVE=0
flags="$(sort "$STATE/orphan-flags" | tr '\n' ' ' | sed 's/ $//')"
eq "with tmux answering dead, the stamps that named a session are judged as well" "s-alive s-dead s-flag" "$flags"
has "a second scan counts a second run" 'runs=2' "$(cat "$STATE/orphan-scan.status")"
n="$(ls "$RUN"/session-start-* | wc -l | tr -d ' ')"
eq "no stamp was deleted or moved by either scan" 6 "$n"
[ ! -d "$RUN/reaped" ] && pass "nothing was archived (the scan has no reaping step)" || fail "a reaped/ directory appeared"

# --- 3. the report (what the boot says) ---------------------------------------------
report() { # CUR: prints ORPHAN_SCAN_HYG
  "$BASH_BIN" -c 'set -u; . "$1"; ORPHAN_SCAN_NOTE=""; orphan_scan_report "$2" "$3" "$4"; printf "%s" "$ORPHAN_SCAN_HYG"' _ "$HOOKS/hooklib.sh" "$RUN" "$STATE" "$1"
}
has "the report counts the flagged stamps that still exist" ' 3 session(s) abandoned without a work-tracking reconciliation' "$(report '')"
has "the running session's own stamp never counts" ' 2 session(s) abandoned' "$(report s-flag)"
rm -f "$RUN/session-start-s-flag" "$RUN/session-start-s-dead"
has "a flagged stamp that session-close removed stops counting at once" ' 1 session(s) abandoned' "$(report '')"
rm -f "$RUN/session-start-s-alive"
eq "with every flagged stamp gone the report is silent" "" "$(report '')"

# --- 4. boot: the scan runs detached and never holds the boot path -----------------
reset_state
mkstamp b1 '30 hours ago' "$REPO"
mkdir -p "$STATE"
SLOW="$TMP/slow"; mkdir -p "$SLOW"
REAL_GIT="$(command -v git)"
printf '#!/bin/sh\nsleep 2\nexec "%s" "$@"\n' "$REAL_GIT" > "$SLOW/git"; chmod +x "$SLOW/git"
spawn_bg() { # CUR [VAR=value...]: the boot-path call, background mode
  local cur="$1"; shift
  env "$@" "$BASH_BIN" -c 'set -u; . "$1"; orphan_scan_spawn "$2" "$3" "$4" bg' _ "$HOOKS/hooklib.sh" "$RUN" "$STATE" "$cur"
}
wait_status() { # STATE-VALUE [SECONDS]: poll until status has state=<value>
  local want="$1" tries=$(( ${2:-20} * 10 ))
  while [ "$tries" -gt 0 ]; do
    grep -q "^state=$want\$" "$STATE/orphan-scan.status" 2>/dev/null && return 0
    sleep 0.1; tries=$((tries - 1))
  done
  return 1
}
wait_runs() { # N [SECONDS]: poll until the status counts N runs and is not running
  local want="$1" tries=$(( ${2:-20} * 10 ))
  while [ "$tries" -gt 0 ]; do
    if grep -q "^runs=$want\$" "$STATE/orphan-scan.status" 2>/dev/null && ! grep -q '^state=running$' "$STATE/orphan-scan.status"; then return 0; fi
    sleep 0.1; tries=$((tries - 1))
  done
  return 1
}
t0="$(date +%s%N)"
spawn_bg me PATH="$SLOW:$PATH"
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
[ "$ms" -lt 1500 ] && pass "the boot-path call returns at once while a slow scan runs (${ms} ms)" || fail "the boot-path call took ${ms} ms: it waited for the scan"
wait_status running 5 && pass "the detached scan records state=running" || fail "the scan never recorded running: $(cat "$STATE/orphan-scan.status" 2>/dev/null)"
wait_status ok 30 && pass "and finishes with state=ok" || fail "the detached scan did not finish: $(cat "$STATE/orphan-scan.status" 2>/dev/null)"
eq "the detached scan flagged the stamp" "b1" "$(cat "$STATE/orphan-flags" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
# the throttle: a second boot inside the interval starts nothing
spawn_bg me2; sleep 1
eq "a second boot inside the throttle starts no scan (runs still 1)" "runs=1" "$(grep '^runs=' "$STATE/orphan-scan.status")"
# interval 0: due again
spawn_bg me2 OPS_ORPHAN_SCAN_INTERVAL=0; wait_runs 2 10
eq "with the interval at 0 the next boot scans again (runs 2)" "runs=2" "$(grep '^runs=' "$STATE/orphan-scan.status")"
# no stamps at all: nothing is started and old flags are cleared
rm -f "$RUN"/session-start-*
rm -f "$STATE/orphan-scan.status"
spawn_bg me3; sleep 0.5
[ ! -e "$STATE/orphan-scan.status" ] && pass "no stamp left: no scan is started" || fail "a scan was started with no stamp to judge"
[ ! -e "$STATE/orphan-flags" ] && pass "no stamp left: the old flags are cleared" || fail "stale flags survived"

# a stampede of boots in the same second runs ONE scan
reset_state; mkstamp st1 '30 hours ago' "$REPO"
for _ in 1 2 3 4 5 6; do spawn_bg x PATH="$SLOW:$PATH" & done; wait
wait_status ok 30 || true; sleep 1
eq "six simultaneous boots run one scan" "runs=1" "$(grep '^runs=' "$STATE/orphan-scan.status" 2>/dev/null)"

# --- 6. locks ------------------------------------------------------------------------
reset_state; mkstamp l1 '30 hours ago' "$REPO"; mkdir -p "$STATE"
if command -v flock >/dev/null 2>&1; then
  # the subshell takes the lock, then becomes the sleep that holds it: one PID to kill
  ( exec 8>>"$STATE/orphan-scan.lock"; flock -n 8 || exit 1; exec sleep 5 ) & holder=$!
  sleep 0.5
  scan_sync x; sleep 0.2
  [ ! -e "$STATE/orphan-scan.status" ] && pass "a held flock skips the scan quietly" || fail "the scan ran under a held flock: $(cat "$STATE/orphan-scan.status")"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
else
  printf '  SKIP  flock cases (no flock)\n'
fi
rm -rf "$STATE/orphan-scan.lock"
# the mkdir lock (the path a box without flock takes), forced on this box
mkdir -p "$STATE/orphan-scan.lock.d"; printf '%s\n' "$$" > "$STATE/orphan-scan.lock.d/pid"
scan_sync x OPS_ORPHAN_LOCK=mkdir
[ ! -e "$STATE/orphan-scan.status" ] && pass "a live mkdir-lock owner is never robbed" || fail "the scan took a live owner's lock"
( : ) & dead=$!; wait "$dead" 2>/dev/null
printf '%s\n' "$dead" > "$STATE/orphan-scan.lock.d/pid"
scan_sync x OPS_ORPHAN_LOCK=mkdir
has "a dead mkdir-lock owner is recovered and the scan runs" 'state=ok' "$(cat "$STATE/orphan-scan.status" 2>/dev/null)"
[ ! -e "$STATE/orphan-scan.lock.d" ] && pass "the mkdir lock is released after the scan" || fail "the mkdir lock was left behind"

# --- 7. failures are named, never silent ---------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  reset_state; mkstamp f1 '30 hours ago' "$REPO"; mkdir -p "$STATE"; chmod 555 "$STATE"
  note="$( "$BASH_BIN" -c '. "$1"; orphan_scan_spawn "$2" "$3" x bg; printf "%s" "$ORPHAN_SCAN_NOTE"' _ "$HOOKS/hooklib.sh" "$RUN" "$STATE" )"
  chmod 755 "$STATE"
  has "an unwritable state dir is named at boot" 'cannot write' "$note"
else
  printf '  SKIP  unwritable state dir (running as root)\n'
fi
reset_state; mkstamp f2 '30 hours ago' "$REPO"; mkdir -p "$STATE/orphan-scan.status"   # a directory where the status file belongs
scan_sync x
[ -e "$STATE/orphan-scan.error" ] && pass "a status that cannot be written leaves an error marker" || fail "no error marker for an unwritable status"
has "and the boot report names it" 'orphan-stamp scan failed' "$(report '')"
rm -rf "$STATE/orphan-scan.status" "$STATE/orphan-scan.error"
scan_sync x
[ ! -e "$STATE/orphan-scan.error" ] && has "a later passing scan clears the failure" 'state=ok' "$(cat "$STATE/orphan-scan.status")" || fail "the error marker outlived a passing scan"
# a scan that wrote state=error is named by its reason, every boot
printf 'state=error\nstarted=1\nfinished=2\npid=1\nruns=1\nflagged=0\nerrors=cannot read stamps in /x\n' > "$STATE/orphan-scan.status"
has "a scan in state=error is named with its reason" 'orphan-stamp scan failed: cannot read stamps in /x' "$(report '')"
# a scan killed mid-run leaves state=running; the boot names it once it is 15 minutes old
printf 'state=running\nstarted=%s\nfinished=\npid=1\nruns=1\nflagged=0\nerrors=\n' "$(( $(date +%s) - 1200 ))" > "$STATE/orphan-scan.status"
has "a scan stuck in running for 20 minutes is named" 'started 20m ago and never finished' "$(report '')"
printf 'state=running\nstarted=%s\nfinished=\npid=1\nruns=1\nflagged=0\nerrors=\n' "$(( $(date +%s) - 60 ))" > "$STATE/orphan-scan.status"
lacks "a scan that has run for one minute is not named" 'never finished' "$(report '')"
# the scan could not read the stamps: the last good flags are kept
reset_state; mkstamp k1 '30 hours ago' "$REPO"; mkdir -p "$STATE"; printf 'k1\n' > "$STATE/orphan-flags"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$RUN/session-start-k1"
  scan_sync x
  chmod 600 "$RUN/session-start-k1"
  has "an unreadable stamp makes the scan end in state=error" 'state=error' "$(cat "$STATE/orphan-scan.status")"
  eq "and the last good flags stay" "k1" "$(tr -d '\n' < "$STATE/orphan-flags")"
fi

# A git failure is not evidence that no work happened. Keep the previous flags
# and report the failed read, even when git emitted some subjects before failing.
reset_state; mkstamp gitfail '30 hours ago' "$REPO"; mkdir -p "$STATE"
printf 'gitfail\n' > "$STATE/orphan-flags"
BADGIT="$TMP/badgit"; mkdir -p "$BADGIT"
printf '#!/bin/sh\nprintf "feat(example): partial history\\n"\nexit 128\n' > "$BADGIT/git"
chmod +x "$BADGIT/git"
v="$(PATH="$BADGIT:$PATH" verdict gitfail)"
eq "a failed git-history read is an error, not quiet or partial evidence" error "${v%%$'\t'*}"
scan_sync x PATH="$BADGIT:$PATH"
has "a git failure makes the scan report state=error" 'state=error' "$(cat "$STATE/orphan-scan.status")"
has "the failed read is named" 'cannot read git history' "$(cat "$STATE/orphan-scan.status")"
eq "a git failure preserves the last good flags" gitfail "$(tr -d '\n' < "$STATE/orphan-flags")"
scan_sync x
has "a later successful git read clears the failure" 'state=ok' "$(cat "$STATE/orphan-scan.status")"

# --- 8. the briefing is the caller ----------------------------------------------------
reset_state; mkstamp bf '30 hours ago' "$REPO"; mkdir -p "$TMP/ops-dir"
briefing() { ( cd "$TMP" && env -u TMUX HOME="$HOME" OPS_DIR="$TMP/ops-dir" CLAUDE_CONFIG_DIR="$HOME/cfg" "$@" bash "$HOOKS/session-briefing.sh" </dev/null 2>/dev/null ); }
out="$(briefing OPS_ORPHAN_SCAN=sync)"
has "the briefing's Hygiene line carries the abandoned-session count (sync)" 'session(s) abandoned without a work-tracking reconciliation' "$(grep '^ Hygiene:' <<< "$out")"
out="$(briefing OPS_ORPHAN_SCAN=sync)"
has "and again on the next boot, from the flags the scan left" 'session(s) abandoned' "$(grep '^ Hygiene:' <<< "$out")"
reset_state; mkstamp bg1 '30 hours ago' "$REPO"
out="$(briefing)"
lacks "a first background boot has no flags yet and prints no count" 'abandoned' "$out"
wait_status ok 20 && pass "the background scan the briefing started finishes" || fail "the briefing's detached scan never finished"
out="$(briefing)"
has "the next boot reports what that scan found" 'session(s) abandoned' "$(grep '^ Hygiene:' <<< "$out")"

if [ "$fails" -eq 0 ]; then
  printf 'orphan-gate-test: ALL CASES PASS\n'; exit 0
else
  printf 'orphan-gate-test: %d FAILURE(S)\n' "$fails"; exit 1
fi
