[CmdletBinding()]
param(
    # Registers the resource providers the enabled modules need instead of
    # failing on them. The preprovision hook never passes it, so
    # `azd provision --preview` stays read-only; run
    # ./scripts/preflight.ps1 -RegisterProviders yourself when preflight
    # reports an unregistered provider.
    [switch] $RegisterProviders
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'naming.ps1')
. (Join-Path $PSScriptRoot 'module-selection.ps1')

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $json = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }

    return $json | ConvertFrom-Json
}

function Get-RequiredEnvironmentValue {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $value = & azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Required azd environment value '$Name' is not set."
    }

    return $value.Trim()
}

function Get-ProviderRegistrationState {
    param(
        [Parameter(Mandatory)]
        [string] $Namespace,

        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    $state = & az provider show --namespace $Namespace --subscription $SubscriptionId `
        --query registrationState --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect provider '$Namespace'."
    }

    return [string] $state
}

foreach ($command in @('az', 'azd')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found."
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Profile resolution
# ---------------------------------------------------------------------------

$knownProfiles = @('core', 'private', 'full')

$deploymentProfile = (& azd env get-value DEPLOYMENT_PROFILE 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($deploymentProfile)) {
    $deploymentProfile = 'core'
}
$deploymentProfile = $deploymentProfile.Trim()

if ($deploymentProfile -notin $knownProfiles) {
    throw "DEPLOYMENT_PROFILE must be one of: $($knownProfiles -join ', '); received '$deploymentProfile'. Set a supported value, for example: azd env set DEPLOYMENT_PROFILE private"
}

$isPrivateOrHigher = $deploymentProfile -ne 'core'
$isFull = $deploymentProfile -eq 'full'

# ---------------------------------------------------------------------------
# Feature resolution - mirrors the featureSettings block of infra/main.bicep
# ---------------------------------------------------------------------------

$featureOverridesJson = Get-RequiredEnvironmentValue -Name 'AZURE_FEATURE_OVERRIDES_JSON'
try {
    $featureOverrides = $featureOverridesJson | ConvertFrom-Json -AsHashtable
}
catch [System.ArgumentException] {
    throw 'AZURE_FEATURE_OVERRIDES_JSON must be a JSON object.'
}
if ($featureOverrides -isnot [System.Collections.IDictionary]) {
    throw 'AZURE_FEATURE_OVERRIDES_JSON must be a JSON object.'
}

$featureSettings = [ordered] @{
    network           = $isPrivateOrHigher
    keyVault          = $isPrivateOrHigher
    storage           = $isPrivateOrHigher
    bastion           = $isFull
    windowsVm         = $isFull
    linuxVm           = $isFull
    natGateway        = $isFull
    entraLogin        = $isFull
    shutdownSchedules = $isFull
    roleAssignments   = $true
}

$supportedFeatures = @($featureSettings.Keys)
foreach ($feature in $featureOverrides.Keys) {
    if ($feature -cnotin $supportedFeatures) {
        throw "Unsupported feature override '$feature'. Supported keys: $($supportedFeatures -join ', ')."
    }
    if ($featureOverrides[$feature] -isnot [bool]) {
        throw "Feature override '$feature' must be true or false."
    }
    $featureSettings[$feature] = $featureOverrides[$feature]
}

$anyVm = $featureSettings.windowsVm -or $featureSettings.linuxVm

if ($featureSettings.shutdownSchedules -and -not $anyVm) {
    throw 'shutdownSchedules requires at least one jumpbox VM.'
}
if ($featureSettings.entraLogin -and -not $anyVm) {
    throw 'entraLogin requires at least one jumpbox VM.'
}
if ($featureSettings.entraLogin -ne $featureSettings.natGateway) {
    throw 'natGateway and entraLogin must be enabled or disabled together; air-gapped deployments set both to false.'
}
if ($anyVm -and -not $featureSettings.bastion) {
    throw 'Jumpbox VMs require Bastion because this template configures no alternate private access path.'
}

# The same defensive derivations infra/main.bicep applies, so preflight and the
# template agree on what is actually deployed.
$deployNetwork = $featureSettings.network -or $featureSettings.bastion -or $anyVm
$deployKeyVault = $featureSettings.keyVault -or $anyVm
$deployStorage = [bool] $featureSettings.storage

# ---------------------------------------------------------------------------
# Catalog-driven module enablement
# ---------------------------------------------------------------------------

$catalogPath = Join-Path $repoRoot 'infra/modules/catalog.json'
if (-not (Test-Path -LiteralPath $catalogPath)) {
    throw "Module catalog '$catalogPath' is missing. Run ./scripts/build-catalog.ps1."
}
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json -AsHashtable

# Maps a catalog module to whether this deployment will actually deploy it.
# Anything not listed here falls back to its declared feature flag.
$moduleEnabled = @{
    'monitoring'  = $true
    'network'     = $deployNetwork
    'private-dns' = $deployNetwork
    'key-vault'   = $deployKeyVault
    'storage'     = $deployStorage
    'bastion'     = [bool] $featureSettings.bastion
    'nat-gateway' = [bool] $featureSettings.natGateway
    'jumpboxes'   = $anyVm
}

$enabledModules = @(Get-EnabledCatalogModules -Modules $catalog.modules -Features $featureSettings -Composition $moduleEnabled)
foreach ($module in $enabledModules) {
    $name = [string] $module['name']
    if ($module['profiles'] -notcontains $deploymentProfile) {
        Write-Warning "Module '$name' is enabled by an override but is not part of the '$deploymentProfile' profile."
    }

}

# ---------------------------------------------------------------------------
# Core checks - these run for every profile, including core
# ---------------------------------------------------------------------------

$subscriptionId = Get-RequiredEnvironmentValue -Name 'AZURE_SUBSCRIPTION_ID'
$location = Get-RequiredEnvironmentValue -Name 'AZURE_LOCATION'
$environmentName = Get-RequiredEnvironmentValue -Name 'AZURE_ENV_NAME'
$cachedSubscriptionCode = Get-RequiredEnvironmentValue -Name 'AZURE_SUBSCRIPTION_CODE'

if ($environmentName -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])$') {
    throw 'AZURE_ENV_NAME must contain 2-32 lowercase alphanumeric or hyphen characters and must start and end with an alphanumeric character.'
}
if ($location -cnotmatch '^[a-z0-9]+$') {
    throw "AZURE_LOCATION '$location' is not a valid Azure region name."
}
$parsedSubscriptionId = [Guid]::Empty
if (
    -not [Guid]::TryParseExact($subscriptionId, 'D', [ref] $parsedSubscriptionId) -or
    $parsedSubscriptionId -eq [Guid]::Empty
) {
    throw 'AZURE_SUBSCRIPTION_ID must be a non-empty GUID.'
}
Assert-DeploymentSubscription -SubscriptionId $subscriptionId

$account = Invoke-AzJson -Arguments @('account', 'show', '--subscription', $subscriptionId)
if ($account.state -ne 'Enabled') {
    throw "Subscription '$subscriptionId' is not enabled."
}
$null = Assert-SubscriptionCode -SubscriptionName $account.name `
    -CachedCode $cachedSubscriptionCode -SubscriptionId $subscriptionId
Write-Output "Target subscription: '$($account.name)' ($subscriptionId) in tenant $($account.tenantId)."

$locations = @(Invoke-AzJson -Arguments @('account', 'list-locations', '--query', "[?name=='$location'].name"))
if ($locations.Count -eq 0) {
    throw "Azure location '$location' is not recognized."
}
$locationCatalogPath = Join-Path $repoRoot 'infra/core/location-codes.json'
$locationCode = Get-LocationCode -Location $location -CatalogPath $locationCatalogPath
$tenantCode = Get-TenantCode -TenantId $account.tenantId `
    -CatalogPath (Join-Path $repoRoot 'infra/core/tenant-codes.json')

# ---------------------------------------------------------------------------
# Provider registration - derived from the modules actually enabled
# ---------------------------------------------------------------------------

$providers = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($module in $enabledModules) {
    foreach ($provider in $module['providers']) {
        $null = $providers.Add([string] $provider)
    }
}
if ($featureSettings.roleAssignments) {
    $null = $providers.Add('Microsoft.Authorization')
}
if (-not $featureSettings.shutdownSchedules) {
    # The jumpboxes module declares Microsoft.DevTestLab because that is the
    # provider behind auto-shutdown schedules. Without schedules it is not used.
    $null = $providers.Remove('Microsoft.DevTestLab')
}

$providerStates = [ordered] @{}
foreach ($provider in $providers) {
    $providerStates[$provider] = Get-ProviderRegistrationState -Namespace $provider -SubscriptionId $subscriptionId
}
$unregisteredProviders = @($providerStates.Keys | Where-Object { $providerStates[$_] -ne 'Registered' })

if ($unregisteredProviders.Count -gt 0 -and $RegisterProviders) {
    # Opt-in only. Registration is a subscription-wide change, so the hook never
    # does it on its own; an operator who passes -RegisterProviders has asked
    # for exactly this.
    foreach ($provider in $unregisteredProviders) {
        Write-Output "Registering provider '$provider' in subscription $subscriptionId (was '$($providerStates[$provider])')..."
        & az provider register --namespace $provider --subscription $subscriptionId --wait --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to register provider '$provider'. Registration needs Microsoft.Resources/subscriptions/providers/register/action on the subscription; ask someone who has it to run: az provider register --namespace $provider --subscription $subscriptionId --wait"
        }
        $providerStates[$provider] = Get-ProviderRegistrationState -Namespace $provider -SubscriptionId $subscriptionId
        if ($providerStates[$provider] -ne 'Registered') {
            throw "Provider '$provider' is still '$($providerStates[$provider])' after registration. Wait for it to finish, then re-run preflight."
        }
        Write-Output "Registered provider '$provider'."
    }
    $unregisteredProviders = @()
}

if ($unregisteredProviders.Count -gt 0) {
    # Microsoft.DevTestLab is the usual offender: it backs the full profile's
    # auto-shutdown schedules and is rarely registered until something needs it.
    $missing = @($unregisteredProviders | Where-Object { $providerStates[$_] -ne 'Registering' })
    $pending = @($unregisteredProviders | Where-Object { $providerStates[$_] -eq 'Registering' })
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($missing.Count -gt 0) {
        $lines.Add("Register these Azure providers before provisioning: $($missing -join ', ').")
        $lines.Add('Run ./scripts/preflight.ps1 -RegisterProviders, or register them yourself and re-run preflight:')
        foreach ($provider in $missing) {
            $lines.Add("  az provider register --namespace $provider --subscription $subscriptionId --wait")
        }
    }
    if ($pending.Count -gt 0) {
        $lines.Add("Registration is still in progress for: $($pending -join ', '). Wait for it to finish, then re-run preflight.")
    }
    throw ($lines -join [Environment]::NewLine)
}

# ---------------------------------------------------------------------------
# Operator principals - only demanded when an enabled module needs them
# ---------------------------------------------------------------------------

$requiresOperatorPrincipals = $featureSettings.roleAssignments -and
    @($enabledModules | Where-Object { $_['preflight']['requiresOperatorPrincipals'] }).Count -gt 0

$operatorPrincipalIdsCsv = (& azd env get-value AZURE_OPERATOR_PRINCIPAL_IDS 2>$null)
$operatorPrincipalIds = @(if (
    $LASTEXITCODE -ne 0 -or
    [string]::IsNullOrWhiteSpace($operatorPrincipalIdsCsv)
) {
    @()
}
else {
    @($operatorPrincipalIdsCsv.Split(',', [StringSplitOptions]::RemoveEmptyEntries) |
        ForEach-Object { $_.Trim() })
})

if ($requiresOperatorPrincipals -and $operatorPrincipalIds.Count -eq 0) {
    throw 'At least one Entra operator principal ID is required when a jumpbox is deployed with role assignments enabled. Set AZURE_OPERATOR_PRINCIPAL_IDS or disable the roleAssignments feature.'
}

$seenPrincipalIds = [System.Collections.Generic.HashSet[Guid]]::new()
foreach ($principalId in $operatorPrincipalIds) {
    $parsedPrincipalId = [Guid]::Empty
    if (
        $principalId -isnot [string] -or
        -not [Guid]::TryParseExact($principalId, 'D', [ref] $parsedPrincipalId) -or
        $parsedPrincipalId -eq [Guid]::Empty
    ) {
        throw "Invalid Entra operator principal ID '$principalId'."
    }
    if (-not $seenPrincipalIds.Add($parsedPrincipalId)) {
        throw "Duplicate Entra operator principal ID '$principalId'."
    }
}

# ---------------------------------------------------------------------------
# Compute checks - skipped entirely unless a jumpbox is deployed
# ---------------------------------------------------------------------------

$requestedChecks = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($module in $enabledModules) {
    foreach ($check in $module['preflight']['checks']) {
        $null = $requestedChecks.Add([string] $check)
    }
}

if ($requestedChecks.Contains('vmSkuAvailability')) {
    $vmSizes = @()
    if ($featureSettings.windowsVm) {
        $vmSizes += 'Standard_D4s_v5'
    }
    if ($featureSettings.linuxVm) {
        $vmSizes += 'Standard_D2s_v5'
    }
    foreach ($vmSize in $vmSizes) {
        $sku = @(Invoke-AzJson -Arguments @(
            'vm', 'list-skus',
            '--subscription', $subscriptionId,
            '--location', $location,
            '--size', $vmSize,
            '--all',
            '--query', "[?name=='$vmSize']"
        ))

        if ($sku.Count -eq 0) {
            throw "VM size '$vmSize' is unavailable or restricted in '$location'."
        }

        $locationRestrictionCount = @(
            $sku[0].restrictions |
                Where-Object { $null -ne $_ -and $_.type -eq 'Location' }
        ).Count
        if ($locationRestrictionCount -gt 0) {
            throw "VM size '$vmSize' is unavailable or restricted in '$location'."
        }
    }
}

if ($requestedChecks.Contains('windowsImage') -and $featureSettings.windowsVm) {
    $windowsUrn = 'MicrosoftWindowsDesktop:windows-11:win11-24h2-pro:latest'
    $null = Invoke-AzJson -Arguments @(
        'vm', 'image', 'show',
        '--subscription', $subscriptionId,
        '--location', $location,
        '--urn', $windowsUrn
    )
}

if ($requestedChecks.Contains('vcpuQuota')) {
    $requiredVcpus = $(if ($featureSettings.windowsVm) { 4 } else { 0 }) +
        $(if ($featureSettings.linuxVm) { 2 } else { 0 })

    $regionalUsage = Invoke-AzJson -Arguments @(
        'vm', 'list-usage',
        '--subscription', $subscriptionId,
        '--location', $location,
        '--query', "[?localName=='Total Regional vCPUs' || localName=='Standard DSv5 Family vCPUs']"
    )

    foreach ($usage in $regionalUsage) {
        if (($usage.limit - $usage.currentValue) -lt $requiredVcpus) {
            throw "Insufficient '$($usage.localName)' quota in '$location': $requiredVcpus vCPUs are required."
        }
    }
}

$moduleList = ($enabledModules | ForEach-Object { $_['name'] }) -join ', '
Write-Output "Preflight passed for environment '$environmentName' using profile '$deploymentProfile' in '$location' ($locationCode), tenant code '$tenantCode' and subscription code '$cachedSubscriptionCode'."
Write-Output "Modules: $moduleList"
Write-Output "Providers verified: $($providers -join ', ')"
