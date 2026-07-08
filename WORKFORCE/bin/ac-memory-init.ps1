# ac-memory-init.ps1 -- initialize Claude Code auto-memory git-sync on Windows.
#
# Windows counterpart to bin/ac-memory-init (bash). Moves existing Claude Code
# memory at $env:USERPROFILE\.claude\projects\<encoded>\memory\ into
# $env:USERPROFILE\OPS\.claude-memory\<hostname>-<encoded>\ and creates
# a symbolic link from the original path to the new target.
#
# Per doctrine 2026-05-13__memory-sync-doctrine.md (Option A: drafts graduate
# to CONTEXT/).
#
# Requires: PowerShell 5.1+ AND one of:
#   - Developer Mode enabled (Windows 10 1703+) -- allows non-admin symlinks
#   - Administrator PowerShell session
#
# Usage:
#   .\ac-memory-init.ps1                       # standard
#   .\ac-memory-init.ps1 -HostnameOverride foo # override hostname
#   .\ac-memory-init.ps1 -DryRun               # show what would happen
#   .\ac-memory-init.ps1 -AutoCommit           # after init, stage+commit+push
#                                                the new memory subdir
#
# Exit codes:
#   0 -- success (already initialized OR initialized just now)
#   1 -- error
#   2 -- gitignore conflict

[CmdletBinding()]
param(
    [string]$HostnameOverride = "",
    [switch]$DryRun,
    [switch]$AutoCommit
)

$ErrorActionPreference = "Stop"

function Log($msg)   { Write-Host "[ac-memory-init] $msg" }
function Dry($msg)   { Log "[dry-run] $msg" }
function Die($msg)   { Write-Error "ac-memory-init: $msg"; exit 1 }

$Ops      = if ($env:OPS_DIR) { $env:OPS_DIR } else { Join-Path $env:USERPROFILE "OPS" }
$MemoryRoot  = Join-Path $Ops ".claude-memory"

# Hostname: lowercase, no whitespace.
$Host_       = if ($HostnameOverride) { $HostnameOverride } else { $env:COMPUTERNAME }
$Host_       = ($Host_ -replace '\s', '').ToLower()
if (-not $Host_) { Die "could not determine hostname" }

# Claude Code path encoding on Windows: replace \ and / with -, including drive letter colon.
# E.g., C:\Users\SampleUser -> -C--Users-SampleUser (Claude actually uses this -- verify on first run).
# Easiest robust derivation: take $env:USERPROFILE and apply same scheme.
$UP = $env:USERPROFILE
$Encoded = $UP -replace '[\\/]', '-' -replace ':', '-'
if (-not $Encoded) { Die "could not derive encoded user-profile path" }

$Target       = Join-Path $MemoryRoot ("${Host_}-${Encoded}")
$TargetRel    = ".claude-memory/${Host_}-${Encoded}"
$Source       = Join-Path $env:USERPROFILE (".claude\projects\$Encoded\memory")
$SourceParent = Split-Path -Parent $Source

Log "host:    $Host_"
Log "encoded: $Encoded"
Log "target:  $Target"
Log "source:  $Source"

# Sanity: OPS present.
if (-not (Test-Path $Ops)) { Die "OPS not found at $Ops -- clone the repo first" }

# Sanity: gitignore not excluding target. Best-effort check.
if (Get-Command git -ErrorAction SilentlyContinue) {
    Push-Location $Ops
    try {
        $checkPath = "$TargetRel/MEMORY.md"
        $null = git check-ignore -q $checkPath 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Error "ac-memory-init: .gitignore excludes $Target -- fix .gitignore first"
            exit 2
        }
    } finally { Pop-Location }
}

# --- Initialization cases (mutually exclusive) -------------------------------
# Case 1: already a symlink.
# Case 2: source is real directory with files.
# Case 3: source doesn't exist.

$sourceItem = $null
if (Test-Path $Source) {
    $sourceItem = Get-Item $Source -Force
}

# Treat both SymbolicLink and Junction as already-linked reparse points.
# deploy.ps1 falls back to Junction when Developer Mode + admin both
# absent, so a fresh re-run after a junction fallback would mis-classify
# the source as a real directory and try to symlink over it.
$isReparsePoint = $false
if ($sourceItem) {
    $isReparsePoint = ($sourceItem.LinkType -eq "SymbolicLink" -or $sourceItem.LinkType -eq "Junction")
}

if ($isReparsePoint) {
    $existing = $sourceItem.Target
    if ($existing -is [array]) { $existing = $existing[0] }
    $existingResolved = (Resolve-Path -LiteralPath $existing -ErrorAction SilentlyContinue).Path
    $targetResolved   = if (Test-Path $Target) { (Resolve-Path -LiteralPath $Target).Path } else { $Target }
    if ($existingResolved -eq $targetResolved) {
        Log "already initialized -- symlink points at $Target"
    } else {
        Log "existing symlink points elsewhere: $existing"
        if ($DryRun) {
            Dry "would atomically repoint: $Source -> $Target"
        } else {
            if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Force -Path $Target | Out-Null }
            if (Test-Path $existing) {
                $existingItem = Get-Item $existing -Force
                if ($existingItem.PSIsContainer) {
                    Get-ChildItem -LiteralPath $existing -Force | ForEach-Object {
                        Move-Item -LiteralPath $_.FullName -Destination $Target -Force -ErrorAction SilentlyContinue
                    }
                    Remove-Item -LiteralPath $existing -Force -ErrorAction SilentlyContinue
                }
            }
            Remove-Item -LiteralPath $Source -Force
            New-Item -ItemType SymbolicLink -Path $Source -Target $Target | Out-Null
            Log "symlink repointed: $Source -> $Target"
        }
    }
} elseif ($sourceItem -and $sourceItem.PSIsContainer) {
    Log "source is real directory -- will migrate"
    if ($DryRun) {
        Dry "would create $Target"
        Dry "would move files from $Source to $Target"
        Dry "would remove $Source"
        Dry "would create symlink: $Source -> $Target"
    } else {
        New-Item -ItemType Directory -Force -Path $Target | Out-Null
        # Use $script:moved consistently (the ForEach-Object scriptblock
        # runs in a child scope; a plain $moved++ inside the block
        # increments a different variable and the outer print stays 0).
        $script:moved = 0
        Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
            $destPath = Join-Path $Target $_.Name
            if (Test-Path $destPath) {
                Log "skip (already in target): $($_.Name)"
                return
            }
            Move-Item -LiteralPath $_.FullName -Destination $Target
            $script:moved++
        }
        Log "moved $($script:moved) file(s) into target"
        $remaining = Get-ChildItem -LiteralPath $Source -Force
        if ($remaining) { Die "source $Source not empty after move -- investigate" }
        Remove-Item -LiteralPath $Source -Force
        New-Item -ItemType SymbolicLink -Path $Source -Target $Target | Out-Null
        Log "symlinked: $Source -> $Target"
    }
} else {
    Log "no existing memory at source -- creating empty target and symlink"
    if ($DryRun) {
        Dry "would create $Target"
        Dry "would create $SourceParent"
        Dry "would create symlink: $Source -> $Target"
    } else {
        New-Item -ItemType Directory -Force -Path $Target | Out-Null
        New-Item -ItemType Directory -Force -Path $SourceParent | Out-Null
        try {
            New-Item -ItemType SymbolicLink -Path $Source -Target $Target | Out-Null
        } catch {
            Die "symlink creation failed -- enable Developer Mode (Settings > Update & Security > For Developers) OR run as Administrator. Error: $_"
        }
        Log "symlinked: $Source -> $Target (empty target ready for first write)"
    }
}

# --- Optional auto-commit + push of the new memory subdir --------------------
# Only fires when -AutoCommit is set AND there's actually something new to
# commit at the target path. Stages ONLY the target subdir by exact path.
# Never touches other modified files. Graceful degradation on any failure.

if ($AutoCommit -and -not $DryRun) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Log "auto-commit: git not in PATH, skipping"
        exit 0
    }
    Push-Location $Ops
    try {
        $statusOut = git status --porcelain $TargetRel 2>$null
        if (-not $statusOut) {
            Log "auto-commit: nothing new at $TargetRel -- skipping"
            exit 0
        }

        Log "auto-commit: staging $TargetRel"
        git add $TargetRel 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Log "auto-commit: git add failed -- leaving as untracked, continuing"
            exit 0
        }

        $commitMsg = "feat(memory): seed .claude-memory/ from $Host_ host"
        git commit -m $commitMsg 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Log "auto-commit: committed ($commitMsg)"
            git push 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Log "auto-commit: pushed to remote"
            } else {
                Log "auto-commit: push failed (network? auth? upstream config?) -- commit landed locally; recover with: cd $Ops; git push"
            }
        } else {
            Log "auto-commit: commit failed (hook? signing? pre-commit?) -- files staged but uncommitted; inspect with: cd $Ops; git status"
        }
    } finally { Pop-Location }
}

exit 0
