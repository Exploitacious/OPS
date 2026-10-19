#!/usr/bin/env bash
# daily-sync-test.sh: the daily backup commits every run but pushes only to an
# origin the push gate (bin/origin-private-check) verifies private, and its
# project stage runs either way.
#
# daily-sync.sh backs up $HOME/OPS, so the test points HOME at a throwaway tree
# and never touches the real copy. origin is a GitHub URL, so the gate asks a
# stubbed gh; a fake ssh serves that URL from a local bare repo, so pulls work
# offline and a push that does happen lands there. Asserts:
#   - public origin: the day's commit stays local, the remote is unchanged, the
#     log names the skip and its reason, and the project stage still runs
#   - private origin, clean tree: the held commit goes out
#   - private origin, new changes: committed and pushed
#   - unverifiable origin: skipped with the opt-in fix in the log
#   - an empty or truncated gate (both exit 0) is not a verdict: nothing pushed
#   - a failed pull (unreachable origin, or a rebase that conflicts) leaves the
#     tree exactly as it was: tracked edits, staged changes, untracked files,
#     HEAD, and no leftover stash or rebase
#
# Run:  bash ~/OPS/.claude-config/bin/tests/daily-sync-test.sh
set -uo pipefail

CFG="$(cd "$(dirname "$0")/../.." && pwd)"
SYNC="$CFG/backup/daily-sync.sh"
CHECK="$CFG/bin/origin-private-check"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/daily-sync-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; [ -f "${LOG:-}" ] && sed 's/^/  log: /' "$LOG" >&2; exit 1; }
pass() { echo "PASS: $*"; }

unset OPS_DIR
export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GH_ANSWER=false PUSH_LOG="$WORK/push.log" FAKE_REMOTE="$WORK/remote.git"
mkdir -p "$HOME" "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$GH_ANSWER" = error ] && exit 1
printf '%s\n' "$GH_ANSWER"
STUB
cat > "$WORK/fake-ssh" <<'STUB'
#!/usr/bin/env bash
case "${*: -1}" in
  git-upload-pack*) exec git upload-pack "$FAKE_REMOTE" ;;
  git-receive-pack*) echo receive-pack >> "$PUSH_LOG"; exec git receive-pack "$FAKE_REMOTE" ;;
esac
exit 1
STUB
chmod +x "$WORK/bin/gh" "$WORK/fake-ssh"
export PATH="$WORK/bin:$PATH" GIT_SSH_COMMAND="$WORK/fake-ssh" GIT_SSH_VARIANT=ssh

# A minimal copy: the gate where daily-sync looks for it, the sync.log ignore
# every copy ships, and a project-stage stub that leaves a trace in the log.
SEED="$WORK/seed"
git init -q -b main "$SEED" || fail "git init"
mkdir -p "$SEED/.claude-config/bin" "$SEED/PROJECTS"
cp "$CHECK" "$SEED/.claude-config/bin/origin-private-check"
printf '.claude-config/backup/sync.log\n' > "$SEED/.gitignore"
printf '#!/usr/bin/env bash\necho "projects stage ran ($1)"\n' > "$SEED/PROJECTS/sync-check.sh"
git -C "$SEED" add -A && git -C "$SEED" commit -q -m seed || fail "seed commit"
git clone -q --bare "$SEED" "$FAKE_REMOTE" || fail "bare clone"
OPS="$HOME/OPS"
git clone -q git@github.com:acme/ops-copy.git "$OPS" || fail "clone through the fake ssh"
LOG="$OPS/.claude-config/backup/sync.log"
remote_head() { git -C "$FAKE_REMOTE" rev-parse main; }
local_head() { git -C "$OPS" rev-parse HEAD; }
run_sync() { rm -f "$LOG"; bash "$SYNC" || fail "daily-sync exited non-zero"; }

# --- Public origin: commit locally, never push, projects still sync ----------
before="$(remote_head)"
printf 'private note\n' > "$OPS/note.md"
GH_ANSWER=false run_sync
grep -q 'OPS: WARN push skipped, commit kept locally: origin-private-check: public: github.com/acme/ops-copy is public' "$LOG" \
  || fail "public origin skip not logged with its reason"
grep -q 'gh repo edit acme/ops-copy --visibility private' "$LOG" || fail "the fix is not in the log"
[ "$(git -C "$OPS" log -1 --format=%s)" = "Daily Backup $(date '+%Y-%m-%d')" ] || fail "the day's commit was not made"
[ -z "$(git -C "$OPS" status --porcelain)" ] || fail "the tree is not clean after the commit"
[ "$(remote_head)" = "$before" ] && [ ! -e "$PUSH_LOG" ] || fail "pushed to a public origin"
grep -q 'projects stage ran (--auto)' "$LOG" || fail "the project stage did not run after the skip"
pass "public origin: commit kept locally, nothing pushed, project stage still ran"

# --- Private origin, clean tree: the held commit goes out --------------------
GH_ANSWER=true run_sync
grep -q 'OPS: backup pushed successfully (origin-private-check: private: github.com/acme/ops-copy is private)' "$LOG" \
  || fail "held commit push not logged"
[ "$(remote_head)" = "$(local_head)" ] || fail "the held commit was not pushed on a clean run"
pass "private origin: a commit held by an earlier skip is pushed on the next clean run"

# --- Private origin, new changes: committed and pushed ------------------------
printf 'another note\n' > "$OPS/note2.md"
GH_ANSWER=true run_sync
[ "$(remote_head)" = "$(local_head)" ] || fail "new changes were not pushed to a private origin"
git -C "$FAKE_REMOTE" cat-file -e main:note2.md || fail "the pushed commit lacks the new file"
grep -q 'projects stage ran (--auto)' "$LOG" || fail "the project stage did not run"
pass "private origin: new changes are committed and pushed"

# --- Unverifiable origin: skipped, with the opt-in in the fix -----------------
before="$(remote_head)"
printf 'third note\n' > "$OPS/note3.md"
GH_ANSWER=error run_sync
grep -q 'OPS: WARN push skipped, commit kept locally: origin-private-check: unverified: gh could not read github.com/acme/ops-copy' "$LOG" \
  || fail "unverifiable origin skip not logged"
grep -q 'gh auth login), or confirm the repo is private, then run: git -C ".*" config ops.pushVerified true' "$LOG" \
  || fail "the gh sign-in and opt-in fix is not in the log"
[ "$(remote_head)" = "$before" ] || fail "pushed to an unverified origin"
pass "unverifiable origin: commit kept locally, the log names gh auth and the opt-in"

# --- A failed commit is an error, never a backup ------------------------------
# (2026-10-19: a fresh install whose commit failed logged "commit kept locally",
# or "pushed successfully", for a backup that did not exist)
before="$(remote_head)"; head_before="$(local_head)"
printf 'fourth note\n' > "$OPS/note4.md"
printf '#!/usr/bin/env bash\nexit 1\n' > "$OPS/.git/hooks/pre-commit"; chmod +x "$OPS/.git/hooks/pre-commit"
GH_ANSWER=true run_sync
grep -q 'OPS: ERROR commit failed; changes left staged, nothing pushed' "$LOG" || fail "a failed commit was not logged as an error"
if grep -q -e 'backup pushed successfully' -e 'commit kept locally' "$LOG"; then fail "a failed commit was reported as a backup"; fi
[ "$(local_head)" = "$head_before" ] && [ "$(remote_head)" = "$before" ] || fail "a commit or push happened after the commit failed"
grep -q 'projects stage ran (--auto)' "$LOG" || fail "the project stage did not run after the failed commit"
rm -f "$OPS/.git/hooks/pre-commit"
pass "failed commit: logged as an error, nothing pushed, project stage still ran"

# --- No git identity: the failure names the fix --------------------------------
(
  export GIT_AUTHOR_NAME= GIT_COMMITTER_NAME= GIT_AUTHOR_EMAIL= GIT_COMMITTER_EMAIL= GIT_CONFIG_GLOBAL=/dev/null
  GH_ANSWER=true run_sync
)
grep -q 'OPS: ERROR' "$LOG" || fail "a backup without an identity did not log an error"
grep -q 'no git identity: run git config --global user.name' "$LOG" || fail "the identity fix is not in the log"
if grep -q -e 'backup pushed successfully' -e 'commit kept locally' "$LOG"; then fail "a backup without an identity was reported as done"; fi
[ "$(local_head)" = "$head_before" ] && [ "$(remote_head)" = "$before" ] || fail "a commit or push happened without an identity"
pass "no git identity: the backup fails loudly, names the fix, and pushes nothing"

# --- An empty or truncated gate is not a verdict --------------------------------
# (2026-10-19: `bash <gate>` exiting 0 counted as verified, and an empty file or
# one cut off after its function definitions exits 0, so the backup pushed to a
# public origin.) The truncation point is the line before the gate's main body.
GATE_COPY="$OPS/.claude-config/bin/origin-private-check"
body_line="$(grep -n '^if ! command -v git' "$CHECK" | head -1 | cut -d: -f1)"
[ -n "$body_line" ] || fail "fixture: the gate's main body was not found"
head -n "$((body_line - 1))" "$CHECK" > "$WORK/truncated-gate"
bash -n "$WORK/truncated-gate" && bash "$WORK/truncated-gate" "$OPS" 2>/dev/null \
  || fail "fixture: the truncated gate does not parse and exit 0, so the case is not exercised"
push_count() { cat "$PUSH_LOG" 2>/dev/null | wc -l | tr -d ' '; }
for kind in empty truncated; do
    before="$(remote_head)"; pushes_before="$(push_count)"
    if [ "$kind" = empty ]; then : > "$GATE_COPY"; else cp "$WORK/truncated-gate" "$GATE_COPY"; fi
    printf '%s gate note\n' "$kind" > "$OPS/$kind-gate.md"
    GH_ANSWER=false run_sync
    grep -q 'OPS: WARN push skipped, commit kept locally: .*exited 0 without its private verdict' "$LOG" \
      || fail "$kind gate: the skip is not logged"
    if grep -q 'backup pushed successfully' "$LOG"; then fail "$kind gate: reported a push"; fi
    [ "$(remote_head)" = "$before" ] && [ "$(push_count)" = "$pushes_before" ] || fail "$kind gate: pushed to a public origin"
    git -C "$OPS" cat-file -e "HEAD:$kind-gate.md" || fail "$kind gate: the day's commit was not kept locally"
done
cp "$CHECK" "$GATE_COPY"
pass "an empty or truncated gate exits 0 but is not a verdict: commit kept locally, nothing pushed"

# --- A failed pull leaves the tree exactly as it was ----------------------------
# (2026-10-19: a failed `git pull --rebase` returned with the work still in the
# stash, so uncommitted and untracked files vanished from the tree, and later
# runs saw a clean tree and never restored them.)
tree_state() {
    (cd "$OPS" && git rev-parse HEAD && git status --porcelain=v1 -uall && git diff && git diff --cached \
      && git stash list && find . -path ./.git -prune -o -path ./.claude-config/backup/sync.log -prune -o -type f -print0 \
      | LC_ALL=C sort -z | xargs -0 sha256sum)
}
dirty_tree() {
    printf 'edited %s\n' "$1" >> "$OPS/note.md"
    printf 'untracked %s\n' "$1" > "$OPS/untracked-$1.md"
    printf 'staged %s\n' "$1" > "$OPS/staged-$1.md"; git -C "$OPS" add "staged-$1.md"
    printf 'staged then edited %s\n' "$1" >> "$OPS/note2.md"; git -C "$OPS" add note2.md
    printf 'unstaged on top %s\n' "$1" >> "$OPS/note2.md"
}
dirty_tree offline
before_state="$(tree_state)"; before="$(remote_head)"
FAKE_REMOTE="$WORK/unreachable.git" GH_ANSWER=true run_sync
grep -q 'OPS: ERROR pull --rebase failed; nothing committed or pushed' "$LOG" || fail "unreachable origin: the failed pull was not logged as an error"
grep -q 'local changes restored to the working tree' "$LOG" || fail "unreachable origin: the restore was not logged"
[ "$(tree_state)" = "$before_state" ] || { diff <(printf '%s\n' "$before_state") <(tree_state) >&2; fail "unreachable origin: the tree changed"; }
[ "$(remote_head)" = "$before" ] || fail "unreachable origin: something was pushed"
grep -q 'projects stage ran (--auto)' "$LOG" || fail "unreachable origin: the project stage did not run"
pass "unreachable origin: the tree is exactly as before (edits, index, untracked), no stash left, nothing committed"

# A pull whose rebase conflicts (a held local commit and a remote commit add the
# same file) is aborted, so HEAD and the tree come back too.
git -C "$OPS" stash push -q -u -m park || fail "fixture: could not park the dirty tree"
printf 'local side\n' > "$OPS/clash.md"; git -C "$OPS" add clash.md; git -C "$OPS" commit -q -m "local clash" || fail "fixture: local commit"
git -C "$OPS" stash pop -q --index || fail "fixture: could not unpark the dirty tree"
git clone -q "$FAKE_REMOTE" "$WORK/other" || fail "fixture: second clone"
printf 'remote side\n' > "$WORK/other/clash.md"
git -C "$WORK/other" add clash.md && git -C "$WORK/other" commit -q -m "remote clash" && git -C "$WORK/other" push -q origin HEAD:main \
  || fail "fixture: could not advance the remote"
before_state="$(tree_state)"; before="$(remote_head)"
GH_ANSWER=true run_sync
grep -q 'OPS: ERROR pull --rebase failed; nothing committed or pushed' "$LOG" || fail "conflicting rebase: the failed pull was not logged"
[ ! -d "$OPS/.git/rebase-merge" ] && [ ! -d "$OPS/.git/rebase-apply" ] || fail "conflicting rebase: a rebase was left in progress"
[ "$(tree_state)" = "$before_state" ] || { diff <(printf '%s\n' "$before_state") <(tree_state) >&2; fail "conflicting rebase: the tree or HEAD changed"; }
[ "$(remote_head)" = "$before" ] || fail "conflicting rebase: something was pushed"
pass "conflicting rebase: aborted, and the tree and HEAD are exactly as before"

echo "ALL PASS"
