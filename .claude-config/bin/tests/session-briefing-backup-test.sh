#!/usr/bin/env bash
# session-briefing-backup-test.sh: the boot briefing reports a nightly backup
# that did not finish clean.
#
# daily-sync.sh exits 0 whatever its OPS stage did, so its log is the only
# record of a skipped push or a failed stage. The briefing must:
#   - print a Backup line naming the last run's OPS-stage ERROR and WARN lines,
#     continuation lines included, so the reason and the fix reach the session
#   - read only the LAST run: an earlier run's problem that a later clean run
#     resolved stays quiet
#   - stay quiet on a clean run and when there is no log at all
# HOME and the OPS copy are fixtures in this test's own temp dir.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/briefing-backup.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" OPS_DIR="$WORK/home/OPS"
unset CLAUDE_CONFIG_DIR
mkdir -p "$OPS_DIR/CONTEXT" "$OPS_DIR/.claude-config/backup" "$HOME/.claude"
printf '# Core\n' > "$OPS_DIR/CONTEXT/core.md"
LOG="$OPS_DIR/.claude-config/backup/sync.log"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
briefing() { bash "$ROOT/.claude-config/hooks/session-briefing.sh" </dev/null; }
run_block() { # TS LINE...: one daily-sync run in the log's format
  local ts="$1"; shift
  printf '[%s] ===== daily-sync start =====\n' "$ts"
  local l; for l in "$@"; do printf '[%s] %s\n' "$ts" "$l"; done
  printf '[%s] PROJECTS: running sync-check.sh --auto\n[%s] ===== daily-sync complete =====\n' "$ts" "$ts"
}

out="$(briefing)"
case "$out" in *"Backup:"*) bad "no log: printed a Backup line" ;; *) ok "no log: quiet" ;; esac

run_block "2026-10-18 09:00:01" "OPS: backup pushed successfully (origin-private-check: private: github.com/acme/ops is private)" > "$LOG"
out="$(briefing)"
case "$out" in *"Backup:"*) bad "clean run: printed a Backup line" ;; *) ok "clean run: quiet" ;; esac

{ run_block "2026-10-17 09:00:01" "OPS: ERROR pull --rebase failed; nothing pushed: fatal: unreachable"
  run_block "2026-10-18 09:00:01" "OPS: backup pushed successfully (origin-private-check: private: github.com/acme/ops is private)"; } > "$LOG"
out="$(briefing)"
case "$out" in *"Backup:"*) bad "an earlier failure fixed by a later clean run still reported" ;; *) ok "only the last run counts" ;; esac

run_block "2026-10-19 09:00:02" \
  "OPS: WARN push skipped, commit kept locally: origin-private-check: unverified: gh could not read github.com/acme/ops; confirm the repo is private, then run: git -C \"/x/OPS\" config ops.pushVerified true" >> "$LOG"
out="$(briefing)"
grep -q '^ Backup:  the nightly backup at 2026-10-19 09:00 did not finish clean: WARN push skipped, commit kept locally: origin-private-check: unverified: gh could not read github.com/acme/ops; confirm the repo is private, then run: git -C "/x/OPS" config ops.pushVerified true (full log: ~/OPS/.claude-config/backup/sync.log)$' <<< "$out" \
  && ok "skipped push: reason and fix reported" || bad "skipped push: $(grep Backup <<< "$out")"

run_block "2026-10-20 09:00:03" \
  "OPS: ERROR commit failed; changes left staged, nothing pushed: Author identity unknown" \
  "     no git identity: run git config --global user.name \"Your Name\" and git config --global user.email <your-email>" \
  "OPS: WARN could not restore the mode of note.md (was 600)" >> "$LOG"
out="$(briefing)"
line="$(grep '^ Backup:' <<< "$out")"
case "$line" in
  *"2026-10-20 09:00"*"ERROR commit failed; changes left staged, nothing pushed: Author identity unknown; no git identity: run git config --global user.name"*" / WARN could not restore the mode of note.md (was 600)"*)
    ok "failed stage: every ERROR and WARN of the last run, continuation included" ;;
  *) bad "failed stage: $line" ;;
esac
case "$line" in *"push skipped"*) bad "failed stage: an older run's line leaked in" ;; *) ok "failed stage: no older run's line" ;; esac

echo "session-briefing-backup-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
