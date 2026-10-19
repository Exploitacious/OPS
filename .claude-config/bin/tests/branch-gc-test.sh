#!/usr/bin/env bash
# branch-gc-test.sh - behavior tests for branch-gc (merged-PR branch/worktree GC).
#
# Why pin this: branch-gc deletes branches and worktrees in live repos on a daily
# timer. Its whole value is that it removes ONLY work a merged PR provably carried
# and fails closed on everything else, so every refusal path is asserted here:
# extra local commits, CLOSED/OPEN/no PR, dirty/untracked/ignored/locked/in-use
# worktrees, the main checkout, the default branch, live T3 threads, stacked-PR
# bases, gh failures, truncated and malformed gh output, and an unreadable T3 DB.
# A removable worktree is moved into the trash, not deleted; purge, restore, the
# cross-filesystem refusal and the process scope are pinned in branch-gc-safety-test.py.
# Everything runs against fixture repos in mktemp with a stub `gh` on PATH; HOME is
# pointed into the sandbox so no real repo, T3 DB, or log is ever read or written.
#
# Exit 0 = all pass. Any failure exits 1 and prints the offending case.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../sandbox-guard.sh" && sandbox_guard || exit 97
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../branch-gc"
[ -x "$SCRIPT" ] || { echo "branch-gc missing or not executable: $SCRIPT" >&2; exit 1; }

PASS=0; FAIL=0
pass()  { PASS=$((PASS+1)); }
faild() { FAIL=$((FAIL+1)); echo "FAIL: $1"; [ $# -gt 1 ] && echo "  $2"; }
check() { local name="$1"; shift; if "$@"; then pass; else faild "$name" "${DETAIL:-}"; fi; DETAIL=""; }

TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME"
# A T3 session exports T3CODE_HOME; every run below names its fixture database,
# and none may fall back to the live T3 home.
unset T3CODE_HOME
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# A fixture URL rewrite failure must never fall back to real GitHub transport.
export GIT_ALLOW_PROTOCOL=file
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export BRANCH_GC_LOG="$TMP/state/branch-gc.log"
# Quarantined worktrees land here (the default, under the sandboxed HOME).
TRASH="$HOME/.local/state/ops/branch-gc-trash"
export BRANCH_GC_TRASH_DIR="$TRASH" BRANCH_GC_TRASH_DAYS=7
# Inspect real process cwds through an isolated proc view. Host service processes
# can be intentionally unreadable, a refusal covered by the safety suite.
export BRANCH_GC_PROC_ROOT="$TMP/proc"
mkdir -p "$BRANCH_GC_PROC_ROOT/self"
# The cases below rerun --apply on repos whose GitHub stub changes while no local
# ref moves, and the skip window would answer those reruns from the previous
# clean run. It is off here and on, with its own cases, in section 10.
export BRANCH_GC_SKIP_SECONDS=0
GH_STUB="$TMP/gh"; mkdir -p "$GH_STUB" "$TMP/bin"
export GH_STUB

# --- stub gh: canned JSON per owner_repo, *.fail file = error exit ---------------
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB/calls.log"
kind="$1 $2"; repo=""; o=""; n=""
case "$kind" in
  "repo view") repo="$3" ;;
  "pr list") shift 2; while [ $# -gt 0 ]; do [ "$1" = --repo ] && repo="$2"; shift; done ;;
  "api graphql") shift 2
                 while [ $# -gt 0 ]; do
                   if [ "$1" = -f ]; then case "$2" in o=*) o="${2#o=}" ;; n=*) n="${2#n=}" ;; esac; fi
                   shift
                 done
                 repo="$o/$n" ;;
  *) echo "gh stub: unsupported: $*" >&2; exit 64 ;;
esac
key="${repo//\//_}"
if [ "$kind" = "pr list" ] && [ -e "$GH_STUB/$key.fail" ]; then cat "$GH_STUB/$key.fail" >&2; exit 1; fi
# *.slow: hold the PR list until branch-gc's own deadline has passed, so the
# deadline falls between the repo's start and its first branch on any load.
if [ "$kind" = "pr list" ] && [ -e "$GH_STUB/$key.slow" ]; then
  while [ "$(date +%s)" -le "${BRANCH_GC_DEADLINE:-0}" ]; do sleep 0.2; done
fi
case "$kind" in
  "repo view") cat "$GH_STUB/$key.repo.json" 2>/dev/null || { echo "HTTP 404: Not Found" >&2; exit 1; } ;;
  "pr list")   cat "$GH_STUB/$key.prs.json" ;;
  # totalCount: a *.total file overrides it (simulates a list gh silently capped).
  "api graphql") if [ -e "$GH_STUB/$key.total" ]; then cat "$GH_STUB/$key.total"; else jq 'length' "$GH_STUB/$key.prs.json"; fi ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

g() { git -C "$@"; }
# new_repo <name> <owner/repo>: bare origin + clone on main, raw origin url is the
# GitHub form (what branch-gc parses) and insteadOf maps transport to the bare repo.
new_repo() {
    local name="$1" nwo="$2" url="git@github.com:$2.git"
    git init -q --bare -b main "$TMP/$name-origin.git"
    git init -q -b main "$TMP/$name"
    # `__pycache__` and `node_modules` without a slash also ignore a FILE of that
    # name (cache cases C6, C15). ui/package.json makes ui/dist/ a build output.
    printf '*.log\n__pycache__\n.pytest_cache/\n.env\nmy__pycache__/\nnode_modules\n.astro/\ndist/\nmy_node_modules/\n' \
        > "$TMP/$name/.gitignore"
    printf 'base\n' > "$TMP/$name/f.txt"
    mkdir -p "$TMP/$name/pkg"; printf 'x = 1\n' > "$TMP/$name/pkg/mod.py"
    mkdir -p "$TMP/$name/ui"; printf '{}\n' > "$TMP/$name/ui/package.json"
    g "$TMP/$name" add -A; g "$TMP/$name" commit -qm base
    g "$TMP/$name" remote add origin "$url"
    g "$TMP/$name" config "url.$TMP/$name-origin.git.insteadOf" "$url"
    g "$TMP/$name" push -q origin main
    g "$TMP/$name" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    printf '{"nameWithOwner":"%s","defaultBranchRef":{"name":"main"}}\n' "$nwo" > "$GH_STUB/${nwo//\//_}.repo.json"
}
# branch_commit <repo> <branch>: new branch off main with one commit; prints tip.
branch_commit() {
    g "$1" branch -q "$2" main
    local tree; tree="$(g "$1" rev-parse main^{tree})"
    local c; c="$(printf '%s\n' "$2" | g "$1" commit-tree "$tree" -p main)"
    g "$1" update-ref "refs/heads/$2" "$c"
    printf '%s' "$c"
}
PRS_JSON="[]"
pr() {  # pr <number> <state> <head> <oid> [base] [mergedAt|null]; default mergedAt is weeks old
    PRS_JSON="$(jq -c --argjson n "$1" --arg s "$2" --arg h "$3" --arg o "$4" --arg b "${5:-main}" --arg m "${6:-default}" \
        '. + [{number: $n, state: $s, headRefName: $h, headRefOid: $o, baseRefName: $b,
               mergedAt: (if $s != "MERGED" then null elif $m == "default" then "2026-09-01T00:00:00Z"
                          elif $m == "null" then null else $m end)}]' <<< "$PRS_JSON")"
}

# --- repo W (acme/widget): most cases ----------------------------------------------
W="$TMP/widget"; new_repo widget acme/widget

T_exact="$(branch_commit "$W" merged-exact)";      g "$W" push -q origin merged-exact; pr 1 MERGED merged-exact "$T_exact"
# ancestor: PR head Y is one commit past the local tip X; Y is present via origin.
T_anc="$(branch_commit "$W" merged-ancestor)"
Y="$(printf 'y\n' | g "$W" commit-tree "$(g "$W" rev-parse main^{tree})" -p "$T_anc")"
g "$W" push -q origin "$Y:refs/heads/merged-ancestor";                        pr 2 MERGED merged-ancestor "$Y"
T_extra_pr="$(branch_commit "$W" merged-extra)";   pr 3 MERGED merged-extra "$T_extra_pr"
# The remote carries exactly the PR head; only the local branch has the extra commit.
g "$W" push -q origin "$T_extra_pr:refs/heads/merged-extra"
T_extra="$(printf 'extra\n' | g "$W" commit-tree "$(g "$W" rev-parse main^{tree})" -p "$T_extra_pr")"
g "$W" update-ref refs/heads/merged-extra "$T_extra"
T_closed="$(branch_commit "$W" closed)";           pr 4 CLOSED closed "$T_closed"
branch_commit "$W" nopr >/dev/null
T_open="$(branch_commit "$W" open)";               pr 5 OPEN open "$T_open"
# Reused branch: an old MERGED PR carries the tip, but a new OPEN PR is live on it.
T_reused="$(branch_commit "$W" reused)";           pr 21 MERGED reused "$T_reused"; pr 22 OPEN reused "$T_reused"

mkwt() {  # mkwt <branch> <pr#> [mergedAt|null]: merged branch checked out in a linked worktree
    local t; t="$(branch_commit "$W" "$1")"
    g "$W" worktree add -q "$TMP/wt-$1" "$1"
    pr "$2" MERGED "$1" "$t" main "${3:-default}"
}
mkwt wt-dirty 6;      printf 'changed\n' > "$TMP/wt-wt-dirty/f.txt"
mkwt wt-untracked 7;  printf 'new\n' > "$TMP/wt-wt-untracked/new.txt"
mkwt wt-ignored 8;    printf 'data\n' > "$TMP/wt-wt-ignored/research.log"
mkwt wt-clean 9;      T_clean="$(g "$W" rev-parse wt-clean)"
mkwt wt-locked 10;    g "$W" worktree lock "$TMP/wt-wt-locked"
mkwt wt-inuse 11
mkwt wt-t3-active 12
mkwt wt-t3-stale 13
mkwt wt-t3-deleted 14
mkwt wt-t3-msg 15
mkwt wt-gone 16;      rm -rf "$TMP/wt-wt-gone"
# Regenerable caches (operator ruling 2026-09-22): only ignored DIRECTORIES whose
# basename is exactly __pycache__ or .pytest_cache pass, at any depth.
pyc()    { mkdir -p "$1/pkg/__pycache__"; printf 'c' > "$1/pkg/__pycache__/mod.cpython-314.pyc"; }
pytc()   { mkdir -p "$1/.pytest_cache/v/cache"; printf '{}' > "$1/.pytest_cache/v/cache/lastfailed"; }
mkwt wt-pyc 30;       pyc  "$TMP/wt-wt-pyc"
mkwt wt-pytest 31;    pytc "$TMP/wt-wt-pytest"
mkwt wt-both 32;      pyc  "$TMP/wt-wt-both"; pytc "$TMP/wt-wt-both"
mkwt wt-pyc-env 33;   pyc  "$TMP/wt-wt-pyc-env"; printf 'SECRET=x\n' > "$TMP/wt-wt-pyc-env/.env"
mkwt wt-mypyc 34;     mkdir -p "$TMP/wt-wt-mypyc/my__pycache__"; printf 'd' > "$TMP/wt-wt-mypyc/my__pycache__/data"
mkwt wt-pycfile 35;   printf 'not a dir\n' > "$TMP/wt-wt-pycfile/__pycache__"
mkwt wt-mod-pyc 36;   pyc  "$TMP/wt-wt-mod-pyc"; printf 'changed\n' > "$TMP/wt-wt-mod-pyc/f.txt"
# Regenerable JS caches (2026-09-24): node_modules/ and .astro/ anywhere, dist/
# only beside a package.json. Look-alikes and FILES of those names still block.
nodem()  { mkdir -p "$1/ui/node_modules/pkg"; printf 'js' > "$1/ui/node_modules/pkg/index.js"; }
astro()  { mkdir -p "$1/ui/.astro"; printf '{}' > "$1/ui/.astro/types.json"; }
distui() { mkdir -p "$1/ui/dist"; printf '<html>' > "$1/ui/dist/index.html"; }
mkwt wt-nodemod 60;      nodem  "$TMP/wt-wt-nodemod"
mkwt wt-astro 61;        astro  "$TMP/wt-wt-astro"
mkwt wt-dist-pkg 62;     distui "$TMP/wt-wt-dist-pkg"
mkwt wt-js-all 63;       nodem  "$TMP/wt-wt-js-all"; astro "$TMP/wt-wt-js-all"; distui "$TMP/wt-wt-js-all"; pyc "$TMP/wt-wt-js-all"
mkwt wt-dist-nopkg 64;   mkdir -p "$TMP/wt-wt-dist-nopkg/pkg/dist"; printf 'x' > "$TMP/wt-wt-dist-nopkg/pkg/dist/out.bin"
mkwt wt-mynodemod 65;    mkdir -p "$TMP/wt-wt-mynodemod/my_node_modules"; printf 'd' > "$TMP/wt-wt-mynodemod/my_node_modules/data"
mkwt wt-nodemodfile 66;  printf 'not a dir\n' > "$TMP/wt-wt-nodemodfile/node_modules"
mkwt wt-js-env 67;       nodem  "$TMP/wt-wt-js-env"; printf 'SECRET=x\n' > "$TMP/wt-wt-js-env/ui/.env"
# Worktree grace: a worktree waits 2h after mergedAt; a bare branch does not.
AGO1="$(jq -rn 'now - 3600 | floor | todate')"
AGO3="$(jq -rn 'now - 3 * 3600 | floor | todate')"
AGO25="$(jq -rn 'now - 25 * 3600 | floor | todate')"
mkwt wt-grace-1h 40 "$AGO1"
mkwt wt-grace-3h 46 "$AGO3"
mkwt wt-grace-25h 41 "$AGO25"
# Merged-PR T3 rule: activity from before the merge (3h ago) no longer holds the
# worktree; activity after it, or a thread mid-turn, still does.
mkwt wt-t3-premerge 47 "$AGO3"
mkwt wt-t3-postmerge 48 "$AGO3"
mkwt wt-t3-premerge-running 49 "$AGO3"
mkwt wt-nomerged 42 null
mkwt wt-badmerged 43 yesterday
T_bg="$(branch_commit "$W" br-grace-1h)";  pr 44 MERGED br-grace-1h "$T_bg" main "$AGO1"
T_bb="$(branch_commit "$W" br-badmerged)"; pr 45 MERGED br-badmerged "$T_bb" main garbage
g "$W" worktree add -q --detach "$TMP/wt-detached" main

# No PR at all (2026-09-24): a branch is deleted with `git branch -d` only when
# origin/main holds its tip and every oid its reflog recorded; a worktree on one
# must also sit untouched for 72h. CLOSED stays report-only however contained.
g "$W" branch -q nopr-contained main
g "$W" branch -q nopr-resetaway main
T_ra="$(printf 'ra\n' | g "$W" commit-tree "$(g "$W" rev-parse main^{tree})" -p main)"
g "$W" update-ref -m "work" refs/heads/nopr-resetaway "$T_ra"
g "$W" update-ref -m "reset away" refs/heads/nopr-resetaway "$(g "$W" rev-parse main)"
g "$W" branch -q closed-contained main; pr 50 CLOSED closed-contained "$(g "$W" rev-parse main)"
OLD100="$(( $(date +%s) - 100 * 3600 ))"
backdate() {  # every file in worktree $1 and in its admin dir older than 72h
    find "$1" "$(g "$1" rev-parse --absolute-git-dir)" -xdev -exec touch -h -d "@$OLD100" {} +
}
mknwt() {  # mknwt <branch> [base]: no-PR branch checked out in a worktree added 100h ago
    g "$W" branch -q "$1" "${2:-main}"
    GIT_COMMITTER_DATE="@$OLD100 +0000" g "$W" worktree add -q "$TMP/wt-$1" "$1"
}
mknwt nwt-idle
mknwt nwt-fresh
mknwt nwt-freshfile
mknwt nwt-freshadmin
mknwt nwt-freshreflog
mknwt nwt-dirty
mknwt nwt-t3
mknwt nwt-cache
T_nc="$(printf 'nc\n' | g "$W" commit-tree "$(g "$W" rev-parse main^{tree})" -p main)"
mknwt nwt-commit "$T_nc"
# nwt-fresh keeps its fresh checkout (a lane that just started: clean, 0 commits).
for d in idle freshfile freshadmin freshreflog dirty t3 cache commit; do backdate "$TMP/wt-nwt-$d"; done
touch "$TMP/wt-nwt-freshfile/pkg/mod.py"
touch "$(g "$TMP/wt-nwt-freshadmin" rev-parse --absolute-git-dir)/index"   # a lane's index write
g "$TMP/wt-nwt-freshreflog" update-ref -m "lane touched HEAD" HEAD "$(g "$W" rev-parse main)"
# Only the new reflog ENTRY is fresh: the file holding it goes back to 100h ago.
touch -d "@$OLD100" "$(g "$TMP/wt-nwt-freshreflog" rev-parse --absolute-git-dir)/logs/HEAD"
printf 'edited\n' > "$TMP/wt-nwt-dirty/f.txt"; touch -d "@$OLD100" "$TMP/wt-nwt-dirty/f.txt"
nodem "$TMP/wt-nwt-cache"   # fresh, but ignored caches do not count toward idle

T_base="$(branch_commit "$W" stack-base)";   g "$W" push -q origin stack-base
pr 17 MERGED stack-base "$T_base"; pr 18 OPEN stack-child "$T_base" stack-base
T_rx="$(branch_commit "$W" remote-extra)"
RX="$(printf 'rx\n' | g "$W" commit-tree "$(g "$W" rev-parse main^{tree})" -p "$T_rx")"
g "$W" push -q origin "$RX:refs/heads/remote-extra";                         pr 19 MERGED remote-extra "$T_rx"
T_ro="$(printf 'ro\n' | g "$W" commit-tree "$(g "$W" rev-parse main^{tree})" -p main)"
g "$W" push -q origin "$T_ro:refs/heads/remote-only";                        pr 20 MERGED remote-only "$T_ro"
# Bad proof metadata is a repo-level error. Exercise each bad record separately
# below so it cannot turn the ordinary safety cases into vacuous repo skips.
printf '%s\n' "$PRS_JSON" | jq '[.[] | select(.number == 42 or .number == 43 or .number == 45)]' > "$TMP/bad-merge-prs.json"
PRS_JSON="$(jq '[.[] | select(.number != 42 and .number != 43 and .number != 45)]' <<< "$PRS_JSON")"
printf '%s\n' "$PRS_JSON" > "$GH_STUB/acme_widget.prs.json"
cp "$GH_STUB/acme_widget.prs.json" "$TMP/widget-valid.json"

# A process parked inside wt-inuse (an agent between commits).
( cd "$TMP/wt-wt-inuse" && exec sleep 600 ) & PIDS+=($!)
ln -s "/proc/${PIDS[0]}" "$BRANCH_GC_PROC_ROOT/${PIDS[0]}"
sleep 0.2

# --- repo G (acme/gadget): main checkout on a merged branch, default not checked out
G="$TMP/gadget"; new_repo gadget acme/gadget
T_fm="$(branch_commit "$G" feature-main)"; g "$G" checkout -q feature-main
PRS_JSON="[]"; pr 1 MERGED feature-main "$T_fm"
# A MERGED PR whose head is named main (a fork's main) must still never touch main.
pr 2 MERGED main "$(g "$G" rev-parse main)"
printf '%s\n' "$PRS_JSON" > "$GH_STUB/acme_gadget.prs.json"

# --- T3 fixture DB: real table/column names from ~/.t3/userdata/state.sqlite -----
T3DB="$TMP/t3/state.sqlite"; mkdir -p "$TMP/t3"
python3 - "$T3DB" "$TMP" <<'PY'
import datetime, sqlite3, sys
db, tmp = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
con.executescript("""
CREATE TABLE projection_threads (
      thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL, branch TEXT,
      worktree_path TEXT, latest_turn_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      deleted_at TEXT, runtime_mode TEXT NOT NULL DEFAULT 'full-access',
      interaction_mode TEXT NOT NULL DEFAULT 'default', model_selection_json TEXT, archived_at TEXT,
      latest_user_message_at TEXT, pending_approval_count INTEGER NOT NULL DEFAULT 0,
      pending_user_input_count INTEGER NOT NULL DEFAULT 0, has_actionable_proposed_plan INTEGER NOT NULL DEFAULT 0,
      settled_override TEXT, settled_at TEXT, snoozed_until TEXT, snoozed_at TEXT,
      title_regeneration_request_id TEXT, title_regeneration_started_at TEXT, pinned_at TEXT, pin_order_key TEXT,
      linked_pull_request_json TEXT, unsettled_at TEXT, branch_pull_request_json TEXT, active_order_key TEXT,
      title_state_json TEXT);
CREATE TABLE projection_thread_sessions (
      thread_id TEXT PRIMARY KEY, status TEXT NOT NULL, provider_name TEXT, provider_session_id TEXT,
      provider_thread_id TEXT, active_turn_id TEXT, last_error TEXT, updated_at TEXT NOT NULL,
      runtime_mode TEXT NOT NULL DEFAULT 'full-access', provider_instance_id TEXT);
CREATE TABLE projection_thread_messages (
      message_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, turn_id TEXT, role TEXT NOT NULL, text TEXT NOT NULL,
      is_streaming INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      attachments_json TEXT, context_json TEXT);
CREATE TABLE projection_thread_activities (
      activity_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, turn_id TEXT, tone TEXT NOT NULL, kind TEXT NOT NULL,
      summary TEXT NOT NULL, payload_json TEXT NOT NULL, created_at TEXT NOT NULL, sequence INTEGER);
""")
now = datetime.datetime.now(datetime.timezone.utc)
def ago(h): return (now - datetime.timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def thread(tid, wt, upd_h, deleted=None, status="stopped"):
    con.execute("insert into projection_threads (thread_id, project_id, title, branch, worktree_path, created_at, updated_at, deleted_at) values (?,?,?,?,?,?,?,?)",
                (tid, "p1", tid, wt, "%s/wt-%s" % (tmp, wt), ago(200), ago(upd_h), deleted))
    con.execute("insert into projection_thread_sessions (thread_id, status, updated_at) values (?,?,?)", (tid, status, ago(upd_h)))
# An older live thread on the same worktree, inserted first: the reason must still
# name the newest activity (1h), not whichever row the query returned first.
thread("thr-active-old", "wt-t3-active", 5)
thread("thr-active", "wt-t3-active", 1)
thread("thr-stale", "wt-t3-stale", 100)
thread("thr-deleted", "wt-t3-deleted", 1, deleted=ago(0.5))
thread("thr-msg", "wt-t3-msg", 100)
# PRs 47-49 merged 3h ago; a finished review thread idle since 5h ago predates it.
thread("thr-premerge", "wt-t3-premerge", 5)
thread("thr-postmerge", "wt-t3-postmerge", 1)
thread("thr-premerge-run", "wt-t3-premerge-running", 5, status="running")
thread("thr-nwt", "nwt-t3", 1)
# Only the newest message is recent: the max-over-columns rule must see it.
con.execute("insert into projection_thread_messages values ('m1','thr-msg',null,'user','hi',0,?,?,null,null)", (ago(2), ago(2)))
con.commit()
PY

run() { BRANCH_GC_T3_DB="$T3DB" bash "$SCRIPT" --tsv "$@" 2> "$TMP/stderr"; }
act() { awk -F'\t' -v r="$2" -v b="$3" '$1 == r && $2 == b {print $5; exit}' "$1"; }
why() { awk -F'\t' -v r="$2" -v b="$3" '$1 == r && $2 == b {print $6; exit}' "$1"; }
snap() { { g "$1" for-each-ref --format='%(objectname) %(refname)'; g "$1" worktree list --porcelain; \
           git --git-dir="$1-origin.git" for-each-ref --format='%(objectname) %(refname)'; } > "$2"; }
is_act()  { DETAIL="$2/$3: action='$(act "$1" "$2" "$3")' reason='$(why "$1" "$2" "$3")' want '$4'"; [ "$(act "$1" "$2" "$3")" = "$4" ]; }
why_has() { DETAIL="$2/$3: reason='$(why "$1" "$2" "$3")' want *$4*"; case "$(why "$1" "$2" "$3")" in *"$4"*) return 0 ;; *) return 1 ;; esac; }
has_ref() { g "$1" rev-parse -q --verify "refs/heads/$2" >/dev/null; }
has_remote() { [ -n "$(git --git-dir="$1-origin.git" for-each-ref "refs/heads/$2")" ]; }

# === 1. dry-run: every verdict right, nothing changed ==============================
snap "$W" "$TMP/w.before"; snap "$G" "$TMP/g.before"
: > "$GH_STUB/calls.log"
run --dry-run "$W" "$G" > "$TMP/dry.tsv"; rc=$?
check "1a dry-run exits 0" [ "$rc" -eq 0 ]
snap "$W" "$TMP/w.after"; snap "$G" "$TMP/g.after"
DETAIL="$(diff "$TMP/w.before" "$TMP/w.after" | head -5)"; check "1b dry-run changed nothing in widget" cmp -s "$TMP/w.before" "$TMP/w.after"
DETAIL="$(diff "$TMP/g.before" "$TMP/g.after" | head -5)"; check "1c dry-run changed nothing in gadget" cmp -s "$TMP/g.before" "$TMP/g.after"
check "1c' dry-run created no trash"              [ ! -e "$TRASH" ]
check "1d merged, tip == head -> remove"          is_act "$TMP/dry.tsv" acme/widget merged-exact remove
check "1e merged, tip ancestor of head -> remove" is_act "$TMP/dry.tsv" acme/widget merged-ancestor remove
check "1f merged + extra local commit -> report"  is_act "$TMP/dry.tsv" acme/widget merged-extra report
check "1f' reason names the extra commits"        why_has "$TMP/dry.tsv" acme/widget merged-extra "local has commits not in merged PR #3"
check "1g CLOSED -> report"                       is_act "$TMP/dry.tsv" acme/widget closed report
check "1h no PR -> report"                        is_act "$TMP/dry.tsv" acme/widget nopr report
check "1i OPEN -> report"                         is_act "$TMP/dry.tsv" acme/widget open report
check "1i' MERGED + OPEN on one head -> report"  why_has "$TMP/dry.tsv" acme/widget reused "open PR"
check "1j dirty worktree -> report"               is_act "$TMP/dry.tsv" acme/widget wt-dirty report
check "1j' reason says dirty"                     why_has "$TMP/dry.tsv" acme/widget wt-dirty "worktree dirty"
check "1k untracked-only worktree -> report"      is_act "$TMP/dry.tsv" acme/widget wt-untracked report
check "1l ignored-only worktree -> report"        why_has "$TMP/dry.tsv" acme/widget wt-ignored "ignored files (research.log"
check "1m clean worktree -> quarantine"           is_act "$TMP/dry.tsv" acme/widget wt-clean quarantine
check "1m' reason says it would move to trash"   why_has "$TMP/dry.tsv" acme/widget wt-clean "worktree clean, would move to trash"
check "1n locked worktree -> report"              why_has "$TMP/dry.tsv" acme/widget wt-locked "worktree locked"
check "1o worktree with a live cwd -> report"     why_has "$TMP/dry.tsv" acme/widget wt-inuse "in use by pid"
check "1p T3 thread active 1h ago -> report"      why_has "$TMP/dry.tsv" acme/widget wt-t3-active "T3 thread still active"
check "1q T3 thread idle 100h -> quarantine"      is_act "$TMP/dry.tsv" acme/widget wt-t3-stale quarantine
check "1r deleted T3 thread does not protect"     is_act "$TMP/dry.tsv" acme/widget wt-t3-deleted quarantine
check "1p' reason names the newest thread activity" why_has "$TMP/dry.tsv" acme/widget wt-t3-active "(1h ago)"
check "1s recent T3 message keeps thread active"  why_has "$TMP/dry.tsv" acme/widget wt-t3-msg "T3 thread still active"
check "C1 only __pycache__/ -> quarantine"        is_act "$TMP/dry.tsv" acme/widget wt-pyc quarantine
check "C2 only .pytest_cache/ -> quarantine"      is_act "$TMP/dry.tsv" acme/widget wt-pytest quarantine
check "C3 both caches -> quarantine"              is_act "$TMP/dry.tsv" acme/widget wt-both quarantine
check "C4 __pycache__/ + .env -> report"          is_act "$TMP/dry.tsv" acme/widget wt-pyc-env report
check "C4' reason names .env, not the cache"      why_has "$TMP/dry.tsv" acme/widget wt-pyc-env "ignored files (.env)"
check "C5 my__pycache__/ -> report"               why_has "$TMP/dry.tsv" acme/widget wt-mypyc "ignored files (my__pycache__/)"
check "C6 ignored FILE named __pycache__ -> report" why_has "$TMP/dry.tsv" acme/widget wt-pycfile "ignored files (__pycache__)"
check "C7 modified file + __pycache__/ -> report" why_has "$TMP/dry.tsv" acme/widget wt-mod-pyc "worktree dirty (1 changed/untracked: f.txt)"
check "G1 worktree merged 1h ago -> report"       is_act "$TMP/dry.tsv" acme/widget wt-grace-1h report
check "G1' reason gives age and 2h grace"         why_has "$TMP/dry.tsv" acme/widget wt-grace-1h "h ago; worktree grace 2h"
check "G1b worktree merged 3h ago -> quarantine"  is_act "$TMP/dry.tsv" acme/widget wt-grace-3h quarantine
check "G2 worktree merged 25h ago -> quarantine"  is_act "$TMP/dry.tsv" acme/widget wt-grace-25h quarantine
check "C10 only node_modules/ -> quarantine"      is_act "$TMP/dry.tsv" acme/widget wt-nodemod quarantine
check "C11 only .astro/ -> quarantine"            is_act "$TMP/dry.tsv" acme/widget wt-astro quarantine
check "C12 dist/ beside package.json -> quarantine" is_act "$TMP/dry.tsv" acme/widget wt-dist-pkg quarantine
check "C13 every allowed cache at once -> quarantine" is_act "$TMP/dry.tsv" acme/widget wt-js-all quarantine
check "C14 dist/ without package.json -> report"  why_has "$TMP/dry.tsv" acme/widget wt-dist-nopkg "ignored files (pkg/dist/)"
check "C15 my_node_modules/ -> report"            why_has "$TMP/dry.tsv" acme/widget wt-mynodemod "ignored files (my_node_modules/)"
check "C16 ignored FILE named node_modules -> report" why_has "$TMP/dry.tsv" acme/widget wt-nodemodfile "ignored files (node_modules)"
check "C17 node_modules/ + .env -> report names .env" why_has "$TMP/dry.tsv" acme/widget wt-js-env "ignored files (ui/.env"
check "T1 merged, T3 idle since before merge -> quarantine" is_act "$TMP/dry.tsv" acme/widget wt-t3-premerge quarantine
check "T2 merged, T3 active after merge -> report" why_has "$TMP/dry.tsv" acme/widget wt-t3-postmerge "T3 thread still active"
check "T3 merged, pre-merge T3 thread mid-turn -> report" why_has "$TMP/dry.tsv" acme/widget wt-t3-premerge-running "session running"
check "N1 no PR, contained, no worktree -> remove" is_act "$TMP/dry.tsv" acme/widget nopr-contained remove
check "N1' reason says git branch -d"             why_has "$TMP/dry.tsv" acme/widget nopr-contained "no PR; tip and reflog contained in origin/main; would git branch -d"
check "N2 no PR, commit not in origin/main -> report" why_has "$TMP/dry.tsv" acme/widget nopr "no PR; tip has 1 commit(s) not in origin/main"
check "N3 no PR, reflog held uncontained work -> report" why_has "$TMP/dry.tsv" acme/widget nopr-resetaway "branch reflog records ${T_ra:0:12}"
check "N4 CLOSED PR, contained -> report"         why_has "$TMP/dry.tsv" acme/widget closed-contained "PR closed without merge"
check "W1 no-PR worktree idle 100h -> quarantine" is_act "$TMP/dry.tsv" acme/widget nwt-idle quarantine
check "W1' reason says idle and git branch -d"    why_has "$TMP/dry.tsv" acme/widget nwt-idle "worktree clean and idle 72h, would move to trash and git branch -d"
check "W2 no-PR worktree just created -> report"  why_has "$TMP/dry.tsv" acme/widget nwt-fresh "no-PR worktrees wait 72h idle"
check "W3 one fresh file -> report"               why_has "$TMP/dry.tsv" acme/widget nwt-freshfile "(file pkg/mod.py)"
check "W4 fresh admin-dir index -> report"        why_has "$TMP/dry.tsv" acme/widget nwt-freshadmin "(admin index)"
check "W5 fresh HEAD reflog entry -> report"      why_has "$TMP/dry.tsv" acme/widget nwt-freshreflog "(HEAD reflog)"
check "W6 dirty no-PR worktree -> report"         why_has "$TMP/dry.tsv" acme/widget nwt-dirty "worktree dirty"
check "W7 T3 thread 1h ago on no-PR worktree -> report" why_has "$TMP/dry.tsv" acme/widget nwt-t3 "T3 thread still active"
check "W8 fresh ignored cache does not count -> quarantine" is_act "$TMP/dry.tsv" acme/widget nwt-cache quarantine
check "W9 no-PR worktree with a commit -> report" why_has "$TMP/dry.tsv" acme/widget nwt-commit "tip has 1 commit(s) not in origin/main"
bad_merge_proof() {
    jq --argjson n "$1" '[.[] | select(.number == $n)]' "$TMP/bad-merge-prs.json" > "$GH_STUB/acme_widget.prs.json"
    run --dry-run "$W" > "$TMP/bad-merge.tsv"; local bad_rc=$?
    cp "$TMP/widget-valid.json" "$GH_STUB/acme_widget.prs.json"
    [ "$bad_rc" -ne 0 ] && is_act "$TMP/bad-merge.tsv" "$W" - skip
}
check "G5 bare branch merged 1h ago -> remove"    is_act "$TMP/dry.tsv" acme/widget br-grace-1h remove
check "1t missing worktree dir -> report"         is_act "$TMP/dry.tsv" acme/widget wt-gone report
check "1u detached worktree -> report"            is_act "$TMP/dry.tsv" acme/widget "(detached)" report
check "1v main checkout on merged branch -> report" why_has "$TMP/dry.tsv" acme/gadget feature-main "main checkout sits on merged branch feature-main"
check "1w default branch never touched"           why_has "$TMP/dry.tsv" acme/gadget main "default branch, never touched"
check "1x no remote rows without --remote"        [ -z "$(awk -F'\t' '$2 ~ /^origin\//' "$TMP/dry.tsv")" ]
DETAIL="$(cat "$GH_STUB/calls.log")"
check "1y one pr list per repo (batched)"         [ "$(grep -c '^pr list' "$GH_STUB/calls.log")" -eq 2 ]
DETAIL="$(tail -3 "$BRANCH_GC_LOG" 2>/dev/null)"
check "1z log has timestamped would-remove lines" grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] dry-run acme/widget merged-exact: would remove' "$BRANCH_GC_LOG"
check "G3 missing mergedAt -> skip entire repo"   bad_merge_proof 42
check "G4 garbage mergedAt -> skip entire repo"   bad_merge_proof 43
check "G6 garbage mergedAt, bare branch -> skip entire repo" bad_merge_proof 45

# grace 0 disables the window; bad mergedAt still fails closed; bad value is usage.
BRANCH_GC_WORKTREE_GRACE_HOURS=0 run --dry-run "$W" > "$TMP/grace0.tsv"; rc=$?
check "G7 grace 0 -> 1h-old worktree removable"   eval '[ "$rc" -eq 0 ] && is_act "$TMP/grace0.tsv" acme/widget wt-grace-1h quarantine'
check "G7' grace 0: no-PR worktree still report"  is_act "$TMP/grace0.tsv" acme/widget wt-nomerged report
BRANCH_GC_WORKTREE_GRACE_HOURS=abc run --dry-run "$W" > /dev/null; rc=$?
check "G8 non-numeric grace -> exit 2"            [ "$rc" -eq 2 ]

# === 2. unreadable T3 DB: worktree removals blocked, run fails =====================
printf 'not a sqlite db' > "$TMP/t3/garbage.sqlite"
BRANCH_GC_T3_DB="$TMP/t3/garbage.sqlite" bash "$SCRIPT" --tsv --dry-run "$W" > "$TMP/t3bad.tsv" 2>/dev/null; rc=$?
check "2a unreadable T3 DB exits non-zero"          [ "$rc" -ne 0 ]
check "2b clean worktree blocked by unreadable T3"  why_has "$TMP/t3bad.tsv" acme/widget wt-clean "T3 state unreadable"
check "2c non-worktree branch still evaluated"      is_act "$TMP/t3bad.tsv" acme/widget merged-exact remove

# === 2d. T3 0.1.0 (Orchestrator V2): statev2.sqlite beside a mode-000 V1 file ========
# The V1 thread set above, rebuilt in V2 tables (most archived, as on the live
# host). The V1 copy beside it cannot be opened, so every verdict here comes from
# statev2.sqlite; reading the V1 file would turn each worktree row unreadable.
T3V2="$TMP/t3v2/userdata"; mkdir -p "$T3V2"
cp "$T3DB" "$T3V2/state.sqlite"; chmod 000 "$T3V2/state.sqlite"
python3 - "$HERE" "$T3V2/statev2.sqlite" "$TMP" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from branch_gc_t3v2_fixture import V2Fixture
fx, tmp = V2Fixture(sys.argv[2]), sys.argv[3]
def th(tid, wt, h, **kw):
    fx.thread(tid, "%s/wt-%s" % (tmp, wt), updated_h=h, **kw)
th("thr-active-old", "wt-t3-active", 5, archived_h=4)
th("thr-active", "wt-t3-active", 1, archived_h=0.5)
th("thr-stale", "wt-t3-stale", 100, archived_h=90)
th("thr-deleted", "wt-t3-deleted", 1, deleted_h=0.5)
th("thr-msg", "wt-t3-msg", 100, archived_h=90)
fx.message("thr-msg", created_h=2)
th("thr-premerge", "wt-t3-premerge", 5, archived_h=4)
th("thr-postmerge", "wt-t3-postmerge", 1)
th("thr-premerge-run", "wt-t3-premerge-running", 5)
fx.run("thr-premerge-run", "running", requested_h=5)
th("thr-nwt", "nwt-t3", 1)
fx.close()
PY
BRANCH_GC_T3_DB="$T3V2/state.sqlite" bash "$SCRIPT" --tsv --dry-run "$W" > "$TMP/v2dry.tsv" 2> "$TMP/stderr"; rc=$?
DETAIL="rc=$rc $(head -c 400 "$TMP/stderr")"; check "2d V2 dry-run exits 0" [ "$rc" -eq 0 ]
DETAIL="$(head -1 "$TMP/v2dry.tsv")"; check "2d' header names the V2 source" grep -q 'T3=ok (v2 .*/statev2.sqlite)' "$TMP/v2dry.tsv"
check "2e V2 archived thread active 1h ago -> report" why_has "$TMP/v2dry.tsv" acme/widget wt-t3-active "T3 thread still active"
check "2e' reason names the newest activity"          why_has "$TMP/v2dry.tsv" acme/widget wt-t3-active "(1h ago), archived"
check "2f V2 archived thread idle 100h -> quarantine" is_act "$TMP/v2dry.tsv" acme/widget wt-t3-stale quarantine
check "2g V2 deleted thread does not protect"         is_act "$TMP/v2dry.tsv" acme/widget wt-t3-deleted quarantine
check "2h V2 recent message keeps thread active"      why_has "$TMP/v2dry.tsv" acme/widget wt-t3-msg "T3 thread still active"
check "2i V2 merged, idle since before merge -> quarantine" is_act "$TMP/v2dry.tsv" acme/widget wt-t3-premerge quarantine
check "2j V2 merged, active after merge -> report"    why_has "$TMP/v2dry.tsv" acme/widget wt-t3-postmerge "T3 thread still active"
check "2k V2 merged, pre-merge run in flight -> report" why_has "$TMP/v2dry.tsv" acme/widget wt-t3-premerge-running "run running"
check "2l V2 thread on no-PR worktree -> report"      why_has "$TMP/v2dry.tsv" acme/widget nwt-t3 "T3 thread still active"
check "2m V2 worktree with no thread unaffected"      is_act "$TMP/v2dry.tsv" acme/widget wt-clean quarantine
DETAIL="$(grep 'T3 v2 snapshot' "$BRANCH_GC_LOG" | tail -1)"
check "2n V2 snapshot logged with its high-water"     grep -q 'T3 v2 snapshot: event high-water [0-9]*; 9 threads, 8 own a worktree on 7 path(s), 1 path(s) hard-held' "$BRANCH_GC_LOG"

# === 3. --apply (no --remote) ======================================================
run --apply "$W" "$G" > "$TMP/apply.tsv"; rc=$?
DETAIL="rc=$rc $(cat "$TMP/stderr")"; check "3a apply exits 0" [ "$rc" -eq 0 ]
check "3b merged-exact deleted"            eval '! has_ref "$W" merged-exact'
check "3c merged-ancestor deleted"         eval '! has_ref "$W" merged-ancestor'
check "3d merged-extra kept at its tip"    [ "$(g "$W" rev-parse -q --verify refs/heads/merged-extra)" = "$T_extra" ]
check "3e closed/nopr/open/reused kept"    eval 'has_ref "$W" closed && has_ref "$W" nopr && has_ref "$W" open && has_ref "$W" reused'
check "3f dirty worktree + branch kept"    eval '[ -f "$TMP/wt-wt-dirty/f.txt" ] && has_ref "$W" wt-dirty'
check "3g untracked worktree kept"         eval '[ -f "$TMP/wt-wt-untracked/new.txt" ] && has_ref "$W" wt-untracked'
check "3h ignored-file worktree kept"      eval '[ -f "$TMP/wt-wt-ignored/research.log" ] && has_ref "$W" wt-ignored'
check "3i clean worktree removed"          eval '[ ! -e "$TMP/wt-wt-clean" ] && ! has_ref "$W" wt-clean'
check "3j clean worktree row says quarantined" is_act "$TMP/apply.tsv" acme/widget wt-clean quarantined
Q_CLEAN="$(ls -d "$TRASH"/*__acme-widget__wt-clean 2>/dev/null | head -n 1)"
DETAIL="entry='$Q_CLEAN'"
check "3j' clean worktree sits in the trash"      eval '[ -f "$Q_CLEAN/worktree/f.txt" ] && [ -f "$Q_CLEAN/git-admin/HEAD" ]'
DETAIL="$(cat "$Q_CLEAN/manifest.json" 2>&1)"
check "3j'' manifest names branch, tip and path"  eval '[ "$(jq -r "[.branch, .tip, .worktree, .pr, .method] | @tsv" "$Q_CLEAN/manifest.json")" = "wt-clean	$T_clean	$TMP/wt-wt-clean	9	rename" ]'
check "3j''' cache worktree keeps its cache in trash" eval '[ -f "$(ls -d "$TRASH"/*__acme-widget__wt-pyc | head -n 1)/worktree/pkg/__pycache__/mod.cpython-314.pyc" ]'
check "3k locked worktree kept"            eval '[ -d "$TMP/wt-wt-locked" ] && has_ref "$W" wt-locked'
check "3l in-use worktree kept"            eval '[ -d "$TMP/wt-wt-inuse" ] && has_ref "$W" wt-inuse'
check "3m active T3 worktrees kept"        eval '[ -d "$TMP/wt-wt-t3-active" ] && [ -d "$TMP/wt-wt-t3-msg" ]'
check "3n stale + deleted T3 worktrees removed" eval '[ ! -e "$TMP/wt-wt-t3-stale" ] && [ ! -e "$TMP/wt-wt-t3-deleted" ]'
check "3o missing worktree metadata and branch retained" eval 'g "$W" worktree list --porcelain | grep -q wt-wt-gone && has_ref "$W" wt-gone'
check "C8 cache-only worktrees removed by apply" eval '[ ! -e "$TMP/wt-wt-pyc" ] && [ ! -e "$TMP/wt-wt-pytest" ] && [ ! -e "$TMP/wt-wt-both" ] && ! has_ref "$W" wt-pyc && ! has_ref "$W" wt-both'
check "C9 blocked cache cases kept with their files" eval '[ -f "$TMP/wt-wt-pyc-env/.env" ] && [ -f "$TMP/wt-wt-mypyc/my__pycache__/data" ] && [ -f "$TMP/wt-wt-pycfile/__pycache__" ] && [ -d "$TMP/wt-wt-mod-pyc/pkg/__pycache__" ] && has_ref "$W" wt-pyc-env && has_ref "$W" wt-mypyc && has_ref "$W" wt-pycfile && has_ref "$W" wt-mod-pyc'
check "G9 apply: grace worktree + branch kept"   eval '[ -d "$TMP/wt-wt-grace-1h" ] && has_ref "$W" wt-grace-1h'
check "G10 apply: 25h worktree + branch removed" eval '[ ! -e "$TMP/wt-wt-grace-25h" ] && ! has_ref "$W" wt-grace-25h'
check "G11 apply: 1h bare branch deleted"        eval '! has_ref "$W" br-grace-1h'
check "G12 apply: no-PR grace fixtures kept"      eval 'has_ref "$W" br-badmerged && has_ref "$W" wt-nomerged && [ -d "$TMP/wt-wt-badmerged" ]'
check "G13 apply: 3h worktree + branch removed"   eval '[ ! -e "$TMP/wt-wt-grace-3h" ] && ! has_ref "$W" wt-grace-3h'
check "C18 apply: JS-cache worktrees removed"     eval '[ ! -e "$TMP/wt-wt-nodemod" ] && [ ! -e "$TMP/wt-wt-astro" ] && [ ! -e "$TMP/wt-wt-dist-pkg" ] && [ ! -e "$TMP/wt-wt-js-all" ] && ! has_ref "$W" wt-js-all'
check "C19 apply: node_modules kept inside the trash" eval '[ -f "$(ls -d "$TRASH"/*__acme-widget__wt-nodemod | head -n 1)/worktree/ui/node_modules/pkg/index.js" ]'
check "C20 apply: blocked JS cases kept with their files" eval '[ -f "$TMP/wt-wt-dist-nopkg/pkg/dist/out.bin" ] && [ -f "$TMP/wt-wt-mynodemod/my_node_modules/data" ] && [ -f "$TMP/wt-wt-nodemodfile/node_modules" ] && [ -f "$TMP/wt-wt-js-env/ui/.env" ] && has_ref "$W" wt-js-env && has_ref "$W" wt-dist-nopkg'
check "T4 apply: pre-merge T3 worktree removed"   eval '[ ! -e "$TMP/wt-wt-t3-premerge" ] && ! has_ref "$W" wt-t3-premerge'
check "T5 apply: post-merge and mid-turn T3 worktrees kept" eval '[ -d "$TMP/wt-wt-t3-postmerge" ] && [ -d "$TMP/wt-wt-t3-premerge-running" ] && has_ref "$W" wt-t3-postmerge && has_ref "$W" wt-t3-premerge-running'
check "N5 apply: contained no-PR branch deleted"  eval '! has_ref "$W" nopr-contained'
check "N6 apply: no-PR reset-away and CLOSED kept" eval 'has_ref "$W" nopr-resetaway && has_ref "$W" closed-contained'
check "N7 log says git branch -d"                 grep -qF "acme/widget nopr-contained: deleted branch with git branch -d" "$BRANCH_GC_LOG"
check "W10 apply: idle no-PR worktree quarantined" eval '[ ! -e "$TMP/wt-nwt-idle" ] && ! has_ref "$W" nwt-idle && [ ! -e "$TMP/wt-nwt-cache" ] && ! has_ref "$W" nwt-cache'
Q_NWT="$(ls -d "$TRASH"/*__acme-widget__nwt-idle 2>/dev/null | head -n 1)"
DETAIL="$(cat "$Q_NWT/manifest.json" 2>&1)"
check "W11 no-PR manifest: pr null, basis contained" eval '[ "$(jq -r "[.pr, .merged_at, .basis, .contained_in] | map(tostring) | @tsv" "$Q_NWT/manifest.json")" = "null	null	contained	refs/remotes/origin/main" ]'
all_nwt_kept() { local d; for d in fresh freshfile freshadmin freshreflog dirty t3 commit; do [ -d "$TMP/wt-nwt-$d" ] && has_ref "$W" "nwt-$d" || return 1; done; }
check "W12 apply: every blocked no-PR worktree kept" all_nwt_kept
check "W13 apply: dirty no-PR edit survives"       eval '[ "$(cat "$TMP/wt-nwt-dirty/f.txt")" = edited ]'
check "3p detached worktree kept"          [ -d "$TMP/wt-detached" ]
check "3q main + main-checkout branch kept" eval 'has_ref "$G" main && has_ref "$G" feature-main && [ "$(g "$G" symbolic-ref --short HEAD)" = feature-main ]'
check "3r widget main kept"                has_ref "$W" main
check "3s remote refs untouched without --remote" eval 'has_remote "$W" merged-exact && has_remote "$W" stack-base && has_remote "$W" remote-only'
check "3t log records the deletion with its sha" grep -qF "acme/widget merged-exact: deleted branch (was $T_exact)" "$BRANCH_GC_LOG"

# === 4. --apply --remote =============================================================
run --apply --remote "$W" > "$TMP/remote.tsv"; rc=$?
DETAIL="rc=$rc $(cat "$TMP/stderr")"; check "4a apply --remote exits 0" [ "$rc" -eq 0 ]
check "4b remote merged-exact deleted"          eval '! has_remote "$W" merged-exact'
check "4c remote-only merged branch deleted"    eval '! has_remote "$W" remote-only'
check "4d stacked base kept on remote"          has_remote "$W" stack-base
check "4d' reason names the open child PR"      why_has "$TMP/remote.tsv" acme/widget origin/stack-base "open PR #18 is based on this branch"
check "4e local stack-base still removed"       eval '! has_ref "$W" stack-base'
check "4f remote tip past PR head kept"         eval 'has_remote "$W" remote-extra && ! has_ref "$W" remote-extra'
check "4g remote of an ineligible local kept"   has_remote "$W" merged-extra
check "4g' reason names the ineligible local"  why_has "$TMP/remote.tsv" acme/widget origin/merged-extra "local branch merged-extra is not eligible"
check "4h remote main never deleted"            has_remote "$W" main

# === 5. idempotent: a second --apply finds nothing new and exits 0 ================
before="$(g "$W" for-each-ref | wc -l)"
run --apply "$W" "$G" > "$TMP/again.tsv"; rc=$?
check "5a second apply exits 0"                 [ "$rc" -eq 0 ]
check "5b second apply removes nothing"         [ -z "$(awk -F'\t' '$5 ~ /^(removed|remove-failed|quarantined|purged|purge-failed)$/' "$TMP/again.tsv")" ]
check "5c ref count unchanged"                  [ "$(g "$W" for-each-ref | wc -l)" = "$before" ]

# === 6. gh failure: repo skipped whole, other repos still processed, exit non-zero =
B="$TMP/broken"; new_repo broken acme/broken
T_b="$(branch_commit "$B" merged-b)"
PRS_JSON="[]"; pr 1 MERGED merged-b "$T_b"; printf '%s\n' "$PRS_JSON" > "$GH_STUB/acme_broken.prs.json"
printf 'HTTP 403: API rate limit exceeded for user\n' > "$GH_STUB/acme_broken.fail"
run --apply "$B" "$G" > "$TMP/ghfail.tsv"; rc=$?
check "6a gh failure exits non-zero"            [ "$rc" -ne 0 ]
check "6b merged branch in failed repo kept"    has_ref "$B" merged-b
check "6c failed repo row is skip"              why_has "$TMP/ghfail.tsv" "$B" - "gh pr list failed: HTTP 403"
check "6d other repo still processed"           is_act "$TMP/ghfail.tsv" acme/gadget feature-main report
check "6e failure logged"                       grep -q "ERROR $B: repo skipped: gh pr list failed" "$BRANCH_GC_LOG"
rm -f "$GH_STUB/acme_broken.fail"; rm -f "$GH_STUB/acme_broken.repo.json"
run --apply "$B" > "$TMP/ghview.tsv"; rc=$?
check "6f gh repo view failure also skips"      eval '[ "$rc" -ne 0 ] && has_ref "$B" merged-b'

# === 7. truncated and malformed gh output: ambiguous -> skip =======================
printf '{"nameWithOwner":"acme/broken","defaultBranchRef":{"name":"main"}}\n' > "$GH_STUB/acme_broken.repo.json"
BRANCH_GC_PR_LIMIT=1 run --apply "$B" > "$TMP/trunc.tsv"; rc=$?
check "7a full page (possible truncation) -> skip, non-zero" eval '[ "$rc" -ne 0 ] && has_ref "$B" merged-b'
check "7a' reason says truncated"               why_has "$TMP/trunc.tsv" "$B" - "may be truncated"
printf '5\n' > "$GH_STUB/acme_broken.total"
run --apply "$B" > "$TMP/capped.tsv"; rc=$?
check "7a2 list shorter than totalCount -> skip, non-zero" eval '[ "$rc" -ne 0 ] && has_ref "$B" merged-b'
check "7a3 reason says 1 of 5"                  why_has "$TMP/capped.tsv" "$B" - "returned 1 of 5 PRs"
rm -f "$GH_STUB/acme_broken.total"
printf '[{"number":1,"state":"MERGED","headRefName":"merged-b","baseRefName":"main"},{"number":"x"}]\n' > "$GH_STUB/acme_broken.prs.json"
run --apply "$B" > "$TMP/bad.tsv"; rc=$?
check "7b malformed JSON -> skip, non-zero"     eval '[ "$rc" -ne 0 ] && has_ref "$B" merged-b'
# An empty headRefOid must never let another column stand in for the oid.
printf '[{"number":1,"state":"MERGED","headRefName":"merged-b","headRefOid":"","baseRefName":"main","mergedAt":"2026-09-01T00:00:00Z"}]\n' > "$GH_STUB/acme_broken.prs.json"
run --apply "$B" > "$TMP/nooid.tsv"; rc=$?
check "7c merged PR without head oid -> skip repo" eval '[ "$rc" -ne 0 ] && has_ref "$B" merged-b'
check "7c' reason says malformed JSON"          why_has "$TMP/nooid.tsv" "$B" - "malformed JSON"

# === 8. branch moved after the PR merged (pushed follow-up) is kept =================
g "$B" update-ref refs/heads/merged-b "$(printf 'later\n' | g "$B" commit-tree "$(g "$B" rev-parse main^{tree})" -p "$T_b")"
PRS_JSON="[]"; pr 1 MERGED merged-b "$T_b"; printf '%s\n' "$PRS_JSON" > "$GH_STUB/acme_broken.prs.json"
run --apply "$B" > "$TMP/moved.tsv"; rc=$?
check "8a follow-up commit after merge -> kept" eval '[ "$rc" -eq 0 ] && has_ref "$B" merged-b'

# === 9. a linked worktree passed as a repo folds into its main repo ================
: > "$GH_STUB/calls.log"
run --dry-run "$W" "$TMP/wt-wt-dirty" > "$TMP/fold.tsv"; rc=$?
check "9a linked worktree arg scanned once"     [ "$(grep -c '^pr list' "$GH_STUB/calls.log")" -eq 1 ]

# === 10. skip window and soft deadline (2026-10-15) =================================
# The skip window is on only in this section (BRANCH_GC_SKIP_SECONDS=600 per run).
K="$TMP/skipper"; new_repo skipper acme/skipper
T_k1="$(branch_commit "$K" merged-k1)"; T_k2="$(branch_commit "$K" merged-k2)"
PRS_JSON="[]"; pr 1 MERGED merged-k1 "$T_k1"; pr 2 MERGED merged-k2 "$T_k2"
printf '%s\n' "$PRS_JSON" > "$GH_STUB/acme_skipper.prs.json"
ghk() { grep -c '^pr list.*acme/skipper' "$GH_STUB/calls.log" 2>/dev/null || true; }
skiprun() { BRANCH_GC_SKIP_SECONDS=600 run --apply "$K" > "$1"; }
# A deadline already passed starts nothing; one passing mid-repo stops before
# the first branch. Either way nothing is removed and the run says why.
BRANCH_GC_DEADLINE="$(( $(date +%s) - 1 ))" run --apply "$K" > "$TMP/late0.tsv"; rc=$?
check "10a past deadline: exit 0, repo not started" eval '[ "$rc" -eq 0 ] && [ "$(ghk)" -eq 0 ]'
check "10a' reason says not started"            why_has "$TMP/late0.tsv" "$K" - "not started: the run's deadline passed"
: > "$GH_STUB/acme_skipper.slow"
BRANCH_GC_DEADLINE="$(( $(date +%s) + 15 ))" run --apply "$K" > "$TMP/late1.tsv"; rc=$?
rm -f "$GH_STUB/acme_skipper.slow"
check "10b deadline mid-repo: exit 0, branches kept" eval '[ "$rc" -eq 0 ] && has_ref "$K" merged-k1 && has_ref "$K" merged-k2'
check "10b' each branch says not evaluated"     eval 'why_has "$TMP/late1.tsv" acme/skipper merged-k1 "not evaluated" && why_has "$TMP/late1.tsv" acme/skipper merged-k2 "not evaluated"'
check "10b'' the log says where it stopped"     eval 'grep -q "acme/skipper: deadline passed; no further branch is evaluated" "$BRANCH_GC_LOG" && grep -q "acme/skipper: remove=0 report=0 quarantine=0 fail=0 not-evaluated=2" "$BRANCH_GC_LOG"'
: > "$GH_STUB/acme_skipper.slow"
BRANCH_GC_DEADLINE="$(( $(date +%s) + 15 ))" BRANCH_GC_T3_DB="$T3DB" bash "$SCRIPT" --apply "$K" > "$TMP/late2.txt" 2>&1
rm -f "$GH_STUB/acme_skipper.slow"
check "10b''' the summary says it stopped"      grep -q 'stopped at the deadline: 2 branch(es) not evaluated' "$TMP/late2.txt"
# A clean apply records the repo's fingerprint; an immediate rerun skips it.
skiprun "$TMP/skip1.tsv"; rc=$?
check "10c clean apply removes both"            eval '[ "$rc" -eq 0 ] && ! has_ref "$K" merged-k1 && ! has_ref "$K" merged-k2'
n="$(ghk)"; skiprun "$TMP/skip2.tsv"; rc=$?
check "10d unchanged rerun is skipped"          eval '[ "$rc" -eq 0 ] && [ "$(ghk)" -eq "$n" ] && is_act "$TMP/skip2.tsv" "$K" - skip'
check "10d' reason names the earlier clean run"  why_has "$TMP/skip2.tsv" "$K" - "unchanged since the clean --apply"
# Any ref change is a different fingerprint: a new merged branch is seen at once.
T_k3="$(branch_commit "$K" merged-k3)"; pr 3 MERGED merged-k3 "$T_k3"; printf '%s\n' "$PRS_JSON" > "$GH_STUB/acme_skipper.prs.json"
skiprun "$TMP/skip3.tsv"; rc=$?
check "10e a ref change is not skipped"         eval '[ "$rc" -eq 0 ] && ! has_ref "$K" merged-k3 && is_act "$TMP/skip3.tsv" acme/skipper merged-k3 removed'
n="$(ghk)"; skiprun "$TMP/skip4.tsv"
check "10e' and the result is skippable again"  eval '[ "$(ghk)" -eq "$n" ] && is_act "$TMP/skip4.tsv" "$K" - skip'
g "$K" worktree add -q --detach "$TMP/wt-skipper" main
n="$(ghk)"; skiprun "$TMP/skip5.tsv"
check "10f a worktree change is not skipped"    [ "$(ghk)" -gt "$n" ]
n="$(ghk)"; BRANCH_GC_WORKTREE_GRACE_HOURS=5 BRANCH_GC_SKIP_SECONDS=600 run --apply "$K" > "$TMP/skip6.tsv"
check "10g a settings change is not skipped"    [ "$(ghk)" -gt "$n" ]
n="$(ghk)"; BRANCH_GC_SKIP_SECONDS=600 run --dry-run "$K" > "$TMP/skip7.tsv"
check "10h a dry run never skips"               [ "$(ghk)" -gt "$n" ]
n="$(ghk)"; BRANCH_GC_SKIP_SECONDS=0 run --apply "$K" > "$TMP/skip8.tsv"
check "10i BRANCH_GC_SKIP_SECONDS=0 never skips" [ "$(ghk)" -gt "$n" ]
# A failed run records nothing, so the next run decides afresh. (The new branch
# makes the failing run evaluate the repo rather than skip it.)
skiprun "$TMP/skip9.tsv"
branch_commit "$K" stray-k4 >/dev/null
printf 'HTTP 502\n' > "$GH_STUB/acme_skipper.fail"
skiprun "$TMP/skip10.tsv"; rc=$?
rm -f "$GH_STUB/acme_skipper.fail"
n="$(ghk)"; skiprun "$TMP/skip11.tsv"
check "10j after a failed run nothing is skipped" eval '[ "$rc" -ne 0 ] && [ "$(ghk)" -gt "$n" ]'

check "11 remote branches honor the soft deadline" python3 "$HERE/branch-gc-deadline-test.py"
check "13 T3 V2 liveness and fail-closed suite"    python3 -B "$HERE/branch-gc-t3v2-test.py"

# === 12. a worktree this run quarantined is noise when its own turn comes (2026-10-15) =
# The default repo list holds each linked worktree beside its main repo, and the main
# repo is scanned first, so a worktree quarantined there was a vanished directory
# when its own entry came up: 189 "ERROR <path>: not a git repo" lines in the real
# log, every one for a path quarantined earlier in the same run, each ending its run
# "failed". Only that case is noise. A path gone for any other reason must still fail
# the run, and a registration whose directory vanished must still be reported (and
# never pruned: restore and unmounted volumes need it).
Q="$TMP/qgc"; new_repo qgc acme/qgc
PRS_JSON="[]"
qwt() {  # qwt <n>: merged branch merged-q<n> checked out at $TMP/wt-q<n>, PR merged long ago
    local t; t="$(branch_commit "$Q" "merged-q$1")"
    g "$Q" worktree add -q "$TMP/wt-q$1" "merged-q$1"
    pr "$1" MERGED "merged-q$1" "$t"; printf '%s\n' "$PRS_JSON" > "$GH_STUB/acme_qgc.prs.json"
}
log_has() { grep -qF -- "$1" "$BRANCH_GC_LOG"; }
qwt 1
run --apply "$Q" "$TMP/wt-q1" > "$TMP/q1.tsv"; rc=$?
check "12a quarantined in this run: exit 0"             eval '[ "$rc" -eq 0 ] && [ ! -e "$TMP/wt-q1" ] && ! has_ref "$Q" merged-q1'
check "12a' it is a skip row that says why"             eval 'is_act "$TMP/q1.tsv" "$TMP/wt-q1" - skip && why_has "$TMP/q1.tsv" "$TMP/wt-q1" - "quarantined earlier in this run"'
check "12a'' the log holds a NOTE and no ERROR"         eval 'log_has "NOTE $TMP/wt-q1: worktree quarantined earlier in this run" && ! log_has "ERROR $TMP/wt-q1: not a git repo"'
check "12a''' the worktree really is in the trash"      eval 'ls "$TRASH" | grep -q "acme-qgc__merged-q1"'
# A path an EARLIER run quarantined, passed again by hand, is not recognized: this
# decision is made from this run's memory only, so it stays an error.
run --apply "$Q" "$TMP/wt-q1" > "$TMP/q1b.tsv"; rc=$?
check "12b an earlier run's quarantine is still an error" eval '[ "$rc" -ne 0 ] && why_has "$TMP/q1b.tsv" "$TMP/wt-q1" - "not a git repo" && log_has "ERROR $TMP/wt-q1: not a git repo"'
# A sibling that merely shares a prefix with a quarantined path is no match.
run --apply "$Q" "$TMP/wt-q1x" > "$TMP/q1c.tsv"; rc=$?
check "12c a path that never existed fails the run"     eval '[ "$rc" -ne 0 ] && why_has "$TMP/q1c.tsv" "$TMP/wt-q1x" - "not a git repo" && log_has "ERROR $TMP/wt-q1x: not a git repo"'
# A worktree that vanished some other way keeps its registration and its branch,
# and is reported both as an unavailable registration and, when named, as a failed path.
qwt 2; rm -rf "$TMP/wt-q2"
run --apply "$Q" > "$TMP/q2a.tsv"; rc=$?
check "12d a vanished registration is reported, not an error" eval '[ "$rc" -eq 0 ] && why_has "$TMP/q2a.tsv" acme/qgc merged-q2 "worktree unavailable"'
check "12d' and kept: registration and branch"          eval 'g "$Q" worktree list --porcelain | grep -q "wt-q2" && has_ref "$Q" merged-q2'
run --apply "$Q" "$TMP/wt-q2" > "$TMP/q2b.tsv"; rc=$?
check "12e naming the vanished path fails the run"      eval '[ "$rc" -ne 0 ] && why_has "$TMP/q2b.tsv" "$TMP/wt-q2" - "not a git repo" && log_has "ERROR $TMP/wt-q2: not a git repo"'
check "12e' the registration is still not pruned"       eval 'g "$Q" worktree list --porcelain | grep -q "wt-q2" && has_ref "$Q" merged-q2'
# A directory inside a worktree this run quarantined is gone with it.
qwt 3
run --apply "$Q" "$TMP/wt-q3/pkg" > "$TMP/q3.tsv"; rc=$?
check "12f a path inside a quarantined worktree: exit 0" eval '[ "$rc" -eq 0 ] && [ ! -e "$TMP/wt-q3" ] && why_has "$TMP/q3.tsv" "$TMP/wt-q3/pkg" - "quarantined earlier in this run"'
# Worktree listed before its main repo: folded in, nothing to report.
qwt 4
run --apply "$TMP/wt-q4" "$Q" > "$TMP/q4.tsv"; rc=$?
check "12g worktree first, main repo second: exit 0"    eval '[ "$rc" -eq 0 ] && [ ! -e "$TMP/wt-q4" ] && ! log_has "ERROR $TMP/wt-q4"'
# Resolve aliases while their symlinks still exist, and preserve trailing-slash
# and directory inputs that really were inside the moved worktree.
qwt 5; ln -s "$TMP/wt-q5" "$TMP/q5-link"
run --apply "$Q" "$TMP/wt-q5/" "$TMP/wt-q5/pkg/" "$TMP/q5-link/pkg" > "$TMP/q5.tsv"; rc=$?
check "12h aliases and trailing slashes: exit 0"      [ "$rc" -eq 0 ]
for p in "$TMP/wt-q5/" "$TMP/wt-q5/pkg/" "$TMP/q5-link/pkg"; do
    check "12h' moved path $p is recognized" why_has "$TMP/q5.tsv" "$p" - "quarantined earlier in this run"
done
# Neither a sibling nor a missing child was moved. Keep these in the SAME run as
# the quarantine, so the test exercises the nonempty quarantine set.
qwt 6
run --apply "$Q" "$TMP/wt-q6" "$TMP/wt-q6x" "$TMP/wt-q6/missing" > "$TMP/q6.tsv"; rc=$?
check "12i unrelated missing inputs still fail"      [ "$rc" -ne 0 ]
check "12i' the actual moved path is recognized"     why_has "$TMP/q6.tsv" "$TMP/wt-q6" - "quarantined earlier in this run"
check "12i'' a sibling is not a descendant"          why_has "$TMP/q6.tsv" "$TMP/wt-q6x" - "not a git repo"
check "12i''' a missing child was never moved"       why_has "$TMP/q6.tsv" "$TMP/wt-q6/missing" - "not a git repo"
# A tracked symlink can name a separate repo. Once its containing worktree moves,
# resolving the now-missing link lexically would claim that repo was scanned too.
new_repo qother acme/qother
qwt 7
ln -s "$TMP/qother" "$TMP/wt-q7/other"
g "$TMP/wt-q7" add other; g "$TMP/wt-q7" commit -qm 'tracked link to another repo'
PRS_JSON="$(jq -c --arg tip "$(g "$TMP/wt-q7" rev-parse HEAD)" \
    'map(if .headRefName == "merged-q7" then .headRefOid = $tip else . end)' <<< "$PRS_JSON")"
printf '%s\n' "$PRS_JSON" > "$GH_STUB/acme_qgc.prs.json"
run --apply "$Q" "$TMP/wt-q7/other" > "$TMP/q7.tsv"; rc=$?
check "12j a moved symlink cannot conceal an unscanned repo" eval '[ "$rc" -ne 0 ] && [ ! -e "$TMP/wt-q7" ] && why_has "$TMP/q7.tsv" "$TMP/wt-q7/other" - "not a git repo"'
# Command substitution strips trailing newlines. Keep the canonical path byte
# exact, or a distinct repo ending in a newline aliases the quarantined path.
qwt 8; git init -q -b main "$TMP/wt-q8"$'\n'
ln -s "$TMP/wt-q8"$'\n' "$TMP/wt-q8/other"
g "$TMP/wt-q8" add other; g "$TMP/wt-q8" commit -qm 'tracked link to a repo ending in a newline'
PRS_JSON="$(jq -c --arg tip "$(g "$TMP/wt-q8" rev-parse HEAD)" \
    'map(if .headRefName == "merged-q8" then .headRefOid = $tip else . end)' <<< "$PRS_JSON")"
printf '%s\n' "$PRS_JSON" > "$GH_STUB/acme_qgc.prs.json"
run --apply "$Q" "$TMP/wt-q8/other" > "$TMP/q8.tsv"; rc=$?
check "12k canonical paths preserve trailing newlines" eval '[ "$rc" -ne 0 ] && [ ! -e "$TMP/wt-q8" ] && why_has "$TMP/q8.tsv" "$TMP/wt-q8/other" - "not a git repo"'

echo "branch-gc-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
