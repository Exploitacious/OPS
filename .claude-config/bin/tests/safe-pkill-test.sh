#!/usr/bin/env bash
# safe-pkill-test.sh: behavior tests for bin/safe-pkill (and its safe-pgrep, pkill
# and pgrep names), the pkill that does not kill its own caller.
#
# THE POINT OF THE SUITE. The Bash tool runs a command as `bash -c '<command line>'`,
# so `pkill -f "<text in my command>"` matches the shell running it and kills it
# (Claude Code shows exit 144; a plain bash -c shows 143, the same SIGTERM). The first
# cases run that exact shape three ways against one target process: plain pkill (the
# caller dies, nothing after the kill runs: this is the "before"), safe-pkill with
# procps' -A, and safe-pkill's own ancestor filter (the path an old procps takes).
# The caller must survive and print its marker under both safe paths, and the target
# must still die.
#
# Also pinned: the waiter twin (`until ! pgrep -f X` never ends under plain pgrep
# and ends under safe-pgrep, also when run through bin/await); every target that
# matches is still killed (nothing is narrowed beyond the caller's own chain); exit
# codes follow the real tool; signal forms; what is killed is printed on stderr
# and logged; the shim install, the shim's lookup of the real tool and its refusal to
# overwrite; an old-procps stub that has no -A takes the fallback by itself; options
# the fallback cannot filter run the real tool unchanged with a notice.
#
# SAFETY. Every pattern carries a number unique to this run, so only this suite's
# own processes match it (other sessions run suites on the same box and must never
# be hit). Background targets are `sleep` and are reaped by exact PID; the log goes
# to a temp dir. The shim cases write links only under a temp dir, never ~/.local/bin.
#
# Usage: safe-pkill-test.sh    (exit 0 all pass, 1 otherwise)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SP="${SAFE_PKILL_UNDER_TEST:-$HERE/../safe-pkill}"
SPG="$HERE/../safe-pgrep"
AW="$HERE/../await"
[ -x "$SP" ] || { echo "FAIL: $SP missing or not executable"; exit 1; }
[ -L "$SPG" ] && [ "$(readlink "$SPG")" = safe-pkill ] || { echo "FAIL: $SPG must be a symlink to safe-pkill"; exit 1; }
command -v pgrep >/dev/null && command -v pkill >/dev/null || { echo "SKIP: no procps pgrep/pkill on this host"; exit 0; }

T="$(mktemp -d)"; BG=()
cleanup() { local p; for p in "${BG[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }

export SAFE_PKILL_LOG="$T/safe-pkill.log"
unset SAFE_PKILL_DISABLE SAFE_PKILL_NO_A SAFE_PKILL_REAL_DIR

# A number nobody else's command line holds: it makes the pattern unique to this run.
N="7$RANDOM$RANDOM$$"
target() {  # target <n>: start `sleep <N><n>` in the background; sets TP
  sleep "$N$1" & TP=$!; BG+=("$TP"); disown "$TP" 2>/dev/null
}
alive() { kill -0 "$1" 2>/dev/null; }
settle() { local p="$1" _try; for _try in $(seq 1 40); do alive "$p" || return 0; sleep 0.05; done; return 1; }

echo "safe-pkill-test:"

# --- 1. the caller dies under plain pkill, lives under safe-pkill ---------------
target 1; tp=$TP
out="$(bash -c "pkill -f 'sleep ${N}1'; echo CALLER-ALIVE" 2>/dev/null)"; rc=$?
if [ "$rc" -ge 128 ] && [ "$out" != CALLER-ALIVE ]; then ok "BEFORE: plain pkill -f kills the bash -c that runs it (exit $rc, nothing after it ran)"
else bad "baseline did not reproduce the self-kill: rc=$rc out='$out' (the premise of this suite)"; fi
kill "$tp" 2>/dev/null

target 2; tp=$TP
out="$(bash -c "'$SP' -f 'sleep ${N}2'; echo \"CALLER-ALIVE rc=\$?\"" 2>"$T/err")"; rc=$?
{ [ "$out" = "CALLER-ALIVE rc=0" ] && [ "$rc" -eq 0 ] && settle "$tp"; } \
  && ok "AFTER (-A path): the caller survives, runs on, and the target is dead" \
  || bad "safe-pkill -A path: rc=$rc out='$out' target alive=$(alive "$tp" && echo yes || echo no)" "$(cat "$T/err")"

target 3; tp=$TP
out="$(SAFE_PKILL_NO_A=1 bash -c "'$SP' -f 'sleep ${N}3'; echo \"CALLER-ALIVE rc=\$?\"" 2>"$T/err")"; rc=$?
{ [ "$out" = "CALLER-ALIVE rc=0" ] && [ "$rc" -eq 0 ] && settle "$tp"; } \
  && ok "AFTER (ancestor-filter fallback): the caller survives, runs on, and the target is dead" \
  || bad "safe-pkill fallback path: rc=$rc out='$out'" "$(cat "$T/err")"

# the same, with the caller one more shell deep and under timeout (a wrapper chain)
target 4; tp=$TP
out="$(bash -c "bash -c \"timeout 20 bash -c \\\"'$SP' -f 'sleep ${N}4'; echo CHAIN-ALIVE\\\"\"" 2>/dev/null)"
{ [ "$out" = CHAIN-ALIVE ] && settle "$tp"; } && ok "a deeper chain (bash -c, bash -c, timeout, bash -c) survives and kills the target" || bad "deep chain: out='$out'"

# A help-looking token after -- is a pattern. Restrict matching to our children:
# the helper must kill the target but leave its own bash -c caller alive. No other
# session's processes can be selected by the -P filter.
for path in A fallback; do
  bash -c 'exec -a "$1" sleep "$2"' x --help "${N}24" & tp=$!; BG+=("$tp"); disown "$tp" 2>/dev/null
  if [ "$path" = fallback ]; then export SAFE_PKILL_NO_A=1; else unset SAFE_PKILL_NO_A; fi
  out="$(bash -c "'$SP' -P '$$' -f -- '--help'; echo \"CALLER-ALIVE rc=\$?\"" 2>"$T/err")"; rc=$?
  unset SAFE_PKILL_NO_A
  { [ "$rc" -eq 0 ] && [ "$out" = 'CALLER-ALIVE rc=0' ] && settle "$tp"; } \
    && ok "a literal --help pattern keeps ancestor exclusion ($path path)" || bad "literal help pattern ($path): rc=$rc out='$out'"
done

# SAFE_PKILL_DISABLE=1 is the plain tool again: the escape hatch is real
target 5; tp=$TP
out="$(SAFE_PKILL_DISABLE=1 bash -c "'$SP' -f 'sleep ${N}5'; echo CALLER-ALIVE" 2>/dev/null)"; rc=$?
{ [ "$rc" -ge 128 ] && [ "$out" != CALLER-ALIVE ]; } && ok "SAFE_PKILL_DISABLE=1 runs the real tool unchanged (and shows the self-kill)" || bad "disable switch: rc=$rc out='$out'"
kill "$tp" 2>/dev/null

# --- 2. the waiter twin: until ! pgrep -f X ------------------------------------
# wait for the sleep above by its unique pattern, written as a lane would write it
# (the pattern text sits in the waiter's own bash -c command line)
sleep "${N}6" & wp=$!; BG+=("$wp"); disown "$wp" 2>/dev/null; ( sleep 1.2; kill "$wp" 2>/dev/null ) & BG+=("$!")
out="$(bash -c "n=0; until ! '$SPG' -f 'sleep ${N}6' >/dev/null; do sleep 0.2; n=\$((n+1)); [ \$n -gt 60 ] && { echo STUCK; exit 1; }; done; echo WAITER-ENDED" 2>/dev/null)"
[ "$out" = WAITER-ENDED ] && ok "until ! safe-pgrep -f X ends once X has exited" || bad "safe-pgrep waiter: out='$out'"
out="$(bash -c "n=0; until ! pgrep -f 'sleep ${N}6' >/dev/null; do sleep 0.1; n=\$((n+1)); [ \$n -gt 10 ] && { echo STUCK; exit 1; }; done; echo WAITER-ENDED" 2>/dev/null)"
[ "$out" = STUCK ] && ok "BEFORE: the same waiter with plain pgrep never ends (it matches its own bash -c)" || bad "plain pgrep waiter should be stuck: out='$out'"

# through bin/await, as the lane block teaches
if [ -x "$AW" ]; then
  sleep "${N}7" & wp=$!; BG+=("$wp"); disown "$wp" 2>/dev/null; ( sleep 1.0; kill "$wp" 2>/dev/null ) & BG+=("$!")
  out="$("$AW" --timeout 15 --every 0.2 -q -- bash -c "! '$SPG' -f 'sleep ${N}7'" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "await -- bash -c '! safe-pgrep -f X' returns 0 when X is gone" || bad "await + safe-pgrep: rc=$rc out='$out'"
  sleep "${N}8" & wp=$!; BG+=("$wp"); disown "$wp" 2>/dev/null
  "$AW" --timeout 1 --every 0.2 -q -- bash -c "! pgrep -f 'sleep ${N}8'" >/dev/null 2>&1; rc=$?
  kill "$wp" 2>/dev/null
  [ "$rc" -eq 124 ] && ok "BEFORE: the same await check with plain pgrep matches await's own argv forever" || echo "NOTE: plain pgrep under await returned $rc (no self-match here)"
fi

# --- 3. nothing is narrowed: every matching target dies ------------------------
sleep "${N}9" & t1=$!; sleep "${N}9" & t2=$!; BG+=("$t1" "$t2"); disown "$t1" "$t2" 2>/dev/null
sleep "${N}99" & t3=$!; BG+=("$t3"); disown "$t3" 2>/dev/null     # a different pattern's process must survive
out="$(bash -c "'$SP' -f 'sleep ${N}9\$' ; echo rc=\$?" 2>"$T/err")"
{ settle "$t1" && settle "$t2" && alive "$t3"; } && ok "two processes that match are both killed; a process that does not match is left alone" \
  || bad "narrowing check: t1=$(alive $t1 && echo up || echo down) t2=$(alive $t2 && echo up || echo down) t3=$(alive $t3 && echo up || echo down)" "$(cat "$T/err")"
kill "$t3" 2>/dev/null

# --- 4. exit codes follow the real tool ----------------------------------------
bash -c "'$SP' -f 'sleep ${N}0000001'" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "no match: exit 1" || bad "no match: exit $rc"
bash -c "'$SPG' -f 'sleep ${N}0000001'" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "safe-pgrep, no match: exit 1" || bad "safe-pgrep no match: exit $rc"
"$SP" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "no pattern: exit 2 (the real tool's usage error)" || bad "no pattern: exit $rc"
"$SP" --bogus-option x >/dev/null 2>&1; rc=$?
[ "$rc" -ge 2 ] && ok "an unknown option: exit $rc" || bad "unknown option exit $rc"
out="$("$SP" --version 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [[ "$out" == *procps* ]]; } && ok "--version goes straight to the real tool" || bad "--version: rc=$rc out=$out"

# --- 5. signals, in every spelling ---------------------------------------------
for spec in "-9" "-KILL" "-SIGKILL" "-kill" "--signal 9" "--signal=KILL"; do
  for path in A fallback; do
    sleep "${N}10" & tp=$!; BG+=("$tp"); disown "$tp" 2>/dev/null
    if [ "$path" = fallback ]; then export SAFE_PKILL_NO_A=1; else unset SAFE_PKILL_NO_A; fi
    # shellcheck disable=SC2086
    bash -c "'$SP' $spec -f 'sleep ${N}10'" >/dev/null 2>&1; rc=$?
    unset SAFE_PKILL_NO_A
    { [ "$rc" -eq 0 ] && settle "$tp"; } && ok "signal form '$spec' ($path path)" || { bad "signal form '$spec' ($path path): rc=$rc"; kill "$tp" 2>/dev/null; }
  done
done

# --- 6. what it killed is printed (stderr) and logged; stdout stays clean -------
target 11; tp=$TP
bash -c "'$SP' -f 'sleep ${N}11'" >"$T/o" 2>"$T/e"
{ [ ! -s "$T/o" ] && grep -q "safe-pkill: sleep killed (pid $tp)" "$T/e"; } && ok "the killed process is named on stderr; stdout stays empty" \
  || bad "kill report: stdout='$(cat "$T/o")' stderr='$(cat "$T/e")'"
grep -q "pkill rc=0 path=A killed=1 args=-f sleep ${N}11" "$SAFE_PKILL_LOG" && ok "the call is logged with its path and kill count" || bad "log line missing" "$(tail -3 "$SAFE_PKILL_LOG")"
target 12; tp=$TP
bash -c "SAFE_PKILL_NO_A=1 '$SP' -f 'sleep ${N}12'" >"$T/o" 2>"$T/e"
grep -q "safe-pkill: sleep killed (pid $tp)" "$T/e" && ok "the fallback names what it killed too" || bad "fallback kill report" "$(cat "$T/e")"
# -c on the fallback counts what was killed
target 13; tp=$TP
cnt="$(SAFE_PKILL_NO_A=1 bash -c "'$SP' -c -f 'sleep ${N}13'" 2>/dev/null)"
[ "$cnt" = 1 ] && ok "-c prints the count on stdout (fallback)" || bad "-c count: '$cnt'"
settle "$tp" >/dev/null

# --- 7. safe-pgrep: list forms and counts, both paths ---------------------------
target 14; tp=$TP
for path in A fallback; do
  if [ "$path" = fallback ]; then export SAFE_PKILL_NO_A=1; else unset SAFE_PKILL_NO_A; fi
  pids="$(bash -c "'$SPG' -f 'sleep ${N}14'" 2>/dev/null)"
  [ "$pids" = "$tp" ] && ok "safe-pgrep lists exactly the target and not its own caller ($path path)" || bad "safe-pgrep pids ($path): '$pids' want $tp"
  cnt="$(bash -c "'$SPG' -c -f 'sleep ${N}14'" 2>/dev/null)"
  [ "$cnt" = 1 ] && ok "safe-pgrep -c counts the target only ($path path)" || bad "safe-pgrep -c ($path): '$cnt'"
  lst="$(bash -c "'$SPG' -lf 'sleep ${N}14'" 2>/dev/null)"
  [[ "$lst" == "$tp sleep"* ]] && ok "safe-pgrep -lf prints pid and name ($path path)" || bad "safe-pgrep -lf ($path): '$lst'"
done
unset SAFE_PKILL_NO_A
# (the trailing ':' keeps bash -c from exec-ing pgrep directly, as the Bash tool's own wrapper never does)
plain="$(bash -c "pgrep -c -f 'sleep ${N}14'; :" 2>/dev/null)"
[ "$plain" -ge 2 ] 2>/dev/null && ok "BEFORE: plain pgrep -c counts the target plus its own bash -c caller ($plain)" || bad "plain pgrep -c: '$plain'"
kill "$tp" 2>/dev/null

# --- 8. an old procps without -A takes the fallback by itself -------------------
mkdir -p "$T/old"
REAL_PGREP="$(command -v pgrep)"; REAL_PKILL="$(command -v pkill)"
for tool in pgrep pkill; do
  real="$REAL_PGREP"; [ "$tool" = pkill ] && real="$REAL_PKILL"
  cat > "$T/old/$tool" <<STUB
#!/usr/bin/env bash
# stands in for a procps 3.3 $tool: no -A
for a in "\$@"; do [ "\$a" = -A ] && { echo "$tool: invalid option -- 'A'" >&2; exit 2; }; done
exec "$real" "\$@"
STUB
  chmod +x "$T/old/$tool"
done
target 15; tp=$TP
out="$(SAFE_PKILL_REAL_DIR="$T/old" bash -c "'$SP' -f 'sleep ${N}15'; echo \"CALLER-ALIVE rc=\$?\"" 2>"$T/err")"
{ [ "$out" = "CALLER-ALIVE rc=0" ] && settle "$tp" && grep -q 'path=fallback' "$SAFE_PKILL_LOG"; } \
  && ok "a procps without -A: the helper detects it, filters ancestors itself, and the caller survives" \
  || bad "old-procps stub: out='$out'" "$(cat "$T/err")"

# options the fallback cannot filter safely: the real tool runs unchanged, with a notice
target 16; tp=$TP
out="$(SAFE_PKILL_NO_A=1 "$SPG" -n -f "sleep ${N}16" 2>"$T/err")"
{ [ "$out" = "$tp" ] && grep -q 'running the real pgrep unchanged' "$T/err"; } \
  && ok "-n on the fallback: real pgrep runs unchanged and says so" || bad "-n passthrough: out='$out'" "$(cat "$T/err")"
kill "$tp" 2>/dev/null

# Invalid pkill options must not become valid pgrep selectors. A fixture returns
# only our own sleep, and signal 0 makes even the old broken path non-destructive.
mkdir -p "$T/options"
ln -s "$REAL_PKILL" "$T/options/pkill"
cat > "$T/options/pgrep" <<'SH'
#!/usr/bin/env bash
printf '%s sleep\n' "$SAFE_PKILL_FIXTURE_PID"
SH
chmod +x "$T/options/pgrep"
target 21; tp=$TP
for opt in -v -a -l -w; do
  SAFE_PKILL_NO_A=1 SAFE_PKILL_REAL_DIR="$T/options" SAFE_PKILL_FIXTURE_PID="$tp" \
    "$SP" -0 "$opt" -f "sleep ${N}21" >"$T/o" 2>"$T/e"; rc=$?
  [ "$rc" -eq 2 ] && ok "fallback preserves pkill's rejection of $opt" || bad "pkill-only validation $opt: rc=$rc"
done
"$SP" --bogus-option fixture >"$T/o" 2>"$T/e"; rc=$?
{ [ "$rc" -eq 2 ] && [ ! -s "$T/o" ] && [ -s "$T/e" ]; } \
  && ok "the explicit -A path keeps native diagnostics on stderr" || bad "diagnostic streams: rc=$rc stdout=$(cat "$T/o")"
mkdir -p "$T/match-error"
SAFE_PKILL_NO_A=1 TMPDIR="$T/match-error" "$SP" -f '[' >"$T/o" 2>"$T/e"; rc=$?
{ [ "$rc" -eq 2 ] && [ -z "$(ls -A "$T/match-error")" ]; } \
  && ok "a fallback match error preserves native status and removes its temporary listing before exec" || bad "match-error cleanup: rc=$rc files=$(ls -A "$T/match-error")"
# A missing or empty signal used to be dropped, silently restoring TERM.
for signal_form in missing empty invalid invalid-number; do
  case "$signal_form" in
    missing) signal_args=(--signal) ;;
    empty) signal_args=(--signal '') ;;
    invalid) signal_args=(--signal no-such-signal) ;;
    invalid-number) signal_args=(--signal 143) ;;
  esac
  SAFE_PKILL_NO_A=1 SAFE_PKILL_REAL_DIR="$T/options" SAFE_PKILL_FIXTURE_PID="$tp" \
    "$SP" "${signal_args[@]}" >"$T/o" 2>"$T/e"; rc=$?
  { [ "$rc" -eq 2 ] && alive "$tp"; } && ok "fallback rejects a $signal_form signal without signalling a process" \
    || bad "invalid signal $signal_form: rc=$rc target alive=$(alive "$tp" && echo yes || echo no)"
done
kill "$tp" 2>/dev/null

# Attached option values are opaque, even if they contain e, c, l or a. The
# fixture accepts only the original value, then lists our own target for signal 0.
cat > "$T/options/pgrep" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = -tce ]; then printf '%s sleep\n' "$SAFE_PKILL_FIXTURE_PID"; exit 0; fi
done
exit 1
SH
target 22; tp=$TP
SAFE_PKILL_NO_A=1 SAFE_PKILL_REAL_DIR="$T/options" SAFE_PKILL_FIXTURE_PID="$tp" \
  "$SP" -0 -tce -f fixture >"$T/o" 2>"$T/e"; rc=$?
{ [ "$rc" -eq 0 ] && [ ! -s "$T/o" ]; } && ok "fallback preserves an attached option value without peeling its letters" || bad "attached value: rc=$rc stdout=$(cat "$T/o")"
kill "$tp" 2>/dev/null

# -c counts selections even when the process disappears before kill. No live
# process can have this Linux PID, and signal 0 has no side effects in any case.
cat > "$T/options/pgrep" <<'SH'
#!/usr/bin/env bash
printf '2147483647 vanished\n'
SH
cnt="$(SAFE_PKILL_NO_A=1 SAFE_PKILL_REAL_DIR="$T/options" "$SP" -0 -c fixture 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 1 ] && [ "$cnt" = 1 ]; } && ok "fallback -c counts a selected process whose signal fails" || bad "selected count: rc=$rc count='$cnt'"

# no real tool at all
SAFE_PKILL_REAL_DIR="$T/nothing" "$SP" -f x >/dev/null 2>"$T/err"; rc=$?
{ [ "$rc" -eq 127 ] && grep -q 'no real pkill' "$T/err"; } && ok "no real pkill found: exit 127 with a message" || bad "no real tool: rc=$rc" "$(cat "$T/err")"

# --- 9. shims -------------------------------------------------------------------
mkdir -p "$T/bin"
"$SP" --install-shims "$T/bin" >"$T/o" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && [ -L "$T/bin/pkill" ] && [ -L "$T/bin/pgrep" ] && [ "$(realpath "$T/bin/pkill")" = "$(realpath "$SP")" ]; } \
  && ok "--install-shims links pkill and pgrep to the helper" || bad "install-shims: rc=$rc" "$(cat "$T/o")"
"$SP" --install-shims "$T/bin" >"$T/o" 2>&1
grep -q 'already points here' "$T/o" && ok "--install-shims is idempotent" || bad "second install" "$(cat "$T/o")"
mkdir -p "$T/bin2"; printf '#!/bin/sh\necho mine\n' > "$T/bin2/pkill"; chmod +x "$T/bin2/pkill"
"$SP" --install-shims "$T/bin2" >"$T/o" 2>&1; rc=$?
{ [ "$rc" -ne 0 ] && [ "$("$T/bin2/pkill")" = mine ] && [ -L "$T/bin2/pgrep" ]; } && ok "--install-shims never overwrites a file that is not its own link" || bad "overwrite guard: rc=$rc" "$(cat "$T/o")"
# the plain command, earlier on PATH than procps, is the safe one
target 17; tp=$TP
out="$(PATH="$T/bin:$PATH" bash -c "pkill -f 'sleep ${N}17'; echo \"CALLER-ALIVE rc=\$?\"" 2>"$T/err")"
{ [ "$out" = "CALLER-ALIVE rc=0" ] && settle "$tp"; } && ok "with the shim first on PATH, a plain 'pkill -f' is safe and does not recurse into itself" || bad "shim run: out='$out'" "$(cat "$T/err")"
[ ! -s "$T/err" ] && ok "the shim adds nothing to stderr (a script that reads pkill's stderr as an error cannot break)" || bad "shim wrote to stderr" "$(cat "$T/err")"
# ... and the real tool's own -e report stays on stdout, in its own words
target 18; tp=$TP
out="$(PATH="$T/bin:$PATH" bash -c "pkill -e -f 'sleep ${N}18'; :" 2>"$T/err")"
{ [[ "$out" == "sleep killed (pid $tp)" ]] && [ ! -s "$T/err" ]; } && ok "shim: pkill -e prints the real tool's own report on stdout, nothing on stderr" || bad "shim -e: out='$out'" "$(cat "$T/err")"
settle "$tp" >/dev/null
target 19; tp=$TP
out="$(SAFE_PKILL_NO_A=1 PATH="$T/bin:$PATH" bash -c "pkill -f 'sleep ${N}19'; :" 2>"$T/err")"
{ [ -z "$out" ] && [ ! -s "$T/err" ]; } && settle "$tp" && ok "shim on the fallback path: silent too, and the target is dead" || bad "shim fallback: out='$out'" "$(cat "$T/err")"
target 20; tp=$TP
out="$(SAFE_PKILL_NO_A=1 PATH="$T/bin:$PATH" bash -c "pkill -e -f 'sleep ${N}20'; :" 2>"$T/err")"
{ [[ "$out" == "sleep killed (pid $tp)" ]] && [ ! -s "$T/err" ]; } && ok "shim fallback: -e reports on stdout as pkill does" || bad "shim fallback -e: out='$out'" "$(cat "$T/err")"
settle "$tp" >/dev/null
out="$(PATH="$T/bin:$PATH" bash -c "type -P pgrep")"
[ "$out" = "$T/bin/pgrep" ] && ok "the pgrep shim is the one PATH finds first" || bad "pgrep shim lookup: '$out'"
target 23; tp=$TP
out="$(SAFE_PKILL_NO_A=1 "$T/bin/pkill" -0 --cou -P "$$" -f "^sleep ${N}23$" 2>"$T/err")"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = 1 ] && [ ! -s "$T/err" ]; } \
  && ok "an abbreviated --count retains native count semantics and clean shim streams" || bad "abbreviated option: rc=$rc out='$out'" "$(cat "$T/err")"
kill "$tp" 2>/dev/null
"$SP" --remove-shims "$T/bin" >/dev/null 2>&1
{ [ ! -e "$T/bin/pkill" ] && [ ! -e "$T/bin/pgrep" ]; } && ok "--remove-shims removes the helper's own links" || bad "remove-shims left files"
"$SP" --remove-shims "$T/bin2" >/dev/null 2>&1
[ "$("$T/bin2/pkill")" = mine ] && ok "--remove-shims leaves a file that is not its own link" || bad "remove-shims removed a foreign file"

echo "safe-pkill-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
