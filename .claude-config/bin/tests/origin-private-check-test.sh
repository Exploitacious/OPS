#!/usr/bin/env bash
# origin-private-check-test.sh: the push gate's verdicts, against a stubbed gh
# and a stubbed ssh, so no case touches the network or the real ~/.ssh/config.
#
# Asserts: GitHub private -> 0, public -> 1; the public template in every URL
# form -> 1 without asking gh, even when gh would say private; gh missing,
# failing, or answering oddly -> 2; a non-GitHub host or a local path -> 2,
# and -> 0 with the repo-local opt-in; the opt-in never overrides a public
# answer and is ignored when set globally; push URLs decide; an ssh alias for
# github.com is resolved; every reason is one line and never carries a URL's
# credentials.
#
# Run:  bash ~/OPS/.claude-config/bin/tests/origin-private-check-test.sh
set -uo pipefail

CHECK="$(cd "$(dirname "$0")/.." && pwd)/origin-private-check"
[ -f "$CHECK" ] || { echo "FAIL: origin-private-check missing at $CHECK" >&2; exit 1; }
BASH_BIN="$(command -v bash)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/origin-private-check-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$WORK/bin" "$WORK/nogh"
export GH_LOG="$WORK/gh.log" SSH_LOG="$WORK/ssh.log"

# gh stub: answers from $GH_STUB and records its arguments.
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "${GH_STUB:-}" in
  true|false) printf '%s\n' "$GH_STUB" ;;
  error) echo 'HTTP 404: Not Found (https://api.github.com/repos/x/y)' >&2; exit 1 ;;
  odd) echo 'null' ;;
  *) exit 4 ;;
esac
STUB
# ssh stub: `ssh -G -- <host>` resolves the alias work-gh to github.com and
# every other host to itself, the way a ~/.ssh/config HostName would.
cat > "$WORK/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_LOG"
[ "$1" = -G ] || exit 255
host="${*: -1}"
case "$host" in work-gh) echo 'hostname github.com' ;; *) echo "hostname $host" ;; esac
STUB
chmod +x "$WORK/bin/gh" "$WORK/bin/ssh"
# A PATH with everything the gate runs except gh.
for tool in git tr awk timeout; do
  p="$(command -v "$tool")" && ln -s "$p" "$WORK/nogh/$tool"
done
cp "$WORK/bin/ssh" "$WORK/nogh/ssh"
WITH_GH="$WORK/bin:$PATH"

REPO="$WORK/repo"
git init -q "$REPO" || fail "git init"

# origin <url> [push-url...]: origin fetches from <url>; with push URLs given,
# pushes go to those instead. Written with git config so an option-shaped URL
# (which `git remote add` rejects) can be tested too.
origin() {
  git -C "$REPO" remote remove origin 2>/dev/null
  git -C "$REPO" config remote.origin.url "$1" || fail "set url $1"
  shift
  local u
  for u in "$@"; do git -C "$REPO" config --add remote.origin.pushurl "$u" || fail "push url $u"; done
}
optin() { git -C "$REPO" config ops.pushVerified "$1"; }
no_optin() { git -C "$REPO" config --unset ops.pushVerified 2>/dev/null; return 0; }

# run_check [path]: sets RC and ERR (stderr); stdout must stay empty.
run_check() {
  local path="${1:-$WITH_GH}" out
  : > "$GH_LOG"; : > "$SSH_LOG"
  out="$(PATH="$path" "$BASH_BIN" "$CHECK" "$REPO" 2>"$WORK/err")"; RC=$?
  ERR="$(cat "$WORK/err")"
  [ -z "$out" ] || fail "stdout not empty: $out"
}
# expect <rc> <label> [reason-substring]
expect() {
  [ "$RC" -eq "$1" ] || fail "$2: exit $RC, want $1 (reason: $ERR)"
  [ "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" = 1 ] || fail "$2: reason is not one line: $ERR"
  case "$ERR" in "origin-private-check: "*) ;; *) fail "$2: reason lacks the prefix: $ERR" ;; esac
  if [ -n "${3:-}" ]; then
    case "$ERR" in *"$3"*) ;; *) fail "$2: reason lacks '$3': $ERR" ;; esac
  fi
}
gh_not_called() { [ ! -s "$GH_LOG" ] || fail "$1: gh was called: $(cat "$GH_LOG")"; }

# --- GitHub answers ------------------------------------------------------------
origin https://github.com/acme/ops-copy.git
GH_STUB=true; export GH_STUB
run_check; expect 0 "private repo" "github.com/acme/ops-copy is private"
grep -qx 'api --hostname github.com repos/acme/ops-copy --jq .private' "$GH_LOG" \
  || fail "gh not asked for repos/acme/ops-copy on github.com: $(cat "$GH_LOG")"
GH_STUB=false
run_check; expect 1 "public repo" "github.com/acme/ops-copy is public"
pass "GitHub private exits 0, public exits 1, asked through gh api --hostname github.com"

# --- The public template, in every URL form ------------------------------------
GH_STUB=true
for url in \
  https://github.com/Exploitacious/OPS \
  https://github.com/Exploitacious/OPS.git \
  https://github.com/exploitacious/ops.git/ \
  HTTPS://GitHub.com/EXPLOITACIOUS/OPS.GIT \
  http://github.com/Exploitacious/OPS \
  https://www.github.com/Exploitacious/OPS \
  git@github.com:Exploitacious/OPS.git \
  github.com:Exploitacious/OPS \
  git@github.com:/Exploitacious/OPS.git \
  ssh://git@github.com/Exploitacious/OPS.git \
  ssh://git@github.com:22/Exploitacious/OPS \
  ssh://git@ssh.github.com:443/Exploitacious/OPS.git \
  git://github.com/Exploitacious/OPS.git \
  git@work-gh:Exploitacious/OPS.git; do
  origin "$url"
  run_check; expect 1 "template $url" "public OPS template"
  gh_not_called "template $url"
done
pass "the public template is refused in every URL form without asking gh"

# --- gh missing, failing, or answering oddly -----------------------------------
origin git@github.com:acme/ops-copy.git
run_check "$WORK/nogh"; expect 2 "gh missing" "gh (GitHub CLI) is not installed"
GH_STUB=error; run_check; expect 2 "gh error" "gh could not read github.com/acme/ops-copy"
case "$ERR" in *"gh auth login"*ops.pushVerified*) ;; *) fail "gh error: the fix does not name gh sign-in and the opt-in: $ERR" ;; esac
GH_STUB=odd; run_check; expect 2 "gh odd answer" "unexpected answer"
GH_STUB=unauth; run_check; expect 2 "gh not signed in" "exit 4"
pass "gh missing, failing, unauthenticated, or answering oddly exits 2"

# --- Hosts it cannot verify, and the opt-in ------------------------------------
GH_STUB=true
for url in \
  https://git.example.com/acme/ops.git \
  git@git.example.com:acme/ops.git \
  ssh://git@git.example.com:2222/acme/ops.git \
  "$WORK/bare.git" \
  "file://$WORK/bare.git" \
  'C:/Users/someone/ops'; do
  origin "$url"
  no_optin
  run_check; expect 2 "unverifiable $url" "ops.pushVerified"
  case "$ERR" in *"gh auth login"*) fail "unverifiable $url: suggests gh for a host gh cannot vouch for: $ERR" ;; esac
  gh_not_called "unverifiable $url"
  optin true
  run_check; expect 0 "opt-in $url" "private by opt-in"
done
no_optin
git config --global ops.pushVerified true
origin https://git.example.com/acme/ops.git
run_check; expect 2 "global opt-in" "unverified"
git config --global --unset ops.pushVerified
pass "non-GitHub hosts and local paths exit 2, and 0 only with the repo-local opt-in"

optin true
GH_STUB=false; origin https://github.com/acme/ops-copy.git
run_check; expect 1 "opt-in vs public" "is public"
origin https://github.com/Exploitacious/OPS.git
run_check; expect 1 "opt-in vs template" "public OPS template"
GH_STUB=error; origin https://github.com/acme/ops-copy.git
run_check; expect 0 "opt-in covers a gh failure" "private by opt-in"
no_optin
pass "the opt-in never overrides a public answer or the template"

# --- Push URLs decide ------------------------------------------------------------
GH_STUB=true
origin https://github.com/acme/ops-copy.git https://github.com/Exploitacious/OPS.git
run_check; expect 1 "pushurl is the template" "public OPS template"
origin https://github.com/Exploitacious/OPS.git https://github.com/acme/ops-copy.git
run_check; expect 0 "fetch from the template, push to a private copy" "acme/ops-copy is private"
origin https://github.com/acme/ops-copy.git https://github.com/acme/ops-copy.git https://git.example.com/acme/ops.git
run_check; expect 2 "one unverifiable push URL" "git.example.com"
optin true; run_check; expect 0 "one unverifiable push URL with opt-in" "private by opt-in"; no_optin
pass "every push URL is checked, and the push URL wins over the fetch URL"

# --- ssh aliases, malformed URLs, no origin --------------------------------------
GH_STUB=true; origin git@work-gh:acme/ops-copy.git
run_check; expect 0 "ssh alias" "acme/ops-copy is private"
grep -q -- '-G -- work-gh' "$SSH_LOG" || fail "ssh alias not resolved with ssh -G: $(cat "$SSH_LOG")"
GH_STUB=false; run_check; expect 1 "ssh alias, public" "is public"
GH_STUB=true
for url in https://github.com/../acme https://github.com/acme https://github.com/acme/ops/extra https://github.com '-oProxyCommand=evil:acme/ops'; do
  origin "$url"
  run_check; expect 2 "malformed $url"
  gh_not_called "malformed $url"
done
grep -q 'ProxyCommand' "$SSH_LOG" && fail "an option-shaped host reached ssh"
git -C "$REPO" remote remove origin
run_check; expect 2 "no origin" "no origin remote"
REPO="$WORK/not-a-repo"; mkdir -p "$REPO"
run_check; expect 2 "not a repo" "not a git repository"
REPO="$WORK/repo"
pass "ssh aliases resolve; malformed URLs, no origin, and no repo exit 2"

# --- Credentials never reach the reason -----------------------------------------
for stub in true false error; do
  GH_STUB=$stub
  origin 'https://x-access-token:ghp_SECRETVALUE1234@github.com/acme/ops-copy.git'
  run_check
  case "$ERR" in *SECRETVALUE*|*x-access-token*) fail "credentials printed ($stub): $ERR" ;; esac
  origin 'https://x-access-token:ghp_SECRETVALUE1234@github.com/Exploitacious/OPS.git'
  run_check
  case "$ERR" in *SECRETVALUE*|*x-access-token*) fail "credentials printed (template): $ERR" ;; esac
done
origin 'https://deploy:hunter2pass@git.example.com/acme/ops.git'
run_check; expect 2 "credentials on another host"
case "$ERR" in *hunter2pass*|*deploy:*) fail "credentials printed (other host): $ERR" ;; esac
pass "URL credentials never appear in a reason"

echo "ALL PASS"
