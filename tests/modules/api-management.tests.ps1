. (Join-Path $PSScriptRoot '..' 'assert.ps1')
. (Join-Path $PSScriptRoot '..' 'common.ps1')
. (Get-RepoPath 'scripts/graph-configuration.ps1')
. (Get-RepoPath 'tests/arm-expression.ps1')

$moduleRoot = Get-RepoPath 'infra/modules/api-management'
$contract = Get-Content (Join-Path $moduleRoot 'contract.json') -Raw | ConvertFrom-Json
$openapi = Get-Content (Join-Path $moduleRoot 'openapi.json') -Raw | ConvertFrom-Json

Test-Case 'Graph OpenAPI exposes exactly four read-only operations and agreed bounds' {
    $operations = @()
    foreach ($path in $openapi.paths.PSObject.Properties) {
        Assert-Equal ($path.Value.PSObject.Properties.Name -join ',') 'get' 'Every facade operation must be GET only.'
        $operations += $path.Value.get.operationId
    }
    Assert-Equal (($operations | Sort-Object) -join ',') (($contract.tools.name | Sort-Object) -join ',') 'OpenAPI and native tool contracts must agree.'
    Assert-Equal $operations.Count 4 'Exactly four operations are approved.'
    Assert-Equal $openapi.components.parameters.PageSize.schema.default $contract.defaultPageSize 'Default page size drift.'
    Assert-Equal $openapi.components.parameters.PageSize.schema.maximum $contract.maximumPageSize 'Maximum page size drift.'
    Assert-Equal $contract.detailMaxBytes 65536 'Details must have a documented measurable byte boundary.'
    Assert-Equal $contract.maximumCalendarDays 31 'Calendar windows must remain capped.'
    Assert-NotMatch $contract.tools[0].fields -Pattern '(^|,)body(,|$)' -Message 'Message lists must not select bodies.'
}

Test-Case 'Graph opt-ins default off on every profile and add no network' {
    $template = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra/main.bicep')
    foreach ($profile in @('core', 'private', 'full')) {
        $flags = Get-ProfileFeatureFlags -Template $template -ProfileName $profile
        foreach ($flag in @('deployApiManagement', 'deployAiFoundry', 'configureGraphMcp')) {
            Assert-Equal $flags[$flag] $false "$flag must remain off for $profile."
        }
    }
    $enabled = Get-ProfileFeatureFlags -Template $template -ProfileName core -Overrides @{apiManagement=$true;aiFoundry=$true;keyVault=$true}
    Assert-Equal $enabled.deployApiManagement $true 'APIM opt-in missing.'
    Assert-Equal $enabled.deployAiFoundry $true 'Foundry opt-in missing.'
    Assert-Equal $enabled.deployNetwork $false 'The public PoC must not pull in a network.'
    Assert-Equal $enabled.configureGraphMcp $false 'Infrastructure bootstrap must not expose Graph APIs.'
}

Test-Case 'public Graph preflight fails closed on mixed profiles, missing identity and implicit models' {
    $features = @{apiManagement=$true;aiFoundry=$true;graphMcp=$false;keyVault=$true;roleAssignments=$true}
    $settings = @{publisherName='Contoso';publisherEmail='operator@contoso.com';deploymentsJson='[]';purgeProtection='true';gatewayClientId='';allowedClientIds='';credentialSecretName='graph-obo-client-secret'}
    Assert-GraphDeploymentSettings -Profile core -Features $features -DeployNetwork $false -Settings $settings
    Assert-Throws { Assert-GraphDeploymentSettings -Profile private -Features $features -DeployNetwork $true -Settings $settings } 'Do not silently enable public Graph resources in private profiles.'
    $features.graphMcp=$true
    Assert-Throws { Assert-GraphDeploymentSettings -Profile core -Features $features -DeployNetwork $false -Settings $settings } 'Gateway identity must be configured before Graph exposure.'
    $features.graphMcp=$false
    $settings.deploymentsJson='[{"name":"synthetic","model":"synthetic","version":"latest","sku":"Standard","capacity":1}]'
    Assert-Throws { Assert-GraphDeploymentSettings -Profile core -Features $features -DeployNetwork $false -Settings $settings } 'A model version cannot silently float.'
}

Test-Case 'MCP and REST enforce the same delegated authentication without buffering native responses' {
    [xml]$mcp = Get-Content (Join-Path $moduleRoot 'policies/mcp.xml') -Raw
    [xml]$rest = Get-Content (Join-Path $moduleRoot 'policies/rest.xml') -Raw
    foreach ($policy in @($mcp, $rest)) {
        Assert-True ($null -ne $policy.SelectSingleNode('//inbound/include-fragment[@fragment-id="graph-authenticate"]')) 'Both surfaces require the shared authentication fragment.'
    }
    Assert-NotMatch $mcp.OuterXml -Pattern 'Response\.Body' -Message 'Native streaming must not be buffered by a policy.'
    $auth = Get-Content (Join-Path $moduleRoot 'policies/authenticate.xml') -Raw
    foreach ($claim in @('tid','ver','scp','azp')) {
        Assert-Match $auth "claim name=`"$claim`"" "Missing authentication claim $claim."
    }
    Assert-Match $auth 'access_as_user' 'Delegated scope is mandatory.'
    $obo = Get-Content (Join-Path $moduleRoot 'policies/obo.xml') -Raw
    Assert-Match $obo 'on_behalf_of' 'Graph must receive an OBO token, not the gateway assertion.'
    Assert-Match $obo 'Uri\.EscapeDataString\("\{\{graph-obo-secret\}\}"\)' 'Form-encode the confidential credential.'
    Assert-Match $obo 'obo_timeout' 'Timeouts must fail explicitly.'
    foreach ($file in Get-ChildItem (Join-Path $moduleRoot 'policies') -Filter *.xml) {
        Assert-NotMatch (Get-Content $file.FullName -Raw) 'cache-(lookup|store)|<trace|log-to-eventhub' 'No token/payload caching or tracing.'
    }
}

Test-Case 'native MCP binds full operation IDs and has zero payload/header diagnostics' {
    $compiled = Get-CompiledTemplate -BicepPath (Join-Path $moduleRoot 'main.bicep')
    $text = Get-Content (Join-Path $moduleRoot 'main.bicep') -Raw
    Assert-Match $text "service/apis/tools@2025-09-01-preview" 'Native child tools must use the accepted management API.'
    Assert-Match $text 'operationId:.*restApi\.id.*/operations/' 'Tools must bind full ARM IDs.'
    $diagnostic = @($compiled.resources | Where-Object type -eq 'Microsoft.ApiManagement/service/diagnostics')[0]
    foreach ($side in @('frontend','backend')) {
        foreach ($direction in @('request','response')) {
            Assert-Equal $diagnostic.properties.$side.$direction.body.bytes 0 'No body bytes may be logged.'
            Assert-Equal @($diagnostic.properties.$side.$direction.headers).Count 0 'No sensitive headers may be logged.'
        }
    }
    Assert-Equal $diagnostic.properties.logClientIp $false 'Do not log caller IP addresses.'
}

Test-Case 'ARM GUID dependencies are deterministic version-five names' {
    $template = [pscustomobject]@{}
    $first = Invoke-ArmExpression -Expression "[guid('secret','gateway','reader')]" -Template $template
    $again = Invoke-ArmExpression -Expression "[guid('secret','gateway','reader')]" -Template $template
    Assert-Equal $first $again 'Idempotent role dependencies require stable GUIDs.'
    Assert-Match $first '^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' 'Expected UUIDv5 shape.'
    Assert-True ($first -ne (Invoke-ArmExpression -Expression "[guid('gateway','secret','reader')]" -Template $template)) 'Input order must affect the dependency name.'
    $extension = Invoke-ArmExpression -Expression "[extensionResourceId('/subscriptions/s/resourceGroups/r/providers/Microsoft.KeyVault/vaults/v/secrets/secret','Microsoft.Authorization/roleAssignments','reader')]" -Template $template
    Assert-Equal $extension '/subscriptions/s/resourceGroups/r/providers/Microsoft.KeyVault/vaults/v/secrets/secret/providers/Microsoft.Authorization/roleAssignments/reader' 'Secret-scoped extension dependencies must preserve their actual parent scope.'
}

Test-Case 'Azure Monitor logger omits optional credentials and precedes its diagnostic' {
    $compiled = Get-CompiledTemplate -BicepPath (Join-Path $moduleRoot 'main.bicep')
    $loggers = @($compiled.resources | Where-Object type -eq 'Microsoft.ApiManagement/service/loggers')
    Assert-Equal $loggers.Count 1 'The diagnostic requires an existing logger; a reference alone does not provision it.'
    Assert-Equal $loggers[0].properties.loggerType 'azureMonitor' 'Do not substitute a credentialed Application Insights or Event Hub destination.'
    Assert-True (-not ($loggers[0].properties.PSObject.Properties.Name -contains 'credentials')) 'Omit optional credentials entirely; an empty object invokes connection-method validation.'
    Assert-True (-not ($loggers[0].properties.PSObject.Properties.Name -contains 'resourceId')) 'Do not introduce a new log destination.'
    $diagnostics = @($compiled.resources | Where-Object type -eq 'Microsoft.ApiManagement/service/diagnostics')
    Assert-Equal $diagnostics.Count 1 'Keep the all-APIs privacy diagnostic.'
    $diagnostic = $diagnostics[0]
    Assert-Match $diagnostic.properties.loggerId "'Microsoft.ApiManagement/service/loggers'.*'azuremonitor'" 'Reference the actual logger resource.'
    Assert-True ($diagnostic.dependsOn -contains $diagnostic.properties.loggerId) 'ARM must create the logger before the diagnostic.'
    Assert-Equal $diagnostic.properties.sampling.percentage 0 'Do not collect request samples.'
    Assert-Equal $diagnostic.properties.httpCorrelationProtocol 'None' 'Do not propagate correlation headers.'
    Assert-True (-not ($diagnostic.properties.PSObject.Properties.Name -contains 'alwaysLog')) 'Errors must not bypass zero sampling.'
    $metrics = @($compiled.resources | Where-Object type -eq 'Microsoft.Insights/diagnosticSettings')
    Assert-Equal $metrics.Count 1 'Preserve the existing metrics-only destination.'
    Assert-Equal @($metrics[0].properties.logs).Count 0 'GatewayLogs can contain sensitive paths and query parameters.'
    Assert-Equal @($metrics[0].properties.metrics).Count 1 'Only the approved metric category is enabled.'
    Assert-Equal $metrics[0].properties.metrics[0].category 'AllMetrics' 'Preserve platform metrics.'
    Assert-Equal $metrics[0].properties.metrics[0].enabled $true 'Do not disable approved monitoring.'
    $roles = @($compiled.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
    Assert-Equal $roles.Count 1 'Do not introduce a monitoring role assignment.'
    Assert-Equal $roles[0].condition "[parameters('configureGraph')]" 'The existing credential role must remain separately gated.'
}

Test-Case 'Graph gateway preserves disabled legacy portal and insecure transport protocols' {
    $compiled = Get-CompiledTemplate -BicepPath (Join-Path $moduleRoot 'main.bicep')
    $service = @($compiled.resources | Where-Object type -eq 'Microsoft.ApiManagement/service')[0]
    Assert-Equal $service.properties.legacyPortalStatus 'Disabled' 'Do not re-enable the legacy portal on reprovision.'
    foreach ($suffix in @(
            'Backend.Protocols.Ssl30', 'Backend.Protocols.Tls10', 'Backend.Protocols.Tls11',
            'Ciphers.TripleDes168', 'Protocols.Ssl30', 'Protocols.Tls10', 'Protocols.Tls11'
        )) {
        Assert-Equal $service.properties.customProperties."Microsoft.WindowsAzure.ApiManagement.Gateway.Security.$suffix" 'False' 'Preserve the deployed insecure protocol/cipher restrictions explicitly.'
    }
}

Test-Case 'Graph composition preserves restricted vault access without new private networking' {
    $root = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra/main.bicep')
    $publicAccess = $root.resources.keyVault.properties.parameters.enablePublicAccess.value
    foreach ($graphEnabled in @($false, $true)) {
        $overrides = @{apiManagement=$true;aiFoundry=$true;keyVault=$true;graphMcp=$graphEnabled;roleAssignments=$false} | ConvertTo-Json -Compress
        $parameters = @{
            deploymentProfile='core'
            enableNetwork=$null;enableKeyVault=$null;enableStorage=$null
            enableBastion=$null;enableWindowsVm=$null;enableLinuxVm=$null
            enableNatGateway=$null;enableEntraLogin=$null;enableShutdownSchedules=$null
            enableRoleAssignments=$false
            enableApiManagement=$false
            enableAiFoundry=$false
            enableGraphMcp=$false
            featureOverridesBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($overrides))
        }
        Assert-Equal (Invoke-ArmExpression -Expression $publicAccess -Template $root -Parameters $parameters) $false 'The gateway must not silently enable vault public access in either stage.'
    }
    $vault = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra/modules/key-vault/main.bicep')
    $resource = @($vault.resources | Where-Object type -eq 'Microsoft.KeyVault/vaults')[0]
    foreach ($scenario in @(
            @{public=$false;subnet='';dns='';expected='Disabled'}
            @{public=$true;subnet='';dns='';expected='Enabled'}
            @{public=$true;subnet='synthetic-subnet';dns='synthetic-zone';expected='Disabled'}
        )) {
        $actual = Invoke-ArmExpression -Expression $resource.properties.publicNetworkAccess -Template $vault -Parameters @{
            enablePublicAccess=$scenario.public;privateEndpointSubnetId=$scenario.subnet;privateDnsZoneId=$scenario.dns
        }
        Assert-Equal $actual $scenario.expected 'Preserve direct module callers and private-endpoint precedence.'
    }
    Assert-Equal $resource.properties.networkAcls.defaultAction 'Deny' 'Do not weaken the vault firewall.'
    Assert-Equal $resource.properties.networkAcls.bypass 'AzureServices' 'Preserve the reviewed trusted-service exception.'
    Assert-Equal @($resource.properties.networkAcls.ipRules).Count 0 'Do not add an operator IP exception.'
    Assert-Equal @($resource.properties.networkAcls.virtualNetworkRules).Count 0 'Do not add new networking.'
}
