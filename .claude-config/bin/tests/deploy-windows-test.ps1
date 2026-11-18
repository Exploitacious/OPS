# Run with pwsh -NoProfile -File .claude-config/bin/tests/deploy-windows-test.ps1.
# Exercises extracted deploy code against temporary fixtures, never a live profile.
$ErrorActionPreference = 'Stop'
$deployPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'deploy.ps1'
$script:deployText = [IO.File]::ReadAllText($deployPath)
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($deployPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$coreFunction = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-CoreRule' }, $true)
if (-not $coreFunction) { throw 'Set-CoreRule was not found' }
Invoke-Expression $coreFunction.Extent.Text
function Write-Status { param($Msg, $Color) }
function Write-Good { param($Msg) }
function Write-Warn { param($Msg) }
function Write-Bad { param($Msg) }
function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Extract-Block { param($Start, $End)
    $begin = $script:deployText.IndexOf($Start)
    if ($begin -lt 0) { throw "Deploy block missing: $Start" }
    $finish = $script:deployText.IndexOf($End, $begin)
    if ($finish -lt 0) { throw "Deploy block missing: $Start" }
    return $script:deployText.Substring($begin, $finish - $begin)
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('deploy-windows-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $CoreSrc = Join-Path $fixture 'core content.md'
    $CoreRuleDir = Join-Path $fixture 'rules'
    $CoreRule = Join-Path $CoreRuleDir 'ops-core.md'
    $importAssignment = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$CoreImport' }, $true)
    Assert ($null -ne $importAssignment) 'Core import assignment was not found'
    Invoke-Expression $importAssignment.Extent.Text
    Assert ($CoreImport.Contains('core\ content.md')) 'Spaced core import was not escaped'
    [IO.File]::WriteAllText($CoreSrc, "# Core`n")
    Assert (Set-CoreRule) 'Fresh core rule failed'
    Assert ((Get-Item -LiteralPath $CoreRule -Force).LinkType -eq 'SymbolicLink') 'Core rule is not a link'
    Assert (Set-CoreRule) 'Core rule rerun failed'
    Remove-Item -LiteralPath $CoreRule -Force
    [IO.File]::WriteAllText($CoreRule, 'operator rule')
    Assert (Set-CoreRule) 'Regular core rule replacement failed'
    $backups = @(Get-ChildItem -LiteralPath $CoreRuleDir -Filter 'ops-core.md.backup_*')
    Assert ($backups.Count -eq 1 -and [IO.File]::ReadAllText($backups[0].FullName) -eq 'operator rule') 'Existing rule was not backed up intact'
    Write-Host 'PASS: core link, rerun, and operator rule backup'

    Remove-Item -LiteralPath $CoreRule -Force
    $outside = Join-Path $fixture 'outside.md'
    New-Item -ItemType SymbolicLink -Path $CoreRule -Target $outside | Out-Null
    # Simulate Windows without Developer Mode. Native creation must fail while
    # all ordinary directory setup uses the real cmdlet.
    function New-Item {
        param($ItemType, $Path, $Target, [switch]$Force, $ErrorAction)
        if ($ItemType -eq 'SymbolicLink') { throw 'Simulated symlink privilege failure' }
        Microsoft.PowerShell.Management\New-Item @PSBoundParameters
    }
    Assert (Set-CoreRule) 'Core fallback failed for a dangling prior link'
    Assert (-not (Test-Path -LiteralPath $outside)) 'Core fallback wrote through the dangling link'
    Assert (-not (Get-Item -LiteralPath $CoreRule -Force).LinkType) 'Fallback did not create a regular rule'
    Assert ([IO.File]::ReadAllText($CoreRule).Trim() -eq $CoreImport) 'Fallback rule content is wrong'
    Assert (Set-CoreRule) 'Fallback rerun failed'
    Remove-Item Function:\New-Item
    Write-Host 'PASS: dangling prior core link and spaced fallback import'

    Remove-Item -LiteralPath $CoreRule -Force
    [IO.File]::WriteAllText($outside, 'operator target')
    function New-Item {
        param($ItemType, $Path, $Target, [switch]$Force, $ErrorAction)
        if ($ItemType -eq 'SymbolicLink') {
            Microsoft.PowerShell.Management\New-Item -ItemType SymbolicLink -Path $Path -Target $outside | Out-Null
            throw 'Simulated path collision during symlink creation'
        }
        Microsoft.PowerShell.Management\New-Item @PSBoundParameters
    }
    Assert (-not (Set-CoreRule)) 'Fallback accepted a path collision'
    Assert ([IO.File]::ReadAllText($outside) -eq 'operator target') 'Fallback overwrote the target of a competing link'
    Remove-Item Function:\New-Item
    Write-Host 'PASS: fallback path collision preserves the competing link target'

    $OpsRoot = Join-Path $fixture 'ops'
    New-Item -ItemType Directory -Path (Join-Path $OpsRoot 'SKILLS') -Force | Out-Null
    $ConfigDir = Join-Path $OpsRoot '.claude-config'
    $ClaudeHome = Join-Path $fixture 'claude'
    New-Item -ItemType Directory -Path $ClaudeHome -Force | Out-Null
    $linkBlock = Extract-Block '# --- Symlink skills,' '# --- The always-loaded core:'
    function New-Item {
        param($ItemType, $Path, $Target, [switch]$Force, $ErrorAction)
        if ($ItemType -in @('SymbolicLink', 'Junction')) { throw 'Simulated directory link failure' }
        Microsoft.PowerShell.Management\New-Item @PSBoundParameters
    }
    $DeployFailed = @()
    Invoke-Expression $linkBlock
    Assert ($DeployFailed -contains 'link-skills') 'Failed skills directory link was not recorded'
    Assert ($DeployFailed -contains 'link-commands') 'Missing source directory was not recorded'
    Remove-Item Function:\New-Item
    Write-Host 'PASS: failed skill links and missing source directories mark deployment failed'

    $trustFunction = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-TrustAnchor' }, $true)
    Assert ($null -ne $trustFunction) 'Set-TrustAnchor was not found'
    Invoke-Expression $trustFunction.Extent.Text
    $trustCall = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-TrustAnchor' }, $true)
    Assert ($trustCall.Extent.Text.Contains('-ConfigDir $env:USERPROFILE')) 'Default trust state is not beside the default .claude directory'
    $trustDir = Join-Path $fixture 'trust'
    New-Item -ItemType Directory -Path $trustDir -Force | Out-Null
    $stateFile = Join-Path $trustDir '.claude.json'
    $previousProfile = $env:USERPROFILE
    $env:USERPROFILE = $trustDir
    try {
        $DeployFailed = @()
        [IO.File]::WriteAllText($stateFile, '{"other":{"preserve":17}}')
        Set-TrustAnchor -ConfigDir $trustDir -Label test
        $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
        Assert ($state.other.preserve -eq 17 -and $state.projects.$trustDir.hasTrustDialogAccepted -eq $true) 'Trust merge lost existing state or missed the anchor'
        foreach ($badJson in @('{corrupt', '[]', '[{"preserve":true}]', 'null', '{"projects":[]}')) {
            [IO.File]::WriteAllText($stateFile, $badJson)
            $DeployFailed = @()
            Set-TrustAnchor -ConfigDir $trustDir -Label test
            Assert ([IO.File]::ReadAllText($stateFile) -ceq $badJson) 'Trust merge overwrote invalid app state'
            Assert ($DeployFailed -contains 'trust-anchor') 'Invalid app state did not fail deployment'
        }
        Remove-Item -LiteralPath $stateFile -Force
        [IO.File]::WriteAllText($outside, '{"operator":"state"}')
        New-Item -ItemType SymbolicLink -Path $stateFile -Target $outside | Out-Null
        $DeployFailed = @()
        Set-TrustAnchor -ConfigDir $trustDir -Label test
        Assert ([IO.File]::ReadAllText($outside) -ceq '{"operator":"state"}') 'Trust merge wrote through a symlink'
        Assert ($DeployFailed -contains 'trust-anchor') 'Symlinked app state did not fail deployment'
        Assert (@(Get-ChildItem -LiteralPath $trustDir -Filter '.claude.json.tmp-*' -Force).Count -eq 0) 'Trust update left temporary state files'
        Write-Host 'PASS: default trust path, JSON merge, invalid state preservation, and symlink refusal'
    }
    finally { $env:USERPROFILE = $previousProfile }

    # The nightly task is registered on every copy, with or without an origin
    # remote (deploy.sh follows the same rule): daily-sync.sh decides what a
    # copy with no origin does, so the block never runs git. Run the real block
    # with the ScheduledTask cmdlets replaced by recorders; the repos are real,
    # made with the real git, and a git recorder is in scope only for the block.
    $taskBlock = Extract-Block '# --- Register daily backup scheduled task ---' '# --- Claude Code plugins:'
    $bashLine = '$BashExe = Resolve-BashExe'
    Assert ($taskBlock.Contains($bashLine)) 'The task block no longer resolves bash with Resolve-BashExe'
    $taskBlock = $taskBlock.Replace($bashLine, '$BashExe = $FixtureBash')
    $taskRoot = Join-Path $fixture 'task'
    Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path $taskRoot -Force | Out-Null
    $FixtureBash = Join-Path $taskRoot 'bash'
    [IO.File]::WriteAllText($FixtureBash, '')
    function New-TaskRepo {
        param([string]$Name, [string]$Remote, [switch]$NoGit)
        $dir = Join-Path $taskRoot $Name
        Microsoft.PowerShell.Management\New-Item -ItemType Directory -Path (Join-Path $dir '.claude-config/backup') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir '.claude-config/backup/daily-sync.sh'), '')
        if (-not $NoGit) { $null = @(& git init -q $dir 2>&1) }
        if ($Remote) { $null = @(& git -C $dir remote add $Remote 'git@example.invalid:acme/ops-copy.git' 2>&1) }
        return $dir
    }
    function New-ScheduledTaskAction { param($Execute, $Argument, $WorkingDirectory) [pscustomobject]@{ Execute = $Execute; Arguments = $Argument } }
    function New-ScheduledTaskTrigger { param([switch]$Daily, $At) 'trigger' }
    function New-ScheduledTaskSettingsSet {
        param([switch]$StartWhenAvailable, [switch]$RunOnlyIfNetworkAvailable, $MultipleInstances, $ExecutionTimeLimit, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries)
        'settings'
    }
    function Register-ScheduledTask {
        param($TaskName, $Action, $Trigger, $Settings, $Description, [switch]$Force)
        $script:registerCalls++; $script:registeredAction = $Action
    }
    function Get-ScheduledTask {
        param($TaskName, $ErrorAction)
        if ($script:registerCalls -gt 0) { [pscustomobject]@{ Actions = @($script:registeredAction) } }
        elseif ($script:taskExists) { [pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = 'old'; Arguments = 'old' }) } }
    }
    function Write-Warn { param($Msg) $script:taskWarns += @("$Msg") }
    function Write-Good { param($Msg) $script:taskGoods += @("$Msg") }
    function Invoke-TaskBlock {
        param([string]$Root, [bool]$System = $true, [bool]$Existing = $false)
        $script:registerCalls = 0; $script:registeredAction = $null; $script:taskExists = $Existing
        $script:taskWarns = @(); $script:taskGoods = @(); $script:gitCalls = @()
        $OpsRoot = $Root; $BackupDir = Join-Path $Root '.claude-config/backup'; $NoSystem = -not $System
        # Records the call, then runs the real git, so a remote check brought
        # back into the block fails both on the call and on what it decides.
        function git { $script:gitCalls += @("$args"); & (Get-Command git -CommandType Application | Select-Object -First 1) @args }
        Invoke-Expression $taskBlock
    }
    function Assert-Registered {
        param([string]$Label)
        Assert ($script:registerCalls -eq 1) "${Label}: the task was not registered once ($script:registerCalls)"
        Assert (@($script:taskGoods | Where-Object { $_ -like 'Daily backup task registered + verified*' }).Count -eq 1) "${Label}: no verified-registration line: $($script:taskGoods -join ' | ')"
        Assert ($script:taskWarns.Count -eq 0) "${Label}: a warning was printed: $($script:taskWarns -join ' | ')"
        Assert ($script:gitCalls.Count -eq 0) "${Label}: the task block ran git: $($script:gitCalls -join ' | ')"
    }

    Invoke-TaskBlock -Root (New-TaskRepo 'with-origin' 'origin')
    Assert-Registered 'origin present'
    Write-Host 'PASS: origin present: the daily backup task is registered and verified as before'

    Invoke-TaskBlock -Root (New-TaskRepo 'no-origin')
    Assert-Registered 'no origin'
    Write-Host 'PASS: no origin: the task is registered and verified the same way, with no warning'

    Invoke-TaskBlock -Root (New-TaskRepo 'other-remote' 'upstream')
    Assert-Registered 'remote named upstream'
    Invoke-TaskBlock -Root (New-TaskRepo 'not-a-repo' -NoGit)
    Assert-Registered 'not a repository'
    Write-Host 'PASS: no origin: a remote under another name, or no repository at all, is registered the same way'

    Invoke-TaskBlock -Root (Join-Path $taskRoot 'no-origin') -Existing $true
    Assert-Registered 'existing task, no origin'
    Write-Host 'PASS: an existing task on a copy with no origin is re-registered like any other, with no warning'

    Invoke-TaskBlock -Root (Join-Path $taskRoot 'with-origin') -System $false
    Invoke-TaskBlock -Root (Join-Path $taskRoot 'no-origin') -System $false
    Assert ($script:registerCalls -eq 0) '-NoSystem registered a task'
    Write-Host 'PASS: -NoSystem registers nothing'

    foreach ($fn in 'New-TaskRepo', 'New-ScheduledTaskAction', 'New-ScheduledTaskTrigger', 'New-ScheduledTaskSettingsSet', 'Register-ScheduledTask', 'Get-ScheduledTask', 'Write-Good', 'Invoke-TaskBlock', 'Assert-Registered') {
        Remove-Item "Function:\$fn" -ErrorAction SilentlyContinue
    }
    function Write-Warn { param($Msg) }

    # Execute only the actual summary in a child process so exit 1 is observable.
    $summaryStart = $script:deployText.IndexOf('# --- Summary ---')
    $summaryEnd = $script:deployText.IndexOf('if ($Host.Name', $summaryStart)
    $summary = $script:deployText.Substring($summaryStart, $summaryEnd - $summaryStart)
    $summaryProbe = Join-Path $fixture 'summary.ps1'
    [IO.File]::WriteAllText($summaryProbe, @'
function Write-Status { param($Msg, $Color) }
function Write-Bad { param($Msg) }
function Write-Good { param($Msg) }
$DeployFailed = @('trust-anchor')
$ConfigDir = '.'
'@ + "`n" + $summary)
    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $summaryProbe *> $null
    Assert ($LASTEXITCODE -eq 1) 'Failed deployment summary returned success'
    $probeText = [IO.File]::ReadAllText($summaryProbe).Replace('$DeployFailed = @(''trust-anchor'')', '$DeployFailed = @()')
    [IO.File]::WriteAllText($summaryProbe, $probeText)
    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $summaryProbe *> $null
    Assert ($LASTEXITCODE -eq 0) 'Successful deployment summary returned failure'
    Write-Host 'PASS: deployment summary returns failure or success accurately'
}
finally {
    Remove-Item Function:\New-Item -ErrorAction SilentlyContinue
    Remove-Item Function:\git -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
Write-Host 'ALL PASS'
