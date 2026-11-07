#!/usr/bin/env bash
# memory-init-hostkey-test.sh: behavior tests for bin/memory-init's host key, for
# the per-machine memory-host file that every pool reader honors, and for which
# cwds get a pool. (memory-init-test.sh covers conflicting pools and the push
# gate; the case table that feeds all readers the same files is
# memory-host-key-rule-test.sh.)
#
# Why pin it. The host key prefixes every pool under OPS/.claude-memory/, a store
# that git syncs across machines. A successor box can share its predecessor's
# pools, so its key comes from a file, ~/.config/ops/memory-host, not from its
# hostname. A wrong key here either strands a session with an empty pool set (a
# fresh tree under the new hostname) or, worse, moves one machine's memory into
# another's. Cases:
#   - no file, no flag: the key is the one the hostname gives, exactly as
#     before (the hostname, or m-<machine-id[:12]> when it is generic);
#   - the file wins over the hostname, --hostname wins over the file;
#   - --set-host-key writes the file (normalized, atomically, with no temp
#     file left), runs with that key, is a no-op when the file already says it,
#     and --dry-run writes nothing;
#   - an invalid or empty value, from the flag or the file, is refused with a
#     message and exit 1, never ignored, and creates no pool;
#   - the successor-box switch-over: a symlink that points at an old pool is
#     repointed at the shared pool and its files moved in without overwriting,
#     and a name collision leaves both pools and the link as they were;
#   - which cwds get a pool: a scratch or temp cwd (-tmp*, T3 Code "No project"
#     scratch dirs in both dot spellings, Claude's own temp dir,
#     t3code-claude-title) gets none, whatever its memory dir holds; a project
#     whose memory dir is empty, or holds only the generated MEMORY.md, gets
#     none; one with any entry (a dotfile too) is migrated as before; a link to
#     a missing non-scratch pool gets the pool recreated and a scratch one is
#     left alone.
# bin/memory-index and memory-init.ps1 read the same file; the PowerShell cases
# are the last section of this suite (skipped, loudly, without pwsh).
#
# Every path is under a temp dir (HOME, OPS_DIR, CLAUDE_CONFIG_DIR); the live
# pools are never read. The guard below refuses any run outside bin/sandbox-run.
#
# Usage: memory-init-hostkey-test.sh    (exit 0 all pass, 1 otherwise)
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
INIT="${INIT_UNDER_TEST:-$HERE/../memory-init}"
INITPS="${INITPS_UNDER_TEST:-$HERE/../memory-init.ps1}"
[ -f "$INIT" ] || { echo "FAIL: $INIT missing"; exit 1; }

T="$(mktemp -d)"; H2ROOT=""
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; [ -z "$H2ROOT" ] || rm -rf "$H2ROOT"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }

echo "memory-init-hostkey-test:"

# The key the hostname alone gives: bin/memory-init's own rule, mirrored here.
plain_host() {
  local raw mid
  raw="$(hostname 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    ''|workspace|localhost|localhost.localdomain|ubuntu|debian|kali|raspberrypi)
      mid=""
      [ -r /etc/machine-id ] && mid="$(cat /etc/machine-id 2>/dev/null)"
      [ -z "$mid" ] && [ -r /var/lib/dbus/machine-id ] && mid="$(cat /var/lib/dbus/machine-id 2>/dev/null)"
      mid="$(printf '%s' "$mid" | tr -d '[:space:]')"
      printf 'm-%s' "${mid:0:12}" ;;
    *) printf '%s' "$raw" ;;
  esac
}
PLAIN="$(plain_host)"
[ -n "$PLAIN" ] && [ "$PLAIN" != "m-" ] || { echo "FAIL: this box gives no hostname or machine-id key"; exit 1; }

# fixture <name>: a fresh HOME, OPS checkout and Claude config dir.
fixture() {
  H="$T/$1/home"; CW="$T/$1/ops"; CFG="$T/$1/cfg"
  mkdir -p "$H" "$CW/.claude-memory" "$CFG/projects"
  git -c init.defaultBranch=main init -q "$CW" >/dev/null 2>&1
  MH="$H/.config/ops/memory-host"
  ENC="$(printf '%s' "$H" | sed 's|/|-|g')"
}
# run_init <args...>: sets OUT (stdout and stderr) and RC.
run_init() {
  OUT="$(env HOME="$H" OPS_DIR="$CW" CLAUDE_CONFIG_DIR="$CFG" bash "$INIT" "$@" 2>&1 </dev/null)"; RC=$?
}
pools() { (cd "$CW/.claude-memory" && ls -A | sort | tr '\n' ' '); }
hostline() { grep -m1 '^\[memory-init\] host: ' <<< "$OUT" | sed 's/^\[memory-init\] host: *//'; }
setfile() { mkdir -p "$(dirname "$MH")"; printf '%b' "$1" > "$MH"; }

# --- 1. no file, no flag: exactly the hostname's key ----------------------------
fixture c1
run_init
if [ "$RC" = 0 ] && [ "$(hostline)" = "$PLAIN" ] && [ "$(pools)" = "$PLAIN$ENC " ]; then
  ok "no file: the key is the hostname's ($PLAIN) and the pool is created under it"
else bad "no file changed the key" "rc=$RC host=$(hostline) pools=$(pools) out=$OUT"; fi
[ ! -e "$MH" ] && ok "no file: nothing writes the memory-host file" || bad "a plain run wrote $MH"

# --- 2. the file wins over the hostname -----------------------------------------
fixture c2
setfile 'sharedbox\n'
run_init
if [ "$RC" = 0 ] && [ "$(hostline)" = sharedbox ] && [ "$(pools)" = "sharedbox$ENC " ] \
   && [ "$(readlink -f "$CFG/projects/$ENC/memory")" = "$(readlink -f "$CW/.claude-memory/sharedbox$ENC")" ] \
   && grep -q "host key 'sharedbox' from $MH" <<< "$OUT"; then
  ok "the file wins: pool and symlink use the file's key, and the log says where it came from"
else bad "file key not used" "rc=$RC host=$(hostline) pools=$(pools) out=$OUT"; fi

# ASCII case folds and CRLF is an accepted ending; the full rule is in tests/memory-host-key-rule-test.sh.
fixture c2b
setfile 'SharedBox\r\n'
run_init
[ "$RC" = 0 ] && [ "$(hostline)" = sharedbox ] \
  && ok "the file value is lowercased (ASCII), and a CRLF ending is fine" || bad "file value not normalized" "rc=$RC host=$(hostline) out=$OUT"

# --- 3. --hostname wins over the file --------------------------------------------
fixture c3
setfile 'sharedbox\n'
run_init --hostname OtherBox
if [ "$RC" = 0 ] && [ "$(hostline)" = otherbox ] && [ "$(pools)" = "otherbox$ENC " ] && [ "$(cat "$MH")" = sharedbox ]; then
  ok "--hostname wins over the file for the run and leaves the file alone"
else bad "--hostname did not beat the file" "rc=$RC host=$(hostline) pools=$(pools) file=$(cat "$MH")"; fi

# --- 4. --set-host-key ------------------------------------------------------------
fixture c4
run_init --set-host-key SharedHost
if [ "$RC" = 0 ] && [ "$(cat "$MH")" = sharedhost ] && [ "$(hostline)" = sharedhost ] && [ "$(pools)" = "sharedhost$ENC " ] \
   && [ "$(ls -A "$(dirname "$MH")")" = memory-host ]; then
  ok "--set-host-key writes the normalized key, runs with it, and leaves no temp file"
else bad "--set-host-key" "rc=$RC file=$(cat "$MH" 2>&1) host=$(hostline) pools=$(pools) dir=$(ls -A "$(dirname "$MH")" 2>&1) out=$OUT"; fi
run_init --set-host-key sharedhost
[ "$RC" = 0 ] && grep -q "already says 'sharedhost'" <<< "$OUT" && [ "$(cat "$MH")" = sharedhost ] \
  && ok "--set-host-key with the same key is a no-op that says so" || bad "--set-host-key rerun" "rc=$RC out=$OUT"
run_init --set-host-key other
[ "$RC" = 0 ] && grep -q "(was 'sharedhost')" <<< "$OUT" && [ "$(cat "$MH")" = other ] \
  && ok "--set-host-key replacing a key names the old one" || bad "--set-host-key replace" "rc=$RC out=$OUT"
before="$(cat "$MH")"; run_init --set-host-key third --dry-run
[ "$RC" = 0 ] && [ "$(cat "$MH")" = "$before" ] && grep -q "would write host key 'third'" <<< "$OUT" && [ "$(hostline)" = third ] \
  && ok "--dry-run --set-host-key writes nothing and reports the key it would use" || bad "dry-run wrote or mis-reported" "rc=$RC file=$(cat "$MH") out=$OUT"
run_init --set-host-key a --hostname b
[ "$RC" = 1 ] && grep -q 'ambiguous' <<< "$OUT" && [ "$(cat "$MH")" = "$before" ] \
  && ok "--set-host-key together with --hostname is refused" || bad "ambiguous flags accepted" "rc=$RC out=$OUT"
help_out="$(bash "$INIT" --help 2>&1)"
grep -q -- '--set-host-key' <<< "$help_out" && grep -q 'memory-host' <<< "$help_out" && grep -q 'Undo' <<< "$help_out" \
   && grep -q 'per' <<< "$help_out" && grep -q 'root sessions' <<< "$help_out" && grep -q 'Exit codes' <<< "$help_out" \
  && ok "--help documents --set-host-key, the file, how to undo it, that it is per HOME (root needs its own), and the exit codes" || bad "--help silent on the host key" "$help_out"

# --- 5. invalid values are refused, never ignored ---------------------------------
long64="$(printf 'a%.0s' $(seq 1 64))"
long63="$(printf 'a%.0s' $(seq 1 63))"
check_refused_flag() {  # check_refused_flag <label> <value>
  fixture "r$RANDOM$RANDOM"; setfile 'keepme\n'
  run_init --set-host-key "$2"
  if [ "$RC" = 1 ] && grep -q '^memory-init: ' <<< "$OUT" && [ "$(cat "$MH")" = keepme ] && [ -z "$(pools)" ]; then
    ok "--set-host-key refuses $1, keeps the old file and creates no pool"
  else bad "--set-host-key accepted $1" "rc=$RC file=$(cat "$MH") pools=$(pools) out=$OUT"; fi
}
check_refused_flag "an empty value" ""
check_refused_flag "a path" "a/b"
check_refused_flag "a parent path" "../x"
check_refused_flag "a leading dot" ".hidden"
check_refused_flag "a leading hyphen" "-x"
check_refused_flag "a space" "two words"
check_refused_flag "a leading space (no trimming)" " sharedbox"
check_refused_flag "a newline inside the value" "$(printf 'sharedbox\n.')"
check_refused_flag "a 64-character value" "$long64"
check_refused_flag "non-ASCII" "caf$(printf '\303\251')"
check_refused_flag "the Kelvin sign (U+212A lowercases to ASCII k)" "$(printf '\342\204\252')"
fixture c5ok; run_init --set-host-key "$long63"
[ "$RC" = 0 ] && [ "$(cat "$MH")" = "$long63" ] && ok "--set-host-key accepts a 63-character key" || bad "63-character key refused" "rc=$RC out=$OUT"
fixture c5dots; run_init --set-host-key "ex.ample_1-b"
[ "$RC" = 0 ] && [ "$(cat "$MH")" = "ex.ample_1-b" ] && ok "--set-host-key accepts dot, underscore and hyphen" || bad "dot/underscore/hyphen key refused" "rc=$RC out=$OUT"
fixture c5h1; run_init --hostname ""
[ "$RC" = 1 ] && grep -q 'is empty' <<< "$OUT" && [ -z "$(pools)" ] \
  && ok "--hostname with an empty value is refused, not silently replaced by the hostname" || bad "--hostname '' fell back" "rc=$RC pools=$(pools) out=$OUT"
fixture c5h2; run_init --hostname "a/b"
[ "$RC" = 1 ] && [ -z "$(pools)" ] && ok "--hostname with a path is refused" || bad "--hostname a/b accepted" "rc=$RC pools=$(pools) out=$OUT"
fixture c5h3; run_init --hostname
[ "$RC" = 1 ] && grep -q 'needs a value' <<< "$OUT" && ok "--hostname with no value is refused" || bad "--hostname without a value" "rc=$RC out=$OUT"
fixture c5h4; run_init --set-host-key
[ "$RC" = 1 ] && grep -q 'needs a value' <<< "$OUT" && ok "--set-host-key with no value is refused" || bad "--set-host-key without a value" "rc=$RC out=$OUT"

# A bad memory-host file stops the run: no pool under the hostname's key.
check_refused_file() {  # check_refused_file <label> <printf-escaped content>
  fixture "f$RANDOM$RANDOM"; setfile "$2"
  run_init
  if [ "$RC" = 1 ] && grep -q "memory-init: " <<< "$OUT" && grep -q 'host key' <<< "$OUT" && [ -z "$(pools)" ]; then
    ok "a memory-host file with $1 stops memory-init and creates no pool"
  else bad "a memory-host file with $1 was tolerated" "rc=$RC pools=$(pools) out=$OUT"; fi
}
check_refused_file "no content" ''
check_refused_file "surrounding spaces (no trimming)" ' sharedbox \n'
check_refused_file "a UTF-8 BOM" '\xef\xbb\xbfsharedbox\n'
check_refused_file "only whitespace" ' \n\n'
check_refused_file "a path" '../escape\n'
check_refused_file "a slash" 'a/b\n'
check_refused_file "two words" 'two words\n'
check_refused_file "two lines" 'one\ntwo\n'
check_refused_file "a leading hyphen" '-x\n'
check_refused_file "a 64-character value" "$long64\n"
check_refused_file "a NUL byte" 'ab\0cd\n'
fixture f_dir; mkdir -p "$MH"; run_init
[ "$RC" = 1 ] && grep -q 'not a readable regular file' <<< "$OUT" && [ -z "$(pools)" ] \
  && ok "a directory in place of the memory-host file stops memory-init" || bad "directory tolerated" "rc=$RC out=$OUT"
fixture f_dir_set; mkdir -p "$MH"; run_init --set-host-key sharedhost
[ "$RC" = 1 ] && grep -q 'is a directory' <<< "$OUT" && [ -d "$MH" ] && [ -z "$(ls -A "$MH")" ] \
  && ok "--set-host-key onto a directory is refused, and nothing is moved inside it" || bad "--set-host-key wrote into a directory" "rc=$RC ls=$(ls -A "$MH") out=$OUT"
fixture f_dangling; mkdir -p "$(dirname "$MH")"; ln -s "$H/nowhere" "$MH"; run_init
[ "$RC" = 1 ] && [ -z "$(pools)" ] && ok "a dangling memory-host symlink stops memory-init" || bad "dangling symlink tolerated" "rc=$RC out=$OUT"
fixture f_ok_link; mkdir -p "$(dirname "$MH")"; printf 'viaLink\n' > "$H/real-key"; ln -s "$H/real-key" "$MH"; run_init
[ "$RC" = 0 ] && [ "$(hostline)" = vialink ] && ok "a memory-host symlink to a good file is followed" || bad "good symlink refused" "rc=$RC out=$OUT"

# --- 6. the successor-box switch-over: an old pool's link moves onto the shared pool -------
fixture c6
mkdir -p "$CW/.claude-memory/sharedhost$ENC" "$CW/.claude-memory/oldbox$ENC" "$CFG/projects/$ENC"
printf 'shared fact\n' > "$CW/.claude-memory/sharedhost$ENC/keep.md"
printf 'old fact\n' > "$CW/.claude-memory/oldbox$ENC/old.md"
ln -s "$CW/.claude-memory/oldbox$ENC" "$CFG/projects/$ENC/memory"
run_init --set-host-key sharedhost
shared="$CW/.claude-memory/sharedhost$ENC"
if [ "$RC" = 0 ] && [ "$(readlink -f "$CFG/projects/$ENC/memory")" = "$(readlink -f "$shared")" ] \
   && [ "$(cat "$shared/keep.md")" = 'shared fact' ] && [ "$(cat "$shared/old.md")" = 'old fact' ] \
   && [ ! -e "$CW/.claude-memory/oldbox$ENC" ]; then
  ok "switch-over: the link moves to the shared pool, its files come along, none is overwritten"
else bad "switch-over" "rc=$RC link=$(readlink -f "$CFG/projects/$ENC/memory") keep=$(cat "$shared/keep.md" 2>&1) old=$(cat "$shared/old.md" 2>&1) out=$OUT"; fi
run_init
[ "$RC" = 0 ] && grep -q 'already initialized' <<< "$OUT" && ok "switch-over: a second run is idempotent" || bad "second run not idempotent" "rc=$RC out=$OUT"
# A same-named note in both pools is never overwritten, and nothing moves: both pools and the link stay.
fixture c6b
mkdir -p "$CW/.claude-memory/sharedhost$ENC" "$CW/.claude-memory/oldbox$ENC" "$CFG/projects/$ENC"
printf 'shared fact\n' > "$CW/.claude-memory/sharedhost$ENC/keep.md"
printf 'would clobber\n' > "$CW/.claude-memory/oldbox$ENC/keep.md"
printf 'old fact\n' > "$CW/.claude-memory/oldbox$ENC/old.md"
ln -s "$CW/.claude-memory/oldbox$ENC" "$CFG/projects/$ENC/memory"
run_init --set-host-key sharedhost
if [ "$RC" = 1 ] && grep -q 'conflicting target entry: keep.md' <<< "$OUT" \
   && [ "$(readlink -f "$CFG/projects/$ENC/memory")" = "$(readlink -f "$CW/.claude-memory/oldbox$ENC")" ] \
   && [ "$(cat "$CW/.claude-memory/sharedhost$ENC/keep.md")" = 'shared fact' ] && [ "$(cat "$CW/.claude-memory/oldbox$ENC/keep.md")" = 'would clobber' ] \
   && [ -f "$CW/.claude-memory/oldbox$ENC/old.md" ]; then
  ok "switch-over: a colliding note stops the move, says so, and leaves both pools and the link unchanged"
else bad "collision not handled" "rc=$RC out=$OUT"; fi

# --- 7. which cwds get a pool: scratch and temp cwds, empty memory dirs -------------
# The keys below are arbitrary strings: only the name of a projects/ dir matters.
mkmem() {  # mkmem <key> [file...]: a real projects/<key>/memory dir holding the named files
  local k="$1"; shift
  mkdir -p "$CFG/projects/$k/memory"
  local f; for f in "$@"; do printf 'a fact\n' > "$CFG/projects/$k/memory/$f"; done
}
fixture c7
mkmem -tmp-t3code-claude-title-LVsv9U x.md
mkmem -tmp-other-scratch                        # empty, and scratch
mkmem -home-user--claude-tmp-claude-1000-verify y.md
mkmem -home-user-t3code-claude-title-ZZ z.md
mkmem -home-user-real-project fact.md           # a real project with an entry
mkmem -home-user-emptyproj                      # a real project, empty memory dir
mkmem -home-user-indexonly MEMORY.md            # only the generated index
mkmem -home-user-dotfile .hidden                # a dotfile is an entry
mkdir -p "$CFG/projects/-home-user-dangling" "$CFG/projects/-tmp-t3code-claude-title-DANGLE"
ln -s "$CW/.claude-memory/$PLAIN-home-user-dangling" "$CFG/projects/-home-user-dangling/memory"
ln -s "$CW/.claude-memory/$PLAIN-tmp-t3code-claude-title-DANGLE" "$CFG/projects/-tmp-t3code-claude-title-DANGLE/memory"
run_init
want="$PLAIN-home-user-dangling $PLAIN-home-user-dotfile $PLAIN-home-user-real-project $PLAIN$ENC "
if [ "$RC" = 0 ] && [ "$(pools)" = "$want" ]; then
  ok "scratch and empty: only the HOME pool, the real project, the dotfile project and the recreated dangling pool exist (no -tmp, claude-tmp, t3code-claude-title or empty-dir pools)"
else bad "pool set after scratch and empty cwds" "rc=$RC pools=$(pools) want=$want out=$OUT"; fi
grep -q 'skipped 5 scratch or temp cwd(s)' <<< "$OUT" && ok "scratch cwds: the run says how many it skipped (5, the dangling scratch link among them)" || bad "scratch skip count" "$OUT"
if [ -L "$CFG/projects/-home-user-real-project/memory" ] && [ -f "$CW/.claude-memory/$PLAIN-home-user-real-project/fact.md" ] \
   && [ -f "$CW/.claude-memory/$PLAIN-home-user-dotfile/.hidden" ]; then
  ok "a project with an entry (a dotfile counts) is migrated and linked, as before"
else bad "real project not migrated" "$OUT"; fi
if [ -d "$CFG/projects/-home-user-emptyproj/memory" ] && [ ! -L "$CFG/projects/-home-user-emptyproj/memory" ] \
   && [ -d "$CFG/projects/-home-user-indexonly/memory" ] && [ ! -L "$CFG/projects/-home-user-indexonly/memory" ] \
   && [ -f "$CFG/projects/-home-user-indexonly/memory/MEMORY.md" ] \
   && grep -q 'source is an empty memory dir: skipping' <<< "$OUT"; then
  ok "an empty memory dir, and one holding only MEMORY.md, are left alone: no pool, no link, nothing moved"
else bad "empty source handled wrongly" "$OUT"; fi
[ -f "$CFG/projects/-tmp-t3code-claude-title-LVsv9U/memory/x.md" ] && [ ! -L "$CFG/projects/-tmp-t3code-claude-title-LVsv9U/memory" ] \
  && [ -f "$CFG/projects/-home-user--claude-tmp-claude-1000-verify/memory/y.md" ] \
  && ok "scratch memory dirs keep their files in place: nothing is moved or linked" || bad "scratch dir touched" "$OUT"
[ -d "$CW/.claude-memory/$PLAIN-home-user-dangling" ] && grep -q 'pool directory was missing: recreated' <<< "$OUT" \
  && ok "a link to a missing non-scratch pool gets its pool recreated" || bad "dangling pool not recreated" "$OUT"
[ ! -e "$CW/.claude-memory/$PLAIN-tmp-t3code-claude-title-DANGLE" ] && [ -L "$CFG/projects/-tmp-t3code-claude-title-DANGLE/memory" ] \
  && ok "a dangling link of a scratch cwd is left as it is (nothing recreated)" || bad "scratch dangling link handled wrongly" "$OUT"
run_init
[ "$RC" = 0 ] && [ "$(pools)" = "$want" ] && ok "a second run changes nothing (idempotent)" || bad "second run changed the pools" "pools=$(pools)"
fixture c7d; mkmem -home-user-emptyproj; mkmem -tmp-x x.md; ln -s "$CW/.claude-memory/$PLAIN-gone" "$CFG/projects/-home-user-emptyproj/memory.link" 2>/dev/null; rm -f "$CFG/projects/-home-user-emptyproj/memory.link"
run_init --dry-run
[ "$RC" = 0 ] && [ "$(pools)" = "" ] && ok "--dry-run on scratch and empty cwds creates nothing" || bad "dry run created pools" "pools=$(pools) $OUT"

# The T3 "No project" scratch dirs ($HOME/.t3/scratch/<date>-<title>-<id>): the key holds the home's
# encoding, so these cases need a HOME that is not under /tmp (which -tmp* would catch on its own).
H2ROOT="$HOME/mi-scratch-test-$$"; rm -rf "$H2ROOT"; mkdir -p "$H2ROOT"
H="$H2ROOT/home"; CW="$H2ROOT/ops"; CFG="$H2ROOT/cfg"; mkdir -p "$H" "$CW/.claude-memory" "$CFG/projects"
git -c init.defaultBranch=main init -q "$CW" >/dev/null 2>&1
MH="$H/.config/ops/memory-host"; ENC="$(printf '%s' "$H" | sed 's|/|-|g')"
mkmem "$ENC--t3-scratch-2026-10-04-example-title-5ebbadc7" a.md
mkmem "$ENC-.t3-scratch-2026-10-05-older-build-spelling-abc" b.md
mkmem "$ENC-t3-notes-project" c.md                # a real project whose key only resembles the prefix
mkmem "$ENC-.t3-project" d.md
run_init
want="$PLAIN$ENC $PLAIN$ENC-.t3-project $PLAIN$ENC-t3-notes-project "
if [ "$RC" = 0 ] && [ "$(pools)" = "$want" ] && grep -q 'skipped 2 scratch or temp cwd(s)' <<< "$OUT"; then
  ok "T3 scratch dirs: both spellings of \$HOME/.t3/scratch/ are skipped; a project key that only resembles the prefix is migrated"
else bad "T3 scratch keys" "rc=$RC pools=$(pools) want=$want out=$OUT"; fi
rm -rf "$H2ROOT"; H2ROOT=""

# --- 8. memory-init.ps1: the same file and rule (needs pwsh; SKIP says so) ----------
PWSH="$(command -v pwsh 2>/dev/null || true)"
if [ -z "$PWSH" ] || [ ! -f "$INITPS" ]; then
  echo "SKIP: memory-init.ps1 cases (pwsh not on PATH in this run)"
else
  run_ps() {  # run_ps <args...>; HOME also set as USERPROFILE, which ps1 reads
    OUT="$(env HOME="$H" USERPROFILE="$H" OPS_DIR="$CW" CLAUDE_CONFIG_DIR="$CFG" "$PWSH" -NoProfile -NonInteractive -File "$INITPS" "$@" 2>&1 </dev/null)"; RC=$?
  }
  pshost() { grep -m1 '^\[memory-init\] host: ' <<< "$OUT" | sed 's/^\[memory-init\] host: *//'; }
  # PowerShell encodes the home cwd as the name of its projects/ dir by replacing / \ : with -.
  fixture p1; setfile 'sharedbox\n'; run_ps -DryRun
  [ "$RC" = 0 ] && [ "$(pshost)" = sharedbox ] && ok "ps1: the memory-host file is the host key" || bad "ps1 ignored the file" "rc=$RC out=$OUT"
  fixture p2; setfile 'sharedbox\n'; run_ps -HostnameOverride OtherBox -DryRun
  [ "$RC" = 0 ] && [ "$(pshost)" = otherbox ] && ok "ps1: -HostnameOverride wins over the file" || bad "ps1 override lost to the file" "rc=$RC out=$OUT"
  fixture p3; COMPUTERNAME=WinBox run_ps -DryRun
  [ "$RC" = 0 ] && [ "$(pshost)" = winbox ] && ok "ps1: no file keeps COMPUTERNAME, lowercased, as before" || bad "ps1 changed the no-file key" "rc=$RC out=$OUT"
  fixture p4; run_ps -SetHostKey SharedHost -DryRun
  [ "$RC" = 0 ] && [ ! -e "$MH" ] && [ "$(pshost)" = sharedhost ] && ok "ps1: -SetHostKey -DryRun writes nothing" || bad "ps1 dry run wrote" "rc=$RC out=$OUT"
  fixture p5; run_ps -SetHostKey SharedHost -OnlyHome
  if [ "$RC" = 0 ] && [ "$(od -An -c "$MH" | tr -d ' ')" = 'sharedhost\n' ] && [ "$(pshost)" = sharedhost ]; then
    ok "ps1: -SetHostKey writes the normalized key as one UTF-8 line (no BOM) and runs with it"
  else bad "ps1 -SetHostKey" "rc=$RC file=$(od -An -c "$MH" 2>&1) out=$OUT"; fi
  for v in 'a/b' '../x' 'two words' '-x' ' sharedbox' "$long64" "$(printf '\342\204\252')"; do
    fixture "pr$RANDOM"; setfile 'keepme\n'; run_ps -SetHostKey "$v"
    if [ "$RC" != 0 ] && [ "$(cat "$MH")" = keepme ]; then ok "ps1: -SetHostKey refuses '${v:0:12}'"; else bad "ps1 accepted '$v'" "rc=$RC out=$OUT"; fi
  done
  fixture pd; mkdir -p "$MH"; run_ps -SetHostKey sharedhost
  if [ "$RC" != 0 ] && [ -d "$MH" ] && [ -z "$(ls -A "$MH")" ]; then ok "ps1: -SetHostKey onto a directory is refused, nothing moved inside"; else bad "ps1 wrote into a directory" "rc=$RC ls=$(ls -A "$MH") out=$OUT"; fi
  for c in '' ' \n' 'a/b\n' 'one\ntwo\n'; do
    fixture "pf$RANDOM"; setfile "$c"; run_ps -DryRun
    if [ "$RC" != 0 ] && [ -z "$(pools)" ]; then ok "ps1: a bad memory-host file stops the run"; else bad "ps1 tolerated a bad file" "rc=$RC content=$(printf '%q' "$c") out=$OUT"; fi
  done
  # which cwds get a pool: the same two rules as the bash run (see section 7). The ps1 joins the host
  # and the key with a dash (a Windows key starts with a drive letter), so a key that starts with
  # one, as these do, gives a double dash.
  fixture p7
  mkmem -tmp-t3code-claude-title-LVsv9U x.md; mkmem -tmp-other-scratch
  mkmem -home-user--claude-tmp-claude-1000-verify y.md
  mkmem -home-user-real-project fact.md; mkmem -home-user-emptyproj; mkmem -home-user-indexonly MEMORY.md
  mkmem -home-user-dotfile .hidden
  mkmem C--Users-user-AppData-Local-Temp-scratch z.md
  mkdir -p "$CFG/projects/-home-user-dangling"; ln -s "$CW/.claude-memory/winbox--home-user-dangling" "$CFG/projects/-home-user-dangling/memory"
  COMPUTERNAME=WinBox run_ps
  want="winbox--home-user-dangling winbox--home-user-dotfile winbox--home-user-real-project winbox-$ENC "
  if [ "$RC" = 0 ] && [ "$(pools)" = "$want" ] && grep -q 'skipped 4 scratch or temp cwd(s)' <<< "$OUT" \
     && [ -f "$CFG/projects/-tmp-t3code-claude-title-LVsv9U/memory/x.md" ] && [ -d "$CFG/projects/-home-user-emptyproj/memory" ] \
     && [ ! -L "$CFG/projects/-home-user-emptyproj/memory" ] && grep -q 'pool directory was missing' <<< "$OUT"; then
    ok "ps1: scratch and empty cwds get no pool, a real project and a dotfile project are migrated, a dangling pool is recreated"
  else bad "ps1 pool set" "rc=$RC pools=$(pools) want=$want out=$OUT"; fi
  COMPUTERNAME=WinBox run_ps
  [ "$RC" = 0 ] && [ "$(pools)" = "$want" ] && ok "ps1: a second run changes nothing" || bad "ps1 second run" "pools=$(pools)"
fi

echo
echo "memory-init-hostkey-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
