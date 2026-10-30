# Deployment plan

This is the project's deployment contract. `azure-prepare` fills it in,
`azure-validate` records evidence against it, and `azure-deploy` changes Azure
only after the approval below is recorded. Keep it aligned with `README.md`,
`docs/`, `azure.yaml`, the hooks and the Bicep.

Status: **Deployed and verified - approved initial resource-only stage.
The supported omission correction completed normal azd/Bicep provisioning;
overall ARM deployment and actual APIM logger/diagnostic operations Succeeded.
Both earlier failures remain recorded. Resources are billable; no rollback
occurred. Explicit security restrictions are retained.
The exact selected local target/model and `core` overrides still enable APIM,
Foundry and Key Vault, with Graph MCP and role assignments disabled.
Validation and existing recovery approval cover this resource-only stage, not
the later Graph/OAuth/runtime stage. A subsequent, separately approved
registrations/service-principals-only step is recorded below; it does not
activate the gateway or authorize credentials, consent or role grants.
No end-to-end Graph/MCP integration success is claimed.**

## Target

| Item | Value |
|---|---|
| azd environment | `<environment>` |
| Tenant | `<tenant name>` (`<tenant-guid>`), listed in `infra/core/tenant-codes.json` |
| Subscription | `<subscription name>` (`<subscription-guid>`), code `s<N>` |
| Region | `<region>` (`<location code>`) |
| Deployment profile | `core`; retain existing `private` and `full` defaults |
| Feature overrides | Explicit `apiManagement`, `aiFoundry`, `keyVault` opt-ins |
| Catalog modules | API Management, existing Foundry and Key Vault modules |

Actual target identifiers and publisher contact details remain only in ignored
local configuration, never in this public contract. All new Azure workload
resources belong to one dedicated environment resource group through the
existing subscription-scope Bicep composition; do not reuse unrelated demo
accounts, projects or model deployments.

## Decisions

Record each decision with its date, who approved it, and the alternatives and
consequences considered. A later decision supersedes an earlier one explicitly;
do not rewrite history.

- 2026-10-29, user: public Entra-protected HTTPS PoC, APIM Developer (fixed idle
  charge, no production SLA), Foundry prompt agent and native Streamable HTTP
  MCP. Native management API `2025-09-01-preview` is explicitly accepted.
- 2026-10-29, user: signed-in-user read-only mail/calendar, delegated `Mail.Read`
  and `Calendars.Read`, including message bodies and event details. Four tools:
  `list_messages`, `get_message`, `list_calendar_view`, `get_event`.
  No writes, app permissions, shared mailboxes, arbitrary proxy, custom MCP
  process, Functions, containers, toolbox, hosted agent app or private network.
- 2026-10-29, implementation decision: list default 10, maximum 25 (reject, never
  clamp). These are proposed implementation defaults, not separately
  user-confirmed choices. Calendar start/end require explicit offsets and
  positive duration.
- 2026-10-29, user: calendar queries may span at most 31 days.
- 2026-10-29, implementation: metadata-only message lists use fixed fields.
  Continuations are untrusted, user/operation-bound opaque envelopes, revalidated
  against the fixed Graph host, `/me` path, fields and page bounds every time.
  Never invent or increment a Graph `$skip`.
- 2026-10-29, implementation: successful detail JSON is limited to 65,536 UTF-8
  bytes; list JSON to 131,072 bytes. An oversized payload fails explicitly and
  is never silently truncated. Native MCP streaming bodies are never inspected.
- 2026-10-29, user: both REST and MCP validate tenant-specific v2 gateway tokens,
  delegated `access_as_user` and approved clients. OBO alone exchanges the
  validated assertion for Graph; no shared tokens or managed-identity substitute.
  Key Vault protects the confidential credential; no token/payload caching.
- 2026-10-29, user: Foundry custom OAuth targets our gateway audience with
  `offline_access` and exact returned callback. Four-tool allowlist and approval
  on every call; OAuth consent and MCP approval are separate interactions.
- 2026-10-29, user: preparation is approved, **not** provisioning, provider
  registration, app/credential/consent/RBAC changes, models or destructive cleanup.
  Target, exact model/version/SKU/capacity, costs, budget, publisher and synthetic
  mailbox users still require decisions and separate approvals.
- 2026-10-29, subsequent user selections: target context, local environment and
  publisher are configured privately. Model `gpt-5.4-mini`, version `2026-03-17`,
  `DataZoneStandard`, capacity 10 is selected for US-zone processing, not
  region-only processing. This is pay-per-token allocation, not reserved PTUs.
- 2026-10-29, subsequent user direction: deploy all new Azure workload resources
  into their own single resource group using this repository's azd/Bicep
  structure. The first stage uses `core` with `apiManagement`, `aiFoundry` and
  `keyVault` true, `graphMcp` and `roleAssignments` false. Entra apps,
  credentials, consent and API enablement remain separately gated. The budget
  question was skipped: no monthly ceiling or budget resource is inferred.
  Complete validation and obtain scoped preview approval before provisioning.

## Independent preparation review

2026-10-29: an independent design reviewer identified fixed-field enforcement,
continuation parameter conflicts, real Graph next-link shape, native REST
outbound-policy execution, and platform diagnostics as material risks.
The implementation fixes field values as well as query names, rejects
continuation/initial-argument mixing and unexpected paths, and disables
payload/header diagnostics. Actual policy-expression tests cover these offline;
live MCP oversize/auth tests remain mandatory. If native policy propagation
fails, stop; do not buffer native streaming responses or substitute architecture.
Offline tests cannot establish APIM's runtime behavior or real next-link shape.

## Public exceptions and risks

- APIM and Foundry are public for the approved PoC; both REST and native MCP
  require Entra. Subscription keys are not an authentication substitute.
- Vault firewall remains deny-by-default with trusted-service integration and
  secret-scoped APIM identity RBAC. Operator firewall exceptions require separate
  approval/removal. Restrict policy-edit/debug/trace access.
- Never log/cache assertions, credentials, Authorization, consent URLs or mailbox
  payloads. Foundry conversations can retain content even when APIM body logs are
  off; use synthetic mail/calendar fixtures and review retention before real data.
- Mailbox text is untrusted data, not instructions. Do not follow embedded links.
- APIM Developer illustrative public retail price queried 2026-10-29:
  USD 0.0658/hour, about USD 48.03/730 hours in example regions. This selects no
  region and excludes model tokens, Key Vault, monitoring, bandwidth, tax and
  account terms. A Log Analytics daily cap is not a spending cap.

## Validation checklist

All checks must pass before a deployment. A passing PR or offline test run does
not waive any of them.

For the initial resource-only stage, infrastructure validation applies to the
explicit Graph-disabled composition. The live REST/MCP/Graph/Foundry acceptance
items below remain later API-stage gates; they are not claimed complete or
required to prove runtime behavior of APIs that have not yet been enabled.

- [x] All initial resource-stage validation checks pass (`azure-validate`, azd/Bicep recipe).
  - [x] 1. AZD installation: `azd version` completed.
  - [x] 2. Schema validation: Azure MCP validated `azure.yaml` against the stable schema.
  - [x] 3. Environment setup: selected local context/model/publisher and explicit first-stage flags verified through azd, without dumping private environment files.
  - [x] 4. Authentication check: ordinary user-approved tenant-specific azd sign-in succeeded; actual selected-target preview succeeded.
  - [x] 5. Subscription/location check: selected target is Enabled in AzureCloud, already active in Azure CLI; approved local tenant naming mapping and actual azd target access are verified.
  - [x] 6. Aspire pre-provisioning: not applicable; no Aspire host.
  - [x] 7. Provision preview: actual scoped azd preview passed, eight friendly Create rows including the selected model, no Modify/Delete; real selected-stage preflight passed.
  - [x] 8. Build verification: Bicep compile/lint and clean .NET build passed.
  - [x] 9. Docker build context: not applicable; no hosted service/container.
  - [x] 10. Package validation: not applicable; infrastructure-only native MCP.
  - [x] 11. Azure Policy validation: prior scoped policy/provider/permission/quota evidence recorded privately; actual composed preview and read-only preflight passed.
  - [x] 12. Aspire post-provisioning: not applicable; no Aspire host.
- [x] Run the completed-change PowerShell suite, with CI-shell exclusions below.
- [x] Record the environment-specific evidence below; exact names/identifiers remain in ignored local evidence.
- [x] Run catalog/docs freshness, PowerShell AST, JSON/OpenAPI/XML and .NET checks.
- [x] Verify offline four-GET OpenAPI definitions and full ARM MCP operation bindings.
- [ ] Verify exactly four read-only MCP schemas and full ARM operation bindings.
- [ ] Verify REST **and MCP** reject missing/expired/wrong issuer/audience/client,
  app-only and insufficient-scope tokens.
- [ ] Verify native initialize, initialized notification, tools/list and tools/call
  over Streamable HTTP; real header propagation and REST outbound-size enforcement.
- [ ] Verify OBO downstream consent and actionable Conditional Access errors.
- [ ] Verify two licensed same-tenant users cannot cross tokens, cursors, IDs,
  conversations or approvals.
- [ ] Verify paging, sizes 1/10/25, empty results, offset/recurrence/31-day
  boundaries, exact byte limits, oversize, throttling, malformed and timeout errors.
- [ ] Verify actual named Foundry tool calls, consent accept/reject, approval
  deny/continue, expiry and reauthentication against synthetic fixtures.
- [x] Verify resource/tag/output state, disabled opt-ins and idempotent resource-stage recovery.

## Controlled live sequence and recovery

Use the privately selected target/model/publisher and approved local tenant
naming mapping; select synthetic test identities when their stage is due.
No budget ceiling is approved. Verify context, region, policy, providers, quota
and roles; review costs and azd preview through
`azure-validate`. Obtain separate infrastructure approval before `azure-deploy`.
Obtain separate
Entra/credential/consent approval before identity bootstrap and secret population.
Test direct REST/MCP with the public PKCE client, then configure the approved
Foundry model/OAuth/agent and actual returned callback. Never invent application
packaging for this infrastructure-only native MCP deployment.

Keep previous API revisions/policies/tool definitions and agent version for
non-destructive rollback. Connection disable, user revocation, credential rotation
and versionless Key Vault refresh require operational authority. Teardown requires
separate approval and an inventory of owned RG resources **and** tenant apps,
grants and conversations; Key Vault retention/purge caveats still apply.

## Approval

- 2026-10-29: user approved offline code preparation only. No live operation
  or target has been approved.
- 2026-10-29, subsequent approvals: selected target/environment/model and
  publisher configuration are persisted locally. User requested deployment
  into one dedicated resource group; the required resource-only stage
  validation/preview is being prepared. No provisioning has occurred and no
  preview result has yet been approved. Tenant naming code is approved locally;
  azd target reauthentication and the staged resource preview succeeded. Separate
  Entra, credential, consent, role-grant and live-user gates are unchanged.
- 2026-10-29, subsequent explicit user approval: provision the validated initial
  resource-only preview, eight creates and no modifications/deletions in one
  new dedicated resource group. Developer APIM, the selected new Foundry
  account/project/model, Standard Key Vault and monitoring become billable.
  The illustrative USD 52.61 monthly component estimate is not a spending cap.
  Graph/MCP activation, identity apps, credentials, consent and role grants
  are excluded.

## Validation Proof

Record each validation or deployment run: the date, the environment, the
commands run, and the result. Never record secrets or `.env` contents.

### 2026-10-29: offline preparation, isolated checkout

No Azure/Entra target or mailbox was used. All identity/app/credential/provider
mutations in regression tests used synthetic mocked transports, never live
credentials. All new packages came through the approved NuGet feed.

| Actual command/check | Completed result |
|---|---|
| `azd version` | Installed, 1.37.2 stable |
| Azure MCP `validate_azure_yaml` for the checkout's `azure.yaml` | Valid against the official stable schema; no Azure account access |
| `./tests/run-tests.ps1` | 123 cases passed, 0 failures; includes all Bicep build/lint, profile/naming/catalog/module/adoption cases and actual C# 7.3 policy expressions |
| `./tests/run-tests.ps1 -Name graph-policy` | Passed; final full run contains 8 policy cases covering byte/31-day/offset bounds, forged cursors/IDs, OBO classification and sanitized on-error |
| `./tests/run-tests.ps1 -Name graph-identity` | 6 passed, including mocked owned-app convergence/callback preservation, no consent/password calls, and no existing-credential reset |
| `./scripts/build-catalog.ps1 -Check` | Passed; generated catalog/DNS files current |
| `./scripts/build-docs.ps1 -Check` | Passed; generated module table current |
| `az bicep build --file infra/main.bicep --stdout` | Passed; all module builds/lint also passed in the full suite |
| `az bicep format --file <changed-file> --stdout` | Root and API Management module matched their checked-in formatting |
| PowerShell parser AST over `scripts/` and `tests/` | Passed; changed scripts parsed before execution |
| `ConvertFrom-Json` / `[xml]` over nonignored repository JSON/XML/project files | 36 parsed successfully; module tests check the four-GET/limit contract; final recursive OpenAPI check resolved all 34 local references |
| `dotnet restore GraphMcp.slnx --locked-mode --verbosity minimal` | Passed using the approved feed and generated lockfiles |
| `dotnet clean GraphMcp.slnx --verbosity minimal` | Passed |
| `dotnet build GraphMcp.slnx --no-restore --verbosity minimal -warnaserror` | Passed, 0 warnings/errors |
| `dotnet test GraphMcp.slnx --no-build --no-restore --verbosity minimal` | 180 passed, 0 skipped |
| `dotnet format GraphMcp.slnx --no-restore --verify-no-changes --verbosity minimal` | Passed |
| Inline PowerShell approved-feed registration audit of both new lockfiles | All 37 unique direct/transitive versions met the 7-day age gate; unlike tracked-file-only discovery, this explicitly included the new untracked lockfiles |
| `dotnet run --project src/GraphMcp.TestClient --no-build --no-restore -- offline` | Running client reported `validated_no_network`, exactly four tools and the bounded byte contract |
| Default `configure-graph-identity.ps1` / `set-graph-credential.ps1` with environment `synthetic` | Preparation only; no auth/network, consent or credentials |
| SDK `definition` smoke with explicit synthetic endpoint/configuration | Usable gitignored SDK JSON preview produced; no live agent mutation/apply mode |
| `git diff --check` | Passed |

Final changed-script AST check parsed all 14 modified/new PowerShell files
successfully. Catalog/docs freshness and whitespace checks were repeated after
the final implementation edits.

The `azure-validate` workflow was started normally and its azd recipe added
above. It remains at `AddValidationSteps`, before `RunValidation`: environment,
authentication, target context, preview and effective Azure policy are
intentionally unverified. Its local progress file is gitignored. The plan is
**not** `Validated`, and `azure-deploy` was not invoked.

The full PowerShell runner reports three CI-shell cases as passing after warning
and returning early: masking action execution, PR branch-rule execution and
tracked-stack detection. Their Bash bodies were **not executed** on this host
because Git-for-Windows Bash is unavailable. A WSL Bash shim on PATH is not a
Windows-path-compatible replacement. Existing CI must execute these on its
supported runner; no tool installation or permission bypass was attempted.

An earlier full run exposed five adopted-hook failures caused by preflight's
new validator not being copied. Added the dependency to convention adoption;
the completed-change full rerun passed all 123 cases. Earlier harness/bootstrap
errors were corrected before these final results; no failed check is claimed
as passing.

### Remaining live gates - not executed

- Approve the successful exact resource-stage preview before provisioning the
  dedicated resource group/resources. Context/model/publisher/naming are selected
  privately; no budget amount was approved. Two licensed same-tenant synthetic
  users and project access remain later acceptance-stage inputs.
- Complete target preflight/preview after the scoped read-only context,
  policy/provider/quota/lifecycle/management-permission checks. Entra
  app-management, downstream delegated-consent and vault data access are still
  separate authority gates.
- Review current target-specific recurring/idle costs and approve public,
  preview, secret lifecycle and mailbox/conversation data handling.
- Run real preflight/azd preview only after target selection; obtain separate
  infrastructure and Entra/credential/consent approvals before their mutations.
- Configure the supported encrypted custom OAuth connection, its exact returned
  callback and trusted consent route; review/apply and pin the agent definition.
- Execute the entire REST/native MCP/Graph/Foundry/two-user/fault acceptance
  matrix above under separate user authorization. Runtime native forwarding,
  backing-policy size enforcement and actual Graph paging remain unproven.

No issue, PR, commit, Azure provision/model/provider operation, Entra mutation,
consent grant, credential creation or destructive cleanup was performed.

### 2026-10-29: selected-target readiness, before resource-stage preview

Read-only queries used the explicitly selected subscription. Existing providers
were registered; scoped policy review found no applicable location or
APIM/Foundry restriction. Selected model catalogue, quota, lifecycle and token
prices were checked. Advertised management permissions cover the proposed
resource writes; they do not prove Entra/admin-consent or data-plane authority.
The selected subscription is already active; no global CLI default was changed.

The approved local azd environment stores context, exact model JSON and
publisher fields. Only intended keys were read back, with publisher values
withheld. Resource-stage flags are explicit and leave Graph APIs/native MCP
tools, credential references and role assignments disabled. The existing
`Get-TenantCode` helper now verifies the exact approved local mapping; all other
catalogue entries are unchanged. No code was invented or private catalogue
dumped. Public naming
rules allow empty legacy omission or 2-12 lowercase letters/digits; the committed
example uses a fictitious tenant and code `123456`.

The dated illustrative component subtotal is USD 52.61 for 730 Developer unit
hours, 100 synthetic agent turns aggregating 1 million uncached input tokens
and 200,000 total output tokens including reasoning, 1,000 Standard Key Vault
operations and 1 GB of billable monthly Analytics ingestion. This uses actual
module defaults: one Developer unit, Standard vault, shared workspace-based
Application Insights, 30-day retention and a 1 GB/day ingestion cap. No shared
free allowance or cache discount is assumed. Native platform metrics and direct
diagnostic routing to Log Analytics are not charged again as unrelated export
meters. Actual traffic, repeated rounds, background ingestion, egress, additional
features, taxes and account terms are not bounded; this is neither a quote nor
a ceiling. The skipped budget question remains unapproved.

Exact evidence, rate filters, arithmetic and live gates are in ignored
`.azure/cost-prepreview.local.json` and the existing target/model readiness
files. No sensitive identifiers or contact values belong in this document.
The first authorized `azd provision --preview` command exited 1 during provisioning
manager initialization, while fetching the current principal and resolving
selected-subscription access. It never reached resource evaluation or hooks.
Cached azd login was insufficient; normal tenant-specific azd reauthentication
was then completed through the normal approved sign-in. No alternate deployment provider, fake principal ID, global-default
change or silent sign-in bypass was attempted. Exact original output remains
in ignored `.azure/resource-stage-preview.local.log`; sanitized diagnosis and
helper-verified regional names are in the matching `.local.json`.

The next preview exposed unescaped quoted model JSON in the azd parameter
binding. The correction follows the existing feature-override transport:
the tag hook derives `FOUNDRY_DEPLOYMENTS_BASE64` and Bicep decodes it, retaining
the direct ARM JSON parameter when the encoded parameter is empty. A further
attempt established azd resolves required inputs before hooks, as the deployment
runbook already documents. The existing local tag bootstrap seeded the missing
subscription code/repository/timestamps and both exact encoded selections.
No guards, naming inputs or selected model values were weakened or replaced.

| Actual new command/check | Completed result |
|---|---|
| `azd auth login --tenant-id <selected-tenant>` | Passed through ordinary user-approved sign-in; no logout or CLI-default changes |
| `./tests/run-tests.ps1 -Name graph-configuration` | 4 passed, 0 failed: missing/empty/nonempty arrays, actual hook and pre/post-hook JSON composition, compiled decoding and direct ARM compatibility |
| PowerShell parser AST for changed tag hook and regression | Passed before execution |
| `az bicep format --file infra/main.bicep` | Passed |
| Root Bicep compile through `Get-CompiledTemplate` and `az bicep lint --file infra/main.bicep` | Passed |
| `./scripts/set-deployment-tags.ps1` | Passed; local bootstrap generated required metadata and encoded values; source model/overrides preserved |
| `azd provision --preview --environment <selected> --subscription <selected> --location <selected> --no-prompt --output json` | Passed; eight azd friendly Create rows, no Modify/Delete, including the selected model; no actual resource provisioning |
| `./scripts/preflight.ps1` without registration switch | Passed for actual selected stage; no provider registration |
| Existing helper/rule comparison against actual preview names | Passed for regional and global resources; actual deterministic suffix, no approved-code shortening |
| Actual encoded model plus compiled root/nested binding | Exactly one `gpt-5.4-mini`, version `2026-03-17`, `DataZoneStandard`, capacity 10, `NoAutoUpgrade`; actual preview contains that model alias |
| Static compiled feature and role-condition review | Only monitoring/APIM/Foundry/Key Vault modules on; Graph/network/storage/VM/NAT/Bastion and role assignments off |

The friendly preview reports no property deltas for creates. It confirms the
nonempty selected model deployment, while exact version/SKU/capacity proof comes
from the actual encoded parameter readback and compiled root/nested bindings;
do not misstate those as independently echoed ARM property deltas. Counts refer
to azd's actual resource summary, not exhaustive diagnostic/configuration child
or nested ARM deployment counts.

Exact resources/names and original preview output are in ignored
`.azure/resource-stage-validation.local.json` and
`.azure/resource-stage-preview-seeded.local.log`. Prior failed attempts remain
preserved. The actual scoped preview is not permission to provision; no
resources, provider registrations, role grants, apps, credentials or consent
have changed. The azure-validate recipe, build, static-role, proof and
error-resolution steps are complete; the workflow instructed updating this
status only after those checks passed. Obtain scoped provisioning approval
before the azure-deploy resource step. Prior unrelated offline suites are reused.

### 2026-10-29: approved initial provisioning failed; partial resources exist

The user explicitly approved the exact validated resource preview. Immediately
before the change, selected context, source/encoded model and feature settings,
tenant naming mapping, completed validation state and the absence of the new
target resource group were verified. The ordinary scoped `azd provision`
command completed with exit 1; original output remains
in ignored `.azure/resource-stage-provision.local.log`.

The resource group, monitoring, new Foundry account/project/model and vault have
reported successful creation. An independent scoped live model read already
confirms `Succeeded`, `gpt-5.4-mini` version `2026-03-17`,
`DataZoneStandard`, capacity 10 and `NoAutoUpgrade`. The main APIM service also
reached `Succeeded`, Developer capacity 1. The actual failed nested ARM operation
is `Microsoft.ApiManagement/service/loggers`, child `azuremonitor`, with
`ValidationError`: credentials did not contain an expected connection method.
No custom logger or all-APIs diagnostic persisted, and normal azd outputs were
not populated because the overall deployment failed. The main resources remain
potentially billable; no destructive rollback was attempted.

The live inventory also contains the platform-created Application Insights
Failure Anomalies smart-detector alert rule in the same dedicated resource
group, not an additional user-configured workload. It was absent from azd's
friendly preview rows. It is not deleted or treated as a cost cap; notification
or alert usage costs are not established by the original illustrative estimate.

Recovery retains the approved monitoring/privacy/identity scope: reference
`/loggers/azuremonitor` directly as documented by the current diagnostic REST
contract, rather than provisioning a credentialed custom logger. No credential,
monitoring role or new destination is added. Zero sampling, body bytes, headers,
client-IP logging and metrics-only routing remain unchanged. The Microsoft
Learn MCP initially was unavailable, so official Learn pages were read directly;
the restored MCP subsequently confirmed the diagnostic contract. Targeted
regressions, Bicep validation and an actual non-destructive azd preview must pass
before the normal idempotent provisioning retry. New roles/secrets, replacements,
additional billable scope or another material design change require approval.

The first recovery preview passed with zero creates, six modifies, two unchanged
and zero resource deletes/replacements, but revealed exposure deltas that were
**not applied**. Live metadata confirms vault public network access and APIM's
legacy portal are Disabled. The old no-private-endpoint vault payload explicitly
requested Enabled, so that difference was not dismissed as harmless noise.
The gateway composition now explicitly keeps vault public access Disabled,
without adding a private endpoint or changing Deny/AzureServices/empty allowlists.
Direct module callers retain their existing default. Current Key Vault network
guidance explicitly states trusted-service bypass also applies with public access
Disabled; actual APIM secret retrieval remains separately gated and untested.

APIM's supported legacy-portal and insecure protocol/cipher settings are now
explicitly disabled. The omitted HTTP/2 value has a documented False default;
NAT Disabled versus Unsupported is service/default metadata and introduces no
NAT resource. Foundry associated/default-project metadata, project endpoints and
internal identifiers, and model current-capacity fields are server-maintained,
not requested deletions of those resources. Exact model/SKU/version/capacity and
NoAutoUpgrade remain explicitly configured. The corrected preview must confirm
no public-access, legacy-portal or insecure-protocol enablement before recovery.

### 2026-10-29: same-scope recovery validation

| Actual command/check | Completed result |
|---|---|
| PowerShell parser AST for `tests/modules/api-management.tests.ps1` | Passed before execution |
| `./tests/run-tests.ps1 -Name api-management` | 9 passed, 0 failed; includes built-in logger reference/no custom credentialed logger, zero diagnostics, explicit APIM security restrictions, composed vault restrictions and direct-module compatibility |
| `./tests/run-tests.ps1 -Name bicep` | 13 passed, 0 failed; all Bicep compile/lint, profile ladder, module dependencies and role/purge-protection controls |
| `az bicep format --file <changed-bicep>` and `az bicep lint --file infra/main.bicep` | Passed |
| `./scripts/preflight.ps1` | Passed for the actual selected stage, without provider registration |
| `azd auth login --check-status --output json` | Passed; no sign-in/default changes required |
| `azd provision --preview --environment <selected> --subscription <selected> --location <selected> --no-prompt --output json` | Corrected preview passed: zero creates, five modifies, three unchanged, zero resource deletes/replacements |
| Actual selected source/Base64 and compiled feature/role review | Exact selected model retained; APIM/Foundry/vault enabled, Graph/roles/network/storage/VM/NAT/Bastion disabled |
| `git diff --check` | Passed |

The corrected preview reports Key Vault **NoChange**, with no legacy-portal or
insecure protocol/cipher enablement. Remaining friendly property deltas concern
HTTP/2's documented False default, NAT service status, server-maintained Foundry
project/capacity metadata, the service's default model safety-policy name and
Application Insights creation metadata. These are not resource removals or new
billable scope. Model safety-policy retention and all actual child settings must
be checked after the normal azd retry, rather than assumed from a preview.
The failed first run and the blocked exposure-changing preview remain preserved.
Exact private output is in `.azure/resource-stage-preserved-preview.local.log`;
unrelated completed offline suites were not rerun.

### 2026-10-29: recovery provision failed on missing logger

The normal idempotent azd retry exited 1 after the main resources again reported
success. The exact failed ARM operation is
`Microsoft.ApiManagement/service/diagnostics`, child `azuremonitor`, with
`Logger Id 'azuremonitor' does not exist`. A metadata-only logger list is empty.
The diagnostic reference example did **not** establish automatic logger creation;
the preceding built-in-without-resource assumption is superseded by this live
failure. No ad hoc write, exposure opening, role or credential was introduced.
Original retry output and failed operation are preserved in ignored local files.

The bounded next correction declares the `azureMonitor` logger and its diagnostic
dependency, omitting the optional credentials property entirely rather than
submitting an empty object. The current logger REST schema permits this shape;
schema acceptance does not prove the service will accept it. Targeted validation,
a normal preview and one normal same-scope retry may establish that. If Azure
still requires a connection credential, stop and report the contract/platform
blocker rather than introducing a secret, identity role or another destination.

The first-party type-specific evidence was then established from the current
[Azure Verified Module logger implementation](https://github.com/Azure/bicep-registry-modules/blob/main/avm/res/api-management/service/logger/main.bicep):
it uses the same `Microsoft.ApiManagement/service/loggers@2024-05-01` API,
accepts `azureMonitor`, documents credentials as ignored for that type and emits
the credentials property **only when the type is not `azureMonitor`**. This
supports the precise omission shape beyond the generic optional schema.
Our emitted ARM regression asserts the property is absent, not null or empty,
and that the diagnostic depends on the real logger resource. Both disproven
attempts are retained above; no third provisioning attempt was made while
type-specific evidence was unresolved.

The omission correction then passed the actual nine-case APIM regression,
including compiled property absence and the diagnostic's logger dependency,
changed-test AST parsing, root compile/lint and formatting. The already-passed
13-case Bicep/profile/security-preservation checks remain applicable and were
not rerun. The fresh normal scoped azd preview passed with zero creates,
five modifies, three unchanged and zero resource deletes/replacements, with
vault NoChange and no exposure/security enablement. Its original output is
`.azure/resource-stage-omitted-credentials-preview.local.log`. Exact context,
source/derived model and Graph/role exclusions remain unchanged; no credential,
identity setting or role was introduced. The standard validation workflow
repeated recipe, build/static-role, proof and error-resolution checks for this
correction; live acceptance is still required, not inferred from that preview.

### 2026-10-29: resource-only recovery provisioned and independently verified

The single supported omitted-credentials retry completed normally. The actual
subscription deployment is `Succeeded`, normal azd outputs were populated (19
variables), and the APIM logger, all-APIs diagnostic and metrics-setting ARM
operations are individually `Succeeded`. The emitted logger credentials property
is absent, matching the first-party type-specific module. No role, credential,
identity setting or alternative monitoring destination was needed.

| Actual command/check | Completed result |
|---|---|
| Normal scoped `azd provision --environment <selected> --subscription <selected> --location <selected> --no-prompt --output json` | Exit 0; overall ARM deployment `Succeeded`; ordinary outputs returned |
| `./scripts/test-deployment.ps1 -Environment <selected>` | All repository checks passed: owned RG tags, named resource types, project child and excluded network/compute |
| Explicit scoped ARM reads of APIM logger/diagnostic/metrics and their deployment operations | Passed; both children and metrics configuration exist and their ARM operations Succeeded |
| Live diagnostic privacy assertions | Sampling 0, all four body captures 0 bytes, header lists empty, client-IP logging false, no error-sampling exception; no enabled GatewayLogs, AllMetrics enabled |
| Explicit scoped reads of every main resource and the model | All Succeeded, expected names/scope/tags; exact selected model/version/SKU/capacity, NoAutoUpgrade and Microsoft.DefaultV2 safety policy retained |
| Vault/workspace/security assertions | Vault public access Disabled, Deny/AzureServices with no allowlists, RBAC/purge protection on; 30-day workspace retention and 1 GB/day cap; APIM legacy portal and insecure protocols/cipher remain off |
| `az role assignment list --subscription <selected> --all --assignee-object-id <identity> --fill-principal-name false --fill-role-definition-name false` | Zero subscription/descendant role assignments for each APIM, Foundry account and project identity; no directory query/grant |
| Live API/named-value metadata and normal disabled azd outputs | No Graph REST/native MCP API or Graph credential references; Graph/network/storage/VM/Bastion outputs empty |
| `azd show --environment <selected> --output json` | Passed; no hosted application services, as intended; actual HTTPS URLs are taken from deployment outputs/ARM metadata |
| Unauthenticated HTTPS HEAD to actual APIM gateway and Foundry project URLs | Both returned HTTP 404: TLS/HTTP transport reachability only, not functional authentication/model/API acceptance |
| `git diff --check` | Passed |

Azure Monitor does not return `httpCorrelationProtocol`; the REST contract makes
that setting applicable to Application Insights, not this logger type. An initial
over-strict live assertion was corrected to record that inapplicability explicitly,
not substitute a fake live None value. The meaningful privacy settings above were
read back and checked. No model inference, mailbox operation or agent call ran.

The APIM service also has its platform-created subscription-protected Echo API,
with no Graph scope; it was identified, not called or silently deleted. The
same-RG Application Insights Failure Anomalies alert remains identified separately
from managed deployment rows. No network/compute/storage/container workload or
resource outside the dedicated RG was added. Existing resources remain billable;
the illustrative estimate is not a forecast or spending cap.

Original failures, first-party evidence, full successful provision output,
resource/child/role/privacy checks and actual HTTPS endpoints/portal references
are source-linked from ignored `.azure/resource-stage-final.local.json`.
Public documents contain no actual target IDs, generated target names, contacts,
keys or credentials. At resource-stage completion, remaining gates were Entra apps/delegated consent,
credentials/secret access, approved synthetic users, API/MCP activation,
Foundry OAuth/agent setup and actual two-user/fault/end-to-end acceptance.

## Role Assignment Verification

- Status: statically and live-verified for the initial Graph-disabled resource stage.
- APIM credential-secret reader and Key Vault operator-reader assignments are
  conditionally disabled by the actual compiled stage settings.
- Monitoring and Foundry create no role assignments. Resource managed identities
  perform no application data operations in this stage; they need no unused
  grants merely to exist.
- Later Key Vault secret access, local/project-user authorization, delegated
  Graph consent and API enablement remain separately reviewed and approved.
- Actual APIM, Foundry account and project identities have zero
  subscription/descendant assignments in the scoped live role check.

## Subsequent identity-manifests-only stage

The user separately approved only the three dedicated single-tenant app
registrations and their corresponding service principals, the read-only
delegated manifests and the localhost PKCE redirect. Fresh exact-name checks
found no existing objects; the unchanged identity helper applied once.
Independent scoped reads then verified all three owned `AzureADMyOrg`
registrations and matching same-tenant principals, the gateway's v2
`access_as_user` and delegated `Mail.Read`/`Calendars.Read`, gateway-only client
requests, the approved loopback and an empty Foundry callback.

No passwords/certificates, OAuth consent grants, application-role assignments
or preauthorized clients were present. Actual application/principal IDs were
saved only in ignored local azd configuration/evidence, never this contract.
No operator permissions, infrastructure, RBAC, firewall, API/MCP, mailbox or
model operations were changed/invoked by this identity stage.

Apply and verification evidence are in ignored
`.azure/identity-manifests-apply.local.json` and
`.azure/identity-manifests-verified.local.json`. Credential creation/rotation
now fails closed before `addPassword` pending a separately approved bounded
Set Secret readiness route/probe and implementation. Storage-failure tests
exercise only synthetic transport and sanitized orphan-key recovery metadata;
they are not live storage-readiness evidence. Credential expiry, consent,
secret access/network bootstrap, project/user/model RBAC, actual callback,
API/MCP activation and all live acceptance remain separate gates.

| Follow-through check | Result |
|---|---|
| PowerShell AST parse of the two changed identity/credential scripts and their tests | Passed |
| `./tests/run-tests.ps1 -Name graph-identity` | 9 passed, 0 failed; includes creation/rotation readiness refusal and sanitized HTTP/timeout/transport/unconfirmed-copy recovery |
| Corrected default credential helper | `PreparedOnly`, no network/credential change, `CredentialWriteSupported=false` |
| Actual source and derived feature overrides after identity apply | APIM/Foundry/vault on; Graph MCP and role assignments remain off |
| Touched-file actual-identity-ID/privacy and whitespace checks | Passed; actual identity IDs remain only in ignored local configuration/evidence |

Ignored `.azure/identity-credential-safety-validation.local.json` retains the
bounded follow-through evidence. No live credential apply or readiness probe
was run, and unrelated previously completed suites were not rerun.

## Graph MCP activation stage (2026-10-29)

User approval: deploy the APIM Graph APIs, the native MCP server and a Foundry agent that uses it, with
signed-in-user (OBO) authentication, into the existing environment (#8).

| Step | Who | Result |
|---|---|---|
| Admin consent: gateway `Mail.Read Calendars.Read`; Foundry client `access_as_user` | User | Granted (`AllPrincipals`), read back |
| Gateway credential (180 days) stored through ARM after the nonsecret write probe | User, `set-graph-credential.ps1` | `graph-obo-client-secret` enabled; probe secret disabled; vault public access still disabled |
| `graphMcp=true`, `roleAssignments=true`; `azd provision` | Operator | Failed twice, then Succeeded: APIM rejected `System.UriKind` in `rest.xml`; parallel MCP tool writes hit `PreconditionFailed`. Fixed (`new Uri(string)`, `@batchSize(1)`) |
| APIM state | Operator | REST API `graph-read`, MCP API `graph-mcp` with the four tools, fragments `graph-authenticate`/`graph-obo`, named value `graph-obo-secret` Key Vault status `Success` |
| Unauthenticated probes | Operator | REST `/graph/messages` 401; MCP `initialize` without token or with an invalid token 401. An unmatched REST path returns 502 with no body |
| Foundry OAuth connection, agent, callback registration | User | Pending |
| Signed-in REST/MCP/agent calls | User | Not run |
