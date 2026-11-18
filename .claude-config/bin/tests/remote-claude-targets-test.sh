#!/usr/bin/env bash
# remote-claude-targets-test.sh: the tmux targets the remote-session scripts pass are the
# right form for the command (remote-sessions/lib-remote-claude.sh, new-remote-claude.sh).
#
# Why: tmux resolves targets differently by command. A bare exact-session target "=NAME"
# is fine for has-session and kill-session, but send-keys with it fails ("can't find pane")
# on tmux 3.5a and 3.6, which dropped the launch line and left a bare shell that never became
# a Claude session, and display-message with it prints an empty value. Pane-level commands
# need "=NAME:" (exact session, current window). Both forms stay exact, so a name that is a
# prefix of a sibling's (Dev and Dev2) never reaches the sibling.
#
# Offline: `tmux` and `sleep` are shell functions here, so no tmux binary runs and nothing
# waits; each call's argv is logged and pinned. The real-server proof, with a prefix-sharing
# sibling, is remote-claude-tmux-test.sh.
#
# Pinned: for rc_launch (create and resume), rc_sweep, rc_archive and the already-running
# branch of new-remote-claude.sh, the exact argv of every tmux call; session-level commands
# take "=NAME", pane-level ones "=NAME:", and no -t target is ever bare.
#
# Every path (HOME, the registry, the archive, the env file) is a fixture under a temp dir.
# Usage: remote-claude-targets-test.sh    (exit 0 all pass, 1 otherwise)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
RS="$HERE/../../remote-sessions"
[ -f "$RS/lib-remote-claude.sh" ] && [ -f "$RS/new-remote-claude.sh" ] || { echo "FAIL: remote-sessions scripts missing"; exit 1; }

T="$(mktemp -d)"; export T; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }

echo "remote-claude-targets-test:"
mkdir -p "$T/home/.claude/projects/p" "$T/work"
unset TMUX
export HOME="$T/home" TMUX_TMPDIR="$T/tmuxtmp" RC_ENVFILE="$T/env.sh" RC_REGISTRY="$T/registry.tsv" \
  RC_ARCHIVE="$T/archive.tsv" RC_DEFAULT_WORKDIR="$T/work" TMUX_LOG="$T/tmux.log"
: > "$RC_ENVFILE"

# The stub: logs one line per call (arguments joined by a unit separator so a space inside an
# argument stays visible), then answers the way a running tmux would. TMUX_HAS decides
# has-session (0 running, 1 not); TMUX_ATTACHED is what session_attached returns.
tmux() {
  ( IFS=$'\037'; printf '%s\n' "$*" >> "$TMUX_LOG" )
  case "$1" in
    has-session) return "${TMUX_HAS:-1}" ;;
    new-session) [ "${TMUX_FAIL:-}" != create ]; return ;;
    list-panes) [ "${TMUX_FAIL:-}" != pane ]; return ;;
    send-keys)
      if [ "$#" -eq 5 ]; then [ "${TMUX_FAIL:-}" != launch ]
      else [ "${TMUX_FAIL:-}" != enter ]; fi
      return ;;
    display-message) case "$*" in *session_attached*) printf '%s\n' "${TMUX_ATTACHED:-0}" ;; *) printf '%s\n' "$T/work" ;; esac ;;
  esac
  return 0
}
export -f tmux
sleep() { :; }   # rc_launch waits 12 s for a real claude to start; nothing to wait for here
export -f sleep
# shellcheck source=/dev/null
. "$RS/lib-remote-claude.sh"
# the lib puts the system dirs first on PATH; a function still beats any binary
[ "$(type -t tmux)" = function ] || { echo "FAIL: the tmux stub is not in force; refusing to go on"; exit 1; }

US=$'\037'
SID="11111111-2222-3333-4444-555555555555"
calls() { cat "$TMUX_LOG" 2>/dev/null; }
reset() { : > "$TMUX_LOG"; TMUX_HAS=1; TMUX_ATTACHED=0; }
line_is() {  # <label> <expected argv, joined by the separator>
  if calls | grep -qxF -- "$2"; then ok "$1"; else bad "$1 (no call '${2//$US/ }')" "$(calls | tr "$US" ' ')"; fi
}
no_bare() {  # <label>: every -t target is an exact one, and pane-level commands end with a colon
  local label="$1" badline=""
  while IFS= read -r l; do
    IFS="$US" read -r -a a <<< "$l"
    local cmd="${a[0]}" i tgt=""
    for i in "${!a[@]}"; do [ "${a[$i]}" = "-t" ] && tgt="${a[$((i+1))]}"; done
    [ -n "$tgt" ] || continue
    case "$tgt" in =*) ;; *) badline="$l (not an exact target)" ;; esac
    case "$cmd" in
      has-session|kill-session) case "$tgt" in *:) badline="$l (session-level target has a colon)" ;; esac ;;
      send-keys|display-message|list-panes) case "$tgt" in *:) ;; *) badline="$l (pane-level target has no colon)" ;; esac ;;
    esac
  done < <(calls)
  [ -z "$badline" ] && ok "$label" || bad "$label" "${badline//$US/ }"
}

# --- rc_launch, create ---------------------------------------------------------------------
reset
out="$(rc_launch Dev "$T/work" "$SID" 2>&1)"
line_is "launch: has-session uses =NAME" "has-session${US}-t${US}=Dev"
line_is "launch: new-session names the session and its dir" "new-session${US}-d${US}-s${US}Dev${US}-c${US}$T/work"
line_is "launch: the readiness wait asks list-panes for =NAME:" "list-panes${US}-t${US}=Dev:"
LAUNCH="set -a; source '$RC_ENVFILE' 2>/dev/null; set +a; claude --remote-control 'Dev' --session-id '$SID'"
line_is "launch: send-keys delivers the launch line to =NAME:" "send-keys${US}-t${US}=Dev:${US}$LAUNCH${US}Enter"
line_is "launch: send-keys sends the first-run Enter to =NAME:" "send-keys${US}-t${US}=Dev:${US}Enter"
line_is "launch: display-message reads the pane dir from =NAME:" "display-message${US}-p${US}-t${US}=Dev:${US}-F${US}#{pane_current_path}"
no_bare "launch: no -t target is bare, pane-level ones end in a colon, session-level ones do not"
case "$out" in *"OK name=Dev cwd=$T/work session_id=$SID mode=create"*) ok "launch: the status line reports the pane dir and mode=create" ;; *) bad "launch: status line" "$out" ;; esac

# --- rc_launch, failed tmux steps -----------------------------------------------------------
for stage in create pane launch enter; do
  reset
  out="$(TMUX_FAIL="$stage" rc_launch Dev "$T/work" "$SID" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && [[ "$out" == *"ERR_TMUX name=Dev"* && "$out" != *"OK name=Dev"* ]]; then
    ok "launch: a failed $stage step returns an error"
  else
    bad "launch: a failed $stage step was reported as success" "rc=$rc $out"
  fi
done
reset
TMUX_FAIL=pane rc_launch Dev "$T/work" "$SID" >/dev/null 2>&1
if calls | grep -q "^send-keys$US"; then
  bad "launch: attempted to send input after the pane wait expired"
else
  ok "launch: no input is sent after the pane wait expires"
fi

# --- rc_launch, resume under a secondary profile --------------------------------------------
mkdir -p "$T/prof/projects/p"; : > "$T/prof/projects/p/$SID.jsonl"
reset
out="$(rc_launch Dev "$T/work" "$SID" "$T/prof" 2>&1)"
line_is "resume: the launch line (resume flag, profile prefix) goes to =NAME:" "send-keys${US}-t${US}=Dev:${US}set -a; source '$RC_ENVFILE' 2>/dev/null; set +a; CLAUDE_CONFIG_DIR='$T/prof' claude --remote-control 'Dev' -r '$SID'${US}Enter"
no_bare "resume: no -t target is bare"

# --- rc_launch, already running: skipped before any pane command ------------------------------
reset; TMUX_HAS=0
out="$(rc_launch Dev "$T/work" "$SID" 2>&1)"
case "$out" in "SKIP name=Dev (already running)") ok "already running: SKIP" ;; *) bad "already running status" "$out" ;; esac
[ "$(calls | wc -l | tr -d ' ')" = 1 ] && line_is "already running: only has-session =NAME was asked" "has-session${US}-t${US}=Dev" || bad "already running: more than has-session ran" "$(calls | tr "$US" ' ')"

# --- rc_sweep ------------------------------------------------------------------------------------
printf 'Dev\t%s\t%s\n' "$T/work" "$SID" > "$RC_REGISTRY"
reset; TMUX_HAS=0; TMUX_ATTACHED=1
out="$(rc_sweep 2>&1)"
line_is "sweep: has-session uses =NAME" "has-session${US}-t${US}=Dev"
line_is "sweep: the attached probe asks display-message on =NAME:" "display-message${US}-p${US}-t${US}=Dev:${US}#{session_attached}"
printf '%s\n' "$out" | grep -qE '^ +OK +Dev .*live\*' && ok "sweep: an attached session reads as OK, live*" || bad "sweep: attached row" "$out"
no_bare "sweep: no -t target is bare"
reset; TMUX_HAS=0; TMUX_ATTACHED=0
out="$(rc_sweep 2>&1)"
printf '%s\n' "$out" | grep -qE '^ +IDLE +Dev ' && ok "sweep: a detached session reads as IDLE" || bad "sweep: detached row" "$out"

# --- rc_archive (kills the session by its exact name) ----------------------------------------------
printf 'Dev\t%s\t%s\n' "$T/work" "$SID" > "$RC_REGISTRY"
reset; TMUX_HAS=0
out="$(rc_archive Dev 2>&1)"
line_is "archive: has-session uses =NAME" "has-session${US}-t${US}=Dev"
line_is "archive: kill-session uses =NAME (no colon)" "kill-session${US}-t${US}=Dev"
no_bare "archive: no -t target is bare"

# --- new-remote-claude.sh, the already-running branch -------------------------------------------------
reset; TMUX_HAS=0
out="$(TMUX_HAS=0 bash "$RS/new-remote-claude.sh" Dev "$T/work" 2>&1)"; rc=$?   # the stub reads TMUX_HAS from its environment
{ [ "$rc" = 3 ] && case "$out" in *"ERR_EXISTS: a tmux session named 'Dev' is already running (cwd: $T/work)"*) true ;; *) false ;; esac; } \
  && ok "new-remote-claude: an already-running name exits 3 and reports the pane's dir" || bad "new-remote-claude: rc=$rc" "$out"
line_is "new-remote-claude: has-session uses =NAME" "has-session${US}-t${US}=Dev"
line_is "new-remote-claude: display-message reads the dir from =NAME:" "display-message${US}-p${US}-t${US}=Dev:${US}-F${US}#{pane_current_path}"
no_bare "new-remote-claude: no -t target is bare"

echo "remote-claude-targets-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
