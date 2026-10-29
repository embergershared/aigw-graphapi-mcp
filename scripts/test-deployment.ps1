<#
.SYNOPSIS
    Checks that a provisioned azd environment deployed what it reported.

.DESCRIPTION
    Runs after `azd provision`, in the pull request deployment workflow or by
    hand. It reads the environment's outputs and confirms, through the Azure
    CLI, that:

      * the resource group exists and carries the environment's tags
      * every resource in it finished provisioning
      * every resource the outputs name exists with the expected type
      * each jumpbox VM is running
      * a core deployment without overrides holds no network or compute
        resource

    It deliberately does not assert settings that tenant policy may rewrite
    after deployment, such as public network access.

.PARAMETER Environment
    The azd environment. Defaults to the selected one.
#>
[CmdletBinding()]
param(
    [string] $Environment
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$environmentArguments = @(if ($Environment) { @('-e', $Environment) } else { @() })
$lines = & azd env get-values @environmentArguments
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read the azd environment values. Provision the environment first.'
}
$values = @{}
foreach ($line in $lines) {
    $match = [regex]::Match([string] $line, '^(?<key>[A-Za-z0-9_]+)="(?<value>.*)"$')
    if ($match.Success) {
        $values[$match.Groups['key'].Value] = $match.Groups['value'].Value -replace '\\"', '"'
    }
}

function Get-Value {
    param([Parameter(Mandatory)] [string] $Name)
    if ($values.ContainsKey($Name)) { return [string] $values[$Name] }
    return ''
}

foreach ($required in @('AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_DEPLOYMENT_PROFILE')) {
    if (-not (Get-Value $required)) {
        throw "azd environment value '$required' is not set. Provision the environment first."
    }
}

$environmentName = Get-Value 'AZURE_ENV_NAME'
$subscriptionId = Get-Value 'AZURE_SUBSCRIPTION_ID'
$resourceGroup = Get-Value 'AZURE_RESOURCE_GROUP'
$deploymentProfile = Get-Value 'AZURE_DEPLOYMENT_PROFILE'

$failures = [System.Collections.Generic.List[string]]::new()
function Write-Check {
    param([bool] $Passed, [string] $Message)
    if ($Passed) { Write-Output "[ OK ] $Message" }
    else {
        Write-Output "[FAIL] $Message"
        $failures.Add($Message)
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $json = & az @Arguments --subscription $subscriptionId --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
    return (($json -join "`n") | ConvertFrom-Json)
}

$group = Invoke-AzJson -Arguments @('group', 'show', '--name', $resourceGroup)
$tags = $group.tags
$tagValue = { param($name) if ($null -ne $tags -and $tags.PSObject.Properties[$name]) { [string] $tags.$name } else { '' } }
Write-Check -Passed ((& $tagValue 'azd-env-name') -ceq $environmentName) -Message "Resource group '$resourceGroup' is tagged azd-env-name=$environmentName."
Write-Check -Passed ((& $tagValue 'profile') -ceq $deploymentProfile) -Message "Resource group '$resourceGroup' is tagged profile=$deploymentProfile."

$resources = @(Invoke-AzJson -Arguments @('resource', 'list', '--resource-group', $resourceGroup))
Write-Output "Resource group '$resourceGroup' holds $($resources.Count) resource(s)."
foreach ($resource in $resources) {
    $state = if ($resource.PSObject.Properties['provisioningState']) { [string] $resource.provisioningState } else { '' }
    if ($state -and $state -ne 'Succeeded') {
        Write-Check -Passed $false -Message "'$($resource.name)' ($($resource.type)) is '$state', not Succeeded."
    }
}
if (@($resources | Where-Object { $_.PSObject.Properties['provisioningState'] -and $_.provisioningState -and $_.provisioningState -ne 'Succeeded' }).Count -eq 0) {
    Write-Check -Passed $true -Message 'Every resource finished provisioning.'
}

$expectedTypes = [ordered] @{
    AZURE_VIRTUAL_NETWORK_NAME      = 'Microsoft.Network/virtualNetworks'
    AZURE_KEY_VAULT_NAME            = 'Microsoft.KeyVault/vaults'
    AZURE_STORAGE_ACCOUNT_NAME      = 'Microsoft.Storage/storageAccounts'
    AZURE_APPLICATION_INSIGHTS_NAME = 'Microsoft.Insights/components'
    AZURE_BASTION_NAME              = 'Microsoft.Network/bastionHosts'
    AZURE_WINDOWS_VM_NAME           = 'Microsoft.Compute/virtualMachines'
    AZURE_LINUX_VM_NAME             = 'Microsoft.Compute/virtualMachines'
}
$workspaceId = Get-Value 'AZURE_LOG_ANALYTICS_WORKSPACE_ID'
$expected = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $expectedTypes.GetEnumerator()) {
    $name = Get-Value $entry.Key
    if ($name) { $expected.Add([pscustomobject] @{ Output = $entry.Key; Name = $name; Type = $entry.Value }) }
}
if ($workspaceId) {
    $expected.Add([pscustomobject] @{ Output = 'AZURE_LOG_ANALYTICS_WORKSPACE_ID'; Name = ($workspaceId -split '/')[-1]; Type = 'Microsoft.OperationalInsights/workspaces' })
}
foreach ($item in $expected) {
    $found = @($resources | Where-Object { $_.name -ceq $item.Name -and ([string] $_.type) -ieq $item.Type }).Count -gt 0
    Write-Check -Passed $found -Message "$($item.Output) names an existing $($item.Type) '$($item.Name)'."
}

foreach ($output in @('AZURE_WINDOWS_VM_NAME', 'AZURE_LINUX_VM_NAME')) {
    $vmName = Get-Value $output
    if (-not $vmName) { continue }
    $power = & az vm get-instance-view --subscription $subscriptionId --resource-group $resourceGroup --name $vmName `
        --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Unable to read the power state of '$vmName'." }
    Write-Check -Passed (([string] $power).Trim() -eq 'PowerState/running') -Message "VM '$vmName' is running (reported '$(([string] $power).Trim())')."
}

# An override such as {"roleAssignments":false} keeps core free of network and
# compute; one that turns a network or VM feature on does not.
$overridesJson = (Get-Value 'AZURE_FEATURE_OVERRIDES_JSON').Trim()
$overrides = if ($overridesJson) { $overridesJson | ConvertFrom-Json -AsHashtable } else { @{} }
$addsNetwork = @('network', 'bastion', 'windowsVm', 'linuxVm', 'natGateway' | Where-Object { $overrides.ContainsKey($_) -and $overrides[$_] -eq $true }).Count -gt 0
if ($deploymentProfile -eq 'core' -and -not $addsNetwork) {
    $forbidden = @($resources | Where-Object { ([string] $_.type) -imatch '^Microsoft\.(Network|Compute)/' })
    Write-Check -Passed ($forbidden.Count -eq 0) -Message "The core profile deployed no network or compute resource$(if ($forbidden.Count) { ': ' + (($forbidden | ForEach-Object { $_.name }) -join ', ') })."
}

if ($failures.Count -gt 0) {
    throw "$($failures.Count) deployment check(s) failed for '$environmentName'."
}
Write-Output "All deployment checks passed for '$environmentName' ($deploymentProfile)."
