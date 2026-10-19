#!/usr/bin/env bash
# Exercise deploy's real mount function without network, git writes, or a live
# install. The git stub deliberately leaves partial clones and races publication.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
DEPLOY="$(cd "$(dirname "$0")/../.." && pwd)/deploy.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy-mount.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
OPS_ROOT="$WORK/OPS"
SKILLS_SOURCE_DIR="$OPS_ROOT/PROJECTS/Exploitacious/agent-skills"
export SKILLS_SOURCE_URL='https://invalid.example/agent-skills.git'
SKILLS_VENDOR="$WORK/vendor.sh"
LOG="$WORK/log"
export LOG
export CHECK_RC=0
mkdir -p "$OPS_ROOT/SKILLS"
printf 'sample\tExploitacious/agent-skills/skills/sample\n' > "$OPS_ROOT/SKILLS/VENDORED.tsv"
cat > "$SKILLS_VENDOR" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$OPS_DIR" >> "$LOG"
if [[ "$1" == --check ]]; then exit "$CHECK_RC"; fi
STUB
msg_ok() { :; }
msg_warn() { :; }
msg_bad() { :; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eval "$(awk '/^mount_skills\(\) \{/ {p=1} p {print} p && /^}/ {exit}' "$DEPLOY")"
# BSD/macOS mv has no -T. Every case below runs with an mv that rejects it,
# so a GNU-only publish step fails here instead of on a Mac (2026-10-19).
mv() {
  local a
  for a in "$@"; do
    [[ "$a" == -- ]] && break
    [[ "$a" == -*T* ]] && { printf 'mv: illegal option -- T\n' >&2; return 1; }
  done
  command mv "$@"
}
GIT_MODE=fail
git() {
  printf '%s\n' "$*" >> "$LOG"
  if [[ "$1" == -C ]]; then
    [[ "$GIT_MODE" != incomplete ]]
    return
  fi
  [[ "$1" == clone ]] || fail "unexpected git operation: $*"
  local dest="${*: -1}"
  mkdir -p "$dest/.git"
  printf 'partial\n' > "$dest/partial"
  [[ "$GIT_MODE" != fail ]] || return 128
  rm "$dest/partial"
  printf 'complete\n' > "$dest/complete"
  if [[ "$GIT_MODE" == race ]]; then
    mkdir -p "$SKILLS_SOURCE_DIR"
    printf 'user data\n' > "$SKILLS_SOURCE_DIR/sentinel"
  fi
}
if mount_skills; then fail 'failed clone reported success'; fi
[[ ! -e "$SKILLS_SOURCE_DIR" ]] || fail 'failed clone poisoned the canonical source path'
[[ -z "$(find "$WORK" -name 'agent-skills.clone.*' -print -quit)" ]] || fail 'failed clone leaked a temporary tree'
GIT_MODE=ok
mount_skills || fail 'retry after a failed clone failed'
[[ -f "$SKILLS_SOURCE_DIR/complete" ]] || fail 'completed clone not published'
[[ "$(grep -c '^sync ' "$LOG")" == 1 ]] || fail 'mount did not run sync exactly once'
: > "$LOG"
mount_skills || fail 'redeploy of an existing clone failed'
! grep -q '^clone\|pull' "$LOG" || fail 'redeploy cloned or pulled the existing source'
CHECK_RC=2
if mount_skills; then fail 'sync skipped a missing mount but deploy reported success'; fi
CHECK_RC=0
GIT_MODE=incomplete
if mount_skills; then fail 'an incomplete existing clone reported success'; fi
[[ -f "$SKILLS_SOURCE_DIR/complete" ]] || fail 'incomplete-clone check changed the existing source'
rm -rf "$SKILLS_SOURCE_DIR"
GIT_MODE=race
if mount_skills; then fail 'concurrent destination creation reported success'; fi
[[ "$(cat "$SKILLS_SOURCE_DIR/sentinel")" == 'user data' ]] || fail 'publication overwrote a concurrent destination'
[[ ! -e "$SKILLS_SOURCE_DIR/complete" ]] || fail 'publication copied into a concurrent destination'
[[ -z "$(find "$WORK" -name 'agent-skills.clone.*' -print -quit)" ]] || fail 'publication conflict leaked a temporary tree'
printf 'PASS: clone failure, retry, redeploy, incomplete clone and publication collision (BSD-style mv)\n'
