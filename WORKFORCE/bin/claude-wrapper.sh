#!/usr/bin/env bash
# claude-wrapper.sh — shell function that wraps `claude` invocations
# for safe root/non-root sharing on a single host.
#
# Source from your shellrc:
#   source "$HOME/OPS/WORKFORCE/bin/claude-wrapper.sh"
#
# Two protections:
#
# 1. Root permission-mode auto-fix. Claude Code refuses to honor
#    `permissionMode: bypassPermissions` from settings.json when
#    running as root (hardcoded safety check). This wrapper detects
#    root invocations and prepends `--permission-mode auto` at the
#    CLI level, overriding settings.json for that session WITHOUT
#    modifying any files. Your normal user keeps bypassPermissions for
#    normal sessions; root automatically degrades to auto. No manual
#    edit-settings-and-revert dance.
#
# 2. Single-instance lock — SHARED-HOST ONLY. Two UIDs sharing the SAME
#    config dir (a non-root user + root, where `~/.claude/` and
#    `/root/.claude/` are one directory via symlink + ACLs) race on
#    .credentials.json, .claude.json, sessions/, history.jsonl —
#    causing the "occasionally something gets corrupted, auth lost"
#    behavior. The lock serializes ONLY that case. It is gated on a
#    shared-host signal — running as root (the documented root+non-root
#    hazard), or `AC_SHARED_HOST` exported on a host that shares a config
#    dir across UIDs. On a NORMAL single-user host the lock is OFF, so
#    concurrent same-profile sessions (deliberate parallel work) run
#    freely — locking them would defeat the point. Separate profiles
#    (e.g. a second one via `CLAUDE_CONFIG_DIR`) never shared state
#    anyway. Lockfile: <config-dir>/.instance.lock.
#
# Lockfile: <config-dir>/.instance.lock
# Conflict exit code: 99 (distinct from claude's own exit codes).
#
# Compatibility: bash + zsh. Other shells skip silently.

if [ -z "${BASH_VERSION:-}" ] && [ -z "${ZSH_VERSION:-}" ]; then
  return 2>/dev/null || true
fi

# Lockfile is resolved per-invocation inside claude() from
# CLAUDE_CONFIG_DIR (set by whatever launcher/alias you use for a second
# profile, if you run one), so each config dir locks independently. Do NOT
# resolve it here at source time — CLAUDE_CONFIG_DIR isn't set yet during
# shellrc init.

# Resolve the real claude binary. Try at SOURCE time first (before the
# function shadows the name). If PATH doesn't include ~/.local/bin yet
# (common during early shellrc init), fall back to lazy resolution on
# first invocation via well-known install paths.
__ac_claude_bin=$(command -v claude 2>/dev/null || true)
# Validate: must be an absolute path to an executable.
case "$__ac_claude_bin" in
  /*) [ -x "$__ac_claude_bin" ] || __ac_claude_bin="" ;;
  *)  __ac_claude_bin="" ;;
esac

claude() {
  # Lazy resolve: if source-time lookup missed (PATH incomplete during
  # shellrc init), check well-known install locations on first call.
  if [ -z "$__ac_claude_bin" ] || [ ! -x "$__ac_claude_bin" ]; then
    local candidate
    for candidate in \
      "$HOME/.local/bin/claude" \
      "/usr/local/bin/claude" \
      "/usr/bin/claude"; do
      if [ -x "$candidate" ]; then
        __ac_claude_bin="$candidate"
        break
      fi
    done
  fi

  if [ -z "$__ac_claude_bin" ] || [ ! -x "$__ac_claude_bin" ]; then
    echo "claude: binary not found in PATH or well-known locations." >&2
    echo "        Install claude, then re-source the wrapper:" >&2
    echo "        source \$HOME/OPS/WORKFORCE/bin/claude-wrapper.sh" >&2
    return 127
  fi

  # Single-instance lock is ONLY for the shared-host collision (root + a
  # non-root user sharing ONE config dir). On a normal single-user host,
  # concurrent same-profile sessions are DESIRED (parallel work), so we must
  # NOT lock there. Gate on the shared-host signal: running as root (the
  # documented root+non-root hazard), or AC_SHARED_HOST exported on a
  # shared-config-dir host.
  local __ac_use_lock=0
  if [ "$(id -u)" -eq 0 ] || [ -n "${AC_SHARED_HOST:-}" ]; then
    __ac_use_lock=1
  fi
  local __ac_claude_lockfile="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.instance.lock"
  if [ "$__ac_use_lock" -eq 1 ] && [ ! -e "$__ac_claude_lockfile" ] \
     && [ -d "$(dirname "$__ac_claude_lockfile")" ]; then
    touch "$__ac_claude_lockfile" 2>/dev/null || true
  fi

  # Build flag list. Root gets --permission-mode auto auto-injected.
  local -a extra_flags
  extra_flags=()
  if [ "$(id -u)" -eq 0 ]; then
    extra_flags=(--permission-mode auto)
  fi

  # Always-on ultracode (operator standing directive: run ultracode every
  # session for consistent high-effort execution).
  # ultracode is session-only state — NOT persistable in settings.json
  # (verified: no `ultracode` settings key in the docs, and `--effort
  # ultracode` is rejected; valid efforts are low|medium|high|xhigh|max).
  # The only launch-time lever is `--settings` inline JSON. Verified SAFE
  # to inject: command-line --settings is precedence layer #2 ("command
  # line arguments") and merges PER-KEY — it adds `ultracode` and leaves
  # every settings.json key (autoCompactEnabled, effortLevel, env, hooks)
  # resolved from the User scope. It does NOT wholesale-replace the file.
  # Covers any profile you run through this function: bare `claude`, and
  # any wrapper/alias for a second profile (e.g. via `CLAUDE_CONFIG_DIR`)
  # that ultimately calls `claude`.
  # Skipped when the caller already passed --settings so their flag wins
  # and we never emit a double --settings. (Benign false-skip if a prompt
  # arg literally contains the token "--settings"; the operator runs plain
  # `claude`, so this is a non-issue in practice.)
  case " $* " in
    *" --settings "*|*" --settings="*) : ;;
    *) extra_flags+=(--settings '{"ultracode":true}') ;;
  esac

  # Shared host → serialize via flock (non-blocking; conflict exit 99).
  # Normal single-user host → DON'T lock, so concurrent same-profile sessions
  # (parallel work) run freely.
  if [ "$__ac_use_lock" -eq 1 ] && command -v flock >/dev/null 2>&1 \
     && [ -e "$__ac_claude_lockfile" ]; then
    flock -n -E 99 "$__ac_claude_lockfile" "$__ac_claude_bin" "${extra_flags[@]}" "$@"
    local rc=$?
    if [ "$rc" -eq 99 ]; then
      echo "claude: another claude session is already running on this SHARED-HOST config dir." >&2
      echo "        Lockfile: $__ac_claude_lockfile" >&2
      echo "        Wait for it to exit, or: pgrep -af claude && kill <pid>" >&2
      return 1
    fi
    return $rc
  fi

  # Not a shared host (or flock unavailable): run directly. Concurrent
  # same-profile sessions are allowed by design here.
  "$__ac_claude_bin" "${extra_flags[@]}" "$@"
}
