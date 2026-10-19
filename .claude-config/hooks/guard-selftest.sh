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
# Without Python 3 the gate falls back to every directory the command names.
# A PATH with the tools the hook and gate use, but no python, proves it never
# skips an OPS copy (it needs jq, the harness's JSON parser, to read the call).
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
