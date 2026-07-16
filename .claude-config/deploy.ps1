#Requires -Version 5.1
<#
.SYNOPSIS
    OPS Stage 2 deployer (Windows). Mirrors deploy.sh (Linux/macOS).
.DESCRIPTION
    Stage 2 owns everything OPS-specific. Stage 1 (linuxploitacious's
    winSetup.ps1) owns host setup + Level 1 Claude files. Do NOT deploy
    Level 1 files here.

    What this script does (in order):
      1. Symlink ~/.claude/{skills,commands,agents,workflows}/ -> OPS sources
      2. Wire WORKFORCE/bin PATH onto the untracked profile.local.ps1 seam
      3. Initialize Claude Code auto-memory git-sync (ac-memory-init.ps1)
      4. Seed the trust anchor ($HOME trusted, no folder-trust prompt)
      5. Emit the always-on ultracode shim to the profile.local.ps1 seam
      6. Register the daily backup scheduled task (dynamic bash + WorkingDirectory)
      7. Install caveman Claude Code plugin (with CLI fallback probe)
      8. Pin CLAUDE_CODE_GIT_BASH_PATH + run the security-guard self-test

    All host-specific content goes to the untracked profile.local.ps1 seam, never
    $PROFILE (a shim/symlink tied to the PUBLIC linuxploitacious repo).

    Note: claude-wrapper (root/user flock) is Linux-only -- Windows
    runs single-user so the wrapper isn't needed here.

    Idempotent -- safe to re-run after any OPS git pull.
    Full procedure: see ~/OPS/DEPLOYMENT.md.
#>

$ErrorActionPreference = "Stop"

# --- Colors & Helpers ---
function Write-Status  { param([string]$Msg, [string]$Color = "White") Write-Host $Msg -ForegroundColor $Color }
function Write-Action  { param([string]$Msg) Write-Host "  -> $Msg" -ForegroundColor Cyan }
function Write-Good    { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn    { param([string]$Msg) Write-Host "  [!!] $Msg" -ForegroundColor Yellow }
function Write-Bad     { param([string]$Msg) Write-Host "  [XX] $Msg" -ForegroundColor Red }

# --- Paths ---
$ConfigDir  = $PSScriptRoot
$ClaudeHome = Join-Path $env:USERPROFILE ".claude"
$BackupDir  = Join-Path $ConfigDir "backup"

# Level 1 files (settings.json, CLAUDE.md, statusline.sh) come from
# linuxploitacious -- deploy.ps1 must NOT deploy them.

# --- Untracked machine-local profile seam ---
# OPS-specific, host-specific content (WORKFORCE/bin PATH, ultracode shim) is
# written to profile.local.ps1 -- an UNTRACKED file the tracked
# linuxploitacious profile sources at its end -- NEVER to $PROFILE.
# $PROFILE is a symlink/shim tied to the PUBLIC linuxploitacious repo;
# appending there dirties that repo and freezes its Stage-1 auto-sync.
# Mirrors deploy.sh's ensure_*_localrc writing to ~/.<shell>rc.local.
function Get-ProfileSeamPaths {
    # One seam per PowerShell edition dir (PS7 + PS5.1). Resolved via the
    # Documents special folder -- same call winSetup uses -- so it survives
    # OneDrive Known Folder Move.
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $paths = @()
    foreach ($ed in @('PowerShell', 'WindowsPowerShell')) {
        $paths += (Join-Path (Join-Path $docs $ed) 'profile.local.ps1')
    }
    return $paths
}

function Add-SeamBlock {
    # Idempotently append a block to every profile seam. Refuses to write to a
    # symlink (defense in depth, mirrors deploy.sh's symlink guard): the seam
    # must be a real, untracked, host-local file. Returns $true if the block is
    # present in at least one seam afterward.
    param(
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Body,
        [string]$MatchLine   # extra substring that must also be present, so a
                             # stale marker with a removed body still re-writes
    )
    $ok = $false
    foreach ($seam in (Get-ProfileSeamPaths)) {
        $dir = Split-Path $seam -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (Test-Path $seam) {
            $it = Get-Item $seam -Force
            if ($it.LinkType -in @('SymbolicLink', 'Junction')) {
                Write-Warn "$seam is a symlink -- refusing to append (expected a real untracked file)."
                continue
            }
        } else {
            New-Item -ItemType File -Path $seam -Force | Out-Null
        }
        $content = Get-Content $seam -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Contains($Marker) -and (-not $MatchLine -or $content.Contains($MatchLine))) {
            Write-Good "Already in $(Split-Path $seam -Leaf): $Marker"
            $ok = $true
            continue
        }
        Add-Content -Path $seam -Value ("`r`n" + $Body)
        Write-Good "Wrote to $(Split-Path (Split-Path $seam -Parent) -Leaf)\$(Split-Path $seam -Leaf): $Marker"
        $ok = $true
    }
    return $ok
}

# --- Header ---
Write-Host ""
Write-Status "CLAUDE CODE CONFIG DEPLOY" "Cyan"
Write-Status ("-" * 50) "DarkGray"
Write-Host ""

# --- Ensure ~/.claude/ exists ---
if (-not (Test-Path $ClaudeHome)) {
    New-Item -ItemType Directory -Path $ClaudeHome -Force | Out-Null
    Write-Good "Created $ClaudeHome"
}

# --- Symlink skills, commands, agents & workflows directories ---
# skills/ links to ../SKILLS (canonical source library, shared with GUI Projects).
# commands/, agents/, workflows/ link to .claude-config/* (CC-only). Mirrors deploy.sh.
Write-Host ""
Write-Status "Linking skills, commands, agents & workflows directories..." "Yellow"

$OpsRoot = Split-Path $ConfigDir -Parent
$LinkMap = @(
    @{ Name = "skills";    Source = (Join-Path $OpsRoot "SKILLS") },
    @{ Name = "commands";  Source = (Join-Path $ConfigDir "commands") },
    @{ Name = "agents";    Source = (Join-Path $ConfigDir "agents") },
    @{ Name = "workflows"; Source = (Join-Path $ConfigDir "workflows") }
)

foreach ($entry in $LinkMap) {
    $subdir = $entry.Name
    $source = $entry.Source
    $target = Join-Path $ClaudeHome $subdir

    if (-not (Test-Path $source)) {
        Write-Warn "Source missing, skipping: $source"
        continue
    }

    # Already a correct symlink or junction
    if ((Test-Path $target) -and ((Get-Item $target).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $existing = (Get-Item $target).Target -replace '^\\\\\?\\', ''
        if ($existing -eq $source) {
            Write-Good "Already linked: $subdir/"
            continue
        }
        Write-Action "Updating symlink: $subdir/"
        Remove-Item $target -Force
    }
    elseif (Test-Path $target) {
        # Real directory -- back it up
        $stamp  = Get-Date -Format "yyyyMMdd_HHmmss"
        $backup = "${target}.backup_${stamp}"
        Move-Item $target $backup
        Write-Warn "Backed up existing $subdir/ to $backup"
    }

    try {
        New-Item -ItemType SymbolicLink -Path $target -Target $source -Force -ErrorAction Stop | Out-Null
        Write-Good "Linked: $subdir/ -> $source"
    }
    catch {
        # Fallback: NTFS junction (no admin required for local directories)
        try {
            New-Item -ItemType Junction -Path $target -Target $source -Force -ErrorAction Stop | Out-Null
            Write-Good "Junction: $subdir/ -> $source"
        }
        catch {
            Write-Bad "Failed to create symlink or junction for $subdir/."
            Write-Bad "  Enable Developer Mode or run as Administrator."
            Write-Bad "  Error: $_"
        }
    }
}

# --- WORKFORCE/bin (multi-agent helpers) ---
Write-Host ""
Write-Status "Wiring WORKFORCE/bin..." "Yellow"

$WorkforceBin = Join-Path $OpsRoot "WORKFORCE\bin"

if (Test-Path $WorkforceBin) {
    $pathTag = "# --- OPS WORKFORCE/bin PATH (localrc seam) ---"
    # Single-quoted here-string: resolved at RUNTIME (user-agnostic), never at
    # deploy time -- no hardcoded absolute path lands in the seam.
    $pathBody = @'
# --- OPS WORKFORCE/bin PATH (localrc seam) ---
$env:Path = "$(Join-Path $env:USERPROFILE 'OPS\WORKFORCE\bin');$env:Path"
'@
    if (Add-SeamBlock -Marker $pathTag -Body $pathBody -MatchLine 'WORKFORCE\bin') {
        Write-Good "WORKFORCE/bin wired onto PATH via profile.local.ps1 seam."
    }
    else {
        Write-Warn "Could not write WORKFORCE/bin PATH to any profile seam."
    }
}
else {
    Write-Warn "WORKFORCE/bin not found -- skipping PATH wiring."
}

# --- Claude Code auto-memory git-sync ---
# ac-memory-init.ps1 walks Claude's encoded cwd subdirs and symlinks
# each into .claude-memory/<host>-<encoded>/ so per-session memory
# survives in this repo. Idempotent + safe on every machine.
Write-Host ""
Write-Status "Initializing Claude Code auto-memory git-sync..." "Yellow"

$MemoryInit = Join-Path $OpsRoot "WORKFORCE\bin\ac-memory-init.ps1"

# Run the walker against an explicit config dir. Sets CLAUDE_CONFIG_DIR so the
# result never depends on the environment deploy.ps1 was launched from, and
# restores it after. If you run a second Claude Code profile via
# CLAUDE_CONFIG_DIR, call this again with that dir.
function Invoke-MemoryInit {
    param([string]$ConfigDir, [string]$Label)
    if (-not (Test-Path $MemoryInit)) { Write-Warn "ac-memory-init.ps1 not present -- skipping $Label memory sync."; return }
    $prev = $env:CLAUDE_CONFIG_DIR
    $env:CLAUDE_CONFIG_DIR = $ConfigDir
    try {
        & $MemoryInit -AutoCommit
        if ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) {
            Write-Good "Memory sync ($Label) initialized (or already in place)."
        }
        elseif ($LASTEXITCODE -eq 2) {
            Write-Warn "ac-memory-init ($Label): .gitignore excludes target. Fix and re-run."
        }
        else {
            Write-Warn "ac-memory-init ($Label) exited rc=$LASTEXITCODE -- inspect manually."
        }
    }
    catch {
        Write-Warn "ac-memory-init.ps1 ($Label) failed: $_"
    }
    finally {
        if ($null -eq $prev) { Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
        else { $env:CLAUDE_CONFIG_DIR = $prev }
    }
}

Invoke-MemoryInit -ConfigDir $ClaudeHome -Label "default"

# --- Trust anchor ---
# Mark $HOME trusted so Claude's parent-dir-walking trust check covers every
# repo beneath it -- no folder-trust prompt, ever. Keyed off $env:USERPROFILE
# (never a hardcoded username), merged into the existing .claude.json without
# touching other keys. Mirrors deploy.sh's seed_trust.
#
# NOTE: if you run a second Claude Code profile via CLAUDE_CONFIG_DIR (a
# separate .claude.json/.credentials.json sharing this config surface), run
# Set-TrustAnchor against that config dir too -- it is not covered
# automatically.
Write-Host ""
Write-Status "Seeding trust anchor..." "Yellow"

function Set-TrustAnchor {
    param([string]$ConfigDir, [string]$Label)
    $jf = Join-Path $ConfigDir ".claude.json"
    try {
        if (Test-Path $jf) { $cfg = Get-Content $jf -Raw | ConvertFrom-Json }
        else { $cfg = [pscustomobject]@{} }
        if (-not $cfg.PSObject.Properties['projects']) {
            $cfg | Add-Member -NotePropertyName projects -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $homeKey = $env:USERPROFILE
        if (-not $cfg.projects.PSObject.Properties[$homeKey]) {
            $cfg.projects | Add-Member -NotePropertyName $homeKey -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $cfg.projects.$homeKey | Add-Member -NotePropertyName hasTrustDialogAccepted -NotePropertyValue $true -Force
        $cfg | ConvertTo-Json -Depth 20 | Set-Content $jf -Encoding UTF8
        Write-Good "Trust anchor set ($Label)."
    }
    catch { Write-Warn "Could not seed $Label trust anchor: $_" }
}
Set-TrustAnchor -ConfigDir $ClaudeHome -Label "default"

# --- Always-on ultracode shim (operator directive) -> profile.local.ps1 seam ---
# Wrap `claude` so every interactive session runs with ultracode unless the
# caller already passed --settings. `& (Get-Command ... -CommandType
# Application)` reaches the real exe (PowerShell has no `command` builtin),
# avoiding function recursion. Mirrors deploy.sh's ensure_claude_localrc.
# Written to the untracked seam: forcing the token cost on every
# linuxploitacious cloner would be wrong.
$ultraTag = "# --- Always-on ultracode for interactive Claude Code ---"
$ultraBody = @'
# --- Always-on ultracode for interactive Claude Code ---
function claude {
    $exe = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { Write-Error "claude executable not found on PATH"; return }
    $hasSettings = $false
    foreach ($a in $args) { if ($a -eq '--settings') { $hasSettings = $true; break } }
    if ($hasSettings) { & $exe.Source @args }
    else { & $exe.Source --settings '{"ultracode":true}' @args }
}
'@
if (Add-SeamBlock -Marker $ultraTag -Body $ultraBody -MatchLine 'ultracode') {
    Write-Good "Always-on ultracode shim wired via profile.local.ps1 seam."
}
else {
    Write-Warn "Could not write ultracode shim to any profile seam."
}

# --- Register daily backup scheduled task ---
Write-Host ""
Write-Status "Checking daily backup task..." "Yellow"

$TaskName     = "OPS Daily Backup"
$BackupScript = Join-Path $BackupDir "daily-sync.sh"

# Resolve bash.exe from the INSTALLED Git (Git Bash) rather than trusting a
# hardcoded path. The retired daily-sync-task.xml baked in both a static Git
# path AND a hardcoded username (dead on any other box); we build the action
# dynamically from resolved git + $env:USERPROFILE instead.
function Resolve-BashExe {
    # git.exe can live at <root>\cmd\git.exe, <root>\bin\git.exe, OR
    # <root>\mingw64\bin\git.exe; bash.exe is always at <root>\bin\bash.exe
    # (also <root>\usr\bin\bash.exe). Walk up from git.exe to the true root
    # rather than assuming one level -- "one up + bin" misses the mingw64 case.
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        $dir = Split-Path $gitCmd.Source -Parent
        for ($i = 0; $i -lt 4 -and $dir; $i++) {
            foreach ($rel in @('bin\bash.exe', 'usr\bin\bash.exe')) {
                $c = Join-Path $dir $rel
                if (Test-Path $c) { return $c }
            }
            $dir = Split-Path $dir -Parent
        }
    }
    foreach ($c in @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

$BashExe = Resolve-BashExe

if (-not $BashExe) {
    Write-Warn "Could not resolve bash.exe (Git Bash) -- daily backup task NOT registered."
    Write-Warn "Install Git for Windows, then re-run deploy.ps1."
}
elseif (-not (Test-Path $BackupScript)) {
    Write-Warn "Backup script not found at $BackupScript -- skipping backup task."
}
else {
    try {
        # -l (login shell) so PATH/gh/git identity are present, matching cron.
        $bashArg  = '-l "{0}"' -f $BackupScript
        $action   = New-ScheduledTaskAction -Execute $BashExe -Argument $bashArg -WorkingDirectory $BackupDir
        $trigger  = New-ScheduledTaskTrigger -Daily -At '9:00AM'
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
                        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
                        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
            -Description "Daily backup of OPS directory to GitHub" -Force | Out-Null

        # Post-register verification: prove the action points at the REAL bash +
        # this box's script, so [OK] can't fire for a dead target.
        $reg = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $act = if ($reg) { $reg.Actions[0] } else { $null }
        if ($act -and $act.Execute -eq $BashExe -and $act.Arguments -like "*daily-sync.sh*" `
            -and (Test-Path $BashExe) -and (Test-Path $BackupScript)) {
            Write-Good "Daily backup task registered + verified -> $BashExe (daily 9:00 AM)."
        }
        else {
            Write-Warn "Task registered but could not be verified -- inspect:"
            Write-Warn "  Get-ScheduledTask -TaskName '$TaskName' | Select-Object -Expand Actions"
        }
    }
    catch {
        Write-Warn "Could not register backup task (run elevated once on a fresh box): $_"
    }
}

# --- Install Claude Code plugins ---
Write-Host ""
Write-Status "Checking Claude Code plugins..." "Yellow"

# Resolve the claude CLI. A bare deploy.ps1 re-run may reach here before a PATH
# refresh, so probe known install locations too (mirrors deploy.sh find_claude).
function Resolve-ClaudeCli {
    $c = Get-Command claude -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\claude.exe'),
        (Join-Path $env:APPDATA     'npm\claude.cmd'),
        (Join-Path $env:APPDATA     'npm\claude.ps1'),
        (Join-Path $env:LOCALAPPDATA 'Programs\claude\claude.exe'))) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

$claudeExe = Resolve-ClaudeCli
if ($claudeExe) {
    Write-Action "Registering caveman plugin marketplace..."
    $marketplaceOut = & $claudeExe plugin marketplace add JuliusBrussee/caveman 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Good "Marketplace registered."
        Write-Action "Installing caveman plugin..."
        $pluginOut = & $claudeExe plugin install caveman@caveman 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Good "Caveman plugin installed."
        }
        else {
            Write-Warn "Plugin install returned: $pluginOut"
            Write-Warn "Run manually: claude plugin install caveman@caveman"
        }
    }
    else {
        Write-Warn "Marketplace add returned: $marketplaceOut"
    }
}
else {
    Write-Warn "Claude CLI not found in PATH or standard install locations. Skipping plugin install."
    Write-Warn "Install Claude Code first: https://claude.ai/download"
}

# --- Git Bash pin + doctor (defense in depth) ---
# Git Bash is the shell for every hook + the statusLine. Claude Code
# auto-detects it, but pin CLAUDE_CODE_GIT_BASH_PATH (User env, machine-local
# -- NOT the tracked settings.json) so it never mis-resolves. deploy.ps1 can
# run standalone, so ensure it here too.
Write-Host ""
Write-Status "Pinning + verifying Git Bash..." "Yellow"
if ($BashExe -and (Test-Path $BashExe)) {
    $bashVer = & $BashExe -lc 'bash --version' 2>$null | Select-Object -First 1
    if ($bashVer) {
        # Re-pin when unset OR when the existing pin no longer resolves (stale
        # after a Git move/uninstall) -- not only when empty.
        $curPin = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')
        if (-not $curPin -or -not (Test-Path $curPin)) {
            [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $BashExe, 'User')
            $env:CLAUDE_CODE_GIT_BASH_PATH = $BashExe
            Write-Good "Pinned CLAUDE_CODE_GIT_BASH_PATH -> $BashExe"
        }
        else {
            Write-Good "CLAUDE_CODE_GIT_BASH_PATH already pinned -> $curPin"
        }
        Write-Good "Git Bash live: $bashVer"
    }
    else {
        Write-Warn "Git Bash resolved ($BashExe) but 'bash --version' produced no output."
    }
}
else {
    Write-Bad "Git Bash not found -- hooks + statusLine will be dead. Install Git for Windows."
}

# --- Security-guard self-test (prove fail-closed, not fail-open) ---
# On Windows a guard's helper can resolve to 127 and fall through `|| exit 0`,
# silently disabling every hard gate. This probes the deployed guards with
# blocked inputs and confirms they exit 2.
Write-Host ""
Write-Status "Verifying security guards enforce..." "Yellow"
$SelfTest = Join-Path $ConfigDir "hooks\guard-selftest.sh"
if ($BashExe -and (Test-Path $SelfTest)) {
    $selfUnix = (& $BashExe -lc "cygpath -u '$SelfTest'" 2>$null).Trim()
    $guardOut = & $BashExe -lc "'$selfUnix'" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Good "Security guards enforce (git-guard + secrets-guard block probes)."
    }
    else {
        Write-Bad "Guard self-test FAILED -- a hard gate may be disabled (jq installed?):"
        $guardOut | ForEach-Object { Write-Warn "  $_" }
    }
}
else {
    Write-Warn "Skipping guard self-test (Git Bash or guard-selftest.sh not found)."
}

# --- Summary ---
Write-Host ""
Write-Status ("-" * 50) "DarkGray"
Write-Good "Deploy complete."
Write-Host ""
Write-Host "  Config source:  $ConfigDir" -ForegroundColor DarkGray
Write-Host "  Claude home:    $ClaudeHome" -ForegroundColor DarkGray
Write-Host "  Memory store:   $(Join-Path $ConfigDir 'memory')" -ForegroundColor DarkGray
Write-Host ""

if ($Host.Name -eq "ConsoleHost") {
    Write-Host "Press any key to exit..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
