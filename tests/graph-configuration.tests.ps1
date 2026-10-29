. (Join-Path $PSScriptRoot 'assert.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'arm-expression.ps1')

$graphConfigurationTemplate = Get-CompiledTemplate -BicepPath (Get-RepoPath 'infra/main.bicep')
$syntheticDeployments = '[{"name":"fixture-deployment","model":"fixture-model","version":"2026-03-17","sku":"DataZoneStandard","capacity":10}]'

foreach ($scenario in @(
        @{ Name = 'missing'; Json = $null; Expected = '[]' }
        @{ Name = 'empty'; Json = '[]'; Expected = '[]' }
        @{ Name = 'nonempty'; Json = $syntheticDeployments; Expected = $syntheticDeployments }
    )) {
    Test-Case "azd parameter interpolation preserves $($scenario.Name) model selections" {
        $fixtureValues = @{
            DEPLOYMENT_PROFILE = 'core'
            AZURE_REPOSITORY = 'fixture'
            AZURE_SUBSCRIPTION_ID = '11111111-1111-1111-1111-111111111111'
            AZURE_LOCATION = 'eastus2'
            AZURE_ENV_NAME = 'fixture'
            AZURE_FEATURE_OVERRIDES_JSON = '{"aiFoundry":true,"graphMcp":false,"roleAssignments":false}'
        }
        if ($null -ne $scenario.Json) { $fixtureValues.FOUNDRY_DEPLOYMENTS_JSON = $scenario.Json }
        function azd {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'env' -and $args[1] -eq 'get-value') {
                if ($fixtureValues.ContainsKey($args[2])) { return $fixtureValues[$args[2]] }
                $global:LASTEXITCODE = 1
                return
            }
            if ($args[0] -eq 'env' -and $args[1] -eq 'set') {
                $fixtureValues[$args[2]] = [string] $args[3]
                return
            }
            throw "Unexpected azd call: $args"
        }
        function az {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'account' -and $args[1] -eq 'show') {
                if ($args -contains 'id') { return $fixtureValues.AZURE_SUBSCRIPTION_ID }
                if ($args -contains 'name') { return 'fixture-s1-projects' }
            }
            throw "Unexpected Azure call: $args"
        }

        $parameterText = Get-Content -LiteralPath (Get-RepoPath 'infra/main.parameters.json') -Raw
        $composeParameters = {
            [regex]::Replace($parameterText, '\$\{(?<name>[A-Z0-9_]+)(?:=(?<fallback>[^}]*))?\}', {
                    param($match)
                    $name = $match.Groups['name'].Value
                    if ($fixtureValues.ContainsKey($name)) { return [string] $fixtureValues[$name] }
                    return $match.Groups['fallback'].Value
                }) | ConvertFrom-Json
        }
        $beforeHook = & $composeParameters
        Assert-Equal -Actual $beforeHook.parameters.foundryDeploymentsBase64.value -Expected '' `
            -Message 'Initial azd parameter resolution must parse before the hook generates derived values.'
        & (Get-RepoPath 'scripts/set-deployment-tags.ps1') | Out-Null
        $encoded = $fixtureValues.FOUNDRY_DEPLOYMENTS_BASE64
        Assert-Equal -Actual ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))) `
            -Expected $scenario.Expected -Message 'The real hook must encode the exact selected model JSON, defaulting only when absent.'
        if ($null -ne $scenario.Json) {
            Assert-Equal -Actual $fixtureValues.FOUNDRY_DEPLOYMENTS_JSON -Expected $scenario.Json `
                -Message 'Encoding must not overwrite the user-selected source value.'
        }

        $composed = & $composeParameters
        Assert-Equal -Actual $composed.parameters.foundryDeploymentsBase64.value -Expected $encoded `
            -Message 'The actual azd parameter binding must remain parseable with a nonempty JSON array.'
        Assert-True -Condition ($null -eq $composed.parameters.PSObject.Properties['foundryDeploymentsJson']) `
            -Message 'Never interpolate raw quoted model JSON into the azd parameter file.'
        $expression = $graphConfigurationTemplate.resources.aiFoundry.properties.parameters.deployments.value
        $actual = @(Invoke-ArmExpression -Expression $expression -Template $graphConfigurationTemplate `
                -Parameters @{ foundryDeploymentsBase64 = $encoded })
        Assert-Equal -Actual $actual.Count -Expected @($scenario.Expected | ConvertFrom-Json).Count `
            -Message 'The compiled root module must receive the selected number of deployments.'
        if ($scenario.Name -eq 'nonempty') {
            Assert-Equal -Actual $actual[0].name -Expected 'fixture-deployment' -Message 'Deployment aliases must survive.'
            Assert-Equal -Actual $actual[0].capacity -Expected 10 -Message 'Selected capacity must survive.'
            Assert-Equal -Actual $actual[0].sku -Expected 'DataZoneStandard' -Message 'Selected processing SKU must survive.'
        }
    }
}

Test-Case 'direct ARM model JSON parameter remains backward compatible' {
    $expression = $graphConfigurationTemplate.resources.aiFoundry.properties.parameters.deployments.value
    $actual = @(Invoke-ArmExpression -Expression $expression -Template $graphConfigurationTemplate `
            -Parameters @{ foundryDeploymentsBase64 = ''; foundryDeploymentsJson = $syntheticDeployments })
    Assert-Equal -Actual $actual.Count -Expected 1 -Message 'Existing direct ARM JSON callers must retain their model.'
    Assert-Equal -Actual $actual[0].model -Expected 'fixture-model' -Message 'The original direct parameter must still feed Foundry.'
}
