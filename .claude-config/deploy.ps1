#Requires -Version 5.1
<#
.SYNOPSIS
    OPS Stage 2 deployer (Windows). Mirrors deploy.sh (Linux/macOS).
.DESCRIPTION
    Stage 2 owns everything OPS-specific. Stage 1 (linuxploitacious's
    winSetup.ps1) owns host setup + Level 1 Claude files. Do NOT deploy
    Level 1 files here.

    What this script does (in order):
      1. Symlink ~/.claude/{skills,commands,agents,workflows}/ -> OPS/SKILLS/
         and OPS/.claude-config/{commands,agents,workflows}/
      2. Wire WORKFORCE/bin onto PATH (PowerShell `$PROFILE)
      3. Initialize Claude Code auto-memory git-sync (ac-memory-init.ps1)
      4. Register daily backup scheduled task
      5. Install caveman Claude Code plugin

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
    # Idempotent PATH addition in PowerShell profile.
    if (-not $PROFILE) {
        Write-Warn "PowerShell `$PROFILE not defined -- skipping PATH wiring."
    }
    else {
        $profileDir  = Split-Path $PROFILE -Parent
        $profilePath = $PROFILE

        if (-not (Test-Path $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        }
        if (-not (Test-Path $profilePath)) {
            New-Item -ItemType File -Path $profilePath -Force | Out-Null
        }

        $pathTag = "# --- OPS WORKFORCE/bin ---"
        $existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
        if ($existing -and $existing.Contains($pathTag)) {
            Write-Good "WORKFORCE/bin already on PATH in `$PROFILE"
        }
        else {
            $pathBlock = @"

$pathTag
`$env:Path = "$WorkforceBin;`$env:Path"
"@
            Add-Content -Path $profilePath -Value $pathBlock
            Write-Good "Added WORKFORCE/bin to `$PROFILE (open new PowerShell session to pick up)"
        }
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
if (Test-Path $MemoryInit) {
    try {
        & $MemoryInit -AutoCommit
        if ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) {
            Write-Good "Memory sync initialized (or already in place)."
        }
        elseif ($LASTEXITCODE -eq 2) {
            Write-Warn "ac-memory-init: .gitignore excludes target. Fix and re-run."
        }
        else {
            Write-Warn "ac-memory-init exited rc=$LASTEXITCODE -- inspect manually."
        }
    }
    catch {
        Write-Warn "ac-memory-init.ps1 failed: $_"
    }
}
else {
    Write-Warn "ac-memory-init.ps1 not present at $MemoryInit -- skipping."
}

# --- Register daily backup scheduled task ---
Write-Host ""
Write-Status "Checking daily backup task..." "Yellow"

$TaskName = "OPS Daily Backup"
$TaskXml  = Join-Path $BackupDir "daily-sync-task.xml"

if (Test-Path $TaskXml) {
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if ($existingTask) {
        # Check if the task action still points to the old path
        $currentAction = $existingTask.Actions[0].Arguments
        if ($currentAction -like "*claude-backup*") {
            Write-Action "Updating task to new config path..."
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Register-ScheduledTask -TaskName $TaskName -Xml (Get-Content $TaskXml -Raw) | Out-Null
            Write-Good "Task re-registered with updated path."
        }
        else {
            Write-Good "Task '$TaskName' already registered and up to date."
        }
    }
    else {
        Write-Action "Registering scheduled task..."
        try {
            Register-ScheduledTask -TaskName $TaskName -Xml (Get-Content $TaskXml -Raw) | Out-Null
            Write-Good "Task '$TaskName' registered (daily at 9:00 AM)."
        }
        catch {
            Write-Warn "Could not register task. Run as Administrator, or import manually:"
            Write-Warn "  schtasks /create /tn `"$TaskName`" /xml `"$TaskXml`""
        }
    }
}
else {
    Write-Warn "Task XML not found at $TaskXml -- skipping."
}

# --- Install Claude Code plugins ---
Write-Host ""
Write-Status "Checking Claude Code plugins..." "Yellow"

$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    Write-Action "Registering caveman plugin marketplace..."
    $marketplaceOut = & claude plugin marketplace add JuliusBrussee/caveman 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Good "Marketplace registered."
        Write-Action "Installing caveman plugin..."
        $pluginOut = & claude plugin install caveman@caveman 2>&1
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
    Write-Warn "Claude CLI not found in PATH. Skipping plugin install."
    Write-Warn "Install Claude Code first: https://claude.ai/download"
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
