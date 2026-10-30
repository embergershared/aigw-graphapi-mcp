<#
.SYNOPSIS
    Prepares the nonsecret settings for a supported encrypted Foundry custom OAuth connection.
.DESCRIPTION
    Offline only. Creation and secret entry use the supported Foundry portal, not an
    invented connection API. Copy its actual callback into configure-graph-identity.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid] $TenantId,
    [Parameter(Mandatory)] [guid] $GatewayClientId,
    [Parameter(Mandatory)] [guid] $FoundryClientId,
    [Parameter(Mandatory)] [uri] $McpServerUrl,
    [string] $ReturnedCallbackUri=''
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'graph-identity.ps1')
if ($TenantId -eq [guid]::Empty -or $GatewayClientId -eq [guid]::Empty -or
    $FoundryClientId -eq [guid]::Empty -or $GatewayClientId -eq $FoundryClientId) { throw 'Select distinct owned gateway/web clients and the tenant.' }
if (-not $McpServerUrl.IsAbsoluteUri -or $McpServerUrl.Scheme -cne 'https' -or
    $McpServerUrl.UserInfo -or $McpServerUrl.Query -or $McpServerUrl.Fragment -or -not $McpServerUrl.IsDefaultPort) {
    throw 'Use the actual deployed HTTPS MCP URL without credentials, query, fragment or a nonstandard port.'
}
$null=Get-GraphIdentityPlan -Environment 'validation' -FoundryCallbackUri $ReturnedCallbackUri
[pscustomobject]@{
    Status='PreparedOnly'
    ServerUrl=$McpServerUrl.AbsoluteUri
    ClientId=$FoundryClientId.ToString()
    AuthorizationEndpoint="https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize"
    TokenEndpoint="https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    Scopes="api://$GatewayClientId/access_as_user offline_access"
    ReturnedCallbackUri=$ReturnedCallbackUri
    AllowedTools=@('list_messages','get_message','list_calendar_view','get_event')
    RequireApproval='always'
    CredentialHandling='Enter only into the supported encrypted custom OAuth connection. Never files, CLI arguments or output.'
    RemainingGate='Create the owned connection after approval, use its exact returned callback, then separately verify consent and native MCP invocation.'
}
