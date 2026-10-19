# sandbox-guard.sh - sourced, never executed. The first statement of every test
# suite that runs a destructive tool (one that deletes or moves files: the list
# and the rule live in verify-ops.sh, check 24, check_sandbox_guards):
#
#   . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
#
# sandbox_guard exits 97 with "refusing to run outside sandbox-run: <reason>"
# unless the process is inside a sandbox built by bin/sandbox-run. The
# environment alone never satisfies it: the mount table must show
#   - the root filesystem mounted read-only,
#   - a tmpfs mounted exactly at the account's home directory (the real home
#     is hidden behind it), and $HOME on a tmpfs (the fresh home, the fresh
#     /tmp, or a dir in either: a suite may point HOME at a fixture before it
#     starts another guarded suite),
#   - the nonce file /tmp/.ops-sandbox/nonce as a read-only mount whose
#     content equals OPS_SANDBOX_NONCE,
# and OPS_SANDBOX=1. Creating those mounts takes a new mount namespace, which
# a stray export cannot fake. sandbox_guard.py is the Python twin; keep the two
# in step (tests/sandbox-run-test.sh runs both on the same cases).
#
# Why (2026-10-15, in the harness this one is ported from): a mutation sweep of
# a scratch-cleanup tool ran outside any sandbox, and with the too-broad-root
# refusal mutated away the real deleter cleaned / and $HOME. A suite that
# refuses to start outside the sandbox cannot do that again, whoever runs it
# and however.
#
# Safe under set -euo pipefail: every command that may fail is tested.

# _sandbox_guard_esc PATH: PATH escaped the way /proc/self/mountinfo writes it.
_sandbox_guard_esc() {
  local s="$1"
  s="${s//\\/\\134}"; s="${s// /\\040}"; s="${s//$'\t'/\\011}"; s="${s//$'\n'/\\012}"
  printf '%s' "$s"
}

# _sandbox_guard_top PATH: sets _SG_OPTS and _SG_FSTYPE from the mount that is
# visible at exactly PATH (the top of the stack of mounts on that mount point).
# Returns 1 when nothing is mounted there, the table cannot be read, or the
# stack has more than one top (never guess).
_sandbox_guard_top() {
  local want line id parent mp opts rest fstype n=0 top="" cand
  local -a ids=() parents=() optss=() types=()
  want="$(_sandbox_guard_esc "$1")"
  [ -r /proc/self/mountinfo ] || return 1
  while IFS= read -r line; do
    read -r id parent _ _ mp opts rest <<< "$line" || continue
    [ "$mp" = "$want" ] || continue
    # Optional fields (possibly none) run up to a lone "-"; the type follows it.
    rest=" $rest "
    case "$rest" in *" - "*) ;; *) return 1 ;; esac
    rest="${rest#* - }"; fstype="${rest%% *}"
    ids+=("$id"); parents+=("$parent"); optss+=("$opts"); types+=("$fstype")
  done < /proc/self/mountinfo
  [ "${#ids[@]}" -gt 0 ] || return 1
  for cand in "${!ids[@]}"; do
    local covered=0 j
    for j in "${!ids[@]}"; do
      [ "${parents[$j]}" = "${ids[$cand]}" ] && covered=1
    done
    if [ "$covered" = 0 ]; then n=$((n + 1)); top="$cand"; fi
  done
  [ "$n" = 1 ] || return 1
  _SG_OPTS="${optss[$top]}"; _SG_FSTYPE="${types[$top]}"
  return 0
}

# _sandbox_guard_holder PATH: prints the mount point of the mount that holds
# PATH (the longest mount point that is PATH or a parent of it), escaped.
_sandbox_guard_holder() {
  local want best="" line mp
  want="$(_sandbox_guard_esc "$1")"
  [ -r /proc/self/mountinfo ] || return 1
  while IFS= read -r line; do
    read -r _ _ _ _ mp _ <<< "$line" || continue
    case "$want/" in "${mp%/}"/*) [ "${#mp}" -gt "${#best}" ] && best="$mp" ;; esac
  done < /proc/self/mountinfo
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# sandbox_guard_check: 0 when every condition holds, else 1 with the first
# failed condition in SANDBOX_GUARD_REASON.
sandbox_guard_check() {
  local pw_home nonce content holder home_r
  SANDBOX_GUARD_REASON=""
  if ! _sandbox_guard_top /; then
    SANDBOX_GUARD_REASON="cannot read the mount at / from /proc/self/mountinfo"; return 1
  fi
  case ",$_SG_OPTS," in *,ro,*) ;; *)
    SANDBOX_GUARD_REASON="the root filesystem is mounted read-write"; return 1 ;; esac
  case "${HOME:-}" in /*) ;; *) SANDBOX_GUARD_REASON="HOME is unset or not absolute"; return 1 ;; esac
  home_r="$(realpath -m -- "$HOME" 2>/dev/null)" || home_r=""
  holder=""
  [ -z "$home_r" ] || holder="$(_sandbox_guard_holder "$home_r")" || holder=""
  # The holder is escaped; _sandbox_guard_top escapes its argument, so undo the
  # four escapes first (a mount point never holds a literal backslash-digit run).
  holder="$(printf '%b' "${holder//\\/\\0}")"
  if [ -z "$home_r" ] || [ -z "$holder" ] || ! _sandbox_guard_top "$holder" || [ "$_SG_FSTYPE" != tmpfs ]; then
    SANDBOX_GUARD_REASON="HOME ($HOME) is not on a tmpfs"; return 1
  fi
  pw_home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)" || pw_home=""
  [ -z "$pw_home" ] || pw_home="$(realpath -m -- "$pw_home" 2>/dev/null)" || pw_home=""
  if [ -z "$pw_home" ]; then
    SANDBOX_GUARD_REASON="cannot find the account's home directory"; return 1
  fi
  if ! _sandbox_guard_top "$pw_home" || [ "$_SG_FSTYPE" != tmpfs ]; then
    SANDBOX_GUARD_REASON="the account's home directory ($pw_home) is not hidden behind a tmpfs"; return 1
  fi
  if [ "${OPS_SANDBOX:-}" != 1 ]; then
    SANDBOX_GUARD_REASON="OPS_SANDBOX is not 1"; return 1
  fi
  nonce="${OPS_SANDBOX_NONCE:-}"
  if ! [[ "$nonce" =~ ^[0-9a-f]{32}$ ]]; then
    SANDBOX_GUARD_REASON="OPS_SANDBOX_NONCE is missing or malformed"; return 1
  fi
  if ! _sandbox_guard_top /tmp/.ops-sandbox/nonce; then
    SANDBOX_GUARD_REASON="the nonce file /tmp/.ops-sandbox/nonce is not a mount"; return 1
  fi
  case ",$_SG_OPTS," in *,ro,*) ;; *)
    SANDBOX_GUARD_REASON="the nonce file is not mounted read-only"; return 1 ;; esac
  content=""
  IFS= read -r content < /tmp/.ops-sandbox/nonce || true
  if [ "$content" != "$nonce" ]; then
    SANDBOX_GUARD_REASON="the nonce file does not match OPS_SANDBOX_NONCE"; return 1
  fi
  return 0
}

# sandbox_guard: return 0 inside the sandbox; otherwise print the refusal and
# exit 97 (exit, not return: a caller that forgets "|| exit" still stops).
sandbox_guard() {
  if sandbox_guard_check; then return 0; fi
  printf 'refusing to run outside sandbox-run: %s\n' "$SANDBOX_GUARD_REASON" >&2
  printf '  run it through the sandbox (bin/README.md, sandbox-run): .claude-config/bin/sandbox-run --no-net --ro-bind <checkout> -- bash %s\n' \
    "${BASH_SOURCE[1]:-<suite>}" >&2
  exit 97
}
