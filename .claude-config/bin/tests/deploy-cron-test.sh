#!/usr/bin/env bash
# deploy-cron-test.sh: deploy.sh schedules the nightly backup only when the OPS
# repo has an `origin` remote.
#
# A copy with no remote is a supported setup (OPS works without GitHub). There
# the backup's OPS stage logs "'origin' does not appear to be a git repository"
# on every run and the session briefing reports a failed backup in every
# session, so deploy must not schedule the job. daily-sync.sh is unchanged: a
# copy that has a remote and cannot push still logs and reports loudly (that is
# daily-sync-test.sh's ground).
#
# This runs the real cron block sliced out of deploy.sh, against a fake
# `crontab` kept in a file and throwaway git repos as the OPS root, and asserts:
#   - origin present: the cron line is installed once, exactly as before, and a
#     second run installs nothing more
#   - no origin (a fresh `git init`, a remote under another name, a directory
#     that is not a repository): nothing is written to the crontab, the one
#     "No git remote" line is printed, and the deploy does not count it a failure
#   - an existing cron line is left alone, with and without an origin: the
#     crontab is byte-identical and written zero times; without an origin the
#     deploy says so and names the fix, and still removes nothing
#   - other crontab entries survive a run in every case
#   - --no-system touches no crontab either way
#
# Writes only inside its own mktemp directory. It slices deploy.sh, so like the
# other deploy suites it starts with the sandbox guard (verify-ops check 24) and
# runs inside sandbox-run:
#   ~/OPS/.claude-config/bin/sandbox-run --no-bind --no-net --ro-bind ~/OPS -- \
#     bash ~/OPS/.claude-config/bin/tests/deploy-cron-test.sh
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97

CFG="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY="$CFG/deploy.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/deploy-cron-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; [ -f "${OUT:-}" ] && sed 's/^/  deploy said: /' "$OUT" >&2; exit 1; }
pass() { echo "PASS: $*"; }

export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$HOME" "$WORK/bin"

# A per-user crontab kept in $CRONTAB_FILE; every write is counted.
cat > "$WORK/bin/crontab" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -l) [ -f "$CRONTAB_FILE" ] || { echo "no crontab for test" >&2; exit 1; }; cat "$CRONTAB_FILE" ;;
  -)  cat > "$CRONTAB_FILE.new" && mv "$CRONTAB_FILE.new" "$CRONTAB_FILE" && echo write >> "$CRONTAB_FILE.writes" ;;
  *)  echo "fake crontab: unexpected arguments: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$WORK/bin/crontab"

BLOCK="$(awk '/^# --- Daily backup cron job ---/ {p=1} p && /^# --- Claude Code plugins/ {exit} p {print}' "$DEPLOY")"
printf '%s\n' "$BLOCK" | grep -q 'crontab' && printf '%s\n' "$BLOCK" | grep -q 'CRON_LINE' \
  || fail "the cron block was not found in deploy.sh (its start or end marker moved)"

# A throwaway OPS root: a git repo with the backup script in place. $2 names a
# remote to add (the URL is never contacted); none adds no remote.
mk_repo() {
  git init -q "$1" || fail "git init $1"
  mkdir -p "$1/.claude-config/backup"
  printf '#!/usr/bin/env bash\n' > "$1/.claude-config/backup/daily-sync.sh"
  [ -z "${2:-}" ] || git -C "$1" remote add "$2" git@example.invalid:acme/ops-copy.git
}

N=0
# run_block <ops-root> [no-system]: the cron block, with deploy's message
# helpers replaced by recorders. Output lands in $OUT; the block's failure
# list on its last line.
run_block() {
  N=$((N + 1)); OUT="$WORK/out.$N"
  (
    msg_ok() { echo "OK $*"; }
    msg_warn() { echo "WARN $*"; }
    msg_bad() { echo "BAD $*"; }
    c_yel() { :; }
    OPS_ROOT="$1"; CONFIG_DIR="$1/.claude-config"; NO_SYSTEM="${2:-0}"; DEPLOY_FAILED=''
    PATH="$WORK/bin:$PATH"
    eval "$BLOCK"
    echo "DEPLOY_FAILED=[$DEPLOY_FAILED]"
  ) > "$OUT" 2>&1
}

new_crontab() { export CRONTAB_FILE="$WORK/crontab.$1"; rm -f "$CRONTAB_FILE" "$CRONTAB_FILE.writes"; }
cron_count() { grep -cF '# OPS Daily Backup' "$CRONTAB_FILE" 2>/dev/null || true; }
cron_writes() { if [ -f "$CRONTAB_FILE.writes" ]; then wc -l < "$CRONTAB_FILE.writes" | tr -d ' '; else echo 0; fi; }
NOREMOTE_MSG='No git remote: the nightly backup is not scheduled. Add a GitHub remote (DEPLOYMENT.md), then rerun deploy.'

# --- 1. origin present: scheduled as before ----------------------------------
mk_repo "$WORK/with-origin" origin
new_crontab 1
run_block "$WORK/with-origin"
[ "$(cron_count)" = 1 ] || fail "with an origin, the cron line was not installed exactly once ($(cron_count))"
[ "$(grep -F '# OPS Daily Backup' "$CRONTAB_FILE")" = "0 9 * * * $WORK/with-origin/.claude-config/backup/daily-sync.sh # OPS Daily Backup" ] \
  || fail "the installed cron line changed shape: $(cat "$CRONTAB_FILE")"
grep -q '^OK Cron job installed' "$OUT" || fail "no 'installed' message with an origin"
grep -q '^DEPLOY_FAILED=\[\]$' "$OUT" || fail "a clean install counted as a failed deploy"
! grep -q 'No git remote' "$OUT" || fail "the no-remote line was printed with an origin"
run_block "$WORK/with-origin"
[ "$(cron_count)" = 1 ] && [ "$(cron_writes)" = 1 ] || fail "a second run installed another line (lines $(cron_count), writes $(cron_writes))"
grep -q '^OK Cron job already installed' "$OUT" || fail "no 'already installed' message on the second run"
pass "origin present: the cron line is installed once as before, and a rerun adds nothing"

# --- 2. no origin: nothing scheduled, one clear line --------------------------
mk_repo "$WORK/bare-init"
new_crontab 2
run_block "$WORK/bare-init"
[ ! -e "$CRONTAB_FILE" ] && [ "$(cron_writes)" = 0 ] || fail "with no origin, the crontab was written"
[ "$(grep -c '^WARN No git remote' "$OUT")" = 1 ] && grep -qxF "WARN $NOREMOTE_MSG" "$OUT" || fail "the no-remote line is missing, duplicated or reworded"
grep -q '^DEPLOY_FAILED=\[\]$' "$OUT" || fail "a copy with no remote counted as a failed deploy"
! grep -q '^BAD' "$OUT" || fail "a copy with no remote printed a failure line"
pass "no origin: nothing is scheduled, the one no-remote line is printed, and deploy still passes"

# Other crontab entries survive, byte for byte, with no write.
new_crontab 2b
printf '30 2 * * * /usr/local/bin/other-job\n' > "$CRONTAB_FILE"
cp "$CRONTAB_FILE" "$WORK/before"
run_block "$WORK/bare-init"
cmp -s "$CRONTAB_FILE" "$WORK/before" && [ "$(cron_writes)" = 0 ] || fail "no-origin deploy changed an unrelated crontab"
pass "no origin: unrelated crontab entries are untouched"

# A remote under another name is not an origin: daily-sync.sh pushes origin.
mk_repo "$WORK/other-remote" upstream
new_crontab 2c
run_block "$WORK/other-remote"
[ ! -e "$CRONTAB_FILE" ] && grep -q '^WARN No git remote' "$OUT" || fail "a remote named upstream was treated as an origin"
pass "no origin: a remote under another name does not count"

# Not a repository at all (a tarball copy): no origin either, and no crash.
mkdir -p "$WORK/not-a-repo/.claude-config/backup"
printf '#!/usr/bin/env bash\n' > "$WORK/not-a-repo/.claude-config/backup/daily-sync.sh"
new_crontab 2d
run_block "$WORK/not-a-repo"
[ ! -e "$CRONTAB_FILE" ] && grep -q '^WARN No git remote' "$OUT" && grep -q '^DEPLOY_FAILED=\[\]$' "$OUT" \
  || fail "a directory that is not a repository was scheduled or failed the deploy"
pass "no origin: a directory that is not a git repository is handled the same way"

# --- 3. an existing cron line is left alone ------------------------------------
EXISTING="0 9 * * * $WORK/with-origin/.claude-config/backup/daily-sync.sh # OPS Daily Backup"
for case in with-origin bare-init; do
  new_crontab "3-$case"
  printf '30 2 * * * /usr/local/bin/other-job\n%s\n' "$EXISTING" > "$CRONTAB_FILE"
  cp "$CRONTAB_FILE" "$WORK/before"
  run_block "$WORK/$case"
  cmp -s "$CRONTAB_FILE" "$WORK/before" || fail "an existing cron line was changed ($case)"
  [ "$(cron_writes)" = 0 ] || fail "an existing cron line was rewritten ($case)"
  [ "$(cron_count)" = 1 ] || fail "an existing cron line was removed or duplicated ($case)"
  grep -q '^DEPLOY_FAILED=\[\]$' "$OUT" || fail "an existing cron line failed the deploy ($case)"
  if [ "$case" = with-origin ]; then
    grep -q '^OK Cron job already installed' "$OUT" || fail "no 'already installed' message with an origin"
  else
    grep -q '^WARN Cron job already installed, but this copy has no git remote' "$OUT" && grep -q 'crontab -e' "$OUT" \
      || fail "an existing line with no origin did not say so and name the fix"
    ! grep -q 'No git remote: the nightly backup is not scheduled' "$OUT" || fail "claimed 'not scheduled' while a line exists"
  fi
done
pass "an existing cron line is left alone with and without an origin (no write, nothing removed); without one the deploy names the fix"

# --- 4. --no-system touches no crontab, with or without an origin --------------
for case in with-origin bare-init; do
  new_crontab "4-$case"
  run_block "$WORK/$case" 1
  [ ! -e "$CRONTAB_FILE" ] && grep -q '^WARN --no-system: crontab not touched' "$OUT" || fail "--no-system touched the crontab ($case)"
done
pass "--no-system leaves the crontab alone either way"
