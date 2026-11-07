#!/usr/bin/env bash
# secrets-scan.sh: literal-credential detector for memory/lessons surfaces.
#
# Usage:
#   secrets-scan.sh FILE|DIR [...]    scan files/dirs (md files), print hits
#   secrets-scan.sh --stdin [LABEL]   scan stdin text (used by secrets-guard hook)
#
# Exit: 0 = clean · 1 = hits found (one line per hit: <path>:<line>: <pattern>)
#       2 = input could not be read or scanned; callers fail closed
#
# Policy (operator directive 2026-07-06): secrets live ONLY in SOPS vaults or
# .env files. Memory entries and lessons files store POINTERS ("see vault at
# <path>", "1Password entry X"), never literal values. This scanner backs
# secrets-guard.sh (write-time), verify-ops.sh (repo gate), and any
# pre-push scan. Two pattern tiers:
#   HARD: unambiguous credential shapes; always flagged.
#   SOFT: assignment-style (password:, api_key=); skipped when the line
#          already reads as a pointer (sops/vault/1password/.env/redacted),
#          because pointers are exactly what we WANT written.
set -uo pipefail

HARD_PATTERNS=(
  'github-token|ghp_[A-Za-z0-9]{20,}'
  'github-pat|github_pat_[A-Za-z0-9_]{20,}'
  'openai-anthropic-key|(^|[^A-Za-z0-9/_-])sk-[A-Za-z0-9_-]{20,}'
  'anthropic-key|sk-ant-[A-Za-z0-9_-]{20,}'
  'slack-token|xox[baprs]-[A-Za-z0-9-]{10,}'
  'aws-access-key|AKIA[0-9A-Z]{16}'
  'google-api-key|AIza[0-9A-Za-z_-]{30,}'
  'gitlab-pat|glpat-[A-Za-z0-9_-]{20,}'
  'private-key-block|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'jwt|eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{10,}'
  'age-secret-key|AGE-SECRET-KEY-1[A-Z0-9]{20,}'
  # Flag-form credentials (CLI flags carrying a literal password inline).
  # Values starting with < or $ are placeholders/vars, deliberately unmatched.
  'sshpass-flag-password|sshpass[[:space:]]+-p[[:space:]]*["'"'"'`]?[^<$"'"'"'`[:space:]][^[:space:]]{5,}'
  'mysql-inline-password|mysql[a-z]*\b.*[[:space:]]-p[^<$[:space:]-][^[:space:]]{4,}'
  'curl-user-password|(curl|wget)\b.*[[:space:]](-u|--user)[[:space:]=]+[^[:space:]:<$]+:[^[:space:]<$]{3,}'
  'env-var-password|(SSHPASS|PGPASSWORD|MYSQL_PWD)=["'"'"'`]?[^<$"'"'"'`[:space:]][^[:space:]]{5,}'
)

SOFT_PATTERNS=(
  'password-assignment|(password|passwd)["'"'"']?\s*[:=]\s*["'"'"'`]?[^[:space:]"'"'"'`]{8,}'
  'secret-assignment|(api[_-]?key|api[_-]?token|access[_-]?token|client[_-]?secret|auth[_-]?token)["'"'"']?\s*[:=]\s*["'"'"'`]?[A-Za-z0-9_/+.=-]{16,}'
)

# Lines that are pointers or docs-about-secrets, not secrets.
POINTER_RE='(sops|vault|1password|1Password|\.env|redacted|REDACTED|<[a-z-]+>|placeholder|example|pointer|see )'

# grep exits 0 on a match, 1 on no match, and 2 or more on an error (a pattern
# this grep cannot compile, an engine limit, a broken pipe). An error is not "no
# match": the line was not scanned. The old `if grep -q` read every grep error as
# a clean line, so a scanner that could not run passed everything; now a line
# grep could not read makes the result exit 2, and secrets-guard blocks the write.
# A found credential (exit 1) still wins, because it is the more useful answer.
scan_stream() { # $1 = label for output
  local label="$1" rc=0 err=0 lineno=0 line entry name re st
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    for entry in "${HARD_PATTERNS[@]}"; do
      name="${entry%%|*}"; re="${entry#*|}"
      printf '%s' "$line" | grep -qE -- "$re"; st=$?
      if [ "$st" -eq 0 ]; then
        echo "${label}:${lineno}: ${name}"
        rc=1
      elif [ "$st" -ne 1 ]; then
        echo "secrets-scan: ${label}:${lineno}: grep failed on ${name} (exit ${st}); line not scanned" >&2
        err=1
      fi
    done
    # A failed pointer test must not exempt the line: scan it as a non-pointer.
    printf '%s' "$line" | grep -qiE -- "$POINTER_RE"; st=$?
    if [ "$st" -gt 1 ]; then
      echo "secrets-scan: ${label}:${lineno}: grep failed on the pointer check (exit ${st}); scanning as a non-pointer" >&2
      err=1
    fi
    if [ "$st" -ne 0 ]; then
      for entry in "${SOFT_PATTERNS[@]}"; do
        name="${entry%%|*}"; re="${entry#*|}"
        printf '%s' "$line" | grep -qiE -- "$re"; st=$?
        if [ "$st" -eq 0 ]; then
          echo "${label}:${lineno}: ${name}"
          rc=1
        elif [ "$st" -ne 1 ]; then
          echo "secrets-scan: ${label}:${lineno}: grep failed on ${name} (exit ${st}); line not scanned" >&2
          err=1
        fi
      done
    fi
  done
  [ "$rc" -eq 1 ] && return 1
  [ "$err" -eq 1 ] && return 2
  return 0
}

if [ "${1:-}" = "--stdin" ]; then
  scan_stream "${2:-stdin}"
  exit $?
fi

[ $# -ge 1 ] || { echo "usage: secrets-scan.sh FILE|DIR [...] | --stdin [label]" >&2; exit 64; }

RC=0
note_rc() {  # keep 1 (hits) over 2 (a scan error) over 0
  [ "$1" -eq 1 ] && RC=1
  [ "$1" -eq 2 ] && [ "$RC" -eq 0 ] && RC=2
  return 0
}
scan_file() {
  local f="$1" st
  if [ ! -f "$f" ] || ! { exec 3< "$f"; } 2>/dev/null; then
    echo "secrets-scan: cannot read $f; file not scanned" >&2
    return 2
  fi
  scan_stream "$f" <&3; st=$?
  exec 3<&-
  return "$st"
}
for target in "$@"; do
  if [ -d "$target" ]; then
    # Find cannot report its status through process substitution. An empty
    # NUL-framed path (never a real find result) terminates the list and carries
    # that status, so a failed or partial walk cannot look like a clean tree.
    walk_rc=""
    while IFS= read -r -d '' f; do
      if [ -z "$f" ]; then IFS= read -r -d '' walk_rc || walk_rc=""; break; fi
      scan_file "$f"; note_rc $?
    done < <(find "$target" -type f -name '*.md' ! -path '*/.git/*' -print0; printf '\0%s\0' "$?")
    if [ "$walk_rc" != 0 ]; then
      echo "secrets-scan: $target: directory walk failed (exit ${walk_rc:-unknown}); tree not fully scanned" >&2
      note_rc 2
    fi
  else
    scan_file "$target"; note_rc $?
  fi
done
exit $RC
