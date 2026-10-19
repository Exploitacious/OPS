#!/usr/bin/env bash
# Prove the live startup briefing does not claim a missing or unrelated core
# loaded. HOME and both profiles are disposable; no live config is read.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/briefing-core.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" OPS_DIR="$WORK/OPS"
unset CLAUDE_CONFIG_DIR
mkdir -p "$OPS_DIR/CONTEXT" "$HOME/.claude/rules"
printf '# Core\n' > "$OPS_DIR/CONTEXT/core.md"
RULE="$HOME/.claude/rules/ops-core.md"
briefing() { bash "$ROOT/.claude-config/hooks/session-briefing.sh" </dev/null; }
expect() {
  local want="$1" out
  out="$(briefing)"
  if ! grep -qF "Boot:    $want" <<< "$out"; then
    printf 'FAIL: expected boot status %s\n%s\n' "$want" "$out" >&2
    exit 1
  fi
}
expect 'core.md NOT linked'
ln -s "$OPS_DIR/CONTEXT/core.md" "$RULE"
expect 'core.md loaded via rules/ops-core.md'
rm "$RULE"
printf '# Example mentions CONTEXT/core.md\n' > "$RULE"
expect 'core.md NOT linked'
printf '@%s\n' "$HOME/missing/CONTEXT/core.md" > "$RULE"
expect 'core.md NOT linked'
mkdir -p "$WORK/other/CONTEXT"
printf '# Other\n' > "$WORK/other/CONTEXT/core.md"
printf '@%s\n' "$WORK/other/CONTEXT/core.md" > "$RULE"
expect 'core.md NOT linked'
printf '@%s\n' "$OPS_DIR/CONTEXT/core.md" > "$RULE"
expect 'core.md loaded via rules/ops-core.md (import)'
printf '```\n@%s\n```\n' "$OPS_DIR/CONTEXT/core.md" > "$RULE"
expect 'core.md NOT linked'
mv "$OPS_DIR" "$WORK/OPS with spaces"
export OPS_DIR="$WORK/OPS with spaces"
printf '@%s\n' "$OPS_DIR/CONTEXT/core.md" > "$RULE"
expect 'core.md NOT linked'
printf '@%s\n' "${OPS_DIR// /\\ }/CONTEXT/core.md" > "$RULE"
expect 'core.md loaded via rules/ops-core.md (import)'
export CLAUDE_CONFIG_DIR="$HOME/other-profile"
expect 'core.md NOT linked'
mkdir -p "$CLAUDE_CONFIG_DIR/rules"
ln -s "$OPS_DIR/CONTEXT/core.md" "$CLAUDE_CONFIG_DIR/rules/ops-core.md"
expect 'core.md loaded via rules/ops-core.md'
# Both realpath calls used to fail to the empty string and compare equal.
rm "$OPS_DIR/CONTEXT/core.md"
expect 'core.md NOT linked'
echo 'PASS: startup briefing validates core links and imports in each profile'
