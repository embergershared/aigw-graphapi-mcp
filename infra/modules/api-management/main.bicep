targetScope = 'resourceGroup'

@minLength(1)
@maxLength(50)
param name string
param location string = resourceGroup().location
param tags object = {}
@minLength(1)
param publisherName string
@minLength(3)
param publisherEmail string
param logAnalyticsWorkspaceId string
param configureGraph bool = false
param tenantId string = subscription().tenantId
param gatewayClientId string = ''
param allowedClientIds array = []
param keyVaultName string
param credentialSecretName string = 'graph-obo-client-secret'

var contract = loadJsonContent('./contract.json')
var allowedClientClaims = join(map(allowedClientIds, clientId => '<value>${clientId}</value>'), '')
var authFragment = replace(
  replace(
    replace(loadTextContent('./policies/authenticate.xml'), '@@APPROVED_CLIENTS@@', allowedClientClaims),
    '@@RATE_LIMIT_CALLS@@',
    string(contract.rateLimitCalls)
  ),
  '@@RATE_LIMIT_PERIOD@@',
  string(contract.rateLimitPeriodSeconds)
)

resource service 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Developer'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherName: publisherName
    publisherEmail: publisherEmail
    publicNetworkAccess: 'Enabled'
    virtualNetworkType: 'None'
    legacyPortalStatus: 'Disabled'
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Ssl30': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TripleDes168': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Ssl30': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'False'
    }
  }
}

// Metrics only: GatewayLogs include sensitive request paths/query values.
resource metrics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'metrics-to-log-analytics'
  scope: service
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
    logs: []
  }
}

resource monitorLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: service
  name: 'azuremonitor'
  properties: {
    loggerType: 'azureMonitor'
    isBuffered: true
  }
}

// Explicit all-APIs settings also protect native MCP from body-log buffering.
resource safeDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: service
  name: 'azuremonitor'
  properties: {
    loggerId: monitorLogger.id
    logClientIp: false
    httpCorrelationProtocol: 'None'
    sampling: {
      samplingType: 'fixed'
      percentage: 0
    }
    frontend: {
      request: {
        body: { bytes: 0 }
        headers: []
      }
      response: {
        body: { bytes: 0 }
        headers: []
      }
    }
    backend: {
      request: {
        body: { bytes: 0 }
        headers: []
      }
      response: {
        body: { bytes: 0 }
        headers: []
      }
    }
  }
}

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
}

resource credential 'Microsoft.KeyVault/vaults/secrets@2024-11-01' existing = {
  parent: vault
  name: credentialSecretName
}

resource credentialReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (configureGraph) {
  name: guid(credential.id, service.id, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: credential
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalId: service.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

var publicValues = {
  'gateway-tenant-id': tenantId
  'gateway-client-id': gatewayClientId
  'gateway-openid-config': '${environment().authentication.loginEndpoint}${tenantId}/v2.0/.well-known/openid-configuration'
}

resource namedValues 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [
  for item in items(publicValues): if (configureGraph) {
    parent: service
    name: item.key
    properties: {
      displayName: item.key
      value: item.value
      secret: false
    }
  }
]

resource oboSecret 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = if (configureGraph) {
  parent: service
  name: 'graph-obo-secret'
  properties: {
    displayName: 'graph-obo-secret'
    secret: true
    keyVault: {
      secretIdentifier: 'https://${keyVaultName}${environment().suffixes.keyvaultDns}/secrets/${credentialSecretName}'
    }
  }
  dependsOn: [
    credentialReader
  ]
}

resource authentication 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = if (configureGraph) {
  parent: service
  name: 'graph-authenticate'
  properties: {
    format: 'rawxml'
    value: authFragment
  }
  dependsOn: [
    namedValues
  ]
}

resource obo 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = if (configureGraph) {
  parent: service
  name: 'graph-obo'
  properties: {
    format: 'rawxml'
    value: replace(loadTextContent('./policies/obo.xml'), '@@OBO_TIMEOUT@@', string(contract.oboTimeoutSeconds))
  }
  dependsOn: [
    oboSecret
    namedValues
  ]
}

resource restApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = if (configureGraph) {
  parent: service
  name: 'graph-read'
  properties: {
    displayName: 'My mail and calendar (read only)'
    path: 'graph'
    protocols: ['https']
    subscriptionRequired: false
    serviceUrl: 'https://graph.microsoft.com'
    format: 'openapi+json'
    value: loadTextContent('./openapi.json')
  }
}

resource restPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = if (configureGraph) {
  parent: restApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(
      replace(loadTextContent('./policies/rest.xml'), '@@CONTRACT_BASE64@@', base64(string(contract))),
      '@@BACKEND_TIMEOUT@@',
      string(contract.backendTimeoutSeconds)
    )
  }
  dependsOn: [
    authentication
    obo
  ]
}

resource mcpApi 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' = if (configureGraph) {
  parent: service
  name: 'graph-mcp'
  properties: {
    type: 'mcp'
    displayName: 'My mail and calendar MCP'
    path: 'graph-mcp'
    protocols: ['https']
    subscriptionRequired: false
  }
}

resource mcpPolicy 'Microsoft.ApiManagement/service/apis/policies@2025-09-01-preview' = if (configureGraph) {
  parent: mcpApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('./policies/mcp.xml')
  }
  dependsOn: [
    authentication
  ]
}

// One at a time: parallel tool writes on the same MCP API fail with PreconditionFailed.
@batchSize(1)
resource tools 'Microsoft.ApiManagement/service/apis/tools@2025-09-01-preview' = [
  for tool in contract.tools: if (configureGraph) {
    parent: mcpApi
    name: tool.name
    properties: {
      displayName: tool.name
      description: tool.description
      operationId: '${restApi.id}/operations/${tool.name}'
    }
    dependsOn: [
      restPolicy
      mcpPolicy
    ]
  }
]

output id string = service.id
output name string = service.name
output principalId string = service.identity.principalId
output restUrl string = configureGraph ? '${service.properties.gatewayUrl}/graph' : ''
@description('Read the deployed MCP API resource/server URL after provisioning; do not infer a transport URL from this ID.')
output mcpApiId string = configureGraph ? mcpApi.id : ''
