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

echo "pre-compact-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
