#!/usr/bin/env bash
# await-test.sh: behavior tests for bin/await, the wait helper that replaces
# `sleep N; check` (a pattern Claude Code refuses).
#
# Pinned: a check that passes returns 0 at once and passes its stdout through; a
# check that turns true later returns 0 after more than one attempt; a check that
# never passes returns 124 at the deadline with its last output on stderr; a check
# that hangs is stopped at the deadline instead of holding the wait; a missing
# command returns 127 without waiting out the clock; usage errors return 2; a lone
# argument with shell syntax runs under bash -c; --pid and --file/--grep wait on a
# process and a log line; -q and -v change only the chatter; TERM ends the wait and
# the running check with it.
#
# Time bounds are generous (a loaded box must not flake this), and each background
# process the test starts is killed by its exact PID, never by a pattern: other
# sessions run suites on the same box.
#
# Usage: await-test.sh    (exit 0 all pass, 1 otherwise)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
AW="${AWAIT_UNDER_TEST:-$HERE/../await}"
[ -x "$AW" ] || { echo "FAIL: $AW missing or not executable"; exit 1; }

T="$(mktemp -d)"; BG=()
cleanup() { local p; for p in "${BG[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }
ms_now() { date +%s%N | cut -c1-13; }

# run <args...>: sets rc, out, err and ms (wall time).
run() {
  local t0 t1
  t0="$(ms_now)"
  out="$("$AW" "$@" 2>"$T/err")"; rc=$?
  t1="$(ms_now)"; ms=$(( t1 - t0 )); err="$(cat "$T/err")"
}

echo "await-test:"

# 1. passes at once
run --timeout 5 --every 0.2 -- true
{ [ "$rc" -eq 0 ] && [ "$ms" -lt 1500 ] && [[ "$err" == *"condition met after 0 s (1 attempt)"* ]]; } \
  && ok "a passing check returns 0 at once (${ms} ms)" || bad "passing check: rc=$rc ms=$ms err=$err"

# 2. the successful attempt's stdout passes through; failed attempts stay silent
echo 0 > "$T/count"
cat > "$T/third.sh" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$1") + 1 )); echo "$n" > "$1"
echo "attempt $n output"
[ "$n" -ge 3 ]
SH
chmod +x "$T/third.sh"
run --timeout 10 --every 0.1 -- "$T/third.sh" "$T/count"
{ [ "$rc" -eq 0 ] && [ "$out" = "attempt 3 output" ] && [[ "$err" == *"3 attempts"* ]]; } \
  && ok "a check that turns true on attempt 3: exit 0, only the winning attempt's stdout, '3 attempts'" \
  || bad "third-attempt check: rc=$rc out='$out' err='$err'"

# 3. a condition that becomes true while waiting (a file appears)
rm -f "$T/appears"
( sleep 0.6; : > "$T/appears" ) & BG+=("$!")
run --timeout 10 --every 0.2 -- test -e "$T/appears"
{ [ "$rc" -eq 0 ] && [ "$ms" -ge 500 ] && [ "$ms" -lt 6000 ]; } \
  && ok "waits for a file to appear (${ms} ms)" || bad "file wait: rc=$rc ms=$ms err=$err"

# 4. never true: 124 at the deadline, with the last output
run --timeout 1 --every 0.2 -- bash -c 'echo still waiting; exit 1'
{ [ "$rc" -eq 124 ] && [ "$ms" -ge 900 ] && [ "$ms" -lt 5000 ] && [[ "$err" == *"timed out after"* ]] && [[ "$err" == *"still waiting"* ]]; } \
  && ok "a check that never passes: exit 124 after about the timeout (${ms} ms), last output shown" \
  || bad "timeout: rc=$rc ms=$ms err=$err"

# 5. a check that hangs is stopped at the deadline
if command -v timeout >/dev/null 2>&1; then
  run --timeout 1 --every 0.2 -- sleep 30
  { [ "$rc" -eq 124 ] && [ "$ms" -lt 8000 ]; } \
    && ok "a hanging check is stopped at the deadline (${ms} ms, not 30 s)" || bad "hanging check: rc=$rc ms=$ms"
else
  echo "SKIP: no timeout binary on this host (a hanging check is not bounded)"
fi

# A successful command must not borrow an extra second beyond a short deadline.
run -q --timeout 0.05 -- sleep 0.25
[ "$rc" -eq 124 ] && ok "a check that succeeds after a subsecond deadline still times out" || bad "late success: rc=$rc ms=$ms"
echo 0 > "$T/count"
run -q --timeout 0.1 --every 0.1 -- "$T/third.sh" "$T/count"
{ [ "$rc" -eq 124 ] && [ "$(cat "$T/count")" = 1 ]; } \
  && ok "polling does not start another attempt after the deadline" || bad "attempt after deadline: rc=$rc count=$(cat "$T/count")"

# Reading a named pipe can block grep too; --file is not exempt from the deadline.
mkfifo "$T/log.pipe"
run -q --timeout 0.1 --file "$T/log.pipe" --grep ready
[ "$rc" -eq 124 ] && ok "--file --grep on a silent FIFO is bounded" || bad "FIFO check: rc=$rc ms=$ms"

# 6. a command that does not exist: 127 straight away
run --timeout 20 --every 0.5 -- no-such-command-await-test
{ [ "$rc" -eq 127 ] && [ "$ms" -lt 3000 ] && [[ "$err" == *"not found"* ]]; } \
  && ok "a missing command exits 127 without waiting out the clock (${ms} ms)" || bad "missing command: rc=$rc ms=$ms err=$err"

# 7. usage errors
for args in "" "--timeout" "--timeout abc -- true" "--every -1 -- true" "--bogus -- true" "--grep x -- true" "--pid x" "--pid 1 -- true" "--file"; do
  # shellcheck disable=SC2086
  run $args
  [ "$rc" -eq 2 ] && ok "usage error exits 2: await $args" || bad "usage error 'await $args': rc=$rc err=$err"
done
run -h
{ [ "$rc" -eq 0 ] && [[ "$out" == *"Usage:"* ]]; } && ok "-h prints the usage and exits 0" || bad "-h: rc=$rc"

# 8. a lone argument with shell syntax runs under bash -c
printf 'ready\n' > "$T/log"
run --timeout 5 --every 0.2 -- "test -s $T/log && grep -q ready $T/log && echo found-it"
{ [ "$rc" -eq 0 ] && [ "$out" = found-it ]; } && ok "a quoted shell string runs under bash -c" || bad "shell string: rc=$rc out=$out err=$err"
# several arguments are NOT re-split by a shell
run --timeout 3 --every 0.2 -- test -s "$T/log with space"
[ "$rc" -eq 124 ] && ok "separate arguments are run as given (a path with a space is one argument)" || bad "argv form: rc=$rc"

# 9. --pid
sleep 1.2 & p=$!; BG+=("$p")
run --timeout 10 --every 0.2 --pid "$p"
{ [ "$rc" -eq 0 ] && [ "$ms" -ge 900 ] && [ "$ms" -lt 8000 ]; } && ok "--pid waits until the process has exited (${ms} ms)" || bad "--pid: rc=$rc ms=$ms err=$err"
wait "$p" 2>/dev/null
sleep 30 & p=$!; BG+=("$p")
run --timeout 1 --every 0.2 --pid "$p"
[ "$rc" -eq 124 ] && ok "--pid on a live process times out with 124" || bad "--pid live: rc=$rc"
kill "$p" 2>/dev/null; wait "$p" 2>/dev/null

# 10. --file and --file --grep
rm -f "$T/f"
run --timeout 1 --every 0.2 --file "$T/f"
[ "$rc" -eq 124 ] && ok "--file on a missing file times out" || bad "--file missing: rc=$rc"
: > "$T/f"
run --timeout 3 --every 0.2 --file "$T/f"
[ "$rc" -eq 0 ] && ok "--file passes once the file exists" || bad "--file exists: rc=$rc"
run --timeout 1 --every 0.2 --file "$T/f" --grep 'DONE [0-9]+'
[ "$rc" -eq 124 ] && ok "--file --grep times out while no line matches" || bad "--grep nomatch: rc=$rc"
( sleep 0.5; echo "build DONE 7" >> "$T/f" ) & BG+=("$!")
run --timeout 10 --every 0.2 --file "$T/f" --grep 'DONE [0-9]+'
{ [ "$rc" -eq 0 ] && [ "$ms" -ge 400 ]; } && ok "--file --grep passes when a matching line appears (${ms} ms)" || bad "--grep match: rc=$rc ms=$ms"

# 11. -q and -v
run -q --timeout 2 --every 0.2 -- true
{ [ "$rc" -eq 0 ] && [ -z "$err" ]; } && ok "-q prints no status line" || bad "-q: err='$err'"
echo 0 > "$T/count"
run -v --timeout 10 --every 0.1 -- "$T/third.sh" "$T/count"
[[ "$err" == *"attempt 1 exit 1"* && "$err" == *"attempt 3 exit 0"* ]] && ok "-v prints one line per attempt" || bad "-v: err='$err'"

# 11b. --every 0 is floored (a spin would burn the CPU and flood the log)
run -v --timeout 1 --every 0 -- false
att="$(printf '%s\n' "$err" | grep -c '^await: attempt ')"
{ [ "$rc" -eq 124 ] && [ "$att" -le 14 ] && [ "$att" -ge 3 ]; } && ok "--every 0 is floored at 0.1 s ($att attempts in 1 s)" || bad "--every 0: rc=$rc attempts=$att"

# 12. TERM ends the wait and the check it is running
"$AW" --timeout 60 --every 0.2 -- bash -c 'echo $$ > '"$T"'/child.pid; sleep 30; false' >/dev/null 2>&1 &
ap=$!; BG+=("$ap")
for _ in $(seq 1 50); do [ -s "$T/child.pid" ] && break; sleep 0.1; done
cpid="$(cat "$T/child.pid" 2>/dev/null)"
kill -TERM "$ap" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$ap" 2>/dev/null || break; sleep 0.1; done
wait "$ap" 2>/dev/null; trc=$?
sleep 0.5
alive=no; [ -n "$cpid" ] && kill -0 "$cpid" 2>/dev/null && alive=yes
{ [ "$trc" -eq 143 ] && [ "$alive" = no ]; } && ok "TERM ends await (143) and the check it was running" \
  || { bad "TERM handling: await rc=$trc, check still alive=$alive"; [ -n "$cpid" ] && kill "$cpid" 2>/dev/null; }

# Bash defers a trap while waiting on a foreground sleep. A polling pause must be
# interruptible too, even when --every is much longer than the caller can wait.
"$AW" --timeout 30 --every 20 -- bash -c 'touch "$1"; exit 1' x "$T/paused" >/dev/null 2>&1 &
ap=$!; BG+=("$ap")
for _ in $(seq 1 50); do [ -f "$T/paused" ] && break; sleep 0.02; done
sleep 0.1
kill -TERM "$ap" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$ap" 2>/dev/null || break; sleep 0.02; done
if kill -0 "$ap" 2>/dev/null; then
  bad "TERM during the polling pause did not stop await promptly"; kill -KILL "$ap" 2>/dev/null
fi
wait "$ap" 2>/dev/null; trc=$?
[ "$trc" -eq 143 ] && ok "TERM during a long polling pause exits promptly with 143" || bad "pause TERM: rc=$trc"

# No timer is preferable to neither a deadline nor an error. Keep only the tools
# used before the dependency check on PATH, so this cannot accidentally hang.
mkdir -p "$T/no-timer"
env PATH="$T/no-timer" "$(command -v bash)" "$AW" --timeout 0.1 -- sleep 30 >"$T/o" 2>"$T/e"; nrc=$?
{ [ "$nrc" -eq 127 ] && grep -q 'timeout or gtimeout is required' "$T/e"; } \
  && ok "a missing timeout tool exits 127 before running the check" || bad "no timer: rc=$nrc err=$(cat "$T/e")"

# 13. the temp file is removed
before="$(ls "${TMPDIR:-/tmp}"/await.* 2>/dev/null | wc -l)"
run --timeout 2 --every 0.2 -- true
after="$(ls "${TMPDIR:-/tmp}"/await.* 2>/dev/null | wc -l)"
[ "$after" -le "$before" ] && ok "no temp file left behind" || bad "temp files: $before before, $after after"

echo "await-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
