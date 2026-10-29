# Pull request deployments

Every pull request that changes infrastructure can be deployed into
throwaway environments before it merges. The workflows preview the change,
deploy it for real, check the result, and always tear it down. A failure in
any of those steps fails the pull request's check.

Nothing runs until you complete the setup below. Until the
`PR_DEPLOYMENT_ENABLED` repository variable is `true`, every job is skipped.
That includes repositories created from this template.

## What runs and when

| Workflow | Runs when | Profiles | Use as a required check |
|---|---|---|---|
| `pr-deployment.yml` | A pull request is opened, pushed to or reopened, and changes `infra/`, `scripts/`, `azure.yaml` or the deployment workflows | `core` and `private`, side by side | Yes: **PR deployment result** |
| `pr-deployment-full.yml` | A pull request with the `deploy-full` label: when the label is added, and on every later push | `full` | No: it is slow and opt-in |
| `pr-deployment.yml`, manual | **Run workflow** on any branch | The one profile you pick | — |
| `pr-deployment-cleanup.yml` | Nightly, or by hand | Removes leftovers older than 6 hours | — |

Each deployment runs these steps in a throwaway azd environment named
`pr<number>-<profile>-<run>-<attempt>`, such as `pr12-private-40-1`:

1. **Approval.** The job waits for a reviewer of the `pr-deployment` GitHub
   environment. Nothing reaches Azure before that.
2. **Create the environment.** It runs `azd env new` and the usual bootstrap.
   It sets `AZURE_KEY_VAULT_PURGE_PROTECTION=false` so the vault can be purged
   on teardown.
3. **What-if.** It runs `azd provision --preview`, which also runs preflight.
   The counts, such as `Resources: 12 to create, 0 to modify, 0 to delete, 1
   unchanged.`, are posted on the pull request as one comment per profile,
   which later runs update in place, and in the run summary. The resources and
   their changes are only in the run log; see [Public logs](#public-logs).
4. **Provision.** It runs `azd provision`.
5. **Check.** `scripts/test-deployment.ps1` confirms that the resource group
   carries the environment's tags, that every resource finished provisioning,
   that every resource the outputs name exists with the expected type, and
   that each jumpbox is running. A `core` deployment must hold no network or
   compute resource. It does not check settings that tenant policy may rewrite,
   such as public network access.
6. **Tear down.** `scripts/remove-ci-environments.ps1` deletes the resource
   group and purges its Key Vault. This step runs even when an earlier step
   failed or the run was cancelled.

The teardown and the nightly cleanup only delete a resource group when its
`repository` tag is this repository and its `azd-env-name` tag matches the
throwaway naming pattern. No other resource group is ever touched.

## Public logs

Anyone can read a public repository's run logs, job summaries and pull request
comments. The workflows follow `.github/instructions/workflows.instructions.md`:

- The tenant, subscription and client IDs, the tenant code and the operator
  IDs are **secrets**, so GitHub masks them in the logs. A repository variable
  would be printed as is.
- Each job that signs in to Azure first runs `.github/actions/mask-values`,
  which also masks each GUID inside those secrets, such as one operator ID out
  of the list.
- The summary and the pull request comment carry the what-if counts only.
- Pull requests from forks get neither the secrets nor an Azure token.

If something leaked, delete the workflow run, which removes its logs and
summary, then rotate what can be rotated.

## Setup

You need rights to create an app registration in the tenant, to assign roles
on the subscription, and to administer the GitHub repository. Run the
commands from a shell where the Azure CLI and the GitHub CLI are signed in.

### 1. Check the target subscription

- Pick the tenant's code. The tenant catalog, `infra/core/tenant-codes.json`,
  is gitignored, so the runner has none: each deployment job writes one that
  holds only `AZURE_TENANT_ID` with the code in `CI_TENANT_CODE` (step 5). Use
  the code your own catalog gives the tenant, so the throwaway resources are
  named like your other environments.
- Register the resource providers once. The workflow never registers them:

  ```powershell
  azd env new ci-setup --subscription <subscription-guid> --location eastus2
  azd env set DEPLOYMENT_PROFILE full
  ./scripts/set-deployment-tags.ps1
  ./scripts/preflight.ps1 -RegisterProviders
  ```

- For `full`, make sure the region has quota for 6 DSv5 vCPUs and that the
  subscription can deploy the Windows 11 Pro image.

### 2. Create the deployment identity

```powershell
$app = az ad app create --display-name 'gh-<repository>-pr-deployment' | ConvertFrom-Json
$sp = az ad sp create --id $app.appId | ConvertFrom-Json
```

Add two federated credentials. The first trusts deployment jobs, which always
run in the `pr-deployment` GitHub environment. The second trusts the nightly
cleanup, which runs on `main`:

```powershell
$repo = gh repo view --json nameWithOwner --jq .nameWithOwner
foreach ($credential in @(
        @{ name = 'pr-deployment'; subject = "repo:${repo}:environment:pr-deployment" }
        @{ name = 'pr-deployment-cleanup'; subject = "repo:${repo}:ref:refs/heads/main" })) {
    $credential.issuer = 'https://token.actions.githubusercontent.com'
    $credential.audiences = @('api://AzureADTokenExchange')
    $credential | ConvertTo-Json | Set-Content fic.json
    az ad app federated-credential create --id $app.appId --parameters '@fic.json'
}
Remove-Item fic.json
```

No client secret is created. GitHub stores the IDs as secrets only so its
public logs mask them.

### 3. Grant it roles on the subscription

`core` and `private` need only **Contributor**, which also lets the teardown
purge Key Vaults:

```powershell
az role assignment create --assignee-object-id $sp.id --assignee-principal-type ServicePrincipal `
    --role Contributor --scope /subscriptions/<subscription-guid>
```

`full` grants operators **Virtual Machine User Login**, so the identity also
needs to create role assignments. Grant **Role Based Access Control
Administrator**, constrained to the four roles this template assigns:

```powershell
$roles = '4633458b-17de-408a-b874-0445c86b69e6, ba92f5b4-2d11-453d-a403-e96b0029c9fe, 0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb, fb879df8-f326-4884-b1cf-06f3ad86be52'
$condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roles})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roles}))"
az role assignment create --assignee-object-id $sp.id --assignee-principal-type ServicePrincipal `
    --role 'Role Based Access Control Administrator' --scope /subscriptions/<subscription-guid> `
    --condition $condition --condition-version 2.0
```

Then set `CI_OPERATOR_PRINCIPAL_IDS` to the identity's own object ID in
step 5, so the deployment has an operator to grant. If you would rather not
grant this role, set `CI_FEATURE_OVERRIDES_JSON` to
`{"roleAssignments":false}` instead.

### 4. Create the GitHub environment and label

The `pr-deployment` environment holds the approval gate. Add yourself, or a
team, as a required reviewer:

```powershell
$reviewer = gh api user --jq .id
@{ reviewers = @(@{ type = 'User'; id = [int] $reviewer }) } | ConvertTo-Json -Depth 3 |
    gh api --method PUT "repos/$repo/environments/pr-deployment" --input -
gh label create deploy-full --description 'Deploy the full profile for this pull request' --color B60205
```

Leave the environment's deployment branches unrestricted. Pull request runs
use the `refs/pull/<n>/merge` ref, which a branch policy would block.

### 5. Set the repository secrets and variables

Identifiers are repository **secrets**, so the public logs mask them. Only the
on/off switch, the region and the overrides are **variables**.

| Name | Kind | Value | Required |
|---|---|---|---|
| `AZURE_CLIENT_ID` | Secret | The app registration's client ID | Yes |
| `AZURE_TENANT_ID` | Secret | The tenant GUID | Yes |
| `AZURE_SUBSCRIPTION_ID` | Secret | The target subscription GUID | Yes |
| `CI_TENANT_CODE` | Secret | The tenant's code, 2-12 lowercase letters and digits, as in your `infra/core/tenant-codes.json` | Yes |
| `CI_OPERATOR_PRINCIPAL_IDS` | Secret | Comma-separated operator object IDs for the deployed environments, normally the identity's own | For `full` with role assignments |
| `PR_DEPLOYMENT_ENABLED` | Variable | `true` turns the workflows on; anything else keeps them skipped | Yes |
| `AZURE_LOCATION` | Variable | The region; defaults to `eastus2` | No |
| `CI_FEATURE_OVERRIDES_JSON` | Variable | Expert overrides applied to every run, such as `{"roleAssignments":false}` | No |

`gh secret set` reads the value from the pipeline, so it never sits on a
command line. Set the switch last:

```powershell
'<tenant-guid>' | gh secret set AZURE_TENANT_ID
'<subscription-guid>' | gh secret set AZURE_SUBSCRIPTION_ID
'<tenant-code>' | gh secret set CI_TENANT_CODE
$sp.id | gh secret set CI_OPERATOR_PRINCIPAL_IDS
$app.appId | gh secret set AZURE_CLIENT_ID
gh variable set PR_DEPLOYMENT_ENABLED --body true
```

If you set these up before the IDs became secrets, delete the old variables:

```powershell
'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'CI_TENANT_CODE', 'CI_OPERATOR_PRINCIPAL_IDS' |
    ForEach-Object { gh variable delete $_ }
```

### 6. Make the check block merges

Add **PR deployment result** to the required checks of the `main` ruleset,
next to **CI result** and **PR rules** ([ci-cd.md](ci-cd.md#repository-settings)).
It always reports, even for a pull request that changes no infrastructure, so
requiring it never leaves a pull request waiting:

```powershell
$id = gh api "repos/$repo/rulesets" --jq '.[] | select(.name == "main") | .id'
$ruleset = gh api "repos/$repo/rulesets/$id" | ConvertFrom-Json
$checks = ($ruleset.rules | Where-Object type -eq 'required_status_checks').parameters
$checks.required_status_checks += [pscustomobject] @{ context = 'PR deployment result'; integration_id = 15368 }
$ruleset | Select-Object name, target, enforcement, conditions, rules, bypass_actors |
    ConvertTo-Json -Depth 10 | gh api --method PUT "repos/$repo/rulesets/$id" --input -
```

## Using it

- Open a pull request that changes infrastructure, then approve the waiting
  `core` and `private` jobs. The what-if comments appear first. The check
  turns green once both environments deployed, passed the checks and were
  torn down.
- Add the `deploy-full` label to also deploy `full`. Remove the label to stop
  deploying it on later pushes.
- To deploy a branch without a pull request, run **PR deployment** from the
  Actions tab and pick the profile:

  ```powershell
  gh workflow run pr-deployment.yml --ref <branch> -f profile=full
  ```

- Pull requests from forks are never deployed, because they never receive
  Azure credentials. Their result check passes with a note. Review the change
  and deploy it from a branch in this repository instead.

## Cost and time

Each run deploys real resources for as long as the run lasts. `core` and
`private` take a few minutes each. `full` takes the longest, because
Standard Bastion alone takes several minutes to create and to delete. While
it runs it bills for Bastion, NAT Gateway, both VMs and the private endpoints.
That is why it runs only on request.

Concurrent runs for the same pull request and profile queue instead of
cancelling each other, because a cancelled run would skip its teardown.

## When something is left behind

A teardown can fail, or a runner can be lost mid-run. The nightly
**PR deployment cleanup** removes every throwaway environment of this
repository created more than 6 hours ago. To clean up at once, run it from the
Actions tab with a smaller age, or by hand:

```powershell
./scripts/remove-ci-environments.ps1 -SubscriptionId <subscription-guid> -Repository <owner>/<repo> -OlderThanHours 0 -WhatIf
```

Drop `-WhatIf` to delete. The script reports a Key Vault created with purge
protection and leaves it to expire, because purge protection cannot be
bypassed.
