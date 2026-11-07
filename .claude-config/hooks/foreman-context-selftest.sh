#!/usr/bin/env bash
# foreman-context-selftest.sh: prove foreman-context.sh prints CONTEXT/foreman.md
# for a foreman and prints nothing for a lane, and that every failure mode degrades
# the way the hook documents. Run by hand or from a gate:
#   .claude-config/hooks/foreman-context-selftest.sh
#
# Hermetic: the hook finds its root from its own path, so each case builds a
# private fixture root (a copy of the hook and hooklib.sh, a fixture
# CONTEXT/foreman.md, and a stub bin/lane-class that answers whatever the case
# sets) under a mktemp directory. HOME points inside it, so nothing reads or writes
# the box's real hook state. The real foreman.md, when this checkout has one, is
# checked separately for its size and read through the hook whole.
#
# Exit 0 = every case behaves; 1 = a defect.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

export HOME="$WORK/home"; mkdir -p "$HOME"
unset OPS_LANE_CLASS T3CODE_THREAD_ID CLAUDE_CODE_SESSION_ID

# make_root <name>: a fixture root with the hook, hooklib, a foreman.md, and a
# lane-class stub that prints the content of <root>/.class (exit 0).
make_root() {
  local r="$WORK/$1"
  mkdir -p "$r/.claude-config/hooks" "$r/.claude-config/bin" "$r/CONTEXT"
  cp "$SELF_DIR/foreman-context.sh" "$SELF_DIR/hooklib.sh" "$r/.claude-config/hooks/"
  printf '# Foreman doctrine\n\nFIXTURE RULE ONE.\nFIXTURE RULE TWO.\n' > "$r/CONTEXT/foreman.md"
  cat > "$r/.claude-config/bin/lane-class" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
cat "$(dirname "$0")/../../.class" 2>/dev/null
exit 0
STUB
  chmod +x "$r/.claude-config/bin/lane-class" "$r/.claude-config/hooks/foreman-context.sh"
  printf 'foreman\n' > "$r/.class"
  printf '%s' "$r"
}
# run_hook <root> [payload]: stdout of the hook; its exit code lands in $RC.
RC=0
run_hook() {
  local out
  out="$(printf '%s' "${2:-}" | "$1/.claude-config/hooks/foreman-context.sh" 2>"$WORK/stderr")"
  RC=$?
  printf '%s' "$out"
}
expect_silent() { # <label> <output>
  if [ -z "$2" ] && [ "$RC" -eq 0 ]; then pass "$1"; else fail "$1 (rc=$RC, printed: ${2:0:80})"; fi
}

# 1. A foreman gets the whole file, on every SessionStart source.
R="$(make_root foreman)"
for src in startup resume clear compact; do
  got="$(run_hook "$R" "{\"source\":\"$src\",\"session_id\":\"s-$src\"}")"
  if [ "$RC" -eq 0 ] && [ "$got" = "$(cat "$R/CONTEXT/foreman.md")" ]; then pass "foreman prints foreman.md (source $src)"
  else fail "foreman prints foreman.md (source $src; rc=$RC)"; fi
done
got="$(run_hook "$R" "")"
[ "$got" = "$(cat "$R/CONTEXT/foreman.md")" ] && pass "foreman prints with an empty payload" || fail "foreman prints with an empty payload"

# 2. Lanes get nothing: both lane classes lane-class can report.
for cls in t3-lane agent-lane; do
  R="$(make_root "lane-$cls")"; printf '%s\n' "$cls" > "$R/.class"
  expect_silent "$cls prints nothing" "$(run_hook "$R" '{"source":"startup","session_id":"s1"}')"
done

# 3. The real lane-class (when this checkout has one) keeps the file out of a subagent
# and a delegated lane, and leaves a foreman's alone.
if [ -x "$SELF_DIR/../bin/lane-class" ]; then
  R="$(make_root reallc)"; cp "$SELF_DIR/../bin/lane-class" "$R/.claude-config/bin/lane-class"
  expect_silent "a payload with an agent_id prints nothing (the real lane-class)" \
    "$(run_hook "$R" '{"source":"startup","session_id":"s2","agent_id":"a-1"}')"
  out="$(printf '%s' '{"source":"startup","session_id":"s3"}' | OPS_LANE_CLASS=t3-lane "$R/.claude-config/hooks/foreman-context.sh" 2>/dev/null)"
  [ -z "$out" ] && pass "OPS_LANE_CLASS=t3-lane prints nothing (the real lane-class)" || fail "OPS_LANE_CLASS=t3-lane printed"
  got="$(run_hook "$R" '{"source":"startup","session_id":"s4"}')"
  [ "$got" = "$(cat "$R/CONTEXT/foreman.md")" ] && pass "a plain startup payload prints (the real lane-class)" || fail "a plain startup payload did not print"
else
  printf 'ok   (skip) no bin/lane-class beside this hook: real-classifier cases not run\n'
fi

# 4. Degraded lane-class: foreman is the documented default.
R="$(make_root nolc)"; rm -f "$R/.claude-config/bin/lane-class"
got="$(run_hook "$R" '{"source":"startup"}')"
[ "$RC" -eq 0 ] && [ -n "$got" ] && pass "missing lane-class degrades to foreman" || fail "missing lane-class degrades to foreman (rc=$RC)"

R="$(make_root lcgarbage)"
printf '#!/usr/bin/env bash\necho "not a class"; exit 7\n' > "$R/.claude-config/bin/lane-class"
got="$(run_hook "$R" '{"source":"startup"}')"
[ "$RC" -eq 0 ] && [ -n "$got" ] && pass "failing lane-class degrades to foreman" || fail "failing lane-class degrades to foreman (rc=$RC)"

R="$(make_root lcslow)"
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$R/.claude-config/bin/lane-class"
start=$SECONDS
got="$(run_hook "$R" '{"source":"startup"}')"
if [ "$RC" -eq 0 ] && [ -n "$got" ] && [ $((SECONDS - start)) -le 8 ]; then pass "hung lane-class is cut and degrades to foreman"
else fail "hung lane-class is cut and degrades to foreman (rc=$RC, $((SECONDS - start)) s)"; fi

# 5. The file: missing, empty, and over the limit print nothing, exit 0. The limit is
# 8192 bytes, verify-ops check 19's SessionStart budget; the two edge cases pin the
# hook's own constant to it (exactly 8192 prints, 8193 does not).
R="$(make_root nofile)"; rm -f "$R/CONTEXT/foreman.md"
expect_silent "missing foreman.md prints nothing (an older template, or a copy not yet synced)" "$(run_hook "$R" '{"source":"startup"}')"
R="$(make_root empty)"; : > "$R/CONTEXT/foreman.md"
expect_silent "empty foreman.md prints nothing" "$(run_hook "$R" '{"source":"startup"}')"
R="$(make_root big)"; { printf '# Foreman doctrine\n'; head -c $((8193 - 19)) /dev/zero | tr '\0' 'x'; } > "$R/CONTEXT/foreman.md"
[ "$(wc -c < "$R/CONTEXT/foreman.md" | tr -d ' ')" -eq 8193 ] || fail "fixture is not 8193 bytes"
expect_silent "foreman.md of 8193 bytes prints nothing (the core.md fallback fires)" "$(run_hook "$R" '{"source":"startup"}')"
R="$(make_root edge)"; { printf '# Foreman doctrine\n'; head -c $((8192 - 19)) /dev/zero | tr '\0' 'x'; } > "$R/CONTEXT/foreman.md"
[ "$(wc -c < "$R/CONTEXT/foreman.md" | tr -d ' ')" -eq 8192 ] || fail "fixture is not 8192 bytes"
got="$(run_hook "$R" '{"source":"startup"}')"
[ "$RC" -eq 0 ] && [ -n "$got" ] && pass "foreman.md of exactly 8192 bytes prints" || fail "foreman.md of exactly 8192 bytes prints (rc=$RC)"

# 6. The real file, when this checkout has one: within the 8192-byte limit and printed
# whole for a foreman, nothing for a lane. A checkout without CONTEXT/foreman.md (an
# older template) skips this section: the hook's own no-file case is case 5.
real="$REAL_ROOT/CONTEXT/foreman.md"
if [ -f "$real" ]; then
  sz="$(wc -c < "$real" | tr -d ' ')"
  [ "$sz" -le 8192 ] && pass "real foreman.md is $sz bytes (limit 8192)" || fail "real foreman.md is $sz bytes, over the 8192 limit"
  R="$(make_root real)"; cp "$real" "$R/CONTEXT/foreman.md"
  got="$(run_hook "$R" '{"source":"resume","session_id":"s9"}')"
  [ "$RC" -eq 0 ] && [ "$got" = "$(cat "$real")" ] && pass "hook prints the real foreman.md whole for a foreman" || fail "hook prints the real foreman.md whole (rc=$RC)"
  R="$(make_root reallane)"; cp "$real" "$R/CONTEXT/foreman.md"; printf 't3-lane\n' > "$R/.class"
  expect_silent "hook prints none of the real foreman.md for a lane" "$(run_hook "$R" '{"source":"resume","session_id":"s9"}')"
else
  printf 'ok   (skip) no CONTEXT/foreman.md in this checkout: real-file cases not run\n'
fi

# 7. Nothing on stderr leaks into a normal foreman run.
R="$(make_root quiet)"
run_hook "$R" '{"source":"startup"}' >/dev/null
[ ! -s "$WORK/stderr" ] && pass "no stderr on a normal foreman run" || fail "stderr on a normal run: $(head -c 120 "$WORK/stderr")"

if [ "$fails" -eq 0 ]; then echo "foreman-context-selftest: all cases pass"; exit 0; fi
echo "foreman-context-selftest: $fails case(s) FAILED"
exit 1
