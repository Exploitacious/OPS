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

    $skillsBlock = Extract-Block '# --- Mount the shared skills ' '# --- Claude Code plugins:'
    $OpsRoot = Join-Path $fixture 'ops'
    New-Item -ItemType Directory -Path (Join-Path $OpsRoot 'SKILLS') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $OpsRoot 'SKILLS/VENDORED.tsv'), "alpha`tExploitacious/agent-skills/SKILLS/alpha`n")
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
    function git {
        param($Action, $Quiet, $Url, $Destination)
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Destination '.git') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $Destination 'interrupted'), 'partial clone')
        $global:LASTEXITCODE = 128
    }
    $DeployFailed = @(); $BashExe = $null
    Invoke-Expression $skillsBlock
    Assert ($DeployFailed -contains 'skills-mount') 'Clone failure was not recorded'
    Assert (-not (Test-Path -LiteralPath $SkillsSrcDir)) 'Failed clone occupied the canonical skill source'
    Assert (@(Get-ChildItem -LiteralPath (Split-Path $SkillsSrcDir -Parent) -Filter '.agent-skills.clone-*' -Force).Count -eq 0) 'Failed clone left a temporary directory'
    Write-Host 'PASS: failed skills clone marks failure and leaves its canonical path free'
    function git {
        param($Action, $Quiet, $Url, $Destination)
        New-Item -ItemType Directory -Path (Join-Path $Destination '.git') -Force | Out-Null
        $global:LASTEXITCODE = 0
    }
    $DeployFailed = @()
    Invoke-Expression $skillsBlock
    Assert (Test-Path -LiteralPath (Join-Path $SkillsSrcDir '.git')) 'Retry did not publish the complete clone'
    Write-Host 'PASS: deployment retries and publishes a complete clone'
    $SkillsSrcDir = Join-Path $OpsRoot 'PROJECTS/Exploitacious/agent-skills'
    New-Item -ItemType Directory -Path (Join-Path $SkillsSrcDir '.git') -Force | Out-Null
    $DeployFailed = @()
    Invoke-Expression $skillsBlock
    Assert ($DeployFailed -contains 'skills-mount') 'Missing Git Bash was not recorded'
    Write-Host 'PASS: missing Git Bash marks skills deployment failed'
    Remove-Item -LiteralPath $SkillsSrcDir -Recurse -Force
    function git {
        param($Action, $Quiet, $Url, $Destination)
        New-Item -ItemType Directory -Path (Join-Path $Destination '.git') -Force | Out-Null
        New-Item -ItemType Directory -Path $SkillsSrcDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $SkillsSrcDir 'operator-file'), 'preserve')
        $global:LASTEXITCODE = 0
    }
    $DeployFailed = @()
    Invoke-Expression $skillsBlock
    Assert ($DeployFailed -contains 'skills-mount') 'Concurrent clone destination was accepted'
    Assert ([IO.File]::ReadAllText((Join-Path $SkillsSrcDir 'operator-file')) -eq 'preserve') 'Concurrent destination was damaged'
    Assert (@(Get-ChildItem -LiteralPath $SkillsSrcDir -Force).Count -eq 1) 'Clone was nested into the concurrent destination'
    Write-Host 'PASS: clone publication preserves a destination created concurrently'
    Remove-Item Function:\git

    $nativeBash = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nativeBash -and $PSVersionTable.Platform -eq 'Unix') {
        $oldRoot = $OpsRoot
        $OpsRoot = Join-Path $fixture "OPS O'Neill"
        [IO.Directory]::Move($oldRoot, $OpsRoot)
        $SkillsSrcDir = Join-Path $OpsRoot 'PROJECTS/Exploitacious/agent-skills'
        New-Item -ItemType Directory -Path (Join-Path $SkillsSrcDir '.git') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $OpsRoot '.claude-config/bin') -Force | Out-Null
        $sourceSkill = Join-Path $SkillsSrcDir 'SKILLS/alpha/SKILL.md'
        New-Item -ItemType Directory -Path (Split-Path $sourceSkill -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($sourceSkill, 'skill source')
        [IO.File]::WriteAllText((Join-Path $OpsRoot '.claude-config/bin/skills-vendor.sh'), @'
[ "$OPS_DIR" = "$OPS_TEST_EXPECTED_ROOT" ] || exit 22
source="$OPS_DIR/PROJECTS/Exploitacious/agent-skills/SKILLS/alpha/SKILL.md"
case "$1" in
    sync)
        [ -f "$source" ] || exit 0
        mkdir -p "$OPS_DIR/SKILLS/alpha"
        cp "$source" "$OPS_DIR/SKILLS/alpha/SKILL.md"
        printf 'mounted' > "$OPS_DIR/SKILLS/mounted.txt"
        ;;
    --check)
        [ -f "$source" ] && [ -f "$OPS_DIR/SKILLS/alpha/SKILL.md" ] || exit 2
        cmp "$source" "$OPS_DIR/SKILLS/alpha/SKILL.md" || exit 1
        ;;
    *) exit 23 ;;
esac
'@)
        $env:OPS_TEST_EXPECTED_ROOT = $OpsRoot
        function Invoke-FixtureBash {
            param($Mode)
            # Git Bash's cygpath is unavailable on Linux; identity conversion
            # still exercises the real script's shell quoting and exit status.
            $body = 'cygpath() { printf "%s\n" "$2"; }' + "`n" + (@($input) -join "`n")
            ($body + "`r`n") | & $nativeBash.Source -s
            $global:LASTEXITCODE = $LASTEXITCODE
        }
        $BashExe = 'Invoke-FixtureBash'
        $DeployFailed = @()
        Invoke-Expression $skillsBlock
        Assert ($DeployFailed.Count -eq 0) 'Skill sync failed with a spaced or apostrophe path'
        Assert ([IO.File]::ReadAllText((Join-Path $OpsRoot 'SKILLS/mounted.txt')) -eq 'mounted') 'Skill sync did not reach the intended root'
        Assert ($null -eq $env:OPS_DEPLOY_ROOT) 'Skill sync leaked its temporary root environment'
        Write-Host 'PASS: skill sync handles spaces and apostrophes as literal path data'
        Remove-Item -LiteralPath $sourceSkill -Force
        $DeployFailed = @()
        Invoke-Expression $skillsBlock
        Assert ($DeployFailed -contains 'skills-mount') 'Successful sync with a missing source skill was treated as a complete mount'
        Write-Host 'PASS: successful sync followed by missing-mount check rc 2 fails deployment'
        Remove-Item Function:\Invoke-FixtureBash
        Remove-Item Env:\OPS_TEST_EXPECTED_ROOT
    }
    else { Write-Host 'SKIP: POSIX path quoting execution (requires Unix bash)' }

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

    # Execute only the actual summary in a child process so exit 1 is observable.
    $summaryStart = $script:deployText.IndexOf('# --- Summary ---')
    $summaryEnd = $script:deployText.IndexOf('if ($Host.Name', $summaryStart)
    $summary = $script:deployText.Substring($summaryStart, $summaryEnd - $summaryStart)
    $summaryProbe = Join-Path $fixture 'summary.ps1'
    [IO.File]::WriteAllText($summaryProbe, @'
function Write-Status { param($Msg, $Color) }
function Write-Bad { param($Msg) }
function Write-Good { param($Msg) }
$DeployFailed = @('skills-mount')
$ConfigDir = '.'
'@ + "`n" + $summary)
    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $summaryProbe *> $null
    Assert ($LASTEXITCODE -eq 1) 'Failed deployment summary returned success'
    $probeText = [IO.File]::ReadAllText($summaryProbe).Replace('$DeployFailed = @(''skills-mount'')', '$DeployFailed = @()')
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
