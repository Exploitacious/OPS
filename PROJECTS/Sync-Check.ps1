#Requires -Version 5.1
<#
.SYNOPSIS
    Checks all git repos in the PROJECTS directory and brings them up to date.
.DESCRIPTION
    Walks through every folder, fetches the latest from the remote, and
    rebases your local branch onto it. Uncommitted changes are shelved
    automatically before the rebase, then you're asked what to do with them
    after. Plain-language prompts -- no git jargon required.
#>

$ProjectsRoot = $PSScriptRoot
$Separator = "-" * 70
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------
function Write-Status {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Write-Explain {
    param([string]$Message)
    Write-Host "    (explain) $Message" -ForegroundColor DarkGray
}

function Write-Action {
    param([string]$Message)
    Write-Host "    -> $Message" -ForegroundColor Cyan
}

function Write-Good {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [!!] $Message" -ForegroundColor Yellow
}

function Write-Bad {
    param([string]$Message)
    Write-Host "    [XX] $Message" -ForegroundColor Red
}

function Read-Choice {
    param(
        [string]$Prompt,
        [System.Collections.IDictionary]$Options  # key (single letter) -> description
    )
    while ($true) {
        Write-Host ""
        Write-Host "    $Prompt" -ForegroundColor White
        foreach ($k in $Options.Keys) {
            Write-Host "      [$k] $($Options[$k])" -ForegroundColor Gray
        }
        $response = Read-Host "    Choice"
        $response = $response.Trim().ToUpper()
        if ($Options.Contains($response)) {
            return $response
        }
        Write-Host "    (not a valid option, try again)" -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------
# Header
# ---------------------------------------------------------------
Write-Host ""
Write-Status "GIT SYNC -- $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "Cyan"
Write-Status $Separator "DarkGray"
Write-Host "What this does: for each project, it checks if the server has"
Write-Host "newer changes, then updates your local copy. If you have unsaved"
Write-Host "edits, it tucks them aside first so nothing gets lost." -ForegroundColor DarkGray
Write-Host ""

$summary = @{
    Synced       = @()
    AlreadyClean = @()
    NeedsAttn    = @()
    Skipped      = @()
    StashesKept  = @()
}

# ---------------------------------------------------------------
# Main loop -- recursive discovery
# ---------------------------------------------------------------
# PROJECTS uses a cluster layout: PROJECTS/<org>/<repo>/.
# Walk every directory; treat any dir containing a .git/ as a repo
# (matches sync-check.sh's `find -name .git -prune` semantics).
# -mindepth 2-equivalent: skip cluster dirs themselves (they're not repos).
Get-ChildItem -Path $ProjectsRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
    Test-Path (Join-Path $_.FullName ".git")
} | ForEach-Object {
    $dir = $_.FullName
    # Use relative path as display name so cluster-layout repos are unambiguous.
    $name = $dir.Substring($ProjectsRoot.Length).TrimStart('\','/')

    Write-Status "[$name]" "Yellow"

    # Fetch
    Write-Action "Asking the server what's new..."
    Write-Explain "This doesn't change anything yet -- it just downloads info."
    $fetchOutput = & git -C $dir fetch --all --prune 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Bad "Couldn't reach the server: $fetchOutput"
        $summary.Skipped += $name
        Write-Host ""
        return
    }

    # Current branch
    $branch = & git -C $dir symbolic-ref --short HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "This repo isn't on a branch right now (detached state). Skipping."
        Write-Explain "Usually happens if you checked out a specific commit. Not dangerous, just unusual."
        $summary.Skipped += $name
        Write-Host ""
        return
    }

    # Upstream?
    $upstream = & git -C $dir rev-parse --abbrev-ref "${branch}@{upstream}" 2>&1
    $hasUpstream = $LASTEXITCODE -eq 0
    if (-not $hasUpstream) {
        Write-Warn "Branch '$branch' isn't connected to any server branch. Nothing to sync against."
        Write-Explain "You'd fix this with: git push -u origin $branch"
        $summary.NeedsAttn += "$name (no upstream on $branch)"
        Write-Host ""
        return
    }

    # Ahead/behind
    $ahead = 0
    $behind = 0
    $counts = & git -C $dir rev-list --left-right --count "${branch}...${upstream}" 2>&1
    if ($counts -match "^(\d+)\s+(\d+)$") {
        $ahead = [int]$Matches[1]
        $behind = [int]$Matches[2]
    }

    # Dirty?
    $dirtyRaw = & git -C $dir status --porcelain 2>&1
    $uncommittedCount = if ($dirtyRaw) { ($dirtyRaw | Measure-Object).Count } else { 0 }
    $isDirty = $uncommittedCount -gt 0

    # Status line in plain English
    Write-Host "    Branch: $branch <-> $upstream" -ForegroundColor Gray
    if ($ahead -gt 0)  { Write-Host "    You have $ahead local commit(s) the server doesn't." -ForegroundColor Gray }
    if ($behind -gt 0) { Write-Host "    Server has $behind commit(s) you don't." -ForegroundColor Gray }
    if ($isDirty)      { Write-Host "    You have $uncommittedCount uncommitted change(s) sitting locally." -ForegroundColor Gray }

    # Nothing to do
    if ($ahead -eq 0 -and $behind -eq 0 -and -not $isDirty) {
        Write-Good "Already in sync. Nothing to do."
        $summary.AlreadyClean += $name
        Write-Host ""
        return
    }

    # No rebase needed (not behind the server). Report and move on -- don't stash.
    if ($behind -eq 0) {
        if ($ahead -gt 0) {
            Write-Good "You're ahead of the server. No rebase needed."
            Write-Explain "When you're ready to share these commits: git push"
        }
        if ($isDirty) {
            Write-Warn "You have $uncommittedCount uncommitted change(s). Leaving them alone."
            Write-Explain "Nothing on the server to reconcile with, so no need to shelve them."
            $summary.NeedsAttn += "$name (uncommitted changes)"
        } else {
            $summary.AlreadyClean += $name
        }
        Write-Host ""
        return
    }

    # ----- Dirty tree handling -----
    $stashRef = $null
    if ($isDirty) {
        Write-Action "Shelving your uncommitted changes so the update can happen safely..."
        Write-Explain "In git terms this is called a 'stash'. Think of it as a labeled drawer."
        $stashLabel = "sync-check-$name-$Timestamp"
        $stashOut = & git -C $dir stash push -u -m $stashLabel 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Bad "Couldn't shelve changes: $stashOut"
            $summary.NeedsAttn += "$name (stash failed)"
            Write-Host ""
            return
        }
        # Resolve the stash by its label (so later ops are unambiguous)
        $stashList = & git -C $dir stash list 2>&1
        $stashMatch = ($stashList | Where-Object { $_ -match [regex]::Escape($stashLabel) } | Select-Object -First 1)
        if ($stashMatch -match '^(stash@\{\d+\})') {
            $stashRef = $Matches[1]
        }
        Write-Good "Changes shelved as: $stashLabel"
    }

    # ----- Rebase (only if behind or diverged) -----
    $rebaseNeeded = ($behind -gt 0)
    $rebaseSucceeded = $true

    if ($rebaseNeeded) {
        if ($ahead -gt 0) {
            Write-Action "Your history and the server's have diverged. Replaying your $ahead local commit(s) on top of the server's latest..."
            Write-Explain "This is a 'rebase'. Your local commits get re-applied one by one onto the newest server version, so history stays clean."
        } else {
            Write-Action "Updating your branch to match the server's latest..."
            Write-Explain "Fast-forward: no conflict possible, just catching up."
        }

        $rebaseOut = & git -C $dir rebase $upstream 2>&1
        if ($LASTEXITCODE -ne 0) {
            $rebaseSucceeded = $false
            Write-Bad "Update hit a conflict and was cancelled. Your repo is back to how it was."
            Write-Explain "A conflict means the same lines were changed both locally and on the server. A script can't safely guess which version you want."

            # Abort the rebase to leave repo clean
            & git -C $dir rebase --abort 2>&1 | Out-Null

            # Show what conflicted
            $conflictFiles = $rebaseOut | Select-String -Pattern "CONFLICT" | ForEach-Object { $_.ToString() }
            if ($conflictFiles) {
                Write-Host "    Conflicting files:" -ForegroundColor DarkYellow
                $conflictFiles | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
            }

            # If we stashed, restore the stash so user is back where they started
            if ($stashRef) {
                Write-Action "Putting your shelved changes back so you're exactly where you started..."
                $popOut = & git -C $dir stash pop $stashRef 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Good "Shelved changes restored."
                } else {
                    Write-Warn "Couldn't auto-restore the shelf. Run this manually: git stash pop $stashRef"
                    $summary.StashesKept += "$name ($stashLabel)"
                }
            }

            $summary.NeedsAttn += "$name (rebase conflict -- manual resolution needed)"
            Write-Host ""
            return
        } else {
            Write-Good "Update applied cleanly."
        }
    }

    # ----- If we stashed, ask what to do with the shelf -----
    if ($stashRef) {
        $decided = $false
        while (-not $decided) {
            $choice = Read-Choice -Prompt "Your shelved changes are still tucked away. What do you want to do with them?" -Options ([ordered]@{
                "P" = "Put them back in the project (most common -- you keep working)"
                "K" = "Leave them on the shelf for later (I'll see them with: git stash list)"
                "D" = "Discard them permanently (you don't want these edits anymore)"
                "V" = "Show me the shelved changes first, then ask again"
            })

            switch ($choice) {
                "P" {
                    Write-Action "Putting shelved changes back..."
                    Write-Explain "git calls this 'stash pop'."
                    $popOut = & git -C $dir stash pop $stashRef 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Good "Done. Your edits are back in place."
                    } else {
                        Write-Warn "Putting them back caused a conflict with the newly pulled code."
                        Write-Explain "Your edits and the server's updates touched the same lines. The shelf is still safe -- resolve the conflict in your editor, or run: git stash drop $stashRef to toss them."
                        $summary.StashesKept += "$name ($stashLabel)"
                        $summary.NeedsAttn += "$name (stash pop conflict)"
                    }
                    $decided = $true
                }
                "K" {
                    Write-Good "Left on the shelf. Recover later with: git stash pop $stashRef"
                    $summary.StashesKept += "$name ($stashLabel)"
                    $decided = $true
                }
                "D" {
                    # Extra confirm because this is destructive
                    $confirm = Read-Host "    Really discard? This can't be undone. Type YES to confirm"
                    if ($confirm -eq "YES") {
                        & git -C $dir stash drop $stashRef 2>&1 | Out-Null
                        Write-Good "Discarded."
                        $decided = $true
                    } else {
                        Write-Host "    Cancelled. Pick again." -ForegroundColor DarkYellow
                    }
                }
                "V" {
                    Write-Host ""
                    Write-Host "    --- Shelved changes ---" -ForegroundColor DarkCyan
                    & git -C $dir stash show -p $stashRef | Out-Host
                    Write-Host "    --- end ---" -ForegroundColor DarkCyan
                }
            }
        }
    }

    $summary.Synced += $name
    Write-Host ""
}

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
Write-Status $Separator "DarkGray"
Write-Host ""
Write-Status "SUMMARY" "Cyan"

if ($summary.AlreadyClean.Count -gt 0) {
    Write-Status "  Already in sync ($($summary.AlreadyClean.Count)):" "Green"
    $summary.AlreadyClean | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkGreen }
}
if ($summary.Synced.Count -gt 0) {
    Write-Status "  Updated ($($summary.Synced.Count)):" "Cyan"
    $summary.Synced | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkCyan }
}
if ($summary.StashesKept.Count -gt 0) {
    Write-Status "  Shelves left for later ($($summary.StashesKept.Count)):" "Yellow"
    $summary.StashesKept | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkYellow }
    Write-Host "    (see them anytime with: git stash list)" -ForegroundColor DarkGray
}
if ($summary.NeedsAttn.Count -gt 0) {
    Write-Status "  Needs your attention ($($summary.NeedsAttn.Count)):" "Red"
    $summary.NeedsAttn | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkRed }
}
if ($summary.Skipped.Count -gt 0) {
    Write-Status "  Skipped ($($summary.Skipped.Count)):" "DarkGray"
    $summary.Skipped | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkGray }
}

Write-Host ""
Write-Status "Done." "DarkGray"

if ($Host.Name -eq "ConsoleHost") {
    Write-Host ""
    Write-Host "Press any key to exit..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
