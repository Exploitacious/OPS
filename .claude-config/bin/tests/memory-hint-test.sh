#!/usr/bin/env bash
# memory-hint-test.sh - behavior tests for the UserPromptSubmit memory hint
# (hooks/memory-hint.sh and bin/memory-index --hint, --find).
#
# Why pin it: the hint runs on every prompt in every foreman session. A scorer
# that fires on common words becomes noise paid for on each turn; one that
# fires on a baton or a scheduled wake puts memory lines into a message nobody
# typed; one that is slow taxes every prompt; one that crashes must never stop a
# prompt. Cases:
#   - a strong match prints "Relevant memory: <name>: <description>" and at most
#     three of them; a prompt about nothing in the pools, a weak match (one
#     shared word), a very short or very long prompt print nothing;
#   - nothing for a message the harness sent (slash command, compaction summary,
#     baton, scheduled wake, task notification, a note from another agent, a T3
#     quote reply), each built from words that WOULD match if it were typed, so
#     the skip is what silences it (a typed control prints);
#   - nothing from a lane: agent_id in the payload, or bin/lane-class answering
#     t3-lane or agent-lane; a foreman answer, a missing lane-class, a failing one
#     and one that prints rubbish all degrade to foreman (the shared contract);
#   - the pools it reads: this directory's pool and the root pool, the root's
#     type project entries left out unless pinned, CLAUDE_PROJECT_DIR winning
#     over a drifted payload cwd;
#   - the hook is fast (under 300 ms with a 300-entry pool beside a 300-entry
#     root pool), writes nothing, exits 0 on every failure and logs the failure;
#   - an indexer with no --hint (an older bin/memory-index) is silent and logs
#     nothing; MEMORY_HINT=0 turns the hook off.
#
# Every path is under a temp dir (HOME, OPS_DIR, OPS_STATE_DIR); the live pools
# are never read. HOOK_UNDER_TEST swaps the hook (the indexer is the one beside
# it, in ../bin/memory-index, and must take --hint and --ops).
#
# MEMORY_HINT_TEST_MAX_MS (default 300) moves the speed bound for a slow host: the hook starts the
# interpreter through hook_python, and a version-manager shim for python3 adds its own start-up.
#
# Usage: memory-hint-test.sh    (exit 0 all pass, 1 otherwise)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
HOOK="${HOOK_UNDER_TEST:-$HERE/../../hooks/memory-hint.sh}"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing"; exit 1; }
INDEXER="$(dirname "$HOOK")/../bin/memory-index"
[ -f "$INDEXER" ] || { echo "FAIL: bin/memory-index missing beside the hook"; exit 1; }
# The hook is a thin wrapper over the indexer's --hint mode. An indexer without it makes the hook
# silent by design, which would turn every case below into a confusing "match" failure: say why.
grep -q -e '--hint' "$INDEXER" || { echo "FAIL: $INDEXER has no --hint mode (the memory-hint hook needs the bin/memory-index that ships it)"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 required"; exit 1; }
command -v git >/dev/null || { echo "FAIL: git required"; exit 1; }

T="$(mktemp -d)"; trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }
echo "memory-hint-test:"

key() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
gitq() { git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# --- fixture: an OPS checkout, a project repo, their pools ---------------------
CW="$T/ops"; PROJ="$T/widgets"; CFG="$T/cfg"; HOST=testhost; ST="$T/state"
mkdir -p "$T/home" "$CFG/projects" "$ST" "$CW/.claude-memory" "$PROJ"
gitq init "$CW"; gitq -C "$CW" commit --allow-empty -m init
gitq init "$PROJ"; gitq -C "$PROJ" commit --allow-empty -m init
ROOTP="$CW/.claude-memory/$HOST$(key "$CW")"
PROJP="$CW/.claude-memory/$HOST$(key "$PROJ")"
mkdir -p "$ROOTP" "$PROJP"
entry() {  # entry <pool> <stem> <type> <description> [modified [pinned]]
  { printf -- '---\nname: %s\ndescription: "%s"\nmetadata:\n  type: %s\n' "$2" "$4" "$3"
    [ -n "${5:-}" ] && printf '  modified: %s\n' "$5"
    [ -n "${6:-}" ] && printf '  pinned: %s\n' "$6"
    printf -- '---\nbody text\n'; } > "$1/$2.md"
}
entry "$PROJP" feedback-examplebill-billing-rounding-let-it-be feedback "Operator 2026-10-26: do not chase rounding on Examplebill time entries; send hours once and accept what Examplebill stores" 2026-10-26T10:00:00Z
entry "$PROJP" reference-gateway-firmware-restart reference "Gateway firmware restarts the agent after a 3017 event" 2026-10-27T10:00:00Z
entry "$PROJP" feedback-log-hours-before-closing-a-job feedback "Put hours on a job before closing it, or use the verification requested status" 2026-10-14T10:00:00Z
entry "$ROOTP" feedback-gh-merge-recompute-race feedback "gh pr merge fails right after a push while mergeStateStatus recomputes; poll for CLEAN, then retry" 2026-10-30T10:00:00Z
entry "$ROOTP" project-workstream-storage-migration project "Storage migration workstream state: the cutover list and the nightly sync window" 2026-10-31T10:00:00Z
entry "$ROOTP" project-pinned-storage-ruling project "Operator ruling: storage cutover waits for the backup window, never during business hours" 2026-10-01T10:00:00Z true
i=0
for topic in printers monitors routers switches kiosks tablets docks scanners modems badges; do
  i=$((i+1))
  entry "$PROJP" "reference-filler-$topic" reference "Notes about $topic firmware, vendor portals and the usual replacement schedule number $i" "2026-09-$(printf '%02d' $i)T10:00:00Z"
  entry "$ROOTP" "reference-rootfiller-$topic" reference "General $topic gotcha seen on several sites, filed number $i for later" "2026-08-$(printf '%02d' $i)T10:00:00Z"
done

# hint <prompt> [env assignments...]: the hook's stdout for a UserPromptSubmit payload
hint() {
  local prompt="$1"; shift
  python3 -I -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":"s-1","cwd":sys.argv[2],"prompt":sys.argv[1]}))' \
    "$prompt" "$PROJ" 2>/dev/null | env -u CLAUDE_PROJECT_DIR -u MEMORY_INDEX_DIR -u MEMORY_DIGEST_ROOT_DIR \
    HOME="$T/home" OPS_DIR="$CW" CLAUDE_CONFIG_DIR="$CFG" MEMORY_DIGEST_HOST="$HOST" OPS_STATE_DIR="$ST" \
    "$@" bash "$HOOK" 2>"$T/err"
}
snapshot() { (cd "$T" && find ops widgets cfg -printf '%y %m %s %T@ %p\n' | sort | md5sum); }
BEFORE="$(snapshot)"

STRONG="Stop being so picky about rounding when billing, just let Examplebill do what it does"
WANT="Relevant memory: feedback-examplebill-billing-rounding-let-it-be:"

# 1. a strong match: one line, the exact shape, the right entry
out="$(hint "$STRONG")"; rc=$?
if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] \
   && [[ "$out" == "$WANT Operator 2026-10-26: do not chase rounding"* ]]; then
  ok "match: a prompt about Examplebill rounding prints that entry as 'Relevant memory: <name>: <description>'"
else bad "match" "rc=$rc out=$out"; fi

# 2. nothing for a prompt about nothing the pools hold, and for a weak match (one shared word)
out="$(hint "what is the weather like in the capital today, and will it rain on the weekend")"
[ -z "$out" ] && ok "no match: an unrelated prompt prints nothing" || bad "unrelated prompt printed" "$out"
out="$(hint "please send the billing summary to the accounting mailbox before lunch")"
[ -z "$out" ] && ok "weak match: one shared word (billing) is not a strong match" || bad "one shared word printed" "$out"
out="$(hint "ok thanks")"; [ -z "$out" ] && ok "a prompt of fewer than three content words prints nothing" || bad "short prompt printed" "$out"
long="$STRONG $(python3 -I -c 'print("filler words about nothing much at all " * 70)')"
out="$(hint "$long")"; [ -z "$out" ] && ok "a prompt of 150 or more content words (a paste, a brief) prints nothing" || bad "long prompt printed" "$out"

# 3. the harness's own sends: each carries words that match strongly if typed
SM="the Examplebill billing rounding and the time entries"
skip_case() {  # skip_case <label> <prompt>
  local o; o="$(hint "$2")"
  if [ -z "$o" ]; then ok "harness send: $1 prints nothing"; else bad "harness send printed: $1" "$o"; fi
}
control="$(hint "$SM")"
[[ "$control" == "$WANT"* ]] \
  && ok "control: the words used in the harness-send cases match when typed" || bad "control prompt does not match" "$control"
skip_case "a slash command" "/compact $SM"
skip_case "the compaction summary" "This session is being continued from a previous conversation that ran out of context. $SM"
skip_case "a baton (RESUME PROTOCOL)" "## RESUME PROTOCOL (updated 2026-11-04 18:50Z)
- NEXT ACTION: finish $SM"
skip_case "the default resume text" "Continue the standing work. Read the freshest durable anchor and execute NEXT ACTION on $SM."
skip_case "a scheduled wake" "Scheduled one-time check from the OPS thread (set 2026-10-22 20:22 ET). First delete this scheduled task with delete_scheduled_task, then look at $SM."
skip_case "a one-shot wake" "One-shot morning check on $SM. Delete this task first."
skip_case "a task notification" "<task-notification><summary>$SM</summary></task-notification>"
skip_case "a note from another agent" "FYI from the example foreman thread. No reply needed. $SM."
skip_case "a delegated-task brief" "Delegated task node:delegated-task:abc. Work on $SM."
skip_case "a T3 quote reply with no typed words" "[Assistant quote](t3-citation://v1/x/y/message%3Aprovider?text=$(printf '%s' "$SM" | sed 's/ /+/g')&comment=ok)"
skip_case "a command echo block" "<local-command-stdout>$SM</local-command-stdout>"
skip_case "a system reminder block" "<system-reminder>$SM</system-reminder>"
# ... but a typed reply that quotes an assistant message is still scored on the typed words.
out="$(hint "[Assistant quote](t3-citation://v1/x/y/message?text=junk&comment=c) $STRONG")"
[[ "$out" == "$WANT"* ]] \
  && ok "a quote reply scores the words typed, not the quoted text" || bad "quote reply with typed words" "$out"

# 4. at most three lines when many entries match
MANY="$T/many-pool"; mkdir -p "$MANY"
for n in 1 2 3 4 5 6; do entry "$MANY" "feedback-storage-cutover-rule-$n" feedback "Storage cutover rule $n: wait for the backup window before the tenant move" "2026-10-2${n}T10:00:00Z"; done
for n in 1 2 3 4 5 6 7 8 9; do entry "$MANY" "reference-misc-$n" reference "Unrelated note number $n about badges and kiosks" "2026-09-0${n}T10:00:00Z"; done
out="$(hint "what is the storage cutover rule for the backup window before the tenant move" MEMORY_INDEX_DIR="$MANY" MEMORY_DIGEST_ROOT_DIR="$T/none")"
[ "$(printf '%s\n' "$out" | grep -c '^Relevant memory: ')" = 3 ] && ok "six strong matches print exactly three lines" || bad "line cap" "$out"

# 5. which pools: the root pool is read; its type project entries are not, unless pinned
out="$(hint "when I run gh pr merge right after a push and mergeStateStatus is still recomputing, retry once it is CLEAN")"
[[ "$out" == *"Relevant memory: feedback-gh-merge-recompute-race:"* ]] && ok "the root pool is read: a root entry matches from a project cwd" || bad "root pool not read" "$out"
out="$(hint "what is on the storage migration cutover list and the nightly sync window")"
if ! grep -q 'project-workstream-storage-migration' <<< "$out"; then
  ok "the root pool's type project entry (workstream state) is not hinted from a project cwd"
else bad "root project entry hinted" "$out"; fi
out="$(hint "does the storage cutover wait for the backup window or run during business hours")"
[[ "$out" == *"Relevant memory: project-pinned-storage-ruling:"* ]] && ok "a pinned type project entry of the root pool is hinted (it is a ruling)" || bad "pinned project entry" "$out"
# from the OPS cwd itself the root pool's project entries are this directory's own
rootcwd="$(python3 -I -c 'import json,sys; print(json.dumps({"prompt":sys.argv[1],"cwd":sys.argv[2]}))' "what is on the storage migration cutover list and the nightly sync window" "$CW" \
  | env -u CLAUDE_PROJECT_DIR HOME="$T/home" OPS_DIR="$CW" CLAUDE_CONFIG_DIR="$CFG" MEMORY_DIGEST_HOST="$HOST" OPS_STATE_DIR="$ST" bash "$HOOK")"
[[ "$rootcwd" == *"project-workstream-storage-migration"* ]] && ok "from the OPS cwd, the root pool's workstream entries are hinted" || bad "root cwd" "$rootcwd"
# CLAUDE_PROJECT_DIR wins over a payload cwd that drifted (a pool-less scratch dir)
mkdir -p "$T/scratch"
out="$(python3 -I -c 'import json,sys; print(json.dumps({"prompt":sys.argv[1],"cwd":sys.argv[2]}))' "$STRONG" "$T/scratch" \
  | env HOME="$T/home" OPS_DIR="$CW" CLAUDE_CONFIG_DIR="$CFG" MEMORY_DIGEST_HOST="$HOST" OPS_STATE_DIR="$ST" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK")"
[[ "$out" == "$WANT"* ]] \
  && ok "CLAUDE_PROJECT_DIR (the session's start) wins over a drifted payload cwd" || bad "CLAUDE_PROJECT_DIR ignored" "$out"
none="$(python3 -I -c 'import json,sys; print(json.dumps({"prompt":sys.argv[1],"cwd":sys.argv[2]}))' "$STRONG" "$T/scratch" \
  | env -u CLAUDE_PROJECT_DIR HOME="$T/home" OPS_DIR="$CW" CLAUDE_CONFIG_DIR="$CFG" MEMORY_DIGEST_HOST="$HOST" OPS_STATE_DIR="$ST" bash "$HOOK")"
[ -z "$none" ] && ok "a cwd with no pool reads only the root pool: the project's entry is not found" || bad "pool-less cwd matched a project entry" "$none"

# 6. lanes: agent_id, and bin/lane-class (the shared contract: foreman, t3-lane, agent-lane)
M="$T/mirror/.claude-config"; mkdir -p "$M/hooks" "$M/bin"
cp "$(dirname "$HOOK")/memory-hint.sh" "$(dirname "$HOOK")/hooklib.sh" "$M/hooks/"
cp "$(dirname "$HOOK")/../bin/memory-index" "$M/bin/memory-index"
MH="$M/hooks/memory-hint.sh"
lane_out() {  # lane_out <lane-class script body or ->: the hook with a stub bin/lane-class
  rm -f "$M/bin/lane-class"
  [ "$1" = - ] || { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$M/bin/lane-class"; chmod 755 "$M/bin/lane-class"; }
  HOOK="$MH" hint "$STRONG"
}
o="$(lane_out 'echo foreman')";  [[ "$o" == "$WANT"* ]] && ok "lane-class foreman: the hint prints" || bad "foreman suppressed" "$o"
o="$(lane_out 'echo t3-lane')";  [ -z "$o" ] && ok "lane-class t3-lane: nothing" || bad "t3-lane got a hint" "$o"
o="$(lane_out 'echo agent-lane')"; [ -z "$o" ] && ok "lane-class agent-lane: nothing" || bad "agent-lane got a hint" "$o"
o="$(lane_out -)";               [[ "$o" == "$WANT"* ]] && ok "lane-class missing: degrades to foreman, the hint prints" || bad "missing lane-class suppressed" "$o"
o="$(lane_out 'exit 3')";        [[ "$o" == "$WANT"* ]] && ok "lane-class failing (exit 3, no output): degrades to foreman" || bad "failing lane-class suppressed" "$o"
o="$(lane_out 'echo what-is-this')"; [[ "$o" == "$WANT"* ]] && ok "lane-class printing rubbish: treated as foreman" || bad "rubbish lane-class suppressed" "$o"
# the payload reaches lane-class on stdin
o="$(lane_out 'cat > "'"$T"'/lane-stdin"; echo foreman')"
grep -q '"session_id": *"s-1"' "$T/lane-stdin" && ok "lane-class receives the hook payload on stdin" || bad "lane-class got no payload" "$(cat "$T/lane-stdin" 2>&1)"
# a lane-class that would hang is not waited on forever (the hook caps the scorer, not lane-class; a prompt
# in a lane is never blocked longer than lane-class's own 300 ms contract), so only the fast contract is tested.
agent="$(python3 -I -c 'import json,sys; print(json.dumps({"prompt":sys.argv[1],"cwd":sys.argv[2],"agent_id":"a-1"}))' "$STRONG" "$PROJ" \
  | env HOME="$T/home" OPS_DIR="$CW" CLAUDE_CONFIG_DIR="$CFG" MEMORY_DIGEST_HOST="$HOST" OPS_STATE_DIR="$ST" bash "$HOOK")"
[ -z "$agent" ] && ok "a payload with agent_id (an in-process lane) prints nothing" || bad "agent_id got a hint" "$agent"
rm -f "$M/bin/lane-class"

# 7. speed: under 300 ms with a 300-entry pool beside a 300-entry root pool
BIGP="$T/big-pool"; BIGR="$T/big-root"; mkdir -p "$BIGP" "$BIGR"
python3 -I - "$BIGP" "$BIGR" <<'PY'
import os, sys
words = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu".split()
for d, pre in ((sys.argv[1], "p"), (sys.argv[2], "r")):
    for i in range(300):
        stem = f"{pre}-{words[i % 26]}-{words[(i * 7) % 26]}-{i:03d}"
        desc = f"{words[(i * 3) % 26]} {words[(i * 5) % 26]} {words[(i * 11) % 26]} gotcha number {i} with a fix and a date and some more words to make it realistic"
        with open(os.path.join(d, stem + ".md"), "w") as f:
            f.write(f"---\nname: {stem}\ndescription: {desc}\nmetadata:\n  type: reference\n  modified: 2026-10-{1 + i % 28:02d}T00:00:00Z\n---\nbody\n")
PY
MAXMS="${MEMORY_HINT_TEST_MAX_MS:-300}"
ms() { local s e; s="${EPOCHREALTIME/./}"; "$@" >/dev/null 2>&1; e="${EPOCHREALTIME/./}"; echo $(( (e - s) / 1000 )); }
payload_big="$(python3 -I -c 'import json,sys; print(json.dumps({"prompt":sys.argv[1],"cwd":sys.argv[2]}))' "what is the tango whiskey gotcha number 42 with a fix about golf and hotel" "$PROJ")"
runbig() { printf '%s' "$payload_big" | env -u CLAUDE_PROJECT_DIR HOME="$T/home" OPS_DIR="$CW" CLAUDE_CONFIG_DIR="$CFG" MEMORY_DIGEST_HOST="$HOST" \
  OPS_STATE_DIR="$ST" MEMORY_INDEX_DIR="$BIGP" MEMORY_DIGEST_ROOT_DIR="$BIGR" bash "$HOOK"; }
times=""; for _ in 1 2 3 4 5 6 7; do times="$times $(ms runbig)"; done
sorted="$(tr ' ' '\n' <<< "$times" | sed '/^$/d' | sort -n | tr '\n' ' ')"
min="$(awk '{print $1}' <<< "$sorted")"; med="$(awk '{print $4}' <<< "$sorted")"
[ "$min" -lt "$MAXMS" ] && ok "speed: 600 entries, 7 runs: min ${min} ms, median ${med} ms (limit ${MAXMS} ms for the fastest; sorted: $sorted)" || bad "slow: min ${min} ms (sorted $sorted)"
[ "$med" -lt "$MAXMS" ] && ok "speed: the median run is ${med} ms, under ${MAXMS} ms" || bad "median ${med} ms over ${MAXMS} ms"

# 8. read-only, fail-open, logged
AFTER="$(snapshot)"
[ "$BEFORE" = "$AFTER" ] && ok "read-only: the fixture tree is unchanged after every run" || bad "the hook changed the fixture tree"
chmod 000 "$PROJP"
out="$(hint "$STRONG")"; rc=$?
chmod 755 "$PROJP"
if [ "$(id -u)" = 0 ]; then echo "SKIP: unreadable-pool case (running as root reads mode 000 dirs)"
elif [ "$rc" = 0 ] && [ -z "$out" ] && grep -q 'DigestError: cannot list' "$ST/memory-hint.log"; then
  ok "an unreadable pool: nothing printed, exit 0, the failure is one line in memory-hint.log"
else bad "unreadable pool" "rc=$rc out=$out log=$(cat "$ST/memory-hint.log" 2>&1)"; fi
printf 'not json at all' | env HOME="$T/home" OPS_DIR="$CW" OPS_STATE_DIR="$ST" bash "$HOOK" >"$T/o" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/o" ] && ok "a garbled payload: nothing printed, exit 0" || bad "garbled payload" "rc=$rc $(cat "$T/o")"
bash "$HOOK" </dev/null >"$T/o" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/o" ] && ok "an empty stdin: nothing printed, exit 0" || bad "empty stdin" "rc=$rc"
out="$(hint "$STRONG" MEMORY_HINT=0)"; [ -z "$out" ] && ok "MEMORY_HINT=0 turns the hook off" || bad "MEMORY_HINT=0 ignored" "$out"
# The last two cases read the hook's own exit status, so the payload comes from a file (a pipe
# from python would add its own SIGPIPE status when the hook exits before reading stdin).
PF="$T/payload.json"
python3 -I -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":"s-1","cwd":sys.argv[2],"prompt":sys.argv[1]}))' "$STRONG" "$PROJ" > "$PF"
mirror_run() { env -u CLAUDE_PROJECT_DIR HOME="$T/home" OPS_DIR="$CW" CLAUDE_CONFIG_DIR="$CFG" MEMORY_DIGEST_HOST="$HOST" OPS_STATE_DIR="$ST" bash "$MH" < "$PF" 2>/dev/null; }
# a scorer that dies: the stub carries the --hint marker the hook looks for, then exits 7
printf '#!/usr/bin/env python3\n# supports --hint\nimport sys\nsys.exit(7)\n' > "$M/bin/memory-index"
rm -f "$ST/memory-hint.log"
o="$(mirror_run)"; rc=$?
[ "$rc" = 0 ] && [ -z "$o" ] && grep -q 'scorer or input pipe failed (status 7)' "$ST/memory-hint.log" \
  && ok "a crashing scorer: nothing printed, exit 0, the failure is one line in memory-hint.log" || bad "crashing scorer" "rc=$rc o=$o log=$(cat "$ST/memory-hint.log" 2>&1)"
# an indexer that predates --hint: no output and, unlike a crash, no log line on every prompt
printf '#!/usr/bin/env python3\nimport sys\nprint("usage: memory-index [--check] <DIR>", file=sys.stderr)\nsys.exit(1)\n' > "$M/bin/memory-index"
rm -f "$ST/memory-hint.log"
o="$(mirror_run)"; rc=$?
[ "$rc" = 0 ] && [ -z "$o" ] && [ ! -e "$ST/memory-hint.log" ] \
  && ok "an indexer with no --hint: nothing printed, exit 0 and no log line" || bad "indexer without --hint" "rc=$rc o=$o log=$(cat "$ST/memory-hint.log" 2>&1)"

echo
echo "memory-hint-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
