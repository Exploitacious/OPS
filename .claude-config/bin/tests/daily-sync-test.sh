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

echo "ALL PASS"
