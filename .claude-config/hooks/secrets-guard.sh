#!/usr/bin/env bash
# secrets-guard.sh: write-time guard for memory + lessons surfaces.
#
# Registered twice in the shared settings.json:
#   PreToolUse  (Write|Edit) → `secrets-guard.sh pre` : BLOCKS (exit 2) a
#     Write/Edit that would put a literal credential into an auto-memory pool
#     or a CONTEXT/projects lessons file. Policy: secrets live only in SOPS
#     vaults or .env files; these surfaces store pointers.
#   PostToolUse (Write|Edit) → `secrets-guard.sh post`: routing NUDGE
#     (exit 2 = feedback to the agent, the write itself stands): a memory
#     entry that is clearly single-project material belongs in
#     CONTEXT/projects/<project>-lessons.md per core.md § "Memory and where
#     knowledge goes", not in the cross-project pool.
#
# Escape hatch: SECRETS_GUARD=off disables both modes (operator emergencies).
# Scope is deliberately narrow: normal code/docs writes are untouched; only
# memory pools + lessons files are gated, so false positives are cheap and
# the fix is always "write the pointer instead".
#
# Fail closed. The pre scan used to copy the candidate content to a mktemp file
# with an unchecked `printf >`: when the temp filesystem was full it scanned an
# empty file and allowed the write, and `TMP=$(mktemp) || exit 0` failed open
# the same way. Now the pre scan pipes the content to the scanner and uses no
# temp file at all, so a full disk cannot blind it, and anything but a clean
# scan blocks: hits (exit 1) and a scanner that failed, is missing, or could not
# read the whole stream (any other status) alike, each with its own message. A
# hook payload it cannot read is not empty content either: without a
# trustworthy path the guard cannot prove the write is outside its scope, so
# pre blocks it. The guarded-path test runs before the content is extracted, so
# a write to an unguarded path costs no scan. The post nudge still reads a temp
# file (it greps the content several times); a temp file it cannot make or fill
# skips the nudge with a note and never blocks, because post exit 2 is advice
# about a write that already stands.
set -uo pipefail

MODE="${1:-pre}"
[ "${SECRETS_GUARD:-on}" = "off" ] && exit 0

# A failed read or extractor is not empty content (see the header): pre blocks,
# post only says so.
input_failure() {
  echo "secrets-guard: $1; write could not be scanned." >&2
  [ "$MODE" != pre ] || exit 2
  exit 0
}

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/hooklib.sh" || input_failure "cannot load hooklib.sh"

# Scanner lives alongside the hooks in .claude-config/bin; fall back to the
# deployed ~/OPS location when the hook runs from a copy. A missing scanner is
# checked once the path is known to be guarded (below), never as a silent pass.
SCAN="$HOOK_DIR/../bin/secrets-scan.sh"
[ -x "$SCAN" ] || SCAN="$HOME/OPS/.claude-config/bin/secrets-scan.sh"

# Parse the hook JSON: file_path + content/new_string. The portable extractor
# (jq -> python) replaces the old `python3 -c`, which was dead on Windows
# (no python3 shim) and fell through `|| exit 0` = fail-open.
RAW_INPUT="$(cat)" || input_failure "hook input could not be read"
if ! FILE_PATH="$(printf '%s' "$RAW_INPUT" | hook_field tool_input.file_path)"; then
  # No JSON parser at all (jq is a hard dependency, so this is a broken box).
  # The path is unknown, so the write may be a guarded one: pre blocks it, the
  # same way git-guard blocks every command it cannot read.
  input_failure "file_path could not be extracted (no JSON parser: install jq)"
fi
[ -n "$FILE_PATH" ] || input_failure "hook input has no file_path (invalid or incomplete payload)"

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

# A guarded path: now the content (Write: content, Edit: new_string).
CONTENT="$(printf '%s' "$RAW_INPUT" | hook_field tool_input.content)" \
  || input_failure "guarded content could not be extracted"
if [ -z "$CONTENT" ]; then
  CONTENT="$(printf '%s' "$RAW_INPUT" | hook_field tool_input.new_string)" \
    || input_failure "guarded new_string could not be extracted"
fi

if [ ! -x "$SCAN" ]; then
  echo "secrets-guard: cannot scan guarded content: scanner missing/not executable at $SCAN" >&2
  [ "$MODE" != pre ] || exit 2
  exit 0
fi

if [ "$MODE" = "pre" ]; then
  # No temp file: the content goes to the scanner on a pipe. PIPESTATUS is read
  # for both ends, so a printf that died part way (a scanner that stopped
  # reading early) cannot pass as a clean scan.
  HITS="$(printf '%s' "$CONTENT" | "$SCAN" --stdin "$(basename "$FILE_PATH")"; ps=("${PIPESTATUS[@]}"); [ "${ps[0]}" -eq 0 ] || exit 125; exit "${ps[1]}")"
  rc=$?
  [ "$rc" -eq 0 ] && exit 0
  if [ "$rc" -ne 1 ]; then
    {
      echo "secrets-guard: BLOCKED write to $FILE_PATH: the content could not be scanned (scanner or pipe failed, status $rc), and a write that cannot be checked is not allowed."
      [ -z "$HITS" ] || echo "$HITS"
      echo "Retry the write; if it keeps failing, check the scanner ($SCAN: grep present?) and the process limits."
      echo "Operator emergency only: SECRETS_GUARD=off disables this guard."
    } >&2
    exit 2
  fi
  {
    echo "secrets-guard: BLOCKED write to $FILE_PATH: content matches literal-credential pattern(s):"
    echo "$HITS"
    echo "Policy (operator, 2026-07-06): secrets live ONLY in SOPS vaults or .env files."
    echo "Memory/lessons entries store POINTERS: rewrite the entry to reference where the"
    echo "secret lives (vault path, 1Password entry, .env var name), not its value."
  } >&2
  exit 2
fi

if [ "$MODE" = "post" ]; then
  # Routing nudge: only for substantive project-typed memory entries landing
  # in a cross-project pool; indexes and lessons files stay quiet. Stub-phrased
  # entries are NOT suppressed: under charter § Eviction stubs shouldn't exist,
  # so a legacy stub is flush debt that belongs in the queue.
  case "$FILE_PATH" in
    "$HOME"/OPS/CONTEXT/projects/* | */OPS/CONTEXT/projects/*) exit 0 ;;  # already routed right
    */memory/MEMORY.md) exit 0 ;;                  # index, not an entry
  esac
  # The one place a temp file is still used (see the header). A failure to make
  # or fill it skips the nudge and says so; it never blocks.
  if ! TMP="$(mktemp 2>/dev/null)"; then
    echo "secrets-guard: post: cannot make a temp file under ${TMPDIR:-/tmp}; routing nudge skipped for $FILE_PATH" >&2
    exit 0
  fi
  trap 'rm -f "$TMP"' EXIT
  if ! printf '%s' "$CONTENT" > "$TMP" 2>/dev/null; then
    echo "secrets-guard: post: cannot write the temp file $TMP; routing nudge skipped for $FILE_PATH" >&2
    exit 0
  fi
  SIZE="$(wc -c < "$TMP")"
  [ "$SIZE" -ge 400 ] || exit 0
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
  # Queue the entry for the closeout flush (the closeout skills own eviction): the closeout
  # consumes this file mechanically instead of relying on session recall.
  QUEUE_DIR="$HOME/.claude-compact-cycle"
  mkdir -p "$QUEUE_DIR" 2>/dev/null || true
  printf '%s\t%s\tproject:%s\n' "$(date -Is)" "$FILE_PATH" "$MATCH" >> "$QUEUE_DIR/memory-flush-queue" 2>/dev/null || true
  {
    echo "memory-routing nudge: the entry just written ($(basename "$FILE_PATH")) is type:project and"
    echo "mentions '$MATCH': per core.md § 'Memory and where knowledge goes', durable single-project"
    echo "lessons belong in CONTEXT/projects/${MATCH}-lessons.md (synced, loaded when working that"
    echo "project). Keep it in auto-memory only if it is genuinely cross-project or in-flight session"
    echo "state; otherwise fold it into the lessons file and DELETE the memory entry (no stub -"
    echo "charter § Eviction). Queued for the closeout flush either way."
  } >&2
  exit 2
fi

exit 0
