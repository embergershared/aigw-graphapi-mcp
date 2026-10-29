<#
.SYNOPSIS
    Deletes throwaway pull request environments and purges their Key Vaults.

.DESCRIPTION
    The pull request deployment workflow calls this with -EnvironmentName as
    its teardown step, and the nightly cleanup workflow calls it with
    -OlderThanHours to remove anything a failed teardown left behind.

    It only touches resource groups that this repository created for a
    throwaway environment: the group's repository tag must equal -Repository
    and its azd-env-name tag must match the throwaway naming pattern in
    scripts/ci-environments.ps1. Any other resource group is never deleted,
    whatever its name.

    Deleting a resource group soft-deletes its Key Vault. Vaults from the same
    environments are then purged, so their names are free again at once. A
    vault created with purge protection cannot be purged; it is reported and
    left to expire.

    It does not rely on azd state, so it also cleans up after a provision that
    failed half way.

.PARAMETER SubscriptionId
    Subscription that holds the environments.

.PARAMETER Repository
    owner/name of the repository, as the repository tag records it.

.PARAMETER EnvironmentName
    Remove exactly this environment.

.PARAMETER OlderThanHours
    Remove every throwaway environment of this repository whose created-on
    tag is older than this many hours.

.EXAMPLE
    ./scripts/remove-ci-environments.ps1 -SubscriptionId <id> -Repository owner/repo -EnvironmentName pr12-core-40-1
.EXAMPLE
    ./scripts/remove-ci-environments.ps1 -SubscriptionId <id> -Repository owner/repo -OlderThanHours 6 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'One')]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $Repository,
    [Parameter(Mandatory, ParameterSetName = 'One')] [string] $EnvironmentName,
    [Parameter(Mandatory, ParameterSetName = 'Sweep')] [ValidateRange(0, 8760)] [int] $OlderThanHours
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'ci-environments.ps1')

if ($PSCmdlet.ParameterSetName -eq 'One' -and -not (Test-CiEnvironmentName $EnvironmentName)) {
    throw "'$EnvironmentName' is not a throwaway environment name; refusing to remove it."
}
$cutoff = [DateTimeOffset]::UtcNow.AddHours(-$OlderThanHours)

function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $json = & az @Arguments --subscription $SubscriptionId --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
    $text = ($json -join "`n").Trim()
    if (-not $text) { return @() }
    return ($text | ConvertFrom-Json)
}

function Get-Tag {
    param($Tags, [string] $Name)
    if ($null -eq $Tags -or -not $Tags.PSObject.Properties[$Name]) { return '' }
    return [string] $Tags.$Name
}

function Test-Selected {
    param($Tags, [string] $CreatedOn)
    if ((Get-Tag $Tags 'repository') -cne $Repository) { return $false }
    $name = Get-Tag $Tags 'azd-env-name'
    if (-not (Test-CiEnvironmentName $name)) { return $false }
    if ($PSCmdlet.ParameterSetName -eq 'One') { return $name -ceq $EnvironmentName }
    $created = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($CreatedOn, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref] $created)) {
        Write-Warning "Skipping '$name': its creation time '$CreatedOn' cannot be read."
        return $false
    }
    return $created -lt $cutoff
}

$removed = [System.Collections.Generic.List[string]]::new()
$groups = @(Invoke-AzJson -Arguments @('group', 'list'))
foreach ($group in $groups) {
    if (-not (Test-Selected -Tags $group.tags -CreatedOn (Get-Tag $group.tags 'created-on'))) { continue }
    $name = Get-Tag $group.tags 'azd-env-name'
    if ($PSCmdlet.ShouldProcess("resource group '$($group.name)' of environment '$name'", 'Delete')) {
        Write-Output "Deleting resource group '$($group.name)' ($name)..."
        & az group delete --name $group.name --subscription $SubscriptionId --yes --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Unable to delete resource group '$($group.name)'." }
        Write-Output "Deleted resource group '$($group.name)'."
    }
    $removed.Add($name)
}

$vaults = @(Invoke-AzJson -Arguments @('keyvault', 'list-deleted', '--resource-type', 'vault'))
$purged = 0
foreach ($vault in $vaults) {
    $properties = $vault.properties
    $tags = if ($properties.PSObject.Properties['tags']) { $properties.tags } else { $null }
    $name = Get-Tag $tags 'azd-env-name'
    if ((Get-Tag $tags 'repository') -cne $Repository -or -not (Test-CiEnvironmentName $name)) { continue }
    if ($PSCmdlet.ParameterSetName -eq 'One' -and $name -cne $EnvironmentName) { continue }
    if ($properties.PSObject.Properties['purgeProtectionEnabled'] -and $properties.purgeProtectionEnabled) {
        Write-Warning "Key Vault '$($vault.name)' of '$name' has purge protection and stays soft-deleted until $($properties.scheduledPurgeDate)."
        continue
    }
    if ($PSCmdlet.ShouldProcess("soft-deleted Key Vault '$($vault.name)' of environment '$name'", 'Purge')) {
        & az keyvault purge --name $vault.name --location $properties.location --subscription $SubscriptionId --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "Unable to purge Key Vault '$($vault.name)'." }
        Write-Output "Purged Key Vault '$($vault.name)'."
    }
    $purged++
}

if ($removed.Count -eq 0 -and $purged -eq 0) {
    Write-Output 'Nothing to remove.'
}
else {
    Write-Output "Removed $($removed.Count) environment(s) and purged $purged Key Vault(s)."
}
