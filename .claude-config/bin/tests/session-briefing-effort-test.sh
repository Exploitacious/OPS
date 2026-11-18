#!/usr/bin/env bash
# session-briefing-effort-test.sh: the Config line's effort is what the session really runs,
# with its source named (hooks/session-briefing.sh).
#
# Why: the line used to print the first effortLevel key anywhere in the settings file, which
# is another model's saved level, or none, rather than this session's. Claude Code resolves
# the env CLAUDE_CODE_EFFORT_LEVEL, then --effort at launch, then the saved level for the
# model (modelSettings.<model>.effortLevel), then the model's default; the line now follows
# that order and labels which one it printed.
#
# Pinned:
#   precedence: env above the launch flag above the saved level above "model default";
#   the launch flag: found on the nearest ancestor whose comm is claude (a stub script named
#     claude, so the kernel sets comm; an argv[0] rename alone does not), both `--effort=V`
#     and `--effort V`, the last one winning, nothing after `--`, an unrelated argument never
#     read, a bare `--effort` with no value ignored, a process not named claude not read;
#   invalid values (launch, env, saved) are reported as invalid and never printed, and no
#     other argument of the claude command line reaches the output, whatever it holds;
#   the walk: at most 16 parents (a real chain of shells, and a fake /proc tree through the
#     BRIEFING_PROC_ROOT seam), stops at PID 1, and any read error, a vanished parent, an
#     unreadable command line, or a host with no /proc falls back to the saved level;
#   the saved level: keyed by the payload's model, else the active profile's pin, without a
#     [1m] suffix, read from the active profile (not the other profile's file), labelled an
#     estimate when SessionStart omitted the model, a top-level effortLevel never read, a
#     missing settings file a default and an unreadable one "unknown", not a default;
#   a lane gets its one line and nothing about effort.
#
# Every path is under a temp dir (HOME, OPS_DIR, CLAUDE_CONFIG_DIR are fixtures); stub
# claude processes only, never the real CLI. Nothing here deletes outside that temp dir.
#
# Usage: session-briefing-effort-test.sh    (exit 0 all pass, 1 any fail, 77 did not run)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
HOOK="$HERE/../../hooks/session-briefing.sh"
[ -f "$HOOK" ] || { echo "FAIL: the hook is missing"; exit 1; }
command -v jq >/dev/null || { echo "session-briefing-effort-test: did not run: no jq (the hooks' own parser)"; exit 77; }
[ -r /proc/self/stat ] || { echo "session-briefing-effort-test: did not run: no /proc (the stub-claude cases need a Linux host)"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }

echo "session-briefing-effort-test:"
mkdir -p "$T/home/.claude" "$T/cfg/projects" "$T/ops/CONTEXT" "$T/work"
printf '# Core\n' > "$T/ops/CONTEXT/core.md"
export BRIEF_HOOK_PATH="$HOOK"

# BRIEF_LAUNCH is what runs the hook: bash by default, or a stub named claude, which runs
# the hook as its child. BRIEF_PIN is an env CLAUDE_CODE_EFFORT_LEVEL for one case (the
# ambient one is always dropped, so a run inside a Claude session is still hermetic).
BRIEF_LAUNCH=(bash "$HOOK")
brief() {  # [payload]: runs the briefing; stdout in $T/out, stderr in $T/err, status in $rc
  ( cd "$T/work" && printf '%s' "${1:-}" | env -u TMUX -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_LANE_CLASS \
      -u OPS_STATE_DIR -u OPS_ORPHAN_SCAN -u T3CODE_HOME -u CLAUDE_CODE_EFFORT_LEVEL -u BRIEFING_PROC_ROOT \
      HOME="$T/home" OPS_DIR="$T/ops" CLAUDE_CONFIG_DIR="$T/cfg" LANE_CLASS_NO_DB=1 GIT_CONFIG_NOSYSTEM=1 \
      ${BRIEF_PIN:+CLAUDE_CODE_EFFORT_LEVEL="$BRIEF_PIN"} ${BRIEF_ROOT:+BRIEFING_PROC_ROOT="$BRIEF_ROOT"} \
      ${BRIEF_LANE:+OPS_LANE_CLASS="$BRIEF_LANE"} \
      "${BRIEF_LAUNCH[@]}" >"$T/out" 2>"$T/err" )
  rc=$?
}
launch() { BRIEF_LAUNCH=("$@"); }
reset() { BRIEF_LAUNCH=(bash "$HOOK"); BRIEF_PIN=""; BRIEF_ROOT=""; BRIEF_LANE=""; }
efflines() { sed -n 's/^ Config:.*  ·  effort \(.*\)  ·  main=.*$/\1/p' "$T/out"; }
effcase() {  # <label> <expected effort text>: the last brief run
  local got; got="$(efflines)"
  [ "$rc" -eq 0 ] && [ "$got" = "$2" ] && ok "$1" || bad "$1 (want '$2', got '$got', rc=$rc)" "$(grep -F ' Config:' "$T/out")"
}
nosecret() {  # <label> <fragment>...: none of them anywhere in the hook's output
  local label="$1" frag; shift
  for frag in "$@"; do
    if grep -qF -- "$frag" "$T/out" "$T/err"; then bad "$label: '$frag' reached the output" "$(cat "$T/out" "$T/err")"; return; fi
  done
  ok "$label"
}

# Stub claude processes. comm of a script run through its #! line is the script's file name.
mkdir -p "$T/fc" "$T/fc-outer" "$T/fc-other" "$T/fc-deep" "$T/fc-argv0"
printf '#!/bin/bash\nbash "$BRIEF_HOOK_PATH"\n' > "$T/fc/claude"
# An outer claude (with its own --effort) that starts an inner claude: the nearest one counts.
printf '#!/bin/bash\n"%s/fc/claude" --inner\n' "$T" > "$T/fc-outer/claude"
# The same stub under another name: not a claude, so its arguments are not read.
printf '#!/bin/bash\nbash "$BRIEF_HOOK_PATH"\n' > "$T/fc-other/notclaude"
# claude, then an intermediate shell (a command hook runs through one), then the hook.
printf '#!/bin/bash\nbash -c '"'"'bash "$BRIEF_HOOK_PATH"; exit $?'"'"'\n' > "$T/fc-deep/claude"
# argv[0] renamed to claude but the program is bash: comm stays "bash", so it is not claude.
printf '#!/bin/bash\nbash "$BRIEF_HOOK_PATH"; exit $?\n' > "$T/fc-argv0/mid.sh"
printf '#!/bin/bash\nexec -a claude bash "%s/fc-argv0/mid.sh" "$@"\n' "$T" > "$T/fc-argv0/launcher"
chmod +x "$T/fc/claude" "$T/fc-outer/claude" "$T/fc-other/notclaude" "$T/fc-deep/claude" "$T/fc-argv0/mid.sh" "$T/fc-argv0/launcher"
# chain.sh <L> is L+1 nested shells between a claude stub and the hook: claude is L+2 parents up.
cat > "$T/chain.sh" <<'EOF'
#!/bin/bash
# chain.sh <levels> <args...>: nests <levels>+1 shells (a child bash that is not exec'd away), then runs the hook
n=$1; shift
if [ "$n" -gt 0 ]; then bash "$0" $((n - 1)) "$@"; exit $?; fi
bash "$BRIEF_HOOK_PATH"; exit $?
EOF
printf '#!/bin/bash\nbash "%s/chain.sh" "$@"\n' "$T" > "$T/fc-chain-claude.sh"
mkdir -p "$T/fc-chain"; cp "$T/fc-chain-claude.sh" "$T/fc-chain/claude"; chmod +x "$T/fc-chain/claude"
# A fake /proc tree for the BRIEFING_PROC_ROOT seam: this script creates it for its own PID
# (which the hook then keeps, by exec), so the walk starts inside the fixture.
#   fakeproc.sh <root> <claude depth, or none> <ending> <argv...>
#   ending: pid1 (the chain ends at PID 1), gone (the chain's next parent has no entry), loop-ok
cat > "$T/fakeproc.sh" <<'EOF'
#!/bin/bash
root=$1; depth=$2; ending=$3; shift 3
rm -rf "$root"; mkdir -p "$root"
pid=$$; i=0
while :; do
  i=$((i + 1)); next=$((7000 + i))
  [ "$ending" = pid1 ] && [ "$i" -gt 20 ] && next=1
  mkdir -p "$root/$pid"
  printf '%s (a b) c) S %s 1 1 0 -1\n' "$pid" "$next" > "$root/$pid/stat"
  if [ "$pid" = "$$" ]; then printf 'bash\n' > "$root/$pid/comm"
  elif [ "$depth" != none ] && [ "$i" -eq $((depth + 1)) ]; then
    printf 'claude\n' > "$root/$pid/comm"; : > "$root/$pid/cmdline"; for a in "$@"; do printf '%s\0' "$a" >> "$root/$pid/cmdline"; done
  else printf 'bash\n' > "$root/$pid/comm"; fi
  [ "$next" = 1 ] && break
  [ "$ending" = gone ] && [ "$i" -ge 3 ] && break
  [ "$i" -ge 30 ] && break
  pid=$next
done
exec bash "$BRIEF_HOOK_PATH"
EOF
chmod +x "$T/fakeproc.sh"

# eff_settings <pin> <modelSettings json> [extra top-level json]: the active profile's settings,
# and the shared one the main= pin comes from (the same content unless a case says otherwise).
eff_settings() {
  printf '{"model":"%s","modelSettings":%s%s}\n' "$1" "$2" "${3:+,$3}" > "$T/cfg/settings.json"
  cp "$T/cfg/settings.json" "$T/home/.claude/settings.json"
}
MS='{"model-a":{"effortLevel":"xhigh"},"model-b":{"effortLevel":"high"},"model-c":{"autoCompactWindow":100000,"effortLevel":"low"}}'
EST='session model unknown, estimated from the settings pin'

# --- the launch flag, found through a stub claude process ---------------------------------
eff_settings "model-a[1m]" "$MS"
launch "$T/fc/claude" --output-format stream-json --effort=high --model model-a
brief ''
effcase "launch: --effort=<v> on the claude ancestor" "high (launch flag)"
launch "$T/fc/claude" --effort xhigh --model model-b
brief ''
effcase "launch: --effort <v> (a space)" "xhigh (launch flag)"
launch "$T/fc/claude" --effort=low -p --effort high
brief ''
effcase "launch: with two flags in mixed forms the last one counts" "high (launch flag)"
launch "$T/fc/claude" --effort=low --model model-b --effort=max
brief ''
effcase "launch: max is a recognized launch level, shown as it is" "max (launch flag)"
launch "$T/fc/claude" --effort=HIGH
brief ''
effcase "launch: the value is lowercased" "high (launch flag)"
launch "$T/fc-deep/claude" --effort=xhigh --model model-b
brief ''
effcase "launch: the claude ancestor is found through an intermediate shell" "xhigh (launch flag)"
launch "$T/fc/claude" --effort
brief ''
effcase "launch: --effort with no value is ignored (saved level, estimated)" "xhigh (saved default; $EST)"
launch "$T/fc/claude" -- --effort=max
brief ''
effcase "launch: an --effort after -- is a prompt word, not a flag" "xhigh (saved default; $EST)"
launch "$T/fc/claude" --effort=low --append-system-prompt "--effort high"
brief ''
effcase "launch: '--effort high' inside one argument is not a flag" "low (launch flag)"
launch "$T/fc/claude" --effort=low -- --effort=high
brief ''
effcase "launch: a flag before -- counts and the words after it do not" "low (launch flag)"
launch "$T/fc/claude" --effort=low --effort -- --effort=high
brief ''
effcase "launch: a pending --effort never consumes the option separator" "low (launch flag)"
launch "$T/fc-outer/claude" --effort=low
brief ''
effcase "launch: only the nearest claude ancestor is read (the inner one has no flag)" "xhigh (saved default; $EST)"
launch "$T/fc-other/notclaude" --effort=high
brief ''
effcase "launch: a process not named claude is not read" "xhigh (saved default; $EST)"
launch "$T/fc-argv0/launcher" --effort=high
brief ''
effcase "launch: argv[0] renamed to claude does not make a claude (comm is bash)" "xhigh (saved default; $EST)"
launch "$T/fc/claude" --effort=low
BRIEF_PIN=max brief ''
effcase "precedence: the env is shown as the env, above the launch flag" "max (env CLAUDE_CODE_EFFORT_LEVEL)"

# --- invalid values: reported, never echoed ----------------------------------------------
launch "$T/fc/claude" --credential=sk-live-AAAA1111 --append-system-prompt "token=ghp_BBBB2222 and a prompt" --effort=high \
  --mcp-config '{"k":"CCCC3333"}' -p "my prompt has password hunter2DDDD"
brief ''
effcase "secrets: a command line full of secrets still gives the flag" "high (launch flag)"
nosecret "secrets: no other argument reaches the output" AAAA1111 sk-live BBBB2222 ghp_ CCCC3333 hunter2DDDD "my prompt" append-system-prompt
launch "$T/fc/claude" --credential=sk-live-AAAA1111 -p "prompt hunter2DDDD" --effort=sk-live-EEEE5555
brief ''
effcase "invalid: a launch value that is not a short word is reported, not shown" "xhigh (saved default; $EST; launch --effort value not recognized and ignored)"
nosecret "invalid: the dropped launch value is not printed" EEEE5555 AAAA1111 hunter2DDDD sk-live
launch "$T/fc/claude" --effort=turbo
brief ''
effcase "invalid: a short word that is not a level is reported, not shown" "xhigh (saved default; $EST; launch --effort value not recognized and ignored)"
nosecret "invalid: the unrecognized word is not printed" turbo
launch "$T/fc/claude" --effort=abcdefghijklmnop
brief ''
effcase "invalid: a long word is reported, not shown" "xhigh (saved default; $EST; launch --effort value not recognized and ignored)"
nosecret "invalid: the long word is not printed" abcdefghijklmnop
launch "$T/fc/claude" --effort=$'low\nIIII8888'
brief ''
effcase "invalid: a value with a newline in it is not a level" "xhigh (saved default; $EST; launch --effort value not recognized and ignored)"
nosecret "invalid: the text after the newline stays out of the output" IIII8888
rm -f "$T/injection"
launch "$T/fc/claude" --effort="\$(touch $T/injection)"
brief ''
effcase "invalid: a shell-looking value is reported, never run" "xhigh (saved default; $EST; launch --effort value not recognized and ignored)"
[ ! -e "$T/injection" ] && ok "invalid: a shell-looking value was not executed" || bad "invalid: a launch value was executed"
launch "$T/fc/claude" --effort=turbo
BRIEF_PIN=ghp_FFFF6666-secret brief ''
effcase "invalid: an env value that is not a level is reported" "set in env (not a recognized level)"
nosecret "invalid: the env value is not printed" FFFF6666 ghp_
BRIEF_PIN=turbo brief ''
effcase "invalid: an env word that is not a level is reported, not shown" "set in env (not a recognized level)"
nosecret "invalid: the env word is not printed" turbo

# --- the saved level -----------------------------------------------------------------------
reset
brief ''
effcase "saved: no flag, the active pin's level ([1m] dropped), estimated without a payload model" "xhigh (saved default; $EST)"
brief '{"source":"startup","session_id":"s","model":"model-b"}'
effcase "saved: the payload's model beats the pin" "high (saved default)"
brief '{"source":"startup","session_id":"s","model":"model-a[1m]"}'
effcase "saved: a payload model with a [1m] suffix finds its entry" "xhigh (saved default)"
brief '{"source":"startup","session_id":"s","model":"model-z"}'
effcase "saved: a model with no entry is the model default" "model default"
eff_settings "model-z" "$MS"
brief ''
effcase "saved: no payload model and a pin with no entry, estimated" "model default ($EST)"
eff_settings "model-a" '{"model-a":{"effortLevel":"xhgih-SECRET"}}'
brief '{"model":"model-a"}'
effcase "saved: an invalid saved level is reported as ignored, not shown" "model default (saved level is not valid and ignored)"
nosecret "saved: the invalid saved level is not printed" xhgih SECRET
eff_settings "model-a" '{"model-a":{"effortLevel":"max"}}'
brief '{"model":"model-a"}'
effcase "saved: max is not a valid saved level" "model default (saved level is not valid and ignored)"
eff_settings "model-a" "$MS" '"effortLevel":"low"'
brief '{"model":"model-a"}'
effcase "saved: a top-level effortLevel is never read" "xhigh (saved default)"
eff_settings "model-z" '{}' '"effortLevel":"low"'
brief '{"model":"model-z"}'
effcase "saved: a top-level effortLevel is not any model's level" "model default"
# the active profile's own file is the source, not the shared one the main= pin comes from
printf '{"model":"model-b","modelSettings":{"model-a":{"effortLevel":"high"},"model-b":{"effortLevel":"low"}}}\n' > "$T/cfg/settings.json"
printf '{"model":"model-a","modelSettings":{"model-a":{"effortLevel":"xhigh"},"model-b":{"effortLevel":"xhigh"}}}\n' > "$T/home/.claude/settings.json"
brief ''
effcase "saved: the active profile's pin and levels win over the other profile's file" "low (saved default; $EST)"
brief '{"model":"model-a"}'
effcase "saved: the payload's model is looked up in the active profile's file" "high (saved default)"
rm -f "$T/cfg/settings.json"
brief '{"model":"model-a"}'
effcase "saved: no active settings file is a default, not an error" "model default (no settings file)"
printf '{"model": "model-a", "modelSettings": {' > "$T/cfg/settings.json"
brief '{"model":"model-a"}'
effcase "saved: an unreadable settings file is 'unknown', not a default" "unknown (settings unreadable)"
printf '{"model":"default"}\n' > "$T/home/.claude/settings.json"
brief ''
effcase "saved: unreadable settings are unknown even without a payload model" "unknown (settings unreadable)"
printf '{"model":"model-a"}\n' > "$T/home/.claude/settings.json"
printf '{"modelSettings":%s}\n' "$MS" > "$T/cfg/settings.json"
brief ''
effcase "saved: a profile without a pin never borrows another profile's pin" "model default (session model unknown)"
eff_settings "default" "$MS"
brief ''
effcase "saved: no pin and no payload model: the session model is unknown" "model default (session model unknown)"

# --- the walk: a fake /proc tree ------------------------------------------------------------
eff_settings "model-a" "$MS"
R="$T/fakeroot"; BRIEF_ROOT="$R"
launch "$T/fakeproc.sh" "$R" 3 loop-ok --effort=high
brief ''
effcase "walk: a claude 3 parents up (a comm with spaces and a paren in stat) is read" "high (launch flag)"
launch "$T/fakeproc.sh" "$R" 16 loop-ok --effort=low
brief ''
effcase "walk: a claude exactly 16 parents up is found" "low (launch flag)"
launch "$T/fakeproc.sh" "$R" 17 loop-ok --effort=low
brief ''
effcase "walk: a claude 17 parents up is not (the hop limit)" "xhigh (saved default; $EST)"
launch "$T/fakeproc.sh" "$R" none pid1 --effort=low
brief ''
effcase "walk: a chain that ends at PID 1 with no claude falls back" "xhigh (saved default; $EST)"
launch "$T/fakeproc.sh" "$R" none gone --effort=low
brief ''
effcase "walk: a parent with no /proc entry falls back" "xhigh (saved default; $EST)"
launch "$T/fakeproc.sh" "$R" 2 loop-ok
brief ''
effcase "walk: a claude with an empty command line falls back" "xhigh (saved default; $EST)"
# an unreadable command line: a claude entry with a comm but no cmdline file
cat > "$T/fakeproc-nocmd.sh" <<'EOF'
#!/bin/bash
root=$1
rm -rf "$root"; mkdir -p "$root/$$" "$root/7001"
printf '%s (bash) S 7001 1 1 0\n' "$$" > "$root/$$/stat"; printf 'bash\n' > "$root/$$/comm"
printf '7001 (claude) S 1 1 1 0\n' > "$root/7001/stat"; printf 'claude\n' > "$root/7001/comm"
exec bash "$BRIEF_HOOK_PATH"
EOF
chmod +x "$T/fakeproc-nocmd.sh"
launch "$T/fakeproc-nocmd.sh" "$R"
brief ''
effcase "walk: a claude whose command line cannot be read falls back" "xhigh (saved default; $EST)"
[ ! -s "$T/err" ] && ok "walk: an unreadable command line prints nothing on stderr" || bad "walk: stderr was not empty" "$(cat "$T/err")"
# no /proc at all (a host that is not Linux): the saved level, no error output
launch bash "$HOOK"
BRIEF_ROOT="$T/no-such-proc" brief ''
effcase "non-Linux: no /proc falls back to the saved level" "xhigh (saved default; $EST)"
[ ! -s "$T/err" ] && ok "non-Linux: nothing on stderr" || bad "non-Linux: stderr was not empty" "$(cat "$T/err")"
BRIEF_ROOT="$T/no-such-proc" BRIEF_PIN=high brief ''
effcase "non-Linux: the env still wins" "high (env CLAUDE_CODE_EFFORT_LEVEL)"

# --- real chains of shells: the hop limit with real processes ---------------------------------
reset
launch "$T/fc-chain/claude" 14 --effort=high
brief ''
effcase "real chain: a claude 16 parents up (15 shells between) is found" "high (launch flag)"
launch "$T/fc-chain/claude" 15 --effort=high
brief ''
effcase "real chain: a claude 17 parents up (16 shells between) is not" "xhigh (saved default; $EST)"

# --- a lane gets one line and nothing about effort ----------------------------------------------
launch "$T/fc/claude" --effort=high
BRIEF_LANE=t3-lane brief ''
if [ "$rc" -eq 0 ] && grep -q 'Briefing: t3-lane session' "$T/out" && ! grep -qi 'effort' "$T/out" && [ "$(grep -c . "$T/out")" -eq 1 ]; then
  ok "lane: one line naming the class, no effort line"
else bad "lane: expected a single terse line" "$(cat "$T/out")"; fi

echo "session-briefing-effort-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
