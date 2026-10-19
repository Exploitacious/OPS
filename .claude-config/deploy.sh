#!/usr/bin/env bash
# OPS Stage 2 deployer (Linux). Mirrors deploy.ps1 (Windows).
#
# Stage 2 owns everything OPS-specific. Stage 1 (linuxploitacious's
# shellSetup.sh) owns host setup + Level 1 Claude files
# (settings.json, CLAUDE.md, statusline.sh from claude/.claude/).
# Do NOT deploy Level 1 files here.
#
# What this script does (in order):
#   1. Symlink ~/.claude/{skills,commands,agents,workflows} -> OPS sources
#   2. Mount the shared skills: clone the public skill source under PROJECTS/
#      when it is absent, then mirror SKILLS/VENDORED.tsv (bin/skills-vendor.sh)
#   3. Link the always-loaded core: ~/.claude/rules/ops-core.md -> CONTEXT/core.md
#   4. Strip the retired fleet wiring (PATH export in ~/.<shell>rc.local, the
#      old wrapper source line in a real ~/.zshrc or ~/.bashrc)
#   5. Wire claude-root-wrapper.sh into root's shellrcs (root permission mode
#      + shared-host lock); needs passwordless sudo
#   6. Write the ultracode-only claude() shim to ~/.<shell>rc.local
#   7. Initialize Claude Code auto-memory git-sync (bin/memory-init)
#   8. Schedule the daily backup cron entry
#   9. Retire the caveman + ponytail Claude Code plugins (uninstall if present)
#  10. Seed the trust anchor
#
# Flags:
#   --no-system   skip every step that writes outside $HOME (the root rc
#                 wiring, step 5, and the user crontab, step 8). For test
#                 installs under a throwaway HOME: crontab is per user, not
#                 per HOME, so a test run would otherwise schedule a backup of
#                 the throwaway tree in the real user's crontab. Same as
#                 OPS_DEPLOY_NO_SYSTEM=1.
#
# Never writes settings.json: on a linuxploitacious host it is a symlink into
# the user's tracked Stage-1 checkout, so a write there dirties that public
# repo, and its next `git pull --ff-only` fails whenever upstream changed the
# same file. An earlier version ran bin/model-probe.sh here, which rewrote the
# "model" pin on every deploy; that step is gone, and model-probe.sh now only
# reports.
#
# Idempotent. Safe to re-run after any OPS git pull.
# Full procedure: see ~/OPS/DEPLOYMENT.md.

set -euo pipefail

NO_SYSTEM="${OPS_DEPLOY_NO_SYSTEM:-0}"
for arg in "$@"; do
  case "$arg" in
    --no-system) NO_SYSTEM=1 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "deploy.sh: unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

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

# Steps that must not abort the rest of the deploy record a failure here; the
# summary prints it and the script exits non-zero (never a silent success).
DEPLOY_FAILED=""

echo ""
c_cyan "CLAUDE CODE CONFIG DEPLOY (Linux)"
c_cyan "--------------------------------------------------"
[[ "$NO_SYSTEM" == 1 ]] && c_yel "  --no-system: skipping the root rc wiring and the crontab entry"
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
    # Real dir or file: back it up
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

# --- Mount the shared skills (clone the public source once, then sync) ---
# SKILLS/VENDORED.tsv lists the portable skills OPS mounts from the public
# Exploitacious/agent-skills repo (MIT); bin/skills-vendor.sh mirrors them from
# a clone under PROJECTS/ into SKILLS/<name>/. Without the clone a fresh install
# has none of the mounted skills, and with a clone but no sync the drift gate
# reads DRIFT. Deploy clones only when the source is absent and never pulls an
# existing clone: a re-deploy must not pull an unreviewed upstream HEAD into
# skills every session loads. Update deliberately: `git -C <clone> pull
# --ff-only`, then `skills-vendor.sh sync`. HTTPS, because a public repo needs
# no SSH key. Clone into a temporary sibling so a failed or interrupted clone
# cannot poison the canonical path and block the next deploy's retry.
echo ""
c_yel "Mounting shared skills..."
SKILLS_SOURCE_URL="https://github.com/Exploitacious/agent-skills.git"
SKILLS_SOURCE_DIR="${OPS_ROOT}/PROJECTS/Exploitacious/agent-skills"
SKILLS_VENDOR="${CONFIG_DIR}/bin/skills-vendor.sh"

mount_skills() {
  if [[ ! -r "${OPS_ROOT}/SKILLS/VENDORED.tsv" ]]; then
    msg_bad "Cannot read SKILLS/VENDORED.tsv: mounted skills cannot be verified."
    return 1
  fi
  if ! grep -qE '^[^#[:space:]][^[:space:]]*[[:space:]]+Exploitacious/agent-skills/' "${OPS_ROOT}/SKILLS/VENDORED.tsv" 2>/dev/null; then
    msg_ok "No mounted skills from Exploitacious/agent-skills in SKILLS/VENDORED.tsv"
    return 0
  fi
  if [[ -d "$SKILLS_SOURCE_DIR/.git" || -f "$SKILLS_SOURCE_DIR/.git" ]]; then
    if ! git -C "$SKILLS_SOURCE_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
      msg_bad "$SKILLS_SOURCE_DIR is an incomplete clone: move it aside, then re-run."
      return 1
    fi
    msg_ok "Skill source already cloned: $SKILLS_SOURCE_DIR (not pulled; see the comment above)"
  elif [[ -e "$SKILLS_SOURCE_DIR" || -L "$SKILLS_SOURCE_DIR" ]]; then
    msg_bad "$SKILLS_SOURCE_DIR exists but is not a git clone: move it aside, then re-run."
    return 1
  elif ! command -v git >/dev/null 2>&1; then
    msg_bad "git not found: cannot clone $SKILLS_SOURCE_URL. Mounted skills stay MISSING."
    return 1
  else
    local clone_tmp
    if ! mkdir -p "${SKILLS_SOURCE_DIR%/*}" \
       || ! clone_tmp="$(mktemp -d "${SKILLS_SOURCE_DIR}.clone.XXXXXX")"; then
      msg_bad "Cannot prepare a temporary skill-source clone."
      return 1
    fi
    if ! git clone --quiet "$SKILLS_SOURCE_URL" "$clone_tmp"; then
      rm -rf -- "$clone_tmp"
      msg_bad "Could not clone $SKILLS_SOURCE_URL (network?). Re-run deploy to retry."
      return 1
    fi
    # -T prevents copying into a concurrently created directory; -n preserves
    # it. GNU mv can return zero when -n skips, so also require the temp gone.
    if ! mv -Tn -- "$clone_tmp" "$SKILLS_SOURCE_DIR" || [[ -e "$clone_tmp" ]]; then
      rm -rf -- "$clone_tmp"
      msg_bad "Skill source appeared during cloning: left $SKILLS_SOURCE_DIR unchanged. Re-run deploy."
      return 1
    fi
    msg_ok "Cloned $SKILLS_SOURCE_URL -> $SKILLS_SOURCE_DIR"
  fi
  if OPS_DIR="$OPS_ROOT" bash "$SKILLS_VENDOR" sync \
     && OPS_DIR="$OPS_ROOT" bash "$SKILLS_VENDOR" --check; then
    # sync deliberately skips uncloned sources. A deploy must also prove every
    # declared mount exists, rather than reporting success with missing skills.
    msg_ok "Mounted skills synced and verified in ${OPS_ROOT}/SKILLS"
  else
    msg_bad "skills-vendor.sh sync failed: mounted skills are out of date (verify-ops reports DRIFT)."
    return 1
  fi
}
mount_skills || DEPLOY_FAILED="$DEPLOY_FAILED skills-mount"

# --- The always-loaded core: ~/.claude/rules/ops-core.md -> CONTEXT/core.md ---
# CONTEXT/core.md is the one file every session and lane must have loaded.
# Claude Code loads every rule file in the user rules dir at launch, for every
# project and with no approval prompt, on every launch path that reads user
# settings: the terminal, T3 Code (its Claude threads pass no --setting-sources,
# so user settings and memory load as in a terminal), IDE extensions, and
# `claude -p`. The route this replaces, a claude() shell function appending the
# charter to the system prompt, ran only for launches typed into an
# interactive shell, so T3 Code and IDE sessions booted without doctrine. The
# Stage-1 ~/.claude/CLAUDE.md is no substitute: on a host without the private
# harness it only asks the model to read ~/OPS/CONTEXT/core.md, a requested
# read rather than a load. A symlink, not a copy: a copy goes stale on the next
# pull. verify-ops.sh check 16 fails when the link is missing or points
# elsewhere.
echo ""
c_yel "Linking the always-loaded core..."
CORE_SRC="${OPS_ROOT}/CONTEXT/core.md"
CORE_RULE_DIR="${CLAUDE_HOME}/rules"
CORE_RULE="${CORE_RULE_DIR}/ops-core.md"

ensure_core_rule() {
  if [[ ! -f "$CORE_SRC" ]]; then
    msg_bad "CONTEXT/core.md missing at $CORE_SRC: sessions would boot without the core."
    return 1
  fi
  # A symlinked rules dir points into another tree (often a tracked dotfiles
  # checkout); writing into it would dirty that tree.
  if [[ -L "$CORE_RULE_DIR" ]]; then
    msg_bad "$CORE_RULE_DIR is a symlink: refusing to write into it. Link it by hand: ln -s $CORE_SRC <real rules dir>/ops-core.md"
    return 1
  fi
  mkdir -p "$CORE_RULE_DIR" || { msg_bad "Could not create $CORE_RULE_DIR"; return 1; }
  if [[ -L "$CORE_RULE" ]]; then
    if [[ "$(readlink -f "$CORE_RULE")" == "$(readlink -f "$CORE_SRC")" ]]; then
      msg_ok "Core already linked: $CORE_RULE -> $CORE_SRC"
      return 0
    fi
    msg_action "Repointing $CORE_RULE (was $(readlink "$CORE_RULE"))"
    if ! rm -f -- "$CORE_RULE"; then
      msg_bad "Could not remove the stale core rule at $CORE_RULE."
      return 1
    fi
  elif [[ -e "$CORE_RULE" ]]; then
    if [[ ! -f "$CORE_RULE" ]]; then
      msg_bad "$CORE_RULE is not a regular file: refusing to replace it."
      return 1
    fi
    # Unique even on rapid redeploys. A timestamp alone can overwrite the only
    # copy of a prior operator rule. The suffix is not .md, so it is not loaded.
    local backup
    if ! backup="$(mktemp "${CORE_RULE}.backup_XXXXXX")"; then
      msg_bad "Could not reserve a backup for $CORE_RULE."
      return 1
    fi
    if ! mv -T -- "$CORE_RULE" "$backup"; then
      rm -f -- "$backup"
      msg_bad "Could not back up $CORE_RULE: left the rule unchanged."
      return 1
    fi
    msg_warn "Backed up existing $CORE_RULE to $backup"
  fi
  # -T rejects a directory or directory symlink created at the target by a
  # concurrent deploy; plain ln would instead create a link inside that tree.
  if ln -sT -- "$CORE_SRC" "$CORE_RULE"; then
    msg_ok "Linked core: $CORE_RULE -> $CORE_SRC"
  else
    msg_bad "Failed to link $CORE_RULE"
    return 1
  fi
}
ensure_core_rule || DEPLOY_FAILED="$DEPLOY_FAILED core-rule"

# --- Legacy cleanup: the retired fleet's shell wiring ---
# The multi-agent fleet (WORKFORCE/) is retired and its bin dir is gone from
# the repo, but earlier deploys appended two blocks for it:
#   - a marker + PATH export to BOTH untracked ~/.zshrc.local and
#     ~/.bashrc.local;
#   - a marker + source line for WORKFORCE/bin/claude-wrapper.sh to ~/.zshrc
#     and ~/.bashrc, when those were real files rather than Stage-1 symlinks.
# Strip those exact lines (and the blank separator the old append put before
# them) so no shell carries a PATH entry or a source line for a file that no
# longer exists. Whole-line exact matches only, so nothing the operator wrote is
# touched. Idempotent: a clean file is a no-op. These literals exist ONLY to
# match and strip what older deploys wrote; nothing adds them any more.
LEGACY_FLEET_PATH_MARKER='# --- OPS WORKFORCE/bin PATH (WS-3 localrc seam) ---'
LEGACY_FLEET_PATH_EXPORT='export PATH="$HOME/OPS/WORKFORCE/bin:$PATH"'
# The same marker keys the root wiring below (wire_wrapper_root heals the
# old WORKFORCE source in /root rcs into the current wrapper source).
LEGACY_USER_WRAPPER_MARKER='# --- OPS Claude wrapper (root/user safety) ---'
LEGACY_USER_WRAPPER_SOURCE='source "$HOME/OPS/WORKFORCE/bin/claude-wrapper.sh" 2>/dev/null'

# strip_legacy_pair <file> <what> <line-a> <line-b>
strip_legacy_pair() {
  local target="$1" what="$2" line_a="$3" line_b="$4"
  [[ -e "$target" || -L "$target" ]] || return 0
  # These are expected to be real, host-local files. Refuse a symlink: the mv
  # below would replace the link with a regular file.
  if [[ -L "$target" ]]; then
    msg_warn "$target is a symlink: refusing $what cleanup (expected a real file)."
    return 0
  fi
  if ! grep -qxF -e "$line_a" -e "$line_b" "$target" 2>/dev/null; then
    msg_ok "No $what in $target"
    return 0
  fi
  local tmp
  if ! tmp="$(mktemp "${target}.legacy.XXXXXX")"; then
    msg_bad "Could not create a temp file beside $target: $what left in place."
    return 0
  fi
  if awk -v a="$line_a" -v b="$line_b" '
      $0 == "" { if (held) print ""; held = 1; next }
      $0 == a || $0 == b { held = 0; next }
      { if (held) print ""; held = 0; print }
      END { if (held) print "" }
    ' "$target" > "$tmp" \
     && chmod --reference="$target" "$tmp" \
     && mv "$tmp" "$target"; then
    msg_ok "Removed $what from $target (open a new shell to pick up)"
  else
    rm -f "$tmp" 2>/dev/null
    msg_bad "Could not rewrite $target: $what left in place."
  fi
}

echo ""
c_yel "Cleaning up the retired fleet wiring..."
strip_legacy_pair "$HOME/.zshrc.local" "retired fleet PATH export" "$LEGACY_FLEET_PATH_MARKER" "$LEGACY_FLEET_PATH_EXPORT"
strip_legacy_pair "$HOME/.bashrc.local" "retired fleet PATH export" "$LEGACY_FLEET_PATH_MARKER" "$LEGACY_FLEET_PATH_EXPORT"
# A Stage-1 rc is a symlink into the public linuxploitacious checkout; the old
# deploy never appended there, so only a real rc file can carry the block.
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [[ -L "$rc" ]] && continue
  strip_legacy_pair "$rc" "retired fleet wrapper source" "$LEGACY_USER_WRAPPER_MARKER" "$LEGACY_USER_WRAPPER_SOURCE"
done

# --- Claude root wrapper (permission-mode shim + shared-host flock) ---
# .claude-config/bin/claude-root-wrapper.sh handles two issues that surface
# when claude runs as root on a host where the operator also runs it:
#   1. Claude refuses bypassPermissions when running as root, so the wrapper
#      injects --permission-mode auto at the CLI level (no settings edit).
#   2. Concurrent claude processes across the operator + root corrupt a shared
#      config dir, so the wrapper holds a flock and only one runs at a time.
# Wired for ROOT only. The operator's ~/.zshrc and ~/.bashrc are Stage-1
# symlinks into the PUBLIC linuxploitacious repo (an append dirties that repo or
# is wiped on the next `git pull --ff-only`), and the operator's own claude() is
# the flock-free ultracode shim in ~/.<shell>rc.local (ensure_claude_localrc
# below); a per-config-dir flock there would block the operator's concurrent
# same-profile sessions. Root's rcs get an absolute source line (root's $HOME is
# /root, so a $HOME-based path would resolve to /root/OPS and silently fail).
# Idempotent.
echo ""
c_yel "Wiring Claude root wrapper..."

WRAPPER_FILE="${CONFIG_DIR}/bin/claude-root-wrapper.sh"
# The marker string is the idempotency key already written into /root rcs on
# provisioned boxes; changing it would orphan those blocks. Keep it verbatim.
WRAPPER_MARKER='# --- OPS Claude wrapper (root/user safety) ---'
# Match only the standalone source lines deploy wrote: the fleet wrapper in its
# absolute and old $HOME forms, and the current wrapper from any checkout. A
# filename substring also matches comments, variables and compound commands:
# deleting those would discard unrelated operator setup.
WRAPPER_SOURCE_RE='^source ("(/[^"`]*|[$]HOME/OPS)/(WORKFORCE/bin/claude-wrapper[.]sh|[.]claude-config/bin/claude-root-wrapper[.]sh)"|/[^[:space:]";|&<>`$()]+/(WORKFORCE/bin/claude-wrapper[.]sh|[.]claude-config/bin/claude-root-wrapper[.]sh)) 2>/dev/null$'
WRAPPER_SOURCE_LINE="source \"${WRAPPER_FILE}\" 2>/dev/null"

wire_wrapper_root() {
  local target="$1"
  sudo test -f "$target" || return 0
  # Refuse symlinks: the rewrite below replaces the file, which would turn a
  # symlink into a regular file and detach it from whatever it points at.
  if sudo test -L "$target"; then
    msg_warn "$target is a symlink: refusing wrapper wiring (expected a real file). Manual: add '${WRAPPER_SOURCE_LINE}'"
    return 0
  fi
  # Exactly one marker and one current source. A second generated source
  # from another checkout must not survive merely because this one exists.
  if sudo awk -v m="$WRAPPER_MARKER" -v re="$WRAPPER_SOURCE_RE" -v current="$WRAPPER_SOURCE_LINE" '
      $0 == m { markers++ }
      $0 ~ re { sources++; if ($0 != current) stale++ }
      END { exit !(markers == 1 && sources == 1 && !stale) }
    ' "$target"; then
    msg_ok "Wrapper already wired in $target"
    return 0
  fi
  # Self-heal: strip every marker and generated source line, including the
  # fleet wrapper's and a source from a different checkout, plus the blank line
  # held before any of those (an earlier append's separator, or a trailing blank
  # the END separator replaces), then append one fresh block. Temp file + mv so
  # a failed rewrite never truncates the rc.
  local tmp
  if ! tmp="$(sudo mktemp "${target}.wrapper.XXXXXX")"; then
    msg_bad "Could not create a temp file beside $target: wrapper not wired."
    return 0
  fi
  if sudo awk -v m="$WRAPPER_MARKER" -v re="$WRAPPER_SOURCE_RE" '
      $0 == "" { if (held) print ""; held = 1; next }
      $0 == m || $0 ~ re { held = 0; next }
      { if (held) print ""; held = 0; print }
      END { print ""; print m }
    ' "$target" | sudo tee "$tmp" >/dev/null \
     && printf '%s\n' "$WRAPPER_SOURCE_LINE" | sudo tee -a "$tmp" >/dev/null \
     && sudo chmod --reference="$target" "$tmp" \
     && sudo chown --reference="$target" "$tmp" \
     && sudo mv "$tmp" "$target"; then
    msg_ok "Wired wrapper into $target"
  else
    sudo rm -f "$tmp" 2>/dev/null
    msg_bad "Could not rewrite $target: wrapper not wired; left the file as it was."
  fi
}

if [[ "$NO_SYSTEM" == 1 ]]; then
  msg_warn "--no-system: /root rcs not wired. Manual: add '${WRAPPER_SOURCE_LINE}' to /root/.zshrc + /root/.bashrc"
elif [[ -f "$WRAPPER_FILE" ]]; then
  if sudo -n true 2>/dev/null; then
    wire_wrapper_root /root/.zshrc
    wire_wrapper_root /root/.bashrc
  else
    msg_warn "Passwordless sudo unavailable: /root rcs not wired."
    msg_warn "Manual: add '${WRAPPER_SOURCE_LINE}' to /root/.zshrc + /root/.bashrc"
  fi
else
  msg_bad "claude-root-wrapper.sh not present at $WRAPPER_FILE: /root rcs not wired."
fi

# --- Always-on ultracode shim ---
# ultracode every interactive Claude Code session, so it is never forgotten.
# Written to the UNTRACKED ~/.<shell>rc.local files (sourced by the generic
# .local seam at the end of the Stage-1 rc files). Kept OUT of the tracked
# public repo on purpose: ultracode is an operator choice, and forcing its token
# cost on every linuxploitacious cloner would be wrong. Kept OUT of the root
# wrapper on purpose: that wrapper is wired for root only, and its
# per-config-dir lock would block the operator's concurrent same-profile
# sessions. ultracode is session-only (no settings.json key; `--effort
# ultracode` is rejected): `--settings` inline JSON is the only launch lever,
# and it MERGES per key (adds the key, does not replace settings.json).
#
# The shim is ultracode-only. The core loads through ~/.claude/rules (above),
# so the shim appends no system prompt: the earlier boot shim appended the
# charter and digest through --append-system-prompt, which only ever reached
# launches typed into a shell. Older hosts carry one of two earlier blocks
# under the same marker: the original ultracode-only function or that boot
# shim (neither has a version tag). The version tag on the line after the
# marker is the idempotency key:
#   - marker + current tag: nothing to do, even if the function body was
#     edited (BOOTSTRAP Round F edits its --settings JSON to turn permission
#     prompts back on, and a re-deploy must keep that choice);
#   - marker without the current tag: validate the managed function and
#     replace it atomically, carrying over a --settings JSON the operator
#     customized;
#   - ambiguous or malformed blocks fail without modifying the file.
echo ""
c_yel "Wiring always-on ultracode shim..."
# The marker string is the idempotency key already written into ~/.<shell>rc.local
# on provisioned boxes; changing it would orphan those blocks. Keep it verbatim.
ULTRACODE_MARKER='# --- Always-on ultracode for interactive Claude Code (WS-3) ---'
# Bump the version whenever the shim body changes; the self-heal keys on it.
ULTRACODE_SHIM_TAG='# ops-shim-version: 2 (ultracode only; CONTEXT/core.md loads through ~/.claude/rules)'

ensure_claude_localrc() {
  local target="$1"
  # Never follow a localrc symlink into a public stow checkout. Build the whole
  # replacement before touching the original, and reject ambiguous marker blocks:
  # the next column-zero brace may belong to an unrelated user function.
  if [[ -L "$target" ]]; then
    msg_warn "Refusing symlinked localrc $target"
    return 1
  fi
  local shim result
  shim="$(
    echo "$ULTRACODE_MARKER"
    echo "$ULTRACODE_SHIM_TAG"
    cat <<'SHIM'
# `command claude` avoids recursion. Flock-free on purpose (a per-config-dir
# flock would block concurrent same-profile sessions). One job: add ultracode
# via --settings unless the caller already passed --settings (ultracode is
# session-only, no settings.json key; a second --settings would override the
# caller's own). The standing orders are not injected here: CONTEXT/core.md
# loads through ~/.claude/rules/ops-core.md on every launch path.
claude() {
  case " $* " in
    *" --settings "*|*" --settings="*) command claude "$@" ;;
    *) command claude --settings '{"ultracode":true}' "$@" ;;
  esac
}
SHIM
  )" || return 1
  if ! result="$(python3 - "$target" "$ULTRACODE_MARKER" "$ULTRACODE_SHIM_TAG" "$shim" <<'PYRC'
import json, os, re, stat, subprocess, sys, tempfile
from pathlib import Path
path = Path(sys.argv[1])
marker = sys.argv[2].encode()
tag = sys.argv[3].encode()
shim = sys.argv[4].encode() + b"\n"
DEFAULT = b"{\"ultracode\":true}"
SETTINGS_RE = re.compile(rb"--settings '([^']*)'")
try:
    if path.is_symlink():
        raise ValueError("symlinked localrc")
    original = path.read_bytes() if path.exists() else b""
    lines = original.splitlines(keepends=True)
    kept, blocks = [], []
    i = 0
    while i < len(lines):
        if lines[i].rstrip(b"\r\n") != marker:
            kept.append(lines[i]); i += 1; continue
        start = i
        i += 1
        # Only comments/blank lines may separate our marker and our function.
        while i < len(lines) and (not lines[i].strip() or lines[i].lstrip().startswith(b"#")):
            i += 1
        if i >= len(lines) or lines[i].rstrip(b"\r\n") != b"claude() {":
            raise ValueError("marker is not followed by the generated claude() function")
        fn = i
        i += 1
        while i < len(lines) and lines[i].rstrip(b"\r\n") != b"}":
            # Generated bodies indent every executable line. A later user
            # function cannot become the end of a truncated generated one.
            if lines[i].strip() and not lines[i].startswith((b" ", b"\t", b"#")):
                raise ValueError("no closing brace before unrelated user content")
            i += 1
        if i == len(lines):
            raise ValueError("no closing brace after the marker")
        body = b"".join(lines[fn:i+1]).replace(b"\r\n", b"\n")
        if subprocess.run(["bash", "-n"], input=body, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode:
            raise ValueError("generated function does not parse independently")
        blocks.append(b"".join(lines[start:i+1]))
        if kept and kept[-1] in (b"\n", b"\r\n"):
            kept.pop()  # exactly the separator written with our block
        i += 1
    rest = b"".join(kept)
    if re.search(rb"(?m)^\s*(?:function\s+claude\b|claude\s*\(\s*\))", rest):
        raise ValueError("unmanaged claude function exists; refusing a duplicate")
    tagged = [b for b in blocks if tag in [l.rstrip(b"\r\n") for l in b.splitlines()]]
    if len(blocks) == 1 and tagged:
        print("current")
        sys.exit(0)
    if tagged:
        # Duplicates around a current block: keep the current one as written
        # (it may carry the operator's Round F edit) and drop the rest.
        new_block = tagged[0].replace(b"\r\n", b"\n")
        if not new_block.endswith(b"\n"):
            new_block += b"\n"
    else:
        # Untagged blocks: carry over one customized --settings JSON, if any.
        values = set()
        for block in blocks:
            for line in block.splitlines():
                if line.lstrip().startswith(b"#") or b"command claude" not in line:
                    continue
                args = line.split(b"command claude", 1)[1]
                if re.search(rb"--settings(?:[ \t=]|$)", args):
                    found = SETTINGS_RE.findall(args)
                    if not found:
                        raise ValueError("custom --settings quoting or file argument; migrate that shim manually")
                    values.update(found)
        # This matcher handles the generated single-quoted JSON form only.
        # Shell-escaped apostrophes truncate a match into invalid JSON; reject
        # it before replacing a valid, customized function with a broken one.
        for value in values:
            try:
                json.loads(value)
            except (ValueError, UnicodeError):
                raise ValueError("old --settings argument is not intact JSON; migrate that customized shim manually") from None
        custom = values - {DEFAULT}
        if len(custom) > 1:
            raise ValueError("old blocks carry conflicting --settings JSON")
        new_block = shim
        if custom:
            new_block = shim.replace(b"'" + DEFAULT + b"'", b"'" + custom.pop() + b"'")
    replacement = rest + b"\n" + new_block
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".ultracode.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(replacement)
            f.flush()
            os.fchmod(f.fileno(), mode)
        # Detect an intervening edit instead of replacing it from our snapshot.
        if path.is_symlink() or (path.read_bytes() if path.exists() else b"") != original:
            raise ValueError("localrc changed during migration")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print("healed" if blocks else "created")
except (OSError, ValueError) as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
PYRC
  )"; then
    msg_warn "Could not safely update $target (no closing brace or ambiguous block): leaving the file unchanged"
    return 1
  fi
  if [[ "$result" == current ]]; then
    msg_ok "Ultracode shim already current in $target"
  else
    [[ "$result" != healed ]] || msg_action "Removed the old ultracode block in $target (rewriting as shim version 2)"
    msg_ok "Wrote ultracode shim (version 2) to $target"
  fi
}

# A refused .local is reported above and left as it was; the deploy goes on.
ensure_claude_localrc "$HOME/.zshrc.local" || true
ensure_claude_localrc "$HOME/.bashrc.local" || true

# --- Claude Code auto-memory git-sync ---
# bin/memory-init walks Claude's encoded cwd subdirs and symlinks each into
# .claude-memory/<host>-<encoded>/ so per-session memory survives in this
# repo. Idempotent + safe on every machine.
echo ""
c_yel "Initializing Claude Code auto-memory git-sync..."

MEMORY_INIT="${CONFIG_DIR}/bin/memory-init"
if [[ -x "$MEMORY_INIT" ]]; then
  if OPS_DIR="$OPS_ROOT" "$MEMORY_INIT" --auto-commit; then
    msg_ok "Memory sync initialized (or already in place)."
  else
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
      msg_warn "memory-init: .gitignore excludes target. Fix and re-run."
    else
      msg_warn "memory-init exited rc=$rc: inspect manually."
    fi
    DEPLOY_FAILED="$DEPLOY_FAILED memory-init"
  fi
else
  msg_bad "memory-init not executable at $MEMORY_INIT: memory sync not initialized."
  DEPLOY_FAILED="$DEPLOY_FAILED memory-init"
fi

# --- Daily backup cron job ---
echo ""
c_yel "Checking daily backup cron job..."

BACKUP_SCRIPT="${CONFIG_DIR}/backup/daily-sync.sh"
CRON_TAG="# OPS Daily Backup"
CRON_LINE="0 9 * * * ${BACKUP_SCRIPT} ${CRON_TAG}"

if [[ "$NO_SYSTEM" == 1 ]]; then
  msg_warn "--no-system: crontab not touched. Manual: $CRON_LINE"
elif [[ ! -f "$BACKUP_SCRIPT" ]]; then
  msg_warn "Backup script not found at $BACKUP_SCRIPT: skipping cron."
else
  chmod +x "$BACKUP_SCRIPT"

  if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
    msg_ok "Cron job already installed."
  else
    if (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -; then
      msg_ok "Cron job installed (daily at 9:00 AM): $BACKUP_SCRIPT"
    else
      msg_bad "Failed to install cron job. Add manually: $CRON_LINE"
      DEPLOY_FAILED="$DEPLOY_FAILED cron"
    fi
  fi
fi

# --- Claude Code plugins: retire caveman + ponytail ---
echo ""
c_yel "Retiring caveman + ponytail Claude Code plugins..."

# A bare `bash deploy.sh` doesn't source the user's login profile, so PATH
# may lack ~/.local/bin or pnpm's bin dir even when claude is installed.
# Probe known install locations before giving up. If running under sudo or
# as root, also check $SUDO_USER's home: the invoking user often has the
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

# Retire the caveman + ponytail plugins. This block used to INSTALL caveman,
# unpinned, from its third-party marketplace head, right after Stage 1 had
# uninstalled it; Stage 1 retires both plugins because their terse-prose and
# lazy-engineering modes are now part of the harness's own operating rules.
# The CLI also edits settings.json when removing a declared plugin or
# marketplace. Leave those declarations to Stage 1: CLI writes also follow
# its symlink into another tracked checkout. Never delete plugin dirs by hand.
retire_plugins() {
  local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  local plugins markets plg rc
  if ! command -v jq >/dev/null 2>&1; then
    msg_warn "jq unavailable: cannot safely inspect plugin retirement; skipping."
    return 0
  fi
  if [[ -f "$settings" ]] && ! jq -e 'type == "object" and
      ((.enabledPlugins // {}) | type == "object") and
      ((.extraKnownMarketplaces // {}) | type == "object")' "$settings" >/dev/null 2>&1; then
    msg_warn "Cannot read plugin declarations in $settings; retirement skipped."
    return 0
  fi
  if ! plugins="$("$CLAUDE_BIN" plugin list --json 2>/dev/null)" ||
     ! jq -e 'type == "array"' <<< "$plugins" >/dev/null 2>&1; then
    msg_warn "Cannot list installed plugins; retirement skipped. Run: claude plugin list --json"
    return 0
  fi
  if ! markets="$("$CLAUDE_BIN" plugin marketplace list --json 2>/dev/null)" ||
     ! jq -e 'type == "array"' <<< "$markets" >/dev/null 2>&1; then
    msg_warn "Cannot list plugin marketplaces; retirement skipped. Run: claude plugin marketplace list --json"
    return 0
  fi
  for plg in caveman ponytail; do
    if [[ -f "$settings" ]] && jq -e --arg id "$plg@$plg" --arg name "$plg" \
        '((.enabledPlugins // {}) | has($id)) or ((.extraKnownMarketplaces // {}) | has($name))' \
        "$settings" >/dev/null 2>&1; then
      msg_warn "Retired plugin $plg is declared in $settings; removal would edit Stage-1 settings. Update Stage 1, then re-run deploy."
      continue
    fi
    if jq -e --arg id "$plg@$plg" '.[] | select(.id == $id and .scope != "user")' <<< "$plugins" >/dev/null; then
      msg_warn "Retired plugin $plg remains in a project or local scope; left unchanged to protect project settings."
    fi
    if jq -e --arg id "$plg@$plg" '.[] | select(.id == $id and .scope == "user")' <<< "$plugins" >/dev/null; then
      if "$CLAUDE_BIN" plugin uninstall "$plg@$plg" --scope user >/dev/null 2>&1; then
        msg_ok "Removed retired plugin: $plg"
      else
        rc=$?
        msg_warn "Retired plugin $plg could not be removed (rc=$rc); inspect: claude plugin list --json"
        continue
      fi
    fi
    # Unscoped marketplace removal can edit the caller's project settings.
    if jq -e --arg name "$plg" '.[] | select(.name == $name)' <<< "$markets" >/dev/null; then
      if "$CLAUDE_BIN" plugin marketplace remove "$plg" --scope user >/dev/null 2>&1; then
        msg_ok "Removed retired plugin marketplace: $plg"
      else
        rc=$?
        msg_warn "Retired marketplace $plg remains (rc=$rc); inspect its declaration before removing it: claude plugin marketplace list --json"
      fi
    fi
  done
}

if [[ -n "$CLAUDE_BIN" ]]; then
  msg_ok "Claude CLI: $CLAUDE_BIN"
  retire_plugins
else
  msg_warn "Claude CLI not found in PATH or standard install locations."
  msg_warn "Checked: \$PATH, ~/.local/bin, ~/.local/share/pnpm, ~/.npm-global/bin, /usr/local/bin, /opt/homebrew/bin"
  msg_warn "Install Claude Code first: https://claude.ai/download"
fi

# --- Trust anchor ---
# Mark $HOME trusted so Claude's parent-dir-walking trust check covers every
# repo beneath it, so no folder-trust prompt, ever. Keyed off $HOME (never a
# hardcoded username). Idempotent + atomic; merges into existing .claude.json
# without touching other keys. (If you run bypassPermissions by default this
# already silences prompts; this additionally covers non-bypass / first-run.)
#
# NOTE: if you run a second Claude Code profile via CLAUDE_CONFIG_DIR (e.g. a
# personal account alongside this one, sharing the same config surface but a
# separate .claude.json/.credentials.json), re-run seed_trust against that
# config dir too; it is not covered automatically.
echo ""
c_yel "Seeding trust anchor..."

seed_trust() {
  local jsonfile="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    msg_warn "python3 absent: cannot seed trust anchor in ${jsonfile}"
    return 1
  fi
  python3 - "$jsonfile" "$HOME" <<'PY'
import json, os, stat, sys, tempfile
from pathlib import Path
path, home = Path(sys.argv[1]), sys.argv[2]
try:
    if path.is_symlink():
        raise ValueError("symlinked app state; configure trust manually")
    original = path.read_bytes() if path.exists() else None
    # An unreadable or malformed config can still contain recoverable auth,
    # MCP, and project state. Never replace it with an empty object.
    d = json.loads(original) if original is not None else {}
    if not isinstance(d, dict):
        raise ValueError("app state must be a JSON object")
    projects = d.setdefault("projects", {})
    if not isinstance(projects, dict):
        raise ValueError("projects must be a JSON object")
    entry = projects.setdefault(home, {})
    if not isinstance(entry, dict):
        raise ValueError("project entry must be a JSON object")
    if entry.get("hasTrustDialogAccepted") is True:
        print("ok"); sys.exit(0)
    entry["hasTrustDialogAccepted"] = True
    mode = stat.S_IMODE(path.stat().st_mode) if original is not None else 0o600
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".trust.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(d, f, indent=2)
            f.flush()
            os.fchmod(f.fileno(), mode)
        if path.is_symlink() or (path.read_bytes() if path.exists() else None) != original:
            raise ValueError("app state changed during trust update")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print("set")
except (OSError, ValueError, UnicodeError) as e:
    print("Cannot seed trust; existing app state left unchanged: " + str(e), file=sys.stderr)
    sys.exit(1)
PY
}

# Claude's default app state is beside ~/.claude/, not inside it.
jf="${HOME}/.claude.json"
if result="$(seed_trust "$jf")"; then
  case "$result" in
    set) msg_ok "Trust anchor set for \$HOME in ${jf}" ;;
    ok)  msg_ok "Trust anchor already present in ${jf}" ;;
  esac
else
  msg_bad "Trust anchor could not be seeded in ${jf}; existing state was preserved."
  DEPLOY_FAILED="$DEPLOY_FAILED trust-anchor"
fi

# --- T3 Code hosts: the headless browser (pointer only) ---
# T3 Code's headless browser needs a one-time `sudo <t3 binary> browser setup`
# per host (DEPLOYMENT.md, "T3 Code hosts"). It installs system libraries and,
# on Ubuntu 23.10 and later, an AppArmor profile scoped to T3's
# chrome-headless-shell, so deploy never runs it: it only points at the step
# when a T3 runtime is present.
t3_bin="$(ls -1d "$HOME"/.t3/runtime/versions/*/t3 2>/dev/null | sort -V | tail -1 || true)"
if [[ -n "$t3_bin" ]]; then
  echo ""
  c_yel "T3 Code detected..."
  msg_action "If T3's browser is not set up on this host yet, run once: sudo $t3_bin browser setup (DEPLOYMENT.md, \"T3 Code hosts\")"
fi

echo ""
c_cyan "--------------------------------------------------"
if [[ -n "$DEPLOY_FAILED" ]]; then
  c_red "Deploy finished with failures:${DEPLOY_FAILED}"
  c_red "Fix the [XX] lines above and re-run (core-rule means sessions boot without CONTEXT/core.md)."
else
  c_green "Deploy complete."
fi
echo ""
echo "  Config source:   $CONFIG_DIR"
echo "  Claude home:     $CLAUDE_HOME       (launch: claude)"
echo "  Always loaded:   $CORE_RULE -> $CORE_SRC"
echo "  Skills source:   ${OPS_ROOT}/SKILLS"
echo ""
echo "  Model pins come from your Stage-1 settings.json; deploy does not change them."
echo "  To check they answer on your plan: ${CONFIG_DIR}/bin/model-probe.sh (report only)"
echo "  Gate: bash ${CONFIG_DIR}/bin/verify-ops.sh"
echo ""
[[ -z "$DEPLOY_FAILED" ]]
