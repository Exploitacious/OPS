#!/usr/bin/env bash
# claude-root-wrapper-test.sh: runnable test suite for
# .claude-config/bin/claude-root-wrapper.sh.
#
# Sources the wrapper in throwaway bash subshells with a fake `claude` binary
# first on PATH and an `id()` override to simulate root, all under a mktemp
# HOME and CLAUDE_CONFIG_DIR (NEVER touches a live config dir or rc), then
# asserts:
#   - root gets --permission-mode auto injected; non-root does not
#   - ultracode --settings is injected once, and skipped when the caller
#     passes its own --settings
#   - root, CLAUDE_SHARED_HOST, and the legacy AC_SHARED_HOST alias each run
#     claude under the instance flock
#   - a held lock makes the wrapper print the conflict (pgrep -l, never the
#     full-argv -af form) and return 1
#   - a non-root call with no shared-host signal takes no lock
#   - a missing binary returns 127 and names the wrapper's real path
#
# Run:  bash ~/OPS/.claude-config/bin/tests/claude-root-wrapper-test.sh
# Exit: 0 = all pass; non-zero on first failure.
set -uo pipefail

WRAPPER="$(cd "$(dirname "$0")/.." && pwd)/claude-root-wrapper.sh"
[ -f "$WRAPPER" ] || { echo "FAIL: wrapper missing at $WRAPPER" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "FAIL: flock not installed; the lock cases cannot run" >&2; exit 1; }

TDIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-root-wrapper-test.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- Fixture: a fake claude that reports its argv and whether the instance
# lock is held by its parent. flock(2) locks on separate open file
# descriptions conflict, so a held lock makes the probe's `flock -n` fail.
mkdir -p "$TDIR/bin" "$TDIR/home" "$TDIR/cfg"
cat > "$TDIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
lock="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.instance.lock"
held=0
if [ -e "$lock" ] && ! flock -n "$lock" true; then held=1; fi
printf 'ARGS:%s\n' "$*"
printf 'HELD:%s\n' "$held"
EOF
chmod +x "$TDIR/bin/claude"
LOCK="$TDIR/cfg/.instance.lock"

# run_wrapper <uid> <cmd...>: source the wrapper in a clean bash with the
# fake binary on PATH, simulate <uid> via an id() override, run <cmd...>.
# Prints the command's output; the subshell's exit code is the command's.
run_wrapper() {
  local uid="$1"; shift
  env -i PATH="$TDIR/bin:/usr/bin:/bin" HOME="$TDIR/home" \
    CLAUDE_CONFIG_DIR="$TDIR/cfg" ${EXTRA_ENV:-} \
    "${TEST_SHELL:-bash}" -c '
      uid="$1"; shift
      id() { if [ "${1:-}" = "-u" ]; then echo "$uid"; else command id "$@"; fi; }
      source "$0"
      "$@"
    ' "$WRAPPER" "$uid" "$@"
}

# --- Root: permission-mode auto + ultracode, under the lock. ---------------
rm -f "$LOCK"
out="$(run_wrapper 0 claude --print hi)" || fail "root call returned non-zero: $out"
printf '%s\n' "$out" | grep -qxF 'ARGS:--permission-mode auto --settings {"ultracode":true} --print hi' \
  || fail "root argv wrong: $out"
pass "root gets --permission-mode auto and ultracode --settings"
printf '%s\n' "$out" | grep -qxF 'HELD:1' || fail "root call did not run under the lock: $out"
[ -e "$LOCK" ] || fail "root call did not create the lockfile"
pass "root runs under the instance lock"

# --- First use and unavailable locking must never launch without a lock. ----
out="$(run_wrapper 0 eval 'export CLAUDE_CONFIG_DIR="$HOME/new config"; claude')"; rc=$?
[ "$rc" -eq 0 ] || fail "first use of a config dir failed: $out"
printf '%s\n' "$out" | grep -qxF 'HELD:1' || fail "new config dir ran without a lock: $out"
pass "first use creates the config dir and takes the instance lock"

out="$(run_wrapper 0 eval '
  command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = flock ]; then return 1; fi
    builtin command "$@"
  }
  claude
' 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "missing flock returned $rc, want 1: $out"
printf '%s\n' "$out" | grep -qF 'flock is required' || fail "missing flock was not explained: $out"
printf '%s\n' "$out" | grep -q '^ARGS:' && fail "binary ran without flock: $out"
pass "missing flock fails closed with a diagnostic"

out="$(run_wrapper 0 eval '
  export CLAUDE_CONFIG_DIR="$HOME/config-file"
  : > "$CLAUDE_CONFIG_DIR"
  claude
' 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "unusable config dir returned $rc, want 1: $out"
printf '%s\n' "$out" | grep -q '^ARGS:' && fail "binary ran with an unusable lock directory: $out"
pass "an unusable config dir fails closed"

# --- Caller --settings wins; no double --settings. --------------------------
out="$(run_wrapper 0 claude --settings '{"x":1}')" || fail "root --settings call non-zero: $out"
printf '%s\n' "$out" | grep -qxF 'ARGS:--permission-mode auto --settings {"x":1}' \
  || fail "caller --settings not honored or doubled: $out"
pass "caller --settings suppresses the ultracode injection"

# --- Re-source after the move while an older claude() still exists. ---------
# A fallback stub prevents this regression test from launching a real binary
# if source-time resolution accidentally chooses the old shell function.
mkdir -p "$TDIR/home/.local/bin"
printf '#!/bin/sh\necho WRONG_FALLBACK\nexit 97\n' > "$TDIR/home/.local/bin/claude"
chmod +x "$TDIR/home/.local/bin/claude"
for test_shell in bash zsh; do
  if ! command -v "$test_shell" >/dev/null 2>&1; then
    echo "SKIP: re-source in $test_shell (shell not installed)"
    continue
  fi
  out="$(TEST_SHELL="$test_shell" run_wrapper 0 eval 'source "$0"; claude --print hi')"; rc=$?
  [ "$rc" -eq 0 ] || fail "$test_shell re-source lost the PATH binary: rc=$rc $out"
  printf '%s\n' "$out" | grep -qxF 'ARGS:--permission-mode auto --settings {"ultracode":true} --print hi' \
    || fail "$test_shell re-source argv wrong: $out"
  printf '%s\n' "$out" | grep -qxF 'HELD:1' || fail "$test_shell re-source lost the lock: $out"
  pass "$test_shell re-source resolves the PATH binary through an existing claude function"
done
rm "$TDIR/home/.local/bin/claude"

# --- Non-root, no shared-host signal: no lock, no permission-mode. ----------
rm -f "$LOCK"
out="$(run_wrapper 1000 claude --print hi)" || fail "non-root call non-zero: $out"
printf '%s\n' "$out" | grep -qxF 'ARGS:--settings {"ultracode":true} --print hi' \
  || fail "non-root argv wrong (permission-mode leaked?): $out"
printf '%s\n' "$out" | grep -qxF 'HELD:0' || fail "non-root plain call ran under a lock: $out"
[ -e "$LOCK" ] && fail "non-root plain call created the lockfile"
pass "non-root plain call takes no lock and gets no permission-mode"

# --- CLAUDE_SHARED_HOST and the legacy AC_SHARED_HOST alias each lock. ------
for var in CLAUDE_SHARED_HOST AC_SHARED_HOST; do
  rm -f "$LOCK"
  out="$(EXTRA_ENV="$var=1" run_wrapper 1000 claude)" || fail "$var call non-zero: $out"
  printf '%s\n' "$out" | grep -qxF 'HELD:1' || fail "$var=1 did not lock: $out"
  printf '%s\n' "$out" | grep -qF -- '--permission-mode' && fail "$var=1 non-root got permission-mode: $out"
  pass "$var=1 on a non-root call runs under the lock"
done

# --- Held lock: conflict message, return 1, binary never runs. --------------
touch "$LOCK"
exec 9>"$LOCK"
flock -n 9 || fail "test could not take the fixture lock"
out="$(run_wrapper 0 claude 2>&1)"; rc=$?
exec 9>&-
[ "$rc" -eq 1 ] || fail "held lock returned $rc, want 1: $out"
printf '%s\n' "$out" | grep -qF 'another claude session is already running' \
  || fail "held lock printed no conflict message: $out"
printf '%s\n' "$out" | grep -qF 'pgrep -l claude' || fail "conflict hint is not pgrep -l: $out"
printf '%s\n' "$out" | grep -qF 'pgrep -af' && fail "conflict hint still suggests full-argv pgrep -af: $out"
printf '%s\n' "$out" | grep -q '^ARGS:' && fail "binary ran despite the held lock: $out"
pass "held lock returns 1 with the conflict message and a pgrep -l hint"

# --- Missing binary: 127 and the wrapper's real absolute path. --------------
# The wrapper's lazy fallback probes /usr/local/bin and /usr/bin; if a real
# claude lives there this case would launch it, so it is reported as skipped
# instead (the other cases never reach the fallback: the fake is on PATH).
if [ -x /usr/local/bin/claude ] || [ -x /usr/bin/claude ]; then
  echo "SKIP: missing-binary case (a real claude is installed in /usr/local/bin or /usr/bin)"
else
  out="$(env -i PATH="/nonexistent" HOME="$TDIR/home" "$BASH" -c 'source "$0"; claude' "$WRAPPER" 2>&1)"; rc=$?
  [ "$rc" -eq 127 ] || fail "missing binary returned $rc, want 127: $out"
  printf '%s\n' "$out" | grep -qF "source $WRAPPER" || fail "missing-binary hint does not name $WRAPPER: $out"
  pass "missing binary returns 127 and names the wrapper's real path"
fi

echo "ALL PASS"
