<#
.SYNOPSIS
    Shared helpers for the pull request deployment workflows.

.DESCRIPTION
    Dot-source this file. It names the throwaway environments that
    .github/workflows/deploy-environment.yml creates, recognizes them again for
    teardown, decides which profiles a run deploys and formats the what-if
    preview counts for the pull request. docs/ci-deployment.md describes the
    workflows.

    Every throwaway environment name matches $CiEnvironmentNamePattern, and the
    teardown and nightly cleanup never touch a resource group whose name does
    not match it.
#>

Set-StrictMode -Version Latest

$script:CiProfiles = @('core', 'private', 'full')

# pr<number>-<profile>-<run>-<attempt> for a pull request, ci-<profile>-<run>-<attempt>
# for a manual run. The longest possible name, pr999999-private-9999999-99, is
# 27 characters, inside AZURE_ENV_NAME's 32-character limit.
$script:CiEnvironmentNamePattern = '^(pr[0-9]{1,6}|ci)-(core|private|full)-[0-9]{1,7}-[0-9]{1,2}$'

# The paths whose changes can alter what a deployment creates. A pull request
# that touches none of them deploys nothing. pr-deployment-full.yml repeats this
# list as its paths filter; a test keeps the two in step.
$script:CiInfrastructurePaths = @(
    'infra/**'
    'scripts/**'
    'azure.yaml'
    '.github/workflows/pr-deployment.yml'
    '.github/workflows/pr-deployment-full.yml'
    '.github/workflows/deploy-environment.yml'
)

function Get-CiEnvironmentName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateSet('core', 'private', 'full')] [string] $DeploymentProfile,
        [int] $PullRequest = 0,
        [Parameter(Mandatory)] [ValidateRange(1, 9999999)] [int] $RunNumber,
        [ValidateRange(1, 99)] [int] $RunAttempt = 1
    )

    $prefix = if ($PullRequest -gt 0) { "pr$PullRequest" } else { 'ci' }
    $name = "$prefix-$DeploymentProfile-$RunNumber-$RunAttempt"
    if ($name -cnotmatch $script:CiEnvironmentNamePattern) {
        throw "Throwaway environment name '$name' does not match $script:CiEnvironmentNamePattern."
    }
    return $name
}

function Test-CiEnvironmentName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()] [AllowNull()] [string] $Name)

    return ([string] $Name) -cmatch $script:CiEnvironmentNamePattern
}

# The tenant catalog is gitignored, so a runner's checkout has none. The
# deployment job writes one holding only the tenant it deploys to.
function New-CiTenantCatalog {
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [string] $TenantId,
        [AllowEmptyString()] [string] $TenantCode,
        [Parameter(Mandatory)] [string] $Path
    )

    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($TenantId, [ref] $parsed)) {
        throw 'The AZURE_TENANT_ID repository secret must be the tenant GUID. See docs/ci-deployment.md.'
    }
    if ($TenantCode -cnotmatch '^[a-z0-9]{2,12}$') {
        throw 'The CI_TENANT_CODE repository secret must be the tenant''s code: 2-12 lowercase alphanumeric characters. See docs/ci-deployment.md.'
    }
    if (Test-Path -LiteralPath $Path) {
        throw "The tenant catalog '$Path' already exists; the runner's checkout must not carry one."
    }

    $catalog = [ordered] @{ $TenantId.Trim().ToLowerInvariant() = [ordered] @{ name = 'CI'; code = $TenantCode } }
    Set-Content -LiteralPath $Path -Value (ConvertTo-Json -InputObject $catalog -Depth 3)
}

function Test-InfrastructureChange {
    <#
    .SYNOPSIS
        True when any of the changed paths can alter what a deployment creates.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyCollection()] [string[]] $Path = @())

    foreach ($changed in $Path) {
        $normalized = ([string] $changed).Trim().Replace('\', '/')
        if (-not $normalized) { continue }
        foreach ($pattern in $script:CiInfrastructurePaths) {
            if ($pattern.EndsWith('/**')) {
                if ($normalized.StartsWith($pattern.Substring(0, $pattern.Length - 2), [StringComparison]::Ordinal)) { return $true }
            }
            elseif ($normalized -ceq $pattern) {
                return $true
            }
        }
    }
    return $false
}

function Get-CiDeploymentProfiles {
    <#
    .SYNOPSIS
        The profiles one run of pr-deployment.yml deploys.
    .DESCRIPTION
        A pull request deploys core and private when it changes infrastructure,
        and nothing otherwise. A manual run deploys the one profile it was given.
        full never runs from here on a pull request; pr-deployment-full.yml
        deploys it when the pull request carries the deploy-full label.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $EventName,
        [AllowEmptyString()] [string] $DispatchProfile = '',
        [bool] $InfrastructureChanged = $false
    )

    switch ($EventName) {
        'pull_request' {
            if ($InfrastructureChanged) { return [string[]] @('core', 'private') }
            return [string[]] @()
        }
        'workflow_dispatch' {
            if ($DispatchProfile -cnotin $script:CiProfiles) {
                throw "Manual runs deploy one of: $($script:CiProfiles -join ', '); received '$DispatchProfile'."
            }
            return [string[]] @($DispatchProfile)
        }
        default { throw "Unsupported event '$EventName'." }
    }
}

# The operations `azd provision --preview` prints at the start of each resource
# line, in the order the comment lists them. azd shows NoChange and Ignore as Skip.
$script:CiPreviewOperations = @('Create', 'Modify', 'Delete', 'Deploy', 'Skip', 'Unsupported')

function Get-PreviewCounts {
    <#
    .SYNOPSIS
        Counts the resources of `azd provision --preview` output by operation.
    .DESCRIPTION
        azd prints one line per resource, `<Operation> : <Type> : <Name>`, with
        the property changes indented below it. Only the operations are kept:
        names and property values identify the tenant's resources.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Preview)

    $counts = [ordered] @{}
    foreach ($operation in $script:CiPreviewOperations) { $counts[$operation] = 0 }
    $pattern = '^\s*(?<op>' + ($script:CiPreviewOperations -join '|') + ')\s+:\s+\S.*?\s:\s'
    foreach ($line in (($Preview -replace "`e\[[0-9;?]*[A-Za-z]", '') -split "`r?`n")) {
        if ($line -cmatch $pattern) { $counts[$Matches['op']]++ }
    }
    return $counts
}

function ConvertTo-PreviewComment {
    <#
    .SYNOPSIS
        Formats the counts of `azd provision --preview` as a pull request comment.
    .DESCRIPTION
        The repository is public, so the comment and the job summary carry only
        how many resources each operation touches; the full preview stays in the
        masked run log. The comment starts with a marker so a later run edits it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateSet('core', 'private', 'full')] [string] $DeploymentProfile,
        [Parameter(Mandatory)] [string] $EnvironmentName,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Preview,
        [Parameter(Mandatory)] [ValidateSet('success', 'failure', 'cancelled', 'skipped')] [string] $Outcome,
        [string] $RunUrl = ''
    )

    $status = switch ($Outcome) {
        'success' { 'succeeded' }
        'failure' { 'failed' }
        'cancelled' { 'was cancelled' }
        'skipped' { 'did not run' }
    }
    $counts = Get-PreviewCounts -Preview $Preview
    $total = ($counts.Values | Measure-Object -Sum).Sum
    $result = if ($total -gt 0) {
        $parts = @(
            "$($counts.Create) to create", "$($counts.Modify) to modify", "$($counts.Delete) to delete"
            if ($counts.Deploy) { "$($counts.Deploy) to deploy" }
            "$($counts.Skip) unchanged"
            if ($counts.Unsupported) { "$($counts.Unsupported) unsupported" }
        )
        "Resources: $($parts -join ', ')."
    }
    elseif ($Outcome -eq 'success') { 'Resources: the preview listed no resources.' }
    else { 'Resources: none counted.' }

    $lines = @(
        "<!-- pr-deployment:$DeploymentProfile -->"
        "### What-if: ``$DeploymentProfile`` profile"
        ''
        "The preview for the throwaway environment ``$EnvironmentName`` $status." + $(if ($RunUrl) { " [Run log]($RunUrl)" } else { '' })
        ''
        $result
        ''
        'The resources and their changes are only in the run log, which masks identifiers.'
    )
    return ($lines -join "`n")
}
