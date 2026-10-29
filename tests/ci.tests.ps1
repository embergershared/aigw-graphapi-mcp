# Proofs for the pull request deployment workflows: throwaway environment
# naming, profile selection, the what-if comment, the teardown's safety rules,
# the post-deployment checks and the shape of the workflow files themselves.
# Everything runs offline against mocked az, azd and gh commands.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'assert.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')
. (Get-RepoPath 'scripts/ci-environments.ps1')

$workflowRoot = Get-RepoPath '.github/workflows'

Test-Case 'throwaway environment names fit AZURE_ENV_NAME and are recognized again' {
    Assert-Equal -Actual (Get-CiEnvironmentName -DeploymentProfile private -PullRequest 12 -RunNumber 40 -RunAttempt 1) `
        -Expected 'pr12-private-40-1' -Message 'A pull request run is named after the pull request.'
    Assert-Equal -Actual (Get-CiEnvironmentName -DeploymentProfile full -RunNumber 40 -RunAttempt 2) `
        -Expected 'ci-full-40-2' -Message 'A manual run is named ci-.'
    $longest = Get-CiEnvironmentName -DeploymentProfile private -PullRequest 999999 -RunNumber 9999999 -RunAttempt 99
    Assert-True -Condition ($longest.Length -le 32) -Message "The longest name '$longest' must fit the 32-character limit."
    Assert-Match -Actual $longest -Pattern '^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])$' -Message 'Names must satisfy the AZURE_ENV_NAME rule preflight enforces.'
    foreach ($name in @('pr12-private-40-1', 'ci-core-1-1', $longest)) {
        Assert-True -Condition (Test-CiEnvironmentName $name) -Message "'$name' must be recognized as throwaway."
    }
    foreach ($name in @('sandbox', 'dev', 'pr12-private-40', 'PR12-core-1-1', 'pr12-core-1-1-extra', 'prod-core-1-1', '', $null)) {
        Assert-True -Condition (-not (Test-CiEnvironmentName $name)) -Message "'$name' must never be treated as throwaway."
    }
    Assert-Throws -Action { Get-CiEnvironmentName -DeploymentProfile minimal -RunNumber 1 } -Message 'Only the three profiles are allowed.'
}

Test-Case 'the runner gets a one-tenant catalog that naming accepts, and bad variables fail' {
    . (Get-RepoPath 'scripts/naming.ps1')
    $tenantId = '11111111-2222-3333-4444-555555555555'
    $path = Join-Path ([IO.Path]::GetTempPath()) ("tenant-codes-$([guid]::NewGuid().ToString('N')).json")
    try {
        New-CiTenantCatalog -TenantId $tenantId.ToUpperInvariant() -TenantCode 'cal01' -Path $path
        Assert-Equal -Actual (Get-TenantCode -TenantId $tenantId -CatalogPath $path) -Expected 'cal01' -Message 'Naming must read the code the job wrote.'
        Assert-Throws -Action { New-CiTenantCatalog -TenantId $tenantId -TenantCode 'cal01' -Path $path } -Message 'An existing catalog must never be overwritten.'
    }
    finally {
        Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    }
    $unused = Join-Path ([IO.Path]::GetTempPath()) ("tenant-codes-$([guid]::NewGuid().ToString('N')).json")
    foreach ($case in @(@('', 'cal01'), @('not-a-guid', 'cal01'), @($tenantId, ''), @($tenantId, 'Cal01'), @($tenantId, 'c'))) {
        Assert-Throws -Action { New-CiTenantCatalog -TenantId $case[0] -TenantCode $case[1] -Path $unused } `
            -Message "Tenant '$($case[0])' with code '$($case[1])' must fail with setup guidance."
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath $unused)) -Message 'A failed call must write nothing.'
    $deploy = Get-Content -LiteralPath (Join-Path $workflowRoot 'deploy-environment.yml') -Raw
    Assert-Match -Actual $deploy -Pattern '(?s)actions/checkout@\S+\s+.*?- name: Write the tenant catalog.*?- name: Sign the Azure CLI in' `
        -Message 'The job must write the catalog before anything compiles Bicep.'
}

Test-Case 'only infrastructure changes deploy, and a manual run deploys its one profile' {
    foreach ($path in @('infra/main.bicep', 'infra/modules/network/main.bicep', 'scripts/preflight.ps1', 'azure.yaml', '.github/workflows/deploy-environment.yml', 'infra\core\naming.bicep')) {
        Assert-True -Condition (Test-InfrastructureChange -Path @('README.md', $path)) -Message "'$path' must count as an infrastructure change."
    }
    foreach ($path in @('README.md', 'docs/deployment.md', 'tests/ci.tests.ps1', 'azure.yaml.bak', 'infrastructure.md', '.github/workflows/ci.yml')) {
        Assert-True -Condition (-not (Test-InfrastructureChange -Path @($path))) -Message "'$path' must not deploy anything."
    }
    Assert-True -Condition (-not (Test-InfrastructureChange -Path @())) -Message 'An empty change deploys nothing.'

    Assert-Equal -Actual ((Get-CiDeploymentProfiles -EventName pull_request -InfrastructureChanged $true) -join ',') -Expected 'core,private' `
        -Message 'An infrastructure pull request deploys core and private, never full.'
    Assert-Equal -Actual @(Get-CiDeploymentProfiles -EventName pull_request -InfrastructureChanged $false).Count -Expected 0 `
        -Message 'Any other pull request deploys nothing.'
    Assert-Equal -Actual ((Get-CiDeploymentProfiles -EventName workflow_dispatch -DispatchProfile full) -join ',') -Expected 'full' `
        -Message 'A manual run deploys the profile it was given.'
    Assert-Throws -Action { Get-CiDeploymentProfiles -EventName workflow_dispatch -DispatchProfile '' } -Message 'A manual run must name a profile.'
    Assert-Equal -Actual (ConvertTo-Json -InputObject @(Get-CiDeploymentProfiles -EventName pull_request) -Compress) -Expected '[]' `
        -Message 'No profiles must serialize to the [] the deploy job checks for.'
    Assert-Equal -Actual (ConvertTo-Json -InputObject @(Get-CiDeploymentProfiles -EventName workflow_dispatch -DispatchProfile core) -Compress) -Expected '["core"]' `
        -Message 'One profile must still serialize as an array for the matrix.'
}

Test-Case 'the what-if comment carries the counts only, never a resource name or ID' {
    # azd's layout (pkg/output/ux/preview_provision.go): padded operation, type and
    # name, colored, with property changes indented below. Fictitious values.
    $preview = @(
        'Previewing Azure resource changes'
        ''
        '  Resources:'
        ''
        "  `e[32mCreate :`e[0m Resource group  : rg-cal01-pr1-core-2-1"
        "  `e[32mCreate :`e[0m Key Vault       : kv-cal01-secretname"
        '      + properties.tenantId: "00000000-1111-2222-3333-444444444444"'
        "  `e[33mModify :`e[0m Log Analytics   : log-cal01-pr1"
        '      ~ properties.retentionInDays: 30 => 60'
        "  `e[90mSkip   :`e[0m Managed Identity : id-cal01-pr1"
        "  `e[31mDelete :`e[0m Private endpoint : pe-cal01-old"
    ) -join "`r`n"
    $counts = Get-PreviewCounts -Preview $preview
    Assert-Equal -Actual (($counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',') `
        -Expected 'Create=2,Modify=1,Delete=1,Deploy=0,Skip=1,Unsupported=0' -Message 'Each resource line counts once, by its operation; property lines do not count.'

    $comment = ConvertTo-PreviewComment -DeploymentProfile core -EnvironmentName pr1-core-2-1 -Preview $preview `
        -Outcome success -RunUrl 'https://example.test/run'
    $lines = $comment -split "`n"
    Assert-Equal -Actual $lines[0] -Expected '<!-- pr-deployment:core -->' -Message 'The marker must be the first line so later runs edit the same comment.'
    Assert-Match -Actual $comment -Pattern 'Resources: 2 to create, 1 to modify, 1 to delete, 1 unchanged\.' -Message 'The comment must give the counts.'
    foreach ($leak in @('cal01', 'secretname', '00000000-1111', 'retentionInDays', "`e")) {
        Assert-NotMatch -Actual $comment -Pattern ([regex]::Escape($leak)) -Message "The comment is public: '$leak' from the preview must not reach it."
    }
    Assert-Match -Actual $comment -Pattern '\[Run log\]\(https://example\.test/run\)' -Message 'The comment must link the run.'

    $failed = ConvertTo-PreviewComment -DeploymentProfile full -EnvironmentName pr1-full-2-1 -Preview 'ERROR: deployment failed' -Outcome failure
    Assert-Match -Actual $failed -Pattern 'pr1-full-2-1` failed' -Message 'A failed preview must say so.'
    Assert-Match -Actual $failed -Pattern 'none counted' -Message 'A failed preview has no counts.'
    Assert-NotMatch -Actual $failed -Pattern 'ERROR' -Message 'Not even an error message from the preview reaches the comment.'
    $empty = ConvertTo-PreviewComment -DeploymentProfile core -EnvironmentName pr1-core-2-1 -Preview '' -Outcome success
    Assert-Match -Actual $empty -Pattern 'listed no resources' -Message 'An empty successful preview must say so.'
}

function Invoke-RemoveFixture {
    param([hashtable] $Arguments, [switch] $WhatIf)

    $calls = [System.Collections.Generic.List[string]]::new()
    $old = [DateTimeOffset]::UtcNow.AddDays(-2).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $young = [DateTimeOffset]::UtcNow.AddMinutes(-30).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $repo = 'owner/repo'
    $groups = @(
        @{ name = 'rg-old-pr'; tags = @{ repository = $repo; 'azd-env-name' = 'pr3-core-10-1'; 'created-on' = $old } }
        @{ name = 'rg-young-pr'; tags = @{ repository = $repo; 'azd-env-name' = 'pr4-private-11-1'; 'created-on' = $young } }
        @{ name = 'rg-sandbox'; tags = @{ repository = $repo; 'azd-env-name' = 'sandbox'; 'created-on' = $old } }
        @{ name = 'rg-other-repo'; tags = @{ repository = 'someone/else'; 'azd-env-name' = 'pr3-core-10-1'; 'created-on' = $old } }
        @{ name = 'rg-untagged'; tags = $null }
        @{ name = 'rg-no-date'; tags = @{ repository = $repo; 'azd-env-name' = 'pr5-core-12-1' } }
    )
    $vaults = @(
        @{ name = 'kv-old'; properties = @{ location = 'eastus2'; purgeProtectionEnabled = $false; tags = @{ repository = $repo; 'azd-env-name' = 'pr3-core-10-1' } } }
        @{ name = 'kv-protected'; properties = @{ location = 'eastus2'; purgeProtectionEnabled = $true; scheduledPurgeDate = 'later'; tags = @{ repository = $repo; 'azd-env-name' = 'pr6-core-13-1' } } }
        @{ name = 'kv-sandbox'; properties = @{ location = 'eastus2'; purgeProtectionEnabled = $false; tags = @{ repository = $repo; 'azd-env-name' = 'sandbox' } } }
        @{ name = 'kv-untagged'; properties = @{ location = 'eastus2'; purgeProtectionEnabled = $false } }
    )
    function az {
        $global:LASTEXITCODE = 0
        switch ("$($args[0]) $($args[1])") {
            'group list' { return ($groups | ConvertTo-Json -Depth 5) }
            'keyvault list-deleted' { return ($vaults | ConvertTo-Json -Depth 5) }
            'group delete' { $calls.Add("delete $($args[3])"); return }
            'keyvault purge' { $calls.Add("purge $($args[3])"); return }
            default { throw "Unexpected Azure call: $args" }
        }
    }
    $output = (& (Get-RepoPath 'scripts/remove-ci-environments.ps1') -SubscriptionId 'sub' -Repository $repo @Arguments -WhatIf:$WhatIf 3>&1) -join "`n"
    return [pscustomobject] @{ Calls = @($calls); Output = $output }
}

Test-Case 'the nightly cleanup removes only old throwaway environments of this repository' {
    $result = Invoke-RemoveFixture -Arguments @{ OlderThanHours = 6 }
    Assert-Equal -Actual ($result.Calls -join ';') -Expected 'delete rg-old-pr;purge kv-old' `
        -Message 'Only the old throwaway group of this repository and its own vault may go.'
    Assert-Match -Actual $result.Output -Pattern "kv-protected.*purge protection" -Message 'A purge-protected vault must be reported, not purged.'
    Assert-Match -Actual $result.Output -Pattern "Skipping 'pr5-core-12-1'" -Message 'A group without a readable creation time must be skipped with a warning.'
}

Test-Case 'the teardown removes exactly its own environment and refuses any other name' {
    $result = Invoke-RemoveFixture -Arguments @{ EnvironmentName = 'pr4-private-11-1' }
    Assert-Equal -Actual ($result.Calls -join ';') -Expected 'delete rg-young-pr' -Message 'A teardown must not wait for the age cutoff, nor touch other environments.'
    $preview = Invoke-RemoveFixture -Arguments @{ OlderThanHours = 0 } -WhatIf
    Assert-Equal -Actual $preview.Calls.Count -Expected 0 -Message '-WhatIf must delete and purge nothing.'
    Assert-Throws -Action { Invoke-RemoveFixture -Arguments @{ EnvironmentName = 'sandbox' } } -Message 'A non-throwaway name must be refused before any call.'
}

function Invoke-DeploymentCheck {
    param(
        [string] $DeploymentProfile = 'private',
        [string] $Overrides = '{}',
        [object[]] $Resources,
        [hashtable] $Outputs = @{},
        [string] $PowerState = 'PowerState/running'
    )

    $values = [ordered] @{
        AZURE_ENV_NAME = 'pr1-private-2-1'; AZURE_SUBSCRIPTION_ID = 'sub'; AZURE_RESOURCE_GROUP = 'rg-fixture'
        AZURE_DEPLOYMENT_PROFILE = $DeploymentProfile; AZURE_FEATURE_OVERRIDES_JSON = $Overrides
        AZURE_LOG_ANALYTICS_WORKSPACE_ID = '/subscriptions/sub/resourceGroups/rg-fixture/providers/Microsoft.OperationalInsights/workspaces/law-fixture'
        AZURE_APPLICATION_INSIGHTS_NAME = 'appi-fixture'
    }
    foreach ($key in $Outputs.Keys) { $values[$key] = $Outputs[$key] }
    function azd {
        $global:LASTEXITCODE = 0
        if ("$($args[0]) $($args[1])" -ne 'env get-values') { throw "Unexpected azd call: $args" }
        return @($values.GetEnumerator() | ForEach-Object { "$($_.Key)=`"$($_.Value)`"" })
    }
    function az {
        $global:LASTEXITCODE = 0
        switch ("$($args[0]) $($args[1])") {
            'group show' { return (@{ name = 'rg-fixture'; tags = @{ 'azd-env-name' = 'pr1-private-2-1'; profile = $DeploymentProfile } } | ConvertTo-Json) }
            'resource list' { return (ConvertTo-Json -InputObject @($Resources) -Depth 4) }
            'vm get-instance-view' { return $PowerState }
            default { throw "Unexpected Azure call: $args" }
        }
    }
    return ((& (Get-RepoPath 'scripts/test-deployment.ps1') -Environment 'pr1-private-2-1') -join "`n")
}

$baseResources = @(
    @{ name = 'law-fixture'; type = 'Microsoft.OperationalInsights/workspaces'; provisioningState = 'Succeeded' }
    @{ name = 'appi-fixture'; type = 'microsoft.insights/components'; provisioningState = 'Succeeded' }
)

Test-Case 'the deployment check passes a healthy deployment and fails a broken one' {
    $private = $baseResources + @(@{ name = 'vnet-fixture'; type = 'Microsoft.Network/virtualNetworks'; provisioningState = 'Succeeded' })
    $output = Invoke-DeploymentCheck -Resources $private -Outputs @{ AZURE_VIRTUAL_NETWORK_NAME = 'vnet-fixture' }
    Assert-Match -Actual $output -Pattern 'All deployment checks passed' -Message 'A healthy private deployment must pass.'

    $failedState = $baseResources + @(@{ name = 'vnet-fixture'; type = 'Microsoft.Network/virtualNetworks'; provisioningState = 'Failed' })
    Assert-Throws -Action { Invoke-DeploymentCheck -Resources $failedState -Outputs @{ AZURE_VIRTUAL_NETWORK_NAME = 'vnet-fixture' } } `
        -Message 'A resource that did not finish provisioning must fail the check.'
    Assert-Throws -Action { Invoke-DeploymentCheck -Resources $baseResources -Outputs @{ AZURE_KEY_VAULT_NAME = 'kv-missing' } } `
        -Message 'An output that names a missing resource must fail the check.'

    $full = $baseResources + @(@{ name = 'vm-win-fixture'; type = 'Microsoft.Compute/virtualMachines'; provisioningState = 'Succeeded' })
    Assert-Throws -Action { Invoke-DeploymentCheck -DeploymentProfile full -Resources $full -Outputs @{ AZURE_WINDOWS_VM_NAME = 'vm-win-fixture' } -PowerState 'PowerState/deallocated' } `
        -Message 'A jumpbox that is not running must fail the check.'
}

Test-Case 'the deployment check holds core to no network or compute unless an override adds them' {
    $withNetwork = $baseResources + @(@{ name = 'vnet-fixture'; type = 'Microsoft.Network/virtualNetworks'; provisioningState = 'Succeeded' })
    Assert-Throws -Action { Invoke-DeploymentCheck -DeploymentProfile core -Resources $withNetwork } -Message 'core with a virtual network must fail.'
    Assert-Throws -Action { Invoke-DeploymentCheck -DeploymentProfile core -Overrides '{"roleAssignments":false}' -Resources $withNetwork } `
        -Message 'An override that adds no network must keep the core rule.'
    $output = Invoke-DeploymentCheck -DeploymentProfile core -Overrides '{"network":true}' -Resources $withNetwork
    Assert-Match -Actual $output -Pattern 'All deployment checks passed' -Message 'An override that adds the network lifts the core rule.'
    $output = Invoke-DeploymentCheck -DeploymentProfile core -Resources $baseResources
    Assert-Match -Actual $output -Pattern 'core profile deployed no network or compute' -Message 'A clean core deployment must pass the rule.'
}

foreach ($scenario in @(
        @{ Name = 'edits the existing marked comment'; Existing = $true; Expected = 'PATCH repos/owner/repo/issues/comments/77' }
        @{ Name = 'creates the comment the first time'; Existing = $false; Expected = 'POST repos/owner/repo/issues/5/comments' }
    )) {
    Test-Case "publishing the what-if $($scenario.Name)" {
        $calls = [System.Collections.Generic.List[string]]::new()
        $existing = $scenario.Existing
        function gh {
            $global:LASTEXITCODE = 0
            if ($args -contains '--paginate') {
                $list = @(@{ id = 12; body = 'An unrelated review comment' } | ConvertTo-Json -Compress)
                if ($existing) { $list += @{ id = 77; body = "<!-- pr-deployment:core -->`nold" } | ConvertTo-Json -Compress }
                return $list
            }
            $calls.Add("$($args[2]) $($args[3])")
        }
        $body = Join-Path ([IO.Path]::GetTempPath()) ("body-$([guid]::NewGuid().ToString('N')).md")
        try {
            Set-Content -LiteralPath $body -Value "<!-- pr-deployment:core -->`nnew"
            & (Get-RepoPath 'scripts/publish-pr-comment.ps1') -Repository owner/repo -PullRequest 5 -BodyPath $body | Out-Null
            Assert-Equal -Actual ($calls -join ';') -Expected $scenario.Expected -Message 'Exactly one comment per profile must exist.'
            Set-Content -LiteralPath $body -Value 'no marker'
            Assert-Throws -Action { & (Get-RepoPath 'scripts/publish-pr-comment.ps1') -Repository owner/repo -PullRequest 5 -BodyPath $body } `
                -Message 'A body without a marker could never be found again and must be refused.'
        }
        finally { Remove-Item -LiteralPath $body -Force -ErrorAction SilentlyContinue }
    }
}

Test-Case 'the full-profile paths filter matches the infrastructure paths' {
    $lines = Get-Content -LiteralPath (Join-Path $workflowRoot 'pr-deployment-full.yml')
    $start = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match '^\s{4}paths:\s*$' })
    Assert-True -Condition ($start -ge 0) -Message 'pr-deployment-full.yml must filter on paths.'
    $paths = @($lines[($start + 1)..($lines.Count - 1)] | ForEach-Object {
            if ($_ -match '^\s{6}-\s+"(?<p>[^"]+)"\s*$') { $Matches['p'] } elseif ($_ -match '^\s*\S') { 'END' }
        })
    $paths = @($paths[0..([Math]::Max(0, [array]::IndexOf($paths, 'END') - 1))])
    Assert-Equal -Actual ($paths -join ',') -Expected ($script:CiInfrastructurePaths -join ',') `
        -Message 'The full workflow must deploy for exactly the changes pr-deployment.yml deploys for.'
}

Test-Case 'the deployment workflows are gated, never cancel a teardown and keep untrusted input out of scripts' {
    $files = @('deploy-environment.yml', 'pr-deployment.yml', 'pr-deployment-full.yml', 'pr-deployment-cleanup.yml')
    foreach ($file in $files) {
        $text = Get-Content -LiteralPath (Join-Path $workflowRoot $file) -Raw
        if ($file -ne 'deploy-environment.yml') {
            Assert-Match -Actual $text -Pattern "vars\.PR_DEPLOYMENT_ENABLED == 'true'" -Message "'$file' must stay skipped until the repository is set up."
        }
        Assert-NotMatch -Actual $text -Pattern 'cancel-in-progress:\s*true' -Message "'$file' must never cancel a run whose teardown is pending."
    }
    $deploy = Get-Content -LiteralPath (Join-Path $workflowRoot 'deploy-environment.yml') -Raw
    Assert-Match -Actual $deploy -Pattern "(?s)- name: Tear down\s+if: always\(\) && steps\.env\.outputs\.name != ''" -Message 'The teardown must run even after a failure or cancellation.'
    Assert-Match -Actual $deploy -Pattern 'environment: pr-deployment' -Message 'Deployments must wait for the approval environment.'
    Assert-Match -Actual $deploy -Pattern "AZURE_KEY_VAULT_PURGE_PROTECTION = 'false'" -Message 'Throwaway vaults must be purgeable.'
    foreach ($caller in @('pr-deployment.yml', 'pr-deployment-full.yml')) {
        $text = Get-Content -LiteralPath (Join-Path $workflowRoot $caller) -Raw
        Assert-Match -Actual $text -Pattern 'github\.event\.pull_request\.head\.repo\.full_name == github\.repository' -Message "'$caller' must never deploy a fork's pull request."
    }

    # An expression expanded inside a script is an injection point. Every run
    # block must take its inputs through env: instead.
    foreach ($workflow in (Get-ChildItem -LiteralPath $workflowRoot -Filter *.yml)) {
        $lines = Get-Content -LiteralPath $workflow.FullName
        $runIndent = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $indent = $line.Length - $line.TrimStart().Length
            if ($runIndent -ge 0 -and ($line.Trim() -eq '' -or $indent -gt $runIndent)) {
                Assert-NotMatch -Actual $line -Pattern '\$\{\{' -Message "$($workflow.Name):$($i + 1) expands an expression inside a script."
                continue
            }
            $runIndent = -1
            if ($line -match '^(?<pad>\s*)(?<dash>- )?run:\s*(?<rest>.*)$') {
                $pad = $Matches['pad'].Length + $(if ($Matches['dash']) { 2 } else { 0 })
                $rest = $Matches['rest']
                Assert-NotMatch -Actual $rest -Pattern '\$\{\{' -Message "$($workflow.Name):$($i + 1) expands an expression inside a script."
                if ($rest -match '^[|>]') { $runIndent = $pad }
            }
        }
    }
}

Test-Case 'the workflows keep identifiers secret, mask them first and pin every action' {
    $files = @(Get-ChildItem -LiteralPath $workflowRoot -Filter *.yml | ForEach-Object Name)
    Assert-True -Condition ($files -contains 'ci.yml') -Message 'Every workflow must be checked.'
    foreach ($file in $files) {
        $text = Get-Content -LiteralPath (Join-Path $workflowRoot $file) -Raw
        # Variables are printed unmasked in public logs; identifiers are secrets.
        foreach ($name in @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'CI_TENANT_CODE', 'CI_OPERATOR_PRINCIPAL_IDS')) {
            Assert-NotMatch -Actual $text -Pattern "vars\.$name\b" -Message "'$file' must read $name from a secret."
        }
        foreach ($use in [regex]::Matches($text, '(?m)^\s*(?:- )?uses:\s*(?<ref>\S+)(?<rest>.*)$')) {
            $ref = $use.Groups['ref'].Value
            if ($ref.StartsWith('./')) { continue }
            Assert-Match -Actual $ref -Pattern '^[\w.-]+/[\w.-]+@[0-9a-f]{40}$' -Message "'$file' must pin '$ref' by commit SHA."
            Assert-Match -Actual $use.Groups['rest'].Value -Pattern '^\s+# v\d+\.\d+\.\d+$' -Message "'$file' must name the version of '$ref' in a comment."
        }
        foreach ($checkout in [regex]::Matches($text, '(?m)^(?<pad>\s*)- uses: actions/checkout@.*\r?\n(?<with>(?:\k<pad>  .*\r?\n)+)')) {
            Assert-Match -Actual $checkout.Groups['with'].Value -Pattern 'persist-credentials: false' -Message "'$file' must not keep the token on a checkout."
        }
        Assert-Equal -Actual ([regex]::Matches($text, '(?m)^\s*- uses: actions/checkout@').Count) `
            -Expected ([regex]::Matches($text, 'persist-credentials: false').Count) -Message "Every checkout in '$file' must drop the token."
        # Every job that runs steps has a timeout; a job that calls a reusable workflow cannot.
        foreach ($job in [regex]::Split(($text -split '(?m)^jobs:\s*$')[1], '(?m)^(?=  [\w-]+:\s*$)') | Where-Object { $_.Trim() }) {
            if ($job -match '(?m)^    runs-on:') {
                Assert-Match -Actual $job -Pattern '(?m)^    timeout-minutes: \d+' -Message "Every job in '$file' must have a timeout."
            }
        }
        if ($text -match 'azure/login@') {
            Assert-Match -Actual $text -Pattern '(?s)- uses: actions/checkout@[^\n]*\n(?:\s+[^\n]*\n)*?\s*\n\s+(?:#[^\n]*\n\s+)*- uses: \./\.github/actions/mask-values' `
                -Message "'$file' must mask the identifiers right after the checkout, before it signs in."
        }
    }
    Assert-True -Condition (Test-Path -LiteralPath (Get-RepoPath '.github/actions/mask-values/mask-values.sh')) -Message 'The masking action must be in the repository.'
}

Test-Case 'the masking action masks each GUID inside a list and skips short values' {
    $bash = Get-TestBash
    $jq = Get-Command jq -ErrorAction SilentlyContinue
    if (-not $bash -or -not $jq) {
        Write-Warning 'bash or jq is missing: the masking action was not run.'
        return
    }
    $script = Get-RepoPath '.github/actions/mask-values/mask-values.sh'
    $env:MASK_MIN_LENGTH = '4'
    try {
        $out = @("11111111-2222-3333-4444-555555555555,66666666-7777-8888-9999-000000000000`nab`ncal01" | & $bash $script)
    }
    finally {
        Remove-Item Env:MASK_MIN_LENGTH
    }
    foreach ($value in @('66666666-7777-8888-9999-000000000000', '11111111-2222-3333-4444-555555555555', 'cal01')) {
        Assert-True -Condition ($out -contains "::add-mask::$value") -Message "'$value' must be masked on its own."
    }
    Assert-True -Condition (-not ($out -contains '::add-mask::ab')) -Message 'A value shorter than the minimum is not masked.'
}

# The jobs of a workflow, by id, each with its text.
function Get-WorkflowJobs {
    param([Parameter(Mandatory)] [string] $Path)

    $text = Get-Content -LiteralPath $Path -Raw
    $jobs = [ordered] @{}
    foreach ($job in [regex]::Split(($text -split '(?m)^jobs:\s*$')[1], '(?m)^(?=  [\w-]+:\s*$)') | Where-Object { $_.Trim() }) {
        if ($job -match '^\s*(?<id>[\w-]+):') { $jobs[$Matches['id']] = $job }
    }
    $jobs
}

# The run script of a step, found by its name or its id, without its YAML indentation.
function Get-WorkflowStepScript {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $StepName
    )

    $lines = Get-Content -LiteralPath $Path
    $step = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match "^\s*- (name|id): $([regex]::Escape($StepName))\s*$" })
    if ($step -lt 0) { throw "No step '$StepName' in $Path." }
    $run = $step + 1
    while ($lines[$run] -notmatch '^\s*run:\s*\|\s*$') { $run++ }
    $body = [System.Collections.Generic.List[string]]::new()
    $indent = -1
    for ($i = $run + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim() -eq '') { $body.Add(''); continue }
        $pad = $line.Length - $line.TrimStart().Length
        if ($indent -lt 0) { $indent = $pad }
        if ($pad -lt $indent) { break }
        $body.Add($line.Substring($indent))
    }
    ($body -join "`n").TrimEnd() + "`n"
}

Test-Case 'CI result waits for every CI job, and CI validates the infrastructure on every PR' {
    $path = Join-Path $workflowRoot 'ci.yml'
    $jobs = Get-WorkflowJobs -Path $path
    Assert-True -Condition ($jobs.Contains('result')) -Message 'ci.yml must have the CI result job.'
    Assert-Match -Actual $jobs['result'] -Pattern '(?m)^    name: CI result\s*$' -Message 'The required check is named CI result.'
    Assert-Match -Actual $jobs['result'] -Pattern '(?m)^    if: always\(\)\s*$' -Message 'CI result must report even when a job failed.'
    $needs = if ($jobs['result'] -match '(?m)^    needs: \[(?<n>[^\]]*)\]') { @($Matches['n'] -split ',\s*' | Sort-Object) } else { @() }
    $others = @($jobs.Keys | Where-Object { $_ -ne 'result' } | Sort-Object)
    Assert-Equal -Actual ($needs -join ',') -Expected ($others -join ',') -Message 'CI result must wait for every other CI job.'

    $text = Get-Content -LiteralPath $path -Raw
    Assert-NotMatch -Actual $text -Pattern '(?m)^\s+paths:' -Message 'CI must run on every PR, so CI result always reports.'
    foreach ($step in @('./scripts/build-catalog.ps1 -Check', './scripts/build-docs.ps1 -Check', './tests/run-tests.ps1', 'az bicep format')) {
        Assert-True -Condition ($jobs['infrastructure'].Contains($step)) -Message "The infrastructure job must run '$step'."
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $workflowRoot 'infra-validation.yml'))) -Message 'The validation lives in ci.yml only.'
}

Test-Case 'PR rules accept each owner''s branch names and refuse squad/ and unprefixed ones' {
    $bash = Get-TestBash
    if (-not $bash) {
        Write-Warning 'bash is missing: the PR rules branch check was not run.'
        return
    }
    $script = Get-WorkflowStepScript -Path (Join-Path $workflowRoot 'pr-rules.yml') -StepName 'Branch name and base branch'
    $cases = @(
        @{ Owner = 'embergershared'; Head = 'emberger/ci/15-ci-result'; Fork = $false; Base = 'main'; Pass = $true }
        @{ Owner = 'g62priv'; Head = 'emm/feature/42-statement-extraction'; Fork = $false; Base = 'main'; Pass = $true }
        @{ Owner = 'contoso'; Head = 'fix/7-retry'; Fork = $false; Base = 'main'; Pass = $true }
        @{ Owner = 'embergershared'; Head = 'fix/57-retry-on-throttle'; Fork = $true; Base = 'main'; Pass = $true }
        @{ Owner = 'embergershared'; Head = 'fix/57-retry-on-throttle'; Fork = $false; Base = 'main'; Pass = $false }
        @{ Owner = 'g62priv'; Head = 'emberger/fix/57-retry'; Fork = $false; Base = 'main'; Pass = $false }
        @{ Owner = 'embergershared'; Head = 'squad/12-anything'; Fork = $false; Base = 'main'; Pass = $false }
        @{ Owner = 'embergershared'; Head = 'emberger/fix/no-issue'; Fork = $false; Base = 'main'; Pass = $false }
        @{ Owner = 'embergershared'; Head = 'emberger/fix/57-retry'; Fork = $false; Base = 'develop'; Pass = $false }
        @{ Owner = 'embergershared'; Head = 'emberger/fix/57-retry'; Fork = $false; Base = 'emberger/main'; Pass = $true }
    )
    $scriptPath = Join-Path ([IO.Path]::GetTempPath()) ("pr-rules-$([guid]::NewGuid().ToString('N')).sh")
    [IO.File]::WriteAllText($scriptPath, $script)
    $saved = @{}
    foreach ($name in 'OWNER', 'REPO', 'HEAD_REPO', 'HEAD_REF', 'BASE_REF', 'DEFAULT_BRANCH') { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        foreach ($case in $cases) {
            $env:OWNER = $case.Owner
            $env:REPO = "$($case.Owner)/project"
            $env:HEAD_REPO = if ($case.Fork) { 'someone/project' } else { $env:REPO }
            $env:HEAD_REF = $case.Head
            $env:BASE_REF = $case.Base
            $env:DEFAULT_BRANCH = 'main'
            & $bash $scriptPath *> $null
            $label = "'$($case.Head)' into '$($case.Base)' in $($case.Owner)$(if ($case.Fork) { ' from a fork' })"
            Assert-Equal -Actual ($LASTEXITCODE -eq 0) -Expected $case.Pass -Message "$label must $(if ($case.Pass) { 'pass' } else { 'fail' })."
        }
    }
    finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        Remove-Item -LiteralPath $scriptPath -ErrorAction SilentlyContinue
    }
}

Test-Case 'CI detects a stack only from tracked files, and the repository variable picks the .NET target' {
    $bash = Get-TestBash
    if (-not $bash) {
        Write-Warning 'bash is missing: the stack detection was not run.'
        return
    }
    $script = Get-WorkflowStepScript -Path (Join-Path $workflowRoot 'ci.yml') -StepName 'stacks'
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ci-stacks-$([guid]::NewGuid().ToString('N'))")
    $scriptPath = "$root.sh"
    [IO.File]::WriteAllText($scriptPath, $script)
    $saved = @{}
    foreach ($name in 'DOTNET_SOLUTION', 'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY') { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    $detect = {
        param([string[]] $Tracked, [string[]] $Untracked = @(), [string] $Solution = '')
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        New-Item -ItemType Directory -Path $root | Out-Null
        foreach ($file in @($Tracked) + @($Untracked) + @('README.md')) {
            $full = Join-Path $root $file
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            Set-Content -LiteralPath $full -Value ''
        }
        git -C $root init -q
        git -C $root add -- README.md @($Tracked)
        $output = Join-Path $root 'github-output.txt'
        $env:GITHUB_OUTPUT = $output.Replace('\', '/')
        $env:GITHUB_STEP_SUMMARY = (Join-Path $root 'summary.md').Replace('\', '/')
        $env:DOTNET_SOLUTION = $Solution
        Push-Location -LiteralPath $root
        try { & $bash $scriptPath.Replace('\', '/') *> $null } finally { Pop-Location }
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message 'The detection must succeed.'
        $result = @{}
        foreach ($line in Get-Content -LiteralPath $output) {
            $key, $value = $line -split '=', 2
            $result[$key] = $value
        }
        $result
    }
    try {
        $none = & $detect -Tracked @() -Untracked @('src/App/App.csproj', 'requirements.lock')
        Assert-Equal -Actual "$($none['dotnet'])/$($none['python'])" -Expected 'false/false' -Message 'Untracked files must not turn a stack on.'

        $both = & $detect -Tracked @('App.slnx', 'src/App/App.csproj', 'requirements.lock', 'requirements-dev.lock')
        Assert-Equal -Actual "$($both['dotnet'])|$($both['dotnet-target'])" -Expected 'true|App.slnx' -Message 'The shallowest solution is the .NET target.'
        Assert-Equal -Actual "$($both['python'])|$($both['python-lock'])" -Expected 'true|requirements-dev.lock' -Message 'The development lock is installed first.'

        $project = & $detect -Tracked @('src/App/App.csproj')
        Assert-Equal -Actual $project['dotnet-target'] -Expected 'src/App/App.csproj' -Message 'Without a solution, the project is the target.'

        $chosen = & $detect -Tracked @('App.slnx', 'src/Other.slnx') -Solution 'src/Other.slnx'
        Assert-Equal -Actual $chosen['dotnet-target'] -Expected 'src/Other.slnx' -Message 'DOTNET_SOLUTION overrides the detection.'
    }
    finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $scriptPath -ErrorAction SilentlyContinue
    }
}

Test-Case 'the code scaffolding restores from the approved feed only, locked, and CI checks the package age' {
    # A project set up with Initialize-Repo.ps1 -Stacks keeps one stack; the template keeps both.
    $dotnet = Test-Path -LiteralPath (Get-RepoPath 'nuget.config')
    $python = Test-Path -LiteralPath (Get-RepoPath '.python-version')
    if (Test-Path -LiteralPath (Get-RepoPath 'scripts/Initialize-Repo.ps1')) {
        Assert-True -Condition ($dotnet -and $python) -Message 'The template must carry both stacks.'
    }

    if ($dotnet) {
        [xml] $nuget = Get-Content -LiteralPath (Get-RepoPath 'nuget.config') -Raw
        $sources = $nuget.configuration.packageSources
        Assert-True -Condition ($null -ne $sources.SelectSingleNode('clear')) -Message 'nuget.config must clear every inherited feed.'
        $feeds = @($sources.SelectNodes('add') | ForEach-Object { $_.value })
        Assert-Equal -Actual ($feeds -join ',') -Expected 'https://packagefeedproxy.microsoft.io/nuget/v3/index.json' `
            -Message 'NuGet must restore from the approved feed only, with no nuget.org fallback.'
        $props = Get-Content -LiteralPath (Get-RepoPath 'Directory.Build.props') -Raw
        Assert-Match -Actual $props -Pattern '<RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>' -Message 'Every .NET project must have a lock file.'
        Assert-Match -Actual $props -Pattern '<RestoreLockedMode Condition="''\$\(ContinuousIntegrationBuild\)'' == ''true''">true</RestoreLockedMode>' -Message 'CI must restore exactly the locked versions.'
        Assert-Match -Actual (Get-Content -LiteralPath (Get-RepoPath 'Directory.Packages.props') -Raw) -Pattern '<ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>' `
            -Message 'NuGet versions must be set centrally.'
        Assert-True -Condition ($null -ne (Get-Content -LiteralPath (Get-RepoPath 'global.json') -Raw | ConvertFrom-Json).sdk.version) -Message 'global.json must pin the SDK.'
        Assert-True -Condition (Test-Path -LiteralPath (Get-RepoPath 'scripts/db/Invoke-EfMigration.ps1')) -Message 'The EF Core migration script must be in the repository.'
    }
    if ($python) {
        Assert-Match -Actual (Get-Content -LiteralPath (Get-RepoPath '.python-version') -Raw) -Pattern '^3\.\d+\s*$' -Message '.python-version must pin a Python 3 release.'
        Assert-True -Condition (Test-Path -LiteralPath (Get-RepoPath 'scripts/lock_requirements.py')) -Message 'The lock script must be in the repository.'
    }

    $ci = Get-Content -LiteralPath (Join-Path $workflowRoot 'ci.yml') -Raw
    Assert-Match -Actual $ci -Pattern 'python scripts/check_package_age\.py --min-age-days 7' -Message 'CI must run the 7-day age gate.'
    Assert-Match -Actual $ci -Pattern 'pip install --require-hashes' -Message 'CI must install Python packages by hash only.'
    foreach ($script in 'scripts/check_package_age.py', 'scripts/db/sqlite_backup.py') {
        Assert-True -Condition (Test-Path -LiteralPath (Get-RepoPath $script)) -Message "'$script' must be in the repository."
    }
}
