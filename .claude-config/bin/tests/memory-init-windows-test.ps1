# Real memory-init in a child process, isolated from the user's profiles and git.
$ErrorActionPreference = 'Stop'
$init = Join-Path (Split-Path $PSScriptRoot -Parent) 'memory-init.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('memory-init-test-' + [guid]::NewGuid())
$previousProfile = $env:USERPROFILE
$previousOps = $env:OPS_DIR
$previousConfig = $env:CLAUDE_CONFIG_DIR
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
}
finally {
    $env:USERPROFILE = $previousProfile
    $env:OPS_DIR = $previousOps
    $env:CLAUDE_CONFIG_DIR = $previousConfig
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
