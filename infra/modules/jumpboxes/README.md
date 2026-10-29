# jumpboxes

Optional Windows 11 and Ubuntu developer desktops inside the virtual network.

| | |
|---|---|
| Kind | `composite` |
| Profiles | `full` |
| Abbreviation | `vm-win`, `vm-lin` |
| Providers | `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.DevTestLab` |
| Private endpoint | none |
| Feature flag | `windowsVm`, `linuxVm` |

## Purpose

A desktop inside the perimeter, for the cases where a private endpoint is only
reachable from within the virtual network.

Neither virtual machine receives a public IP address. Access is via Azure
Bastion only.

## Dependency rules

These rules are enforced by `scripts/preflight.ps1` and by the module itself:

- a jumpbox requires `bastion`, otherwise it is unreachable
- `entraLogin` requires a virtual machine and requires `natGateway` for egress
- `shutdownSchedules` requires a virtual machine

`Microsoft.DevTestLab` is needed only by the auto-shutdown schedules, so
preflight drops it from the registration check when `shutdownSchedules` is
false. It is the provider most often unregistered in a subscription; see
[resource providers](../../../docs/deployment.md#resource-providers).

## Credentials

Administrator passwords are generated with `newGuid()` in the `key-vault`
module and written to Key Vault. They are never emitted as template outputs and
never written to `.azure` state. `credentialRotationTag` forces regeneration
when it changes.

## Access

Only operators can use Entra login: the module grants **Virtual Machine User
Login** to `operatorPrincipalIds`, and an account without it hangs at the
second RDP credential prompt. `scripts/add-operator.ps1` adds people or groups
by name, and `scripts/connect-jumpbox.ps1` opens a windowed RDP session
through Bastion. See
[Bastion access](../../../docs/deployment.md#standard-bastion-access-full-profile-only).

## Parameters

Selected parameters; see `main.bicep` for the full list.

| Name | Type | Required | Notes |
|---|---|---|---|
| `windowsVmName`, `windowsComputerName`, `windowsNicName` | string | yes | `windowsComputerName` obeys the 15 character NetBIOS limit |
| `linuxVmName`, `linuxNicName` | string | yes | |
| `jumpboxSubnetId` | string | yes | From the `network` module |
| `deployWindowsVm`, `deployLinuxVm` | bool | no | Default `false` |
| `windowsVmSize`, `linuxVmSize` | string | no | `Standard_D4s_v5` / `Standard_D2s_v5` |
| `windowsImage`, `linuxImage` | object | yes | Publisher/offer/sku/version |
| `enableEntraLogin` | bool | no | Requires egress |
| `enableShutdownSchedules` | bool | no | Default `true` |
| `shutdownTime`, `shutdownTimeZone` | string | no | `1900`, Eastern Standard Time |
| `operatorPrincipalIds` | array | no | Granted Virtual Machine User Login |

## Outputs

| Name | Notes |
|---|---|
| `windowsVmName` | Empty string when not deployed |
| `linuxVmName` | Empty string when not deployed |
