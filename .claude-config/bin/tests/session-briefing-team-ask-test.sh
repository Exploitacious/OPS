#!/usr/bin/env bash
# session-briefing-team-ask-test.sh: behavior tests for the "Team asks:" line in the boot
# briefing (hooks/session-briefing.sh team_ask_line).
#
# Why pin these: on a team's boxes, an ask from a teammate's agent that needs the owner
# opens an investigation thread on the owner's box. That thread is the first surface; this
# line is the second, and the one that does not depend on the thread having opened. An ask
# whose notice was only a log line reached nobody. So the line must say what is waiting, and
# it must NEVER turn a broken reader into silence: "nothing printed" reads as "nobody is
# waiting on you". And it must not hang boot, speak to a lane, repeat itself inside the
# Team asks workspace, or nag a box that was turned off. A copy with no router installed
# (every copy that is not a team box) must see no change at all.
#
# Cases: tool absent (quiet), the provider's line shown as printed, a line without the label
# (labelled), only the first line, control characters stripped, nothing printed (quiet), a hung
# provider (the timeout line within the cap), one that ignores TERM (killed one grace second
# later), a failing provider (partial output not shown), an old CLI without `pending`, a
# dangling link, a file that is not executable, no timeout command, the provider's argv, the
# disable marker (quiet, provider never run), the Team asks workspace as the working folder
# (itself, a subfolder, a symlink to it; provider never run), lanes (t3-lane and agent-lane;
# provider never run), a resumed session (this hook has no short form, so the line prints
# there too), and the banner's shape (the line follows Reminders, inside the rule, one line,
# far under the 8192-byte budget).
#
# Every path the hook reads is under a temp dir (HOME, OPS_DIR, CLAUDE_CONFIG_DIR, OPS_STATE_DIR);
# the provider is a stub that logs each run. The suite carries the sandbox guard because
# session-briefing.sh writes and moves state files.
#
# Usage: session-briefing-team-ask-test.sh    (exit 0 all pass, 1 otherwise)
# Shell snippets inside the stubs are intentionally literal test data.
# shellcheck disable=SC2016
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
HOOK="$HERE/../../hooks/session-briefing.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required (the hook's own parser)"; exit 1; }
TMO="$(command -v gnutimeout || command -v timeout || true)"
[ -n "$TMO" ] || { echo "SKIP: no timeout command (the hook's reader cap)"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }

mkdir -p "$T/home/.local/bin" "$T/home/.config/team-ask" "$T/home/team-asks/sub" "$T/ops/CONTEXT" "$T/cfg/projects" "$T/state" "$T/work"
printf '# Core\n' > "$T/ops/CONTEXT/core.md"
TOOL="$T/home/.local/bin/team-ask"
CALLS="$T/provider-calls.log"
LANE_THREAD='thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Ax'
STARTUP='{"hook_event_name":"SessionStart","source":"startup","session_id":"sess-team-ask-test"}'
LINE='Team asks: 2 need you · Teammate-A TKT-0001 x3 (1d, thread open) · Teammate-B TKT-0002 (5h, thread FAILED: guard_unproven)'

# provider <body>: a stub team-ask whose run is logged (its argv, one line per run) and then
# does <body>. The log is how a case proves the provider was, or was not, started.
provider() {
  rm -f "$TOOL"
  { printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$CALLS"; printf '%s\n' "$1"; } > "$TOOL"
  chmod +x "$TOOL"
}
ran() { [ -s "$CALLS" ]; }

# brief [cwd] [payload] [VAR=value ...]: run the hook hermetically; output in $T/out, rc in $rc.
brief() {
  local cwd="${1:-$T/work}" payload="${2:-$STARTUP}"
  if [ $# -ge 2 ]; then shift 2; else shift $#; fi
  rm -f "$CALLS"
  ( cd "$cwd" && printf '%s' "$payload" | env -u TMUX -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_LANE_CLASS \
      -u OPS_STATE_DIR -u OPS_ORPHAN_SCAN -u T3CODE_HOME \
      HOME="$T/home" OPS_DIR="$T/ops" CLAUDE_CONFIG_DIR="$T/cfg" OPS_STATE_DIR="$T/state" LANE_CLASS_NO_DB=1 "$@" \
      "$TMO" -k 2 60 bash "${HOOK_UNDER_TEST:-$HOOK}" >"$T/out" 2>"$T/err" )  # a hook that hangs fails its case, not the suite
  rc=$?
}
lines() { grep '^ Team asks:' "$T/out"; }
nlines() { grep -c '^ Team asks:' "$T/out"; }

silent() { # <label>
  if [ "$rc" -eq 0 ] && ! lines >/dev/null; then ok "$1"
  else bad "$1 (rc=$rc)" "$(lines || tail -2 "$T/out")"; fi
}
says() { # <label> <exact line>
  if [ "$rc" -eq 0 ] && [ "$(nlines)" = 1 ] && [ "$(lines)" = "$2" ]; then ok "$1"
  else bad "$1 (rc=$rc)" "got:  $(lines || echo '<no Team asks line>')"$'\n'"    want: $2"; fi
}
within() { # <label> <start> <end> <min> <max>: the elapsed seconds sit in the window
  local d=$(($3 - $2))
  if [ "$d" -ge "$4" ] && [ "$d" -le "$5" ]; then ok "$1 (${d}s)"; else bad "$1 took ${d}s, want ${4}s to ${5}s"; fi
}

echo "session-briefing-team-ask-test:"

# --- quiet cases ------------------------------------------------------------------------------
rm -f "$TOOL"; brief
silent "tool absent: no line, exit 0"
grep -q 'SESSION BRIEFING' "$T/out" && ok "tool absent: the rest of the briefing is untouched" || bad "tool absent: the briefing is gone" "$(head -3 "$T/out")"

provider 'exit 0'; brief
silent "provider prints nothing: quiet (nobody is waiting)"
ran && ok "provider prints nothing: it was started (this is a silence, not a skip)" || bad "provider was never started"

# --- the line -------------------------------------------------------------------------------------
provider "printf '%s\n' '$LINE'"; brief
says "the provider's line is shown as printed, indented like the others" " $LINE"
grep -qx 'pending --brief' "$CALLS" && ok "the provider is run with exactly: pending --brief" || bad "provider argv" "$(cat "$CALLS" 2>/dev/null)"

provider "printf '%s\n' '2 need you · Teammate-A TKT-0001 x3 (1d, thread open)'"; brief
says "a line without the label gets it" " Team asks: 2 need you · Teammate-A TKT-0001 x3 (1d, thread open)"

provider "printf '%s\n' '$LINE' 'second line that must not print' 'third'"; brief
says "only the first line prints" " $LINE"
if grep -qE 'second line that must not print|^third$' "$T/out"; then bad "only the first line prints: the provider's later lines reached the banner" "$(grep -n 'second line\|^third$' "$T/out")"
else ok "only the first line prints: none of the later lines reached the banner (not just none labelled Team asks)"; fi

provider 'printf "Team asks: 1 needs you · \033[31mred\033[0m\001 name (1h)\n"'; brief
if [ "$rc" -eq 0 ] && [ "$(nlines)" = 1 ] && ! grep -q "$(printf '\033')" "$T/out" && [ "$(lines)" = " Team asks: 1 needs you · [31mred[0m name (1h)" ]; then
  ok "control characters are stripped (an escape sequence in a name never reaches the screen)"
else bad "control characters (rc=$rc)" "$(lines | od -c | head -3)"; fi

long="$(printf 'x%.0s' $(seq 1 600))"
provider "printf '%s\n' 'Team asks: $long'"; brief
[ "$(lines | wc -c | tr -d ' ')" -le 402 ] && ok "a very long line is capped (400 characters)" || bad "long line not capped" "$(lines | wc -c)"

# --- the banner's shape ------------------------------------------------------------------------
# Reminders is the operator-facing block just above the line; with one reminder present the
# line must follow it and still sit inside the closing rule.
printf '# Reminders\n- check the backup drive\n' > "$T/ops/.claude-reminders.md"
provider "printf '%s\n' '$LINE'"; brief
sz="$(wc -c < "$T/out" | tr -d ' ')"
rm_l="$(grep -n '^ Reminders:' "$T/out" | head -1 | cut -d: -f1)"; ta="$(grep -n '^ Team asks:' "$T/out" | head -1 | cut -d: -f1)"
if [ "$rc" -eq 0 ] && [ "$sz" -lt 8192 ] && [ "$(nlines)" = 1 ] && [ -n "$rm_l" ] && [ -n "$ta" ] && [ "$ta" -gt "$rm_l" ]; then
  ok "one line, after Reminders, hook stdout ${sz}B (under the 8192B budget)"
else bad "shape (rc=$rc, ${sz}B, Reminders line $rm_l, Team asks line $ta)" "$(head -20 "$T/out")"; fi
[ "$(tail -1 "$T/out")" = "============================================================" ] && ok "the line sits inside the banner" || bad "banner closing rule missing"
rm -f "$T/ops/.claude-reminders.md"

# --- a resumed session --------------------------------------------------------------------------
# This hook has no resume short form: a resume prints the whole briefing, so the line must
# be there too (an ask may have arrived while the session was parked).
provider "printf '%s\n' '$LINE'"
RESUME='{"hook_event_name":"SessionStart","source":"resume","session_id":"sess-team-ask-test"}'
brief "$T/work" "$RESUME"
if grep -q 'SESSION BRIEFING' "$T/out"; then
  says "resume: the full briefing carries the line (this hook has no short form)" " $LINE"
else bad "resume did not print the full briefing (the control for the case above)" "$(head -8 "$T/out")"; fi
provider 'exit 0'; brief "$T/work" "$RESUME"
silent "resume: quiet when nothing waits"

# --- never silent when broken -----------------------------------------------------------------------
provider 'exec sleep 30'
t0="$(date +%s)"; brief; t1="$(date +%s)"
if [ "$rc" -eq 0 ] && [ "$(nlines)" = 1 ] && [ "$(lines)" = " Team asks: pending reader timed out after 3 s; run team-ask pending" ]; then
  within "hung provider: the timeout line, boot not held" "$t0" "$t1" 3 9
else bad "hung provider (rc=$rc, took $((t1 - t0))s)" "$(lines || echo '<no Team asks line>')"; fi

provider 'trap "" TERM; while :; do sleep 1; done'
t0="$(date +%s)"; brief; t1="$(date +%s)"
if [ "$rc" -eq 0 ] && [ "$(lines)" = " Team asks: pending reader timed out after 3 s; run team-ask pending" ]; then
  within "a provider that ignores TERM: killed one grace second later, same line" "$t0" "$t1" 3 10
else bad "TERM-proof provider (rc=$rc, took $((t1 - t0))s)" "$(lines || echo '<no Team asks line>')"; fi

provider 'echo "Team asks: partial output that must not show"; exit 3'; brief
says "failing provider: the failure line, not its partial output" " Team asks: pending reader failed (exit 3); run team-ask pending"

provider 'echo "usage: team-ask [-h] {status,list}" >&2; echo "team-ask: error: argument cmd: invalid choice: '"'"'pending'"'"'" >&2; exit 2'; brief
says "an old CLI without pending: visible, never an empty queue" " Team asks: pending reader failed (exit 2); run team-ask pending"

rm -f "$TOOL"; ln -s "$T/home/.local/lib/team-ask/bin/team-ask" "$TOOL"; brief
says "a link left pointing nowhere: a broken install is named" " Team asks: $TOOL is not executable (a broken install); run team-ask pending"
rm -f "$TOOL"; printf '#!/usr/bin/env bash\necho "Team asks: x"\n' > "$TOOL"; chmod 644 "$TOOL"; brief
says "a tool that is not executable: named, not silent" " Team asks: $TOOL is not executable (a broken install); run team-ask pending"

# Hosts without a timeout binary still must not read a missing reader as an empty queue.
# A copy of the hooks and bin trees, so hook_timeout can be made to fail without touching the repo.
mkdir -p "$T/alt"; cp -r "$HERE/../../hooks" "$T/alt/hooks"; mkdir -p "$T/alt/bin"
for f in "$HERE/.."/*; do [ -f "$f" ] && cp -P "$f" "$T/alt/bin/" 2>/dev/null; done
printf '\nhook_timeout() { return 1; }\n' >> "$T/alt/hooks/hooklib.sh"
export HOOK_UNDER_TEST="$T/alt/hooks/session-briefing.sh"
provider "printf '%s\n' '$LINE'"; brief
says "no timeout command: said so, the provider is not run unbounded" " Team asks: pending reader unavailable (no timeout command); run team-ask pending"
ran && bad "no timeout command: the provider ran without a cap" || ok "no timeout command: the provider was not started"
unset HOOK_UNDER_TEST

# --- the disable marker -----------------------------------------------------------------------------------
provider "printf '%s\n' '$LINE'"
printf 'disabled 2026-11-10T20:00:00Z\nreason: this box was retired\n' > "$T/home/.config/team-ask/disabled"
brief
silent "disable marker: quiet"
ran && bad "disable marker: the provider was started anyway" || ok "disable marker: the provider was not started (the marker is read first)"
rm -f "$T/home/.config/team-ask/disabled"; brief
says "control: the marker removed, the line is back" " $LINE"

# --- the Team asks workspace ------------------------------------------------------------------------------
brief "$T/home/team-asks"
silent "session folder is ~/team-asks: quiet"
ran && bad "~/team-asks: the provider was started" || ok "~/team-asks: the provider was not started"
brief "$T/home/team-asks/sub"
silent "a subfolder of ~/team-asks: quiet"
ln -s "$T/home/team-asks" "$T/via-link"
brief "$T/via-link"
silent "a symlink that resolves to ~/team-asks: quiet"
# The logical folder counts too: a link INSIDE ~/team-asks that points elsewhere still has a
# working folder, as the session names it, under the workspace (the physical path does not).
ln -s "$T/work" "$T/home/team-asks/to-work"
brief "$T/home/team-asks/to-work"
silent "a link inside ~/team-asks that points elsewhere: the session's own path is under the workspace, quiet"
ran && bad "link inside ~/team-asks: the provider was started" || ok "link inside ~/team-asks: the provider was not started"
mkdir -p "$T/home/team-asks-other"
brief "$T/home/team-asks-other"
says "a sibling whose name only starts with team-asks: not the workspace, the line prints" " $LINE"
brief "$T/work"
says "control: any other folder prints the line" " $LINE"

# --- lanes ----------------------------------------------------------------------------------------------------
brief "$T/work" "$STARTUP" T3CODE_THREAD_ID="$LANE_THREAD"
if [ "$rc" -eq 0 ] && [ "$(grep -c . "$T/out")" -eq 1 ] && grep -q 't3-lane session' "$T/out" && ! lines >/dev/null; then ok "t3-lane: one line, no Team asks line"
else bad "t3-lane (rc=$rc)" "$(cat "$T/out")"; fi
ran && bad "t3-lane: the provider was started" || ok "t3-lane: the provider was not started (the lane gate exits first)"
brief "$T/work" '{"hook_event_name":"SessionStart","source":"startup","session_id":"s","agent_id":"agent-9"}'
if [ "$rc" -eq 0 ] && [ "$(grep -c . "$T/out")" -eq 1 ] && grep -q 'agent-lane session' "$T/out" && ! lines >/dev/null; then ok "agent-lane: one line, no Team asks line"
else bad "agent-lane (rc=$rc)" "$(cat "$T/out")"; fi
ran && bad "agent-lane: the provider was started" || ok "agent-lane: the provider was not started"
brief "$T/work" "$STARTUP" OPS_LANE_CLASS=t3-lane
{ ! lines >/dev/null && ! ran; } && ok "OPS_LANE_CLASS=t3-lane: silent, provider not started" || bad "forced lane still spoke" "$(cat "$T/out")"

echo
echo "session-briefing-team-ask-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
