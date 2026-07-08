#!/usr/bin/env bash
# Daily OPS backup to GitHub.
# Runs via Linux cron / Windows Task Scheduler. Commits + pushes any changes.
# No-op if nothing has changed (no empty commits).
#
# Order matters: stash → pull → unstash → commit → push.
# Old version did `git pull --rebase` before staging, which aborts on dirty
# working tree — i.e., the backup failed precisely when there was work to back up.

set -e

OPS_DIR="$HOME/OPS"
LOG_DIR="$OPS_DIR/.claude-config/backup"
LOG_FILE="$LOG_DIR/sync.log"

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

cd "$OPS_DIR" 2>/dev/null || { log "ERROR: Cannot cd to $OPS_DIR"; exit 1; }

# Detect the checked-out branch rather than hardcoding one — a repo created
# from the public template can default to "main" or whatever GitHub set at
# creation time; hardcoding a specific name here would silently no-op every
# pull/push once the actual branch differs.
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
    log "ERROR: could not resolve current branch (detached HEAD?)"
    exit 1
fi

# Check for changes (staged, unstaged, or untracked).
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    # Nothing local. Still pull so the working tree stays current across hosts.
    if git pull --ff-only origin "$BRANCH" >/dev/null 2>&1; then
        log "No local changes; pulled remote (or already up to date)"
    else
        log "WARN: pull --ff-only failed with clean tree (diverged history?)"
    fi
    exit 0
fi

# Local changes exist. Stash them, pull, then re-apply.
STASH_LABEL="daily-sync-auto-$(date -u +%Y-%m-%dT%H-%M-%SZ)"
if ! git stash push -u -m "$STASH_LABEL" >/dev/null 2>&1; then
    log "ERROR: git stash failed; aborting to avoid clobbering local work"
    exit 1
fi

if ! git pull --rebase origin "$BRANCH" >/dev/null 2>&1; then
    log "ERROR: pull --rebase failed; local changes preserved in stash '$STASH_LABEL'"
    log "       recover with: cd $OPS_DIR && git stash list && git stash pop"
    exit 1
fi

if ! git stash pop >/dev/null 2>&1; then
    log "ERROR: stash pop conflicted; local changes preserved in stash '$STASH_LABEL'"
    log "       resolve manually: cd $OPS_DIR && git status && git stash list"
    exit 1
fi

git add -A
if git diff --cached --quiet; then
    log "Stash pop produced no net diff; nothing to commit"
    exit 0
fi

git commit -m "Daily Backup $(date '+%Y-%m-%d')" >/dev/null
git push origin "$BRANCH" >/dev/null 2>&1 || { log "ERROR: push failed"; exit 1; }

log "Backup pushed successfully"
