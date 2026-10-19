#!/usr/bin/env bash
# deploy-rc-wiring-test.sh: runnable test suite for the shell-rc and core-link
# functions in .claude-config/deploy.sh.
#
# deploy.sh is a top-to-bottom script, not a library, so each function under
# test (and the constants it reads) is extracted from the REAL deploy.sh with
# awk/grep and eval'd here; the test never runs deploy.sh and never touches a
# live rc, a live ~/.claude, or /root. Root-owned targets are simulated with a
# `sudo() { "$@"; }` shim on mktemp fixture files.
#
# ensure_core_rule (the always-loaded core link):
#   - links ~/.claude/rules/ops-core.md to CONTEXT/core.md; rerun is a no-op
#   - repoints a link aimed elsewhere; backs up a regular file in the way
#   - refuses a symlinked rules dir, and fails when core.md is missing
#
# strip_legacy_pair (the retired fleet's shell wiring):
#   - strips the PATH marker + export from a ~/.<shell>rc.local and the old
#     wrapper marker + source from a real rc, with the blank separator before
#     them, keeping everything else byte-exact
#   - is a no-op on a clean file and on rerun (idempotent)
#   - leaves near-miss operator lines alone (exact whole-line matches only)
#   - preserves the file mode, refuses a symlink, skips an absent file
#
# wire_wrapper_root:
#   - heals the fleet-era block (marker + absolute WORKFORCE-path source)
#   - heals the older $HOME-based source line
#   - replaces a source line pointing at a different checkout
#   - moves a mid-file block to the end; strips a stray legacy line even when
#     the current block is already present
#   - appends a block to an rc that has none
#   - is byte-identical on rerun (idempotent) and reports "already wired"
#   - preserves the rc's mode, refuses a symlinked rc, skips an absent rc
#
# ensure_claude_localrc (the ultracode-only claude() shim, version 2):
#   - replaces the retired boot shim (--append-system-prompt block) in place
#   - carries an operator's customized --settings JSON (BOOTSTRAP Round F)
#     from the old block into the new one
#   - leaves a current, tagged block alone even when its body was edited
#   - refuses old blocks with conflicting --settings JSON
#   - appends one block to a .local that has none; content after a mid-file
#     block survives, byte-exact
#   - is byte-identical on rerun and reports "already current"
#   - the written shim, sourced with a stub `claude` on PATH, adds
#     --settings '{"ultracode":true}' and does not double a caller's --settings
#   - a marker with no closing brace WARNs and leaves the file unchanged
#   - preserves the file mode, leaves no temp files
#
# Run:  bash ~/OPS/.claude-config/bin/tests/deploy-rc-wiring-test.sh
# Exit: 0 = all pass; non-zero on first failure.
set -uo pipefail

. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
DEPLOY="$(cd "$(dirname "$0")/../.." && pwd)/deploy.sh"
[ -f "$DEPLOY" ] || { echo "FAIL: deploy.sh missing at $DEPLOY" >&2; exit 1; }

TDIR="$(mktemp -d "${TMPDIR:-/tmp}/deploy-rc-wiring-test.XXXXXX")"
trap 'rm -rf "$TDIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# extract_fn <name>: print the function body from deploy.sh, from its
# `name() {` line through the first column-0 `}` OUTSIDE a quoted heredoc.
# ensure_claude_localrc writes its shim through `cat <<'SHIM'`, and that shim
# text ends its own claude() with a column-0 `}`; a terminator that ignored
# heredocs would cut the extraction there and eval half a function. The awk
# tracks the open heredoc tag (the word between the quotes after `<<`) and
# defers the `}` test until the tag line closes it. Fails loudly if absent so a
# rename in deploy.sh breaks this test instead of silently testing nothing.
extract_fn() {
  local body
  body="$(awk -v start="$1() {" -v q="'" '
    BEGIN { re = "<<" q "[A-Z_]+" q }
    $0 == start { p = 1 }
    p { print }
    p && hd != "" { if ($0 == hd) hd = ""; next }
    p && match($0, re) { hd = substr($0, RSTART + 3, RLENGTH - 4); next }
    p && $0 == "}" { exit }
  ' "$DEPLOY")"
  [ -n "$body" ] || fail "function $1 not found in $DEPLOY"
  printf '%s\n' "$body"
}
# extract_var <name>: print deploy.sh's column-0 assignment line for <name>.
extract_var() {
  local line
  line="$(grep -m1 "^$1=" "$DEPLOY")"
  [ -n "$line" ] || fail "assignment $1= not found in $DEPLOY"
  printf '%s\n' "$line"
}

# --- Harness: shims deploy.sh's helpers and sudo, loads the real code. ----
LOG="$TDIR/log"
msg_ok()     { echo "OK $*"   >> "$LOG"; }
msg_action() { echo "ACT $*"  >> "$LOG"; }
msg_warn()   { echo "WARN $*" >> "$LOG"; }
msg_bad()    { echo "BAD $*"  >> "$LOG"; }
sudo() { "$@"; }

# load <extractor> <name>: eval one extracted piece. The subshell's fail()
# only exits the subshell, so its status is checked here to stop the run.
load() { local code; code="$("$1" "$2")" || exit 1; eval "$code"; }

CONFIG_DIR="/srv/checkout/OPS/.claude-config"
OPS_ROOT="$TDIR/ops"
CLAUDE_HOME="$TDIR/home/.claude"
load extract_var CORE_SRC
load extract_var CORE_RULE_DIR
load extract_var CORE_RULE
load extract_fn ensure_core_rule
load extract_var LEGACY_FLEET_PATH_MARKER
load extract_var LEGACY_FLEET_PATH_EXPORT
load extract_var LEGACY_USER_WRAPPER_MARKER
load extract_var LEGACY_USER_WRAPPER_SOURCE
load extract_fn strip_legacy_pair
load extract_var WRAPPER_FILE
load extract_var WRAPPER_MARKER
load extract_var WRAPPER_SOURCE_RE
load extract_var WRAPPER_SOURCE_LINE
load extract_fn wire_wrapper_root
load extract_var ULTRACODE_MARKER
load extract_var ULTRACODE_SHIM_TAG
load extract_fn ensure_claude_localrc

# === ensure_core_rule =======================================================
[ "$CORE_RULE" = "$CLAUDE_HOME/rules/ops-core.md" ] \
  || fail "CORE_RULE is $CORE_RULE, want \$CLAUDE_HOME/rules/ops-core.md (verify-ops check 16 and DEPLOYMENT.md name that path)"
[ "$CORE_SRC" = "$OPS_ROOT/CONTEXT/core.md" ] || fail "CORE_SRC is $CORE_SRC, want \$OPS_ROOT/CONTEXT/core.md"

# --- Missing core: fails, creates nothing. -----------------------------------
: > "$LOG"
ensure_core_rule && fail "a missing core.md did not fail"
[ -e "$CORE_RULE" ] && fail "a missing core.md still produced a link"
grep -q '^BAD .*core.md missing' "$LOG" || fail "missing core.md was not reported: $(cat "$LOG")"
pass "fails without creating a link when CONTEXT/core.md is missing"

mkdir -p "$OPS_ROOT/CONTEXT"
printf '# Core\n' > "$CORE_SRC"

# --- Fresh: links, rerun is a no-op. ------------------------------------------
: > "$LOG"
ensure_core_rule || fail "fresh link failed: $(cat "$LOG")"
[ -L "$CORE_RULE" ] && [ "$(readlink -f "$CORE_RULE")" = "$(readlink -f "$CORE_SRC")" ] \
  || fail "fresh link does not resolve to core.md"
grep -q '^OK Linked core' "$LOG" || fail "fresh link not reported: $(cat "$LOG")"
: > "$LOG"
ensure_core_rule || fail "rerun failed"
grep -q '^OK Core already linked' "$LOG" || fail "rerun did not report already linked: $(cat "$LOG")"
pass "links ~/.claude/rules/ops-core.md to CONTEXT/core.md; rerun is a no-op"

# --- A link aimed elsewhere is repointed. ----------------------------------------
printf 'stale\n' > "$TDIR/elsewhere.md"
rm -f "$CORE_RULE"; ln -s "$TDIR/elsewhere.md" "$CORE_RULE"
: > "$LOG"
ensure_core_rule || fail "repoint failed"
[ "$(readlink -f "$CORE_RULE")" = "$(readlink -f "$CORE_SRC")" ] || fail "a link aimed elsewhere was not repointed"
grep -q '^ACT Repointing' "$LOG" || fail "repoint not reported: $(cat "$LOG")"
[ "$(cat "$TDIR/elsewhere.md")" = stale ] || fail "the old link target was modified"
pass "repoints a link aimed elsewhere without touching its old target"

# --- A regular file in the way is backed up, not deleted. ----------------------
rm -f "$CORE_RULE"; printf 'operator rule\n' > "$CORE_RULE"
: > "$LOG"
ensure_core_rule || fail "backup case failed"
[ -L "$CORE_RULE" ] || fail "regular file was not replaced by the link"
bk="$(ls "$CORE_RULE".backup_* 2>/dev/null | head -1)"
[ -n "$bk" ] && [ "$(cat "$bk")" = "operator rule" ] || fail "regular file was not backed up intact"
case "$bk" in *.md) fail "backup name ends in .md, so Claude Code would load it as a rule" ;; esac
pass "backs up a regular file in the way under a name Claude Code does not load"

# Two redeploys in one second must not overwrite the first operator backup.
date() { printf 'fixed-second\n'; }
for text in 'first operator rule' 'second operator rule'; do
  command rm -f "$CORE_RULE"
  printf '%s\n' "$text" > "$CORE_RULE"
  ensure_core_rule || fail 'repeated core rule backup failed'
done
unset -f date
for text in 'first operator rule' 'second operator rule'; do
  grep -qxF "$text" "$CORE_RULE".backup_* || fail "lost backup: $text"
done
pass "preserves distinct core-rule backups on rapid redeploys"

# Failure to unlink a stale rule must not turn ln into a write inside the old
# symlink target, which can be another checkout or an operator's directory.
command rm -f "$CORE_RULE"
mkdir -p "$TDIR/core-external"
ln -s "$TDIR/core-external" "$CORE_RULE"
rm() { return 1; }
ensure_core_rule && fail 'failed rule unlink reported successful linking'
unset -f rm
[ -z "$(ls -A "$TDIR/core-external")" ] || fail 'linking wrote through a stale rule symlink'
pass "failed unlink does not write through a stale rule symlink"

# --- A symlinked rules dir is refused, nothing written through it. -------------
rm -rf "$CORE_RULE_DIR"; mkdir -p "$TDIR/dotfiles-rules"
ln -s "$TDIR/dotfiles-rules" "$CORE_RULE_DIR"
: > "$LOG"
ensure_core_rule && fail "a symlinked rules dir was not refused"
[ -z "$(ls -A "$TDIR/dotfiles-rules")" ] || fail "wrote through a symlinked rules dir"
grep -q '^BAD .*is a symlink' "$LOG" || fail "symlinked rules dir refusal not reported: $(cat "$LOG")"
pass "refuses a symlinked rules dir"

# === strip_legacy_pair ======================================================
[ "$LEGACY_FLEET_PATH_MARKER" = '# --- OPS WORKFORCE/bin PATH (WS-3 localrc seam) ---' ] \
  || fail "LEGACY_FLEET_PATH_MARKER no longer matches what older deploys wrote"
[ "$LEGACY_FLEET_PATH_EXPORT" = 'export PATH="$HOME/OPS/WORKFORCE/bin:$PATH"' ] \
  || fail "LEGACY_FLEET_PATH_EXPORT no longer matches what older deploys wrote"
[ "$LEGACY_USER_WRAPPER_MARKER" = '# --- OPS Claude wrapper (root/user safety) ---' ] \
  || fail "LEGACY_USER_WRAPPER_MARKER no longer matches what older deploys wrote"
[ "$LEGACY_USER_WRAPPER_SOURCE" = 'source "$HOME/OPS/WORKFORCE/bin/claude-wrapper.sh" 2>/dev/null' ] \
  || fail "LEGACY_USER_WRAPPER_SOURCE no longer matches what older deploys wrote"

# The rest of a live ~/.zshrc.local: the legacy ultracode shim block.
LOCAL_REST='# --- Always-on ultracode for interactive Claude Code (WS-3) ---
claude() {
  command claude --settings '"'"'{"ultracode":true}'"'"' "$@"
}'

# --- Live-host shape of a .local: blank, marker, export, then the rest. -------
printf '\n%s\n%s\n\n%s\n' "$LEGACY_FLEET_PATH_MARKER" "$LEGACY_FLEET_PATH_EXPORT" "$LOCAL_REST" > "$TDIR/local1"
chmod 640 "$TDIR/local1"
printf '\n%s\n' "$LOCAL_REST" > "$TDIR/local-want"
: > "$LOG"
strip_legacy_pair "$TDIR/local1" "retired fleet PATH export" "$LEGACY_FLEET_PATH_MARKER" "$LEGACY_FLEET_PATH_EXPORT"
cmp -s "$TDIR/local1" "$TDIR/local-want" || { diff "$TDIR/local-want" "$TDIR/local1" >&2; fail "live-shape .local not stripped cleanly"; }
grep -q '^OK Removed retired fleet PATH export' "$LOG" || fail "strip not reported: $(cat "$LOG")"
[ "$(stat -c %a "$TDIR/local1")" = "640" ] || fail "strip did not preserve the file mode (got $(stat -c %a "$TDIR/local1"))"
pass "strips the live-host PATH block from a .local and preserves the mode"

: > "$LOG"
strip_legacy_pair "$TDIR/local1" "retired fleet PATH export" "$LEGACY_FLEET_PATH_MARKER" "$LEGACY_FLEET_PATH_EXPORT"
cmp -s "$TDIR/local1" "$TDIR/local-want" || fail "rerun changed a stripped .local (not idempotent)"
grep -q '^OK No retired fleet PATH export' "$LOG" || fail "rerun did not report a clean file: $(cat "$LOG")"
pass "rerun on a stripped file is a no-op"

# --- A real user rc carrying the old wrapper block. ---------------------------
BASE='# ~/.bashrc: executed by bash(1) for non-login shells.
export HISTSIZE=1000

#if [ -f /etc/bash_completion ] && ! shopt -oq posix; then
#    . /etc/bash_completion
#fi'
printf '%s\n\n%s\n%s\n' "$BASE" "$LEGACY_USER_WRAPPER_MARKER" "$LEGACY_USER_WRAPPER_SOURCE" > "$TDIR/userrc"
printf '%s\n' "$BASE" > "$TDIR/userrc-want"
: > "$LOG"
strip_legacy_pair "$TDIR/userrc" "retired fleet wrapper source" "$LEGACY_USER_WRAPPER_MARKER" "$LEGACY_USER_WRAPPER_SOURCE"
cmp -s "$TDIR/userrc" "$TDIR/userrc-want" || { diff "$TDIR/userrc-want" "$TDIR/userrc" >&2; fail "user rc wrapper block not stripped cleanly"; }
pass "strips the old wrapper marker and source from a real user rc"

# --- Near-miss operator lines survive a strip of the exact lines. ----------
NEAR='export PATH="$HOME/bin:$PATH"
# note: '"$LEGACY_FLEET_PATH_MARKER"'
  '"$LEGACY_FLEET_PATH_EXPORT"'
source "$HOME/OPS/WORKFORCE/bin/claude-wrapper.sh"'
printf '%s\n\n%s\n%s\n' "$NEAR" "$LEGACY_FLEET_PATH_MARKER" "$LEGACY_FLEET_PATH_EXPORT" > "$TDIR/local2"
printf '%s\n' "$NEAR" > "$TDIR/local2-want"
strip_legacy_pair "$TDIR/local2" "retired fleet PATH export" "$LEGACY_FLEET_PATH_MARKER" "$LEGACY_FLEET_PATH_EXPORT"
cmp -s "$TDIR/local2" "$TDIR/local2-want" || { diff "$TDIR/local2-want" "$TDIR/local2" >&2; fail "near-miss operator lines were modified"; }
pass "strips only exact legacy lines, leaving near-miss operator lines"

# --- Symlinked file: refused, link and target untouched. ------------------
printf '\n%s\n%s\n' "$LEGACY_FLEET_PATH_MARKER" "$LEGACY_FLEET_PATH_EXPORT" > "$TDIR/local-real"
cp "$TDIR/local-real" "$TDIR/local-real-orig"
ln -s "$TDIR/local-real" "$TDIR/local-link"
: > "$LOG"
strip_legacy_pair "$TDIR/local-link" "retired fleet PATH export" "$LEGACY_FLEET_PATH_MARKER" "$LEGACY_FLEET_PATH_EXPORT"
[ -L "$TDIR/local-link" ] || fail "symlinked .local was replaced by a regular file"
cmp -s "$TDIR/local-real" "$TDIR/local-real-orig" || fail "symlinked .local target was modified"
grep -q '^WARN .*symlink' "$LOG" || fail "symlinked .local refusal was not reported: $(cat "$LOG")"
pass "refuses a symlinked file and reports it"

# --- Absent file: skipped, nothing created, nothing reported. ----------------
: > "$LOG"
strip_legacy_pair "$TDIR/absent.local" "retired fleet PATH export" "$LEGACY_FLEET_PATH_MARKER" "$LEGACY_FLEET_PATH_EXPORT"
[ -e "$TDIR/absent.local" ] && fail "absent .local was created"
[ -s "$LOG" ] && fail "absent .local produced a report: $(cat "$LOG")"
pass "skips an absent file without creating it"

# === wire_wrapper_root ======================================================
[ "$WRAPPER_FILE" = "$CONFIG_DIR/bin/claude-root-wrapper.sh" ] \
  || fail "WRAPPER_FILE is $WRAPPER_FILE, want \$CONFIG_DIR/bin/claude-root-wrapper.sh"
[ "$WRAPPER_MARKER" = '# --- OPS Claude wrapper (root/user safety) ---' ] \
  || fail "WRAPPER_MARKER changed; live /root rcs key idempotency on the old string"

# The single correct block, as deploy.sh writes it after BASE.
want_rc() { printf '%s\n\n%s\n%s\n' "$BASE" "$WRAPPER_MARKER" "$WRAPPER_SOURCE_LINE"; }
want_rc > "$TDIR/want"

# check_heal <label> <fixture file>: wire, compare to the one-block result,
# wire again, require byte-identical output and an "already wired" report.
check_heal() {
  local label="$1" rc="$2"
  : > "$LOG"
  wire_wrapper_root "$rc"
  cmp -s "$rc" "$TDIR/want" || { diff "$TDIR/want" "$rc" >&2; fail "$label: healed rc differs from the one-block result"; }
  grep -q '^OK Wired wrapper' "$LOG" || fail "$label: first run did not report wiring: $(cat "$LOG")"
  cp "$rc" "$TDIR/first"
  : > "$LOG"
  wire_wrapper_root "$rc"
  cmp -s "$rc" "$TDIR/first" || fail "$label: rerun changed the rc (not idempotent)"
  grep -q '^OK Wrapper already wired' "$LOG" || fail "$label: rerun did not report already wired: $(cat "$LOG")"
  pass "$label"
}

# --- Fleet-era shape: marker + absolute WORKFORCE source (old printf form). --
printf '%s\n\n%s\n%s\n' "$BASE" "$WRAPPER_MARKER" \
  'source /home/op/OPS/WORKFORCE/bin/claude-wrapper.sh 2>/dev/null' > "$TDIR/rc1"
chmod 600 "$TDIR/rc1"
check_heal "heals the absolute fleet-era WORKFORCE source block" "$TDIR/rc1"
[ "$(stat -c %a "$TDIR/rc1")" = "600" ] || fail "rewrite did not preserve the rc mode (got $(stat -c %a "$TDIR/rc1"))"
pass "rewrite preserves the rc mode"

# --- Older shape: $HOME-based source (resolves to /root/OPS as root). --------
printf '%s\n\n%s\n%s\n' "$BASE" "$WRAPPER_MARKER" "$LEGACY_USER_WRAPPER_SOURCE" > "$TDIR/rc2"
check_heal "heals the \$HOME-based legacy source block" "$TDIR/rc2"

# --- Stale current-wrapper path from another checkout. ----------------------
printf '%s\n\n%s\n%s\n' "$BASE" "$WRAPPER_MARKER" \
  'source "/old/place/.claude-config/bin/claude-root-wrapper.sh" 2>/dev/null' > "$TDIR/rc3"
check_heal "replaces a claude-root-wrapper.sh source from another checkout" "$TDIR/rc3"

# --- No block at all, with and without a trailing blank line. ---------------
printf '%s\n' "$BASE" > "$TDIR/rc4"
check_heal "appends a block to an rc that has none" "$TDIR/rc4"
printf '%s\n\n' "$BASE" > "$TDIR/rc5"
check_heal "appends a block without doubling a trailing blank line" "$TDIR/rc5"

# --- Legacy block mid-file: moved to the end, its separator blank dropped. --
printf '%s\n\n%s\n%s\n\n%s\n' "$BASE" "$WRAPPER_MARKER" \
  'source /home/op/OPS/WORKFORCE/bin/claude-wrapper.sh 2>/dev/null' \
  'export FOO=1' > "$TDIR/rc6"
printf '%s\n\n%s\n\n%s\n%s\n' "$BASE" 'export FOO=1' "$WRAPPER_MARKER" "$WRAPPER_SOURCE_LINE" > "$TDIR/want6"
: > "$LOG"
wire_wrapper_root "$TDIR/rc6"
cmp -s "$TDIR/rc6" "$TDIR/want6" || { diff "$TDIR/want6" "$TDIR/rc6" >&2; fail "mid-file legacy block not moved cleanly"; }
pass "moves a mid-file legacy block to the end without stray blank lines"

# --- Filenames in operator content are not generated source lines. ----------
OPERATOR_LINES='# Keep a backup of WORKFORCE/bin/claude-wrapper.sh
export WRAPPER_NOTES="claude-root-wrapper.sh migration"
printf "%s\n" "WORKFORCE/bin/claude-wrapper.sh was retired"
source "/opt/custom/claude-root-wrapper.sh" 2>/dev/null
source /home/op/OPS/WORKFORCE/bin/claude-wrapper.sh 2>/dev/null; export KEEP_ME=1'
printf '%s\n\n%s\n%s\n' "$OPERATOR_LINES" "$WRAPPER_MARKER" \
  'source /home/op/OPS/WORKFORCE/bin/claude-wrapper.sh 2>/dev/null' > "$TDIR/operator-rc"
printf '%s\n\n%s\n%s\n' "$OPERATOR_LINES" "$WRAPPER_MARKER" "$WRAPPER_SOURCE_LINE" > "$TDIR/operator-want"
wire_wrapper_root "$TDIR/operator-rc"
cmp -s "$TDIR/operator-rc" "$TDIR/operator-want" \
  || { diff "$TDIR/operator-want" "$TDIR/operator-rc" >&2; fail "wrapper migration deleted operator content"; }
: > "$LOG"
wire_wrapper_root "$TDIR/operator-rc"
cmp -s "$TDIR/operator-rc" "$TDIR/operator-want" || fail "operator content changed on rerun"
grep -q '^OK Wrapper already wired' "$LOG" || fail "operator mentions forced another rewrite"
pass "preserves comments, variables, unrelated sources and compound commands mentioning the wrapper"

# --- A current block must not hide another generated wrapper source. --------
want_rc > "$TDIR/duplicate-rc"
printf '\n%s\n%s\n' "$WRAPPER_MARKER" \
  'source "/old/place/.claude-config/bin/claude-root-wrapper.sh" 2>/dev/null' >> "$TDIR/duplicate-rc"
check_heal "removes duplicate blocks even when a current block is present" "$TDIR/duplicate-rc"

# --- Current block present but a stray legacy line elsewhere: still heals. --
printf '%s\n%s\n\n%s\n%s\n' "$BASE" \
  'source /home/op/OPS/WORKFORCE/bin/claude-wrapper.sh 2>/dev/null' \
  "$WRAPPER_MARKER" "$WRAPPER_SOURCE_LINE" > "$TDIR/rc7"
check_heal "strips a stray legacy line even when the current block is present" "$TDIR/rc7"

# --- Symlinked rc: refused, link and its target untouched. ------------------
printf '%s\n' "$BASE" > "$TDIR/real"
ln -s "$TDIR/real" "$TDIR/link"
: > "$LOG"
wire_wrapper_root "$TDIR/link"
[ -L "$TDIR/link" ] || fail "symlinked rc was replaced by a regular file"
grep -qF "$WRAPPER_MARKER" "$TDIR/real" && fail "symlink target was modified"
grep -q '^WARN .*symlink' "$LOG" || fail "symlinked rc refusal was not reported: $(cat "$LOG")"
pass "refuses a symlinked rc and reports it"

# --- Absent rc: skipped, nothing created. -----------------------------------
wire_wrapper_root "$TDIR/absent"
[ -e "$TDIR/absent" ] && fail "absent rc was created"
pass "skips an absent rc without creating it"

# === ensure_claude_localrc ==================================================
[ "$ULTRACODE_MARKER" = '# --- Always-on ultracode for interactive Claude Code (WS-3) ---' ] \
  || fail "ULTRACODE_MARKER changed; live ~/.<shell>rc.local blocks key idempotency on the old string"
case "$ULTRACODE_SHIM_TAG" in
  '# ops-shim-version: '[0-9]*) ;;
  *) fail "ULTRACODE_SHIM_TAG must start with '# ops-shim-version: <n>' (got: $ULTRACODE_SHIM_TAG)" ;;
esac

# The retired boot shim exactly as earlier OPS deploys wrote it into
# ~/.<shell>rc.local: the marker, then this block. It appended the foreman
# charter and the boot digest through --append-system-prompt.
OLD_BOOT_SHIM="$ULTRACODE_MARKER
$(cat <<'OLDSHIM'
# `command claude` avoids recursion; clawd() calls `claude` so it inherits this.
# Flock-free on purpose (a per-config-dir flock would block concurrent
# same-profile sessions). Two launch-time jobs, both decided per invocation:
#   1. ultracode: added via --settings unless the caller already passed
#      --settings (ultracode is session-only, no settings.json key).
#   2. Boot surface: ride the whole foreman charter + identity boot-digest in
#      the CACHED system prompt via --append-system-prompt, and pin it for the
#      conversation with --system-prompt-snapshot on so it survives
#      resume/compact verbatim with no SessionStart hook re-forcing the reads.
#      Skipped if the caller already passed --append-system-prompt or
#      --system-prompt (no double inject). Fail open: a missing charter (box
#      mid-provision, partial clone) adds neither boot flag and the launch is
#      unaffected. OPS_BOOT_SHA is exported (first 8 hex of the sha1 of the
#      exact appended string) so session-briefing can print the booted version,
#      and only in the branches that actually append boot. Passing the same flag
#      twice keeps only the last, so the two files are concatenated into ONE
#      --append-system-prompt string.
claude() {
  local H boot sha have_sp have_settings
  H="$HOME/OPS"

  boot=""
  if [ -r "$H/CONTEXT/foreman-charter.md" ]; then
    boot="$(cat "$H/CONTEXT/foreman-charter.md"; printf '\n\n'; cat "$H/CONTEXT/boot-digest.md" 2>/dev/null)"
    sha="$(printf '%s' "$boot" | { sha1sum 2>/dev/null || shasum 2>/dev/null; } | cut -c1-8)"
  fi

  have_sp=0; have_settings=0
  case " $* " in
    *" --append-system-prompt "*|*" --append-system-prompt="*|*" --system-prompt "*|*" --system-prompt="*) have_sp=1 ;;
  esac
  case " $* " in
    *" --settings "*|*" --settings="*) have_settings=1 ;;
  esac

  if [ "$have_settings" -eq 0 ] && [ "$have_sp" -eq 0 ] && [ -n "$boot" ]; then
    [ -n "$sha" ] && export OPS_BOOT_SHA="$sha"
    command claude --settings '{"ultracode":true}' --append-system-prompt "$boot" --system-prompt-snapshot on "$@"
  elif [ "$have_settings" -eq 0 ]; then
    command claude --settings '{"ultracode":true}' "$@"
  elif [ "$have_sp" -eq 0 ] && [ -n "$boot" ]; then
    [ -n "$sha" ] && export OPS_BOOT_SHA="$sha"
    command claude --append-system-prompt "$boot" --system-prompt-snapshot on "$@"
  else
    command claude "$@"
  fi
}
OLDSHIM
)"

# shim_shape <file> [settings-json]: the structural facts every healed .local
# must satisfy; the JSON defaults to the stock ultracode settings.
shim_shape() {
  local rc="$1" json="${2:-{\"ultracode\":true\}}"
  [ "$(grep -cxF -- "$ULTRACODE_MARKER" "$rc")" = 1 ] || fail "$rc: expected exactly one marker line, got $(grep -cxF -- "$ULTRACODE_MARKER" "$rc")"
  [ "$(grep -cxF -- "$ULTRACODE_SHIM_TAG" "$rc")" = 1 ] || fail "$rc: expected exactly one version tag, got $(grep -cxF -- "$ULTRACODE_SHIM_TAG" "$rc")"
  [ "$(grep -c '^claude() {' "$rc")" = 1 ] || fail "$rc: expected exactly one claude() definition, got $(grep -c '^claude() {' "$rc")"
  grep -qF -- '--append-system-prompt' "$rc" && fail "$rc: the retired boot flag survived"
  grep -qF 'foreman-charter' "$rc" && fail "$rc: the retired charter path survived"
  grep -qF 'OPS_BOOT_SHA' "$rc" && fail "$rc: the retired boot sha export survived"
  grep -qF -- "--settings '$json'" "$rc" || fail "$rc: the --settings '$json' flag is missing"
}

# --- No block at all: one block appended, BASE untouched. -------------------
printf '%s\n' "$BASE" > "$TDIR/uc-none"
: > "$LOG"
ensure_claude_localrc "$TDIR/uc-none"
shim_shape "$TDIR/uc-none"
[ "$(head -n "$(printf '%s\n' "$BASE" | wc -l)" "$TDIR/uc-none")" = "$BASE" ] || fail "append changed the pre-existing rc content"
grep -q '^OK Wrote ultracode shim' "$LOG" || fail "append did not report the write: $(cat "$LOG")"
pass "appends one ultracode shim to a .local that has none"
# This append result is the one correct block; every heal below must equal it.
cp "$TDIR/uc-none" "$TDIR/uc-want"

# check_shim_heal <label> <fixture> <want>: heal, compare, rerun, require
# byte-identical output and an "already current" report.
check_shim_heal() {
  local label="$1" rc="$2" want="${3:-$TDIR/uc-want}"
  : > "$LOG"
  ensure_claude_localrc "$rc"
  cmp -s "$rc" "$want" || { diff "$want" "$rc" >&2; fail "$label: healed .local differs from the expected result"; }
  grep -q '^ACT Removed the old ultracode block' "$LOG" || fail "$label: strip was not reported: $(cat "$LOG")"
  grep -q '^OK Wrote ultracode shim' "$LOG" || fail "$label: rewrite was not reported: $(cat "$LOG")"
  cp "$rc" "$TDIR/uc-first"
  : > "$LOG"
  ensure_claude_localrc "$rc"
  cmp -s "$rc" "$TDIR/uc-first" || fail "$label: rerun changed the .local (not idempotent)"
  grep -q '^OK Ultracode shim already current' "$LOG" || fail "$label: rerun did not report already current: $(cat "$LOG")"
  pass "$label"
}

# --- Live-host shape: the retired boot shim under the marker. ---------------
printf '%s\n\n%s\n' "$BASE" "$OLD_BOOT_SHIM" > "$TDIR/uc-boot"
chmod 600 "$TDIR/uc-boot"
check_shim_heal "replaces the retired boot shim with the ultracode-only shim" "$TDIR/uc-boot"
[ "$(stat -c %a "$TDIR/uc-boot")" = "600" ] || fail "shim rewrite did not preserve the .local mode (got $(stat -c %a "$TDIR/uc-boot"))"
pass "shim rewrite preserves the .local mode"

# --- Older shape: the legacy ultracode-only block with no version tag. ------
printf '%s\n\n%s\n' "$BASE" "$LOCAL_REST" > "$TDIR/uc-legacy"
check_shim_heal "replaces the legacy untagged ultracode-only block" "$TDIR/uc-legacy"

# --- Round F on the old boot shim: the operator's settings JSON survives. ----
ROUNDF='{"ultracode":true,"permissions":{"defaultMode":"default"},"remoteControlAtStartup":false}'
printf '%s\n\n%s\n' "$BASE" "${OLD_BOOT_SHIM//\{\"ultracode\":true\}/$ROUNDF}" > "$TDIR/uc-roundf"
[ "$(grep -cF -- "--settings '$ROUNDF'" "$TDIR/uc-roundf")" = 2 ] || fail "fixture: Round F edit not applied to both launch lines"
sed "s|--settings '{\"ultracode\":true}'|--settings '$ROUNDF'|" "$TDIR/uc-want" > "$TDIR/uc-roundf-want"
check_shim_heal "carries a Round F --settings JSON from the old boot shim" "$TDIR/uc-roundf" "$TDIR/uc-roundf-want"
shim_shape "$TDIR/uc-roundf" "$ROUNDF"

# --- A current, tagged block edited per Round F is left alone. --------------
cp "$TDIR/uc-roundf-want" "$TDIR/uc-edited"
: > "$LOG"
ensure_claude_localrc "$TDIR/uc-edited"
cmp -s "$TDIR/uc-edited" "$TDIR/uc-roundf-want" || fail "a re-deploy rewrote a current shim the operator edited"
grep -q '^OK Ultracode shim already current' "$LOG" || fail "edited current shim not reported as current: $(cat "$LOG")"
pass "leaves a current, tagged shim alone even when its body was edited"

# --- Old blocks with two different custom JSONs: refused, file unchanged. ---
printf '%s\n\n%s\n\n%s\n' "$BASE" "${OLD_BOOT_SHIM//\{\"ultracode\":true\}/\{\"ultracode\":true,\"x\":1\}}" \
  "${LOCAL_REST//\{\"ultracode\":true\}/\{\"ultracode\":true,\"y\":2\}}" > "$TDIR/uc-conflict"
cp "$TDIR/uc-conflict" "$TDIR/uc-conflict-orig"
: > "$LOG"
ensure_claude_localrc "$TDIR/uc-conflict" && fail "conflicting custom settings were not refused"
cmp -s "$TDIR/uc-conflict" "$TDIR/uc-conflict-orig" || fail "a refused heal changed the file"
grep -q '^WARN ' "$LOG" || fail "conflicting custom settings refusal not reported: $(cat "$LOG")"
pass "refuses old blocks with conflicting --settings JSON and leaves the file unchanged"

# A valid shell-quoted apostrophe cannot be captured by the migration's simple
# single-quoted JSON matcher. Refuse that form rather than truncate the value.
printf '%s\n' "$OLD_BOOT_SHIM" > "$TDIR/uc-apostrophe"
python3 - "$TDIR/uc-apostrophe" <<'PYTEST'
from pathlib import Path
import sys
p = Path(sys.argv[1])
quoted = "'" + '{"ultracode":true,"env":{"LABEL":"it' + "'\\''" + 's"}}' + "'"
p.write_text(p.read_text().replace("'{\"ultracode\":true}'", quoted))
PYTEST
bash -n "$TDIR/uc-apostrophe" || fail 'apostrophe fixture is not valid shell'
cp "$TDIR/uc-apostrophe" "$TDIR/uc-apostrophe-before"
ensure_claude_localrc "$TDIR/uc-apostrophe" && fail 'partially captured settings JSON was migrated'
cmp -s "$TDIR/uc-apostrophe" "$TDIR/uc-apostrophe-before" || fail 'truncated a shell-escaped settings value'
pass "refuses settings shell quoting it cannot preserve, without changing the file"

for variant in file double; do
  printf '%s\n' "$OLD_BOOT_SHIM" > "$TDIR/uc-unsupported"
  python3 - "$TDIR/uc-unsupported" "$variant" <<'PYTEST'
from pathlib import Path
import sys
p = Path(sys.argv[1])
value = '{"permissions":{"defaultMode":"default"}}'
replacement = ('--settings "$HOME/settings.json"' if sys.argv[2] == 'file'
               else '--settings "' + value.replace('"', '\\"') + '"')
p.write_text(p.read_text().replace("--settings '{\"ultracode\":true}'", replacement))
PYTEST
  bash -n "$TDIR/uc-unsupported" || fail 'custom settings fixture is not valid shell'
  cp "$TDIR/uc-unsupported" "$TDIR/uc-unsupported-before"
  ensure_claude_localrc "$TDIR/uc-unsupported" && fail "silently reset $variant settings argument"
  cmp -s "$TDIR/uc-unsupported" "$TDIR/uc-unsupported-before" || fail "changed $variant settings argument"
done
pass "refuses unsupported settings argument forms without resetting operator choices"

# --- Old block mid-file: content after it survives, new block lands last. ---
printf '%s\n\n%s\n\nexport FOO=1\n' "$BASE" "$OLD_BOOT_SHIM" > "$TDIR/uc-mid"
: > "$LOG"
ensure_claude_localrc "$TDIR/uc-mid"
shim_shape "$TDIR/uc-mid"
grep -qx 'export FOO=1' "$TDIR/uc-mid" || fail "content after a mid-file boot shim was lost"
[ "$(grep -n 'export FOO=1' "$TDIR/uc-mid" | cut -d: -f1)" -lt "$(grep -nxF -- "$ULTRACODE_MARKER" "$TDIR/uc-mid" | cut -d: -f1)" ] \
  || fail "the new block did not land after the surviving content"
pass "strips a mid-file boot shim without losing the content after it"

# --- Rerun on the fresh result stays byte-identical. ------------------------
cp "$TDIR/uc-want" "$TDIR/uc-rerun"
: > "$LOG"
ensure_claude_localrc "$TDIR/uc-rerun"
cmp -s "$TDIR/uc-rerun" "$TDIR/uc-want" || fail "rerun on a current shim changed the file"
grep -q '^OK Ultracode shim already current' "$LOG" || fail "rerun did not report already current: $(cat "$LOG")"
pass "rerun on a current shim is a byte-identical no-op"

# --- Behavior: source the written shim with a stub claude on PATH. ----------
STUBBIN="$TDIR/stubbin"; mkdir -p "$STUBBIN"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$STUBBIN/claude"
chmod +x "$STUBBIN/claude"
# run_shim <args...>: `claude <args>` through the written function; prints the
# argv the stub binary received, one per line.
run_shim() { PATH="$STUBBIN:$PATH" bash -c 'source "$1"; shift; claude "$@"' _ "$TDIR/uc-want" "$@"; }
out="$(run_shim -p hi)"
[ "$out" = "$(printf -- '--settings\n{"ultracode":true}\n-p\nhi')" ] \
  || fail "plain launch did not prepend the ultracode --settings (argv: $(printf '%s' "$out" | tr '\n' ' '))"
pass "shim adds --settings '{\"ultracode\":true}' to a plain launch"
out="$(run_shim --settings '{"x":1}' -p hi)"
[ "$out" = "$(printf -- '--settings\n{"x":1}\n-p\nhi')" ] \
  || fail "a caller's --settings was doubled or altered (argv: $(printf '%s' "$out" | tr '\n' ' '))"
out="$(run_shim --settings='{"x":1}')"
[ "$out" = '--settings={"x":1}' ] \
  || fail "a caller's --settings=<json> was doubled or altered (argv: $(printf '%s' "$out" | tr '\n' ' '))"
pass "shim leaves a caller's --settings / --settings= alone (no double ultracode)"
out="$(run_shim -p hi)"
case "$out" in *append-system-prompt*) fail "the shim still appends a system prompt" ;; esac
pass "shim appends no system prompt (the core loads through ~/.claude/rules)"

# --- Corrupt block: marker with no closing brace WARNs, file untouched. -----
printf '%s\n\n%s\nclaude() {\n  command claude "$@"\n' "$BASE" "$ULTRACODE_MARKER" > "$TDIR/uc-corrupt"
cp "$TDIR/uc-corrupt" "$TDIR/uc-corrupt-orig"
: > "$LOG"
ensure_claude_localrc "$TDIR/uc-corrupt"
cmp -s "$TDIR/uc-corrupt" "$TDIR/uc-corrupt-orig" || { diff "$TDIR/uc-corrupt-orig" "$TDIR/uc-corrupt" >&2; fail "a marker with no closing brace changed the file (truncation risk)"; }
grep -q '^WARN .*no closing brace' "$LOG" || fail "corrupt block was not reported as a WARN: $(cat "$LOG")"
grep -q '^OK Wrote' "$LOG" && fail "corrupt block still got a new shim appended (two claude() risk)"
pass "a marker with no closing brace WARNs and leaves the .local unchanged"

# A later user function must never supply the missing generated closing brace.
for body in 'claude() {
  command claude "$@"
user_function() {
  echo keep
}' 'user_function() {
  echo keep
}'; do
  printf '%s\n%s\n' "$ULTRACODE_MARKER" "$body" > "$TDIR/uc-user"
  cp "$TDIR/uc-user" "$TDIR/uc-user-before"
  ensure_claude_localrc "$TDIR/uc-user"
  cmp -s "$TDIR/uc-user" "$TDIR/uc-user-before" || fail "deleted a user function following an incomplete marker block"
done
pass "refuses ambiguous blocks before a user function"

# A current tag elsewhere must not hide a second stale generated definition.
cat "$TDIR/uc-want" > "$TDIR/uc-duplicate"
printf '\n%s\n' "$LOCAL_REST" >> "$TDIR/uc-duplicate"
ensure_claude_localrc "$TDIR/uc-duplicate"
shim_shape "$TDIR/uc-duplicate"
pass "heals duplicate managed definitions even with a current tag"

# CRLF marker matching must not append a second definition; unrelated bytes stay.
printf 'export KEEP=1\r\n\r\n' > "$TDIR/uc-crlf"
printf '%s\n' "$LOCAL_REST" | sed 's/$/\r/' >> "$TDIR/uc-crlf"
ensure_claude_localrc "$TDIR/uc-crlf"
shim_shape "$TDIR/uc-crlf"
python3 - "$TDIR/uc-crlf" <<'PYTEST'
import sys
assert open(sys.argv[1], 'rb').read().startswith(b'export KEEP=1\r\n')
PYTEST
pass "heals CRLF managed block without normalizing user content"

# No trailing newline after surviving content: preserve its bytes on heal.
printf '%s\n\nexport KEEP=1' "$LOCAL_REST" > "$TDIR/uc-no-newline"
ensure_claude_localrc "$TDIR/uc-no-newline"
python3 - "$TDIR/uc-no-newline" <<'PYTEST'
import sys
assert open(sys.argv[1], 'rb').read().startswith(b'\nexport KEEP=1\n# --- Always-on')
PYTEST
cp "$TDIR/uc-no-newline" "$TDIR/uc-first"
ensure_claude_localrc "$TDIR/uc-no-newline"
cmp -s "$TDIR/uc-first" "$TDIR/uc-no-newline" || fail "no-newline input not idempotent"
pass "preserves unterminated user content and is byte-identical on rerun"

printf '%s\n' "$BASE" > "$TDIR/uc-link-target"
ln -s "$TDIR/uc-link-target" "$TDIR/uc-link"
ensure_claude_localrc "$TDIR/uc-link"
[ -L "$TDIR/uc-link" ] && ! grep -qF "$ULTRACODE_MARKER" "$TDIR/uc-link-target" || fail "modified symlinked rc"
pass "refuses symlinked localrc"

# --- No temp files left beside the rcs. -------------------------------------
leftover="$(find "$TDIR" -name '*.wrapper.*' -o -name '*.legacy.*' -o -name '*.ultracode.*' | head -1)"
[ -z "$leftover" ] || fail "temp file left behind: $leftover"
pass "leaves no temp files behind"

echo "ALL PASS"
