#!/usr/bin/env bash
# session-briefing-scope-test.sh: the briefing speaks only about what the thread
# can act on, and says so when a probe fails (hooks/session-briefing.sh).
#
# Pinned:
#   Repo line (the parked project root). A thread that starts in a repo's MAIN
#     checkout works on whatever that checkout has checked out, so the briefing says
#     when it is on a branch other than the repo's default (origin/HEAD, else main,
#     else master) or behind the remote-tracking default; it says nothing on the
#     default branch when not behind, in a linked worktree (parked on purpose), or
#     outside any repo; it uses local refs only (no fetch); and a probe that fails
#     says so instead of printing nothing, because a silent probe reads as clean.
#   Unadopted memory pools. A real (non-symlink) memory dir under the profile's
#     projects/ means git-sync misses it, so the Hygiene line names the first one; a
#     symlinked pool, an EMPTY pool, a "-tmp*" project and a T3 "No project" scratch
#     thread (cwd under ~/.t3/scratch/, spelled with the dot kept or turned into "-")
#     are not named.
#
# Every path is under a temp dir; HOME and the profile are fixtures. The briefing
# starts no scan here (the fixture has no session stamp). The suite still refuses to
# run outside the sandbox: its pool fixtures name the memory-init tool, and a suite
# that names one of the destructive tools carries the guard (verify-ops check 24).
#
# Usage: session-briefing-scope-test.sh    (exit 0 all pass, 1 otherwise)
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
HOOK="$HERE/../../hooks/session-briefing.sh"
[ -f "$HOOK" ] || { echo "FAIL: the hook is missing"; exit 1; }
command -v git >/dev/null || { echo "FAIL: git required"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required (the hooks' own parser)"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }

echo "session-briefing-scope-test:"
mkdir -p "$T/home" "$T/cfg/projects" "$T/ops/CONTEXT"
printf '# Core\n' > "$T/ops/CONTEXT/core.md"
GIT=(git -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false -c init.defaultBranch=main)

# run_in <dir> [VAR=value ...]: the briefing from <dir>; stdout in $out.
run_in() {
  local dir="$1"; shift
  out="$(cd "$dir" && env -u TMUX -u T3CODE_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u OPS_LANE_CLASS -u T3CODE_HOME \
      HOME="$T/home" OPS_DIR="$T/ops" CLAUDE_CONFIG_DIR="$T/cfg" LANE_CLASS_NO_DB=1 GIT_CONFIG_NOSYSTEM=1 \
      "$@" bash "$HOOK" </dev/null 2>"$T/err")"
}
repo_line() { printf '%s\n' "$out" | grep '^ Repo:' || true; }

# --- the Repo line -------------------------------------------------------------------
mkdir -p "$T/plain"
run_in "$T/plain"
[ -z "$(repo_line)" ] && ok "outside any repo: no Repo line, no git run" || bad "a cwd under no repo printed: $(repo_line)"

# a main checkout on its default branch, no remote
R="$T/proj"; mkdir -p "$R"; "${GIT[@]}" -C "$R" init -q .; "${GIT[@]}" -C "$R" commit -q --allow-empty -m first
run_in "$R"
[ -z "$(repo_line)" ] && ok "on the default branch with no remote: quiet" || bad "default branch printed: $(repo_line)"
mkdir -p "$R/sub/dir"; run_in "$R/sub/dir"
[ -z "$(repo_line)" ] && ok "a subdirectory of the default branch: quiet" || bad "subdirectory printed: $(repo_line)"

# a feature branch
"${GIT[@]}" -C "$R" checkout -q -b feature/parked
run_in "$R"
case "$(repo_line)" in *"proj is on feature/parked, not main (local refs, no fetch)"*) ok "on a feature branch: named, with the default and the local-refs note" ;; *) bad "feature branch line: '$(repo_line)'" ;; esac
"${GIT[@]}" -C "$R" checkout -q --detach
run_in "$R"
case "$(repo_line)" in *"proj is on a detached HEAD, not main"*) ok "a detached HEAD: named" ;; *) bad "detached HEAD line: '$(repo_line)'" ;; esac
"${GIT[@]}" -C "$R" checkout -q main

# a linked worktree is parked on purpose: silent
"${GIT[@]}" -C "$R" worktree add -q -b task/x "$T/proj-wt" >/dev/null 2>&1
run_in "$T/proj-wt"
[ -z "$(repo_line)" ] && ok "a linked worktree on its own branch: quiet" || bad "worktree printed: $(repo_line)"

# behind the remote-tracking default (local refs: the fetch happened earlier)
O="$T/origin.git"; "${GIT[@]}" init -q --bare "$O"
C1="$T/clone1"; "${GIT[@]}" clone -q "$O" "$C1" 2>/dev/null
"${GIT[@]}" -C "$C1" checkout -q -b main 2>/dev/null; "${GIT[@]}" -C "$C1" commit -q --allow-empty -m a; "${GIT[@]}" -C "$C1" push -q -u origin main 2>/dev/null
C2="$T/clone2"; "${GIT[@]}" clone -q "$O" "$C2" 2>/dev/null
run_in "$C2"
[ -z "$(repo_line)" ] && ok "a clone level with origin/main: quiet" || bad "level clone printed: $(repo_line)"
"${GIT[@]}" -C "$C1" commit -q --allow-empty -m b; "${GIT[@]}" -C "$C1" commit -q --allow-empty -m c; "${GIT[@]}" -C "$C1" push -q origin main 2>/dev/null
run_in "$C2"
[ -z "$(repo_line)" ] && ok "the remote moved but this checkout has not fetched: quiet (local refs only, no fetch)" || bad "unfetched remote printed: $(repo_line)"
"${GIT[@]}" -C "$C2" fetch -q origin 2>/dev/null
run_in "$C2"
case "$(repo_line)" in *"clone2 main is 2 commit(s) behind origin/main (local refs, no fetch)"*) ok "behind the fetched origin/main: counted" ;; *) bad "behind line: '$(repo_line)'" ;; esac
"${GIT[@]}" -C "$C2" checkout -q -b side
run_in "$C2"
case "$(repo_line)" in *"clone2 is on side, not main; 2 commit(s) behind origin/main"*) ok "off the default branch and behind: both said" ;; *) bad "side branch line: '$(repo_line)'" ;; esac

# origin/HEAD names another default branch
"${GIT[@]}" -C "$C1" checkout -q -b develop; "${GIT[@]}" -C "$C1" push -q -u origin develop 2>/dev/null
"${GIT[@]}" -C "$C2" fetch -q origin 2>/dev/null
"${GIT[@]}" -C "$C2" remote set-head origin develop >/dev/null 2>&1
"${GIT[@]}" -C "$C2" checkout -q main
run_in "$C2"
case "$(repo_line)" in *"clone2 is on main, not develop"*) ok "origin/HEAD naming develop: develop is the default" ;; *) bad "develop default line: '$(repo_line)'" ;; esac

# a repo with only master
M="$T/legacy"; mkdir -p "$M"; "${GIT[@]}" -C "$M" -c init.defaultBranch=master init -q .; "${GIT[@]}" -C "$M" commit -q --allow-empty -m first
run_in "$M"
[ -z "$(repo_line)" ] && ok "a master-only repo on master: quiet" || bad "master repo printed: $(repo_line)"

# a probe that fails says so: a .git directory git cannot read
B="$T/broken"; mkdir -p "$B/.git"
run_in "$B"
case "$(repo_line)" in *"broken: branch check failed ("*"branch state unchecked"*) ok "a failed probe is named, not silent" ;; *) bad "broken repo line: '$(repo_line)'" ;; esac

# a hung git is cut at 2 s and named: a git that never returns
if command -v timeout >/dev/null 2>&1 || command -v gnutimeout >/dev/null 2>&1; then
  mkdir -p "$T/slowbin"
  printf '#!/bin/sh\nsleep 30\n' > "$T/slowbin/git"; chmod +x "$T/slowbin/git"
  start=$SECONDS
  run_in "$R" PATH="$T/slowbin:$PATH"
  el=$((SECONDS - start))
  case "$(repo_line)" in *"proj: branch check failed (timed out after 2s)"*) [ "$el" -le 12 ] && ok "a hung git is cut at 2 s and named (${el}s)" || bad "hung git took ${el}s" ;; *) bad "hung git line: '$(repo_line)' (${el}s)" ;; esac
else
  echo "SKIP: no timeout binary (a hung git is not bounded)"
fi

# --- unadopted memory pools --------------------------------------------------------------
hyg() { printf '%s\n' "$out" | grep '^ Hygiene:' || true; }
PROJ="$T/cfg/projects"
mkdir -p "$PROJ/-work-adopted/memory-real" && ln -s "$PROJ/-work-adopted/memory-real" "$PROJ/-work-adopted/memory"
run_in "$T/plain"
case "$(hyg)" in *unadopted*) bad "a symlinked (adopted) pool was named: $(hyg)" ;; *) ok "a symlinked pool is adopted: not named" ;; esac
mkdir -p "$PROJ/-work-empty/memory"
run_in "$T/plain"
case "$(hyg)" in *unadopted*) bad "an empty pool was named: $(hyg)" ;; *) ok "an EMPTY pool has nothing to miss: not named" ;; esac
printf '# Generated index\n' > "$PROJ/-work-empty/memory/MEMORY.md"
run_in "$T/plain"
case "$(hyg)" in *unadopted*) bad "an index-only pool was named: $(hyg)" ;; *) ok "an index-only pool is empty to memory-init too: not named" ;; esac
for scratch_key in -home-user-claude-tmp-run -home-user-t3code-claude-title-run C--Users-test-AppData-Local-Temp-run; do
  mkdir -p "$PROJ/$scratch_key/memory"; printf 'x\n' > "$PROJ/$scratch_key/memory/note.md"
done
run_in "$T/plain"
case "$(hyg)" in *unadopted*) bad "an unadoptable scratch pool was named: $(hyg)" ;; *) ok "temporary pools memory-init skips are not offered for adoption" ;; esac
mkdir -p "$PROJ/-tmp-throwaway/memory"; printf 'x\n' > "$PROJ/-tmp-throwaway/memory/note.md"
run_in "$T/plain"
case "$(hyg)" in *unadopted*) bad "a -tmp project pool was named: $(hyg)" ;; *) ok "a -tmp* project is a throwaway cwd: not named" ;; esac
# T3 "No project" threads: cwd under $HOME/.t3/scratch/, spelled with the dot kept or turned into "-"
S1="${T}/home/.t3/scratch/"; S1="${S1//\//-}"
S2="${S1//./-}"
mkdir -p "$PROJ/${S1}2026-10-04-a-title-5ebbadc7/memory" "$PROJ/${S2}2026-10-05-b-title-6fccbed8/memory"
printf 'x\n' > "$PROJ/${S1}2026-10-04-a-title-5ebbadc7/memory/note.md"; printf 'x\n' > "$PROJ/${S2}2026-10-05-b-title-6fccbed8/memory/note.md"
run_in "$T/plain"
case "$(hyg)" in *unadopted*) bad "a T3 scratch pool was named: $(hyg)" ;; *) ok "T3 scratch pools (both spellings of the dot) are not named" ;; esac
# a real pool with content is named, by its project key
mkdir -p "$PROJ/-work-real/memory"; printf 'x\n' > "$PROJ/-work-real/memory/note.md"
run_in "$T/plain"
case "$(hyg)" in *"unadopted memory pool (-work-real): run .claude-config/bin/memory-init"*) ok "a real pool with content is named with its project key and the fix" ;; *) bad "real pool line: '$(hyg)'" ;; esac

echo "session-briefing-scope-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
