#!/usr/bin/env bash
# Resolved at SOURCE time so error messages can name this file's real path on any
# machine and for any user (root sourcing it from another user's home included).
# Must be captured here: BASH_SOURCE inside the function would name the caller.
__crw_self="${BASH_SOURCE[0]:-}"
case "$__crw_self" in
  /*) ;;                                        # already absolute
  ?*) __crw_self="$(cd "$(dirname "$__crw_self")" 2>/dev/null && pwd)/$(basename "$__crw_self")" ;;
esac
# claude-root-wrapper.sh: shell function that wraps `claude` invocations
# for root, and for hosts where two UIDs share one Claude config dir.
#
# Wired for ROOT only: .claude-config/deploy.sh (wire_wrapper_root) appends
# an absolute source line to /root/.zshrc and /root/.bashrc:
#   source /home/<user>/OPS/.claude-config/bin/claude-root-wrapper.sh 2>/dev/null
# The absolute path matters: root's $HOME is /root, so a $HOME-based path
# resolves to /root/OPS and silently fails. The operator's own
# interactive claude() is the ultracode shim in
# ~/.<shell>rc.local (deploy.sh ensure_claude_localrc), not this file.
# This replaces the fleet's WORKFORCE/bin/claude-wrapper.sh, which deploy
# also wired into the operator's own rc files.
#
# Two protections:
#
# 1. Root permission-mode auto-fix. Claude Code refuses to honor
#    `permissionMode: bypassPermissions` from settings.json when
#    running as root (hardcoded safety check). This wrapper detects
#    root invocations and prepends `--permission-mode auto` at the
#    CLI level, overriding settings.json for that session WITHOUT
#    modifying any files. The operator keeps bypassPermissions for normal
#    sessions; root automatically degrades to auto. No manual
#    edit-settings-and-revert dance.
#
# 2. Single-instance lock, SHARED-HOST ONLY. Two UIDs sharing the SAME
#    config dir (the operator + root, where `/home/<user>/.claude/` and
#    `/root/.claude/` are one directory via symlink + ACLs) race on
#    .credentials.json, .claude.json, sessions/, history.jsonl,
#    causing the "occasionally something gets corrupted, auth lost"
#    behavior. The lock serializes ONLY that case. It is gated on a
#    shared-host signal: running as root (the documented root+operator
#    hazard), or `CLAUDE_SHARED_HOST` exported on a host that shares a
#    config dir across UIDs. On a NORMAL single-user host the lock is OFF,
#    so concurrent same-profile sessions (deliberate parallel work) run
#    freely; locking them would defeat the point. Separate profiles
#    (a second CLAUDE_CONFIG_DIR) never shared state anyway.
#    Only callers of this wrapper participate. The operator's normal shim
#    takes no lock, so root and the operator must not use a shared config
#    dir concurrently. See DEPLOYMENT.md, "Root and shared config dirs".
#
# Lockfile: <config-dir>/.instance.lock
# Conflict: flock exits 99 (distinct from claude's own exit codes); the
# function prints the conflict and returns 1.
#
# Compatibility: bash + zsh. Other shells skip silently.
# Test: .claude-config/bin/tests/claude-root-wrapper-test.sh (sources this
# file in throwaway shells; never touches a live config dir or rc).

if [ -z "${BASH_VERSION:-}" ] && [ -z "${ZSH_VERSION:-}" ]; then
  return 2>/dev/null || true
fi

# Lockfile is resolved per-invocation inside claude() from
# CLAUDE_CONFIG_DIR (set for a second profile), so each config dir locks
# independently. Do NOT resolve it here at source time:
# CLAUDE_CONFIG_DIR isn't set yet during shellrc init.

# Resolve the real claude binary, ignoring shell functions. During migration
# an existing shell still has the old claude() defined; command -v would find
# that function, discard it, then miss binaries in nonstandard PATH locations.
# If PATH doesn't include ~/.local/bin yet
# (common during early shellrc init), fall back to lazy resolution on
# first invocation via well-known install paths.
if [ -n "${ZSH_VERSION:-}" ]; then
  __crw_claude_bin=$(whence -p claude 2>/dev/null || true)
else
  __crw_claude_bin=$(type -P claude 2>/dev/null || true)
fi
# Validate: must be an absolute path to an executable.
case "$__crw_claude_bin" in
  /*) [ -x "$__crw_claude_bin" ] || __crw_claude_bin="" ;;
  *)  __crw_claude_bin="" ;;
esac

claude() {
  # Lazy resolve: if source-time lookup missed (PATH incomplete during
  # shellrc init), check well-known install locations on first call.
  if [ -z "$__crw_claude_bin" ] || [ ! -x "$__crw_claude_bin" ]; then
    local candidate
    for candidate in \
      "$HOME/.local/bin/claude" \
      "/usr/local/bin/claude" \
      "/usr/bin/claude"; do
      if [ -x "$candidate" ]; then
        __crw_claude_bin="$candidate"
        break
      fi
    done
  fi

  if [ -z "$__crw_claude_bin" ] || [ ! -x "$__crw_claude_bin" ]; then
    echo "claude: binary not found in PATH or well-known locations." >&2
    echo "        Install claude, then re-source the wrapper:" >&2
    # Self-referential on purpose: this message is shown to root, whose
    # $HOME is /root while the wrapper lives in the invoking user's home, so
    # neither $HOME nor a hardcoded user path is right. BASH_SOURCE is;
    # the literal fallback only shows under zsh, which has no BASH_SOURCE.
    echo "        source ${__crw_self:-<OPS checkout>/.claude-config/bin/claude-root-wrapper.sh}" >&2
    return 127
  fi

  # Single-instance lock is ONLY for the shared-host collision (root + the
  # operator sharing ONE config dir). On a normal single-user host, concurrent
  # same-profile sessions are DESIRED (parallel work), so we must NOT lock
  # there. Gate on the shared-host signal: running as root (the documented
  # root+operator hazard), or CLAUDE_SHARED_HOST exported on a shared-config-dir
  # host. AC_SHARED_HOST is the fleet-era name of the same signal (the retired
  # WORKFORCE wrapper read it), still honored so a host that exported it keeps
  # its lock; drop it once no rc on any box sets it.
  local __crw_use_lock=0
  if [ "$(id -u)" -eq 0 ] || [ -n "${CLAUDE_SHARED_HOST:-}" ] \
     || [ -n "${AC_SHARED_HOST:-}" ]; then
    __crw_use_lock=1
  fi
  local __crw_lockfile="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.instance.lock"

  # Build flag list. Root gets --permission-mode auto auto-injected.
  local -a extra_flags
  extra_flags=()
  if [ "$(id -u)" -eq 0 ]; then
    extra_flags=(--permission-mode auto)
  fi

  # Always-on ultracode (the harness default: ultracode every session).
  # ultracode is session-only state, NOT persistable in settings.json
  # (verified: no `ultracode` settings key in the docs, and `--effort
  # ultracode` is rejected; valid efforts are low|medium|high|xhigh|max).
  # The only launch-time lever is `--settings` inline JSON. Verified SAFE
  # to inject: command-line --settings is precedence layer #2 ("command
  # line arguments") and merges PER-KEY: it adds `ultracode` and leaves
  # every settings.json key (autoCompactEnabled, effortLevel, env, hooks)
  # resolved from the User scope. It does NOT wholesale-replace the file.
  # Root has no ~/.<shell>rc.local shim, so this is where root's ultracode
  # comes from.
  # Skipped when the caller already passed --settings so their flag wins
  # and we never emit a double --settings. (Benign false-skip if a prompt
  # arg literally contains the token "--settings"; operator runs plain
  # `claude`, so this is a non-issue in practice.)
  case " $* " in
    *" --settings "*|*" --settings="*) : ;;
    *) extra_flags+=(--settings '{"ultracode":true}') ;;
  esac

  # Shared host: serialize via flock (non-blocking; conflict exit 99).
  # Normal single-user host: DON'T lock, so concurrent same-profile sessions
  # (parallel work) run freely.
  if [ "$__crw_use_lock" -eq 1 ]; then
    # A missing dependency or first-run config dir must not bypass locking.
    # flock creates the lockfile itself; do not precheck its existence.
    if ! command -v flock >/dev/null 2>&1; then
      echo "claude: flock is required for a shared-host config dir; refusing an unlocked launch." >&2
      return 1
    fi
    if ! mkdir -p -- "${__crw_lockfile%/*}"; then
      echo "claude: cannot prepare the shared-host lock directory; refusing an unlocked launch." >&2
      return 1
    fi
    local rc=0
    flock -n -E 99 "$__crw_lockfile" "$__crw_claude_bin" "${extra_flags[@]}" "$@" || rc=$?
    if [ "$rc" -eq 99 ]; then
      echo "claude: another claude session is already running on this SHARED-HOST config dir." >&2
      echo "        Lockfile: $__crw_lockfile" >&2
      # pgrep -l, not -af: full argv can carry another session's prompt or a
      # credential, and this message is printed to whoever hits the lock.
      echo "        Wait for it to exit, or: pgrep -l claude && kill <pid>" >&2
      return 1
    fi
    return $rc
  fi

  # Not a shared host: run directly. Concurrent
  # same-profile sessions are allowed by design here.
  "$__crw_claude_bin" "${extra_flags[@]}" "$@"
}
