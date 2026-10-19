# memory-init.ps1 -- initialize Claude Code auto-memory git-sync on Windows.
#
# Windows counterpart to memory-init (bash, same folder). Walks Claude Code's encoded
# cwd subdirs under <config>/projects/<encoded>/memory/ and links each into
# $HOME\OPS\.claude-memory\<host>-<encoded>\ so per-session memory survives
# in this repo. Handles the HOME cwd AND every project cwd, not just the home
# dir. Honors $env:CLAUDE_CONFIG_DIR, so a second profile (if you run one)
# wires into the same shared OPS store.
#
# Per the 2026-05-13 memory-sync decision (Option A: drafts graduate to
# CONTEXT/; retired with the fleet protocol, read it in git history).
#
# Links are created symlink-first with an NTFS junction fallback (junctions
# need no Developer Mode / admin for a local target), verified before any
# source is removed -- see New-DirLink + the create-link-first pattern below.
#
# Usage:
#   .\memory-init.ps1                           # walk all encoded cwds (default)
#   .\memory-init.ps1 -OnlyHome                 # only the HOME cwd
#   .\memory-init.ps1 -HostnameOverride foo     # override host key
#   .\memory-init.ps1 -DryRun                   # show what would happen
#   .\memory-init.ps1 -AutoCommit               # stage+commit each target; push only
#                                               # to an origin Test-OriginPrivate
#                                               # verifies private (see below)
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

function Log($msg)   { Write-Host "[memory-init] $msg" }
function Dry($msg)   { Log "[dry-run] $msg" }
function Die($msg)   { Write-Error "memory-init: $msg"; exit 1 }

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

# Push gate: the PowerShell twin of bin/origin-private-check, kept in this file
# so a Windows deploy needs no Git Bash for it; keep the two in step.
# -AutoCommit pushes the Operator's memory, and a copy whose origin is public (a
# tryout clone of the public template, a copy made public by mistake, a public
# fork) would publish it, so the push happens only on Code 0. Every push URL of
# origin is checked, because that is where a push lands. Returns Code and Reason:
#   0  verified private (GitHub says private, or the opt-in covers the rest)
#   1  public: the template github.com/Exploitacious/OPS in any URL form or case,
#      or GitHub reports the repo public
#   2  unverified: no origin, gh missing or not signed in, an API or network
#      failure, an unparseable URL, or a host other than github.com
# Opt-in for a remote this cannot verify: `git -C <copy> config ops.pushVerified
# true`, read from the repo's own config only. It turns 2 into 0, never 1.
# Reasons name only host and owner/repo, never a URL's credentials.
function Test-OriginPrivate {
    param([string]$Dir)
    # Windows PowerShell 5.1 turns a native command's stderr into an error
    # record, which under the script's Stop preference would abort the run.
    $ErrorActionPreference = 'Continue'
    $template = 'exploitacious/ops'
    $githubHosts = @('github.com', 'www.github.com', 'ssh.github.com')
    $result = { param($Code, $Reason) [pscustomobject]@{ Code = $Code; Reason = $Reason } }

    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        return (& $result 2 'unverified: git is not installed')
    }
    $null = & git -C $Dir rev-parse --git-dir 2>$null
    if ($LASTEXITCODE -ne 0) { return (& $result 2 "unverified: $Dir is not a git repository") }
    $urls = @(& git -C $Dir remote get-url --push --all origin 2>$null | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if (-not $urls.Count) { return (& $result 2 "unverified: $Dir has no origin remote") }
    $optIn = ("$(& git -C $Dir config --local --bool --get ops.pushVerified 2>$null)".Trim() -eq 'true')

    $oks = New-Object System.Collections.Generic.List[string]
    $unverified = New-Object System.Collections.Generic.List[string]
    $ghBlocked = $false
    foreach ($url in $urls) {
        # Parse to host, owner/repo, and transport; credentials are dropped.
        $h = ''; $path = ''; $ssh = $false
        if ($url -match '^([A-Za-z][A-Za-z0-9+.-]*)://([^/]*)(.*)$') {
            $scheme = $Matches[1].ToLower(); $authority = ($Matches[2] -split '@')[-1]; $path = $Matches[3]
            if ($authority -match '^\[([^\]]*)\]') { $h = $Matches[1] } else { $h = ($authority -split ':')[0] }
            if ($scheme -in @('ssh', 'git+ssh', 'ssh+git')) { $ssh = $true }
            if ($scheme -eq 'file') { $h = '' }
        }
        elseif ($url -match '^([^/:]{2,}):(.*)$') {
            # [user@]host:path is ssh when no slash precedes the first colon; a
            # one-letter "host" is a Windows drive, so the pattern needs two.
            $h = ($Matches[1] -split '@')[-1]; $path = $Matches[2]; $ssh = $true
        }
        $h = $h.ToLower().TrimEnd('.')
        $path = $path.Trim('/')
        if ($path.ToLower().EndsWith('.git')) { $path = $path.Substring(0, $path.Length - 4).TrimEnd('/') }

        if (-not $h) { $unverified.Add('origin is a local path, not a GitHub repo'); continue }
        if ($h.StartsWith('-')) { $unverified.Add('origin has an unsafe host name'); continue }
        $label = $h
        $sshCmd = Get-Command ssh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ssh -and $h -notin $githubHosts -and $sshCmd) {
            $resolved = & $sshCmd.Source -G -- $h 2>$null | ForEach-Object { if ($_ -match '^hostname\s+(\S+)') { $Matches[1].ToLower() } } | Select-Object -First 1
            if ($resolved -in $githubHosts) { $label = "$h (ssh alias for $resolved)"; $h = $resolved }
        }
        if ($h -notin $githubHosts) { $unverified.Add("origin host $label is not github.com, so its visibility cannot be checked"); continue }
        $parts = $path -split '/'
        if ($path -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or ($parts | Where-Object { $_ -in @('.', '..') })) {
            $unverified.Add("cannot read owner/repo from the origin URL on $label"); continue
        }
        # The template check needs no network: a tryout clone is refused offline too.
        if ($path.ToLower() -eq $template) {
            return (& $result 1 "public: origin is the public OPS template (github.com/$path); create your own private copy from it (README.md, Spin-up) and point origin at that copy")
        }
        $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $gh) { $ghBlocked = $true; $unverified.Add("gh (GitHub CLI) is not installed, so github.com/$path cannot be checked"); continue }
        # --hostname pins github.com: a GH_HOST for an Enterprise server must not
        # answer for a github.com URL.
        $prevPrompt = $env:GH_PROMPT_DISABLED
        $env:GH_PROMPT_DISABLED = '1'
        try { $answer = "$(& $gh.Source api --hostname github.com "repos/$path" --jq .private 2>$null)".Trim(); $ghRc = $LASTEXITCODE }
        finally { if ($null -eq $prevPrompt) { Remove-Item Env:\GH_PROMPT_DISABLED -ErrorAction SilentlyContinue } else { $env:GH_PROMPT_DISABLED = $prevPrompt } }
        if ($ghRc -ne 0) { $ghBlocked = $true; $unverified.Add("gh could not read github.com/$path (exit ${ghRc}: not signed in, no access, or offline)"); continue }
        switch ($answer) {
            'true'  { $oks.Add("github.com/$path is private") }
            'false' { return (& $result 1 "public: github.com/$path is public; make it private (gh repo edit $path --visibility private --accept-visibility-change-consequences) or point origin at a private copy") }
            default { $ghBlocked = $true; $unverified.Add("gh gave an unexpected answer for github.com/$path") }
        }
    }
    if ($unverified.Count) {
        if ($optIn) { return (& $result 0 ("private by opt-in (ops.pushVerified=true): " + ($unverified -join '; '))) }
        # Suggest gh only when gh was the blocker: it cannot vouch for another host.
        $fix = "confirm the repo is private, then run: git -C `"$Dir`" config ops.pushVerified true"
        if ($ghBlocked) { $fix = "sign gh in to an account that can read it (install gh, then gh auth login), or $fix" }
        return (& $result 2 ("unverified: " + ($unverified -join '; ') + "; $fix"))
    }
    return (& $result 0 ("private: " + ($oks -join '; ')))
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
            Write-Error "memory-init: .gitignore excludes $target (fatal for HOME path)"
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
                    $entries = @(Get-ChildItem -LiteralPath $existing -Force)
                    # Profiles can hold different notes under the same name.
                    # Preflight every entry before moving any of them, and keep
                    # the current link when a collision needs manual resolution.
                    foreach ($entry in $entries) {
                        $destPath = Join-Path $target $entry.Name
                        if ($null -ne (Get-Item -LiteralPath $destPath -Force -ErrorAction SilentlyContinue)) {
                            throw "[$Encoded] conflicting target entry: $($entry.Name); both pools and the current link are unchanged"
                        }
                    }
                    foreach ($entry in $entries) {
                        Move-Item -LiteralPath $entry.FullName -Destination $target -ErrorAction Stop
                    }
                    Remove-Item -LiteralPath $existing -Force -ErrorAction Stop
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
                # One gate answer per run: it may call the GitHub API.
                if ($null -eq $script:PushGate) { $script:PushGate = Test-OriginPrivate -Dir $Ops }
                if ($script:PushGate.Code -ne 0) {
                    Log "[$Encoded] auto-commit: push skipped, commit kept locally: $($script:PushGate.Reason)"
                    return
                }
                # Name origin, the remote the gate verified. git push reports on
                # stderr, which Windows PowerShell 5.1 under Stop would raise.
                $prevEap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { git push origin 2>$null | Out-Null; $pushRc = $LASTEXITCODE }
                finally { $ErrorActionPreference = $prevEap }
                if ($pushRc -eq 0) { Log "[$Encoded] auto-commit: pushed" }
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
$script:PushGate = $null

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
