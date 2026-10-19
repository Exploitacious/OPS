#!/usr/bin/env bash
# sandbox-run-test.sh - behavior tests for bin/sandbox-run and the two guards
# (bin/sandbox-guard.sh, bin/sandbox_guard.py) that destructive suites run first.
#
# Safe by construction, because a broken sandbox is exactly the case under test:
#   - Every write, delete or rename attempted inside the sandbox names one
#     explicit path inside this test's own scratch dir (a mktemp dir under
#     /var/tmp, which sits on the read-only root inside), so a sandbox that let
#     it through would change that canary and nothing else. No glob, no $HOME
#     path, no recursive delete is ever attempted, inside or out.
#   - The refusal cases run an inert command that only writes an evidence file
#     in the scratch dir; a refusal that failed leaves the evidence behind.
#   - The fake bwrap used for the untrusted-binary case is inert and is refused
#     before it could run.
#   - Cleanup removes the files this test made by name and the dirs with rmdir;
#     anything unexpected is left in place and reported, never swept.
# It runs sandbox-run itself, so it runs bare (outside any sandbox): bwrap
# cannot nest on hosts where AppArmor's unpriv_bwrap profile denies a second
# user namespace (Ubuntu 23.10 and later), so run it outside the sandbox.
#
# Exit 0 = all pass. Any failure exits 1 and prints the offending case.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BIN="$(cd "$HERE/.." && pwd -P)"
SR="$BIN/sandbox-run"
GSH="$BIN/sandbox-guard.sh"
GPY="$BIN/sandbox_guard.py"
LINT="$BIN/sandbox-lint"
for f in "$SR" "$LINT"; do [ -x "$f" ] || { echo "FAIL: missing or not executable: $f"; exit 1; }; done
for f in "$GSH" "$GPY"; do [ -f "$f" ] || { echo "FAIL: missing: $f"; exit 1; }; done
command -v bwrap >/dev/null 2>&1 || { echo "FAIL: bwrap (bubblewrap) is not installed; the sandbox cannot run here"; exit 1; }
# Inner commands run on the read-only root, where anything under the home
# directory is hidden: use a system interpreter for the Python guard.
PY="$(PATH=/usr/local/bin:/usr/bin:/bin command -v python3 2>/dev/null)" \
  || { echo "FAIL: no python3 outside the home directory"; exit 1; }

PASS=0; FAIL=0
pass()  { PASS=$((PASS+1)); }
faild() { FAIL=$((FAIL+1)); echo "FAIL: $1"; [ $# -gt 1 ] && [ -n "$2" ] && echo "  $2"; return 0; }
check() { local name="$1"; shift; if "$@"; then pass; else faild "$name" "${DETAIL:-}"; fi; DETAIL=""; }

SCRATCH="$(mktemp -d /var/tmp/sandbox-run-test.XXXXXX)" || { echo "FAIL: cannot make a scratch dir under /var/tmp"; exit 1; }
case "$SCRATCH" in /var/tmp/sandbox-run-test.??????) ;; *) echo "FAIL: unexpected scratch path $SCRATCH"; exit 1 ;; esac
HOSTTMP=""
MADE_FILES=() MADE_DIRS=()
mkf() { printf '%s\n' "$2" > "$1" && MADE_FILES+=("$1"); }
mkd() { mkdir "$1" && MADE_DIRS+=("$1"); }
cleanup() {
  local f i left=""
  for f in "${MADE_FILES[@]}" "$SCRATCH/rw/written" "$SCRATCH/ro/inner/written" \
           "$SCRATCH/ran" "$SCRATCH/fake-bwrap-ran" "$SCRATCH/new" \
           "$SCRATCH/wt/written" "$SCRATCH/wt2/written" "$SCRATCH/prim/written" "$SCRATCH/hollow/sub/written"; do
    rm -f -- "$f"
  done
  for (( i=${#MADE_DIRS[@]}-1; i>=0; i-- )); do rmdir -- "${MADE_DIRS[$i]}" 2>/dev/null || left="$left ${MADE_DIRS[$i]}"; done
  [ -z "$HOSTTMP" ] || rmdir -- "$HOSTTMP" 2>/dev/null || left="$left $HOSTTMP"
  rmdir -- "$SCRATCH" 2>/dev/null || left="$left $SCRATCH"
  [ -z "$left" ] || echo "NOTE: left in place (unexpected content):$left" >&2
}
trap cleanup EXIT

mkd "$SCRATCH/rw"; mkd "$SCRATCH/ro"; mkd "$SCRATCH/ro/inner"; mkd "$SCRATCH/farm"; mkd "$SCRATCH/farm2"
mkf "$SCRATCH/canary" "canary-original"
mkf "$SCRATCH/ro/file" "ro-original"
ln -s "$HOME" "$SCRATCH/home-link" && MADE_FILES+=("$SCRATCH/home-link")
ln -s /tmp "$SCRATCH/tmp-link" && MADE_FILES+=("$SCRATCH/tmp-link")
# Repository fixtures, made by hand so cleanup stays by name: a primary
# checkout (prim, its .git a git directory git itself accepts), two linked
# worktrees of it (wt with an absolute gitdir line, wt2 with a relative one, as
# worktree.useRelativePaths writes), and a checkout whose .git file names a dir
# without commondir (sm, as a submodule's does); and an empty .git dir that git
# does not take for a repository (hollow, as a sandbox's mount target leaves).
mkd "$SCRATCH/prim"; mkd "$SCRATCH/prim/sub"; mkd "$SCRATCH/prim/.git"
mkd "$SCRATCH/prim/.git/objects"; mkd "$SCRATCH/prim/.git/refs"; mkd "$SCRATCH/prim/.git/worktrees"
mkd "$SCRATCH/prim/.git/worktrees/wt"; mkd "$SCRATCH/prim/.git/worktrees/wt2"
mkd "$SCRATCH/prim/.git/modules"; mkd "$SCRATCH/prim/.git/modules/sm"
mkd "$SCRATCH/wt"; mkd "$SCRATCH/wt2"; mkd "$SCRATCH/sm"
mkd "$SCRATCH/hollow"; mkd "$SCRATCH/hollow/.git"; mkd "$SCRATCH/hollow/sub"
mkf "$SCRATCH/prim/.git/HEAD" "ref: refs/heads/main"
for w in wt wt2; do
  mkf "$SCRATCH/prim/.git/worktrees/$w/HEAD" "ref: refs/heads/$w"
  mkf "$SCRATCH/prim/.git/worktrees/$w/commondir" "../.."
  mkf "$SCRATCH/prim/.git/worktrees/$w/gitdir" "$SCRATCH/$w/.git"
done
mkf "$SCRATCH/wt/.git" "gitdir: $SCRATCH/prim/.git/worktrees/wt"
mkf "$SCRATCH/wt2/.git" "gitdir: ../prim/.git/worktrees/wt2"
mkf "$SCRATCH/sm/.git" "gitdir: $SCRATCH/prim/.git/modules/sm"
UID_="$(id -u)"
PW_HOME="$(getent passwd "$UID_" | cut -d: -f6)"
cd "$SCRATCH" || exit 1

# sb ARGS... : run sandbox-run from the scratch dir; output in OUT, status in RC.
sb() { OUT="$("$SR" "$@" 2>&1)"; RC=$?; }

# --- 1. the inside: env, nonce, fresh HOME and /tmp, PID and network --------------
sb --bind "$SCRATCH/rw" -- /bin/bash -c '
  printf "sb=%s\n" "${OPS_SANDBOX:-}"
  printf "home=%s\n" "$HOME"
  printf "tmpdir=%s\n" "${TMPDIR:-}"
  printf "nonce_env=%s\n" "${OPS_SANDBOX_NONCE:-}"
  printf "nonce_file=%s\n" "$(cat /tmp/.ops-sandbox/nonce 2>/dev/null)"
  printf "home_entries=%s\n" "$(ls -A "$HOME" | wc -l)"
  printf "tmp_entries=%s\n" "$(ls -A /tmp | tr "\n" " ")"
  printf "pid_ns=%s\n" "$(readlink /proc/self/ns/pid)"
  printf "outer_pid_visible=%s\n" "$( [ -e /proc/'"$$"' ] && echo yes || echo no)"
  printf "ifaces=%s\n" "$(tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d " " | sort | tr "\n" " ")"
  if [ -d /run/user/'"$UID_"' ]; then printf "runtime_entries=%s\n" "$(ls -A /run/user/'"$UID_"' | wc -l)"; fi
'
val() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
check "the sandbox starts (rc=$RC)" [ "$RC" = 0 ]
DETAIL="$OUT"; check "OPS_SANDBOX=1 inside" [ "$(val sb)" = 1 ]
DETAIL="$(val home)"; check "HOME inside is the same path as outside" [ "$(val home)" = "$(realpath -m -- "$HOME")" ]
DETAIL="$(val tmpdir)"; check "TMPDIR inside is /tmp" [ "$(val tmpdir)" = /tmp ]
N1="$(val nonce_env)"
DETAIL="$N1"; check "the nonce is 32 hex characters" eval '[[ "$N1" =~ ^[0-9a-f]{32}$ ]]'
DETAIL="env $N1 file $(val nonce_file)"; check "the nonce file matches the nonce in the environment" [ "$(val nonce_file)" = "$N1" ]
DETAIL="$(val home_entries)"; check "HOME inside is empty (fresh tmpfs, nothing of the real home)" [ "$(val home_entries)" = 0 ]
DETAIL="$(val tmp_entries)"; check "/tmp inside holds only the nonce dir" [ "$(val tmp_entries)" = ".ops-sandbox " ]
# Compare namespace identities: the namespace is what isolates, whatever name
# the reaper at pid 1 carries.
DETAIL="$(val pid_ns)"; check "a fresh PID namespace" eval '[ -n "$(val pid_ns)" ] && [ "$(val pid_ns)" != "$(readlink /proc/self/ns/pid)" ]'
check "this test's own pid is not visible inside" [ "$(val outer_pid_visible)" = no ]
if [ -d "/run/user/$UID_" ]; then
  DETAIL="$(val runtime_entries)"; check "the user runtime dir is covered by an empty tmpfs" [ "$(val runtime_entries)" = 0 ]
fi
sb --bind "$SCRATCH/rw" -- /bin/bash -c 'cat /tmp/.ops-sandbox/nonce'
check "a second run gets a different nonce" eval '[ "$RC" = 0 ] && [ -n "$OUT" ] && [ "$OUT" != "$N1" ]'
sb --no-bind --no-net -- /bin/bash -c 'tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d " "'
DETAIL="$OUT"; check "--no-net leaves only loopback" eval '[ "$RC" = 0 ] && [ "$OUT" = lo ]'
sb --no-bind -- /bin/sh -c 'exit 7'
check "the command's exit status passes through (7)" [ "$RC" = 7 ]
# The source descriptors refer to host mounts, including read-only bind sources
# opened before isolation. bwrap must close them before dispatching the payload.
sb --bind "$SCRATCH/rw" --ro-bind "$SCRATCH/ro" -- "$PY" -I -c '
import os
live = []
for name in os.listdir("/proc/self/fd"):
    fd = int(name)
    if fd <= 2:
        continue
    try:
        os.fstat(fd)
    except OSError:
        continue
    live.append(fd)
print(live)
'
DETAIL="$RC $OUT"; check "no host descriptors reach the sandboxed command" eval '[ "$RC" = 0 ] && [ "$OUT" = "[]" ]'

# --- 2. writes outside the binds fail with EROFS; the canary is untouched ----------
# Each probe names one path in the scratch dir. Prints NAME=OK or NAME=<errno>.
PROBE='
import errno, os, sys
s = sys.argv[1]
def attempt(name, fn):
    try:
        fn(); print(name + "=OK")
    except OSError as e:
        print(name + "=" + (errno.errorcode.get(e.errno, str(e.errno))))
def append(p):
    with open(p, "a") as f: f.write("changed\n")
def create(p):
    with open(p, "x") as f: f.write("new\n")
attempt("append_canary", lambda: append(s + "/canary"))
attempt("create_beside_canary", lambda: create(s + "/new"))
attempt("unlink_canary", lambda: os.unlink(s + "/canary"))
attempt("rename_canary", lambda: os.rename(s + "/canary", s + "/canary.moved"))
attempt("chmod_canary", lambda: os.chmod(s + "/canary", 0o600))
attempt("append_ro_bind", lambda: append(s + "/ro/file"))
attempt("write_rw_bind", lambda: create(s + "/rw/written"))
attempt("write_inner_rw_bind", lambda: create(s + "/ro/inner/written"))
attempt("write_home", lambda: create(os.environ["HOME"] + "/probe"))
attempt("write_tmp", lambda: create("/tmp/probe"))
'
CANARY_MODE="$(stat -c %a "$SCRATCH/canary")"
sb --bind "$SCRATCH/rw" --ro-bind "$SCRATCH/ro" --bind "$SCRATCH/ro/inner" -- "$PY" -c "$PROBE" "$SCRATCH"
check "the probe ran (rc=$RC)" [ "$RC" = 0 ]
for k in append_canary create_beside_canary unlink_canary rename_canary chmod_canary append_ro_bind; do
  DETAIL="$(val "$k")"; check "$k fails with EROFS" [ "$(val "$k")" = EROFS ]
done
for k in write_rw_bind write_inner_rw_bind write_home write_tmp; do
  DETAIL="$(val "$k")"; check "$k succeeds" [ "$(val "$k")" = OK ]
done
check "the canary still holds its original content" [ "$(cat "$SCRATCH/canary" 2>/dev/null)" = canary-original ]
check "the canary keeps its mode" [ "$(stat -c %a "$SCRATCH/canary")" = "$CANARY_MODE" ]
check "nothing was created beside the canary" eval '[ ! -e "$SCRATCH/new" ] && [ ! -e "$SCRATCH/canary.moved" ]'
check "the read-only bind's file is unchanged" [ "$(cat "$SCRATCH/ro/file")" = ro-original ]
check "a write inside the --bind dir lands outside" [ "$(cat "$SCRATCH/rw/written" 2>/dev/null)" = new ]
check "a --bind nested inside a --ro-bind is writable" [ "$(cat "$SCRATCH/ro/inner/written" 2>/dev/null)" = new ]
check "the write to HOME inside did not reach the real home" [ ! -e "$HOME/probe" ]
# The opposite nesting: a --ro-bind inside a --bind stays read-only. The outer
# --bind is the scratch dir itself; the probe writes only rw/written (the
# control that the outer bind is writable) and tries ro/file.
NEST='
import errno, sys
s = sys.argv[1]
for name, path in (("append_ro_bind", s + "/ro/file"), ("write_rw_bind", s + "/rw/written")):
    try:
        with open(path, "a") as f: f.write("x\n")
        print(name + "=OK")
    except OSError as e:
        print(name + "=" + errno.errorcode.get(e.errno, str(e.errno)))
'
rm -f -- "$SCRATCH/rw/written"
sb --bind "$SCRATCH" --ro-bind "$SCRATCH/ro" -- "$PY" -c "$NEST" "$SCRATCH"
check "the nested probe ran (rc=$RC)" [ "$RC" = 0 ]
DETAIL="$(val append_ro_bind)"; check "a --ro-bind nested inside a --bind stays read-only" [ "$(val append_ro_bind)" = EROFS ]
DETAIL="$(val write_rw_bind)"; check "control: the outer --bind really is writable" [ "$(val write_rw_bind)" = OK ]
check "the read-only bind's file is still unchanged" [ "$(cat "$SCRATCH/ro/file")" = ro-original ]
rm -f -- "$SCRATCH/rw/written" "$SCRATCH/ro/inner/written"

# --- 3. refusals: non-zero, a clear message, and the command never runs ------------
RAN='printf ran > "$1"'
refused() { # <label> <expected rc> <message part> <sandbox-run args before -->
  local label="$1" want="$2" msg="$3"; shift 3
  rm -f -- "$SCRATCH/ran"
  OUT="$("$SR" "$@" -- /bin/sh -c "$RAN" sh "$SCRATCH/ran" 2>&1)"; RC=$?
  DETAIL="rc=$RC out=$OUT"
  check "refused: $label" eval '[ "$RC" = "$want" ] && [ ! -e "$SCRATCH/ran" ] && printf "%s" "$OUT" | grep -qF -- "$msg"'
}
refused "--bind /" 3 "refusing to make / writable" --bind /
refused "--bind \$HOME" 3 "refusing to make the home directory" --bind "$HOME"
refused "--bind the account home ($PW_HOME)" 3 "refusing to make the home directory" --bind "$PW_HOME"
refused "--bind an ancestor of HOME" 3 "an ancestor of the home directory" --bind "$(dirname "$HOME")"
refused "--bind a symlink to HOME" 3 "refusing to make the home directory" --bind "$SCRATCH/home-link"
refused "--bind a missing directory" 3 "no such directory" --bind "$SCRATCH/missing"
refused "--bind a file" 3 "is not a directory" --bind "$SCRATCH/canary"
refused "--bind a directory owned by root" 3 "not by you" --bind /usr
refused "--bind /tmp (root-owned)" 3 "not by you" --bind "$SCRATCH/tmp-link"
refused "--bind under /proc" 3 "under /proc" --bind /proc/1
if [ -d "/run/user/$UID_" ]; then
  refused "--bind the user runtime dir" 3 "user runtime dir" --bind "/run/user/$UID_"
fi
refused "--bind an empty path" 3 "empty path" --bind ""
refused "--ro-bind /" 3 "refusing /" --ro-bind /
refused "--ro-bind \$HOME" 3 "would expose the home directory" --ro-bind "$HOME"
refused "--ro-bind an ancestor of HOME" 3 "would expose the home directory" --ro-bind "$(dirname "$HOME")"
refused "--ro-bind /tmp" 3 "fresh /tmp" --ro-bind /tmp
refused "--ro-bind a missing path" 3 "no such file" --ro-bind "$SCRATCH/missing"
refused "--no-bind with --bind" 2 "cannot be combined" --no-bind --bind "$SCRATCH/rw"
refused "an unknown option" 2 "unknown option" --frobnicate
OUT="$("$SR" --no-bind 2>&1)"; RC=$?
DETAIL="rc=$RC $OUT"; check "refused: no command" eval '[ "$RC" = 2 ] && printf "%s" "$OUT" | grep -q "no command"'
# A shared checkout is never writable (the 2026-10-17 review's finding: an
# rm -rf under the sandbox reaches whatever is bound). A linked worktree is.
refused "--bind a primary checkout" 3 "$SCRATCH/prim is the primary checkout of a repository" --bind "$SCRATCH/prim"
refused "--bind a directory inside a primary checkout" 3 "$SCRATCH/prim is the primary checkout of a repository" --bind "$SCRATCH/prim/sub"
refused "--bind a git directory" 3 "$SCRATCH/prim/.git is a git directory" --bind "$SCRATCH/prim/.git"
refused "--bind a checkout whose .git file names no linked worktree (a submodule's)" 3 "does not name a linked worktree" --bind "$SCRATCH/sm"
# The fixtures are what git itself sees: the primary checkout's git dir is the
# repository's common dir, a linked worktree's is its own.
gitdirs() { env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE -u GIT_CEILING_DIRECTORIES \
  git -C "$1" rev-parse --path-format=absolute --git-dir --git-common-dir 2>&1 | tr '\n' ' '; }
OUT="$(gitdirs "$SCRATCH/prim/sub")"; DETAIL="$OUT"
check "git agrees: the fixture primary checkout's git dir is the common dir" [ "$OUT" = "$SCRATCH/prim/.git $SCRATCH/prim/.git " ]
for w in wt wt2; do
  OUT="$(gitdirs "$SCRATCH/$w")"; DETAIL="$OUT"
  check "git agrees: the fixture linked worktree $w has a git dir of its own" [ "$OUT" = "$SCRATCH/prim/.git/worktrees/$w $SCRATCH/prim/.git " ]
done
OUT="$(gitdirs "$SCRATCH/hollow/sub")"; DETAIL="$OUT"
check "git agrees: an empty .git dir is not a repository" eval 'printf "%s" "$OUT" | grep -q "not a git repository"'
for w in wt wt2 hollow/sub; do
  sb --bind "$SCRATCH/$w" -- /bin/sh -c 'printf new > "$1"' sh "$SCRATCH/$w/written"
  DETAIL="rc=$RC $OUT"; check "--bind $w (a linked worktree, or below a .git git ignores): allowed and writable" eval '[ "$RC" = 0 ] && [ "$(cat "$SCRATCH/$w/written" 2>/dev/null)" = new ]'
  rm -f -- "$SCRATCH/$w/written"
done
# Nothing is writable by default, not even the work tree the command starts
# in (the default used to be its git toplevel); --no-bind is the same.
DEF='
import errno, os
for name, path in (("cwd", os.path.join(os.getcwd(), "written")), ("home", os.environ["HOME"] + "/probe"), ("tmp", "/tmp/probe")):
    try:
        with open(path, "x") as f: f.write("new\n")
        print(name + "=OK")
    except OSError as e:
        print(name + "=" + errno.errorcode.get(e.errno, str(e.errno)))
'
for start in prim wt; do
  for flag in "" --no-bind; do
    OUT="$(cd "$SCRATCH/$start" && "$SR" $flag -- "$PY" -I -c "$DEF" 2>&1)"; RC=$?
    DETAIL="rc=$RC $OUT"
    check "${flag:-no --bind}, started in ${start}: its work tree is read-only, HOME and /tmp writable" \
      eval '[ "$RC" = 0 ] && [ "$(val cwd)" = EROFS ] && [ "$(val home)" = OK ] && [ "$(val tmp)" = OK ] && [ ! -e "$SCRATCH/$start/written" ]'
  done
done
# A different HOME is protected too, and the account's home stays hidden.
mkd "$SCRATCH/fakehome"
OUT="$(HOME="$SCRATCH/fakehome" "$SR" --bind "$SCRATCH" -- /bin/sh -c "$RAN" sh "$SCRATCH/ran" 2>&1)"; RC=$?
DETAIL="rc=$RC $OUT"; check "refused: --bind an ancestor of a non-default HOME" eval '[ "$RC" = 3 ] && [ ! -e "$SCRATCH/ran" ]'
OUT="$(HOME="$SCRATCH/fakehome" "$SR" --bind "$SCRATCH/rw" -- /bin/sh -c 'printf "%s %s" "$HOME" "$(ls -A "$1" | wc -l)"' sh "$PW_HOME" 2>&1)"; RC=$?
DETAIL="rc=$RC $OUT"; check "with a non-default HOME, HOME is that path and the account home is still empty inside" eval '[ "$RC" = 0 ] && [ "$OUT" = "$SCRATCH/fakehome 0" ]'

# bwrap missing: a caller PATH without bwrap (sandbox-run looks bwrap up on the
# caller's PATH; its own checks use the system PATH).
for t in realpath stat id getent cut awk od tr sort sed git cat; do
  p="$(command -v "$t")" && ln -s "$p" "$SCRATCH/farm/$t" && MADE_FILES+=("$SCRATCH/farm/$t")
done
OUT="$(PATH="$SCRATCH/farm" /bin/bash "$SR" --bind "$SCRATCH/rw" -- /bin/sh -c "$RAN" sh "$SCRATCH/ran" 2>&1)"; RC=$?
DETAIL="rc=$RC $OUT"; check "refused: bwrap missing (exit 4, never unsandboxed)" eval '[ "$RC" = 4 ] && [ ! -e "$SCRATCH/ran" ] && printf "%s" "$OUT" | grep -q "not installed"'
# An untrusted bwrap (user-owned, first on PATH) is refused before it can run.
for t in realpath stat id getent cut awk od tr sort sed git cat; do
  p="$(command -v "$t")" && ln -s "$p" "$SCRATCH/farm2/$t" && MADE_FILES+=("$SCRATCH/farm2/$t")
done
printf '#!/bin/sh\nprintf ran > "%s"\nexit 0\n' "$SCRATCH/fake-bwrap-ran" > "$SCRATCH/farm2/bwrap"; MADE_FILES+=("$SCRATCH/farm2/bwrap")
chmod 755 "$SCRATCH/farm2/bwrap"
OUT="$(PATH="$SCRATCH/farm2" /bin/bash "$SR" --bind "$SCRATCH/rw" -- /bin/sh -c "$RAN" sh "$SCRATCH/ran" 2>&1)"; RC=$?
DETAIL="rc=$RC $OUT"; check "refused: a bwrap not owned by root (exit 4)" eval '[ "$RC" = 4 ] && [ ! -e "$SCRATCH/ran" ] && [ ! -e "$SCRATCH/fake-bwrap-ran" ] && printf "%s" "$OUT" | grep -q "not root"'
# A stub dir first on PATH (as a test's stubs would be) cannot steer the checks:
# a fake realpath and stat claim every path is a harmless dir of yours. The
# command still gets the caller's PATH inside.
mkd "$SCRATCH/farm3"
printf '#!/bin/sh\necho %s/rw\n' "$SCRATCH" > "$SCRATCH/farm3/realpath"; MADE_FILES+=("$SCRATCH/farm3/realpath")
printf '#!/bin/sh\necho %s\n' "$UID_" > "$SCRATCH/farm3/stat"; MADE_FILES+=("$SCRATCH/farm3/stat")
chmod 755 "$SCRATCH/farm3/realpath" "$SCRATCH/farm3/stat"
OUT="$(PATH="$SCRATCH/farm3:$PATH" "$SR" --bind "$HOME" -- /bin/sh -c "$RAN" sh "$SCRATCH/ran" 2>&1)"; RC=$?
DETAIL="rc=$RC $OUT"; check "refused: --bind \$HOME with a fake realpath and stat first on PATH" eval '[ "$RC" = 3 ] && [ ! -e "$SCRATCH/ran" ]'
OUT="$(PATH="$SCRATCH/farm3:$PATH" "$SR" --bind "$SCRATCH/rw" -- /bin/sh -c 'printf "%s" "$PATH"' 2>&1)"; RC=$?
DETAIL="rc=$RC $OUT"; check "the command sees the caller's PATH inside" eval '[ "$RC" = 0 ] && [ "$OUT" = "$SCRATCH/farm3:$PATH" ]'
# Set-up failure: a working directory that does not exist inside (under the
# host's /tmp, which the fresh /tmp hides) fails closed with exit 125.
HOSTTMP="$(mktemp -d /tmp/sandbox-run-test.XXXXXX)"
OUT="$(cd "$HOSTTMP" && "$SR" --bind "$SCRATCH/rw" -- /bin/sh -c "$RAN" sh "$SCRATCH/rw/ran" 2>&1)"; RC=$?
DETAIL="rc=$RC $OUT"; check "a sandbox that cannot be set up exits 125 and runs nothing" eval '[ "$RC" = 125 ] && [ ! -e "$SCRATCH/rw/ran" ] && printf "%s" "$OUT" | grep -q "could not set up the sandbox"'
rm -f -- "$SCRATCH/rw/ran"

# --- 4. the guards: refuse outside, pass inside, and env alone never passes ---------
gsh() { OUT="$(env "$@" /bin/bash -c '. "$1" && sandbox_guard && echo PASSED' gsh "$GSH" 2>&1)"; RC=$?; }
gpy() { OUT="$(env "$@" "$PY" -I "$GPY" 2>&1)"; RC=$?; }
refuses() { [ "$RC" = 97 ] && printf '%s' "$OUT" | grep -q "^refusing to run outside sandbox-run: " && ! printf '%s' "$OUT" | grep -qx "PASSED\|ok"; }
FAKE_NONCE=0123456789abcdef0123456789abcdef
gsh; DETAIL="$RC $OUT"; check "bash guard refuses outside the sandbox (exit 97)" refuses
gpy; DETAIL="$RC $OUT"; check "python guard refuses outside the sandbox (exit 97)" refuses
gsh OPS_SANDBOX=1 OPS_SANDBOX_NONCE="$FAKE_NONCE" HOME=/tmp; DETAIL="$RC $OUT"
check "bash guard refuses spoofed env outside (OPS_SANDBOX=1, a nonce, HOME on a tmpfs)" refuses
gpy OPS_SANDBOX=1 OPS_SANDBOX_NONCE="$FAKE_NONCE" HOME=/tmp; DETAIL="$RC $OUT"
check "python guard refuses spoofed env outside" refuses
# Inside: both pass; then each condition broken on its own inside makes both refuse.
inner() { # <env assignments for the guard>... : prints "bash=<rc> py=<rc>"
  "$SR" --bind "$SCRATCH/rw" --ro-bind "$BIN" -- /bin/bash -c '
    gsh="$1" gpy="$2" py="$3"; shift 3
    env "$@" /bin/bash -c ". \"\$1\" && sandbox_guard" g "$gsh" >/dev/null 2>"$TMPDIR/b.err"; b=$?
    env "$@" "$py" -I "$gpy" >/dev/null 2>"$TMPDIR/p.err"; p=$?
    printf "bash=%s py=%s\n" "$b" "$p"
    head -c 300 "$TMPDIR/b.err"; head -c 300 "$TMPDIR/p.err"' inner "$GSH" "$GPY" "$PY" "$@" 2>&1
}
OUT="$(inner)"; DETAIL="$OUT"; check "both guards pass inside the sandbox" [ "$(printf '%s' "$OUT" | head -1)" = "bash=0 py=0" ]
OUT="$(inner -u OPS_SANDBOX)"; DETAIL="$OUT"; check "inside, OPS_SANDBOX unset: both refuse" [ "$(printf '%s' "$OUT" | head -1)" = "bash=97 py=97" ]
OUT="$(inner OPS_SANDBOX_NONCE="$FAKE_NONCE")"; DETAIL="$OUT"; check "inside, a nonce that does not match the file: both refuse" [ "$(printf '%s' "$OUT" | head -1)" = "bash=97 py=97" ]
OUT="$(inner HOME="$SCRATCH/rw")"; DETAIL="$OUT"; check "inside, HOME pointed at a non-tmpfs dir: both refuse" [ "$(printf '%s' "$OUT" | head -1)" = "bash=97 py=97" ]
# A suite may point HOME at a fixture under the fresh /tmp before it starts
# another guarded suite (branch-gc-test.sh runs branch-gc-deadline-test.py so).
OUT="$(inner HOME=/tmp/fixture/home)"; DETAIL="$OUT"; check "inside, HOME pointed at a fixture dir under the fresh /tmp: both pass" [ "$(printf '%s' "$OUT" | head -1)" = "bash=0 py=0" ]
# HOME at another fresh mount (the sandbox's /tmp) passes: what matters is that
# HOME is a fresh tmpfs mount and the account's home is hidden, not its name.
OUT="$(inner HOME=/tmp)"; DETAIL="$OUT"; check "inside, HOME pointed at the fresh /tmp: both still pass" [ "$(printf '%s' "$OUT" | head -1)" = "bash=0 py=0" ]

# The canonical guard lines, as sandbox-lint defines them, stop a fixture suite
# before its body runs outside the sandbox and let it run inside. The guard's
# path runs from the suite's directory to bin/: from bin/tests, and from a
# self-test beside its tool in hooks/ (remote-sessions/ is the same depth).
mkd "$SCRATCH/gfx"; mkd "$SCRATCH/gfx/bin"; mkd "$SCRATCH/gfx/bin/tests"; mkd "$SCRATCH/gfx/hooks"
cp "$GSH" "$SCRATCH/gfx/bin/sandbox-guard.sh" && MADE_FILES+=("$SCRATCH/gfx/bin/sandbox-guard.sh")
cp "$GPY" "$SCRATCH/gfx/bin/sandbox_guard.py" && MADE_FILES+=("$SCRATCH/gfx/bin/sandbox_guard.py")
for loc in bin/tests hooks; do
  case "$loc" in bin/tests) up=1 ;; *) up='["..", "bin"]' ;; esac
  CANON="$("$PY" -I -c 'import ast, runpy, sys; m = runpy.run_path(sys.argv[1]); up = ast.literal_eval(sys.argv[2]); print(m["guard_sh"](up)); print(m["guard_py"](up))' "$LINT" "$up")"
  SH_LINE="$(printf '%s\n' "$CANON" | sed -n 1p)"; PY_LINE="$(printf '%s\n' "$CANON" | sed -n 2p)"
  { printf '#!/usr/bin/env bash\n# fixture\nset -euo pipefail\n%s\n' "$SH_LINE"; printf 'printf body-ran > "%s"\n' "$SCRATCH/ran"; } > "$SCRATCH/gfx/$loc/s.sh"
  MADE_FILES+=("$SCRATCH/gfx/$loc/s.sh")
  { printf '"""fixture"""\n%s\n' "$PY_LINE"; printf 'open(%s, "w").write("body-ran")\n' "'$SCRATCH/ran'"; } > "$SCRATCH/gfx/$loc/s.py"
  MADE_FILES+=("$SCRATCH/gfx/$loc/s.py")
  rm -f -- "$SCRATCH/ran"
  OUT="$(bash "$SCRATCH/gfx/$loc/s.sh" 2>&1)"; RC=$?
  DETAIL="rc=$RC $OUT"; check "$loc: a shell suite with the canonical guard line stops outside, body never runs" eval '[ "$RC" = 97 ] && [ ! -e "$SCRATCH/ran" ]'
  OUT="$("$PY" "$SCRATCH/gfx/$loc/s.py" 2>&1)"; RC=$?
  DETAIL="rc=$RC $OUT"; check "$loc: a python suite with the canonical guard line stops outside, body never runs" eval '[ "$RC" = 97 ] && [ ! -e "$SCRATCH/ran" ]'
  OUT="$("$SR" --bind "$SCRATCH" -- /bin/bash "$SCRATCH/gfx/$loc/s.sh" 2>&1)"; RC=$?
  DETAIL="rc=$RC $OUT"; check "$loc: the same shell suite runs inside the sandbox" eval '[ "$RC" = 0 ] && [ "$(cat "$SCRATCH/ran" 2>/dev/null)" = body-ran ]'
  rm -f -- "$SCRATCH/ran"
  OUT="$("$SR" --bind "$SCRATCH" -- "$PY" "$SCRATCH/gfx/$loc/s.py" 2>&1)"; RC=$?
  DETAIL="rc=$RC $OUT"; check "$loc: the same python suite runs inside the sandbox" eval '[ "$RC" = 0 ] && [ "$(cat "$SCRATCH/ran" 2>/dev/null)" = body-ran ]'
  rm -f -- "$SCRATCH/ran"
done
# A guard file that is missing fails closed too (the suite cannot source it).
mv -- "$SCRATCH/gfx/bin/sandbox-guard.sh" "$SCRATCH/gfx/bin/sandbox-guard.sh.off"
OUT="$("$SR" --bind "$SCRATCH" -- /bin/bash "$SCRATCH/gfx/bin/tests/s.sh" 2>&1)"; RC=$?
mv -- "$SCRATCH/gfx/bin/sandbox-guard.sh.off" "$SCRATCH/gfx/bin/sandbox-guard.sh"
DETAIL="rc=$RC $OUT"; check "a missing guard file stops the suite even inside (exit 97)" eval '[ "$RC" = 97 ] && [ ! -e "$SCRATCH/ran" ]'

# --- 5. each guard condition on its own -----------------------------------------
# Sandboxes built here by hand with bwrap, right in every way but one, so each
# condition is shown to be checked by itself (a guard that dropped one would pass
# its case). Only the two guards run inside, and they only read /proc and the
# nonce file; that is why one case can afford a writable root.
BW="$(command -v bwrap)"
CN="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
GUARDS='
b_out="$(/bin/bash -c ". \"\$1\" && sandbox_guard" g "$1" 2>&1)"; b=$?
p_out="$("$3" -I "$2" 2>&1)"; p=$?
printf "B %s %s\n" "$b" "$(printf "%s\n" "$b_out" | head -n 1)"
printf "P %s %s\n" "$p" "$(printf "%s\n" "$p_out" | head -n 1)"
'
HM="$(realpath -m -- "$HOME")"
crafted() { # <expected: "pass" or a reason fragment> <label> <bwrap mount args...>
  local want="$1" label="$2" b p; shift 2
  OUT="$("$BW" --die-with-parent --unshare-pid "$@" --ro-bind "$BIN" "$BIN" \
    --setenv HOME "$HM" --setenv TMPDIR /tmp --setenv OPS_SANDBOX 1 --setenv OPS_SANDBOX_NONCE "$CN" \
    -- /bin/bash -c "$GUARDS" g "$GSH" "$GPY" "$PY" 3<<< "$CN" 2>&1)"
  b="$(printf '%s\n' "$OUT" | sed -n 's/^B //p')"; p="$(printf '%s\n' "$OUT" | sed -n 's/^P //p')"
  DETAIL="$OUT"
  if [ "$want" = pass ]; then
    check "crafted sandbox, $label: both guards pass" eval '[ "$b" = "0 " ] && [ "$p" = "0 ok" ]'
  else
    check "crafted sandbox, $label: both guards refuse with the same reason" \
      eval '[ "${b%% *}" = 97 ] && [ "${p%% *}" = 97 ] && [ "${b#* }" = "${p#* }" ] && printf "%s" "$b" | grep -qF -- "$want"'
  fi
}
ROOT_RO=(--ro-bind / / --dev /dev --proc /proc --tmpfs /tmp)
ROOT_RW=(--bind / / --dev /dev --proc /proc --tmpfs /tmp)
HIDE=(--tmpfs "$PW_HOME"); [ "$HM" = "$PW_HOME" ] || HIDE+=(--tmpfs "$HM")
NONCE_RO=(--dir /tmp/.ops-sandbox --ro-bind-data 3 /tmp/.ops-sandbox/nonce)
crafted pass "everything right (the control)" "${ROOT_RO[@]}" "${HIDE[@]}" "${NONCE_RO[@]}"
crafted "the root filesystem is mounted read-write" "root writable" "${ROOT_RW[@]}" "${HIDE[@]}" "${NONCE_RO[@]}"
crafted "is not on a tmpfs" "real home visible" "${ROOT_RO[@]}" "${NONCE_RO[@]}"
crafted "is not a mount" "nonce a plain file, not a mount" "${ROOT_RO[@]}" "${HIDE[@]}" --dir /tmp/.ops-sandbox --file 3 /tmp/.ops-sandbox/nonce
crafted "is not mounted read-only" "nonce mounted writable" "${ROOT_RO[@]}" "${HIDE[@]}" --dir /tmp/.ops-sandbox --bind-data 3 /tmp/.ops-sandbox/nonce
if [ "$HM" = "$PW_HOME" ]; then
  # HOME on a fresh tmpfs of its own while the account's home stays visible.
  OUT="$("$BW" --die-with-parent --unshare-pid "${ROOT_RO[@]}" --tmpfs /var/tmp --ro-bind "$BIN" "$BIN" "${NONCE_RO[@]}" \
    --setenv HOME /var/tmp --setenv TMPDIR /tmp --setenv OPS_SANDBOX 1 --setenv OPS_SANDBOX_NONCE "$CN" \
    -- /bin/bash -c "$GUARDS" g "$GSH" "$GPY" "$PY" 3<<< "$CN" 2>&1)"
  DETAIL="$OUT"
  check "crafted sandbox, HOME fresh but the account's home visible: both refuse" \
    eval 'printf "%s\n" "$OUT" | grep -q "^B 97 .*account.s home directory .* is not hidden" && printf "%s\n" "$OUT" | grep -q "^P 97 .*account.s home directory .* is not hidden"'
fi

echo "sandbox-run-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
