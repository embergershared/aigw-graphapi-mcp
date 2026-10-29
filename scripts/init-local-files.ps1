<#
.SYNOPSIS
    Creates this clone's local tenant and subscription files from the committed
    examples.

.DESCRIPTION
    The tenants and subscriptions a clone deploys to identify real tenants, so
    they are gitignored and never committed. Each one has a committed
    `.example` sibling holding neutral placeholder values:

      infra/core/tenant-codes.json   <- infra/core/tenant-codes.example.json
      docs/targets.md                <- docs/targets.example.md

    This script copies each example to its local file when that file is
    missing, and never overwrites an existing one, so it is safe to run again.
    Bicep loads infra/core/tenant-codes.json at compile time: run the script
    once after cloning, then record your own tenants in both files.

.EXAMPLE
    ./scripts/init-local-files.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

$localFiles = [ordered] @{
    'infra/core/tenant-codes.json' = 'infra/core/tenant-codes.example.json'
    'docs/targets.md'              = 'docs/targets.example.md'
}

foreach ($entry in $localFiles.GetEnumerator()) {
    $target = Join-Path $repoRoot $entry.Key
    $example = Join-Path $repoRoot $entry.Value
    if (-not (Test-Path -LiteralPath $example)) {
        throw "Example file '$($entry.Value)' is missing; nothing was created for '$($entry.Key)'."
    }
    if (Test-Path -LiteralPath $target) {
        Write-Output "Kept: $($entry.Key) already exists."
        continue
    }
    if ($PSCmdlet.ShouldProcess($entry.Key, "Create from $($entry.Value)")) {
        Copy-Item -LiteralPath $example -Destination $target
        Write-Output "Created: $($entry.Key) from $($entry.Value). Record your own tenants in it."
    }
}
