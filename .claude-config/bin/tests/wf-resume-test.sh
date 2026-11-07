#!/usr/bin/env bash
# wf-resume-test.sh: behavior tests for bin/wf-resume, the read-only reader that
# lists workflow lanes which never returned after a usage-limit hold or crash and
# prints the relaunch command.
#
# Two parts. A fixture run built in a temp projects directory (a corrupt journal
# row, a retried lane, an interrupted lane working in a real linked git worktree,
# an idle lane, an active lane, a failed lane, a lane with no transcript) checks
# every classification and output line with a fixed clock. Then a smoke test reads
# a REAL journal with a never-returned lane from ~/.claude/projects (read-only; it
# hashes the run directory before and after) and checks the script agrees with an
# independent count. The real part skips when Claude Code has already deleted
# every such journal (cleanupPeriodDays).
#
# The invariants:
#   1. A lane's final state is its key's last journal row; a retry that returned
#      is not reported.
#   2. never returned = started with no later result or failed; its status is
#      interrupted (transcript ends on the interrupt marker), idle (quiet past
#      --stale-min), active (recent), or no-transcript.
#   3. Exit 1 when any lane never returned, 0 when none, 2 on a usage error.
#   4. The relaunch line names the persisted script and the run id; a missing
#      script says so instead of inventing a path.
#   5. Nothing is written: the run directory hashes the same afterwards.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$HERE/../wf-resume"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }
has() { # label needle (in $OUT)
  case "$OUT" in *"$2"*) pass "$1" ;; *) fail "$1: output lacks '$2'" ;; esac
}
hasnt() {
  case "$OUT" in *"$2"*) fail "$1: output has '$2'" ;; *) pass "$1" ;; esac
}
run() { OUT="$("$@" 2>"$TMP/err")"; RC=$?; ERR="$(cat "$TMP/err")"; }

printf 'wf-resume-test:\n'
[ -x "$WF" ] || { echo "not executable: $WF" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "need git" >&2; exit 1; }

NOW="2026-11-07T12:00:00Z"
P="$TMP/projects"; WS="$P/-home-fixture"; S="sess-fixture-1"
RUN="$WS/$S/subagents/workflows/wf_fix-001"; RUN2="$WS/$S/subagents/workflows/wf_fix-002"; RUN3="$WS/$S/subagents/workflows/wf_fix-003"
mkdir -p "$RUN" "$RUN2" "$RUN3" "$WS/$S/workflows/scripts"
printf '// fixture script\n' > "$WS/$S/workflows/scripts/fixture-wf_fix-001.js"
printf '// fixture script\n' > "$WS/$S/workflows/scripts/fixture-wf_fix-002.js"

# A real repo with a linked worktree: one commit ahead of origin/master and one
# dirty file, so the worktree line has something to report.
REPO="$TMP/repo"; WT="$TMP/repo-lane-wt"
git init -q -b master "$REPO" && git -C "$REPO" config user.email t@example.com && git -C "$REPO" config user.name t \
  && git -C "$REPO" config commit.gpgsign false \
  && echo one > "$REPO/a.txt" && git -C "$REPO" add a.txt && git -C "$REPO" commit -q -m "base commit" \
  && git -C "$REPO" update-ref refs/remotes/origin/master HEAD \
  && git -C "$REPO" worktree add -q -b lane-branch "$WT" \
  && echo two > "$WT/b.txt" && git -C "$WT" add b.txt && git -C "$WT" commit -q -m "lane partial work" \
  && echo dirty > "$WT/c.txt" || { echo "fixture repo failed" >&2; exit 1; }

python3 - "$RUN" "$RUN2" "$RUN3" "$WT" "$REPO" <<'PY'
import json, os, sys
run, run2, run3, wt, repo = sys.argv[1:6]
def ts(h, m): return "2026-11-07T%02d:%02d:00Z" % (h, m)
def row(**k): return json.dumps(k) + "\n"
def transcript(path, last_ts, last_text=None, cwd=None, last_type="assistant"):
    recs = [{"type": "user", "timestamp": ts(7, 0), "cwd": cwd, "message": {"role": "user", "content": "go"}}]
    if last_text:
        recs.append({"type": "user", "timestamp": last_ts, "cwd": cwd, "message": {"role": "user", "content": [{"type": "text", "text": last_text}]}})
    else:
        recs.append({"type": last_type, "timestamp": last_ts, "cwd": cwd, "message": {"content": [{"type": "text", "text": "working"}]}})
    open(path, "w").write("".join(json.dumps(r) + "\n" for r in recs))
j = open(os.path.join(run, "journal.jsonl"), "w")
j.write(row(type="launched"))
for key, agent, label, phase in [("k1", "A1", "lane-returned", "Build"), ("k2", "A2", "lane-retried", "Build"), ("k3", "A3", "lane-interrupted", "Build"),
                                 ("k4", "A4", "lane-idle", "Verify"), ("k5", "A5", "lane-active", "Verify"), ("k6", "A7", "lane-failed", "Verify"), ("k7", "A8", "lane-notranscript", "Verify")]:
    j.write(row(type="started", key=key, agentId=agent, label=label, phase=phase))
j.write("this line is not json\n")
j.write(row(type="result", key="k1", agentId="A1", result="done", toolsUsed=[]))
j.write(row(type="failed", key="k2", agentId="A2"))
j.write(row(type="started", key="k2", agentId="A6", label="lane-retried", phase="Build"))
j.write(row(type="result", key="k2", agentId="A6", result="done on retry"))
j.write(row(type="failed", key="k6", agentId="A7"))
j.close()
transcript(os.path.join(run, "agent-A3.jsonl"), ts(10, 30), last_text="[Request interrupted by user]", cwd=wt)
transcript(os.path.join(run, "agent-A4.jsonl"), ts(10, 0), cwd=repo)
transcript(os.path.join(run, "agent-A5.jsonl"), ts(11, 58), cwd=repo, last_type="api-request")
transcript(os.path.join(run, "agent-A7.jsonl"), ts(9, 0), cwd=repo)
json.dump({"agentType": "workflow-subagent", "description": "lane-failed", "workflowPhase": "Verify"}, open(os.path.join(run, "agent-A7.meta.json"), "w"))
# run 2: everything returned. run 3: a never-returned lane with no persisted script.
open(os.path.join(run2, "journal.jsonl"), "w").write(row(type="launched") + row(type="started", key="a", agentId="B1", label="only", phase="P") + row(type="result", key="a", agentId="B1", result="ok"))
open(os.path.join(run3, "journal.jsonl"), "w").write(row(type="launched") + row(type="started", key="a", agentId="C1", label="orphan", phase="P"))
transcript(os.path.join(run3, "agent-C1.jsonl"), ts(11, 59), cwd=repo)
PY

snapshot() { (cd "$P" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16); }
BEFORE="$(snapshot)"
# The linked worktree's own index. Touching a tracked file makes its cached stat
# data stale: a plain `git status` then refreshes the entry and rewrites the index
# under index.lock (a write into a live lane's worktree); `--no-optional-locks`
# only reads. A bare file-content hash cannot see this, so hash the index itself.
WT_INDEX="$(git -C "$WT" rev-parse --path-format=absolute --git-path index)"
touch -d "10 seconds ago" "$WT/b.txt"   # ctime and mtime now differ from the cached stat data
IDX_BEFORE="$(sha256sum "$WT_INDEX" | cut -c1-16)"

# --- detail of the fixture run ----------------------------------------------
run "$WF" "$RUN" --now "$NOW" --stale-min 15
[ "$RC" -eq 1 ] && pass "exit 1 when a lane never returned" || fail "exit code $RC, want 1 (err: $ERR)"
has "counts line" "7 lanes started, 2 returned, 1 failed, 4 never returned"
has "never-returned header" "NEVER RETURNED (4):"
has "interrupted lane is named and called dead" "lane-interrupted"
has "interrupt marker is read" 'INTERRUPTED: its transcript ends on "[Request interrupted by user]"'
has "idle lane shows its age in hours" "idle 2.0 h"
has "active lane is flagged do-not-relaunch" "ACTIVE 2 min ago"
has "active lane carries the warning" "do not relaunch it"
has "a lane with no transcript says so" "no transcript file for this lane (agent A8)"
has "failed lane listed apart" "FAILED (1; returned an error"
has "the retried lane that returned is not reported" "7 lanes started, 2 returned"
hasnt "retried lane absent from the list" "lane-retried  (phase"
has "worktree branch and counts" "branch lane-branch, 1 changed file(s), 1 commit(s) ahead of origin/master"
has "worktree last commit" 'last commit "'
has "worktree line names the commit subject" "lane partial work"
has "shared-checkout lanes say where their edits are" "not a linked worktree"
has "relaunch names script and run id" "Workflow({scriptPath: \"$WS/$S/workflows/scripts/fixture-wf_fix-001.js\", resumeFromRunId: \"wf_fix-001\"})"
has "resume note present" "RESUMED RUN: a usage-limit hold"
has "no SendMessage warning" "Never SendMessage a workflow lane"
has "cache warning" "Editing a returned lane's prompt makes it miss the cache"
has "skipped corrupt journal row is reported" "1 journal row(s) could not be parsed"

# A lane inside the stale window flips status with the threshold.
run "$WF" "$RUN" --now "$NOW" --stale-min 1
has "a tighter --stale-min turns the 2 minute lane idle" "lane-active"
case "$OUT" in *"ACTIVE 2 min ago"*) fail "--stale-min 1 should not leave the 2 minute lane active" ;; *) pass "--stale-min changes the verdict" ;; esac

# --- JSON ---------------------------------------------------------------------
run "$WF" "$RUN" --now "$NOW" --json
JSON_CHECK="$(printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = d["counts"]
st = {l["label"]: l["status"] for l in d["never_returned"]}
ok = (c == {"started": 7, "returned": 2, "failed": 1, "never_returned": 4}
      and st == {"lane-interrupted": "interrupted", "lane-idle": "idle", "lane-active": "active", "lane-notranscript": "no-transcript"}
      and d["failed"][0]["label"] == "lane-failed" and d["failed"][0]["status"] == "failed"
      and d["relaunch"].endswith("resumeFromRunId: \"wf_fix-001\"})")
      and any(l["worktree"] and l["worktree"].get("ahead") == 1 and l["worktree"]["changed_files"] == 1 for l in d["never_returned"]))
print("ok" if ok else "bad: %s" % json.dumps(c))' 2>&1)"
[ "$JSON_CHECK" = ok ] && pass "--json carries the same facts" || fail "--json: $JSON_CHECK"

# --- the printed zone ------------------------------------------------------------
# Times print in the zone WF_RESUME_TZ names, else the machine's local one. The idle
# lane's last activity is 10:00Z, so Tokyo reads 19:00 JST and UTC reads 10:00 UTC.
run env WF_RESUME_TZ=Asia/Tokyo "$WF" "$RUN" --now "$NOW" --stale-min 15
has "WF_RESUME_TZ sets the zone times print in" "11-07 19:00 JST"
run env WF_RESUME_TZ=UTC "$WF" "$RUN" --now "$NOW" --stale-min 15
has "WF_RESUME_TZ=UTC prints UTC" "11-07 10:00 UTC"
run env WF_RESUME_TZ=Not/AZone "$WF" "$RUN" --now "$NOW"
[ "$RC" -eq 2 ] && case "$ERR" in *"not an IANA zone name"*) pass "a bad WF_RESUME_TZ is a usage error, not a silent fallback" ;; *) fail "bad zone message: $ERR" ;; esac || fail "bad WF_RESUME_TZ rc=$RC"

# --- resolving a run -----------------------------------------------------------
run env WF_RESUME_PROJECTS="$TMP/empty-projects" "$WF" wf_fix-001 --now "$NOW"
[ "$RC" -eq 2 ] && pass "a run id outside the projects roots is a usage error" || fail "id outside roots rc=$RC"
export WF_RESUME_PROJECTS="$P"
run "$WF" wf_fix-001 --now "$NOW"; [ "$RC" -eq 1 ] && has "a run id resolves under WF_RESUME_PROJECTS" "7 lanes started" || fail "run id resolve rc=$RC err=$ERR"
run "$WF" wf_fix-001/journal.jsonl --now "$NOW"; [ "$RC" -eq 2 ] && pass "a nonexistent path is a usage error" || fail "bad path rc=$RC"
run "$WF" "$RUN/journal.jsonl" --now "$NOW"; [ "$RC" -eq 1 ] && has "a journal.jsonl path resolves" "7 lanes started" || fail "journal path rc=$RC"
run "$WF" wf_fix --now "$NOW"; case "$ERR" in *"matches 3 runs"*) pass "an ambiguous prefix names the candidates" ;; *) fail "ambiguous prefix: rc=$RC err=$ERR" ;; esac
run "$WF" wf_nope-999 --now "$NOW"; case "$ERR" in *"no workflow run matches"*) [ "$RC" -eq 2 ] && pass "an unknown run is a usage error" || fail "unknown run rc=$RC" ;; *) fail "unknown run msg: $ERR" ;; esac

# --- a clean run, and a run whose script is missing -----------------------------
run "$WF" "$RUN2" --now "$NOW"
[ "$RC" -eq 0 ] && pass "exit 0 when every lane returned" || fail "clean run rc=$RC"
has "clean run counts" "1 lanes started, 1 returned, 0 failed, 0 never returned"
hasnt "clean run prints no relaunch" "RELAUNCH"
run "$WF" "$RUN3" --now "$NOW"
[ "$RC" -eq 1 ] && has "a missing persisted script is said, not invented" "persisted script for wf_fix-003 was not found" || fail "run3 rc=$RC"
hasnt "no invented script path" "Workflow({scriptPath"

# --- session list ----------------------------------------------------------------
run "$WF" --session "$S" --now "$NOW"
[ "$RC" -eq 1 ] && pass "session list exits 1 when any run has a dead lane" || fail "session list rc=$RC"
has "list names the flagged run" "wf_fix-001  7 started, 2 returned, 1 failed  NEVER RETURNED 4"
has "list shows a clean run as returned" "wf_fix-002  1 started, 1 returned, 0 failed  all returned"
has "list points at the detail command" "Detail: wf-resume <run id>"
run "$WF" --session "no-such-session" --now "$NOW"; [ "$RC" -eq 0 ] && has "a session with no runs is clean" "no workflow runs found" || fail "empty session rc=$RC"
run env -u CLAUDE_CODE_SESSION_ID "$WF"; [ "$RC" -eq 2 ] && pass "no run and no session is a usage error" || fail "no-arg rc=$RC"
run env CLAUDE_CODE_SESSION_ID="$S" "$WF" --now "$NOW"; [ "$RC" -eq 1 ] && has "the session defaults to CLAUDE_CODE_SESSION_ID" "wf_fix-001" || fail "env session rc=$RC"

# --- read-only --------------------------------------------------------------------
AFTER="$(snapshot)"
[ "$BEFORE" = "$AFTER" ] && pass "the run directories hash the same afterwards (read-only)" || fail "fixture files changed: $BEFORE -> $AFTER"
IDX_AFTER="$(sha256sum "$WT_INDEX" | cut -c1-16)"
[ "$IDX_BEFORE" = "$IDX_AFTER" ] && pass "the lane worktree's index is byte-identical afterwards (no stat refresh, no index.lock write)" || fail "wf-resume rewrote the lane worktree's index: $IDX_BEFORE -> $IDX_AFTER (git status without --no-optional-locks?)"
[ ! -e "$WT_INDEX.lock" ] && pass "no index.lock is left behind" || fail "index.lock left in the lane worktree"
[ "$(git -C "$WT" status --short | wc -l)" -eq 1 ] && pass "the lane worktree was not touched (still just the one untracked file)" || fail "worktree status changed: $(git -C "$WT" status --short | tr '\n' ' ')"
unset WF_RESUME_PROJECTS

# --- a real journal, read-only -----------------------------------------------------
REAL="$(python3 - <<'PY'
import glob, json, os, time
best = None
for j in glob.glob(os.path.expanduser("~/.claude/projects/*/*/subagents/workflows/wf_*/journal.jsonl")):
    if time.time() - os.path.getmtime(j) < 86400: continue   # not a run that may still be live
    state = {}
    for line in open(j):
        try: r = json.loads(line)
        except Exception: continue
        if r.get("type") in ("started", "result", "failed") and (r.get("key") or r.get("agentId")):
            state[r.get("key") or r.get("agentId")] = r["type"]
    n = sum(1 for v in state.values() if v == "started")
    if n and (best is None or os.path.getmtime(j) > best[2]): best = (os.path.dirname(j), n, os.path.getmtime(j))
print("%s\t%d" % (best[0], best[1]) if best else "")
PY
)"
if [ -z "$REAL" ]; then
  printf '  SKIP  real journal: no run older than a day with a never-returned lane under ~/.claude/projects\n'
else
  RDIR="${REAL%%$'\t'*}"; RN="${REAL##*$'\t'}"
  RBEFORE="$(find "$RDIR" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)"
  run "$WF" "$RDIR"
  [ "$RC" -eq 1 ] && pass "real journal: exit 1" || fail "real journal rc=$RC err=$ERR"
  has "real journal: the count matches an independent scan" "NEVER RETURNED ($RN):"
  RAFTER="$(find "$RDIR" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)"
  [ "$RBEFORE" = "$RAFTER" ] && pass "real journal: untouched" || fail "real journal changed"
fi

# --- the args prelude documented beside it runs ----------------------------------
# A mounted dynamic-workflows skill carries the prelude every workflow script
# starts with in authoring-workflows.md. The doc is the only copy, so when it is
# there it is executed here under node against every args shape that crashed real
# scripts (undefined, a JSON string, a stringified array, the wrong type) and every
# JSON string that parses to a non-object (null, a number, a boolean). A copy that
# does not mount the skill, or mounts a version from before the prelude, has
# nothing to run: that is a SKIP that says why, never a failure of this tool.
DOC="$HERE/../../../SKILLS/dynamic-workflows/authoring-workflows.md"
if ! command -v node >/dev/null 2>&1; then
  printf '  SKIP  args prelude: node is not installed\n'
elif [ ! -f "$DOC" ]; then
  printf '  SKIP  args prelude: SKILLS/dynamic-workflows is not mounted in this copy\n'
elif ! grep -q '^// Args prelude' "$DOC" 2>/dev/null; then
  printf '  SKIP  args prelude: the mounted dynamic-workflows copy has no "// Args prelude" block (it predates the prelude; sync the mount)\n'
else
  PRELUDE_OUT="$(DOC="$DOC" node -e '
const fs = require("fs");
const md = fs.readFileSync(process.env.DOC, "utf8");
const start = md.indexOf("// Args prelude");
const end = md.indexOf("```", start);
const code = md.slice(start, end);
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const run = new AsyncFunction("args", "log", code + "\nreturn { ok: true, n: LANES.length, A };");
const logs = [];
const cases = [
  ["undefined", undefined, false],
  ["null", null, false],
  ["not json", "not json", false],
  ["empty string", "", false],
  ["number", 5, false],
  ["array as args", [], false],
  ["lanes is a number", { lanes: 5 }, false],
  ["lanes is text that is not JSON", { lanes: "abc" }, false],
  ["object with two lanes", { lanes: [1, 2] }, 2],
  ["JSON string args", JSON.stringify({ lanes: [1, 2, 3] }), 3],
  ["lanes stringified inside the object", { lanes: "[1,2,3,4]" }, 4],
  // JSON.parse turns these strings into null, a number, a boolean, an array and
  // an object, and the prelude must still reach its clean "no lanes" return. The
  // string "null" threw "Cannot read properties of null (reading 'lanes')" in a
  // first version: the parsed value was used without the object check the
  // unparsed one got.
  ["the JSON string null", "null", false],
  ["the JSON string 5", "5", false],
  ["the JSON string true", "true", false],
  ["the JSON string []", "[]", false],
  ["the JSON string {}", "{}", false],
  ["the JSON string of a quoted string", "\"x\"", false],
  ["boolean true", true, false],
  ["empty object", {}, false],
  ["lanes null", { lanes: null }, false],
  ["lanes is an object, not an array", { lanes: { a: 1 } }, false],
  ["lanes is the JSON string null", { lanes: "null" }, false],
  ["JSON string with lanes stringified inside it", "{\"lanes\":\"[1,2]\"}", 2],
  ["a bare array of lanes (no lanes key)", [1, 2], false],
];
(async () => {
  let bad = 0;
  for (const [name, input, want] of cases) {
    let out;
    try { out = await run(input, (m) => logs.push(m)); } catch (e) { console.log("THROWS " + name + ": " + e.message); bad++; continue; }
    const okShape = want === false ? out.error === "no lanes in args" : out.ok === true && out.n === want;
    if (!okShape) { console.log("WRONG " + name + ": " + JSON.stringify(out)); bad++; }
  }
  if (logs.length !== cases.filter((c) => c[2] === false).length) { console.log("log calls: " + logs.length); bad++; }
  console.log(bad === 0 ? "all-ok " + cases.length : "bad");
})();
' 2>&1)"
  case "$PRELUDE_OUT" in
    "all-ok "*) pass "the documented args prelude survives all ${PRELUDE_OUT#all-ok } args shapes (the JSON string null included)" ;;
    *) fail "args prelude: $PRELUDE_OUT" ;;
  esac
fi

# --- no em or en dashes ---------------------------------------------------------------
if grep -q -e "$(printf '\342\200\224')" -e "$(printf '\342\200\223')" "$WF" 2>/dev/null; then fail "wf-resume contains an em or en dash"; else pass "wf-resume has no em or en dashes"; fi

if [ "$fails" -eq 0 ]; then printf 'wf-resume-test: all passed\n'; exit 0; fi
printf 'wf-resume-test: %d failed\n' "$fails" >&2
exit 1
