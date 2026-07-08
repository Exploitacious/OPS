#!/usr/bin/env bash
# secrets-scan.sh — literal-credential detector for memory/lessons surfaces.
#
# Usage:
#   secrets-scan.sh FILE|DIR [...]    scan files/dirs (md files), print hits
#   secrets-scan.sh --stdin [LABEL]   scan stdin text (used by secrets-guard hook)
#
# Exit: 0 = clean · 1 = hits found (one line per hit: <path>:<line>: <pattern>)
#
# Policy (operator directive 2026-07-06): secrets live ONLY in SOPS vaults or
# .env files. Memory entries and lessons files store POINTERS ("see vault at
# <path>", "1Password entry X"), never literal values. This scanner backs
# secrets-guard.sh (write-time), verify-ops.sh (repo gate), and any
# pre-push scan. Two pattern tiers:
#   HARD — unambiguous credential shapes; always flagged.
#   SOFT — assignment-style (password:, api_key=); skipped when the line
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

scan_stream() { # $1 = label for output
  local label="$1" rc=0 lineno=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    for entry in "${HARD_PATTERNS[@]}"; do
      local name="${entry%%|*}" re="${entry#*|}"
      if printf '%s' "$line" | grep -qE -- "$re"; then
        echo "${label}:${lineno}: ${name}"
        rc=1
      fi
    done
    if ! printf '%s' "$line" | grep -qiE "$POINTER_RE"; then
      for entry in "${SOFT_PATTERNS[@]}"; do
        local name="${entry%%|*}" re="${entry#*|}"
        if printf '%s' "$line" | grep -qiE -- "$re"; then
          echo "${label}:${lineno}: ${name}"
          rc=1
        fi
      done
    fi
  done
  return $rc
}

if [ "${1:-}" = "--stdin" ]; then
  scan_stream "${2:-stdin}"
  exit $?
fi

[ $# -ge 1 ] || { echo "usage: secrets-scan.sh FILE|DIR [...] | --stdin [label]" >&2; exit 64; }

RC=0
for target in "$@"; do
  if [ -d "$target" ]; then
    while IFS= read -r f; do
      scan_stream "$f" < "$f" || RC=1
    done < <(find "$target" -type f -name '*.md' ! -path '*/.git/*')
  elif [ -f "$target" ]; then
    scan_stream "$target" < "$target" || RC=1
  fi
done
exit $RC
