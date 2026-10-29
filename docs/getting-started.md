# Getting started

Every project made from this template gets the same conventions layer —
deterministic naming, an approved region catalog, a stable subscription code,
common lifecycle tags, `azd` wiring, preflight validation and a test suite that
enforces all of it. Infrastructure beyond that is opt-in.

Start with `core` — a resource group, tags and monitoring — and add exactly the
resources the project needs from the [module catalog](modules.md). Step up to
`private` when the project needs a VNet and private endpoints, or `full` when it
needs a desktop inside that VNet.

## Start here

A new repository made from the template is set up once with
`./scripts/Initialize-Repo.ps1`; see [template.md](template.md).

1. Create your local tenant and subscription files with
   `./scripts/init-local-files.ps1` (`Initialize-Repo.ps1` already did it in its
   clone), then record your tenants in them; see
   [Local tenant and subscription files](deployment.md#local-tenant-and-subscription-files).
   They are gitignored: they name real tenants.
2. Review [prerequisites and required roles](deployment.md#prerequisites-and-roles).
3. Choose a [deployment profile](#choose-a-profile) and, if needed,
   [expert overrides](configuration.md#expert-feature-overrides).
4. Follow the gated [prepare → validate → deploy lifecycle](deployment.md).
5. Add the resources you need from the [module catalog](modules.md).

PowerShell (workstation), in the repository folder:

```powershell
# Variables values
$tenantId = '<tenant-guid>' # must be listed in infra/core/tenant-codes.json
$subscriptionId = '<subscription-guid>'
# Use a lowercase, unique 2-32 character environment name.
$environment = 'my-azd-env-dev'
$location = 'eastus2'
$deploymentProfile = 'core' # core, private, or full

# Commands execution
az login --tenant $tenantId
az account set --subscription $subscriptionId
azd auth login --tenant-id $tenantId
azd env new $environment --subscription $subscriptionId --location $location
azd env set DEPLOYMENT_PROFILE $deploymentProfile
.\scripts\set-deployment-tags.ps1
azd provision --preview -e $environment
```

The `full` profile additionally requires an operator principal, because it
grants VM sign-in rights:

```powershell
azd env set AZURE_OPERATOR_PRINCIPAL_IDS (az ad signed-in-user show --query id --output tsv)
```

It also deploys into resource providers that `core` never touches.
`Microsoft.DevTestLab`, which backs the VM auto-shutdown schedules, is the one
most often unregistered. Preflight names every unregistered provider with the
command that registers it, and registers them itself only when you ask:

```powershell
.\scripts\preflight.ps1 -RegisterProviders
```

Once provisioned, only operators can sign in to a jumpbox, and
`./scripts/connect-jumpbox.ps1` opens a windowed RDP session through Bastion;
see [Bastion access](deployment.md#standard-bastion-access-full-profile-only).

Preview is not deployment. Do not run `azd provision` or `azd up` until the
validation gate and deployment approval are complete.

Run `set-deployment-tags.ps1` once after creating an environment. AZD resolves
required Bicep inputs before `preprovision` hooks run; the script seeds those
first-use values, including the stable subscription code, and the hook refreshes
update metadata on later provisions. When `AZURE_SUBSCRIPTION_ID` is not set,
the script uses the subscription the Azure CLI is signed in to, and both scripts
fail if the Azure CLI and `azd` target different subscriptions. The subscription
code comes from a final `-<N>` display-name token (`-1` gives `s1`), a delimited
`s<N>` token (`Contoso-s2-Sandbox` gives `s2`), or the subscription ID. To
target another tenant or subscription, see
[Deploy to another tenant or subscription](deployment.md#deploy-to-another-tenant-or-subscription).

Environments deployed by an earlier revision with Azure Monitor private link
require the ordered cleanup described in
[deployment migration guidance](deployment.md#migrating-an-environment-that-previously-used-azure-monitor-private-link)
before reprovisioning.

## Choose a profile

Profiles are a cumulative ladder. Each rung adds to the one below it:

| `DEPLOYMENT_PROFILE` | Deploys | Use it when |
|---|---|---|
| `core` *(default)* | Resource group, common tags, Log Analytics, and Application Insights | The project has no networking requirement — the majority of projects |
| `private` | Everything in `core`, plus VNet, subnets and NSGs, private DNS zones, and a private Key Vault and Storage account | The project must be private by default |
| `full` | Everything in `private`, plus Standard Bastion, Windows 11 and Ubuntu jumpboxes, NAT Gateway, Entra VM login, operator RBAC, and VM auto-shutdown | Someone needs a desktop inside the VNet |

`core` deploys no virtual network, no private endpoints, and no private DNS. It
does not force Key Vault or Storage on a project either — those are catalog
modules you opt into.

For combinations between the rungs, use the documented
[expert feature overrides](configuration.md#expert-feature-overrides).
Dependency validation still applies; for example, jumpbox VMs require Bastion,
and Entra VM login requires NAT egress. Moving down the ladder does not delete
anything: see [profiles](configuration.md#profiles) before changing one.

## What is always present

The conventions layer ships with every profile, including `core`:

| Location | What it provides |
|---|---|
| `infra/core/naming.bicep` | Exported naming functions — the single definition of the naming contract |
| `infra/core/tags.bicep` | The exported common-tag function |
| `infra/core/private-endpoint.bicep` | The one private endpoint and DNS pattern every module uses |
| `infra/core/abbreviations.json` | Approved Cloud Adoption Framework resource abbreviations |
| `infra/core/tenant-codes.json` | The approved tenant-code catalog, keyed by Entra tenant ID; gitignored, local to each clone, started from `tenant-codes.example.json` |
| `docs/targets.md` | This clone's tenants, subscriptions and default target; gitignored, local to each clone, started from `targets.example.md` |
| `scripts/init-local-files.ps1` | Creates the two local files above from their examples when they are missing; never overwrites them |
| `infra/core/location-codes.json` | The approved region-code catalog |
| `infra/core/name-rules.json` | Per-resource length, charset and scope rules |
| `scripts/preflight.ps1` | Fail-closed validation before any deployment; `-RegisterProviders` registers missing resource providers on request |
| `scripts/set-deployment-tags.ps1` | Subscription code, lifecycle tags, and override transport |
| `tests/` | The suite that proves names, rules, catalog and profiles are intact |

## Add resources

Resources live in a self-describing catalog under `infra/modules/`. Each module
carries its own `metadata.json`, and preflight's provider list, the private DNS
zone list and the documentation tables are all derived from it.

```powershell
./scripts/new-module.ps1 -Name service-bus -Abbreviation sbns -Provider Microsoft.ServiceBus -ResourceType Microsoft.ServiceBus/namespaces -ApiVersion 2022-10-01-preview
./scripts/add-module.ps1 -Module service-bus    # generate supported wiring; complete printed declarations
./scripts/promote-module.ps1 -From <path>       # bring a proven module back into the catalog
./scripts/adopt-conventions.ps1 -Path <repo>    # push the conventions into an existing repo
```

See [the module catalog](modules.md) for the contract, the current catalog, and
how to author and promote a module.

## Add .NET or Python code

The template carries no application code, only the scaffolding for it. Code goes
under `src/`, one folder per app or package, and tests under `tests/`. CI builds,
lints and tests a stack as soon as the repository has it.

| Stack | Scaffolding | CI runs it when |
|---|---|---|
| .NET | `global.json` (SDK), `Directory.Build.props` (defaults, lock files), `Directory.Packages.props` (central versions), `nuget.config` (approved feed) | a `*.slnx`, `*.sln` or `*.csproj` is tracked |
| Python | `.python-version`, `ruff.toml`, `scripts/lock_requirements.py` (hash-locked `requirements*.lock`) | `requirements-dev.lock` or `requirements.lock` is tracked |

Either way, every locked package must be at least 7 days old
([supply-chain.md](supply-chain.md)), and a database change goes through a
migration, a backup and a way back ([database.md](database.md)).
`scripts/Initialize-Repo.ps1 -Stacks` removes the files of a stack the project
won't use ([template.md](template.md)).

## Test

```powershell
./tests/run-tests.ps1               # the full suite
./scripts/build-catalog.ps1 -Check  # the generated catalog files are current
./scripts/build-docs.ps1 -Check     # the generated doc tables are current
```

The suite proves that resource names have not drifted, that every name obeys its
resource rules, that the catalog is in sync, that all Bicep builds and lints
clean, that every module's dependencies still resolve to well-formed resource
IDs when its optional inputs keep their defaults, and that `core` produces no
`Microsoft.Network` or `Microsoft.Compute` resources. CI also checks that every
Bicep file is formatted (`az bicep format`).

Pull requests that change infrastructure can also be deployed for real before
they merge. Throwaway `core` and `private` environments are previewed,
provisioned, checked and torn down, and `full` is deployed on request. It is
off until you create the deployment identity; see
[pull request deployments](ci-deployment.md).
