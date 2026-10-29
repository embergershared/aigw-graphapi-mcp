Set-StrictMode -Version Latest
$script:GraphIdentitySettings = @{RequestTimeoutSeconds=30;VaultSecretsApiVersion='7.4'}

function Get-GraphIdentityPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidatePattern('^[a-z][a-z0-9-]{1,31}$')] [string] $Environment,
        [string] $PublicRedirectUri = 'http://localhost:8400/',
        [string] $FoundryCallbackUri = ''
    )
    $redirect = [uri] $PublicRedirectUri
    if (-not $redirect.IsAbsoluteUri -or $redirect.Scheme -ne 'http' -or
        $redirect.Host -ne 'localhost' -or $redirect.AbsolutePath -ne '/' -or
        $redirect.Query -or $redirect.Fragment -or $redirect.UserInfo) {
        throw 'The public client requires an explicitly approved http://localhost loopback redirect, without a path, query or fragment.'
    }
    if ($FoundryCallbackUri) {
        $callback = [uri] $FoundryCallbackUri
        if (-not $callback.IsAbsoluteUri -or $callback.Scheme -ne 'https' -or
            -not $callback.IsDefaultPort -or $callback.Fragment -or $callback.UserInfo -or
            $FoundryCallbackUri.Contains('*')) {
            throw 'Supply the exact HTTPS callback returned by the owned Foundry OAuth connection; no wildcard or invented callback.'
        }
    }
    return [ordered] @{
        status = 'PreparedOnly'
        environment = $Environment
        gatewayName = "graph-mcp-$Environment-gateway"
        foundryName = "graph-mcp-$Environment-foundry"
        publicName = "graph-mcp-$Environment-local"
        ownershipPrefix = "graph-mcp/$Environment"
        gatewayScope = 'access_as_user'
        delegatedGraphPermissions = @('Mail.Read', 'Calendars.Read')
        publicRedirectUri = $PublicRedirectUri
        foundryRedirectUris = @($(if ($FoundryCallbackUri) { $FoundryCallbackUri }))
        consentGranted = $false
        credentialsCreated = $false
    }
}

function Assert-GraphOperatorContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [guid] $TenantId,
        [Parameter(Mandatory)] [guid] $SubscriptionId,
        [Parameter(Mandatory)] [string] $Location
    )
    if ($TenantId -eq [guid]::Empty -or $SubscriptionId -eq [guid]::Empty -or -not $Location) {
        throw 'Select tenant, subscription, environment and region explicitly before applying changes.'
    }
    $accountJson = & az account show --query '{tenantId:tenantId,id:id,environmentName:environmentName}' --output json 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI context could not be verified; no change was made.' }
    $account = $accountJson | ConvertFrom-Json
    if ($account.environmentName -cne 'AzureCloud' -or $account.tenantId -ine $TenantId.ToString() -or
        $account.id -ine $SubscriptionId.ToString()) {
        throw 'The active public-cloud tenant/subscription does not match the explicitly approved target.'
    }
    $expected = @{
        AZURE_TENANT_ID = $TenantId.ToString()
        AZURE_SUBSCRIPTION_ID = $SubscriptionId.ToString()
        AZURE_LOCATION = $Location
    }
    foreach ($entry in $expected.GetEnumerator()) {
        $value = & azd env get-value $entry.Key --environment $Environment 2>$null
        if ($LASTEXITCODE -ne 0 -or ([string]$value).Trim() -ine $entry.Value) {
            throw "The selected azd environment must explicitly match $($entry.Key); no change was made."
        }
    }
    $locations = Get-Content (Join-Path $PSScriptRoot '..\infra\core\location-codes.json') -Raw | ConvertFrom-Json -AsHashtable
    if (-not $locations.Contains($Location)) { throw 'The selected region is not in the approved location catalog.' }
}

function Get-GraphOperatorToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [guid] $TenantId, [string] $Resource = 'https://graph.microsoft.com')
    $token = & az account get-access-token --tenant $TenantId.ToString() --resource $Resource --query accessToken --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw 'A separately authorized signed-in operator token is required; credentials were not printed.'
    }
    # Reject CLI service-principal/application sessions for these operator helpers.
    $parts = $token.Split('.')
    if ($parts.Length -ne 3) { throw 'The operator access token has an unsupported format.' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight($payload.Length + (4 - $payload.Length % 4) % 4, '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable
    if (-not $claims.Contains('scp') -or -not $claims.scp -or $claims['idtyp'] -eq 'app' -or $claims['tid'] -ine $TenantId.ToString()) {
        throw 'Use an independently approved delegated operator session in the selected tenant, never app-only credentials.'
    }
    return $token.Trim()
}

function Invoke-GraphIdentityRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('GET','POST','PATCH')] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Token,
        [System.Collections.IDictionary] $Body
    )
    $arguments = @{
        Method = $Method
        Uri = "https://graph.microsoft.com/v1.0/$Path"
        Headers = @{Authorization = "Bearer $Token"}
        TimeoutSec = $script:GraphIdentitySettings.RequestTimeoutSeconds
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $arguments.ContentType = 'application/json'
        $arguments.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    try { return Invoke-RestMethod @arguments }
    catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        throw "The identity request failed with HTTP $([int]$_.Exception.Response.StatusCode). Stop and reconcile; no response body or credential was logged."
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        throw 'The identity request timed out. Its outcome is uncertain; reconcile the owned application before retrying.'
    }
    catch [System.Net.Http.HttpRequestException] {
        throw 'Identity transport failed. Its outcome is uncertain; reconcile before retrying. No request/response data was logged.'
    }
}

function Get-OwnedGraphApplication {
    [CmdletBinding()]
    param([string] $Name, [string] $OwnershipTag, [string] $Token)
    $query = [uri]::EscapeDataString("displayName eq '$Name'")
    $response = Invoke-GraphIdentityRequest GET "applications?`$filter=$query" $Token
    $matches = @($response.value)
    if ($matches.Count -gt 1) { throw 'Duplicate application names require an operator ownership review; nothing was adopted.' }
    if ($matches.Count -eq 0) { return $null }
    if ($matches[0].tags -cnotcontains $OwnershipTag -or $matches[0].signInAudience -cne 'AzureADMyOrg') {
        throw 'An existing application does not carry the exact ownership tag/single-tenant contract. Refusing to modify it.'
    }
    return $matches[0]
}

function Assert-GraphCredentialStorageReady {
    [CmdletBinding()]
    param()
    throw 'Credential creation/rotation is blocked before addPassword: this helper has no supported mutation-free proof of Key Vault Set Secret reachability and write authorization. Vault metadata, RBAC, tokens and successful reads are not that proof. A bounded data-plane readiness probe and its network route require separate approval and implementation; no probe or credential was created.'
}

function Save-GraphCredentialVaultCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [guid] $ApplicationObjectId,
        [Parameter(Mandatory)] [psobject] $Credential,
        [Parameter(Mandatory)] [string] $VaultName,
        [Parameter(Mandatory)] [string] $SecretName,
        [Parameter(Mandatory)] [DateTimeOffset] $ExpiresOn,
        [Parameter(Mandatory)] [string] $VaultToken
    )
    $secretUri="https://$VaultName.vault.azure.net/secrets/$SecretName"
    $keyId=$Credential.PSObject.Properties['keyId']
    $expiry=$Credential.PSObject.Properties['endDateTime']
    $secret=$Credential.PSObject.Properties['secretText']
    $recovery=[ordered]@{
        ApplicationObjectId=$ApplicationObjectId.ToString()
        CredentialKeyId=$(if($keyId){[string]$keyId.Value}else{''})
        CredentialDisplayName='graph-mcp-obo'
        CredentialExpiresOn=$(if($expiry){[string]$expiry.Value}else{''})
        RequestedExpiresOn=$ExpiresOn.ToUniversalTime().ToString('o')
        SecretIdentifier=$secretUri
        VaultCopyVerified=$false
        PreviousCredentialsRemoved=$false
        RecoveryAction='Stop; retain this nonsecret metadata only in ignored local evidence. Under separate approval reconcile the named application credential and exact vault secret/version metadata, without reading values. Remove only this new CredentialKeyId via application removePassword if explicitly authorized; never delete a prior credential or blindly retry creation.'
    }
    $failure=''
    $body=$null
    $stored=$null
    try {
        $parsedKeyId=[guid]::Empty
        if (-not $secret -or -not $secret.Value -or -not $keyId -or
            -not [guid]::TryParse([string]$keyId.Value,[ref]$parsedKeyId) -or $parsedKeyId -eq [guid]::Empty) {
            $failure='The application credential response did not contain both a value and a usable key ID; reconcile the application before retrying.'
        } else {
            $body=@{value=$secret.Value;attributes=@{enabled=$true;exp=$ExpiresOn.ToUnixTimeSeconds()}} | ConvertTo-Json -Compress
            try {
                $stored=Invoke-RestMethod -Method Put -Uri "${secretUri}?api-version=$($script:GraphIdentitySettings.VaultSecretsApiVersion)" `
                    -Headers @{Authorization="Bearer $VaultToken"} -ContentType 'application/json' -Body $body `
                    -TimeoutSec $script:GraphIdentitySettings.RequestTimeoutSeconds -ErrorAction Stop
            } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
                $failure="Vault storage failed with HTTP $([int]$_.Exception.Response.StatusCode)."
            } catch [System.Threading.Tasks.TaskCanceledException] {
                $failure='Vault storage timed out; its outcome is uncertain.'
            } catch [System.Net.Http.HttpRequestException] {
                $failure='Vault transport failed; its outcome is uncertain.'
            }
            if (-not $failure) {
                $returnedId=if($null -ne $stored){$stored.PSObject.Properties['id']}else{$null}
                $versionUri=$null
                $prefix="/secrets/$SecretName/"
                if (-not $returnedId -or -not [uri]::TryCreate([string]$returnedId.Value,[UriKind]::Absolute,[ref]$versionUri) -or
                    $versionUri.Scheme -cne 'https' -or $versionUri.Host -ine "$VaultName.vault.azure.net" -or
                    -not $versionUri.IsDefaultPort -or $versionUri.UserInfo -or $versionUri.Query -or $versionUri.Fragment -or
                    -not $versionUri.AbsolutePath.StartsWith($prefix,[StringComparison]::Ordinal) -or
                    -not $versionUri.AbsolutePath.Substring($prefix.Length) -or
                    $versionUri.AbsolutePath.Substring($prefix.Length).Contains('/')) {
                    $failure='Vault storage returned no confirmed version of the intended secret; its outcome is uncertain.'
                }
            }
        }
        if ($failure) {
            $exception=[InvalidOperationException]::new("A new application credential may exist, but its vault copy is unconfirmed. $failure No retry or credential removal was attempted. Exact nonsecret recovery metadata is in Exception.Data['CredentialRecovery'].")
            $exception.Data['CredentialRecovery']=[pscustomobject]$recovery
            $errorRecord=[System.Management.Automation.ErrorRecord]::new(
                $exception,'GraphCredentialVaultCopyUnconfirmed',
                [System.Management.Automation.ErrorCategory]::WriteError,[pscustomobject]$recovery)
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }
        [pscustomobject]@{
            Status='CredentialStored'
            VaultCopyVerified=$true
            CredentialKeyId=$parsedKeyId.ToString()
            SecretVersionIdentifier=$versionUri.AbsoluteUri
            PreviousCredentialsRemoved=$false
            NextAction='Verify Key Vault refresh and OBO before separately approving removal of the prior credential.'
        }
    } finally {
        $body=$null
        $stored=$null
        $secret=$null
        $Credential=$null
        $VaultToken=$null
    }
}

function Set-OwnedGraphApplication {
    [CmdletBinding()]
    param([string] $Name, [string] $OwnershipTag, [hashtable] $Desired, [string] $Token)
    $existing = Get-OwnedGraphApplication $Name $OwnershipTag $Token
    if ($null -eq $existing) {
        $body = @{displayName=$Name;signInAudience='AzureADMyOrg';tags=@($OwnershipTag)} + $Desired
        $existing = Invoke-GraphIdentityRequest POST applications $Token $body
    } else {
        if (@($existing.appRoles).Count -gt 0) { throw 'The owned application has unexpected application roles; review rather than silently overwrite them.' }
        $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($resource in $Desired.requiredResourceAccess) {
            foreach ($permission in $resource.resourceAccess) {
                $null=$allowed.Add("$($resource.resourceAppId)/$($permission.id)/$($permission.type)")
            }
        }
        foreach ($resource in $existing.requiredResourceAccess) {
            foreach ($permission in $resource.resourceAccess) {
                if (-not $allowed.Contains("$($resource.resourceAppId)/$($permission.id)/$($permission.type)")) {
                    throw 'The owned application has unexpected permissions. Review separately rather than overwrite or retain broader access.'
                }
            }
        }
        # Do not touch passwordCredentials, owners, grants, or unrelated manifest fields.
        Invoke-GraphIdentityRequest PATCH "applications/$($existing.id)" $Token $Desired | Out-Null
    }
    $query = [uri]::EscapeDataString("appId eq '$($existing.appId)'")
    $principals = Invoke-GraphIdentityRequest GET "servicePrincipals?`$filter=$query" $Token
    if (@($principals.value).Count -eq 0) {
        Invoke-GraphIdentityRequest POST servicePrincipals $Token @{appId=$existing.appId} | Out-Null
    } elseif (@($principals.value).Count -ne 1) { throw 'An unexpected service-principal count requires manual reconciliation.' }
    return $existing
}
