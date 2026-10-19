#!/usr/bin/env bash
# Daily sync: (1) back up the OPS repo to GitHub, (2) pull every project
# repo under PROJECTS/ so all clones stay current across machines.
# Runs via Linux cron / Windows Task Scheduler ("OPS Daily Backup", 09:00).
#
# Design:
#   - No `set -e` at top level: one repo's failure must NOT abort the rest.
#     Each stage is a function that logs and returns; both stages always run.
#   - OPS stage order: commit -> pull --rebase -> push. The day's work is
#     committed where it stands, so the tree is never moved: a pull that fails
#     (offline, a conflict) is aborted and leaves the local commit and the
#     tree exactly as they were, and a run killed at any point leaves the work
#     in the tree or in a commit. The earlier stash -> pull -> pop order
#     stranded the work in a stash when a run was killed between the two, and
#     stash/pop dropped empty directories and reset file modes every day.
#   - Project stage delegates to PROJECTS/sync-check.sh --auto: it walks every
#     repo, fast-forwards / rebases the clean ones, and SKIPS dirty repos
#     (never touches uncommitted work). Pull-only: it never pushes projects.
#   - Push gate: the backup sends the whole copy (memory, CONTEXT, notes) to
#     origin, so it pushes only when bin/origin-private-check verifies origin
#     private: exit 0 and its own "private" verdict line (gate_proved). A public
#     origin (a tryout clone of the public template,
#     a copy made public by mistake, a public fork) or one it cannot verify
#     keeps the day's commit local and logs the reason and the fix. The next
#     run that passes the gate pushes every held commit, even on a clean day.

set -uo pipefail

OPS_DIR="$HOME/OPS"
LOG_DIR="$OPS_DIR/.claude-config/backup"
LOG_FILE="$LOG_DIR/sync.log"
PUSH_GATE="$OPS_DIR/.claude-config/bin/origin-private-check"

# cron starts with PATH=/usr/bin:/bin. Add the usual gh install locations
# (Homebrew, a user-local install) so the push gate finds gh there too; a gate
# that cannot find gh skips every push.
PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin:$HOME/.local/bin"
export PATH

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# gate_proved <stderr>: exit 0 from the gate is not proof by itself: an empty
# file, or one cut off after its function definitions (an interrupted update,
# a full disk), also exits 0, and the backup then pushed to a public origin.
# Only the gate's private branches print these lines, last. memory-init and
# hooks/git-guard.sh carry the same test; keep the three in step.
gate_proved() {
    case "${1##*$'\n'}" in
        "origin-private-check: private: "?*) return 0 ;;
        "origin-private-check: private by opt-in (ops.pushVerified=true): "?*) return 0 ;;
    esac
    return 1
}

# push_ops <branch>: push to origin only through the push gate (see Design).
# A skip returns 1 like a failed push: the backup did not leave the machine.
push_ops() {
    local branch="$1" reason rc=0
    if [ ! -f "$PUSH_GATE" ]; then
        log "OPS: WARN push skipped, commit kept locally: $PUSH_GATE is missing, so origin cannot be verified private"
        return 1
    fi
    reason="$(bash "$PUSH_GATE" "$OPS_DIR" 2>&1 >/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        log "OPS: WARN push skipped, commit kept locally: $reason"
        return 1
    fi
    if ! gate_proved "$reason"; then
        log "OPS: WARN push skipped, commit kept locally: $PUSH_GATE exited 0 without its private verdict (${reason:-no output}), so it is empty or truncated; restore it from the template"
        return 1
    fi
    if git push origin "$branch" >/dev/null 2>&1; then
        log "OPS: backup pushed successfully ($reason)"
    else
        log "OPS: ERROR push failed"
        return 1
    fi
}

# git needs a usable identity to commit; a fresh install may have none.
identity_hint() {
    git var GIT_COMMITTER_IDENT >/dev/null 2>&1 && return 0
    log "     no git identity: run git config --global user.name \"Your Name\" and git config --global user.email <your-email>"
}

# git records only a file's exec bit. A rebase over a remote that moved checks
# the remote out first and then replays the local commits, so the files those
# commits touch are re-created at the default mode: a chmod 600 note came back
# 644. save_modes records their permission bits before the pull, and
# restore_modes puts them back after it, whether it succeeded or was aborted;
# an exec bit the pull itself changed is kept. Save all tracked files: a local
# chmod 600 is invisible to git diff, and a remote edit can recreate that file
# at 644 even on a day with no local commits.
MODE_PATHS=() MODE_BITS=()
file_mode() { stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' -- "$1" 2>/dev/null; }
save_modes() {
    local p m
    MODE_PATHS=() MODE_BITS=()
    while IFS= read -r -d '' p; do
        [ -f "$p" ] && [ ! -L "$p" ] || continue
        m="$(file_mode "$p")" && [ -n "$m" ] || continue
        MODE_PATHS+=("$p"); MODE_BITS+=("$m")
    done < <(git ls-files -z)
}
restore_modes() {
    local i p m now
    for ((i = 0; i < ${#MODE_PATHS[@]}; i++)); do
        p="${MODE_PATHS[$i]}"; m="${MODE_BITS[$i]}"
        [ -f "$p" ] && [ ! -L "$p" ] || continue
        now="$(file_mode "$p")" && [ -n "$now" ] && [ "$now" != "$m" ] || continue
        chmod "$(printf '%o' $(( (8#$m & ~8#111) | (8#$now & 8#111) )))" -- "$p" \
            || log "OPS: WARN could not restore the mode of $p (was $m)"
    done
}

# --- Stage 1: back up the OPS repo itself ----------------------------------
backup_ops() {
    cd "$OPS_DIR" 2>/dev/null || { log "OPS: ERROR cannot cd to $OPS_DIR"; return 1; }

    # A run killed mid-pull can leave a rebase in progress; committing on top
    # of it would land on a detached HEAD. The work is safe in the commit the
    # rebase was replaying; say so and leave it for the Operator.
    if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ] \
       || git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        log "OPS: ERROR a rebase or merge is in progress; nothing committed or pushed. Finish or abort it: cd $OPS_DIR && git status"
        return 1
    fi

    # Detect the checked-out branch rather than hardcoding one: a repo created
    # from the public template can default to "main" or whatever GitHub set at
    # creation time; hardcoding a specific name here would silently no-op every
    # pull/push once the actual branch differs.
    local branch
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
        log "OPS: ERROR could not resolve current branch (detached HEAD?)"
        return 1
    fi

    # Commit first, where the work stands; it never leaves the tree. A commit
    # can fail (no git identity, a hook, signing): pushing or logging "kept
    # locally" after a failed commit reported a backup that did not exist
    # (seen 2026-10-19 on a fresh Debian install with no git identity).
    local committed=0 commit_err
    if ! commit_err="$(git add -A 2>&1)"; then
        log "OPS: ERROR git add failed; nothing committed or pushed: $(printf '%s' "$commit_err" | tail -1)"
        return 1
    fi
    if ! git diff --cached --quiet; then
        if ! commit_err="$(git commit -m "Daily Backup $(date '+%Y-%m-%d')" 2>&1 >/dev/null)"; then
            log "OPS: ERROR commit failed; changes left staged, nothing pushed: $(printf '%s' "$commit_err" | tail -1)"
            identity_hint
            return 1
        fi
        committed=1
    fi

    # Then pull, so the tree stays current across hosts. --no-autostash: the
    # tree is committed, and a stash is exactly what this order avoids. A
    # failed pull (offline, no credentials under cron, a conflicting rebase)
    # aborts the rebase it left half-done, so the local commit and the tree
    # stay exactly as they were, and the next run retries.
    local pull_err pull_why
    save_modes
    if ! pull_err="$(git pull --rebase --no-autostash origin "$branch" 2>&1 >/dev/null)"; then
        # git's first fatal/error line names the cause; its last line is often a hint.
        pull_why="$(printf '%s\n' "$pull_err" | grep -m1 -E '^(fatal|error|ERROR|CONFLICT)')" \
            || pull_why="$(printf '%s\n' "$pull_err" | tail -1)"
        if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
            git rebase --abort >/dev/null 2>&1 || log "OPS: ERROR could not abort the half-done rebase; resolve with: cd $OPS_DIR && git status"
        fi
        restore_modes
        if [ "$committed" = 1 ]; then
            log "OPS: ERROR pull --rebase failed; the day's commit is kept locally, nothing pushed: $pull_why"
        else
            log "OPS: ERROR pull --rebase failed; nothing pushed: $pull_why"
        fi
        log "     the tree is as it was; the next run retries (if it keeps failing: cd $OPS_DIR && git pull --rebase origin $branch)"
        return 1
    fi
    restore_modes
    [ "$committed" = 1 ] || log "OPS: no local changes; pulled remote (or already up to date)"

    # Commits an earlier run held back (push gate, failed push) go out too.
    if [ -n "$(git rev-list -n 1 "origin/$branch..HEAD" 2>/dev/null)" ]; then
        push_ops "$branch"
        return
    fi
    return 0
}

# --- Stage 2: pull every project repo under PROJECTS/ ----------------------
sync_projects() {
    local script="$OPS_DIR/PROJECTS/sync-check.sh"
    if [ ! -f "$script" ]; then
        log "PROJECTS: WARN sync-check.sh not found at $script; skipping project sync"
        return 0
    fi
    log "PROJECTS: running sync-check.sh --auto"
    # --auto = non-interactive: fast-forward/rebase clean repos, skip dirty ones.
    if bash "$script" --auto >> "$LOG_FILE" 2>&1; then
        log "PROJECTS: sync-check.sh --auto completed"
    else
        log "PROJECTS: WARN sync-check.sh --auto exited non-zero (see output above)"
    fi
}

log "===== daily-sync start ====="
backup_ops
sync_projects
log "===== daily-sync complete ====="
