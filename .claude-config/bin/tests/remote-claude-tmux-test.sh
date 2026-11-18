#!/usr/bin/env bash
# remote-claude-tmux-test.sh: rc_launch delivers its launch line to the exact pane on a REAL
# tmux server, with a sibling session whose name starts with the same letters
# (remote-sessions/lib-remote-claude.sh). remote-claude-targets-test.sh pins the argv of
# every call offline; this proves the argv does what it claims, because the defect was
# tmux-version behavior no stub reproduces: on tmux 3.5a and 3.6 `send-keys -t =NAME`
# fails with "can't find pane" (the launch line was silently lost and the session was a
# bare shell), and `display-message -t =NAME` prints an empty value.
#
# Everything runs on a private tmux server reached only through `tmux -L <unique socket>`
# (with TMUX_TMPDIR and TMUX unset or fixture), so the operator's own tmux is never touched.
# A stub `claude` on the fixture's PATH records that it was started and with which
# arguments; the env file, registry and archive are synthetic. The server is stopped, by its
# socket only, on exit.
#
# Pinned: rc_launch of "Dev" while "Dev2" is running starts the stub claude once, in the
# workdir, with the remote-control name and session id; the launch line appears in Dev's pane
# and never in Dev2's; the status line carries the pane's dir (an empty dir reads "unknown");
# rc_archive of Dev kills Dev and leaves Dev2 running. Also recorded, not asserted (the
# behavior is tmux-version dependent): whether the old bare target fails on this tmux.
#
# Usage: remote-claude-tmux-test.sh    (exit 0 all pass, 1 otherwise, 77 did not run: no tmux)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
RS="$HERE/../../remote-sessions"
command -v tmux >/dev/null 2>&1 || { echo "remote-claude-tmux-test: did not run: no tmux"; exit 77; }
command -v bash >/dev/null 2>&1 || { echo "remote-claude-tmux-test: did not run: no bash"; exit 77; }
[ -f "$RS/lib-remote-claude.sh" ] || { echo "FAIL: lib-remote-claude.sh missing"; exit 1; }

REAL_TMUX="$(command -v tmux)"   # the binary itself: env(1) cannot run a shell builtin or function
T="$(mktemp -d)"
SOCK="rc-targets-test-$$-$RANDOM"
SERVER_UP=0
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
  # Stop only the server this test started, by its own socket name.
  [ "$SERVER_UP" = 1 ] && "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }

echo "remote-claude-tmux-test:"
unset TMUX
export TMUX_TMPDIR="$T/tmuxtmp"; mkdir -p "$TMUX_TMPDIR"
mkdir -p "$T/home/.local/bin" "$T/home/.claude/projects" "$T/work"
export HOME="$T/home" RC_ENVFILE="$T/env.sh" RC_REGISTRY="$T/registry.tsv" RC_ARCHIVE="$T/archive.tsv" \
  RC_DEFAULT_WORKDIR="$T/work" CLAUDE_STUB_LOG="$T/claude.log"
printf 'export CLAUDE_STUB_LOG=%q\n' "$CLAUDE_STUB_LOG" > "$RC_ENVFILE"
# The stub claude: record the arguments and the directory, then hold the pane.
cat > "$HOME/.local/bin/claude" <<'EOF'
#!/bin/bash
printf 'args=%s pwd=%s\n' "$*" "$PWD" >> "${CLAUDE_STUB_LOG:-/dev/null}"
exec sleep 120
EOF
chmod +x "$HOME/.local/bin/claude"

# Every tmux call in this test, the lib's included, goes to the private server.
tmux() { "$REAL_TMUX" -L "$SOCK" "$@"; }
export REAL_TMUX SOCK
export -f tmux
# shellcheck source=/dev/null
. "$RS/lib-remote-claude.sh"   # puts the system dirs first on PATH; $HOME/.local/bin (the stub) leads
[ "$(type -t tmux)" = function ] || { echo "FAIL: the private-socket tmux wrapper is not in force; refusing to go on"; exit 1; }
# rc_launch waits 12 s for a real claude; poll for the stub instead.
sleep() { command sleep 0.2; }

# Start the private server with a plain bash in every pane (no user shell rc), HOME and PATH
# from the fixture, then a sibling session whose name Dev is a prefix of.
env -i HOME="$HOME" PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" TERM=xterm TMUX_TMPDIR="$TMUX_TMPDIR" \
  "$REAL_TMUX" -L "$SOCK" -f /dev/null new-session -d -s Anchor -c "$T/work" "sleep 300" 2>"$T/server.err"
if ! tmux has-session -t "=Anchor" 2>/dev/null; then
  echo "remote-claude-tmux-test: did not run: tmux cannot start a private server here ($(tr '\n' ' ' < "$T/server.err"))"
  exit 77
fi
SERVER_UP=1
tmux set -g default-command "bash --norc --noprofile"
tmux new-session -d -s Dev2 -c "$T/work"
echo "tmux $("$REAL_TMUX" -V | awk '{print $2}'), private socket $SOCK"

# What the old bare target does on this tmux (recorded, not asserted).
tmux new-session -d -s Probe -c "$T/work"
if tmux send-keys -t "=Probe" "true" Enter 2>"$T/old.err"; then
  echo "NOTE: this tmux accepts send-keys -t =NAME; the missed delivery is not reproducible here"
else
  echo "NOTE: this tmux rejects send-keys -t =NAME ($(tr -d '\n' < "$T/old.err")): the defect this test guards is live here"
fi
[ -z "$(tmux display-message -p -t '=Probe' '#{pane_current_path}' 2>/dev/null)" ] \
  && echo "NOTE: display-message -t =NAME prints an empty value here"
tmux kill-session -t "=Probe"

# --- rc_launch of Dev while Dev2 runs -------------------------------------------------------------
SID="11111111-2222-3333-4444-555555555555"
out="$(rc_launch Dev "$T/work" "$SID" 2>&1)"
# the stub writes its record when the pane shell runs the launch line; wait for it (bounded)
for _ in $(seq 50); do [ -s "$CLAUDE_STUB_LOG" ] && break; command sleep 0.1; done
[ "$(grep -c . "$CLAUDE_STUB_LOG" 2>/dev/null)" = 1 ] && ok "launch: the stub claude was started exactly once" || bad "launch: stub claude starts: $(grep -c . "$CLAUDE_STUB_LOG" 2>/dev/null || echo 0)" "$(cat "$CLAUDE_STUB_LOG" 2>/dev/null)"
grep -q "args=--remote-control Dev --session-id $SID pwd=$T/work\$" "$CLAUDE_STUB_LOG" 2>/dev/null \
  && ok "launch: it ran in the workdir with the remote-control name and the new session id" || bad "launch: stub arguments" "$(cat "$CLAUDE_STUB_LOG" 2>/dev/null)"
dev_pane="$(tmux capture-pane -p -J -t '=Dev:' 2>/dev/null)"
dev2_pane="$(tmux capture-pane -p -J -t '=Dev2:' 2>/dev/null)"
case "$dev_pane" in *"claude --remote-control 'Dev'"*) ok "launch: the launch line is in Dev's pane" ;; *) bad "launch: Dev's pane has no launch line" "$dev_pane" ;; esac
case "$dev2_pane" in *"claude"*|*"remote-control"*) bad "launch: the launch line reached the prefix-sharing sibling Dev2" "$dev2_pane" ;; *) ok "launch: nothing reached the prefix-sharing sibling Dev2's pane" ;; esac
case "$out" in *"OK name=Dev cwd=$T/work session_id=$SID mode=create"*) ok "launch: the status line carries the pane's dir (display-message resolved)" ;; *) bad "launch: status line" "$out" ;; esac

# --- rc_archive of Dev kills Dev only ---------------------------------------------------------------
rc_register Dev "$T/work" "$SID"   # rc_launch does not register; new-remote-claude.sh does, and archive reads the registry
out="$(rc_archive Dev 2>&1)"
tmux has-session -t "=Dev" 2>/dev/null && bad "archive: Dev is still running" "$out" || ok "archive: Dev was killed"
tmux has-session -t "=Dev2" 2>/dev/null && ok "archive: the prefix-sharing sibling Dev2 is still running" || bad "archive: Dev2 was killed too" "$out"

echo "remote-claude-tmux-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
