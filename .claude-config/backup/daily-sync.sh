#!/usr/bin/env bash
# Daily sync: (1) back up the OPS repo to GitHub, (2) pull every project
# repo under PROJECTS/ so all clones stay current across machines.
# Runs via Linux cron / Windows Task Scheduler ("OPS Daily Backup", 09:00).
#
# Design:
#   - No `set -e` at top level: one repo's failure must NOT abort the rest.
#     Each stage is a function that logs and returns; both stages always run.
#   - OPS stage order: stash -> pull -> unstash -> commit -> push. The old
#     `git pull --rebase` before staging aborted on a dirty tree — i.e. the
#     backup failed precisely when there was work to back up.
#   - Project stage delegates to PROJECTS/sync-check.sh --auto: it walks every
#     repo, fast-forwards / rebases the clean ones, and SKIPS dirty repos
#     (never touches uncommitted work). Pull-only — it never pushes projects.

set -uo pipefail

OPS_DIR="$HOME/OPS"
LOG_DIR="$OPS_DIR/.claude-config/backup"
LOG_FILE="$LOG_DIR/sync.log"

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# --- Stage 1: back up the OPS repo itself ----------------------------------
backup_ops() {
    cd "$OPS_DIR" 2>/dev/null || { log "OPS: ERROR cannot cd to $OPS_DIR"; return 1; }

    # Detect the checked-out branch rather than hardcoding one — a repo created
    # from the public template can default to "main" or whatever GitHub set at
    # creation time; hardcoding a specific name here would silently no-op every
    # pull/push once the actual branch differs.
    local branch
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
        log "OPS: ERROR could not resolve current branch (detached HEAD?)"
        return 1
    fi

    # No local changes: still pull so the tree stays current across hosts.
    if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
        if git pull --ff-only origin "$branch" >/dev/null 2>&1; then
            log "OPS: no local changes; pulled remote (or already up to date)"
        else
            log "OPS: WARN pull --ff-only failed with clean tree (diverged history?)"
        fi
        return 0
    fi

    # Local changes exist. Stash, pull, re-apply, commit, push.
    local stash_label="daily-sync-auto-$(date -u +%Y-%m-%dT%H-%M-%SZ)"
    if ! git stash push -u -m "$stash_label" >/dev/null 2>&1; then
        log "OPS: ERROR git stash failed; aborting OPS backup to avoid clobbering work"
        return 1
    fi

    if ! git pull --rebase origin "$branch" >/dev/null 2>&1; then
        log "OPS: ERROR pull --rebase failed; local changes preserved in stash '$stash_label'"
        log "     recover with: cd $OPS_DIR && git stash list && git stash pop"
        return 1
    fi

    if ! git stash pop >/dev/null 2>&1; then
        log "OPS: ERROR stash pop conflicted; local changes preserved in stash '$stash_label'"
        log "     resolve manually: cd $OPS_DIR && git status && git stash list"
        return 1
    fi

    git add -A
    if git diff --cached --quiet; then
        log "OPS: stash pop produced no net diff; nothing to commit"
        return 0
    fi

    git commit -m "Daily Backup $(date '+%Y-%m-%d')" >/dev/null
    if git push origin "$branch" >/dev/null 2>&1; then
        log "OPS: backup pushed successfully"
    else
        log "OPS: ERROR push failed"
        return 1
    fi
}

# --- Stage 2: pull every project repo under PROJECTS/ ----------------------
sync_projects() {
    local script="$OPS_DIR/PROJECTS/sync-check.sh"
    if [ ! -f "$script" ]; then
        log "PROJECTS: WARN sync-check.sh not found at $script — skipping project sync"
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
