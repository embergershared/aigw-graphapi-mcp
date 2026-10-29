<#
.SYNOPSIS
    Adds Entra users or groups to the operators of the selected azd environment.

.DESCRIPTION
    Operators are the principals in AZURE_OPERATOR_PRINCIPAL_IDS. They receive
    Virtual Machine User Login on the jumpboxes and the data-plane roles on the
    Key Vault and Storage account, so the account that signs in to a jumpbox
    must be one of them, whether or not it is the account that deploys.

    Each principal may be a user principal name, a group display name or an
    object ID. Names are resolved through the Azure CLI, duplicates are
    dropped, and the merged list is written back with azd env set. Nothing is
    deployed: run azd provision afterwards to create the role assignments.

.PARAMETER Principal
    One or more user principal names, group display names or object IDs.

.PARAMETER Environment
    The azd environment. Defaults to the selected one.

.EXAMPLE
    ./scripts/add-operator.ps1 -Principal someone@contoso.com
.EXAMPLE
    ./scripts/add-operator.ps1 -Principal 'Platform Operators', 5d8608e9-fd76-4d76-92ea-06e42c285a08 -Environment sandbox
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string[]] $Principal,

    [string] $Environment
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($command in @('az', 'azd')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found."
    }
}

$environmentArguments = @(if ($Environment) { @('-e', $Environment) } else { @() })

function Resolve-Operator {
    param([Parameter(Mandatory)] [string] $Name)

    $parsed = [Guid]::Empty
    if ([Guid]::TryParseExact($Name, 'D', [ref] $parsed) -and $parsed -ne [Guid]::Empty) {
        return [pscustomobject] @{ Id = $parsed.ToString('D'); Kind = 'object ID'; Name = $Name }
    }

    $userId = & az ad user show --id $Name --query id --output tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($userId)) {
        return [pscustomobject] @{ Id = $userId.Trim(); Kind = 'user'; Name = $Name }
    }

    $groupId = & az ad group show --group $Name --query id --output tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($groupId)) {
        return [pscustomobject] @{ Id = $groupId.Trim(); Kind = 'group'; Name = $Name }
    }

    throw "'$Name' is neither a user principal name, a group display name nor an object ID in the signed-in tenant."
}

$current = (& azd env get-value AZURE_OPERATOR_PRINCIPAL_IDS @environmentArguments 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($current)) {
    $current = ''
}

$ids = [System.Collections.Generic.List[string]]::new()
foreach ($id in $current.Split(',', [StringSplitOptions]::RemoveEmptyEntries)) {
    $trimmed = $id.Trim()
    if ($trimmed -and $trimmed -notin $ids) { $ids.Add($trimmed) }
}

$added = 0
foreach ($name in $Principal) {
    $operator = Resolve-Operator -Name $name
    if ($operator.Id -in $ids) {
        Write-Output "Already an operator: $($operator.Name) ($($operator.Id))."
        continue
    }
    $ids.Add($operator.Id)
    $added++
    Write-Output "Added $($operator.Kind) $($operator.Name) ($($operator.Id))."
}

if ($added -gt 0) {
    & azd env set AZURE_OPERATOR_PRINCIPAL_IDS ($ids -join ',') @environmentArguments
    if ($LASTEXITCODE -ne 0) {
        throw "azd env set failed with exit code $LASTEXITCODE."
    }
}

Write-Output "AZURE_OPERATOR_PRINCIPAL_IDS: $($ids -join ',')"
Write-Output 'Run azd provision to create the role assignments.'
