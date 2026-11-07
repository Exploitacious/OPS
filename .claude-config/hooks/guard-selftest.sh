#!/usr/bin/env bash
# guard-selftest.sh: prove the security guards actually BLOCK (fail-closed),
# not silently allow (fail-open). Run it after deploying the hooks and any
# time by hand. On Windows this is the canary that the jq-based extractor is
# live and python3's absence no longer disables the hard gates.
#
# Exit 0 = every guard enforces as expected; 1 = a guard is dead/misbehaving;
# 2 = a usage error.
#
# --quick runs only the first block below (git-guard's string rules and the
# secrets-guard block) and stops: it is the canary for a deploy, because the
# full set (well over a hundred guard calls, most of them starting Python) takes
# minutes in Git Bash, and a deploy that prints nothing while it runs looks
# hung. The full set is the suite; CI and a by-hand run use it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
quick=0
case "$#:${1:-}" in
  0:) ;;
  1:--quick) quick=1 ;;
  *) echo "usage: guard-selftest.sh [--quick]" >&2; exit 2 ;;
esac
# Git Bash turns ln -s into a copy, and a copied bash.exe cannot find its MSYS
# DLLs (exit 127), so the probes that need a real link (a PATH built of links,
# a directory link) cannot run there; they say SKIP rather than fail. Linux,
# macOS and CI run them.
gs_msys=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) gs_msys=1 ;; esac
# The fake private-key header the secrets-guard probes write, built at run time
# so this file never holds one: written out, two such headers a few lines apart
# read to a history scanner (gitleaks, CI's secrets job) as one key block.
KEYHDR="-----BEGIN OPENSSH PRIV""ATE KEY-----"

probe() {  # label  expected_rc  hook  [hook-args...]   (JSON on stdin)
  local label="$1" want="$2" hook="$3"; shift 3
  local json; json="$(cat)"
  printf '%s' "$json" | "$DIR/$hook" "$@" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "$want" ]; then
    printf '  PASS  %s (exit %s)\n' "$label" "$rc"
  else
    printf '  FAIL  %s (exit %s, want %s)\n' "$label" "$rc" "$want"
    fails=$((fails + 1))
  fi
}

echo "guard-selftest:"
probe "git-guard blocks force-push"          2 git-guard.sh <<'J'
{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}
J
probe "git-guard blocks protected-root rm"   2 git-guard.sh <<'J'
{"tool_name":"Bash","tool_input":{"command":"rm -rf $HOME/OPS"}}
J
probe "git-guard allows normal git"          0 git-guard.sh <<'J'
{"tool_name":"Bash","tool_input":{"command":"git status"}}
J
probe "secrets-guard blocks secret->memory"  2 secrets-guard.sh pre <<J
{"tool_input":{"file_path":"/x/memory/note.md","content":"$KEYHDR"}}
J
if [ "$quick" = 1 ]; then
  if [ "$fails" -eq 0 ]; then
    echo "guard-selftest --quick: ALL GUARDS ENFORCE (core probes; run without --quick for the full set)"
    exit 0
  fi
  echo "guard-selftest --quick: $fails guard(s) NOT enforcing: is jq installed? are the hooks executable (100755)?"
  exit 1
fi
# rtk-awareness: every guard reaches the same verdict whether or not the
# command carries an rtk prefix (bare, absolute-path, `command rtk`, an rtk
# option, the argv form of a command-running subcommand, or rtk after && in a
# chain). Before the fix each blocked form below passed. Read-only rtk git
# still passes. cmdj wraps one command in the PreToolUse JSON with its cwd in
# a plain project repo, where the OPS-copy push gate allows pushes, so only the
# check under test can block (without a cwd the push gate blocked the push
# forms on its own and the force-push check went untested). Each probe reads
# cmdj through a here-string, not a pipe: a pipe runs probe in a subshell, so
# its fails count was lost and a regression here still exited 0 (2026-10-19).
RTKREPO="$(mktemp -d)"; git init -q "$RTKREPO"
cmdj() { jq -cn --arg c "$1" --arg d "$RTKREPO" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
for form in "rtk git push --force origin main" "rtk git push -f origin main" \
            "/usr/local/bin/rtk git push --force origin main" "command rtk git push --force origin main" \
            "rtk -v git push --force origin main" "rtk proxy git push --force origin main" \
            "rtk run git push --force-with-lease origin main" "cd /tmp && rtk git push --force origin main" \
            "rtk git push origin --delete feature" "rtk git push origin :refs/heads/x" \
            "rtk git branch -D feature" "rtk git commit --no-verify -m x" "rtk git filter-repo --force" \
            'rtk rm -rf $HOME/OPS' 'cd /tmp; rtk rm -rf ~' "rtk tmux kill-server" "rtk pkill tmux"; do
  probe "git-guard blocks behind rtk: $form" 2 git-guard.sh <<< "$(cmdj "$form")"
done
for form in "rtk git status" "rtk git log --oneline -5" "rtk git branch -d merged-branch" \
            "rtk tmux -S /tmp/sock kill-server" "rtk rm -rf /tmp/scratch-dir"; do
  probe "git-guard allows behind rtk: $form" 0 git-guard.sh <<< "$(cmdj "$form")"
done
probe "git-guard allows a plain push from a project repo (fixture check)" 0 git-guard.sh <<< "$(cmdj "git push origin main")"
rm -rf "$RTKREPO"
# secrets-guard fails closed: a payload it cannot read (no file_path) is not
# empty content, so the pre scan blocks it rather than pass an unscanned write.
probe "secrets-guard blocks a payload with no file_path" 2 secrets-guard.sh pre <<J
{"tool_name":"Write","tool_input":{"content":"$KEYHDR"}}
J
probe "secrets-guard leaves an unguarded path alone" 0 secrets-guard.sh pre <<J
{"tool_name":"Write","tool_input":{"file_path":"/x/src/app.py","content":"$KEYHDR"}}
J

# --- Push gate for an OPS copy (git-guard.sh, end of file) ---------------------
# Fixture repos in a temp dir: an OPS copy is any repo whose root holds
# .claude-config/bin/origin-private-check (the real gate is copied in). gh is a
# stub answering $GH_STUB, so no case touches the network.
PG="$(mktemp -d "${TMPDIR:-/tmp}/guard-selftest.XXXXXX")"
trap 'rm -rf "$PG"' EXIT
mkdir -p "$PG/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$GH_STUB"\n' > "$PG/bin/gh"; chmod +x "$PG/bin/gh"
GATE_SRC="$DIR/../bin/origin-private-check"
mkrepo() {  # mkrepo <name> <origin-url> ops|plain|empty-gate
  local r="$PG/$1"
  git init -q "$r" && git -C "$r" remote add origin "$2"
  if [ "$3" != plain ]; then
    mkdir -p "$r/.claude-config/bin"
    if [ "$3" = ops ]; then cp "$GATE_SRC" "$r/.claude-config/bin/origin-private-check"
    else : > "$r/.claude-config/bin/origin-private-check"; fi
  fi
}
mkrepo ops-template https://github.com/Exploitacious/OPS.git ops
mkrepo ops-public   https://github.com/acme/ops-public.git ops
mkrepo ops-private  https://github.com/acme/ops-copy.git ops
mkrepo ops-empty    https://github.com/acme/ops-copy.git empty-gate
mkrepo proj         https://github.com/Exploitacious/OPS.git plain
git -C "$PG/ops-private" remote add backup https://github.com/acme/elsewhere.git
export GH_STUB=true
OLDPATH="$PATH"; export PATH="$PG/bin:$PATH"
T="$PG/ops-template"
probe "push gate blocks an OPS copy whose origin is the template" 2 git-guard.sh <<J
{"tool_name":"Bash","cwd":"$T","tool_input":{"command":"git push origin main"}}
J
probe "push gate blocks it through git -C from elsewhere"         2 git-guard.sh <<J
{"tool_name":"Bash","cwd":"$PG","tool_input":{"command":"git -C $T push"}}
J
probe "push gate blocks it through cd <dir> && git push"         2 git-guard.sh <<J
{"tool_name":"Bash","cwd":"/","tool_input":{"command":"cd $T && git add -A && git push"}}
J
probe "push gate blocks it behind an rtk prefix"                 2 git-guard.sh <<J
{"tool_name":"Bash","cwd":"$T","tool_input":{"command":"rtk git push"}}
J
GH_STUB=false probe "push gate blocks an OPS copy GitHub reports public" 2 git-guard.sh <<J
{"tool_name":"Bash","cwd":"$PG/ops-public","tool_input":{"command":"git push"}}
J
probe "push gate allows an OPS copy with a private origin (stub)" 0 git-guard.sh <<J
{"tool_name":"Bash","cwd":"$PG/ops-private","tool_input":{"command":"git commit -qm x && git push origin HEAD"}}
J
probe "push gate blocks the private copy pushing to another remote" 2 git-guard.sh <<J
{"tool_name":"Bash","cwd":"$PG/ops-private","tool_input":{"command":"git push backup main"}}
J
probe "push gate blocks an OPS copy whose gate file is empty"    2 git-guard.sh <<J
{"tool_name":"Bash","cwd":"$PG/ops-empty","tool_input":{"command":"git push"}}
J
probe "push gate leaves a non-OPS repo alone"                    0 git-guard.sh <<J
{"tool_name":"Bash","cwd":"$PG/proj","tool_input":{"command":"git push origin main"}}
J
probe "push gate leaves git -C <non-OPS> push from an OPS cwd"   0 git-guard.sh <<J
{"tool_name":"Bash","cwd":"$T","tool_input":{"command":"git -C $PG/proj push"}}
J
probe "push gate honors the GIT_GUARD=off first-token override"  0 git-guard.sh <<J
{"tool_name":"Bash","cwd":"$T","tool_input":{"command":"GIT_GUARD=off git push origin main"}}
J

# pc <label> <want> <cwd> <command>: a push-gate probe whose payload is built by
# a JSON encoder, so quotes, backslashes and newlines reach the hook intact.
payload() {
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg d "$1" --arg c "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'
  else
    python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1], "tool_input": {"command": sys.argv[2]}}))' "$1" "$2"
  fi
}
# A here-string, not a pipe: probe must run in this shell to count a failure.
pc() { probe "${1//$'\n'/\\n}" "$2" git-guard.sh <<< "$(payload "$3" "$4")"; }
P="$PG/ops-private"

# A redirection after a push with no explicit remote is not the remote
# (2026-10-19: `git push 2>&1` read '2' as the remote and blocked a verified
# copy). Each form: allowed on the private copy, blocked on the template copy.
for form in 'git push 2>&1' 'git push 1>&2' 'git push >&2' 'git push &>/dev/null' 'git push 2>/dev/null' \
            'git push | tail -1' 'git push; echo $?' 'git push --porcelain 2>&1 | tail -3' 'git push >/dev/null 2>&1'; do
  pc "redirect form allowed on a private copy: $form" 0 "$P" "$form"
  pc "redirect form blocked on the template copy: $form" 2 "$T" "$form"
done

# Settings that move a push are refused on an OPS copy, even a private one: the
# gate checks the configured origin, not a command-line override.
for form in 'git -c remote.origin.pushurl=https://github.com/Exploitacious/OPS.git push origin main' \
            'git -c remote.pushDefault=backup push' 'git -c branch.main.remote=backup push' \
            'git -c branch.main.pushRemote=backup push' 'git -c push.default=matching push' \
            'git -c url.https://github.com/acme/elsewhere.git.pushInsteadOf=https://github.com/acme/ops-copy.git push origin main' \
            'PUB=x git --config-env=remote.origin.pushurl=PUB push origin main' \
            'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.pushurl GIT_CONFIG_VALUE_0=x git push origin main' \
            'GIT_CONFIG_GLOBAL=/tmp/other.gitconfig git push origin main'; do
  pc "push override blocked on a private copy: $form" 2 "$P" "$form"
done
pc "an unrelated -c setting does not block a private push" 0 "$P" "git -c core.quotepath=false push origin main"
printf '[remote "origin"]\n  pushurl = https://github.com/Exploitacious/OPS.git\n[alias]\n  included-publish = push origin main\n' > "$PG/push-override.config"
# Verify the realistic input changes Git's destination, using reads only.
for form in "include.path=$PG/push-override.config" "includeIf.gitdir:$P/.git.path=$PG/push-override.config"; do
  if [ "$(git -C "$P" -c "$form" remote get-url --push origin)" != https://github.com/Exploitacious/OPS.git ]; then
    printf '  FAIL  config include fixture does not move the push destination\n'; fails=$((fails + 1))
  fi
  pc "a config include cannot move a private push past the gate: $form" 2 "$P" "git -c '$form' push origin main"
done
pc "a push alias defined in a command-line include is inspected" 2 "$P" "git -c include.path=$PG/push-override.config included-publish"
pc "a push alias in an alternate config file is inspected" 2 "$P" "GIT_CONFIG_GLOBAL=$PG/push-override.config git included-publish"
pc "a shell alias inherits a push destination override" 2 "$P" "git -c remote.origin.pushurl=https://github.com/Exploitacious/OPS.git -c 'alias.publish=!git push origin main' publish"
pc "an ordinary shell push alias still works on a private copy" 0 "$P" "git -c 'alias.publish=!git push origin main' publish"
mkdir -p "$P/sub"
pc "a shell alias runs from the repository root, even from a subdirectory" 2 "$P/sub" "git -c 'alias.publish=!git -C ../ops-template push origin main' publish"
pc "an environment-supplied push alias is still gated" 2 "$T" "PUSH_ALIAS='push origin main' git --config-env=alias.publish=PUSH_ALIAS publish"
pc "an environment-supplied shell push alias is still gated" 2 "$T" "PUSH_ALIAS='!git push origin main' git --config-env=alias.publish=PUSH_ALIAS publish"
pc "an environment-supplied push alias works on a private copy" 0 "$P" "PUSH_ALIAS='push origin main' git --config-env=alias.publish=PUSH_ALIAS publish"
pc "a shell alias inherits other command-line aliases" 2 "$T" "git -c 'alias.publish=!git nested-publish' -c 'alias.nested-publish=push origin main' publish"
pc "global options inside an alias cannot move a push past the gate" 2 "$P" "git -c 'alias.publish=-c remote.origin.pushurl=https://github.com/Exploitacious/OPS.git push origin main' publish"
pc "an alias with an unrelated global option still works" 0 "$P" "git -c 'alias.publish=-c core.quotepath=false push origin main' publish"
pc "an alias cannot shadow the push builtin on the template copy" 2 "$T" "git -c alias.push=status push origin main"
pc "an ignored alias for the push builtin does not block a private push" 0 "$P" "git -c 'alias.push=push backup' push origin main"
git -C "$T" config alias.config-file-publish 'push origin main'
: > "$PG/empty.gitconfig"
pc "GIT_CONFIG cannot hide a real push alias from the config read" 2 "$T" "GIT_CONFIG=$PG/empty.gitconfig git config-file-publish"
pc "a remote change in the same command blocks the push" 2 "$P" "git remote set-url origin https://github.com/acme/elsewhere.git && git push origin main"
pc "adding a config include before a push makes the gate stale" 2 "$P" "git config include.path $PG/push-override.config && git push origin main"
pc "a self-approval in the same command blocks the push" 2 "$P" "git config ops.pushVerified true && git push origin main"
pc "reading the remotes first does not block the push" 0 "$P" "git remote -v && git push origin main"
pc "send-pack from an OPS copy is a push (blocked even when private)" 2 "$P" "git send-pack https://github.com/acme/elsewhere.git main"
pc "send-pack through git -C from elsewhere is blocked" 2 "$PG/proj" "git -C $T send-pack https://github.com/acme/elsewhere.git main"

# The alias lookup never runs with the command's own environment: a PATH (or
# LD_PRELOAD) it sets must not choose code the hook executes.
mkdir -p "$PG/evil"
printf '#!/bin/sh\necho ran >> "%s/evil/marker"\nexec "%s" "$@"\n' "$PG" "$(command -v git)" > "$PG/evil/git"; chmod +x "$PG/evil/git"
pc "an unknown subcommand with a PATH prefix is allowed" 0 "$PG/proj" "PATH=$PG/evil:\$PATH git frobnicate"
if [ -e "$PG/evil/marker" ]; then
  printf '  FAIL  the hook ran the git the command put on PATH\n'; fails=$((fails + 1))
else
  printf '  PASS  the hook never runs the git the command put on PATH\n'
fi

# Forms that reach the template copy from elsewhere; each must be blocked.
mkdir -p "$T/sub"; [ "$gs_msys" = 1 ] || ln -s "$T/sub" "$PG/lnk-sub"
git -C "$T" config alias.p push
for form in "git --git-dir=$T/.git push origin main" "GIT_DIR=$T/.git git push origin main" \
            "git --git-dir=$T/.git --work-tree=$T push" "export GIT_DIR=$T/.git; git push origin main" \
            "bash <<< 'git -C $T push origin main'" "echo 'git -C $T push origin main' | bash" \
            "printf '%s\n' 'git -C $T push' | sh" $'cat <<EOF | bash\ngit -C '"$T"$' push\nEOF' \
            "rtk err git -C $T push" "rtk summary git -C $T push" "rtk bypass git -C $T push" \
            "rtk proxy git -C $T push" "rtk run git -C $T push" "rtk run -c 'git -C $T push'" \
            "bash --norc -c 'git -C $T push'" "bash --noprofile --norc -c 'git -C $T push'" \
            "bash --rcfile /dev/null -c 'git -C $T push'" "bash -lc 'git -C $T push'" \
            "out=\"\$(git -C $T push 2>&1)\"; echo \"\$out\" | tail -1" "echo \"result: \$(git -C $T push)\"" \
            "echo \`git -C $T push\`" "for d in $T; do git -C \$d push; done" "d=$T; cd \$d && git push" \
            "echo $T | xargs -I{} git -C {} push origin main" "cd .. && cd ops-template && git push" \
            "git -C $PG/lnk-sub/.. push" "cd $PG/lnk-sub && git -C .. push" "git p"; do
  case "$form" in "cd .. && cd ops-template"*) cwd="$PG/proj" ;; "git p") cwd="$T" ;; *) cwd="$PG/proj" ;; esac
  case "$gs_msys:$form" in 1:*lnk-sub*) printf '  SKIP  reaches the template copy: %s (needs a directory link; Git Bash copies)\n' "$form"; continue ;; esac
  pc "reaches the template copy, blocked: $form" 2 "$cwd" "$form"
done
pc "cd - returns to the template copy, blocked" 2 "$T" "cd $PG/proj; cd -; git push"
# A worktree checked out at a commit without the gate shares the copy's remotes.
W2="$PG/ops-wt"
git init -q "$W2" && git -C "$W2" remote add origin https://github.com/Exploitacious/OPS.git
echo base > "$W2/README.md"; git -C "$W2" add README.md
git -C "$W2" -c user.name=t -c user.email=t@example.invalid commit -qm base
mkdir -p "$W2/.claude-config/bin"; cp "$GATE_SRC" "$W2/.claude-config/bin/origin-private-check"
git -C "$W2" add -A && git -C "$W2" -c user.name=t -c user.email=t@example.invalid commit -qm gate
git -C "$W2" worktree add -q --detach "$PG/wt-old" HEAD~1
pc "a worktree of the template copy without the gate file is still gated" 2 "$PG/wt-old" "git push origin HEAD:main"
# Nesting beyond what the parser follows falls back to the fail-safe check.
nested="git -C $T push"; for _ in 1 2 3 4 5 6 7 8 9 10; do nested="bash -c $(printf '%q' "$nested")"; done
pc "a push nested past the parse limit is still blocked" 2 "$PG/proj" "$nested"
pc "an untokenizable command naming the copy is still blocked" 2 "$PG/proj" "git -C $T push 'unterminated"

# No false blocks: mentions, other repos, and plain non-push git.
pc "a commit message mentioning push is not a push" 0 "$T" "git commit -qm 'push the fix later'"
pc "echoing a push command is not a push" 0 "$T" "echo 'git push origin main'"
pc "a project push with a redirect from the OPS cwd is left alone" 0 "$T" "git -C $PG/proj push 2>&1 | tail -1"
pc "--git-dir of a non-OPS repo from the OPS cwd is left alone" 0 "$T" "git --git-dir=$PG/proj/.git push origin main"
pc "the private copy pushed from a subshell with a redirect" 0 "$PG/proj" "(cd $P && git push origin main 2>&1)"

# Shell text a plain shlex pass misreads. A "#" inside ${#x} or ${x#y} must not
# start a comment (that would drop the push after it, unseen), and a script's own
# option holding a "c" is not bash -c (its quoted operand is data, not a command).
for form in "b=\${ref#refs/heads/}; git -C $T push origin main" "echo \${#msg} && git -C $T push origin main" \
            "for p in a:b; do id=\${p#*:}; git -C $T push origin main; done" \
            "s=\"docs: x\" && echo \${#s} && git -C $T push origin main"; do
  pc "a push after a \${...#...} expansion is still seen: $form" 2 "$PG/proj" "$form"
done
pc "a script's --claim option is not bash -c" 0 "$PG/proj" "bash scripts/review.sh --claim 'git -C $T push origin main'"
# Spellings of git the raw text does not show: a NUL ends a $'...' string as
# bash ends it (so the word is still git), escapes spell letters, and quotes or
# backslashes split the word. A case statement inside $(...) cannot be read,
# so it goes to the fail-safe check. Each pushes from the template copy, so
# each must be blocked; before the fix each one passed unseen.
BS='\'
for form in "\$'git${BS}0suffix' push origin main" "gi\$'t${BS}x00suffix' push origin main" \
            "\$'git${BS}400suffix' push origin main" "\$'${BS}x67it' push origin main" \
            "\$'${BS}u0067it' push origin main" \
            'g"i"t push origin main' "'g'it push origin main" "g${BS}it push origin main" \
            'echo "$(case x in x) git push origin main;; esac)"'; do
  pc "a push the raw text does not spell is still seen: $form" 2 "$T" "$form"
done
pc "a case statement inside \$(...) with no push passes" 0 "$T" 'x=$(case y in a) echo 1;; esac) && git status'

# A command that names no git starts no Python: the parse is skipped, so text
# the parser cannot read never blocks it. A logging python3 first on PATH
# proves it by count, and that a git command still parses.
pf_dir="$PG/pf" pf_log="$PG/pf-calls"
if pf_real="$(command -v python3)" && mkdir -p "$pf_dir" &&
   printf '#!/bin/sh\necho run >> "%s"\nexec "%s" "$@"\n' "$pf_log" "$pf_real" > "$pf_dir/python3" && chmod +x "$pf_dir/python3"; then
  : > "$pf_log"
  PATH="$pf_dir:$PATH" pc "a no-git command with an unbalanced quote passes" 0 "$PG/proj" "echo \"it's\" && echo 'unbalanced"
  if [ ! -s "$pf_log" ]; then printf '  PASS  git-guard starts no Python for a command with no git\n'
  else printf '  FAIL  git-guard started Python %s time(s) for a no-git command\n' "$(wc -l < "$pf_log")"; fails=$((fails + 1)); fi
  PATH="$pf_dir:$PATH" pc "a git command still parses" 0 "$PG/proj" "git status"
  if [ -s "$pf_log" ]; then printf '  PASS  git-guard starts Python for a git command\n'
  else printf '  FAIL  git-guard started no Python for a git command (the parse was skipped)\n'; fails=$((fails + 1)); fi
else
  printf '  SKIP  prefilter probes (no python3 to wrap)\n'
fi

# --- Conflict markers (git-guard.sh, "Conflict markers") -----------------------
# A commit that would record a line-start merge conflict marker gets a warning,
# here often before git add has staged it; a clean commit gets none. The check
# never blocks (git-guard.sh, "Conflict markers": a commit is the owner's
# content), so every case below wants exit 0, and pcm sorts the hook's stdout:
# warn (the hits warning), uninspectable (the could-not-inspect warning) or
# quiet (no output). Marker lines are built with printf, never written out:
# git-guard reads heredoc bodies too, and this file is itself committed.
mk7() { printf "$1%.0s" 1 2 3 4 5 6 7; }
MK_L="$(mk7 '<')" MK_E="$(mk7 '=')" MK_G="$(mk7 '>')"
mkm() {  # mkm <name>: a fresh repo with one commit, at $PG/mk-<name>
  local r="$PG/mk-$1"
  git init -q "$r" && git -C "$r" config user.name t && git -C "$r" config user.email t@example.invalid &&
    printf 'base\n' > "$r/other.md" && git -C "$r" add other.md && git -C "$r" commit -qm base
}
conflict() { printf 'top\n%s HEAD\nours\n%s\ntheirs\n%s branch\nbottom\n' "$MK_L" "$MK_E" "$MK_G"; }
mk_ok=1
# R1: a clean file staged, a conflicted file untracked.
mkm r1 && printf 'fine\n' > "$PG/mk-r1/clean.md" && git -C "$PG/mk-r1" add clean.md &&
  conflict > "$PG/mk-r1/conflicted.md" || mk_ok=0
# R2: the conflicted file staged, other.md changed but not staged.
mkm r2 && conflict > "$PG/mk-r2/conflicted.md" && git -C "$PG/mk-r2" add conflicted.md &&
  printf 'changed\n' > "$PG/mk-r2/other.md" || mk_ok=0
# R3: precision. Eight characters, a reStructuredText table border, a mid-line
# marker, and seven-character markers in a path whose conflict-marker-size is 8.
mkm r3 && printf '%s\n%s =====\nA       B\nsee %s here\n' "$(mk7 '<')<" "$MK_E" "$MK_L" > "$PG/mk-r3/precise.md" &&
  printf 'fixture.txt conflict-marker-size=8\n' > "$PG/mk-r3/.gitattributes" && conflict > "$PG/mk-r3/fixture.txt" &&
  git -C "$PG/mk-r3" add -A || mk_ok=0
# R4: the attribute the other way: eight-character markers in a size-8 path.
mkm r4 && printf 'fixture.txt conflict-marker-size=8\n' > "$PG/mk-r4/.gitattributes" &&
  printf 'a\n%s< HEAD\nb\n' "$MK_L" > "$PG/mk-r4/fixture.txt" && git -C "$PG/mk-r4" add -A || mk_ok=0
# R5: markers already in HEAD (committed without the hook), nothing staged.
mkm r5 && conflict > "$PG/mk-r5/conflicted.md" && git -C "$PG/mk-r5" add conflicted.md &&
  git -C "$PG/mk-r5" commit -qm "with markers" || mk_ok=0
# R6: an index file git cannot read.
mkm r6 && printf 'not an index\n' > "$PG/mk-r6/bad-index" || mk_ok=0
[ "$mk_ok" = 1 ] || { printf '  FAIL  conflict-marker fixtures (could not build the temp repos)\n'; fails=$((fails + 1)); }
R1="$PG/mk-r1" R2="$PG/mk-r2"
pcm() {  # pcm <label> warn|uninspectable|quiet <cwd> <command>
  local label="${1//$'\n'/\\n}" want="$2" out rc got
  out="$(payload "$3" "$4" | "$DIR/git-guard.sh" 2>/dev/null)"; rc=$?
  case "$out" in
    '') got=quiet ;;
    *'WARNING (conflict markers): cannot inspect'*) got=uninspectable ;;
    *'WARNING (conflict markers)'*) got=warn ;;
    *) got=other ;;
  esac
  if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then
    printf '  PASS  %s (exit 0, %s)\n' "$label" "$got"
  else
    printf '  FAIL  %s (exit %s, %s; want exit 0, %s)\n' "$label" "$rc" "$got" "$want"
    fails=$((fails + 1))
  fi
}
pcm "markers: a clean commit is quiet" quiet "$R1" "git commit -qm x"
pcm "markers: git add then commit in one call warns" warn "$R1" "git add conflicted.md && git commit -qm x"
pcm "markers: git add -A then commit warns" warn "$R1" "git add -A && git commit -qm x"
pcm "markers: commit -a leaves an untracked file out" quiet "$R1" "git commit -a -qm x"
pcm "markers: the \${#s} commit-length idiom is still checked" warn "$R1" 's="docs(x): y" && echo ${#s} && git add conflicted.md && git commit -q -m "$s"'
pcm "markers: a commit inside bash -c is checked" warn "$R1" "bash -c 'git add conflicted.md && git commit -qm x'"
pcm "markers: a script piped to bash is checked" warn "$R1" "echo 'git add conflicted.md && git commit -qm x' | bash"
pcm "markers: a commit through an alias is checked" warn "$R1" "git add conflicted.md && git -c alias.ci=commit ci -qm x"
pcm "markers: git -C <repo> from elsewhere is checked" warn "$PG" "git -C $R1 add conflicted.md && git -C $R1 commit -qm x"
pcm "markers: GIT_GUARD=off skips the check for the one command" quiet "$R1" "GIT_GUARD=off git add conflicted.md && git commit -qm x"
pcm "markers: a staged marker warns" warn "$R2" "git commit -qm x"
pcm "markers: commit <path> without -i leaves the index out" quiet "$R2" "git commit -qm x other.md"
pcm "markers: commit -i <path> still records the index" warn "$R2" "git commit -i -qm x other.md"
pcm "markers: merge --continue records the index" warn "$R2" "git merge --continue"
pcm "markers: --dry-run records nothing" quiet "$R2" "git commit --dry-run -m x"
pcm "markers: a git add with no commit is not checked" quiet "$R2" "git add other.md"
pcm "markers: eight characters, a table border, a mid-line marker and a raised marker size are quiet" quiet "$PG/mk-r3" "git commit -qm x"
pcm "markers: a raised conflict-marker-size is honored both ways" warn "$PG/mk-r4" "git commit -qm x"
pcm "markers: an amend cannot carry markers its commit had" warn "$PG/mk-r5" "git commit --amend -qm y"
pcm "markers: a plain commit on top of that HEAD records nothing new" quiet "$PG/mk-r5" "git commit --allow-empty -qm z"
pcm "markers: an index git cannot read warns that it could not inspect" uninspectable "$PG/mk-r6" "GIT_INDEX_FILE=$PG/mk-r6/bad-index git commit -qm x"
pcm "markers: a commit the parser cannot read falls back to the staged diff" warn "$R2" "git commit -qm 'unterminated"
pcm "markers: unreadable text with no commit is not checked" quiet "$R2" "git status; echo 'unterminated"
# The warning is PreToolUse JSON Claude reads (additionalContext, with a
# systemMessage for the Operator), names the file and line, and says to split
# the call when an earlier step in it may change files.
mk_out="$(payload "$R1" "touch x.md && git add conflicted.md && git commit -qm x" | "$DIR/git-guard.sh" 2>/dev/null)"
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  markers: the warning's JSON shape (jq not installed)"
elif printf '%s' "$mk_out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and (.systemMessage | type) == "string"
    and (.hookSpecificOutput.additionalContext | test("conflicted.md:2:") and test("in its own Bash call") and test("not stopped"))' >/dev/null 2>&1; then
  printf '  PASS  markers: the warning is PreToolUse additionalContext naming file:line and the split-the-call advice\n'
else
  printf '  FAIL  markers: the warning is PreToolUse additionalContext naming file:line and the split-the-call advice (got: %s)\n' "$(printf '%s' "$mk_out" | head -c 300)"
  fails=$((fails + 1))
fi
# Without jq the hook reads the call with Python, and the same Python builds the
# warning's JSON (mk_emit's fallback). A PATH of links with no jq proves it.
if [ "$gs_msys" = 1 ]; then
  echo "  SKIP  markers: the warning's JSON without jq (needs a PATH of links; Git Bash copies)"
elif command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  mkdir -p "$PG/nojq"
  for tool in bash env cat sed grep git dirname tr awk timeout head tail cut; do
    t="$(command -v "$tool")" && ln -s "$t" "$PG/nojq/$tool"
  done
  ln -s "$(readlink -f "$(command -v python3)")" "$PG/nojq/python3"
  mk_out="$(payload "$R1" "git add conflicted.md && git commit -qm x" | PATH="$PG/nojq" "$DIR/git-guard.sh" 2>/dev/null)"; mk_rc=$?
  if [ "$mk_rc" = 0 ] && printf '%s' "$mk_out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
      and (.hookSpecificOutput.additionalContext | test("conflicted.md:2:"))' >/dev/null 2>&1; then
    printf '  PASS  markers: without jq the warning is still PreToolUse JSON (exit 0)\n'
  else
    printf '  FAIL  markers: without jq the warning is still PreToolUse JSON (exit %s, got: %s)\n' "$mk_rc" "$(printf '%s' "$mk_out" | head -c 300)"
    fails=$((fails + 1))
  fi
else
  echo "  SKIP  markers: the warning's JSON without jq (needs jq to read it back and python3 to make it)"
fi
# Without Python 3 the gate falls back to the raw command: a push word plus any
# OPS copy it touches (the cwd, or a directory named anywhere in it) runs that
# copy's gate. A PATH with the tools the hook and gate use, but no python, proves
# it (it needs jq, the harness's JSON parser, to read the call).
if [ "$gs_msys" = 1 ]; then
  echo "  SKIP  push gate fallback without python (needs a PATH of links; Git Bash copies)"
elif command -v jq >/dev/null 2>&1; then
  mkdir -p "$PG/nopy"
  for tool in bash env cat sed grep git jq dirname tr awk timeout head cut; do
    t="$(command -v "$tool")" && ln -s "$t" "$PG/nopy/$tool"
  done
  ln -s "$PG/bin/gh" "$PG/nopy/gh"
  PATH="$PG/nopy" probe "push gate without python blocks git -C <OPS copy> push" 2 git-guard.sh <<J
{"tool_name":"Bash","cwd":"$PG/proj","tool_input":{"command":"git -C $T push"}}
J
  PATH="$PG/nopy" probe "push gate without python leaves a non-OPS push alone" 0 git-guard.sh <<J
{"tool_name":"Bash","cwd":"$PG/proj","tool_input":{"command":"git push origin main"}}
J
  # The fallback reads the raw command, quotes kept, and every directory it names.
  for form in "bash -c 'git -C $T push'" "sh -c \"git -C $T push\"" "eval 'git -C $T push'" \
              "timeout 30 git -C $T push" "xargs git -C $T push" "{ git -C $T push; }" \
              "if true; then git -C $T push; fi" "! git -C $T push" "env -C $T git push" \
              "env --chdir=$T git push" "git --git-dir=$T/.git push" "bash <<< 'git -C $T push'" \
              "git -C $T send-pack https://github.com/acme/elsewhere.git main" "cd .. && cd ops-template && git push"; do
    PATH="$PG/nopy" pc "without python, blocked: $form" 2 "$PG/proj" "$form"
  done
  PATH="$PG/nopy" pc "without python, a push alias of the copy is blocked" 2 "$T" "git p"
  PATH="$PG/nopy" pc "without python, a private copy's push 2>&1 is allowed" 0 "$P" "git push 2>&1 | tail -1"
  PATH="$PG/nopy" pc "without python, non-push git on the template copy is allowed" 0 "$T" "git status && git log -1"
  # The conflict-marker check needs Python; without it a commit is never refused
  # wholesale (git-guard.sh, "Conflict markers": no false blocks on such a box).
  PATH="$PG/nopy" pc "without python, a clean commit is allowed" 0 "$R1" "git commit -qm x"
else
  echo "  SKIP  push gate fallback without python (jq not installed)"
fi
export PATH="$OLDPATH"

# --quick is the deploy canary: it must pass here, fail when a guard it probes
# is dead (a copy of the hooks whose git-guard.sh is `exit 0`), and refuse an
# unknown flag, also after --quick.
q_out="$(bash "$DIR/guard-selftest.sh" --quick 2>&1)"; q_rc=$?
case "$q_rc:$q_out" in
  0:*"--quick: ALL GUARDS ENFORCE"*) printf '  PASS  --quick passes on the live guards\n' ;;
  *) printf '  FAIL  --quick on the live guards (exit %s)\n' "$q_rc"; fails=$((fails + 1)) ;;
esac
q_dead="$PG/quick-dead"
# -L copies what a link points at, and the rm before the write keeps a copied
# link from carrying the stub into the real hook.
if mkdir -p "$q_dead" && cp -RL "$DIR/." "$q_dead/" && rm -f "$q_dead/git-guard.sh" &&
   printf '#!/usr/bin/env bash\nexit 0\n' > "$q_dead/git-guard.sh" && chmod +x "$q_dead/git-guard.sh"; then
  bash "$q_dead/guard-selftest.sh" --quick >/dev/null 2>&1; q_rc=$?
  if [ "$q_rc" = 1 ]; then printf '  PASS  --quick fails when git-guard is dead (exit 1)\n'
  else printf '  FAIL  --quick with a dead git-guard (exit %s, want 1)\n' "$q_rc"; fails=$((fails + 1)); fi
else
  printf '  FAIL  --quick dead-guard probe: could not copy the hooks\n'; fails=$((fails + 1))
fi
bash "$DIR/guard-selftest.sh" --bogus >/dev/null 2>&1; q_rc=$?
if [ "$q_rc" = 2 ]; then printf '  PASS  an unknown flag is refused (exit 2)\n'
else printf '  FAIL  an unknown flag (exit %s, want 2)\n' "$q_rc"; fails=$((fails + 1)); fi
bash "$DIR/guard-selftest.sh" --quick --bogus >/dev/null 2>&1; q_rc=$?
if [ "$q_rc" = 2 ]; then printf '  PASS  --quick refuses a trailing unknown flag (exit 2)\n'
else printf '  FAIL  --quick with a trailing unknown flag (exit %s, want 2)\n' "$q_rc"; fails=$((fails + 1)); fi

if [ "$fails" -eq 0 ]; then
  echo "guard-selftest: ALL GUARDS ENFORCE"
  exit 0
else
  echo "guard-selftest: $fails guard(s) NOT enforcing: is jq installed? are the hooks executable (100755)?"
  exit 1
fi
