#!/usr/bin/env bash
# Existing profiles can point at a prior pool while the new pool already holds
# same-named notes. Migration must preserve both versions and fail visibly.
set -euo pipefail
INIT="$(cd "$(dirname "$0")/.." && pwd)/memory-init"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/memory-init-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" OPS_DIR="$WORK/OPS" CLAUDE_CONFIG_DIR="$WORK/config"
ENCODED="${HOME//\//-}"
OLD="$WORK/old-pool"
TARGET="$OPS_DIR/.claude-memory/fixture$ENCODED"
SOURCE="$CLAUDE_CONFIG_DIR/projects/$ENCODED/memory"
mkdir -p "$OLD" "$TARGET" "${SOURCE%/*}"
printf 'old private note\n' > "$OLD/note.md"
printf 'existing destination note\n' > "$TARGET/note.md"
ln -s "$OLD" "$SOURCE"
if bash "$INIT" --hostname fixture --only-home > "$WORK/log" 2>&1; then
  printf 'FAIL: conflicting pools reported successful initialization\n' >&2; exit 1
fi
[[ "$(readlink "$SOURCE")" == "$OLD" ]] || { echo 'FAIL: repointed away from unresolved notes' >&2; exit 1; }
[[ "$(cat "$OLD/note.md")" == 'old private note' ]] || { echo 'FAIL: old pool changed' >&2; exit 1; }
[[ "$(cat "$TARGET/note.md")" == 'existing destination note' ]] || { echo 'FAIL: target pool changed' >&2; exit 1; }
rm "$TARGET/note.md"
bash "$INIT" --hostname fixture --only-home > "$WORK/log" 2>&1
[[ "$(readlink "$SOURCE")" == "$TARGET" && ! -e "$OLD" ]] || { echo 'FAIL: resolved migration did not complete' >&2; exit 1; }
[[ "$(cat "$TARGET/note.md")" == 'old private note' ]] || { echo 'FAIL: migration lost note' >&2; exit 1; }
bash "$INIT" --hostname fixture --only-home > "$WORK/log" 2>&1
echo 'PASS: conflicting pools remain intact, resolved migration and rerun succeed'

# Auto-commit pushes memory only to an origin the push gate verifies private.
# origin is a GitHub URL, so the gate asks the stubbed gh; a fake ssh serves
# that URL from a local bare repo, so a push that does happen lands there.
GATE="$WORK/gate"
mkdir -p "$GATE/bin" "$GATE/home"
export GH_ANSWER=false PUSH_LOG="$GATE/push.log" FAKE_REMOTE="$GATE/remote.git"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$GH_ANSWER"\n' > "$GATE/bin/gh"
cat > "$GATE/fake-ssh" <<'STUB'
#!/usr/bin/env bash
case "${*: -1}" in
  git-upload-pack*) exec git upload-pack "$FAKE_REMOTE" ;;
  git-receive-pack*) echo receive-pack >> "$PUSH_LOG"; exec git receive-pack "$FAKE_REMOTE" ;;
esac
exit 1
STUB
chmod +x "$GATE/bin/gh" "$GATE/fake-ssh"
export PATH="$GATE/bin:$PATH" GIT_SSH_COMMAND="$GATE/fake-ssh" GIT_SSH_VARIANT=ssh GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export HOME="$GATE/home" OPS_DIR="$GATE/OPS" CLAUDE_CONFIG_DIR="$GATE/config"
git init -q -b main "$GATE/seed" && git -C "$GATE/seed" commit -q --allow-empty -m seed
git clone -q --bare "$GATE/seed" "$FAKE_REMOTE"
git clone -q git@github.com:acme/ops-copy.git "$OPS_DIR"
SEED="$(git -C "$FAKE_REMOTE" rev-parse main)"
GENC="${HOME//\//-}"
POOL="$OPS_DIR/.claude-memory/fixture$GENC"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$GENC/memory"
printf 'first note\n' > "$CLAUDE_CONFIG_DIR/projects/$GENC/memory/note.md"
bash "$INIT" --hostname fixture --only-home --auto-commit > "$GATE/log" 2>&1 || { cat "$GATE/log" >&2; echo 'FAIL: memory-init failed with a public origin' >&2; exit 1; }
grep -q 'push skipped, commit kept locally: origin-private-check: public: github.com/acme/ops-copy is public' "$GATE/log" \
  || { cat "$GATE/log" >&2; echo 'FAIL: public origin skip not logged with its reason' >&2; exit 1; }
[[ "$(git -C "$OPS_DIR" log -1 --format=%s)" == "feat(memory): seed .claude-memory/fixture$GENC" ]] || { echo 'FAIL: memory commit not kept locally' >&2; exit 1; }
[[ -f "$POOL/note.md" ]] || { echo 'FAIL: note not migrated into the pool' >&2; exit 1; }
[[ "$(git -C "$FAKE_REMOTE" rev-parse main)" == "$SEED" && ! -e "$PUSH_LOG" ]] || { echo 'FAIL: memory pushed to a public origin' >&2; exit 1; }
echo 'PASS: auto-commit keeps the commit and does not push to a public origin'

GH_ANSWER=true
printf 'second note\n' > "$POOL/two.md"
bash "$INIT" --hostname fixture --only-home --auto-commit > "$GATE/log" 2>&1 || { cat "$GATE/log" >&2; echo 'FAIL: memory-init failed with a private origin' >&2; exit 1; }
grep -q 'auto-commit: pushed' "$GATE/log" || { cat "$GATE/log" >&2; echo 'FAIL: private origin push not logged' >&2; exit 1; }
[[ "$(git -C "$FAKE_REMOTE" rev-parse main)" == "$(git -C "$OPS_DIR" rev-parse HEAD)" ]] || { echo 'FAIL: memory not pushed to a private origin' >&2; exit 1; }
echo 'PASS: auto-commit pushes held and new commits to a private origin'

# Auto-commit commits the pool path only; other staged work stays staged.
printf 'unrelated\n' > "$OPS_DIR/unrelated.txt"; git -C "$OPS_DIR" add unrelated.txt
printf 'third note\n' > "$POOL/three.md"
bash "$INIT" --hostname fixture --only-home --auto-commit > "$GATE/log" 2>&1 || { cat "$GATE/log" >&2; echo 'FAIL: memory-init failed with staged unrelated work' >&2; exit 1; }
if git -C "$OPS_DIR" show --name-only --format= HEAD | grep -qx unrelated.txt; then echo 'FAIL: auto-commit swept in unrelated staged work' >&2; exit 1; fi
git -C "$OPS_DIR" show --name-only --format= HEAD | grep -q 'three.md' || { echo 'FAIL: the pool change was not committed' >&2; exit 1; }
git -C "$OPS_DIR" diff --cached --name-only | grep -qx unrelated.txt || { echo 'FAIL: unrelated staged work was lost' >&2; exit 1; }
echo 'PASS: auto-commit commits only the memory pool'

# An empty pool stays in git through the daily backup's stash, and a pool an
# earlier backup removed is recreated (2026-10-19: git stash -u dropped the
# empty pool directory and left the memory link dangling).
EMPTYH="$WORK/empty"
(
  export HOME="$EMPTYH/home" OPS_DIR="$EMPTYH/OPS" CLAUDE_CONFIG_DIR="$EMPTYH/config"
  mkdir -p "$HOME"
  git init -q -b main "$OPS_DIR" && git -C "$OPS_DIR" commit -q --allow-empty -m seed
  E="${HOME//\//-}"; P="$OPS_DIR/.claude-memory/fixture$E"; L="$CLAUDE_CONFIG_DIR/projects/$E/memory"
  bash "$INIT" --hostname fixture --only-home > "$EMPTYH/log" 2>&1 || { cat "$EMPTYH/log" >&2; echo 'FAIL: init of an empty pool failed' >&2; exit 1; }
  [[ -L "$L" && -f "$P/.gitkeep" ]] || { cat "$EMPTYH/log" >&2; echo 'FAIL: the empty pool has no placeholder' >&2; exit 1; }
  printf 'x\n' > "$OPS_DIR/other.txt"
  git -C "$OPS_DIR" stash push -q -u -m probe && git -C "$OPS_DIR" stash pop -q
  [[ -d "$L" ]] || { echo 'FAIL: the pool did not survive stash -u and pop' >&2; exit 1; }
  rm -rf "$P"
  [[ ! -d "$L" ]] || { echo 'FAIL: fixture did not dangle the link' >&2; exit 1; }
  bash "$INIT" --hostname fixture --only-home > "$EMPTYH/log" 2>&1 || { cat "$EMPTYH/log" >&2; echo 'FAIL: rerun on a dangling pool failed' >&2; exit 1; }
  [[ -d "$L" && -f "$P/.gitkeep" ]] || { cat "$EMPTYH/log" >&2; echo 'FAIL: the dangling pool was not healed' >&2; exit 1; }
) || exit 1
echo 'PASS: an empty pool survives the backup stash, and a removed pool is recreated'

# The deploy caller must retain the initializer's failure in its final status.
DEPLOY="$(cd "$(dirname "$INIT")/.." && pwd)/deploy.sh"
CONFIG_DIR="$WORK/deploy-config"
export OPS_ROOT="$OPS_DIR"
mkdir -p "$CONFIG_DIR/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$CONFIG_DIR/bin/memory-init"
chmod +x "$CONFIG_DIR/bin/memory-init"
msg_ok() { :; }; msg_warn() { :; }; msg_bad() { :; }
DEPLOY_FAILED=''
eval "$(awk '/^MEMORY_INIT=/ {p=1} p && /^# --- Daily backup/ {exit} p {print}' "$DEPLOY")"
[[ "$DEPLOY_FAILED" == *memory-init* ]] || { echo 'FAIL: deploy swallowed memory initialization failure' >&2; exit 1; }
echo 'PASS: deploy records memory initialization failure'

# A failed crontab install fails the deploy (2026-10-19: it printed
# "Deploy complete." and exited 0 with no backup scheduled).
CRONW="$WORK/cron"; mkdir -p "$CRONW/bin" "$CONFIG_DIR/backup"
printf '#!/usr/bin/env bash\nexit 1\n' > "$CRONW/bin/crontab"; chmod +x "$CRONW/bin/crontab"
printf '#!/usr/bin/env bash\n' > "$CONFIG_DIR/backup/daily-sync.sh"
c_yel() { :; }
DEPLOY_FAILED=''; NO_SYSTEM=0
PATH="$CRONW/bin:$PATH" eval "$(awk '/^# --- Daily backup cron job ---/ {p=1} p && /^# --- Claude Code plugins/ {exit} p {print}' "$DEPLOY")"
[[ "$DEPLOY_FAILED" == *cron* ]] || { echo 'FAIL: a failed cron install did not fail the deploy' >&2; exit 1; }
echo 'PASS: deploy records a failed cron install'
