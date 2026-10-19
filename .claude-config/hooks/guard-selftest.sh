#!/usr/bin/env bash
# guard-selftest.sh: prove the security guards actually BLOCK (fail-closed),
# not silently allow (fail-open). Run it after deploying the hooks and any
# time by hand. On Windows this is the canary that the jq-based extractor is
# live and python3's absence no longer disables the hard gates.
#
# Exit 0 = every guard enforces as expected; 1 = a guard is dead/misbehaving.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0

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
probe "secrets-guard blocks secret->memory"  2 secrets-guard.sh pre <<'J'
{"tool_input":{"file_path":"/x/memory/note.md","content":"-----BEGIN OPENSSH PRIVATE KEY-----"}}
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
mkdir -p "$T/sub"; ln -s "$T/sub" "$PG/lnk-sub"
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
# Without Python 3 the gate falls back to the raw command: a push word plus any
# OPS copy it touches (the cwd, or a directory named anywhere in it) runs that
# copy's gate. A PATH with the tools the hook and gate use, but no python, proves
# it (it needs jq, the harness's JSON parser, to read the call).
if command -v jq >/dev/null 2>&1; then
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
else
  echo "  SKIP  push gate fallback without python (jq not installed)"
fi
export PATH="$OLDPATH"

if [ "$fails" -eq 0 ]; then
  echo "guard-selftest: ALL GUARDS ENFORCE"
  exit 0
else
  echo "guard-selftest: $fails guard(s) NOT enforcing: is jq installed? are the hooks executable (100755)?"
  exit 1
fi
