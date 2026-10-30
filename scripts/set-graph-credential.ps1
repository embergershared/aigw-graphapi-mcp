<#
.SYNOPSIS
    Creates the owned gateway OBO credential and stores it in Key Vault through ARM.
.DESCRIPTION
    No credential is created by default or on reprovision. Apply requires separate approval.
    A nonsecret write probe through ARM (Microsoft.KeyVault/vaults/secrets, which works while
    the vault's public network access is disabled) must succeed before addPassword.
    The value stays in memory and HTTPS bodies: never CLI arguments, files, logs or output.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)] [ValidatePattern('^[a-z][a-z0-9-]{1,31}$')] [string] $Environment,
    [guid] $TenantId,
    [guid] $SubscriptionId,
    [string] $Location,
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$')] [string] $VaultName,
    [string] $ResourceGroupName,
    [ValidatePattern('^[A-Za-z0-9-]{1,127}$')] [string] $SecretName='graph-obo-client-secret',
    [DateTimeOffset] $ExpiresOn,
    [switch] $Apply,
    [switch] $CredentialChangeApproved,
    [switch] $Rotate
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'graph-identity.ps1')
$plan=Get-GraphIdentityPlan $Environment
if (-not $Apply -or $WhatIfPreference) {
    return [pscustomobject]@{Status='PreparedOnly';SecretName=$SecretName;Rotate=[bool]$Rotate;SecretCreated=$false;CredentialWriteSupported=$true;Requires='Separate credential approval, selected expiry, owned app and a successful nonsecret write probe through ARM before addPassword.'}
}
if (-not $CredentialChangeApproved) { throw 'Credential creation/rotation requires separate recorded approval.' }
if (-not $VaultName -or -not $ResourceGroupName -or $ExpiresOn -le [DateTimeOffset]::UtcNow) { throw 'Select the owned vault/resource group and a future explicitly approved credential expiry.' }
Assert-GraphOperatorContext $Environment $TenantId $SubscriptionId $Location
$vaultJson=& az keyvault show --subscription $SubscriptionId.ToString() --name $VaultName --resource-group $ResourceGroupName `
    --query '{id:id,location:location,tags:tags,rbac:properties.enableRbacAuthorization,purge:properties.enablePurgeProtection,firewall:properties.networkAcls.defaultAction}' --output json 2>$null
if ($LASTEXITCODE -ne 0) { throw 'The owned vault could not be verified; no credential was created.' }
$vault=$vaultJson | ConvertFrom-Json
if ($vault.id -ine "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults/$VaultName" -or
    $vault.location -ine $Location -or $vault.tags.environment -cne $Environment -or
    -not $vault.rbac -or -not $vault.purge -or $vault.firewall -cne 'Deny') {
    throw 'The selected vault does not match the owned environment, approved region or deny-by-default RBAC/purge-protection contract.'
}
if (-not $PSCmdlet.ShouldProcess('the owned gateway application and selected vault secret', 'Create a confidential credential and store it over HTTPS (never print its value)')) { return }
$token=Get-GraphOperatorToken $TenantId
$armToken=$null
$password=$null
try {
    $app=Get-OwnedGraphApplication $plan.gatewayName "$($plan.ownershipPrefix)/gateway" $token
    if ($null -eq $app) { throw 'Configure the owned gateway app before creating its credential.' }
    $existing=@($app.passwordCredentials | Where-Object displayName -eq 'graph-mcp-obo')
    if ($existing.Count -gt 0 -and -not $Rotate) {
        return [pscustomobject]@{Status='ExistingCredentialNotRotated';VaultCopyVerified=$false;NextAction='Verify the vault copy and expiry under separate authority; use explicit rotation only when approved.'}
    }
    $armToken=Get-GraphOperatorToken $TenantId 'https://management.azure.com'
    Assert-GraphCredentialStorageReady -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
        -VaultName $VaultName -ArmToken $armToken
    $password=Invoke-GraphIdentityRequest POST "applications/$($app.id)/addPassword" $token @{
        passwordCredential=@{displayName='graph-mcp-obo';endDateTime=$ExpiresOn.ToUniversalTime().ToString('o')}
    }
    Save-GraphCredentialVaultCopy -ApplicationObjectId $app.id -Credential $password -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName -VaultName $VaultName -SecretName $SecretName -ExpiresOn $ExpiresOn -ArmToken $armToken
} finally {
    $password=$null
    $armToken=$null
    $token=$null
}
