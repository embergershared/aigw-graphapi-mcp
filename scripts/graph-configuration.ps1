Set-StrictMode -Version Latest

function Get-GraphEnvironmentSettings {
    [CmdletBinding()]
    param()

    $names = [ordered] @{
        publisherName = @('APIM_PUBLISHER_NAME', '')
        publisherEmail = @('APIM_PUBLISHER_EMAIL', '')
        gatewayClientId = @('GRAPH_GATEWAY_CLIENT_ID', '')
        allowedClientIds = @('GRAPH_ALLOWED_CLIENT_IDS', '')
        credentialSecretName = @('GRAPH_CREDENTIAL_SECRET_NAME', 'graph-obo-client-secret')
        deploymentsJson = @('FOUNDRY_DEPLOYMENTS_JSON', '[]')
        purgeProtection = @('AZURE_KEY_VAULT_PURGE_PROTECTION', 'true')
    }
    $settings = @{}
    foreach ($entry in $names.GetEnumerator()) {
        $value = & azd env get-value $entry.Value[0] 2>$null
        $settings[$entry.Key] = if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($value)) {
            $value.Trim()
        } else { $entry.Value[1] }
    }
    return $settings
}

function Assert-GraphDeploymentSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Profile,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Features,
        [Parameter(Mandatory)] [bool] $DeployNetwork,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Settings
    )

    if (-not ($Features.apiManagement -or $Features.aiFoundry -or $Features.graphMcp)) { return }
    if ($Profile -ne 'core' -or $DeployNetwork) {
        throw 'Public Graph/Foundry opt-ins require core without a network. Private integration is not implemented or approved.'
    }
    if ($Features.apiManagement) {
        if ([string]::IsNullOrWhiteSpace($Settings.publisherName) -or
            $Settings.publisherEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            throw 'Select APIM_PUBLISHER_NAME and APIM_PUBLISHER_EMAIL for the approved target before provisioning Developer.'
        }
    }
    if ($Features.graphMcp) {
        if (-not ($Features.apiManagement -and $Features.keyVault -and $Features.roleAssignments)) {
            throw 'graphMcp requires explicit apiManagement, keyVault and roleAssignments opt-ins. Provision infrastructure and approved identities/secret first.'
        }
        if ($Settings.purgeProtection -cne 'true') { throw 'Graph credentials require Key Vault purge protection.' }
        foreach ($id in @($Settings.gatewayClientId) + @(([string]$Settings.allowedClientIds).Split(','))) {
            $guid = [guid]::Empty
            if (-not [guid]::TryParseExact($id.Trim(), 'D', [ref]$guid) -or $guid -eq [guid]::Empty) {
                throw 'GRAPH_GATEWAY_CLIENT_ID and every GRAPH_ALLOWED_CLIENT_IDS entry must be non-empty GUIDs.'
            }
        }
        $clients = @(([string]$Settings.allowedClientIds).Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() })
        if ($clients.Count -ne 2 -or @($clients | Sort-Object -Unique).Count -ne 2 -or $clients -contains $Settings.gatewayClientId.ToLowerInvariant()) {
            throw 'Allow exactly two distinct caller IDs: the Foundry OAuth web client and local public PKCE client, neither the gateway app itself.'
        }
        if ($Settings.credentialSecretName -cnotmatch '^[A-Za-z0-9-]{1,127}$') {
            throw 'GRAPH_CREDENTIAL_SECRET_NAME must be a Key Vault secret name, never a URL or secret value.'
        }
    }
    try { $deployments = ConvertFrom-Json -InputObject $Settings.deploymentsJson -AsHashtable -NoEnumerate }
    catch [System.ArgumentException] { throw 'FOUNDRY_DEPLOYMENTS_JSON must be a JSON array.' }
    if ($deployments -isnot [array]) { throw 'FOUNDRY_DEPLOYMENTS_JSON must be a JSON array.' }
    if ($deployments.Count -gt 0 -and -not $Features.aiFoundry) { throw 'Model deployments require the aiFoundry opt-in.' }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($deployment in $deployments) {
        if ($deployment -isnot [System.Collections.IDictionary] -or
            @($deployment.Keys | Where-Object { $_ -notin @('name', 'model', 'version', 'sku', 'capacity') }).Count) {
            throw 'Each model deployment permits only name, model, version, sku and capacity.'
        }
        foreach ($key in @('name', 'model', 'version', 'sku')) {
            if (-not $deployment.Contains($key) -or $deployment[$key] -isnot [string] -or
                [string]::IsNullOrWhiteSpace($deployment[$key]) -or $deployment[$key] -ieq 'latest') {
                throw "Each deployment needs an explicit, non-latest '$key'; model lifecycle, SKU and quota remain target-specific gates."
            }
        }
        if (-not $deployment.Contains('capacity') -or
            ($deployment.capacity -isnot [long] -and $deployment.capacity -isnot [int]) -or $deployment.capacity -lt 1) {
            throw 'Each model deployment needs an explicit positive integer capacity.'
        }
        if (-not $seen.Add($deployment.name)) { throw 'Model deployment names must be distinct.' }
    }
}
