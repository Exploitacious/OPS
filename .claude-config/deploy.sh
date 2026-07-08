#!/usr/bin/env bash
# OPS Stage 2 deployer (Linux). Mirrors deploy.ps1 (Windows).
#
# Stage 2 owns everything OPS-specific. Stage 1 (linuxploitacious's
# shellSetup.sh) owns host setup + Level 1 Claude files
# (settings.json, CLAUDE.md, statusline.sh from claude/.claude/).
# Do NOT deploy Level 1 files here.
#
# What this script does (in order):
#   1. Symlink ~/.claude/skills/   -> OPS/SKILLS/
#   2. Symlink ~/.claude/commands/ -> OPS/.claude-config/commands/
#   3. chmod +x scripts in WORKFORCE/bin + export PATH (in shellrc)
#   4. Wire claude-wrapper.sh into the invoking user's + root's shellrcs (flock/permission-mode shim)
#   5. Initialize Claude Code auto-memory git-sync (ac-memory-init)
#   6. Schedule daily backup cron entry
#   7. Install caveman Claude Code plugin
#
# Idempotent. Safe to re-run after any OPS git pull.
# Full procedure: see ~/OPS/DEPLOYMENT.md.

set -euo pipefail

# --- Paths ---
CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_ROOT="$(cd "$CONFIG_DIR/.." && pwd)"
CLAUDE_HOME="${HOME}/.claude"

# --- Helpers ---
c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel()   { printf '\033[33m%s\033[0m\n' "$*"; }
c_cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }

msg_action() { c_cyan "  -> $*"; }
msg_ok()     { c_green "  [OK] $*"; }
msg_warn()   { c_yel   "  [!!] $*"; }
msg_bad()    { c_red   "  [XX] $*"; }

echo ""
c_cyan "CLAUDE CODE CONFIG DEPLOY (Linux)"
c_cyan "--------------------------------------------------"
echo ""

mkdir -p "$CLAUDE_HOME"

# --- Link table ---
# Format: target_name|source_path
LINKS=(
  "skills|${OPS_ROOT}/SKILLS"
  "commands|${CONFIG_DIR}/commands"
  "agents|${CONFIG_DIR}/agents"
  "workflows|${CONFIG_DIR}/workflows"
)

for entry in "${LINKS[@]}"; do
  name="${entry%%|*}"
  source="${entry##*|}"
  target="${CLAUDE_HOME}/${name}"

  if [[ ! -d "$source" ]]; then
    msg_warn "Source missing, skipping: $source"
    continue
  fi

  # Already a correct symlink?
  if [[ -L "$target" ]]; then
    existing="$(readlink -f "$target")"
    desired="$(readlink -f "$source")"
    if [[ "$existing" == "$desired" ]]; then
      msg_ok "Already linked: ${name}/"
      continue
    fi
    msg_action "Updating symlink: ${name}/"
    rm "$target"
  elif [[ -e "$target" ]]; then
    # Real dir or file — back it up
    stamp="$(date +%Y%m%d_%H%M%S)"
    backup="${target}.backup_${stamp}"
    mv "$target" "$backup"
    msg_warn "Backed up existing ${name}/ to ${backup}"
  fi

  if ln -s "$source" "$target"; then
    msg_ok "Linked: ${name}/ -> ${source}"
  else
    msg_bad "Failed to link ${name}/."
  fi
done

# --- WORKFORCE/bin (multi-agent helpers) ---
echo ""
c_yel "Wiring WORKFORCE/bin..."

WORKFORCE_BIN="${OPS_ROOT}/WORKFORCE/bin"

# Route the PATH export through the untracked ~/.<shell>rc.local seam, NOT
# ~/.zshrc/~/.bashrc directly. Those are stow symlinks into the PUBLIC
# linuxploitacious repo (same constraint documented on wire_wrapper_user
# below) — appending to them either dirties that repo or is silently wiped
# on the next `git pull --ff-only`. That is exactly the bug: fleet doctrine
# mandates bare `ac-pulse`/`ac-msg`, but the legacy append target was the
# symlink, so the PATH export never actually persisted. Fixed by writing to
# BOTH ~/.zshrc.local and ~/.bashrc.local unconditionally (mirrors
# ensure_claude_localrc below) so both shells pick it up regardless of which
# one is the operator's login shell.
WORKFORCE_PATH_MARKER='# --- OPS WORKFORCE/bin PATH (WS-3 localrc seam) ---'

ensure_workforce_path_localrc() {
  local target="$1"
  # Defense in depth, mirrors wire_wrapper_user's symlink guard below:
  # these files are expected to always be real, untracked, host-local
  # files — never append if one is ever a symlink (would risk dirtying or
  # losing writes to whatever it points at).
  if [[ -L "$target" ]]; then
    msg_warn "$target is a symlink — refusing PATH append (expected a real untracked file)."
    return 0
  fi
  # Detect BOTH the marker comment AND the actual export line — checking
  # only the marker yields a false positive if the export was hand-removed
  # while the comment lingers.
  if [[ -f "$target" ]] && grep -qF "$WORKFORCE_PATH_MARKER" "$target" 2>/dev/null \
     && grep -q 'OPS/WORKFORCE/bin' "$target" 2>/dev/null; then
    msg_ok "WORKFORCE/bin already on PATH in $target"
    return 0
  fi
  {
    echo ""
    echo "$WORKFORCE_PATH_MARKER"
    echo 'export PATH="$HOME/OPS/WORKFORCE/bin:$PATH"'
  } >> "$target"
  msg_ok "Added WORKFORCE/bin to PATH in $target (open new shell to pick up)"
}

if [[ -d "$WORKFORCE_BIN" ]]; then
  # Make all scripts executable (skip .ps1 — Windows-only)
  find "$WORKFORCE_BIN" -maxdepth 1 -type f ! -name '*.ps1' -exec chmod +x {} \;
  msg_ok "WORKFORCE/bin scripts chmod +x"

  ensure_workforce_path_localrc "$HOME/.zshrc.local"
  ensure_workforce_path_localrc "$HOME/.bashrc.local"
else
  msg_warn "WORKFORCE/bin not found — skipping PATH wiring."
fi

# --- Claude wrapper (root/regular-user flock + permission-mode shim) ---
# WORKFORCE/bin/claude-wrapper.sh handles two issues that surface when
# claude is invoked under both UIDs on the same host:
#   1. Claude refuses bypassPermissions when running as root — wrapper
#      injects --permission-mode auto at the CLI level (no settings edit).
#   2. Concurrent claude processes across the regular user + root corrupt
#      shared state — wrapper holds a flock so only one runs at a time.
# Wire it into both the invoking user's and root's shellrcs. Idempotent.
echo ""
c_yel "Wiring Claude wrapper..."

WRAPPER_FILE="${OPS_ROOT}/WORKFORCE/bin/claude-wrapper.sh"
WRAPPER_MARKER='# --- OPS Claude wrapper (root/user safety) ---'

wire_wrapper_user() {
  local target="$1"
  [[ -f "$target" ]] || return 0
  # ~/.zshrc and ~/.bashrc are stow symlinks to the PUBLIC linuxploitacious
  # repo. Appending here either dirties that repo or is wiped on the next
  # `git pull --ff-only` — which is exactly why the flock wrapper never
  # actually persisted (observed 2026-06-30: no source line in either rc,
  # claude resolved to the bare binary). Skip symlinked targets. Operator-
  # specific Claude shell config (the always-on ultracode shim) is written to
  # ~/.<shell>rc.local by ensure_claude_localrc below — untracked, survives
  # sync. Whether to auto-wire the per-config-dir flock wrapper AT ALL is
  # under review: it would block the operator's concurrent same-profile
  # sessions.
  if [[ -L "$target" ]]; then
    msg_warn "$target is a stow symlink — skipping wrapper append (would be wiped on sync). Ultracode is wired via ~/.<shell>rc.local instead."
    return 0
  fi
  # Require BOTH marker AND a source-line for claude-wrapper.sh — checking
  # only the marker yields a false positive if the source was hand-removed.
  if grep -qF "$WRAPPER_MARKER" "$target" 2>/dev/null \
     && grep -qF 'claude-wrapper.sh' "$target" 2>/dev/null; then
    msg_ok "Wrapper already wired in $target"
    return 0
  fi
  {
    echo ""
    echo "$WRAPPER_MARKER"
    echo 'source "$HOME/OPS/WORKFORCE/bin/claude-wrapper.sh" 2>/dev/null'
  } >> "$target"
  msg_ok "Wired wrapper into $target"
}

wire_wrapper_root() {
  local target="$1"
  sudo test -f "$target" || return 0
  if sudo grep -qF "$WRAPPER_MARKER" "$target" 2>/dev/null; then
    # Self-heal: earlier shellSetup.sh versions wrote $HOME-based source
    # which resolves to /root/OPS and silently fails. Replace with abs.
    if sudo grep -qF 'source "$HOME/OPS/WORKFORCE/bin/claude-wrapper.sh"' "$target" 2>/dev/null; then
      msg_action "Healing broken \$HOME-based wrapper source in $target"
      sudo sed -i.bak '/# --- OPS Claude wrapper (root\/user safety) ---/{N;d;}' "$target"
      sudo rm -f "${target}.bak"
      sudo bash -c "printf '\n%s\nsource %s 2>/dev/null\n' '$WRAPPER_MARKER' '$WRAPPER_FILE' >> '$target'"
      msg_ok "Healed wrapper source in $target"
    else
      msg_ok "Wrapper already wired in $target"
    fi
    return 0
  fi
  sudo bash -c "printf '\n%s\nsource %s 2>/dev/null\n' '$WRAPPER_MARKER' '$WRAPPER_FILE' >> '$target'"
  msg_ok "Wired wrapper into $target"
}

if [[ -f "$WRAPPER_FILE" ]]; then
  wire_wrapper_user "$HOME/.zshrc"
  wire_wrapper_user "$HOME/.bashrc"

  if sudo -n true 2>/dev/null; then
    wire_wrapper_root /root/.zshrc
    wire_wrapper_root /root/.bashrc
  else
    msg_warn "Passwordless sudo unavailable — /root rcs not wired."
    msg_warn "Manual: add 'source $WRAPPER_FILE' to /root/.zshrc + /root/.bashrc"
  fi
else
  msg_warn "claude-wrapper.sh not present at $WRAPPER_FILE — skipping."
fi

# --- Always-on ultracode shim (operator directive; WS-3) ---
# ultracode every interactive Claude Code session, so it is never forgotten.
# Written to the UNTRACKED ~/.<shell>rc.local files (sourced by the generic
# .local seam at the end of the public rc files). Kept OUT of the tracked
# public repo on purpose: ultracode is operator-specific and forcing its token
# cost on every linuxploitacious cloner would be wrong. Kept OUT of the flock
# wrapper on purpose: that wrapper's per-config-dir lock would block the
# operator's concurrent same-profile sessions. ultracode is session-only (no
# settings.json key; `--effort ultracode` is rejected) — `--settings` inline
# JSON is the only launch lever, and it MERGES per-key (adds the key, does not
# replace settings.json). Idempotent via the marker.
echo ""
c_yel "Wiring always-on ultracode shim..."
ULTRACODE_MARKER='# --- Always-on ultracode for interactive Claude Code (WS-3) ---'

ensure_claude_localrc() {
  local target="$1"
  if [[ -f "$target" ]] && grep -qF "$ULTRACODE_MARKER" "$target" 2>/dev/null; then
    msg_ok "Ultracode shim already present in $target"
    return 0
  fi
  cat >> "$target" <<EOF

$ULTRACODE_MARKER
# \`command claude\` avoids recursion when this function shadows the real
# binary. Flock-free on purpose (a per-config-dir flock would block
# concurrent same-profile sessions). Skipped if the caller already passed
# --settings.
claude() {
  case " \$* " in
    *" --settings "*|*" --settings="*) command claude "\$@" ;;
    *) command claude --settings '{"ultracode":true}' "\$@" ;;
  esac
}
EOF
  msg_ok "Wrote ultracode shim to $target"
}

ensure_claude_localrc "$HOME/.zshrc.local"
ensure_claude_localrc "$HOME/.bashrc.local"

# --- Claude Code auto-memory git-sync ---
# ac-memory-init walks Claude's encoded cwd subdirs and symlinks
# each into .claude-memory/<host>-<encoded>/ so per-session memory
# survives in this repo. Idempotent + safe on every machine.
echo ""
c_yel "Initializing Claude Code auto-memory git-sync..."

MEMORY_INIT="${OPS_ROOT}/WORKFORCE/bin/ac-memory-init"
if [[ -x "$MEMORY_INIT" ]]; then
  if "$MEMORY_INIT" --auto-commit; then
    msg_ok "Memory sync initialized (or already in place)."
  else
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
      msg_warn "ac-memory-init: .gitignore excludes target. Fix and re-run."
    else
      msg_warn "ac-memory-init exited rc=$rc — inspect manually."
    fi
  fi
else
  msg_warn "ac-memory-init not executable at $MEMORY_INIT — skipping."
fi

# --- Daily backup cron job ---
echo ""
c_yel "Checking daily backup cron job..."

BACKUP_SCRIPT="${CONFIG_DIR}/backup/daily-sync.sh"
CRON_TAG="# OPS Daily Backup"
CRON_LINE="0 9 * * * ${BACKUP_SCRIPT} ${CRON_TAG}"

if [[ ! -f "$BACKUP_SCRIPT" ]]; then
  msg_warn "Backup script not found at $BACKUP_SCRIPT — skipping cron."
else
  chmod +x "$BACKUP_SCRIPT"

  if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
    msg_ok "Cron job already installed."
  else
    if (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -; then
      msg_ok "Cron job installed (daily at 9:00 AM): $BACKUP_SCRIPT"
    else
      msg_bad "Failed to install cron job. Add manually: $CRON_LINE"
    fi
  fi
fi

# --- Claude Code plugins ---
echo ""
c_yel "Checking Claude Code plugins..."

# A bare `bash deploy.sh` doesn't source the user's login profile, so PATH
# may lack ~/.local/bin or pnpm's bin dir even when claude is installed.
# Probe known install locations before giving up. If running under sudo or
# as root, also check $SUDO_USER's home — the invoking user often has the
# CLI installed there while root does not.
find_claude() {
  local candidate user_home
  local candidates=(
    "$HOME/.local/bin/claude"
    "$HOME/.local/share/pnpm/claude"
    "$HOME/.npm-global/bin/claude"
    "/usr/local/bin/claude"
    "/opt/homebrew/bin/claude"
  )
  if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
    user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
    if [[ -n "$user_home" ]]; then
      candidates+=(
        "$user_home/.local/bin/claude"
        "$user_home/.local/share/pnpm/claude"
        "$user_home/.npm-global/bin/claude"
      )
    fi
  fi

  if command -v claude &>/dev/null; then
    command -v claude
    return 0
  fi
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

CLAUDE_BIN="$(find_claude 2>/dev/null || true)"

if [[ -n "$CLAUDE_BIN" ]]; then
  msg_ok "Claude CLI: $CLAUDE_BIN"
  msg_action "Registering caveman plugin marketplace..."
  if "$CLAUDE_BIN" plugin marketplace add JuliusBrussee/caveman >/dev/null 2>&1; then
    msg_ok "Marketplace registered."
    msg_action "Installing caveman plugin..."
    if "$CLAUDE_BIN" plugin install caveman@caveman >/dev/null 2>&1; then
      msg_ok "Caveman plugin installed."
    else
      msg_warn "Plugin install failed. Run manually: $CLAUDE_BIN plugin install caveman@caveman"
    fi
  else
    msg_warn "Marketplace add failed. Run manually: $CLAUDE_BIN plugin marketplace add JuliusBrussee/caveman"
  fi
else
  msg_warn "Claude CLI not found in PATH or standard install locations."
  msg_warn "Checked: \$PATH, ~/.local/bin, ~/.local/share/pnpm, ~/.npm-global/bin, /usr/local/bin, /opt/homebrew/bin"
  msg_warn "Install Claude Code first: https://claude.ai/download"
fi

# --- Trust anchor ---
# Mark $HOME trusted so Claude's parent-dir-walking trust check covers every
# repo beneath it — no folder-trust prompt, ever. Keyed off $HOME (never a
# hardcoded username). Idempotent + atomic; merges into existing .claude.json
# without touching other keys. (If you run bypassPermissions by default this
# already silences prompts; this additionally covers non-bypass / first-run.)
#
# NOTE: if you run a second Claude Code profile via CLAUDE_CONFIG_DIR (e.g. a
# personal account alongside this one, sharing the same config surface but a
# separate .claude.json/.credentials.json), re-run seed_trust against that
# config dir too — it is not covered automatically.
echo ""
c_yel "Seeding trust anchor..."

seed_trust() {
  local jsonfile="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    msg_warn "python3 absent — cannot seed trust anchor in ${jsonfile}"
    return 0
  fi
  python3 - "$jsonfile" "$HOME" <<'PY'
import json, os, sys
path, home = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        d = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    d = {}
entry = d.setdefault("projects", {}).setdefault(home, {})
if entry.get("hasTrustDialogAccepted") is True:
    print("ok"); sys.exit(0)
entry["hasTrustDialogAccepted"] = True
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
os.replace(tmp, path)
print("set")
PY
}

jf="${CLAUDE_HOME}/.claude.json"
if result="$(seed_trust "$jf")"; then
  case "$result" in
    set) msg_ok "Trust anchor set for \$HOME in ${jf}" ;;
    ok)  msg_ok "Trust anchor already present in ${jf}" ;;
  esac
fi

echo ""
c_cyan "--------------------------------------------------"
c_green "Deploy complete."
echo ""
echo "  Config source:   $CONFIG_DIR"
echo "  Claude home:     $CLAUDE_HOME       (launch: claude)"
echo "  Skills source:   ${OPS_ROOT}/SKILLS"
echo ""
