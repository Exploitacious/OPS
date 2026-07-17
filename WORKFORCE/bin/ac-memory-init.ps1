# ac-memory-init.ps1 -- initialize Claude Code auto-memory git-sync on Windows.
#
# Windows counterpart to bin/ac-memory-init (bash). Walks Claude Code's encoded
# cwd subdirs under <config>/projects/<encoded>/memory/ and links each into
# $HOME\OPS\.claude-memory\<host>-<encoded>\ so per-session memory survives
# in this repo. Handles the HOME cwd AND every project cwd, not just the home
# dir. Honors $env:CLAUDE_CONFIG_DIR, so a second profile (if you run one)
# wires into the same shared OPS store.
#
# Per doctrine 2026-05-13__memory-sync-doctrine.md (Option A: drafts graduate
# to CONTEXT/).
#
# Links are created symlink-first with an NTFS junction fallback (junctions
# need no Developer Mode / admin for a local target), verified before any
# source is removed -- see New-DirLink + the create-link-first pattern below.
#
# Usage:
#   .\ac-memory-init.ps1                        # walk all encoded cwds (default)
#   .\ac-memory-init.ps1 -OnlyHome              # only the HOME cwd
#   .\ac-memory-init.ps1 -HostnameOverride foo  # override host key
#   .\ac-memory-init.ps1 -DryRun                # show what would happen
#   .\ac-memory-init.ps1 -AutoCommit            # stage+commit+push each target
#
# Exit codes:
#   0 -- success (already initialized OR initialized just now)
#   1 -- error
#   2 -- gitignore conflict for the HOME-encoded path (others are skipped)

[CmdletBinding()]
param(
    [string]$HostnameOverride = "",
    [switch]$DryRun,
    [switch]$AutoCommit,
    [switch]$OnlyHome
)

$ErrorActionPreference = "Stop"

function Log($msg)   { Write-Host "[ac-memory-init] $msg" }
function Dry($msg)   { Log "[dry-run] $msg" }
function Die($msg)   { Write-Error "ac-memory-init: $msg"; exit 1 }

# Create a directory link at $LinkPath pointing to $TargetPath. Prefers a
# symlink (needs Developer Mode / admin); falls back to an NTFS junction, which
# needs NO privilege for a local directory target. Verifies the result is a
# resolving reparse point. Returns $true on success, $false on total failure.
# The safety net behind create-link-first: callers must NEVER remove the real
# source before a link is proven.
function New-DirLink {
    param([string]$LinkPath, [string]$TargetPath)
    try {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath -ErrorAction Stop | Out-Null
    } catch {
        try {
            New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath -ErrorAction Stop | Out-Null
        } catch {
            return $false
        }
    }
    if (-not (Test-Path $LinkPath)) { return $false }
    $it = Get-Item $LinkPath -Force
    return ($it.LinkType -in @('SymbolicLink', 'Junction'))
}

$Ops        = if ($env:OPS_DIR) { $env:OPS_DIR } else { Join-Path $env:USERPROFILE "OPS" }
$MemoryRoot = Join-Path $Ops ".claude-memory"

# Config dir: defaults to ~/.claude; a second profile sets CLAUDE_CONFIG_DIR.
# Every profile wires into the same shared store.
$ClaudeCfg  = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".claude" }

# Host key: lowercase, no whitespace. COMPUTERNAME is a real hostname on
# Windows (never generic), so no machine-id fallback is needed here.
$Host_ = if ($HostnameOverride) { $HostnameOverride } else { $env:COMPUTERNAME }
$Host_ = ($Host_ -replace '\s', '').ToLower()
if (-not $Host_) { Die "could not determine host key" }

# Claude Code encodes a cwd by replacing \ / : with -. The HOME cwd's encoded
# form equals the name of its projects/ subdir; derive it from USERPROFILE.
$HomeEncoded = $env:USERPROFILE -replace '[\\/]', '-' -replace ':', '-'
if (-not $HomeEncoded) { Die "could not derive encoded home path" }

Log "host:         $Host_"
Log "config dir:   $ClaudeCfg"
Log "home-encoded: $HomeEncoded"
Log ("mode:         " + $(if ($OnlyHome) { "only-home" } else { "all-cwds" }))

if (-not (Test-Path $Ops)) { Die "OPS not found at $Ops -- clone the repo first" }

# Per-path .gitignore check. Returns $true if the target rel path is ignored.
function Test-TargetIgnored($targetRel) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
    Push-Location $Ops
    try {
        $null = git check-ignore -q "$targetRel/MEMORY.md" 2>$null
        return ($LASTEXITCODE -eq 0)
    } finally { Pop-Location }
}

# --- init_one_encoded: process a single encoded cwd subdir -------------------
function Init-OneEncoded {
    param([string]$Encoded)

    $target       = Join-Path $MemoryRoot "${Host_}-${Encoded}"
    $targetRel    = ".claude-memory/${Host_}-${Encoded}"
    $source       = Join-Path $ClaudeCfg "projects\$Encoded\memory"
    $sourceParent = Split-Path -Parent $source

    Log "[$Encoded] target=$targetRel"

    # gitignore: fatal for HOME, skip for others.
    if (Test-TargetIgnored $targetRel) {
        if ($Encoded -eq $HomeEncoded) {
            Write-Error "ac-memory-init: .gitignore excludes $target (fatal for HOME path)"
            exit 2
        }
        Log "[$Encoded] .gitignore excludes target -- skipping"
        return
    }

    # Treat both SymbolicLink and Junction as already-linked reparse points --
    # a junction-fallback run must not be mis-classified as a real directory.
    $sourceItem = if (Test-Path $source) { Get-Item $source -Force } else { $null }
    $isReparse  = $sourceItem -and ($sourceItem.LinkType -in @('SymbolicLink', 'Junction'))

    if ($isReparse) {
        # Case 1: link already in place -- no-op or repoint.
        $existing = $sourceItem.Target
        if ($existing -is [array]) { $existing = $existing[0] }
        $existingResolved = (Resolve-Path -LiteralPath $existing -ErrorAction SilentlyContinue).Path
        $targetResolved   = if (Test-Path $target) { (Resolve-Path -LiteralPath $target).Path } else { $target }
        if ($existingResolved -eq $targetResolved) {
            Log "[$Encoded] already initialized"
        }
        elseif ($DryRun) {
            Dry "[$Encoded] would repoint (create-link-first) -> $target"
        }
        else {
            if (-not (Test-Path $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
            if (Test-Path $existing) {
                $existingItem = Get-Item $existing -Force
                if ($existingItem.PSIsContainer) {
                    Get-ChildItem -LiteralPath $existing -Force | ForEach-Object {
                        Move-Item -LiteralPath $_.FullName -Destination $target -Force -ErrorAction SilentlyContinue
                    }
                    Remove-Item -LiteralPath $existing -Force -ErrorAction SilentlyContinue
                }
            }
            Remove-Item -LiteralPath $source -Force
            if (New-DirLink -LinkPath $source -TargetPath $target) {
                Log "[$Encoded] link repointed -> $target"
            }
            else {
                Die "[$Encoded] could not create symlink or junction $source -> $target. Memory is safe in $target; re-run with Developer Mode / Administrator."
            }
        }
    }
    elseif ($sourceItem -and $sourceItem.PSIsContainer) {
        # Case 2: real directory -- migrate (create-link-first, safe).
        Log "[$Encoded] source is real directory -- migrating"
        if ($DryRun) {
            Dry "[$Encoded] would migrate $source -> $target and link"
        }
        else {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            # Migrate files into $target FIRST (memory preserved before $source
            # is touched). Track what we move so recovery restores only our
            # files, not a shared target's content. A List works from inside
            # the ForEach-Object scriptblock (child scope) because .Add()
            # mutates the object -- a plain counter would silently stay 0.
            $movedNames = New-Object System.Collections.Generic.List[string]
            Get-ChildItem -LiteralPath $source -Force | ForEach-Object {
                $destPath = Join-Path $target $_.Name
                if (Test-Path $destPath) { Log "[$Encoded] skip (already in target): $($_.Name)"; return }
                Move-Item -LiteralPath $_.FullName -Destination $target
                $movedNames.Add($_.Name)
            }
            Log "[$Encoded] moved $($movedNames.Count) file(s)"
            $remaining = Get-ChildItem -LiteralPath $source -Force
            if ($remaining) { Die "[$Encoded] source $source not empty after move -- investigate (nothing removed)" }
            Remove-Item -LiteralPath $source -Force
            if (New-DirLink -LinkPath $source -TargetPath $target) {
                Log "[$Encoded] linked -> $target"
            }
            else {
                # Recovery: restore only the files we moved so memory is never orphaned.
                New-Item -ItemType Directory -Force -Path $source | Out-Null
                foreach ($n in $movedNames) {
                    $p = Join-Path $target $n
                    if (Test-Path $p) { Move-Item -LiteralPath $p -Destination (Join-Path $source $n) -Force -ErrorAction SilentlyContinue }
                }
                Die "[$Encoded] could not create symlink or junction. Memory restored to $source (un-synced, intact). Enable Developer Mode or run as Administrator, then re-run."
            }
        }
    }
    else {
        # Case 3: no source. Only create-empty-and-link for the HOME cwd; never
        # proliferate empty subdirs for project cwds with no memory yet.
        if ($Encoded -eq $HomeEncoded) {
            Log "[$Encoded] no memory yet -- creating empty target + link (HOME path)"
            if ($DryRun) {
                Dry "[$Encoded] would create target + parent + link"
            }
            else {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                New-Item -ItemType Directory -Force -Path $sourceParent | Out-Null
                if (New-DirLink -LinkPath $source -TargetPath $target) {
                    Log "[$Encoded] linked -> $target (empty target ready for first write)"
                }
                else {
                    Die "[$Encoded] link creation failed -- enable Developer Mode (Settings > Privacy & Security > For developers) OR run as Administrator."
                }
            }
        }
        else {
            Log "[$Encoded] no memory dir -- skipping (not HOME path)"
            return
        }
    }

    # --- per-encoded auto-commit + push -------------------------------------
    if ($AutoCommit -and -not $DryRun) {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Log "[$Encoded] auto-commit: git not in PATH, skipping"
            return
        }
        Push-Location $Ops
        try {
            $statusOut = git status --porcelain $targetRel 2>$null
            if (-not $statusOut) { Log "[$Encoded] auto-commit: nothing new -- skipping"; return }
            Log "[$Encoded] auto-commit: staging $targetRel"
            git add $targetRel 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { Log "[$Encoded] auto-commit: git add failed -- leaving untracked"; return }
            $commitMsg = "feat(memory): seed .claude-memory/${Host_}-${Encoded}"
            git commit -m $commitMsg 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Log "[$Encoded] auto-commit: committed"
                git push 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { Log "[$Encoded] auto-commit: pushed" }
                else { Log "[$Encoded] auto-commit: push failed -- commit landed locally" }
            }
            else {
                Log "[$Encoded] auto-commit: commit failed (hook/signing?) -- staged but uncommitted"
            }
        } finally { Pop-Location }
    }
}

# --- Build the list of encoded subdirs to process ----------------------------
$encodedList = New-Object System.Collections.Generic.List[string]
$encodedList.Add($HomeEncoded)

if (-not $OnlyHome) {
    $projectsDir = Join-Path $ClaudeCfg "projects"
    if (Test-Path $projectsDir) {
        Get-ChildItem $projectsDir -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $enc = $_.Name
            if ($enc -eq $HomeEncoded) { return }
            $mem = Join-Path $_.FullName "memory"
            if (Test-Path $mem) { $encodedList.Add($enc) }   # real dir OR link
        }
    }
}

Log "processing $($encodedList.Count) encoded subdir(s): $($encodedList -join ', ')"
Write-Host ""

# One encoded subdir's unexpected exception (anything not routed through Die,
# which exits 1 immediately) must not silently downgrade to a warning -- the
# documented exit-code contract above promises 1 on error. Continue the loop
# so a bad subdir doesn't block the others from initializing, but remember the
# failure and reflect it in the final exit code instead of reporting success.
$hadError = $false

foreach ($enc in $encodedList) {
    try { Init-OneEncoded -Encoded $enc }
    catch { Log "[$enc] non-fatal error -- continuing: $_"; $hadError = $true }
    Write-Host ""
}

if ($hadError) {
    Log "done, with errors -- see above"
    exit 1
}
Log "done"
exit 0
