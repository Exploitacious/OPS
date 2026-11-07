#!/usr/bin/env bash
# pre-compact-test.sh: the PreCompact hook's branch-gc step.
#
# pre-compact.sh starts `branch-gc --apply` for the repo holding the cwd,
# detached, and appends one result line to its snapshot. What must hold:
#   - a managed repo (~/OPS, ~/linuxploitacious, ~/OPS/PROJECTS/<org>/<repo>)
#     with a github.com origin gets `--apply <main checkout>`, with the trash
#     purge off (BRANCH_GC_TRASH_DAYS=0) and a soft deadline set
#   - any other repo, a non-GitHub origin, a sub-agent lane's compaction
#     (agent_id in the payload) and PRE_COMPACT_BRANCH_GC=0 never run it
#   - the compaction itself is never held up: the hook returns 0 at once
# It also pins the snapshot's "Deferred tools used before this compaction"
# section: the deferred tools called since the previous compaction, most recent
# first, listed before the reading order so post-compact-resume.sh can tell the
# resumed session which tools to re-select, and no section at all when there is
# nothing to name or the transcript cannot be read.
# branch-gc is a stub that records its arguments; HOME, CLAUDE_CONFIG_DIR and
# every repo are fixtures in this test's own temp dir.
#
# Run (it names a destructive tool, so only inside the sandbox):
#   .claude-config/bin/sandbox-run --no-bind --no-net --ro-bind "$PWD" -- bash .claude-config/bin/tests/pre-compact-test.sh
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks" && pwd)/pre-compact.sh"
[ -f "$HOOK" ] || { echo "FAIL: pre-compact.sh missing at $HOOK"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" CLAUDE_CONFIG_DIR="$T/home/.claude" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

STUB="$T/branch-gc"; CALLS="$T/calls"
cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
printf 'args=%s trash_days=%s deadline=%s\n' "\$*" "\${BRANCH_GC_TRASH_DAYS:-unset}" "\${BRANCH_GC_DEADLINE:-unset}" >> "$CALLS"
echo "Summary (remove / report / quarantine / failed):"
echo "  1 / 0 / 0 / 0"
STUBEOF
chmod +x "$STUB"
export PRE_COMPACT_BRANCH_GC_BIN="$STUB"

mkrepo() { # PATH ORIGIN
  git init -q -b main "$1" && git -C "$1" commit -q --allow-empty -m init && git -C "$1" remote add origin "$2"
}
# snapshot_for CWD: the snapshot file this hook wrote for that cwd (newest).
snapshot_for() { ls -1t "$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$1" | sed 's|/|-|g')"/pre-compact-*.md 2>/dev/null | head -1; }
# run_hook CWD PAYLOAD [ENV...]: run the hook from CWD; prints its exit code.
run_hook() { local cwd="$1" payload="$2"; shift 2; (cd "$cwd" && printf '%s' "$payload" | env "$@" bash "$HOOK" >/dev/null 2>&1; echo $?); }
# wait_line CWD: wait up to 15 s for the branch-gc line in the snapshot.
wait_line() { local i snap; for i in $(seq 1 75); do snap="$(snapshot_for "$1")"; [ -n "$snap" ] && grep -q '^- branch-gc (pre-compact):' "$snap" && { grep '^- branch-gc (pre-compact):' "$snap"; return 0; }; sleep 0.2; done; return 1; }
PAY='{"trigger":"auto","reason":"test"}'

# 1. A managed project repo with a github.com origin.
mkrepo "$HOME/OPS/PROJECTS/acme/widget" "https://github.com/acme/widget.git"
rc="$(run_hook "$HOME/OPS/PROJECTS/acme/widget" "$PAY")"
[ "$rc" = 0 ] && ok "managed repo: hook exits 0" || bad "managed repo: hook exit $rc"
line="$(wait_line "$HOME/OPS/PROJECTS/acme/widget")" || line=""
case "$line" in *"--apply $HOME/OPS/PROJECTS/acme/widget: exit 0; 1 / 0 / 0 / 0 (log ~/.local/state/ops/branch-gc.log)"*) ok "managed repo: result line in the snapshot" ;; *) bad "managed repo: line '$line'" ;; esac
grep -q "^args=--apply $HOME/OPS/PROJECTS/acme/widget trash_days=0 deadline=[1-9][0-9]*$" "$CALLS" 2>/dev/null \
  && ok "managed repo: --apply on the main checkout, purge off, deadline set" || bad "managed repo: calls $(cat "$CALLS" 2>/dev/null)"

# 2. A linked worktree of it: branch-gc gets the main checkout, not the worktree.
: > "$CALLS"
git -C "$HOME/OPS/PROJECTS/acme/widget" worktree add -q -b lane "$HOME/OPS/PROJECTS/acme/widget/.claude/worktrees/lane"
rc="$(run_hook "$HOME/OPS/PROJECTS/acme/widget/.claude/worktrees/lane" "$PAY")"
line="$(wait_line "$HOME/OPS/PROJECTS/acme/widget/.claude/worktrees/lane")" || line=""
grep -q "^args=--apply $HOME/OPS/PROJECTS/acme/widget trash_days=0" "$CALLS" 2>/dev/null \
  && ok "linked worktree: branch-gc runs on the main checkout" || bad "linked worktree: calls $(cat "$CALLS" 2>/dev/null); line '$line'"

# 3. A repo outside the managed set: noted, never run.
: > "$CALLS"
mkrepo "$HOME/elsewhere/repo" "https://github.com/acme/other.git"
run_hook "$HOME/elsewhere/repo" "$PAY" >/dev/null
line="$(wait_line "$HOME/elsewhere/repo")" || line=""
case "$line" in *"not run: $HOME/elsewhere/repo is not a repo branch-gc manages"*) ok "unmanaged repo: noted, not run" ;; *) bad "unmanaged repo: line '$line'" ;; esac
[ ! -s "$CALLS" ] && ok "unmanaged repo: branch-gc never called" || bad "unmanaged repo: called $(cat "$CALLS")"

# 4. A managed path whose origin is not GitHub: noted, never run.
mkrepo "$HOME/OPS/PROJECTS/acme/gitea" "https://git.example.invalid/acme/gitea.git"
run_hook "$HOME/OPS/PROJECTS/acme/gitea" "$PAY" >/dev/null
line="$(wait_line "$HOME/OPS/PROJECTS/acme/gitea")" || line=""
case "$line" in *"has no github.com origin"*) ok "non-GitHub origin: noted, not run" ;; *) bad "non-GitHub origin: line '$line'" ;; esac
[ ! -s "$CALLS" ] && ok "non-GitHub origin: branch-gc never called" || bad "non-GitHub origin: called $(cat "$CALLS")"

# 5. A sub-agent lane's compaction and the off switch: no run, no line.
for kind in lane off; do
  : > "$CALLS"
  d="$HOME/OPS/PROJECTS/acme/$kind"; mkrepo "$d" "https://github.com/acme/$kind.git"
  if [ "$kind" = lane ]; then rc="$(run_hook "$d" '{"trigger":"auto","agent_id":"a1b2c3"}')"
  else rc="$(run_hook "$d" "$PAY" PRE_COMPACT_BRANCH_GC=0)"; fi
  sleep 1
  snap="$(snapshot_for "$d")"
  [ "$rc" = 0 ] && [ -n "$snap" ] && ! grep -q 'branch-gc (pre-compact)' "$snap" && [ ! -s "$CALLS" ] \
    && ok "$kind: snapshot written, branch-gc not run" || bad "$kind: rc=$rc snap=$snap calls=$(cat "$CALLS" 2>/dev/null)"
done

# 6. The deferred-tools section of the snapshot. A compaction drops every deferred tool's
# schema; the hook records the ones this session called (mcp-reselect.py, from the
# transcript) so the resume hook can name them. Plain directories (no repo), so the
# branch-gc step has nothing to do and the snapshot is only what this section needs.
tool_line()     { printf '{"type":"assistant","isSidechain":%s,"message":{"role":"assistant","content":[{"type":"text","text":"x"},{"type":"tool_use","id":"t","name":"%s","input":{}}]}}\n' "${2:-false}" "$1"; }
boundary_line() { printf '{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":1},"timestamp":"2026-10-01T00:00:00.000Z"}\n'; }
SECTION="## Deferred tools used before this compaction"
# deferred_run NAME PAYLOAD-TRANSCRIPT-ARG: run the hook from a fresh work dir NAME whose
# transcript is already in $T/NAME.jsonl; $2 is "path" (payload names it) or "nopath".
deferred_run() {
  local d="$HOME/deferred/$1" payload
  mkdir -p "$d"
  if [ "$2" = path ]; then payload="{\"trigger\":\"manual\",\"reason\":\"test\",\"transcript_path\":\"$T/$1.jsonl\"}"
  else payload='{"trigger":"manual","reason":"test"}'; fi
  run_hook "$d" "$payload" >/dev/null
  snapshot_for "$d"
}
# listed SNAPSHOT: the tool names under the section, one per line
listed() { awk -v s="$SECTION" '$0 == s {on=1; next} on && /^## / {on=0} on && /^- / {sub(/^- /,""); print}' "$1"; }

{ tool_line mcp__old__before_the_last_boundary; boundary_line
  tool_line mcp__example-server__lookup; tool_line Bash; tool_line Monitor
  tool_line mcp__example-other__read; tool_line mcp__example-server__lookup
  tool_line mcp__sidechain__ignored true; } > "$T/since-boundary.jsonl"
snap="$(deferred_run since-boundary path)"
got="$(listed "$snap" | tr '\n' ' ')"
[ "$got" = "mcp__example-server__lookup mcp__example-other__read Monitor " ] \
  && ok "deferred tools: the calls since the previous boundary, most recent first, a repeat once, plain and sidechain tools left out" \
  || bad "deferred tools: listed '$got'"
grep -q "re-select each with ToolSearch" "$snap" && ok "deferred tools: the section tells the resumed session to re-select" || bad "deferred tools: no instruction in the section"
[ "$(grep -n "^$SECTION" "$snap" | cut -d: -f1)" -lt "$(grep -n '^## Post-compact reading order' "$snap" | cut -d: -f1)" ] \
  && ok "deferred tools: the section sits before the reading order, so a later appended line never lands inside it" || bad "deferred tools: section order"

{ tool_line mcp__a__one; tool_line mcp__b__two; } > "$T/no-boundary.jsonl"
snap="$(deferred_run no-boundary path)"
[ "$(listed "$snap" | tr '\n' ' ')" = "mcp__b__two mcp__a__one " ] \
  && ok "deferred tools: with no boundary in the transcript the whole window counts" || bad "deferred tools: no-boundary list '$(listed "$snap" | tr '\n' ' ')'"

{ boundary_line; tool_line Bash; tool_line Read; } > "$T/plain-tools.jsonl"
snap="$(deferred_run plain-tools path)"
! grep -q "^$SECTION" "$snap" && grep -q '^## Git state' "$snap" \
  && ok "deferred tools: only plain tools called, so no section and the snapshot is as before" || bad "deferred tools: section written for plain tools"

rm -f "$T/missing.jsonl"
snap="$(deferred_run missing path)"
[ -n "$snap" ] && ! grep -q "^$SECTION" "$snap" && ok "deferred tools: a transcript that does not exist never blocks the snapshot" || bad "deferred tools: missing transcript (snapshot '$snap')"
printf 'not json\n{broken\n' > "$T/garbage.jsonl"; tool_line mcp__a__one >> "$T/garbage.jsonl"
snap="$(deferred_run garbage path)"
[ "$(listed "$snap" | tr '\n' ' ')" = "mcp__a__one " ] && ok "deferred tools: garbage lines in the transcript are skipped" || bad "deferred tools: garbage transcript list '$(listed "$snap" | tr '\n' ' ')'"
tool_line mcp__a__one > "$T/nopath.jsonl"
snap="$(deferred_run nopath nopath)"
[ -n "$snap" ] && ! grep -q "^$SECTION" "$snap" && grep -q '^## Git state' "$snap" \
  && ok "deferred tools: a payload with no transcript_path writes the plain snapshot" || bad "deferred tools: no transcript_path"

echo "pre-compact-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
