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

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/hooklib.sh"

# Scanner lives alongside the hooks in .claude-config/bin; fall back to the
# deployed ~/OPS location when the hook runs from a copy.
SCAN="$HOOK_DIR/../bin/secrets-scan.sh"
[ -x "$SCAN" ] || SCAN="$HOME/OPS/.claude-config/bin/secrets-scan.sh"
[ -x "$SCAN" ] || exit 0

TMP="$(mktemp)" || exit 0
trap 'rm -f "$TMP"' EXIT

# Parse the hook JSON: file_path + content/new_string. The portable extractor
# (jq -> python) replaces the old `python3 -c`, which was dead on Windows
# (no python3 shim) and fell through `|| exit 0` = fail-open.
RAW_INPUT="$(cat)"
if ! FILE_PATH="$(printf '%s' "$RAW_INPUT" | hook_field tool_input.file_path)"; then
  # No JSON parser at all (can't happen on a provisioned box — jq is a hard
  # dependency). This guard fires on EVERY Write|Edit but only cares about the
  # narrow memory/lessons surfaces; blocking all writes to stop a
  # credential-in-memory would be grossly disproportionate. Warn + allow.
  echo "secrets-guard: no JSON parser (jq/python) available — write NOT scanned. Install jq." >&2
  exit 0
fi
[ -n "$FILE_PATH" ] || exit 0
CONTENT="$(printf '%s' "$RAW_INPUT" | hook_field tool_input.content)"
[ -n "$CONTENT" ] || CONTENT="$(printf '%s' "$RAW_INPUT" | hook_field tool_input.new_string)"
printf '%s' "$CONTENT" > "$TMP"

# Normalize Windows backslashes so the case-globs match native file_path forms
# (Windows Claude Code may emit C:\...\memory\x.md).
FILE_PATH="${FILE_PATH//\\//}"

# Guarded surfaces: any auto-memory pool + the lessons files. Unanchored */
# variants also catch drive-letter paths (C:/Users/... vs $HOME=/c/Users/...).
case "$FILE_PATH" in
  */memory/*.md \
  | */.claude-memory/*/*.md | "$HOME"/OPS/.claude-memory/*/*.md \
  | */OPS/CONTEXT/projects/*.md | "$HOME"/OPS/CONTEXT/projects/*.md) ;;
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
    "$HOME"/OPS/CONTEXT/projects/* | */OPS/CONTEXT/projects/*) exit 0 ;;  # already routed right
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
  # Queue the entry for the closeout flush (charter § Eviction) — the closeout
  # consumes this file mechanically instead of relying on session recall.
  QUEUE_DIR="$HOME/.claude-compact-cycle"
  mkdir -p "$QUEUE_DIR" 2>/dev/null || true
  printf '%s\t%s\tproject:%s\n' "$(date -Is)" "$FILE_PATH" "$MATCH" >> "$QUEUE_DIR/memory-flush-queue" 2>/dev/null || true
  {
    echo "memory-routing nudge: the entry just written ($(basename "$FILE_PATH")) is type:project and"
    echo "mentions '$MATCH' — per foreman-charter § 'Where knowledge goes', durable single-project"
    echo "lessons belong in CONTEXT/projects/${MATCH}-lessons.md (synced, loaded when working that"
    echo "project). Keep it in auto-memory only if it is genuinely cross-project or in-flight session"
    echo "state; otherwise fold it into the lessons file and DELETE the memory entry (no stub —"
    echo "charter § Eviction). Queued for the closeout flush either way."
  } >&2
  exit 2
fi

exit 0
