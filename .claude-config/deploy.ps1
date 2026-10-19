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
      2. Link the always-loaded core: ~/.claude/rules/ops-core.md ->
         CONTEXT/core.md (a symlink; where Windows refuses one without
         Developer Mode, a rule file importing the core)
      3. Strip the retired fleet PATH block from the profile.local.ps1 seam
      4. Initialize Claude Code auto-memory git-sync (bin/memory-init.ps1)
      5. Seed the trust anchor ($HOME trusted, no folder-trust prompt)
      6. Emit the always-on ultracode shim to the profile.local.ps1 seam
      7. Register the daily backup scheduled task (dynamic bash + WorkingDirectory)
      8. Mount the shared skills: clone the public skill source under
         PROJECTS/ when absent, then run bin/skills-vendor.sh sync in Git Bash
      9. Retire the caveman + ponytail Claude Code plugins (uninstall if present)
     10. Pin CLAUDE_CODE_GIT_BASH_PATH + run the security-guard self-test

    -NoSystem skips the scheduled task (a system-wide registration), for test
    installs; deploy.sh's --no-system is the Linux counterpart.

    Never writes settings.json or the model pin: Stage 1 owns that file, and
    bin/model-probe.sh only reports whether the pinned models answer.

    All host-specific content goes to the untracked profile.local.ps1 seam, never
    $PROFILE (a shim/symlink tied to the PUBLIC linuxploitacious repo).

    Note: claude-root-wrapper.sh (root permission mode, shared-host lock) is Linux-only -- Windows
    runs single-user so the wrapper isn't needed here.

    Idempotent -- safe to re-run after any OPS git pull.
    Full procedure: see ~/OPS/DEPLOYMENT.md.
#>

param([switch]$NoSystem)

$ErrorActionPreference = "Stop"
# Steps that must not abort the rest record a failure here; the summary says so.
$DeployFailed = @()

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
# OPS-specific, host-specific content (the ultracode shim) is
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
        Write-Bad "Source missing, cannot link ${subdir}: $source"
        $DeployFailed += "link-$subdir"
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
            $DeployFailed += "link-$subdir"
        }
    }
}

# --- The always-loaded core: ~/.claude/rules/ops-core.md -> CONTEXT/core.md ---
# Claude Code loads every user rule file at launch on every launch path, so the
# core needs no launch flag (deploy.sh explains the choice). Prefer a symlink;
# Windows refuses one without Developer Mode or elevation, so fall back to a
# small rule file that imports the core by absolute path. UNVERIFIED on Windows:
# that Claude Code resolves a drive-letter import; run /context once to confirm.
Write-Host ""
Write-Status "Linking the always-loaded core..." "Yellow"
$CoreSrc     = Join-Path $OpsRoot "CONTEXT\core.md"
$CoreRuleDir = Join-Path $ClaudeHome "rules"
$CoreRule    = Join-Path $CoreRuleDir "ops-core.md"
# Claude imports end at an unescaped space, including in Windows profile names.
$CoreImport  = "@" + (($CoreSrc -replace '\\', '/') -replace ' ', '\ ')
function Set-CoreRule {
    if (-not (Test-Path -LiteralPath $CoreSrc -PathType Leaf)) { Write-Bad "CONTEXT\core.md missing at $CoreSrc -- sessions would boot without the core."; return $false }
    if (Test-Path $CoreRuleDir) {
        if ((Get-Item $CoreRuleDir -Force).LinkType) { Write-Bad "$CoreRuleDir is a link -- refusing to write into it."; return $false }
    } else { New-Item -ItemType Directory -Path $CoreRuleDir -Force | Out-Null }
    if (Test-Path $CoreRule) {
        $it = Get-Item $CoreRule -Force
        if ($it.LinkType -eq 'SymbolicLink') {
            $t = (@($it.Target)[0]) -replace '^\\\\\?\\', ''
            if ($t -eq $CoreSrc) { Write-Good "Core already linked: $CoreRule"; return $true }
            Remove-Item $CoreRule -Force
        }
        elseif (([IO.File]::ReadAllText($CoreRule)).Trim() -eq $CoreImport) { Write-Good "Core already imported: $CoreRule"; return $true }
        else {
            $backup = "$CoreRule.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Move-Item $CoreRule $backup
            Write-Warn "Backed up existing $CoreRule to $backup"
        }
    }
    try {
        New-Item -ItemType SymbolicLink -Path $CoreRule -Target $CoreSrc -ErrorAction Stop | Out-Null
        Write-Good "Linked core: $CoreRule -> $CoreSrc"
    }
    catch {
        # CreateNew refuses an entry that appeared while creating the symlink.
        # WriteAllText would follow that entry and could overwrite its target.
        $stream = $null
        try {
            $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes("$CoreImport`n")
            $stream = [IO.File]::Open($CoreRule, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $stream.Write($bytes, 0, $bytes.Length)
            Write-Good "Core imported through $CoreRule ($CoreImport); symlinks need Developer Mode here"
        }
        catch { Write-Bad "Cannot create core import at ${CoreRule}: $_"; return $false }
        finally { if ($stream) { $stream.Dispose() } }
    }
    return $true
}
if (-not (Set-CoreRule)) { $DeployFailed += 'core-rule' }

# --- Legacy cleanup: the retired fleet PATH block in profile.local.ps1 ---
# Earlier deploys appended a marker + PATH line for WORKFORCE\bin, which is
# gone. Remove exactly those two lines (and the blank line written before them)
# from every seam; anything the operator wrote stays. Case-sensitive exact
# matches (-ccontains), so a near-miss line is never touched.
$LegacyPathLines = @(
    '# --- OPS WORKFORCE/bin PATH (localrc seam) ---',
    '$env:Path = "$(Join-Path $env:USERPROFILE ''OPS\WORKFORCE\bin'');$env:Path"'
)
function Remove-SeamLines {
    param([string[]]$Lines, [string]$What)
    foreach ($seam in (Get-ProfileSeamPaths)) {
        if (-not (Test-Path $seam)) { continue }
        if ((Get-Item $seam -Force).LinkType) { Write-Warn "$seam is a link -- refusing $What cleanup."; continue }
        $content = [IO.File]::ReadAllLines($seam)
        if (-not ($content | Where-Object { $Lines -ccontains $_ })) { Write-Good "No $What in $(Split-Path $seam -Leaf)"; continue }
        $out = New-Object System.Collections.Generic.List[string]
        $held = $false
        foreach ($l in $content) {
            if ($l -eq '') { if ($held) { $out.Add('') }; $held = $true; continue }
            if ($Lines -ccontains $l) { $held = $false; continue }
            if ($held) { $out.Add('') }
            $held = $false
            $out.Add($l)
        }
        if ($held) { $out.Add('') }
        [IO.File]::WriteAllLines($seam, $out, (New-Object System.Text.UTF8Encoding $false))
        Write-Good "Removed $What from $seam"
    }
}
Write-Host ""
Write-Status "Cleaning up the retired fleet PATH block..." "Yellow"
Remove-SeamLines -Lines $LegacyPathLines -What "retired fleet PATH block"

# --- Git identity ---
# Every commit needs one: memory-init's auto-commit just below, the daily
# backup, and every agent commit. A machine with no user.name or user.email
# (git cannot guess one) made those commits fail while the deploy reported
# success. Ask git directly, as deploy.sh does, and fail the deploy with the fix.
# Returns $null when both identities resolve, else git's last error line.
function Test-GitIdentity {
    param([string]$Repo)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($var in 'GIT_AUTHOR_IDENT', 'GIT_COMMITTER_IDENT') {
            $out = @(& git -C $Repo var $var 2>&1)
            if ($LASTEXITCODE -ne 0) {
                $last = @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) | Select-Object -Last 1
                if (-not $last) { $last = "git var $var exited $LASTEXITCODE" }
                return $last
            }
        }
        return $null
    }
    catch { return "git could not run: $_" }
    finally { $ErrorActionPreference = $prevEap }
}
Write-Host ""
Write-Status "Checking the git identity..." "Yellow"
$identErr = Test-GitIdentity -Repo $OpsRoot
if ($null -eq $identErr) { Write-Good "git identity is set (commits, memory sync and the daily backup can run)." }
else {
    Write-Bad "git has no usable identity, so commits, memory sync and the daily backup fail: $identErr"
    Write-Action 'Set it once, then re-run deploy: git config --global user.name "Your Name"; git config --global user.email you@example.com'
    $DeployFailed += 'git-identity'
}

# --- Claude Code auto-memory git-sync ---
# bin\memory-init.ps1 walks Claude's encoded cwd subdirs and symlinks
# each into .claude-memory/<host>-<encoded>/ so per-session memory
# survives in this repo. Idempotent + safe on every machine.
Write-Host ""
Write-Status "Initializing Claude Code auto-memory git-sync..." "Yellow"

$MemoryInit = Join-Path $ConfigDir "bin\memory-init.ps1"

# Run the walker against an explicit config dir. Sets CLAUDE_CONFIG_DIR so the
# result never depends on the environment deploy.ps1 was launched from, and
# restores it after. If you run a second Claude Code profile via
# CLAUDE_CONFIG_DIR, call this again with that dir.
function Invoke-MemoryInit {
    param([string]$ConfigDir, [string]$Label)
    if (-not (Test-Path $MemoryInit)) { Write-Bad "memory-init.ps1 not present -- $Label memory sync failed."; $script:DeployFailed += 'memory-init'; return }
    $prev = $env:CLAUDE_CONFIG_DIR
    $prevOps = $env:OPS_DIR
    $env:CLAUDE_CONFIG_DIR = $ConfigDir
    # Deploy initializes this checkout, even when the invoking shell selected a
    # different OPS_DIR or this clone is not under the default ~/OPS path.
    $env:OPS_DIR = $OpsRoot
    try {
        & $MemoryInit -AutoCommit
        if ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) {
            Write-Good "Memory sync ($Label) initialized (or already in place)."
        }
        elseif ($LASTEXITCODE -eq 2) {
            Write-Warn "memory-init ($Label): .gitignore excludes target. Fix and re-run."
            $script:DeployFailed += 'memory-init'
        }
        else {
            Write-Warn "memory-init ($Label) exited rc=$LASTEXITCODE -- inspect manually."
            $script:DeployFailed += 'memory-init'
        }
    }
    catch {
        Write-Warn "memory-init.ps1 ($Label) failed: $_"
        $script:DeployFailed += 'memory-init'
    }
    finally {
        if ($null -eq $prev) { Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
        else { $env:CLAUDE_CONFIG_DIR = $prev }
        if ($null -eq $prevOps) { Remove-Item Env:\OPS_DIR -ErrorAction SilentlyContinue }
        else { $env:OPS_DIR = $prevOps }
    }
}

Invoke-MemoryInit -ConfigDir $ClaudeHome -Label "default"

# --- Trust anchor ---
# Mark $HOME trusted so Claude's parent-dir-walking trust check covers every
# repo beneath it -- no folder-trust prompt, ever. Keyed off $env:USERPROFILE
# (never a hardcoded username), merged into the existing .claude.json without
# touching other keys. Default app state is ~/.claude.json, beside ~/.claude/.
# Mirrors deploy.sh's seed_trust.
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
    $temp = Join-Path $ConfigDir ('.claude.json.tmp-' + [guid]::NewGuid())
    try {
        $entry = Get-Item -LiteralPath $jf -Force -ErrorAction SilentlyContinue
        if ($entry -and ($entry.LinkType -or $entry.PSIsContainer)) { throw 'App state is a link or directory; refusing to replace it' }
        $original = $null
        if ($entry) {
            $original = [IO.File]::ReadAllText($jf)
            # ConvertFrom-Json unwraps a one-element root array in PS 5.1.
            if ($original.TrimStart() -notmatch '^\{') { throw 'Expected an app-state JSON object' }
            $cfg = $original | ConvertFrom-Json -ErrorAction Stop
            if ($cfg -isnot [pscustomobject]) { throw 'Expected an app-state JSON object' }
        }
        else { $cfg = [pscustomobject]@{} }
        if (-not $cfg.PSObject.Properties['projects']) {
            $cfg | Add-Member -NotePropertyName projects -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        elseif ($cfg.projects -isnot [pscustomobject]) { throw 'Expected a projects object' }
        $homeKey = $env:USERPROFILE
        if (-not $cfg.projects.PSObject.Properties[$homeKey]) {
            $cfg.projects | Add-Member -NotePropertyName $homeKey -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        elseif ($cfg.projects.$homeKey -isnot [pscustomobject]) { throw 'Expected a project object' }
        $cfg.projects.$homeKey | Add-Member -NotePropertyName hasTrustDialogAccepted -NotePropertyValue $true -Force
        $json = $cfg | ConvertTo-Json -Depth 100 -WarningAction Stop
        [IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding $false))
        if ($entry) {
            if ([IO.File]::ReadAllText($jf) -cne $original -or (Get-Item -LiteralPath $jf -Force).LinkType) { throw 'App state changed during deployment; retry' }
            [IO.File]::Replace($temp, $jf, [NullString]::Value)
        }
        else { [IO.File]::Move($temp, $jf) }
        Write-Good "Trust anchor set ($Label)."
    }
    catch { Write-Bad "Could not seed $Label trust anchor: $_"; $script:DeployFailed += 'trust-anchor' }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
Set-TrustAnchor -ConfigDir $env:USERPROFILE -Label "default"

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

if ($NoSystem) {
    Write-Warn "-NoSystem: daily backup task not registered."
}
elseif (-not $BashExe) {
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

# --- Mount the shared skills (clone the public source once, then sync) ---
# Same contract as deploy.sh: clone Exploitacious/agent-skills over HTTPS only
# when absent (never pull an existing clone on a re-deploy), then mirror
# SKILLS/VENDORED.tsv with skills-vendor.sh in Git Bash (it falls back to tar
# where rsync is missing, as in a stock Git Bash).
Write-Host ""
Write-Status "Mounting shared skills..." "Yellow"
$SkillsSrcUrl = "https://github.com/Exploitacious/agent-skills.git"
$SkillsSrcDir = Join-Path $OpsRoot "PROJECTS\Exploitacious\agent-skills"
$Vendored     = Join-Path $OpsRoot "SKILLS\VENDORED.tsv"
if (-not ((Test-Path $Vendored) -and (Select-String -Path $Vendored -Pattern '^[^#\s]\S*\s+Exploitacious/agent-skills/' -Quiet))) {
    Write-Good "No mounted skills from Exploitacious/agent-skills in SKILLS\VENDORED.tsv"
}
else {
    $cloned = Test-Path (Join-Path $SkillsSrcDir ".git")
    if (-not $cloned -and (Test-Path $SkillsSrcDir)) {
        Write-Bad "$SkillsSrcDir exists but is not a git clone -- move it aside, then re-run."; $DeployFailed += 'skills-mount'
    }
    elseif (-not $cloned) {
        # Publish only a complete clone. Interrupted clones must not occupy the
        # canonical source path and prevent a later deploy from retrying.
        $cloneParent = Split-Path $SkillsSrcDir -Parent
        $cloneTemp = Join-Path $cloneParent ('.agent-skills.clone-' + [guid]::NewGuid())
        $prevEap = $ErrorActionPreference
        try {
            New-Item -ItemType Directory -Path $cloneParent -Force | Out-Null
            $ErrorActionPreference = "Continue"
            & git clone --quiet $SkillsSrcUrl $cloneTemp 2>&1 | Out-Null
            $cloneRc = $LASTEXITCODE
            $ErrorActionPreference = $prevEap
            if ($cloneRc -ne 0 -or -not (Test-Path (Join-Path $cloneTemp ".git"))) { throw "git clone failed (rc=$cloneRc)" }
            # Directory.Move refuses an existing destination instead of nesting
            # into or replacing a source another process created meanwhile.
            [IO.Directory]::Move($cloneTemp, $SkillsSrcDir)
            $cloned = $true
            Write-Good "Cloned $SkillsSrcUrl -> $SkillsSrcDir"
        }
        catch { Write-Bad "Could not clone ${SkillsSrcUrl}: $_. Mounted skills are missing; re-run to retry."; $DeployFailed += 'skills-mount' }
        finally {
            $ErrorActionPreference = $prevEap
            if (Test-Path -LiteralPath $cloneTemp) { Remove-Item -LiteralPath $cloneTemp -Recurse -Force }
        }
    }
    else { Write-Good "Skill source already cloned: $SkillsSrcDir (not pulled)" }
    if ($cloned) {
        if ($BashExe) {
            # Pass the root as data, including spaces and apostrophes. Piping a
            # constant script also avoids Windows PowerShell native argv quoting.
            $prevRoot = $env:OPS_DEPLOY_ROOT
            $prevEap = $ErrorActionPreference
            try {
                $env:OPS_DEPLOY_ROOT = $OpsRoot
                $ErrorActionPreference = "Continue"
                $mountScript = @'
opsUnix=$(cygpath -u "$OPS_DEPLOY_ROOT") || exit
OPS_DIR="$opsUnix" bash "$opsUnix/.claude-config/bin/skills-vendor.sh" sync || exit
# sync skips absent sources; verify every required mount before reporting success.
OPS_DIR="$opsUnix" bash "$opsUnix/.claude-config/bin/skills-vendor.sh" --check
exit $?
'@
                # Windows native pipelines append CRLF. Supply LF script lines
                # and exit before that appended newline can become shell input.
                $mountScript = ($mountScript -replace "`r", '') + "`n"
                $svOut = $mountScript | & $BashExe -ls 2>&1
                $svRc = $LASTEXITCODE
            }
            catch { $svOut = @($_); $svRc = 1 }
            finally {
                $ErrorActionPreference = $prevEap
                if ($null -eq $prevRoot) { Remove-Item Env:\OPS_DEPLOY_ROOT -ErrorAction SilentlyContinue }
                else { $env:OPS_DEPLOY_ROOT = $prevRoot }
            }
            if ($svRc -eq 0) {
                Write-Good "Mounted skills synced into SKILLS\"
                # The output is captured, and printed whole only on failure. A
                # successful sync can still have moved the Operator's own folder
                # aside (BACKUP) or put one back (RESTORED); show those lines, or
                # the folder leaves SKILLS\ with no notice.
                $svOut | Where-Object { "$_" -match '^(BACKUP|RESTORED) ' } | ForEach-Object { Write-Warn "  $_" }
            }
            else { Write-Bad "skills-vendor.sh sync or completeness check failed:"; $svOut | ForEach-Object { Write-Warn "  $_" }; $DeployFailed += 'skills-mount' }
        }
        else { Write-Bad "Git Bash not found -- mounted skills not synced (install Git for Windows, then re-run deploy.ps1)."; $DeployFailed += 'skills-mount' }
    }
}

# --- Claude Code plugins: retire caveman + ponytail ---
Write-Host ""
Write-Status "Retiring caveman + ponytail Claude Code plugins..." "Yellow"

# Resolve the claude CLI. A bare deploy.ps1 re-run may reach here before a PATH
# refresh, so probe known install locations too (mirrors deploy.sh find_claude).
function Resolve-ClaudeCli {
    # A loaded claude() launch shim is a function with an empty Source. Resolve
    # the application beneath it, as the shim itself does, on repeat deploys.
    $c = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
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

# This block used to INSTALL caveman, unpinned, from its third-party
# marketplace head, right after Stage 1 had uninstalled it; Stage 1 retires
# both plugins because their modes are now part of the harness's own operating
# rules. The CLI edits settings.json when removing a declared plugin or
# marketplace. Leave those declarations to Stage 1: CLI writes also follow
# its symlink into another checkout. Never delete plugin dirs by hand.
# The calls run with ErrorActionPreference Continue: the CLI writes to stderr
# when a plugin is already absent, and Windows PowerShell 5.1 turns redirected
# native stderr into a terminating error under "Stop".
$claudeExe = Resolve-ClaudeCli
function Invoke-PluginRetirement {
    param([string]$Cli)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
        $settingsPath = Join-Path $configDir 'settings.json'
        $settings = $null
        if (Test-Path $settingsPath) {
            try {
                $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $settings -or $settings -isnot [pscustomobject]) { throw 'Expected a settings object' }
                foreach ($key in @('enabledPlugins', 'extraKnownMarketplaces')) {
                    if ($null -ne $settings.$key -and $settings.$key -isnot [pscustomobject]) { throw 'Expected plugin declarations' }
                }
            }
            catch { Write-Warn "Cannot read plugin declarations in $settingsPath; retirement skipped."; return }
        }
        $pluginsOut = & $Cli plugin list --json 2>$null
        $pluginsRc = $LASTEXITCODE
        $marketsOut = & $Cli plugin marketplace list --json 2>$null
        $marketsRc = $LASTEXITCODE
        try {
            if ($pluginsRc -ne 0 -or $marketsRc -ne 0) { throw 'Inventory failed' }
            if (($pluginsOut -join "`n").TrimStart() -notmatch '^\[' -or ($marketsOut -join "`n").TrimStart() -notmatch '^\[') { throw 'Expected inventory arrays' }
            $plugins = @($pluginsOut -join "`n" | ConvertFrom-Json -ErrorAction Stop)
            $markets = @($marketsOut -join "`n" | ConvertFrom-Json -ErrorAction Stop)
        }
        catch { Write-Warn 'Cannot list plugin inventories; retirement skipped. Run: claude plugin list --json'; return }
        foreach ($plg in @('caveman', 'ponytail')) {
            $id = "${plg}@${plg}"
            if (($null -ne $settings.enabledPlugins -and $settings.enabledPlugins.PSObject.Properties[$id]) -or
                ($null -ne $settings.extraKnownMarketplaces -and $settings.extraKnownMarketplaces.PSObject.Properties[$plg])) {
                Write-Warn "Retired plugin $plg is declared in $settingsPath; removal would edit Stage-1 settings. Update Stage 1, then re-run deploy."
                continue
            }
            if (@($plugins | Where-Object { $_.id -eq $id -and $_.scope -ne 'user' }).Count -gt 0) {
                Write-Warn "Retired plugin $plg remains in a project or local scope; left unchanged to protect project settings."
            }
            if (@($plugins | Where-Object { $_.id -eq $id -and $_.scope -eq 'user' }).Count -gt 0) {
                & $Cli plugin uninstall $id --scope user 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Warn "Retired plugin $plg could not be removed (rc=$LASTEXITCODE); inspect: claude plugin list --json"; continue }
                Write-Good "Removed retired plugin: $plg"
            }
            # Unscoped removal can edit settings in the caller's project.
            if (@($markets | Where-Object { $_.name -eq $plg }).Count -gt 0) {
                & $Cli plugin marketplace remove $plg --scope user 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { Write-Good "Removed retired plugin marketplace: $plg" }
                else { Write-Warn "Retired marketplace $plg remains (rc=$LASTEXITCODE); inspect its declaration before removing it: claude plugin marketplace list --json" }
            }
        }
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
}
if ($claudeExe) {
    Invoke-PluginRetirement -Cli $claudeExe
}
else {
    Write-Warn "Claude CLI not found in PATH or standard install locations. Skipping plugin retirement."
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
if ($DeployFailed.Count -gt 0) {
    Write-Bad "Deploy finished with failures: $($DeployFailed -join ', '). Fix the [XX] lines above and re-run."
}
else { Write-Good "Deploy complete." }
Write-Host ""
Write-Host "  Config source:  $ConfigDir" -ForegroundColor DarkGray
Write-Host "  Claude home:    $ClaudeHome" -ForegroundColor DarkGray
Write-Host "  Always loaded:  $CoreRule -> $CoreSrc" -ForegroundColor DarkGray
Write-Host "  Memory store:   $(Join-Path $ConfigDir 'memory')" -ForegroundColor DarkGray
Write-Host ""

# Report an actionable process result before the interactive prompt, so failed
# unattended deployments cannot appear successful or wait for a keypress.
if ($DeployFailed.Count -gt 0) { exit 1 }

if ($Host.Name -eq "ConsoleHost") {
    Write-Host "Press any key to exit..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
