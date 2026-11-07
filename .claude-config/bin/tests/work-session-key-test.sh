#!/usr/bin/env bash
# work-session-key-test.sh: behavior tests for work_session_key (hooks/hooklib.sh)
# and the per-thread state it keys under T3 Code (the session-work-init.sh stamp,
# the PreCompact work-log, and the briefing's leftover-stamp sweep).
#
# The defect: under T3 the key fell back to the encoded cwd, so every thread in
# one directory shared one session-start-* stamp and one work-log-*. A thread
# opened within 7 days inherited the old t0, the work-log mixed several threads
# (an elapsed time of a week), and one thread's session-close deleted its
# siblings' stamp.
#
# The invariants:
#   1. Under T3 with a session id the key is t3-<id sanitized to [A-Za-z0-9-]>,
#      per thread, and independent of the cwd.
#   2. Without T3, without an id, or with an id that sanitizes to nothing, the key
#      is the cwd key as before (never a bare "t3-" shared by every such session).
#   3. tmux still wins over the T3 branch, and ops_backend keeps its tmux, t3code,
#      bare precedence.
#   4. Two threads in one cwd get separate stamps and work-logs, and the second
#      does not inherit the first's t0 or elapsed.
#   5. The briefing's sweep names the thread, not the directory: a running
#      thread's own stamp is never counted against it.
#
# Every case builds its own environment with the T3 and tmux variables cleared
# first, so the verdict does not depend on where the suite runs. HOME is a fixture
# throughout: the live ~/.claude-compact-cycle is never read or written. The suite
# refuses to run outside the sandbox because the hooks it starts write and move
# state files.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$HERE/../../hooks"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

fails=0
pass(){ printf '  PASS  %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }
eq() { # label expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi
}

printf 'work-session-key-test:\n'
[ -r "$HOOKS/hooklib.sh" ] || { echo "cannot read hooklib.sh" >&2; exit 1; }

WORK="$TMP/work dir"; mkdir -p "$WORK"          # a cwd that is not a git repo
OTHER="$TMP/other-cwd"; mkdir -p "$OTHER"
WORK="$(cd "$WORK" && pwd)"; OTHER="$(cd "$OTHER" && pwd)"
STUB="$TMP/stub"; mkdir -p "$STUB"
# tmux stub: answers display-message with $STUB_TMUX_NAME, so no real server is needed.
printf '#!/bin/sh\nprintf "%%s\\n" "${STUB_TMUX_NAME-}"\n' > "$STUB/tmux"; chmod +x "$STUB/tmux"

SID_A='aaaaaaaa-1111-4222-8333-444444444444'
SID_B='bbbbbbbb-5555-4666-8777-888888888888'
CLEAR=(-u TMUX -u T3CODE_HOME -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u STUB_TMUX_NAME -u OPS_ORPHAN_SCAN -u OPS_LANE_CLASS)

# keyin DIR VAR=value...: work_session_key run from DIR under exactly that env.
keyin() {
  local dir="$1"; shift
  ( cd "$dir" && env "${CLEAR[@]}" "$@" bash -c '. "$1"; work_session_key' _ "$HOOKS/hooklib.sh" )
}
BASH_BIN="$(command -v bash)"
backendin() { ( cd "$WORK" && env "${CLEAR[@]}" "$@" "$BASH_BIN" -c '. "$1"; ops_backend' _ "$HOOKS/hooklib.sh" ); }
cwdkey() { printf '%s' "$1" | sed 's|/|-|g' | tr -cd 'A-Za-z0-9-'; }

T3ENV=(T3CODE_HOME=/nonexistent/t3)

# --- 1. T3 plus a session id: per-thread key, independent of the cwd -----------
eq "T3 (T3CODE_HOME) + session id => t3-<id>" "t3-$SID_A" \
   "$(keyin "$WORK" "${T3ENV[@]}" CLAUDE_CODE_SESSION_ID="$SID_A")"
eq "T3 (T3CODE_THREAD_ID only) + session id => t3-<id>" "t3-$SID_A" \
   "$(keyin "$WORK" T3CODE_THREAD_ID="$SID_A" CLAUDE_CODE_SESSION_ID="$SID_A")"
ka="$(keyin "$WORK" "${T3ENV[@]}" CLAUDE_CODE_SESSION_ID="$SID_A")"
kb="$(keyin "$WORK" "${T3ENV[@]}" CLAUDE_CODE_SESSION_ID="$SID_B")"
[ -n "$ka" ] && [ -n "$kb" ] && [ "$ka" != "$kb" ] \
  && pass "two threads in one cwd get different keys (the shared-stamp defect)" \
  || fail "two threads in one cwd share a key ('$ka' vs '$kb')"
eq "same thread keeps its key when the cwd changes (a hook and a Bash call agree)" "$ka" \
   "$(keyin "$OTHER" "${T3ENV[@]}" CLAUDE_CODE_SESSION_ID="$SID_A")"
eq "key is stable across calls" "$ka" "$(keyin "$WORK" "${T3ENV[@]}" CLAUDE_CODE_SESSION_ID="$SID_A")"
eq "session id is sanitized to [A-Za-z0-9-]" "t3-abcdef" \
   "$(keyin "$WORK" "${T3ENV[@]}" CLAUDE_CODE_SESSION_ID='ab/../cd ef')"

# --- 2. fallbacks: the cwd key, never a shared bare "t3-" ----------------------
want="$(cwdkey "$WORK")"
eq "T3 without a session id => cwd key" "$want" "$(keyin "$WORK" "${T3ENV[@]}")"
eq "T3 with an empty session id => cwd key" "$want" "$(keyin "$WORK" "${T3ENV[@]}" CLAUDE_CODE_SESSION_ID=)"
eq "T3 with an id that sanitizes to nothing => cwd key, not bare t3-" "$want" \
   "$(keyin "$WORK" "${T3ENV[@]}" CLAUDE_CODE_SESSION_ID='///...   ')"
eq "session id without T3 => cwd key (a plain terminal session is unchanged)" "$want" \
   "$(keyin "$WORK" CLAUDE_CODE_SESSION_ID="$SID_A")"
eq "no backend, no id => cwd key" "$want" "$(keyin "$WORK")"

# --- 3. tmux still wins --------------------------------------------------------
eq "tmux wins over T3 + session id" "Foo-Bar-baz" \
   "$(keyin "$WORK" "${T3ENV[@]}" CLAUDE_CODE_SESSION_ID="$SID_A" TMUX=/tmp/x,1,0 PATH="$STUB:$PATH" STUB_TMUX_NAME='Foo.Bar:baz')"
eq "ops_backend: tmux over t3code" tmux \
   "$(backendin "${T3ENV[@]}" TMUX=/tmp/x,1,0 PATH="$STUB:$PATH")"
eq "ops_backend: TMUX set but no tmux binary is not tmux" t3code \
   "$(mkdir -p "$TMP/no-tmux"; backendin "${T3ENV[@]}" TMUX=/tmp/x,1,0 PATH="$TMP/no-tmux")"
eq "ops_backend: t3code over bare" t3code "$(backendin "${T3ENV[@]}")"
eq "ops_backend: a T3 thread id alone marks T3" t3code "$(backendin T3CODE_THREAD_ID=x)"
eq "ops_backend: bare" bare "$(backendin)"

# --- 3b. zsh parity: session-close sources hooklib.sh in the zsh Bash tool ------
if command -v zsh >/dev/null 2>&1; then
  zk="$( cd "$WORK" && env "${CLEAR[@]}" "${T3ENV[@]}" CLAUDE_CODE_SESSION_ID="$SID_A" \
         zsh -c '. "$1"; work_session_key' _ "$HOOKS/hooklib.sh" )"
  eq "zsh and bash derive the same T3 key" "$ka" "$zk"
else
  printf '  SKIP  zsh parity (zsh not installed)\n'
fi

# --- 4. end to end: two threads in one cwd, separate stamps and work-logs --------
# Thread A stamped three days ago and never closed (the live shape: a sibling in
# the same directory, still inside the 7-day refresh window). Thread B starts now.
HOME_E="$TMP/home"; RUN="$HOME_E/.claude-compact-cycle"; mkdir -p "$HOME_E/cfg"
t3run() { # SID script [stdin...]: run a hook as thread SID, cwd WORK, fixture HOME
  local sid="$1" script="$2"; shift 2
  ( cd "$WORK" && env "${CLEAR[@]}" HOME="$HOME_E" CLAUDE_CONFIG_DIR="$HOME_E/cfg" PRE_COMPACT_BRANCH_GC=0 \
      T3CODE_HOME=/nonexistent/t3 CLAUDE_CODE_SESSION_ID="$sid" bash "$HOOKS/$script" )
}
printf '{"source":"startup"}' | t3run "$SID_A" session-work-init.sh
old="$(date -d '3 days ago' -Is)"
sed -i "s/^started_at=.*/started_at=$old/" "$RUN/session-start-t3-$SID_A"
printf '{"source":"startup"}' | t3run "$SID_B" session-work-init.sh
[ -f "$RUN/session-start-t3-$SID_A" ] && [ -f "$RUN/session-start-t3-$SID_B" ] \
  && pass "each thread has its own session-start stamp" \
  || fail "expected session-start-t3-<A> and -<B>, found: $(ls "$RUN" 2>/dev/null | tr '\n' ' ')"
b_t0="$(grep -m1 '^started_at=' "$RUN/session-start-t3-$SID_B" 2>/dev/null | cut -d= -f2-)"
b_age=$(( $(date +%s) - $(date -d "${b_t0:-@0}" +%s 2>/dev/null || echo 0) ))
[ "$b_age" -ge 0 ] && [ "$b_age" -lt 300 ] \
  && pass "the new thread's t0 is its own start, not the sibling's three-day-old one" \
  || fail "new thread's t0 is ${b_age}s old (started_at=$b_t0): it inherited a sibling's stamp"
grep -qxF "started_at=$old" "$RUN/session-start-t3-$SID_A" 2>/dev/null \
  && pass "the sibling's stamp is untouched by the new thread" \
  || fail "the sibling's t0 changed"
if [ -f "$RUN/session-start-t3-$SID_A" ]; then
  echo 'SENTINEL=keep' >> "$RUN/session-start-t3-$SID_A"
  printf '{"source":"compact"}' | t3run "$SID_A" session-work-init.sh
  grep -q '^SENTINEL=keep' "$RUN/session-start-t3-$SID_A" \
    && pass "a re-fire for the same thread keeps its stamp (write-if-absent still holds)" \
    || fail "a re-fire rewrote the thread's stamp"
else
  fail "no stamp for thread A to re-fire against"
fi

# PreCompact: B's segment reports B's elapsed. Make B's start about two minutes ago.
sed -i "s/^started_at=.*/started_at=$(date -d '125 seconds ago' -Is)/" "$RUN/session-start-t3-$SID_B"
printf '{"trigger":"manual"}' | t3run "$SID_B" pre-compact.sh >/dev/null 2>&1
if [ -s "$RUN/work-log-t3-$SID_B" ]; then
  el="$(grep -m1 -o 'elapsed=[0-9a-z-]*' "$RUN/work-log-t3-$SID_B")"
  case "$el" in
    elapsed=0h02m|elapsed=0h03m) pass "PreCompact elapsed comes from the thread's own stamp ($el)" ;;
    *) fail "PreCompact elapsed should be about 2 minutes from B's stamp, got '$el' (the sibling's t0 would read 72h)" ;;
  esac
else
  fail "no work-log-t3-<B> written; work-logs: $(ls "$RUN" 2>/dev/null | grep '^work-log' | tr '\n' ' ')"
fi
[ ! -e "$RUN/work-log-t3-$SID_A" ] && ! ls "$RUN"/work-log--* >/dev/null 2>&1 \
  && pass "no work-log is shared with, or written for, the sibling" \
  || fail "unexpected work-logs: $(ls "$RUN" | grep '^work-log' | tr '\n' ' ')"

# session-close deletes only its own thread's state (session-close/mechanics.md, step E).
kA="$(keyin "$WORK" "${T3ENV[@]}" CLAUDE_CODE_SESSION_ID="$SID_A")"
rm -f "$RUN/session-start-$kA" "$RUN/work-log-$kA"
[ ! -e "$RUN/session-start-t3-$SID_A" ] && [ -f "$RUN/session-start-t3-$SID_B" ] \
  && pass "closing thread A leaves thread B's stamp (the sibling-deletion defect)" \
  || fail "closing A removed B's stamp, or left A's"

# --- 5. the briefing's sweep, per thread ------------------------------------------
# A repo with real commits, so a leftover stamp that names it is flaggable. Two
# settled siblings name it (older than 18h, with no tmux to ask); the running thread
# B's own stamp does too and must be exempt. OPS_ORPHAN_SCAN=sync runs the sweep
# inline: by default it runs detached after the briefing returns.
SW="$TMP/sweep"; SRUN="$SW/home/.claude-compact-cycle"; mkdir -p "$SRUN" "$SW/home/cfg" "$SW/repo"
git -C "$SW/repo" init -q . >/dev/null 2>&1
# dated at the stamps' own t0 (30 hours ago), so it falls inside their git window
# whatever the time of day the suite runs
GIT_AUTHOR_DATE="$(date -d '30 hours ago' -Is)" GIT_COMMITTER_DATE="$(date -d '30 hours ago' -Is)" \
  git -C "$SW/repo" -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false \
  commit -q --allow-empty -m 'feat(example): real work' >/dev/null 2>&1
mkst() { printf 'started_at=%s\ncwd=%s\nboot_repo=%s\nboot_head=-\ntmux=-\nsource=startup\n' \
           "$(date -d "$2" -Is)" "$WORK" "$SW/repo" > "$SRUN/session-start-$1"; touch -d "$2" "$SRUN/session-start-$1"; }
sweep() { # sweep SID: the briefing as thread SID, sweep inline; prints the Hygiene line
  ( cd "$WORK" && env "${CLEAR[@]}" HOME="$SW/home" CLAUDE_CONFIG_DIR="$SW/home/cfg" OPS_DIR="$TMP/ops" \
      T3CODE_HOME=/nonexistent/t3 CLAUDE_CODE_SESSION_ID="$1" OPS_ORPHAN_SCAN=sync \
      bash "$HOOKS/session-briefing.sh" </dev/null 2>/dev/null | grep '^ Hygiene:' )
}
mkdir -p "$TMP/ops"
mkst "t3-$SID_B" '30 hours ago'
mkst "t3-cccccccc-9999-4aaa-8bbb-cccccccccccc" '30 hours ago'    # settled sibling with real commits in its window
mkst "t3-dddddddd-9999-4aaa-8bbb-dddddddddddd" '2 hours ago'     # sibling younger than 18h
line="$(sweep "$SID_B")"
case "$line" in
  *" 1 session(s) abandoned without a work-tracking reconciliation"*) pass "the sweep counts the settled sibling only: not the running thread's own stamp, not the young one" ;;
  *) fail "expected exactly one abandoned session from the sweep, got: '$line'" ;;
esac
[ -f "$SRUN/session-start-t3-$SID_B" ] && [ -f "$SRUN/session-start-t3-cccccccc-9999-4aaa-8bbb-cccccccccccc" ] \
  && [ -f "$SRUN/session-start-t3-dddddddd-9999-4aaa-8bbb-dddddddddddd" ] \
  && pass "the sweep leaves every stamp in place (it never deletes or moves one)" \
  || fail "a stamp went missing during the sweep: $(ls "$SRUN" | tr '\n' ' ')"
# the same briefing run as the settled sibling itself: its own stamp is exempt, and B's is now the leftover
line="$(sweep "cccccccc-9999-4aaa-8bbb-cccccccccccc")"
case "$line" in
  *" 1 session(s) abandoned"*) pass "run as the sibling, the count names the other settled stamp (B's), not its own" ;;
  *) fail "sweep as the sibling: '$line'" ;;
esac

if [ "$fails" -eq 0 ]; then
  printf 'work-session-key-test: ALL INVARIANTS HOLD\n'; exit 0
else
  printf 'work-session-key-test: %d FAILURE(S)\n' "$fails"; exit 1
fi
