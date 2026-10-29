<#
.SYNOPSIS
    Prepares owned single-tenant app registrations; changes nothing unless explicitly applied.
.DESCRIPTION
    Applying requires separate identity approval, verified CLI/azd context and confirmation.
    Declares delegated permissions only; never grants consent or creates/rotates credentials.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)] [ValidatePattern('^[a-z][a-z0-9-]{1,31}$')] [string] $Environment,
    [guid] $TenantId,
    [guid] $SubscriptionId,
    [string] $Location,
    [string] $PublicRedirectUri = 'http://localhost:8400/',
    [string] $FoundryCallbackUri = '',
    [switch] $Apply,
    [switch] $IdentityChangeApproved
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'graph-identity.ps1')
$plan = Get-GraphIdentityPlan $Environment $PublicRedirectUri $FoundryCallbackUri
if (-not $Apply -or $WhatIfPreference) { return $plan }
if (-not $IdentityChangeApproved) { throw 'Applying app-registration changes requires separate recorded identity approval.' }
Assert-GraphOperatorContext $Environment $TenantId $SubscriptionId $Location
if (-not $PSCmdlet.ShouldProcess('the explicitly selected tenant and three owned applications', 'Create/update delegated identity manifests (no consent or credentials)')) { return }
$token = Get-GraphOperatorToken $TenantId
try {
    $graph = Invoke-GraphIdentityRequest GET "servicePrincipals?`$filter=appId%20eq%20'00000003-0000-0000-c000-000000000000'" $token
    if (@($graph.value).Count -ne 1) { throw 'The Microsoft Graph service principal must be present in the selected tenant.' }
    $permissions = @()
    foreach ($name in $plan.delegatedGraphPermissions) {
        $scope = @($graph.value[0].oauth2PermissionScopes | Where-Object { $_.value -ceq $name -and $_.isEnabled })
        if ($scope.Count -ne 1) { throw "The required delegated permission $name could not be verified." }
        $permissions += @{id=$scope[0].id;type='Scope'}
    }
    $gatewayTag = "$($plan.ownershipPrefix)/gateway"
    $existing = Get-OwnedGraphApplication $plan.gatewayName $gatewayTag $token
    $existingScopes = @($(if ($null -ne $existing) { $existing.api.oauth2PermissionScopes }))
    if (@($existingScopes | Where-Object value -cne 'access_as_user').Count) { throw 'Unexpected gateway API scopes require manual review.' }
    $scopeId = if ($existingScopes.Count -eq 1) { $existingScopes[0].id } else { [guid]::NewGuid().ToString() }
    $gateway = Set-OwnedGraphApplication $plan.gatewayName $gatewayTag @{
        isFallbackPublicClient=$false
        requiredResourceAccess=@(@{resourceAppId='00000003-0000-0000-c000-000000000000';resourceAccess=$permissions})
        api=@{
            requestedAccessTokenVersion=2
            oauth2PermissionScopes=@(@{
                id=$scopeId;value='access_as_user';type='User';isEnabled=$true
                adminConsentDisplayName='Read your own mail and calendar through the gateway'
                adminConsentDescription='Allows the approved gateway to read the signed-in user mailbox and calendar.'
                userConsentDisplayName='Read your own mail and calendar through the gateway'
                userConsentDescription='Read-only access through the approved gateway; no sending, editing or deleting.'
            })
        }
    } $token
    $audience = "api://$($gateway.appId)"
    if (@($gateway.identifierUris | Where-Object { $_ -cne $audience }).Count) {
        throw 'Unexpected gateway identifier URIs require manual review; the owned audience was not changed.'
    }
    if (@($gateway.identifierUris).Count -ne 1 -or $gateway.identifierUris[0] -cne $audience) {
        Invoke-GraphIdentityRequest PATCH "applications/$($gateway.id)" $token @{identifierUris=@($audience)} | Out-Null
    }
    $gatewayAccess = @(@{resourceAppId=$gateway.appId;resourceAccess=@(@{id=$scopeId;type='Scope'})})
    $existingFoundry = Get-OwnedGraphApplication $plan.foundryName "$($plan.ownershipPrefix)/foundry" $token
    $redirects = if ($FoundryCallbackUri -or $null -eq $existingFoundry) {
        $plan.foundryRedirectUris
    } else { @($existingFoundry.web.redirectUris) }
    $foundry = Set-OwnedGraphApplication $plan.foundryName "$($plan.ownershipPrefix)/foundry" @{
        isFallbackPublicClient=$false;requiredResourceAccess=$gatewayAccess
        web=@{redirectUris=@($redirects);implicitGrantSettings=@{enableAccessTokenIssuance=$false;enableIdTokenIssuance=$false}}
    } $token
    $public = Set-OwnedGraphApplication $plan.publicName "$($plan.ownershipPrefix)/local" @{
        isFallbackPublicClient=$false;requiredResourceAccess=$gatewayAccess
        publicClient=@{redirectUris=@($plan.publicRedirectUri)}
    } $token
    foreach ($entry in @{
        GRAPH_GATEWAY_CLIENT_ID=$gateway.appId
        GRAPH_ALLOWED_CLIENT_IDS="$($foundry.appId),$($public.appId)"
        GRAPH_FOUNDRY_CLIENT_ID=$foundry.appId
        GRAPH_PUBLIC_CLIENT_ID=$public.appId
    }.GetEnumerator()) {
        & azd env set $entry.Key $entry.Value --environment $Environment 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Applications were configured but azd metadata was not saved. Reconcile before continuing.' }
    }
    [pscustomobject]@{Status='IdentityManifestsConfigured';ConsentGranted=$false;CredentialsCreated=$false;CallbackConfigured=[bool]$FoundryCallbackUri}
} finally {
    $token=$null
}
