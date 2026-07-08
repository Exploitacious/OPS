#!/usr/bin/env bash
# secrets-guard.sh — write-time guard for memory + lessons surfaces.
#
# Registered twice in the shared settings.json:
#   PreToolUse  (Write|Edit) → `secrets-guard.sh pre`  — BLOCKS (exit 2) a
#     Write/Edit that would put a literal credential into an auto-memory pool
#     or a CONTEXT/projects lessons file. Policy: secrets live only in SOPS
#     vaults or .env files; these surfaces store pointers.
#   PostToolUse (Write|Edit) → `secrets-guard.sh post` — routing NUDGE
#     (exit 2 = feedback to the agent, the write itself stands): a memory
#     entry that is clearly single-project material belongs in
#     CONTEXT/projects/<project>-lessons.md per foreman-charter § "Where
#     knowledge goes", not in the cross-project pool.
#
# Escape hatch: SECRETS_GUARD=off disables both modes (operator emergencies).
# Scope is deliberately narrow — normal code/docs writes are untouched; only
# memory pools + lessons files are gated, so false positives are cheap and
# the fix is always "write the pointer instead".
set -uo pipefail

MODE="${1:-pre}"
[ "${SECRETS_GUARD:-on}" = "off" ] && exit 0

SCAN="$HOME/OPS/.claude-config/bin/secrets-scan.sh"
[ -x "$SCAN" ] || exit 0

TMP="$(mktemp)" || exit 0
trap 'rm -f "$TMP"' EXIT

# Parse the hook JSON: file_path to stdout, content/new_string into $TMP.
FILE_PATH="$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
path = ti.get("file_path") or ""
content = ti.get("content") or ti.get("new_string") or ""
with open(sys.argv[1], "w") as f:
    f.write(content)
sys.stdout.write(path)
' "$TMP" 2>/dev/null)" || exit 0
[ -n "$FILE_PATH" ] || exit 0

# Guarded surfaces: any auto-memory pool + the lessons files.
case "$FILE_PATH" in
  */memory/*.md | "$HOME"/OPS/.claude-memory/*/*.md | "$HOME"/OPS/CONTEXT/projects/*.md) ;;
  *) exit 0 ;;
esac

if [ "$MODE" = "pre" ]; then
  HITS="$("$SCAN" --stdin "$(basename "$FILE_PATH")" < "$TMP")" && exit 0
  {
    echo "secrets-guard: BLOCKED write to $FILE_PATH — content matches literal-credential pattern(s):"
    echo "$HITS"
    echo "Policy (operator, 2026-07-06): secrets live ONLY in SOPS vaults or .env files."
    echo "Memory/lessons entries store POINTERS — rewrite the entry to reference where the"
    echo "secret lives (vault path, 1Password entry, .env var name), not its value."
  } >&2
  exit 2
fi

if [ "$MODE" = "post" ]; then
  # Routing nudge — only for substantive project-typed memory entries landing
  # in a cross-project pool; stubs/pointers, indexes, and lessons files stay quiet.
  case "$FILE_PATH" in
    "$HOME"/OPS/CONTEXT/projects/*) exit 0 ;;   # already routed right
    */memory/MEMORY.md) exit 0 ;;                  # index, not an entry
  esac
  SIZE="$(wc -c < "$TMP")"
  [ "$SIZE" -ge 400 ] || exit 0
  grep -qiE '(folded to|canonical entry lives|pointer stub)' "$TMP" && exit 0
  grep -qE '^\s*type:\s*project\s*$' "$TMP" || exit 0

  LESSONS_DIR="$HOME/OPS/CONTEXT/projects"
  [ -d "$LESSONS_DIR" ] || exit 0
  MATCH=""
  for lf in "$LESSONS_DIR"/*-lessons.md; do
    [ -e "$lf" ] || continue
    key="$(basename "$lf" | sed 's/-lessons\.md$//')"
    if grep -qiE -- "(^|[^a-z])${key}([^a-z]|$)" "$TMP" \
       || printf '%s' "$(basename "$FILE_PATH")" | grep -qiE -- "$key"; then
      MATCH="$key"
      break
    fi
  done
  [ -n "$MATCH" ] || exit 0
  {
    echo "memory-routing nudge: the entry just written ($(basename "$FILE_PATH")) is type:project and"
    echo "mentions '$MATCH' — per foreman-charter § 'Where knowledge goes', durable single-project"
    echo "lessons belong in CONTEXT/projects/${MATCH}-lessons.md (synced, loaded when working that"
    echo "project). Keep it in auto-memory only if it is genuinely cross-project or in-flight session"
    echo "state; otherwise fold it into the lessons file and reduce the memory entry to a pointer."
  } >&2
  exit 2
fi

exit 0
