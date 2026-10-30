. (Join-Path $PSScriptRoot 'assert.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')
. (Get-RepoPath 'scripts/graph-identity.ps1')

Test-Case 'identity preparation is deterministic, single-purpose and never grants consent or generates credentials' {
    $plan=Get-GraphIdentityPlan -Environment synthetic
    Assert-Equal $plan.gatewayName 'graph-mcp-synthetic-gateway' 'Stable owned names enable safe reruns.'
    Assert-Equal ($plan.delegatedGraphPermissions -join ',') 'Mail.Read,Calendars.Read' 'Exactly the approved read-only delegated scopes.'
    Assert-Equal $plan.consentGranted $false 'Consent must remain independently gated.'
    Assert-Equal $plan.credentialsCreated $false 'Reprovision must not reset credentials.'
    Assert-Equal $plan.foundryRedirectUris.Count 0 'Never invent a Foundry callback.'
    Assert-Throws {Get-GraphIdentityPlan -Environment synthetic -PublicRedirectUri 'https://contoso.com'} 'No arbitrary public redirect.'
    Assert-Throws {Get-GraphIdentityPlan -Environment synthetic -PublicRedirectUri 'http://localhost/callback'} 'Only the approved loopback URI shape.'
    Assert-Throws {Get-GraphIdentityPlan -Environment synthetic -FoundryCallbackUri 'https://contoso.com/*'} 'No wildcard callback.'
}

Test-Case 'all configuration entrypoints prepare offline without calling Azure or Graph' {
    function az { throw 'Unexpected Azure execution during offline preparation.' }
    function azd { throw 'Unexpected azd execution during offline preparation.' }
    function Invoke-RestMethod { throw 'Unexpected HTTP execution during offline preparation.' }
    $identity=& (Get-RepoPath 'scripts/configure-graph-identity.ps1') -Environment synthetic
    Assert-Equal $identity.status 'PreparedOnly' 'Identity preparation must be the default.'
    $credential=& (Get-RepoPath 'scripts/set-graph-credential.ps1') -Environment synthetic
    Assert-Equal $credential.SecretCreated $false 'Offline preparation must not create credentials.'
    Assert-Equal $credential.CredentialWriteSupported $true 'Preparation reports the ARM storage route; Apply still needs approval.'
    $oauth=& (Get-RepoPath 'scripts/configure-foundry-oauth.ps1') `
        -TenantId '00000000-0000-0000-0000-000000000001' `
        -GatewayClientId '00000000-0000-0000-0000-000000000002' `
        -FoundryClientId '00000000-0000-0000-0000-000000000003' `
        -McpServerUrl 'https://contoso.azure-api.net/actual-returned-path'
    Assert-Equal $oauth.RequireApproval 'always' 'Consent is not tool approval.'
    Assert-Equal $oauth.AllowedTools.Count 4 'Exactly four allowlisted tools.'
    Assert-Match $oauth.Scopes '^api://[^ ]+/access_as_user offline_access$' 'Space-separated owned-audience OAuth scopes.'
}

Test-Case 'apply paths refuse to run without separately recorded identity/credential approval' {
    Assert-Throws {& (Get-RepoPath 'scripts/configure-graph-identity.ps1') -Environment synthetic -Apply} 'Plan approval is not tenant-change authority.'
    Assert-Throws {& (Get-RepoPath 'scripts/set-graph-credential.ps1') -Environment synthetic -Apply} 'Credential operations need separate authority.'
}

Test-Case 'owned applications cannot be adopted by name alone' {
    function Invoke-GraphIdentityRequest {
        [pscustomobject]@{value=@([pscustomobject]@{tags=@('unrelated');signInAudience='AzureADMyOrg'})}
    }
    Assert-Throws {Get-OwnedGraphApplication -Name synthetic -OwnershipTag 'graph-mcp/synthetic/gateway' -Token synthetic} 'Reject unowned same-name applications.'
}

Test-Case 'identity apply converges on owned apps without credentials, consent or callback reset (mocked transport)' {
    $global:GraphIdentityTestState=@{Apps=@{};Principals=@{};Calls=[Collections.Generic.List[string]]::new()}
    $tenant='00000000-0000-0000-0000-000000000001'
    $subscription='00000000-0000-0000-0000-000000000002'
    $payload=@{tid=$tenant;scp='Application.ReadWrite.All';idtyp='user'} | ConvertTo-Json -Compress
    $global:GraphIdentityTestState.Token='synthetic.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+','-').Replace('/','_') + '.synthetic'
    function az {
        if ($args[0] -eq 'account' -and $args[1] -eq 'show') {
            $global:LASTEXITCODE=0
            return @{tenantId=$tenant;id=$subscription;environmentName='AzureCloud'} | ConvertTo-Json -Compress
        }
        if ($args[0] -eq 'account' -and $args[1] -eq 'get-access-token') {
            $global:LASTEXITCODE=0; return $global:GraphIdentityTestState.Token
        }
        throw 'Unexpected Azure command in synthetic apply test.'
    }
    function azd {
        $global:LASTEXITCODE=0
        if ($args[0] -eq 'env' -and $args[1] -eq 'set') { return }
        if ($args[0] -eq 'env' -and $args[1] -eq 'get-value') {
            switch ($args[2]) { AZURE_TENANT_ID {return $tenant}; AZURE_SUBSCRIPTION_ID {return $subscription}; AZURE_LOCATION {return 'eastus'} }
        }
        throw 'Unexpected azd command in synthetic apply test.'
    }
    function Invoke-RestMethod {
        param($Method,$Uri,$Headers,$ContentType,$Body,$TimeoutSec)
        $url=[uri]$Uri
        if ($url.Host -cne 'graph.microsoft.com') { throw 'Unexpected host in synthetic apply test.' }
        $path=$url.AbsolutePath.Substring('/v1.0/'.Length)
        $null=$global:GraphIdentityTestState.Calls.Add("$Method $path")
        $json=if($Body){$Body | ConvertFrom-Json -AsHashtable}else{@{}}
        if ($Method -eq 'GET' -and $path -eq 'applications') {
            $query=[uri]::UnescapeDataString($url.Query)
            if ($query -notmatch "displayName eq '([^']+)'") { throw 'Unexpected app lookup.' }
            return [pscustomobject]@{value=@($global:GraphIdentityTestState.Apps.Values | Where-Object displayName -ceq $Matches[1])}
        }
        if ($Method -eq 'POST' -and $path -eq 'applications') {
            $number=$global:GraphIdentityTestState.Apps.Count + 10
            $json.id="00000000-0000-0000-0000-$($number.ToString('000000000000'))"
            $json.appId="00000000-0000-0000-0001-$($number.ToString('000000000000'))"
            $json.passwordCredentials=@();$json.appRoles=@();$json.identifierUris=@()
            $app=[pscustomobject]$json
            $global:GraphIdentityTestState.Apps[$app.id]=$app
            return $app
        }
        if ($Method -eq 'PATCH' -and $path -like 'applications/*') {
            $app=$global:GraphIdentityTestState.Apps[$path.Split('/')[1]]
            foreach($key in $json.Keys){$app | Add-Member -NotePropertyName $key -NotePropertyValue $json[$key] -Force}
            return
        }
        if ($Method -eq 'GET' -and $path -eq 'servicePrincipals') {
            $query=[uri]::UnescapeDataString($url.Query)
            if($query -match '00000003-0000-0000-c000-000000000000') {
                return [pscustomobject]@{value=@([pscustomobject]@{oauth2PermissionScopes=@(
                    [pscustomobject]@{id='00000000-0000-0000-0002-000000000001';value='Mail.Read';isEnabled=$true},
                    [pscustomobject]@{id='00000000-0000-0000-0002-000000000002';value='Calendars.Read';isEnabled=$true}
                )})}
            }
            if($query -notmatch "appId eq '([^']+)'"){throw 'Unexpected principal lookup.'}
            return [pscustomobject]@{value=@($global:GraphIdentityTestState.Principals.Values | Where-Object appId -ceq $Matches[1])}
        }
        if ($Method -eq 'POST' -and $path -eq 'servicePrincipals') {
            $global:GraphIdentityTestState.Principals[$json.appId]=[pscustomobject]$json
            return
        }
        throw 'Unexpected changing API in synthetic apply test.'
    }
    $arguments=@{Environment='synthetic';TenantId=$tenant;SubscriptionId=$subscription;Location='eastus';Apply=$true;IdentityChangeApproved=$true;Confirm=$false}
    try {
    $first=& (Get-RepoPath 'scripts/configure-graph-identity.ps1') @arguments
    Assert-Equal $first.CredentialsCreated $false 'Never create credentials as part of app manifests.'
    $ids=@($global:GraphIdentityTestState.Apps.Keys | Sort-Object) -join ','
    $callback='https://contoso.com/actual-returned-callback'
    $null=& (Get-RepoPath 'scripts/configure-graph-identity.ps1') @arguments -FoundryCallbackUri $callback
    $null=& (Get-RepoPath 'scripts/configure-graph-identity.ps1') @arguments
    Assert-Equal (@($global:GraphIdentityTestState.Apps.Keys | Sort-Object) -join ',') $ids 'Reruns must not create new registrations.'
    Assert-Equal $global:GraphIdentityTestState.Apps.Count 3 'Exactly three owned registrations.'
    Assert-Equal $global:GraphIdentityTestState.Principals.Count 3 'Exactly three corresponding principals.'
    $web=@($global:GraphIdentityTestState.Apps.Values | Where-Object displayName -like '*-foundry')[0]
    Assert-Equal ($web.web.redirectUris -join ',') $callback 'A rerun without callback input must preserve the approved callback.'
    $gateway=@($global:GraphIdentityTestState.Apps.Values | Where-Object displayName -like '*-gateway')[0]
    Assert-Equal $gateway.api.requestedAccessTokenVersion 2 'Gateway must issue v2 tokens.'
    Assert-Equal @($gateway.requiredResourceAccess[0].resourceAccess).Count 2 'Only two Graph delegated permissions.'
    Assert-NotMatch ($global:GraphIdentityTestState.Calls -join ',') 'addPassword|oauth2PermissionGrants|appRoleAssignments' 'No credential/consent/app permission API may be called.'
    $gateway.requiredResourceAccess[0].resourceAccess += @{id='00000000-0000-0000-0002-000000000003';type='Role'}
    Assert-Throws {& (Get-RepoPath 'scripts/configure-graph-identity.ps1') @arguments} 'Unexpected application permission must stop apply rather than be overwritten.'
    } finally { Remove-Variable -Name GraphIdentityTestState -Scope Global }
}

Test-Case 'credential apply never resets an existing owned credential without explicit rotation (mocked transport)' {
    $tenant='00000000-0000-0000-0000-000000000001'
    $subscription='00000000-0000-0000-0000-000000000002'
    $claims=@{tid=$tenant;scp='Application.ReadWrite.All';idtyp='user'} | ConvertTo-Json -Compress
    $credentialToken='synthetic.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_') + '.synthetic'
    function az {
        $global:LASTEXITCODE=0
        if($args[0] -eq 'account' -and $args[1] -eq 'show'){
            return @{tenantId=$tenant;id=$subscription;environmentName='AzureCloud'} | ConvertTo-Json -Compress
        }
        if($args[0] -eq 'account' -and $args[1] -eq 'get-access-token'){return $credentialToken}
        if($args[0] -eq 'keyvault' -and $args[1] -eq 'show'){
            return @{
                id="/subscriptions/$subscription/resourceGroups/synthetic/providers/Microsoft.KeyVault/vaults/contoso-synthetic"
                location='eastus';tags=@{environment='synthetic'};rbac=$true;purge=$true;firewall='Deny'
            } | ConvertTo-Json -Compress
        }
        throw 'Unexpected Azure command during credential simulation.'
    }
    function azd {
        $global:LASTEXITCODE=0
        if($args[0] -eq 'env' -and $args[1] -eq 'get-value'){
            switch($args[2]){AZURE_TENANT_ID{return $tenant};AZURE_SUBSCRIPTION_ID{return $subscription};AZURE_LOCATION{return 'eastus'}}
        }
        throw 'Unexpected azd command during credential simulation.'
    }
    function Invoke-RestMethod {
        param($Method,$Uri,$Headers,$ContentType,$Body,$TimeoutSec)
        if($Method -ne 'GET' -or ([uri]$Uri).AbsolutePath -cne '/v1.0/applications'){
            throw 'Unexpected credential creation, secret read/write or consent request.'
        }
        return [pscustomobject]@{value=@([pscustomobject]@{
            tags=@('graph-mcp/synthetic/gateway');signInAudience='AzureADMyOrg'
            passwordCredentials=@([pscustomobject]@{displayName='graph-mcp-obo'})
        })}
    }
    $result=& (Get-RepoPath 'scripts/set-graph-credential.ps1') -Environment synthetic -TenantId $tenant `
        -SubscriptionId $subscription -Location eastus -ResourceGroupName synthetic -VaultName contoso-synthetic `
        -ExpiresOn ([DateTimeOffset]::UtcNow.AddDays(30)) -Apply -CredentialChangeApproved -Confirm:$false
    Assert-Equal $result.Status 'ExistingCredentialNotRotated' 'An ordinary repeat must never generate another secret.'
    Assert-Equal $result.VaultCopyVerified $false 'Do not pretend an untouched vault copy was verified.'
}

Test-Case 'credential creation and rotation fail before addPassword when the ARM write probe fails' {
    $tenant='00000000-0000-0000-0000-000000000001'
    $subscription='00000000-0000-0000-0000-000000000002'
    $claims=@{tid=$tenant;scp='Application.ReadWrite.All';idtyp='user'} | ConvertTo-Json -Compress
    $operatorToken='synthetic.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_') + '.synthetic'
    $global:GraphCredentialReadinessTestState=@{HasCredential=$false;GraphReads=0;Probes=0;Mutations=0;VaultTokens=0}
    function az {
        $global:LASTEXITCODE=0
        if($args[0] -eq 'account' -and $args[1] -eq 'show'){
            return @{tenantId=$tenant;id=$subscription;environmentName='AzureCloud'} | ConvertTo-Json -Compress
        }
        if($args[0] -eq 'account' -and $args[1] -eq 'get-access-token'){
            if($args -contains 'https://vault.azure.net'){$global:GraphCredentialReadinessTestState.VaultTokens++}
            return $operatorToken
        }
        if($args[0] -eq 'keyvault' -and $args[1] -eq 'show'){
            Assert-True ($args -contains '--subscription') 'Vault metadata must be explicitly scoped.'
            return @{
                id="/subscriptions/$subscription/resourceGroups/synthetic/providers/Microsoft.KeyVault/vaults/contoso-synthetic"
                location='eastus';tags=@{environment='synthetic'};rbac=$true;purge=$true;firewall='Deny'
            } | ConvertTo-Json -Compress
        }
        throw 'Unexpected command in readiness simulation.'
    }
    function azd {
        $global:LASTEXITCODE=0
        if($args[0] -eq 'env' -and $args[1] -eq 'get-value'){
            switch($args[2]){AZURE_TENANT_ID{return $tenant};AZURE_SUBSCRIPTION_ID{return $subscription};AZURE_LOCATION{return 'eastus'}}
        }
        throw 'Unexpected azd command in readiness simulation.'
    }
    function Invoke-RestMethod {
        param($Method,$Uri,$Headers,$ContentType,$Body,$TimeoutSec)
        if($Method -eq 'Put' -and $Uri -ceq "https://management.azure.com/subscriptions/$subscription/resourceGroups/synthetic/providers/Microsoft.KeyVault/vaults/contoso-synthetic/secrets/graph-obo-write-probe?api-version=2023-07-01"){
            $global:GraphCredentialReadinessTestState.Probes++
            throw [System.Net.Http.HttpRequestException]::new('synthetic route failure')
        }
        if($Method -ne 'GET' -or ([uri]$Uri).AbsolutePath -cne '/v1.0/applications'){
            $global:GraphCredentialReadinessTestState.Mutations++
            throw 'Unexpected password/secret mutation before readiness.'
        }
        $global:GraphCredentialReadinessTestState.GraphReads++
        return [pscustomobject]@{value=@([pscustomobject]@{
            id='00000000-0000-0000-0000-000000000010'
            tags=@('graph-mcp/synthetic/gateway');signInAudience='AzureADMyOrg'
            passwordCredentials=@($(if($global:GraphCredentialReadinessTestState.HasCredential){
                [pscustomobject]@{displayName='graph-mcp-obo'}
            }))
        })}
    }
    try {
        foreach($rotate in @($false,$true)){
            $global:GraphCredentialReadinessTestState.HasCredential=$rotate
            $failure=$null
            try {
                & (Get-RepoPath 'scripts/set-graph-credential.ps1') -Environment synthetic -TenantId $tenant `
                    -SubscriptionId $subscription -Location eastus -ResourceGroupName synthetic -VaultName contoso-synthetic `
                    -ExpiresOn ([DateTimeOffset]::UtcNow.AddDays(30)) -Apply -CredentialChangeApproved -Rotate:$rotate -Confirm:$false
            } catch {$failure=$_}
            Assert-True ($null -ne $failure) 'Both first creation and explicit rotation must fail closed.'
            Assert-Match $failure.Exception.Message 'blocked before addPassword' 'Do not mistake metadata/token success for write readiness.'
            Assert-Match $failure.Exception.Message 'write probe through ARM failed' 'A failed route must stop before any credential exists.'
        }
        Assert-Equal $global:GraphCredentialReadinessTestState.GraphReads 2 'Owned-app metadata reads are bounded.'
        Assert-Equal $global:GraphCredentialReadinessTestState.Probes 2 'One nonsecret probe per attempt, before addPassword.'
        Assert-Equal $global:GraphCredentialReadinessTestState.Mutations 0 'Never create a credential when the probe fails.'
        Assert-Equal $global:GraphCredentialReadinessTestState.VaultTokens 0 'Stop even before acquiring a vault token.'
    } finally {Remove-Variable -Name GraphCredentialReadinessTestState -Scope Global}
}

Test-Case 'post-create vault failures expose exact nonsecret recovery metadata without retry or credential removal' {
    $global:GraphCredentialVaultTestState=@{Mode='';Writes=0}
    $credentialValue='synthetic-sensitive-value'
    $vaultToken='synthetic-sensitive-token'
    function Invoke-RestMethod {
        param($Method,$Uri,$Headers,$ContentType,$Body,$TimeoutSec)
        if($Method -ne 'Put' -or $Uri -cne 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/synthetic/providers/Microsoft.KeyVault/vaults/contoso-synthetic/secrets/graph-obo-client-secret?api-version=2023-07-01'){
            throw 'Unexpected probe, credential removal or retry.'
        }
        $global:GraphCredentialVaultTestState.Writes++
        $payload=$Body | ConvertFrom-Json
        if($payload.properties.value -cne $credentialValue -or $Headers.Authorization -cne "Bearer $vaultToken"){
            throw 'Unexpected synthetic storage payload.'
        }
        switch($global:GraphCredentialVaultTestState.Mode){
            'Http403' {
                $response=[System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new($credentialValue,$response)
            }
            'Http503' {
                $response=[System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::ServiceUnavailable)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new($credentialValue,$response)
            }
            'Timeout' {throw [System.Threading.Tasks.TaskCanceledException]::new($credentialValue)}
            'Transport' {throw [System.Net.Http.HttpRequestException]::new($credentialValue)}
            'MissingVersion' {return [pscustomobject]@{properties=[pscustomobject]@{attributes=@{enabled=$true}}}}
            'WrongSecret' {return [pscustomobject]@{properties=[pscustomobject]@{secretUriWithVersion='https://contoso-synthetic.vault.azure.net/secrets/unrelated/version'}}}
            default {throw 'Unexpected test mode.'}
        }
    }
    try {
        foreach($mode in @('Http403','Http503','Timeout','Transport','MissingVersion','WrongSecret','MissingValue','MissingKeyId')){
            $global:GraphCredentialVaultTestState.Mode=$mode
            $global:GraphCredentialVaultTestState.Writes=0
            $credential=[pscustomobject]@{
                keyId='00000000-0000-0000-0000-000000000011'
                endDateTime='2030-01-01T00:00:00Z';secretText=$credentialValue
            }
            if($mode -ceq 'MissingValue'){$credential.secretText=$null}
            if($mode -ceq 'MissingKeyId'){$credential.keyId=$null}
            $arguments=@{
                ApplicationObjectId='00000000-0000-0000-0000-000000000010';Credential=$credential
                SubscriptionId='00000000-0000-0000-0000-000000000002';ResourceGroupName='synthetic'
                VaultName='contoso-synthetic';SecretName='graph-obo-client-secret'
                ExpiresOn=[DateTimeOffset]'2030-01-01T00:00:00Z';ArmToken=$vaultToken
            }
            $failure=$null;$output=@()
            try {$output=@(Save-GraphCredentialVaultCopy @arguments)}catch{$failure=$_}
            Assert-True ($null -ne $failure) "Storage failure must be explicit for $mode."
            Assert-Equal $output.Count 0 'No success-shaped return or secret output after failure.'
            $metadata=$failure.Exception.Data['CredentialRecovery']
            Assert-Equal $metadata.ApplicationObjectId $arguments.ApplicationObjectId 'Recovery identifies the actual application object.'
            Assert-Equal $metadata.CredentialKeyId ([string]$credential.keyId) 'Report the exact new key ID, or explicitly unknown if absent.'
            Assert-Equal $metadata.CredentialDisplayName 'graph-mcp-obo' 'Identify only the new owned credential.'
            Assert-Equal $metadata.CredentialExpiresOn $credential.endDateTime 'Preserve the returned expiry.'
            Assert-Equal $metadata.SecretIdentifier 'https://contoso-synthetic.vault.azure.net/secrets/graph-obo-client-secret' 'Bound reconciliation to the intended secret.'
            Assert-Equal $metadata.VaultCopyVerified $false 'Never infer successful vault storage after failure.'
            Assert-Equal $metadata.PreviousCredentialsRemoved $false 'Never retire working credentials automatically.'
            Assert-Match $metadata.RecoveryAction 'explicitly authorized' 'Cleanup requires new user authority.'
            Assert-Match $failure.Exception.Message 'No retry or credential removal' 'Fail loudly without automatic retries.'
            $safeEvidence=($failure | Out-String) + ($metadata | ConvertTo-Json -Compress)
            Assert-NotMatch $safeEvidence 'synthetic-sensitive-value|synthetic-sensitive-token|secretText|Authorization' 'Errors and recovery metadata must exclude sensitive transport data.'
            $expectedWrites=if($mode -cin @('MissingValue','MissingKeyId')){0}else{1}
            Assert-Equal $global:GraphCredentialVaultTestState.Writes $expectedWrites 'At most one exact secret write, never a probe or retry.'
        }
    } finally {Remove-Variable -Name GraphCredentialVaultTestState -Scope Global}
}

Test-Case 'credential storage confirms the intended version without returning the value (mocked transport only)' {
    function Invoke-RestMethod {
        param($Method,$Uri,$Headers,$ContentType,$Body,$TimeoutSec)
        [pscustomobject]@{properties=[pscustomobject]@{secretUriWithVersion='https://contoso-synthetic.vault.azure.net/secrets/graph-obo-client-secret/version'}}
    }
    $arguments=@{
        ApplicationObjectId='00000000-0000-0000-0000-000000000010'
        Credential=[pscustomobject]@{keyId='00000000-0000-0000-0000-000000000011';endDateTime='2030-01-01T00:00:00Z';secretText='synthetic-sensitive-value'}
        SubscriptionId='00000000-0000-0000-0000-000000000002';ResourceGroupName='synthetic'
        VaultName='contoso-synthetic';SecretName='graph-obo-client-secret'
        ExpiresOn=[DateTimeOffset]'2030-01-01T00:00:00Z';ArmToken='synthetic-sensitive-token'
    }
    $result=Save-GraphCredentialVaultCopy @arguments
    Assert-Equal $result.Status 'CredentialStored' 'Only a confirmed intended version can report success.'
    Assert-Equal $result.VaultCopyVerified $true 'A Set Secret response confirms that particular write only.'
    Assert-Equal $result.PreviousCredentialsRemoved $false 'Successful storage is not credential retirement approval.'
    Assert-NotMatch ($result | ConvertTo-Json -Compress) 'synthetic-sensitive-value|synthetic-sensitive-token|secretText' 'Return nonsecret metadata only.'
}

Test-Case 'Foundry agent plan targets the gateway audience through OAuth and exposes only the four read-only tools (offline)' {
    $arguments=@{
        Environment='synthetic';TenantId='00000000-0000-0000-0000-000000000001'
        GatewayClientId='00000000-0000-0000-0000-000000000002';FoundryClientId='00000000-0000-0000-0000-000000000003'
        McpServerUrl='https://contoso.azure-api.net/graph-mcp/mcp';ModelDeploymentName='synthetic-model'
    }
    $plan=& (Get-RepoPath 'scripts/configure-foundry-agent.ps1') @arguments
    Assert-Equal $plan.Status 'PreparedOnly' 'Without -Apply nothing is created.'
    Assert-Equal $plan.Connection.authType 'OAuth2' 'Each user signs in: OAuth identity passthrough.'
    Assert-Equal ($plan.Connection.scopes -join ' ') 'api://00000000-0000-0000-0000-000000000002/access_as_user offline_access' 'Tokens target the owned gateway audience, refreshable.'
    Assert-Equal $plan.Connection.authorizationUrl 'https://login.microsoftonline.com/00000000-0000-0000-0000-000000000001/oauth2/v2.0/authorize' 'Tenant-specific authority only.'
    $tool=$plan.Agent.definition.tools[0]
    Assert-Equal $tool.type 'mcp' 'The agent uses the APIM MCP server as its tool.'
    Assert-Equal $tool.project_connection_id 'graph-mcp-oauth' 'The tool authenticates through the OAuth connection.'
    Assert-Equal ($tool.allowed_tools -join ',') 'list_messages,get_message,list_calendar_view,get_event' 'Only the four read-only tools.'
    Assert-Equal $tool.require_approval 'always' 'Every MCP call stays an explicit approval.'
    Assert-Equal $plan.Agent.definition.model 'synthetic-model' 'The selected model deployment.'
    Assert-NotMatch ($plan | ConvertTo-Json -Depth 10 -Compress) 'clientSecret|secretText|password' 'The plan carries no credential.'
    $plainHttp=$arguments.Clone(); $plainHttp.McpServerUrl='http://contoso.azure-api.net/graph-mcp/mcp'
    Assert-Throws {& (Get-RepoPath 'scripts/configure-foundry-agent.ps1') @plainHttp} 'Plain HTTP MCP URLs are rejected.'
    $sameApp=$arguments.Clone(); $sameApp.FoundryClientId=$arguments.GatewayClientId
    Assert-Throws {& (Get-RepoPath 'scripts/configure-foundry-agent.ps1') @sameApp} 'The gateway and Foundry apps must differ.'
}
