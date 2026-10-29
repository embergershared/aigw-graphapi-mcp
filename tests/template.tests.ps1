# Proofs for the one-time setup of a repository made from the template:
# scripts/Initialize-Repo.ps1 run with -SkipGitHub and -WhatIf against a copy of
# the tracked files, with a mocked gh. GitHub itself is never called.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'assert.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')

# A git repository on main holding this working tree's files, as git would commit them.
function New-TemplateCopy {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("template-copy-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $root | Out-Null
    foreach ($file in (git -C (Get-RepoRoot) ls-files --cached --others --exclude-standard)) {
        $source = Get-RepoPath $file
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        $target = Join-Path $root $file
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target
    }
    git -C $root init -q -b main
    git -C $root add -A
    git -C $root -c user.name=test -c user.email=test@contoso.com -c commit.gpgsign=false commit -q -m 'Template.'
    if ($LASTEXITCODE) { throw 'The template copy could not be committed.' }
    return $root
}

# gh as Initialize-Repo.ps1 sees it for a new repository; anything else is a call to GitHub.
function Set-GhMock {
    param([string] $Owner = 'contoso', [string] $Name = 'budget-tracker')

    $global:GhMockView = @{
        nameWithOwner    = "$Owner/$Name"
        name             = $Name
        description      = ''
        owner            = @{ login = $Owner }
        defaultBranchRef = @{ name = 'main' }
        visibility       = 'PUBLIC'
    } | ConvertTo-Json -Compress
    function global:gh {
        if ($args[0] -eq 'repo' -and $args[1] -eq 'view') { $global:LASTEXITCODE = 0; return $global:GhMockView }
        throw "Unexpected call to GitHub: gh $($args -join ' ')"
    }
}

function Get-Placeholders([string] $Root) {
    @(git -C $Root grep -l -e '__PROJECT_NAME__' -e '__REPO__' -e '__DESCRIPTION__' -e '__YEAR__' -- . ':!docs/template.md')
}

Test-Case 'Initialize-Repo names the project, removes the template-only parts and an unused stack, and creates the local files' {
    $root = New-TemplateCopy
    Set-GhMock
    try {
        $null = & (Join-Path $root 'scripts/Initialize-Repo.ps1') -Description 'Budget tracker on Azure.' -Stacks dotnet -SkipGitHub 6>$null

        Assert-Equal -Actual @(Get-Placeholders $root).Count -Expected 0 -Message 'No placeholder may be left outside docs/template.md.'
        $readme = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw
        Assert-Match -Actual $readme -Pattern '^# budget-tracker\r?\n\r?\nBudget tracker on Azure\.' -Message 'The README must open with the project name and description.'
        Assert-Match -Actual $readme -Pattern '(?s)\n## Overview\r?\n.*\n## Quick start\r?\n.*\n## Contents\r?\n' -Message 'The README must keep its Overview and Quick start sections before Contents.'
        $rules = Get-Content -LiteralPath (Join-Path $root '.github/copilot-instructions.md') -Raw
        Assert-Match -Actual $rules -Pattern 'gh issue create --repo contoso/budget-tracker' -Message 'The rules must name the new repository.'
        foreach ($file in 'README.md', 'docs/CHANGELOG.md') {
            Assert-NotMatch -Actual (Get-Content -LiteralPath (Join-Path $root $file) -Raw) -Pattern 'template:(start|end)' -Message "'$file' must lose its template-only block."
        }
        $changelog = Get-Content -LiteralPath (Join-Path $root 'docs/CHANGELOG.md') -Raw
        Assert-Match -Actual $changelog -Pattern 'Repository created from' -Message 'The changelog must start from its creation.'
        Assert-NotMatch -Actual $changelog -Pattern '\(#1[0-9]\)' -Message "The template's own entries must not reach the project's changelog."
        Assert-Match -Actual (Get-Content -LiteralPath (Join-Path $root 'docs/template.md') -Raw) -Pattern '__PROJECT_NAME__' -Message 'docs/template.md keeps the placeholders it describes.'

        foreach ($file in '.python-version', 'ruff.toml', 'scripts/lock_requirements.py', '.github/instructions/python.instructions.md', 'scripts/Initialize-Repo.ps1', 'tests/template.tests.ps1') {
            Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $root $file))) -Message "'$file' must be removed."
        }
        foreach ($file in 'global.json', 'nuget.config', 'scripts/init-local-files.ps1') {
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $root $file)) -Message "'$file' must stay."
        }
        foreach ($pair in @{ 'infra/core/tenant-codes.json' = 'infra/core/tenant-codes.example.json'; 'docs/targets.md' = 'docs/targets.example.md' }.GetEnumerator()) {
            Assert-Equal -Actual (Get-FileHash -LiteralPath (Join-Path $root $pair.Key)).Hash -Expected (Get-FileHash -LiteralPath (Join-Path $root $pair.Value)).Hash `
                -Message "'$($pair.Key)' must be created from its example."
        }
        Assert-Equal -Actual @(git -C $root status --porcelain --ignored -- infra/core/tenant-codes.json docs/targets.md | Where-Object { $_ -notmatch '^!! ' }).Count -Expected 0 `
            -Message 'The local tenant files must stay ignored, never staged.'
    }
    finally {
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'Initialize-Repo -WhatIf changes nothing, and it refuses the template itself and a dirty tree' {
    $root = New-TemplateCopy
    try {
        Set-GhMock
        $null = & (Join-Path $root 'scripts/Initialize-Repo.ps1') -Stacks python -WhatIf 6>$null *>$null
        Assert-Equal -Actual @(git -C $root status --porcelain --ignored).Count -Expected 0 -Message '-WhatIf must change no file and create no local file.'

        Set-GhMock -Owner 'embergershared' -Name 'azd-private-starter-template'
        Assert-Throws -Action { & (Join-Path $root 'scripts/Initialize-Repo.ps1') -SkipGitHub 6>$null } -Message 'The template itself must never be initialized.'

        Set-GhMock
        Set-Content -LiteralPath (Join-Path $root 'unrelated.txt') -Value 'work in progress'
        Assert-Throws -Action { & (Join-Path $root 'scripts/Initialize-Repo.ps1') -SkipGitHub 6>$null } -Message 'A tree with changes must be refused.'
    }
    finally {
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Only tests/ci.tests.ps1 reads the stack files, so it is the suite a one-stack project could break.
foreach ($stack in 'dotnet', 'python') {
    Test-Case "a project that keeps only $stack passes its own CI tests" {
        $root = New-TemplateCopy
        Set-GhMock
        try {
            $null = & (Join-Path $root 'scripts/Initialize-Repo.ps1') -Stacks $stack -SkipGitHub 6>$null
            # Its own process: the copy's runner must not reset this run's results.
            $output = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $root 'tests/run-tests.ps1') -Name ci 2>&1
            $exitCode = $LASTEXITCODE
            Assert-Equal -Actual $exitCode -Expected 0 `
                -Message "The CI tests of a $stack-only project must pass:`n$(@($output | Select-String -Pattern '[FAIL]' -SimpleMatch -CaseSensitive -Context 0, 1) -join "`n")"
        }
        finally {
            Remove-Item Function:\gh, Variable:\GhMockView -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Test-Case 'Initialize-Repo uses the owner prefix of the rules and the checks CI reports' {
    $script = Get-Content -LiteralPath (Get-RepoPath 'scripts/Initialize-Repo.ps1') -Raw
    Assert-Match -Actual $script -Pattern "'embergershared' \{ 'emberger/' \}" -Message 'embergershared branches take emberger/.'
    Assert-Match -Actual $script -Pattern "'g62priv' \{ 'emm/' \}" -Message 'g62priv branches take emm/.'
    $checks = if ($script -match '\$RequiredChecks = @\((?<c>[^)]*)\)') { @([regex]::Matches($Matches['c'], "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) } else { @() }
    $ci = Get-Content -LiteralPath (Get-RepoPath '.github/workflows/ci.yml') -Raw
    $rules = Get-Content -LiteralPath (Get-RepoPath '.github/workflows/pr-rules.yml') -Raw
    Assert-Equal -Actual ($checks -join ',') -Expected 'CI result,PR rules' -Message 'The ruleset requires CI result and PR rules.'
    Assert-Match -Actual $ci -Pattern '(?m)^    name: CI result\s*$' -Message 'ci.yml must report CI result.'
    Assert-Match -Actual $rules -Pattern '(?m)^    name: PR rules\s*$' -Message 'pr-rules.yml must report PR rules.'
}
