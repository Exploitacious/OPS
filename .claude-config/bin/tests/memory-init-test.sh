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
