# Real memory-init in a child process, isolated from the user's profiles and git.
$ErrorActionPreference = 'Stop'
$init = Join-Path (Split-Path $PSScriptRoot -Parent) 'memory-init.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('memory-init-test-' + [guid]::NewGuid())
$previousProfile = $env:USERPROFILE
$previousOps = $env:OPS_DIR
$previousConfig = $env:CLAUDE_CONFIG_DIR
# The push-gate cases below change these; all are restored in finally.
$gateEnvNames = @('PATH', 'HOME', 'GH_STUB', 'GH_LOG', 'PUSH_LOG', 'FAKE_REMOTE', 'GIT_SSH_COMMAND', 'GIT_SSH_VARIANT',
    'GIT_CONFIG_NOSYSTEM', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL',
    'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0', 'EMAIL')
$previousGateEnv = @{}
foreach ($name in $gateEnvNames) { $previousGateEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $env:USERPROFILE = Join-Path $fixture 'home'
    $env:OPS_DIR = Join-Path $fixture 'OPS'
    $env:CLAUDE_CONFIG_DIR = Join-Path $fixture 'config'
    $encoded = $env:USERPROFILE -replace '[\\/]', '-' -replace ':', '-'
    $old = Join-Path $fixture 'old-pool'
    $target = Join-Path $env:OPS_DIR ".claude-memory/fixture-$encoded"
    $source = Join-Path $env:CLAUDE_CONFIG_DIR "projects/$encoded/memory"
    New-Item -ItemType Directory -Path $old, $target, (Split-Path $source -Parent) -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $old 'note.md'), 'old private note')
    [IO.File]::WriteAllText((Join-Path $target 'note.md'), 'existing destination note')
    New-Item -ItemType SymbolicLink -Path $source -Target $old | Out-Null
    $pwsh = (Get-Process -Id $PID).Path
    & $pwsh -NoProfile -File $init -HostnameOverride fixture -OnlyHome *> $null
    if ($LASTEXITCODE -ne 1) { throw 'Conflicting pools reported successful initialization' }
    if ((Get-Item -LiteralPath $source).Target -ne $old) { throw 'Repointed away from unresolved notes' }
    if ([IO.File]::ReadAllText((Join-Path $old 'note.md')) -ne 'old private note') { throw 'Old pool changed' }
    if ([IO.File]::ReadAllText((Join-Path $target 'note.md')) -ne 'existing destination note') { throw 'Destination note was overwritten' }
    Remove-Item -LiteralPath (Join-Path $target 'note.md')
    & $pwsh -NoProfile -File $init -HostnameOverride fixture -OnlyHome *> $null
    if ($LASTEXITCODE -ne 0 -or (Get-Item -LiteralPath $source).Target -ne $target) { throw 'Resolved migration failed' }
    if ([IO.File]::ReadAllText((Join-Path $target 'note.md')) -ne 'old private note') { throw 'Migration lost note' }
    & $pwsh -NoProfile -File $init -HostnameOverride fixture -OnlyHome *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Rerun failed' }
    Write-Host 'PASS: conflicting pools remain intact, resolved migration and rerun succeed'

    $deploy = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'deploy.ps1'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($deploy, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-MemoryInit' }, $true)
    Invoke-Expression $fn.Extent.Text
    function Write-Good { param($Msg) }
    function Write-Warn { param($Msg) }
    function Write-Bad { param($Msg) }
    $MemoryInit = Join-Path $fixture 'memory-stub.ps1'
    $proof = Join-Path $fixture 'selected-root.txt'
    [IO.File]::WriteAllText($MemoryInit, 'param([switch]$AutoCommit)' + "`n" + '[IO.File]::WriteAllText($env:OPS_TEST_PROOF, $env:OPS_DIR)' + "`nexit 1`n")
    $env:OPS_TEST_PROOF = $proof
    $OpsRoot = Join-Path $fixture 'deployed-checkout'
    $beforeOps = $env:OPS_DIR; $beforeConfig = $env:CLAUDE_CONFIG_DIR
    $script:DeployFailed = @()
    Invoke-MemoryInit -ConfigDir (Join-Path $fixture 'deployed-config') -Label test
    if ($script:DeployFailed -notcontains 'memory-init') { throw 'Deploy swallowed initialization failure' }
    if ([IO.File]::ReadAllText($proof) -ne $OpsRoot) { throw 'Deploy initialized a different checkout' }
    if ($env:OPS_DIR -ne $beforeOps -or $env:CLAUDE_CONFIG_DIR -ne $beforeConfig) { throw 'Deploy changed the caller environment' }
    Remove-Item Env:\OPS_TEST_PROOF
    Write-Host 'PASS: deploy selects its own checkout, restores environment and records failure'

    # --- Push gate: Test-OriginPrivate, the twin of bin/origin-private-check ---
    # gh is a stub on PATH that answers from GH_STUB and logs its arguments, so
    # no case touches the network. Git's global config is the fixture's own.
    $initAst = [Management.Automation.Language.Parser]::ParseFile($init, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $gateFn = $initAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-OriginPrivate' }, $true)
    if (-not $gateFn) { throw 'memory-init.ps1 has no Test-OriginPrivate' }
    Invoke-Expression $gateFn.Extent.Text
    $onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
    $sep = [IO.Path]::PathSeparator
    $gitExe = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $stubDir = Join-Path $fixture 'stub-bin'
    $noGhDir = Join-Path $fixture 'no-gh-bin'
    New-Item -ItemType Directory -Path $stubDir, $noGhDir, (Join-Path $fixture 'gate-home') -Force | Out-Null
    $env:HOME = Join-Path $fixture 'gate-home'
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GH_LOG = Join-Path $fixture 'gh.log'
    if ($onWindows) {
        [IO.File]::WriteAllText((Join-Path $stubDir 'gh.cmd'), "@echo off`r`necho %*>>`"%GH_LOG%`"`r`nif `"%GH_STUB%`"==`"error`" exit /b 1`r`necho %GH_STUB%`r`n")
        $noGhDir = Split-Path $gitExe -Parent
    }
    else {
        $ghStub = @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ "$GH_STUB" = error ] && exit 1
printf '%s\n' "$GH_STUB"
'@
        [IO.File]::WriteAllText((Join-Path $stubDir 'gh'), ($ghStub -replace "`r", ''))
        & chmod +x (Join-Path $stubDir 'gh')
        New-Item -ItemType SymbolicLink -Path (Join-Path $noGhDir 'git') -Target $gitExe | Out-Null
    }
    $withGh = $stubDir + $sep + $previousGateEnv['PATH']
    $env:PATH = $withGh
    $gateRepo = Join-Path $fixture 'gate-repo'
    & git init -q $gateRepo
    function Set-Origin {
        param([string]$Url, [string[]]$PushUrls = @())
        $ErrorActionPreference = 'Continue'
        & git -C $gateRepo remote remove origin 2>$null
        & git -C $gateRepo config remote.origin.url $Url
        foreach ($u in $PushUrls) { & git -C $gateRepo config --add remote.origin.pushurl $u }
    }
    function Assert-Gate {
        param($Result, [int]$Code, [string]$Label, [string]$Contains = '')
        if ($Result.Code -ne $Code) { throw "${Label}: code $($Result.Code), want $Code ($($Result.Reason))" }
        if ($Contains -and -not $Result.Reason.Contains($Contains)) { throw "${Label}: reason lacks '$Contains': $($Result.Reason)" }
    }
    function Get-GhCalls { if (Test-Path $env:GH_LOG) { @(Get-Content $env:GH_LOG) } else { @() } }

    $env:GH_STUB = 'true'
    Set-Origin 'https://github.com/acme/ops-copy.git'
    Remove-Item $env:GH_LOG -ErrorAction SilentlyContinue
    Assert-Gate (Test-OriginPrivate -Dir $gateRepo) 0 'private' 'github.com/acme/ops-copy is private'
    if ((Get-GhCalls) -notcontains 'api --hostname github.com repos/acme/ops-copy --jq .private') { throw "gh not asked for repos/acme/ops-copy: $(Get-GhCalls)" }
    $env:GH_STUB = 'false'
    Assert-Gate (Test-OriginPrivate -Dir $gateRepo) 1 'public' 'github.com/acme/ops-copy is public'
    $env:GH_STUB = 'true'
    foreach ($url in @('https://github.com/Exploitacious/OPS', 'https://github.com/Exploitacious/OPS.git',
            'https://github.com/exploitacious/ops.git/', 'HTTPS://GitHub.com/EXPLOITACIOUS/OPS.GIT',
            'git@github.com:Exploitacious/OPS.git', 'ssh://git@github.com:22/Exploitacious/OPS',
            'git://github.com/Exploitacious/OPS.git', 'https://user:tok@github.com/Exploitacious/OPS.git')) {
        Set-Origin $url
        Remove-Item $env:GH_LOG -ErrorAction SilentlyContinue
        Assert-Gate (Test-OriginPrivate -Dir $gateRepo) 1 "template $url" 'public OPS template'
        if (Get-GhCalls) { throw "template ${url}: gh was called" }
    }
    Set-Origin 'https://github.com/acme/ops-copy.git'
    $env:PATH = $noGhDir
    Assert-Gate (Test-OriginPrivate -Dir $gateRepo) 2 'gh missing' 'gh (GitHub CLI) is not installed'
    $env:PATH = $withGh
    $env:GH_STUB = 'error'
    Assert-Gate (Test-OriginPrivate -Dir $gateRepo) 2 'gh error' 'gh auth login'
    $env:GH_STUB = 'true'
    foreach ($url in @('https://git.example.com/acme/ops.git', 'git@git.example.com:acme/ops.git', (Join-Path $fixture 'bare.git'))) {
        Set-Origin $url
        & git -C $gateRepo config --unset ops.pushVerified
        $r = Test-OriginPrivate -Dir $gateRepo
        Assert-Gate $r 2 "unverifiable $url" 'ops.pushVerified'
        if ($r.Reason.Contains('gh auth login')) { throw "unverifiable ${url}: suggests gh for a host gh cannot vouch for: $($r.Reason)" }
        & git -C $gateRepo config ops.pushVerified true
        Assert-Gate (Test-OriginPrivate -Dir $gateRepo) 0 "opt-in $url" 'private by opt-in'
    }
    $env:GH_STUB = 'false'
    Set-Origin 'https://github.com/acme/ops-copy.git'
    Assert-Gate (Test-OriginPrivate -Dir $gateRepo) 1 'opt-in vs public' 'is public'
    Set-Origin 'git@github.com:Exploitacious/OPS.git'
    Assert-Gate (Test-OriginPrivate -Dir $gateRepo) 1 'opt-in vs template' 'public OPS template'
    & git -C $gateRepo config --unset ops.pushVerified
    & git config --global ops.pushVerified true
    Set-Origin 'https://git.example.com/acme/ops.git'
    Assert-Gate (Test-OriginPrivate -Dir $gateRepo) 2 'global opt-in is ignored' 'unverified'
    & git config --global --unset ops.pushVerified
    $env:GH_STUB = 'true'
    Set-Origin 'https://github.com/acme/ops-copy.git' -PushUrls @('https://github.com/Exploitacious/OPS.git')
    Assert-Gate (Test-OriginPrivate -Dir $gateRepo) 1 'push URL decides' 'public OPS template'
    foreach ($stub in @('true', 'false', 'error')) {
        $env:GH_STUB = $stub
        Set-Origin 'https://x-access-token:ghp_SECRETVALUE1234@github.com/acme/ops-copy.git'
        $r = Test-OriginPrivate -Dir $gateRepo
        if ($r.Reason -match 'SECRETVALUE|x-access-token') { throw "credentials in reason ($stub): $($r.Reason)" }
    }
    Write-Host 'PASS: Test-OriginPrivate matches the bash gate: private 0, public and template 1, unverifiable 2, repo-local opt-in'

    # Normalized forms reach the template verdict even with the opt-in set, and
    # a push URL list with no usable entry is 2 either way (the bash gate's
    # cases). An ssh stub resolves the alias dot-gh to a trailing-dot HostName.
    if ($onWindows) {
        [IO.File]::WriteAllText((Join-Path $stubDir 'ssh.cmd'), "@echo off`r`nif `"%3`"==`"dot-gh`" (echo hostname github.com.) else (echo hostname %3)`r`n")
    }
    else {
        $sshStub = @'
#!/usr/bin/env bash
[ "$1" = -G ] || exit 255
host="${*: -1}"
case "$host" in dot-gh) echo 'hostname github.com.' ;; *) echo "hostname $host" ;; esac
'@
        [IO.File]::WriteAllText((Join-Path $stubDir 'ssh'), ($sshStub -replace "`r", ''))
        & chmod +x (Join-Path $stubDir 'ssh')
    }
    & git -C $gateRepo config ops.pushVerified true
    $env:GH_STUB = 'true'
    $normalized = @('https://github.com/Exploitacious/%4FPS', 'https://github.com/%45xploitacious/OPS%2Egit',
        'https://github%2Ecom/Exploitacious/OPS', 'git@github.com:Exploitacious/OPS.git ', "git@github.com:Exploitacious/OPS.git`t",
        ' https://github.com/Exploitacious/OPS', 'https://github.com///Exploitacious//OPS//',
        'https://github.com/acme/../Exploitacious/./OPS', 'https://github.com./Exploitacious/OPS', 'git@dot-gh:Exploitacious/OPS.git')
    # Embedded quotes survive native argument passing only off Windows (5.1 and
    # early 7.x on Windows re-quote them), so the quoted forms run there.
    if (-not $onWindows) { $normalized += @("'https://github.com/Exploitacious/OPS.git'", '"git@github.com:Exploitacious/OPS"') }
    foreach ($url in $normalized) {
        Set-Origin $url
        Remove-Item $env:GH_LOG -ErrorAction SilentlyContinue
        Assert-Gate (Test-OriginPrivate -Dir $gateRepo) 1 "normalized template [$url]" 'public OPS template'
        if (Get-GhCalls) { throw "normalized template [$url]: gh was called" }
    }
    Set-Origin "`r"
    Assert-Gate (Test-OriginPrivate -Dir $gateRepo) 2 'lone CR push URL with the opt-in' 'no usable push URL'
    & git -C $gateRepo config --unset ops.pushVerified
    Assert-Gate (Test-OriginPrivate -Dir $gateRepo) 2 'lone CR push URL' 'no usable push URL'
    Write-Host 'PASS: Test-OriginPrivate normalizes template forms like the bash gate and refuses a blank push URL list'

    # --- Push gate in -AutoCommit: commit always, push only when private -----
    # origin is a GitHub URL; a fake ssh serves it from a local bare repo, so
    # pulls work offline and a push that does happen lands there.
    $fakeSsh = Join-Path $fixture 'fake-ssh'
    $fakeSshBody = @'
#!/usr/bin/env bash
case "${*: -1}" in
  git-upload-pack*) exec git upload-pack "$FAKE_REMOTE" ;;
  git-receive-pack*) echo receive-pack >> "$PUSH_LOG"; exec git receive-pack "$FAKE_REMOTE" ;;
esac
exit 1
'@
    [IO.File]::WriteAllText($fakeSsh, ($fakeSshBody -replace "`r", ''))
    if (-not $onWindows) { & chmod +x $fakeSsh }
    $env:GIT_SSH_COMMAND = ($fakeSsh -replace '\\', '/')
    $env:GIT_SSH_VARIANT = 'ssh'
    $env:FAKE_REMOTE = ((Join-Path $fixture 'remote.git') -replace '\\', '/')
    $env:PUSH_LOG = ((Join-Path $fixture 'push.log') -replace '\\', '/')
    $env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@example.invalid'
    $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@example.invalid'
    $seed = Join-Path $fixture 'seed'
    & git init -q -b main $seed
    & git -C $seed commit -q --allow-empty -m seed
    & git clone -q --bare $seed $env:FAKE_REMOTE
    $env:OPS_DIR = Join-Path $fixture 'gate-ops'
    $env:CLAUDE_CONFIG_DIR = Join-Path $fixture 'gate-config'
    & git clone -q git@github.com:acme/ops-copy.git $env:OPS_DIR
    if ($LASTEXITCODE -ne 0) { throw 'Clone through the fake ssh failed' }
    $seedHead = & git -C $env:FAKE_REMOTE rev-parse main
    $memSource = Join-Path $env:CLAUDE_CONFIG_DIR "projects/$encoded/memory"
    New-Item -ItemType Directory -Path $memSource -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $memSource 'note.md'), 'first note')
    $env:GH_STUB = 'false'
    $out = & $pwsh -NoProfile -File $init -HostnameOverride fixture -OnlyHome -AutoCommit *>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "memory-init failed with a public origin: $out" }
    if (-not $out.Contains('push skipped, commit kept locally: public: github.com/acme/ops-copy is public')) { throw "Public origin skip not logged: $out" }
    if ((& git -C $env:OPS_DIR log -1 --format=%s) -ne "feat(memory): seed .claude-memory/fixture-$encoded") { throw 'Memory commit not kept locally' }
    if ((& git -C $env:FAKE_REMOTE rev-parse main) -ne $seedHead -or (Test-Path $env:PUSH_LOG)) { throw 'Memory pushed to a public origin' }
    $env:GH_STUB = 'true'
    [IO.File]::WriteAllText((Join-Path $env:OPS_DIR ".claude-memory/fixture-$encoded/two.md"), 'second note')
    $out = & $pwsh -NoProfile -File $init -HostnameOverride fixture -OnlyHome -AutoCommit *>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "memory-init failed with a private origin: $out" }
    if (-not $out.Contains('auto-commit: pushed')) { throw "Private origin push not logged: $out" }
    if ((& git -C $env:FAKE_REMOTE rev-parse main) -ne (& git -C $env:OPS_DIR rev-parse HEAD)) { throw 'Memory not pushed to a private origin' }
    Write-Host 'PASS: -AutoCommit keeps the commit for a public origin and pushes to a private one'

    # --- No git identity: memory-init shows git's stderr; deploy fails ------
    # (2026-10-19: "commit failed (hook/signing?)" hid the real cause, and the
    # deploy reported success.) user.useConfigOnly with no configured identity
    # makes git refuse to guess, on any host.
    $identityEnv = @{ GIT_AUTHOR_NAME = 't'; GIT_AUTHOR_EMAIL = 't@example.invalid'; GIT_COMMITTER_NAME = 't'; GIT_COMMITTER_EMAIL = 't@example.invalid' }
    $emptyGitConfig = Join-Path $fixture 'empty.gitconfig'
    [IO.File]::WriteAllText($emptyGitConfig, '')
    function Remove-GitIdentity {
        foreach ($n in @($identityEnv.Keys) + 'EMAIL') { Remove-Item "Env:\$n" -ErrorAction SilentlyContinue }
        $env:GIT_CONFIG_GLOBAL = $emptyGitConfig
        $env:GIT_CONFIG_COUNT = '1'; $env:GIT_CONFIG_KEY_0 = 'user.useConfigOnly'; $env:GIT_CONFIG_VALUE_0 = 'true'
    }
    function Restore-GitIdentity {
        foreach ($n in $identityEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $identityEnv[$n]) }
        foreach ($n in 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0') { Remove-Item "Env:\$n" -ErrorAction SilentlyContinue }
    }
    Remove-GitIdentity
    [IO.File]::WriteAllText((Join-Path $env:OPS_DIR ".claude-memory/fixture-$encoded/no-ident.md"), 'note without an identity')
    $out = & $pwsh -NoProfile -File $init -HostnameOverride fixture -OnlyHome -AutoCommit *>&1 | Out-String
    Restore-GitIdentity
    if ($LASTEXITCODE -ne 0) { throw "memory-init failed outright without an identity: $out" }
    if (-not $out.Contains('auto-commit: commit failed, staged but uncommitted. git said:')) { throw "Failed commit not reported: $out" }
    if (-not ($out -match 'Author identity unknown') -or -not ($out -match 'fatal: no email was given')) { throw "git's own stderr is not in the output: $out" }
    if ($out.Contains('hook/signing')) { throw "The old guess is still printed: $out" }
    Write-Host "PASS: -AutoCommit shows git's own stderr for a failed commit, not a guess"

    $script:deployText = [IO.File]::ReadAllText($deploy)
    $begin = $script:deployText.IndexOf('# --- Git identity ---')
    $finish = $script:deployText.IndexOf('# --- Claude Code auto-memory git-sync ---', [Math]::Max($begin, 0))
    if ($begin -lt 0 -or $finish -lt 0) { throw 'deploy.ps1 has no git identity block' }
    $identBlock = $script:deployText.Substring($begin, $finish - $begin)
    $script:deployMsgs = New-Object System.Collections.Generic.List[string]
    function Write-Status { param($Msg, $Color) }
    function Write-Good { param($Msg) $script:deployMsgs.Add("OK $Msg") }
    function Write-Bad { param($Msg) $script:deployMsgs.Add("BAD $Msg") }
    function Write-Action { param($Msg) $script:deployMsgs.Add("ACTION $Msg") }
    $OpsRoot = $env:OPS_DIR
    Remove-GitIdentity
    $DeployFailed = @()
    try { Invoke-Expression $identBlock } finally { Restore-GitIdentity }
    if ($DeployFailed -notcontains 'git-identity') { throw "Deploy did not fail without a git identity: $($script:deployMsgs -join ' | ')" }
    if (-not ($script:deployMsgs | Where-Object { $_ -like 'BAD git has no usable identity*' }) -or
        -not ($script:deployMsgs | Where-Object { $_ -match '^ACTION .*git config --global user\.name .*git config --global user\.email' })) {
        throw "The identity failure does not name the fix: $($script:deployMsgs -join ' | ')"
    }
    $script:deployMsgs.Clear()
    $DeployFailed = @()
    Invoke-Expression $identBlock
    if ($DeployFailed.Count -or -not ($script:deployMsgs | Where-Object { $_ -like 'OK git identity is set*' })) { throw "Deploy failed with a git identity set: $($script:deployMsgs -join ' | ')" }
    Write-Host 'PASS: deploy.ps1 fails without a git identity and names the fix, and passes with one'
}
finally {
    $env:USERPROFILE = $previousProfile
    $env:OPS_DIR = $previousOps
    $env:CLAUDE_CONFIG_DIR = $previousConfig
    foreach ($name in $gateEnvNames) { [Environment]::SetEnvironmentVariable($name, $previousGateEnv[$name]) }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
