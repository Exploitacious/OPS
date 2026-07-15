#!/usr/bin/env bash
# guard-selftest.sh — prove the security guards actually BLOCK (fail-closed),
# not silently allow (fail-open). Run it after deploying the hooks and any
# time by hand. On Windows this is the canary that the jq-based extractor is
# live and python3's absence no longer disables the hard gates.
#
# Exit 0 = every guard enforces as expected; 1 = a guard is dead/misbehaving.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0

probe() {  # label  expected_rc  hook  [hook-args...]   (JSON on stdin)
  local label="$1" want="$2" hook="$3"; shift 3
  local json; json="$(cat)"
  printf '%s' "$json" | "$DIR/$hook" "$@" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "$want" ]; then
    printf '  PASS  %s (exit %s)\n' "$label" "$rc"
  else
    printf '  FAIL  %s (exit %s, want %s)\n' "$label" "$rc" "$want"
    fails=$((fails + 1))
  fi
}

echo "guard-selftest:"
probe "git-guard blocks force-push"          2 git-guard.sh <<'J'
{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}
J
probe "git-guard blocks protected-root rm"   2 git-guard.sh <<'J'
{"tool_name":"Bash","tool_input":{"command":"rm -rf $HOME/OPS"}}
J
probe "git-guard allows normal git"          0 git-guard.sh <<'J'
{"tool_name":"Bash","tool_input":{"command":"git status"}}
J
probe "secrets-guard blocks secret->memory"  2 secrets-guard.sh pre <<'J'
{"tool_input":{"file_path":"/x/memory/note.md","content":"-----BEGIN OPENSSH PRIVATE KEY-----"}}
J

if [ "$fails" -eq 0 ]; then
  echo "guard-selftest: ALL GUARDS ENFORCE"
  exit 0
else
  echo "guard-selftest: $fails guard(s) NOT enforcing — is jq installed? are the hooks executable (100755)?"
  exit 1
fi
