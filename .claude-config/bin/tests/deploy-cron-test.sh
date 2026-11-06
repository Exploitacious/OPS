#!/usr/bin/env bash
# deploy-cron-test.sh: deploy.sh schedules the nightly backup on every copy,
# with or without an `origin` remote.
#
# A copy with no remote is a supported setup (OPS works without GitHub). An
# earlier deploy did not schedule the job there, so such a copy also lost the
# job's nightly project pull and branch-gc. Now daily-sync.sh is the one place
# that decides what a copy with no origin does (it commits locally and logs one
# INFO line; daily-sync-test.sh covers that), and deploy does not look at the
# remotes at all.
#
# This runs the real cron block sliced out of deploy.sh, against a fake
# `crontab` kept in a file and throwaway git repos as the OPS root, and asserts:
#   - origin present: the cron line is installed once, exactly as before, and a
#     second run installs nothing more
#   - no origin (a fresh `git init`, a remote under another name, a directory
#     that is not a repository): the same line is installed once, nothing says
#     "No git remote", and a rerun adds nothing
#   - the cron block never runs git: the remotes are not deploy's decision
#   - an existing cron line is left alone, with and without an origin: the
#     crontab is byte-identical and written zero times, and no warning is printed
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
# git, on the block's PATH only, records every call: the block must make none.
REAL_GIT="$(command -v git)"
cat > "$WORK/bin/git" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/git-calls"
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$WORK/bin/crontab" "$WORK/bin/git"

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
cron_line() { echo "0 9 * * * $1/.claude-config/backup/daily-sync.sh # OPS Daily Backup"; }

# installs_once <ops-root> <label>: one run installs exactly the cron line,
# with no remote check and no warning; a second run adds nothing.
installs_once() {
  rm -f "$WORK/git-calls"
  run_block "$1"
  [ "$(cron_count)" = 1 ] || fail "$2: the cron line was not installed exactly once ($(cron_count))"
  [ "$(grep -F '# OPS Daily Backup' "$CRONTAB_FILE")" = "$(cron_line "$1")" ] \
    || fail "$2: the installed cron line changed shape: $(cat "$CRONTAB_FILE")"
  grep -q '^OK Cron job installed' "$OUT" || fail "$2: no 'installed' message"
  grep -q '^DEPLOY_FAILED=\[\]$' "$OUT" || fail "$2: a clean install counted as a failed deploy"
  ! grep -q -e '^WARN' -e '^BAD' -e 'No git remote' "$OUT" || fail "$2: printed a warning or a failure"
  [ ! -s "$WORK/git-calls" ] || fail "$2: the cron block ran git: $(cat "$WORK/git-calls")"
  run_block "$1"
  [ "$(cron_count)" = 1 ] && [ "$(cron_writes)" = 1 ] || fail "$2: a second run installed another line (lines $(cron_count), writes $(cron_writes))"
  grep -q '^OK Cron job already installed' "$OUT" || fail "$2: no 'already installed' message on the second run"
}

# --- 1. origin present: scheduled as before ----------------------------------
mk_repo "$WORK/with-origin" origin
new_crontab 1
installs_once "$WORK/with-origin" "origin present"
pass "origin present: the cron line is installed once as before, and a rerun adds nothing"

# --- 2. no origin: scheduled the same way ---------------------------------------
mk_repo "$WORK/bare-init"
new_crontab 2
installs_once "$WORK/bare-init" "no origin"
pass "no origin: the cron line is installed once, with no warning, and a rerun adds nothing"

# Other crontab entries survive, byte for byte, ahead of the new line.
new_crontab 2b
printf '30 2 * * * /usr/local/bin/other-job\n' > "$CRONTAB_FILE"
cp "$CRONTAB_FILE" "$WORK/before"
run_block "$WORK/bare-init"
[ "$(head -n 1 "$CRONTAB_FILE")" = "$(cat "$WORK/before")" ] && [ "$(cron_count)" = 1 ] && [ "$(wc -l < "$CRONTAB_FILE")" = 2 ] \
  || fail "no-origin deploy lost or changed an unrelated crontab entry: $(cat "$CRONTAB_FILE")"
pass "no origin: unrelated crontab entries are kept and the line is added once"

# A remote under another name, or no repository at all (a tarball copy): the
# same. What the job does there is daily-sync.sh's to decide, not deploy's (on
# a directory that is not a repository its OPS stage logs an ERROR each night).
mk_repo "$WORK/other-remote" upstream
new_crontab 2c
installs_once "$WORK/other-remote" "remote named upstream"
pass "no origin: a remote under another name is scheduled the same way"
mkdir -p "$WORK/not-a-repo/.claude-config/backup"
printf '#!/usr/bin/env bash\n' > "$WORK/not-a-repo/.claude-config/backup/daily-sync.sh"
new_crontab 2d
installs_once "$WORK/not-a-repo" "not a repository"
pass "no origin: a directory that is not a git repository is scheduled the same way"

# --- 3. an existing cron line is left alone ------------------------------------
EXISTING="$(cron_line "$WORK/with-origin")"
for case in with-origin bare-init; do
  new_crontab "3-$case"
  printf '30 2 * * * /usr/local/bin/other-job\n%s\n' "$EXISTING" > "$CRONTAB_FILE"
  cp "$CRONTAB_FILE" "$WORK/before"
  run_block "$WORK/$case"
  cmp -s "$CRONTAB_FILE" "$WORK/before" || fail "an existing cron line was changed ($case)"
  [ "$(cron_writes)" = 0 ] || fail "an existing cron line was rewritten ($case)"
  [ "$(cron_count)" = 1 ] || fail "an existing cron line was removed or duplicated ($case)"
  grep -q '^DEPLOY_FAILED=\[\]$' "$OUT" || fail "an existing cron line failed the deploy ($case)"
  grep -q '^OK Cron job already installed\.$' "$OUT" || fail "no 'already installed' message ($case)"
  ! grep -q -e '^WARN' -e 'no git remote' "$OUT" || fail "an existing cron line drew a warning ($case)"
done
pass "an existing cron line is left alone with and without an origin (no write, nothing removed, no warning)"

# --- 4. --no-system touches no crontab, with or without an origin --------------
for case in with-origin bare-init; do
  new_crontab "4-$case"
  run_block "$WORK/$case" 1
  [ ! -e "$CRONTAB_FILE" ] && grep -q '^WARN --no-system: crontab not touched' "$OUT" || fail "--no-system touched the crontab ($case)"
done
pass "--no-system leaves the crontab alone either way"
