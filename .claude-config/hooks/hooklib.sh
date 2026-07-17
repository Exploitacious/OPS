#!/usr/bin/env bash
# hooklib.sh — shared helpers for OPS hooks. SOURCED, never executed.
#
# The hooks originally parsed their PreToolUse / compaction JSON payloads with
# an inline `python3 -c ...` heredoc. Windows (Git Bash) has NO `python3` shim
# — winget ships python.exe / py.exe only — so every such call resolved to 127
# and the surrounding `|| exit 0` silently DISABLED the hook: git-guard's hard
# gates, secrets-guard, and the compaction resume banner all became no-ops
# (Windows-parity gap #4 / #17).
#
# hook_field replaces that with a portable extractor: jq first (a hard harness
# dependency, present on Windows AND Linux), then python3 / python / py. If NO
# parser is available it returns 2 so SECURITY callers can fail CLOSED instead
# of fail-open. It never depends on `python3` specifically.
#
# Usage:
#   RAW="$(cat)"
#   v="$(printf '%s' "$RAW" | hook_field tool_input.command)" || { no-parser }
# On success prints the (possibly empty) value and returns 0.
# Returns 2 when no JSON parser exists at all.

hook_field() {
  local path="$1" input out
  input="$(cat)"

  if command -v jq >/dev/null 2>&1; then
    if out="$(printf '%s' "$input" | jq -r --arg p "$path" '
        ($p | split(".")) as $parts
        | reduce $parts[] as $k (.; if type == "object" then .[$k] else null end)
        | if . == null then "" else (. | tostring) end' 2>/dev/null)"; then
      printf '%s' "$out"
      return 0
    fi
  fi

  local py
  for py in python3 python py; do
    if command -v "$py" >/dev/null 2>&1; then
      if out="$(printf '%s' "$input" | "$py" -c '
import json, sys
path = sys.argv[1].split(".")
try:
    d = json.load(sys.stdin)
except Exception:
    sys.stdout.write(""); sys.exit(0)
cur = d
for k in path:
    cur = cur.get(k) if isinstance(cur, dict) else None
    if cur is None:
        break
sys.stdout.write("" if cur is None else str(cur))' "$path" 2>/dev/null)"; then
        printf '%s' "$out"
        return 0
      fi
    fi
  done

  return 2
}

# Resolve a Python interpreter: python3 (Linux/macOS) then python / py (Windows
# has NO python3 shim). Prints the command name; returns 2 if none found. Used
# to run python-shebang'd helpers (e.g. ac-memory-index) portably instead of
# relying on the dead `#!/usr/bin/env python3` line on Windows (gap #10).
hook_python() {
  # VERIFY each candidate actually reports "Python 3" before returning it: on
  # Windows `python3` is frequently a broken App-Execution-Alias stub that
  # resolves on PATH but errors (or opens the Store) when run. The version
  # probe falls through such a stub to the real `python` / `py`.
  local p v
  for p in python3 python py; do
    if command -v "$p" >/dev/null 2>&1; then
      v="$("$p" --version 2>&1)" || continue
      case "$v" in Python\ 3.*) printf '%s' "$p"; return 0 ;; esac
    fi
  done
  return 2
}

# Normalize a possibly-Windows path (drive letter, back/forward slashes) to a
# POSIX path bash can stat. Uses cygpath when present (Git Bash); otherwise
# prints the input unchanged (already POSIX on Linux/macOS).
hook_pathnorm() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}

# work_session_key — the stable per-session key for session-scoped state files
# under ~/.claude-compact-cycle/ (session-start stamp, work-log, resume baton).
# MUST match the resume-baton key formula in the pre-compact-synthesis skill so
# all surfaces agree on one name for a session:
#     tmux name | tr ':. ' '---' | keep [A-Za-z0-9-]
# In tmux: the live (post-boot-normalization) session name — stable for the life
# of the session, which is why session-work-init.sh registers LAST at boot.
# Outside tmux: fall back to the encoded cwd (the workspace-key convention) so a
# non-tmux session still keys deterministically. Prints the key; never fails.
work_session_key() {
  local raw
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    raw="$(tmux display-message -p '#S' 2>/dev/null || true)"
    if [ -n "$raw" ]; then
      printf '%s' "$raw" | tr ':. ' '---' | tr -cd 'A-Za-z0-9-'
      return 0
    fi
  fi
  printf '%s' "$(pwd)" | sed 's|/|-|g' | tr -cd 'A-Za-z0-9-'
}
