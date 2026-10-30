# Graph MCP: prepare, deploy and verify

The code prepares a public Entra-protected proof of concept. **Nothing here is
deployment evidence or permission to change Azure/Entra.** No tenant, subscription,
environment, region, exact model/version/SKU/capacity, publisher, budget or test
users have been selected. The source of truth is
[the deployment contract](../.azure/deployment-plan.md).

## Architecture and exclusions

A signed-in user reaches a Foundry prompt agent with a custom OAuth connection.
It obtains a delegated token for **our gateway**, not Graph. APIM Developer's
native Streamable HTTP MCP maps four tools to a small REST API. Both surfaces
validate the token; the REST policy exchanges it through Entra OBO for a Graph
v1.0 `/me` token. APIM's managed identity only reads the confidential credential
from Key Vault. No user token or mailbox response is cached.

Use `core` plus explicit APIM, Foundry and Key Vault opt-ins. Existing private/full
defaults are preserved but not a supported Graph PoC configuration. No VM,
Bastion, NAT, storage, private endpoints/DNS, Function, container, separate MCP
process, toolbox or hosted agent application is added. There are no writes,
application permissions, shared mailboxes, attachments or arbitrary Graph proxy.
Tenant registrations/grants are not resource-group resources. The optional
[Teams publication](#publish-to-teams-and-microsoft-365-copilot) adds an Azure Bot
Service resource that the Foundry portal creates, not the Bicep.

## Public tool contract

| Tool | Facade GET path | Fixed Graph v1.0 resource | Arguments |
|---|---|---|---|
| `list_messages` | `/messages` | `/me/messages` | `page_size` or `continuation` |
| `get_message` | `/messages/{message_id}` | `/me/messages/{id}` | one encoded item ID |
| `list_calendar_view` | `/calendar-view` | `/me/calendarView` | `start`, `end`, optional `page_size`; or `continuation` alone |
| `get_event` | `/events/{event_id}` | `/me/events/{id}` | one encoded item ID |

The facade is under the deployed REST output's `/graph` base. Obtain the actual
MCP server URL from the deployed native API; do not derive it from its ARM ID.
Native resources pin `2025-09-01-preview`, `type=mcp`; each child tool binds the
full ARM ID of the backing REST operation.

`infra/modules/api-management/contract.json` fixes fields and bounds; OpenAPI
does not expose arbitrary OData, URLs, paths, identities, headers or scopes.
Message lists return metadata without body/bodyPreview. Details include text
bodies and ordinary message/event details, not attachments. Returned strings,
including link-shaped fields, are untrusted data; do not execute/render HTML
or follow embedded links.

| Boundary | Behavior |
|---|---|
| Page size | Default 10, range 1-25; invalid values are rejected, never clamped |
| Calendar window | ISO 8601 instants with `Z` or numeric offsets; end > start; elapsed duration <=31 days |
| Detail JSON | At most **65,536 UTF-8 bytes**, checked before and after projection |
| List JSON | At most **131,072 UTF-8 bytes**, checked before and after shaping |
| IDs / cursors | At most 2,048 / 16,384 characters respectively |
| OBO / Graph backend | 10 / 20 seconds; no automatic policy retries |
| Per-user rate | 60 requests per 60 seconds on each authenticated surface |
| Retry guidance | Integer Retry-After bounded to 1-30 seconds; default 5 |

Oversize fails with 502 `response_too_large`; **nothing is silently truncated**.
The limit includes JSON syntax and non-ASCII UTF-8 bytes. Native streaming
response bodies are never inspected. REST policy buffering has no independently
proven pre-buffer memory ceiling; this is a returned-content boundary, not a
claim about all platform allocation. Live MCP tests must establish that backing
REST outbound policies actually enforce it.

Lists return `{ "items": [...], "continuation": null-or-string }`. Send a returned
continuation **alone**. It is an untrusted base64url envelope, not a credential or
an authorization grant. Every request revalidates user, operation, fixed HTTPS
Graph host, exact `/me` path, fields/order, page size and calendar window.
Preserve service-issued paging parameters; never invent or increment `$skip`.
The real Graph next-link shape must be validated live: an unsupported shape
fails closed rather than broadening the proxy.

Input errors are 400; gateway/user-token errors 401; Graph consent/Conditional
Access action 403 `graph_user_action_required`; Graph missing data 404; throttles
429; OBO/backend/malformed/oversize errors 502; timeouts 504. An `invalid_client`
or invalid-scope exchange is an operator configuration failure, **not user
consent**. Upstream error bodies, claims challenges and tokens are never returned
in public diagnostics. Resolve consent/CA with the tenant administrator; do not
blindly retry auth failures or replace user access with managed identity.

## Identity, roles and credential lifecycle

| Registration | Required contract |
|---|---|
| Gateway API/confidential middle tier | Single tenant, v2 tokens, `api://<gateway-client-id>/access_as_user`; only delegated Graph `Mail.Read` and `Calendars.Read` |
| Foundry OAuth web client | Requests the gateway scope plus `offline_access`; exact callback actually returned by Foundry; no implicit grant |
| Local public PKCE client | Secretless browser auth, explicitly approved localhost loopback; requests the gateway scope |

Validation checks signature, issuer, tenant, audience, lifetime, v2, approved
`azp`, delegated `access_as_user` and user `oid`; app-only tokens are rejected
on REST **and MCP**. Downstream Graph consent must exist before OBO. Foundry
sign-in alone does not grant Graph consent. No `openid`/Graph write permission
is added to create fixtures.

Azure resource RBAC, Entra app-management authority, delegated consent authority,
and Exchange mailbox licensing are distinct prerequisites. Microsoft currently
documents **Foundry Agent Consumer** at project scope as the minimal OAuth
consumer role; **Foundry User** (formerly Azure AI User) is for agent developers.
Verify the current definitions/actions and narrow connection/agent-administration
needs before grants. Do not blanket-grant Contributor. No Foundry RBAC grants
are made by this preparation.

The identity helper looks up deterministic names and requires exact ownership
tags; it refuses collisions, unexpected scopes/permissions and application roles.
It preserves credentials and an existing Foundry callback unless a new exact
callback is supplied. It declares permissions but does **not** grant consent.
An interrupted apply must be reconciled before rerunning; partial creation is
not reported as success.

The credential helper defaults to preparation. Apply checks the selected
CLI/azd tenant/subscription/region and the owned vault's environment tag,
RBAC, default-deny firewall and purge protection. An existing credential is
not recreated. **The secret is written through ARM**
(`Microsoft.KeyVault/vaults/secrets`, API `2023-07-01`): the control plane works
while the vault's public network access stays disabled, so no firewall or
network change is needed. Before `addPassword`, the helper writes a disabled,
nonsecret `graph-obo-write-probe` secret through the same route and requires its
returned version; a failed probe stops with no credential created. The operator
needs `Microsoft.KeyVault/vaults/secrets/write` on the vault (for example
Contributor). Default preparation reports `CredentialWriteSupported=true`; Apply
still needs `-CredentialChangeApproved` and a selected expiry.

The storage boundary is covered with synthetic transport tests. It keeps new values
in memory/HTTPS, never files, CLI arguments or output, and requires a returned
version of the intended vault secret before reporting storage success. An HTTP
failure, timeout, transport failure or unconfirmed response stops without retry
or credential removal. `Exception.Data['CredentialRecovery']` contains only the
application object ID, new credential key ID/display name/expiry, intended secret
reference and reconciliation instructions; the value/token and underlying HTTP
response are not attached.

Preserve only that nonsecret recovery metadata in ignored local evidence. Under
separately approved read authority, reconcile the exact application credential
and secret-version metadata without reading secret values. An uncertain vault
outcome is not a verified copy. The one-time password cannot be fetched again
from Entra after process exit. If cleanup is explicitly approved, remove only
the **new** recorded key ID from the recorded application with
`POST /applications/{actual-application-object-id}/removePassword` and its
`keyId` body; never guess a missing key ID or remove a previous working credential.
Reconcile a missing key ID before any cleanup. Any new creation attempt must
first resolve the readiness gate and have separate credential authority.

APIM has secret-scoped Secrets User access to a **versionless** vault named
value. Operator secret-writing authority and any temporary firewall exception
require separate approval/removal; the scripts never open the firewall.
The gateway composition keeps vault public network access **Disabled**, with
`defaultAction=Deny`, no IP/VNet exceptions and `bypass=AzureServices`. Current
[Key Vault network guidance](https://learn.microsoft.com/en-us/azure/key-vault/general/network-security#key-vault-firewall-enabled-trusted-services-only)
states that the trusted-service bypass also applies with public access disabled.
APIM's later named-value integration requires its system identity and separately
authorized secret access; actual retrieval remains a later live gate. Do not
silently enable public access for bootstrap or operator secret writes.
A workstation is not a trusted-service bypass. Neither Azure RBAC nor using the
portal bypasses the vault firewall. A temporary workstation route would require
separately approved public endpoint access with default-deny retained and an
exact approved source-IP rule, followed by restoration of the original network
and temporary role settings. Adding an IP rule alone while public access stays
disabled does not establish that route; no such exception is made by the helpers.

Foundry's web-client credential must be created and entered by the authorized
operator directly through the supported Entra/Foundry browser flows, without
sharing its value with the assistant. `set-graph-credential.ps1` handles only the
gateway OBO secret; `configure-foundry-oauth.ps1` prepares nonsecret settings only.
There is no implemented unattended credential-creation/transfer path into the
encrypted Foundry custom OAuth connection. Do not invent a connection REST
schema or pass the secret as an argument. Run the OAuth settings helper only
with actual created application IDs and the deployed MCP URL; register exactly
the callback returned by the connection, never a placeholder.

## Safe local preparation

PowerShell (workstation), at the isolated repository checkout:

```powershell
Set-Location '<repository-path>'
.\scripts\configure-graph-identity.ps1 -Environment synthetic
.\scripts\set-graph-credential.ps1 -Environment synthetic
.\tests\run-tests.ps1
.\scripts\build-catalog.ps1 -Check
.\scripts\build-docs.ps1 -Check
dotnet restore GraphMcp.slnx --locked-mode
dotnet build GraphMcp.slnx --no-restore
dotnet test GraphMcp.slnx --no-build --no-restore
dotnet format GraphMcp.slnx --verify-no-changes --no-restore
```

Default helper calls do not contact Azure/Graph or generate credentials.
`-Apply` requires separate `-IdentityChangeApproved` or
`-CredentialChangeApproved`, verified target context and normal confirmation.
`-WhatIf` returns preparation without cloud calls. The flags record a prior
operator decision; they do not themselves authorize changes.

### .NET verification client

The client uses the approved-feed `AIProjectClient`/Responses SDK, not
`PersistentAgentsClient` or a hosted application. No arguments, `offline` and
`help` are network/authentication-free. `definition` writes a usable
`ProjectsAgentVersionCreationOptions` SDK JSON preview into the build's ignored
`artifacts` directory and prints only its path/local-only warning. It does not
create an agent; apply/review in the supported portal is a later operator gate.
The preview contains resource/connection references and must not become public
evidence even though it has no credentials.

All configuration is read from named environment variables prefixed
**`GRAPH_MCP_`**, never an `.env` file:

| Suffix | Required use |
|---|---|
| `GATEWAY_ORIGIN` | Owned HTTPS origin for every configured mode |
| `MCP_URL` **or** `MCP_PATH` | Exactly one, copied from the actual deployed endpoint; no default/guess; must remain on the configured origin |
| `PROJECT_ENDPOINT`, `MODEL_DEPLOYMENT`, `AGENT_NAME`, `CONNECTION_NAME` | Definition and Foundry modes |
| `TENANT_ID`, `CLIENT_ID`, `GATEWAY_SCOPE` | Both live modes; public PKCE client and `api://<gateway-app-id>/access_as_user` |
| `SYNTHETIC_MESSAGE_ID`, `SYNTHETIC_EVENT_ID`, `CALENDAR_START`, `CALENDAR_END` | Both live modes; fixture IDs and offset-aware <=31-day window |
| `AGENT_VERSION` | Foundry mode; pin the reviewed existing version |
| `CONSENT_ORIGIN`, `CONSENT_PATH` | Foundry mode; exact trusted HTTPS route verified from current Foundry configuration, not a wildcard |
| `REST_PATH`, `PAGE_SIZE`, `REDIRECT_URI` | Defaults `/graph`, `10`, `http://localhost:8400/`; register/approve the same loopback URI |
| `HARNESS` | Default `responses`; `copilot` selects conversation continuation instead, not a harness installation |

PowerShell (workstation), at the isolated checkout. The live commands are shown
for the **later separately approved** synthetic-user stage, not run as offline
validation:

```powershell
Set-Location '<repository-path>'
dotnet run --project src\GraphMcp.TestClient --no-build --no-restore -- offline
# After explicit nonsecret configuration:
dotnet run --project src\GraphMcp.TestClient --no-build --no-restore -- definition
# Only after the independent live/user-authorization gates:
dotnet run --project src\GraphMcp.TestClient --no-build --no-restore -- direct --live --open-browser --synthetic
dotnet run --project src\GraphMcp.TestClient --no-build --no-restore -- foundry --live --open-browser --synthetic
```

Direct mode tests REST plus native initialize/initialized/tools-list/tool calls
and requires the configured synthetic detail fixtures. Empty/wrong fixtures
fail. Add `--follow-continuation` explicitly to exercise one returned page per
list, not an unbounded paging loop.

Foundry mode verifies the pinned agent's four-tool/approval-always connection
contract, then requires actual approved execution evidence rather than trusting
model prose. OAuth requires explicit `open` then `done`; each validated MCP
request independently requires `approve` or `deny`. Consent links, tokens,
mailbox bodies and response/conversation IDs are not printed. Unrecognized
server/tool/consent routes fail closed; verify an unexpected route privately
rather than relaxing allowlists.

Ordinary Responses chains `previous_response_id`. The `copilot` continuation
contract creates a fresh conversation and never sends `previous_response_id`;
do not mix the contracts or infer that the client deploys a Copilot harness.
Credential/session/conversation/response state is process-local: use a fresh
process/browser identity per test user. Client budgets are 30 seconds/request,
180 seconds/authentication, 12 Foundry rounds, no automatic retries and a
1,048,576-byte MCP/SDK envelope. Whole detail/list JSON retains the tighter
65,536/131,072-byte UTF-8 limits. Runtime SDK/OAuth/native compatibility remains
unverified until the live matrix passes.

## Separately approved live stages

1. Select the target, publisher, exact model/version/SKU/capacity, full recurring
   and idle costs/budget, licensing, public/preview/secret/data-handling terms and
   two same-tenant licensed mailbox users with project access. Verify CLI/azd
   context, approved/supported region, model lifecycle, policy, quota and roles.
2. Update the deployment contract. Prepare the real azd environment and ignored
   tenant files. Preview and review costs; obtain infrastructure approval before
   provision. An initial override can enable `apiManagement`, `aiFoundry` and
   `keyVault`, with `graphMcp=false` and `roleAssignments=false`; no Graph API is
   exposed yet. `FOUNDRY_DEPLOYMENTS_JSON=[]` avoids inventing a model choice.
   Run the existing `scripts/set-deployment-tags.ps1` local bootstrap before
   preview (and after model/override changes) so required naming/tags and
   encoded selections exist before azd resolves its parameters.
3. Obtain Entra/app-management approval. Apply the owned identity manifests with
   explicit environment/tenant/subscription/location, approved loopback URI and
   initially no invented Foundry callback. The helper records nonsecret app IDs
   in the selected azd environment without printing them. Obtain downstream Graph
   delegated consent separately, under the tenant's consent policy.
4. Obtain credential/vault/RBAC approval, select expiry and the owned vault, then
   run `set-graph-credential.ps1 -Apply -CredentialChangeApproved`: its ARM write
   probe must pass before the gateway password is created. Review operator
   roles before enabling `roleAssignments=true`; the starter also grants configured
   operators vault access. Re-preview the explicit `graphMcp=true` override and deploy its
   protected APIs after approval. Verify Key Vault/RBAC propagation, actual MCP
   URL and both REST/MCP protection. Never register providers implicitly.
5. After approved model deployment, run `configure-foundry-agent.ps1 -Apply
   -CreateConnection -CredentialChangeApproved -ExpiresOn <date>`. It adds a
   password to the owned Foundry app and stores it only in the project's custom
   OAuth connection (`OAuth2`, tenant-specific authorize/token endpoints, gateway
   scope plus `offline_access`), created through ARM. It reports the callback
   the connection returns; if none is returned, copy it from the connection in the
   Foundry portal. Register **the returned callback exactly** by rerunning the
   identity helper with `-FoundryCallbackUri`.
6. The same script creates the prompt agent `graph-mail-calendar` (rerun with
   `-Apply` alone to update it) with exactly four allowed tools, the owned project
   connection and `require_approval=always`. Verify direct PKCE REST/MCP first,
   then the SDK agent flow. User OAuth consent and every MCP approve/deny are
   independent interactions; do not suppress approval to make a test pass.
7. Optionally, after the playground and direct tests pass, publish the agent to
   Teams and Microsoft 365 Copilot under separate approval; see
   [Publish to Teams and Microsoft 365 Copilot](#publish-to-teams-and-microsoft-365-copilot).

Keep `azure-prepare` -> `azure-validate` -> `azure-deploy`. Native MCP has no azd
application service to package/deploy: record that packaging is not applicable
rather than claiming a hosted service exists.

### Cost gate

Public Azure Retail Pricing queried **2026-10-29** returned APIM `Developer`,
meter **Developer Unit**, USD **0.0658 per hour**, about **48.03 for 730 hours**
in example regions eastus/westus2/westeurope/northeurope. This is a dated
illustration, not a region selection, quote or budget approval. Excludes model
tokens, Key Vault, monitoring, bandwidth, tax and account-specific terms.
Zero-priced **Developer Workspace Pack** records are not the Developer Unit.
Requery the approved target's full recurring costs and budget before deployment.
A Log Analytics daily ingestion cap is not a spending cap. Developer bills while
idle and has no production SLA.

## Live acceptance: one user, in the playground

On 2026-10-29 the owner reported the agent working in the Foundry playground:
consent link, sign-in, then approved MCP tool calls returned their own mail and
calendar. APIM metrics did not confirm the calls when read afterwards, and every
other row below (denials, two-user isolation, paging, limits) is still unexecuted.

Offline tests exercise the real policy expressions, but cannot prove APIM policy
support, native authorization/header propagation, real Graph paging, Foundry
OAuth/CA or end-to-end execution. Collect only sanitized counts/outcomes, not
tokens, IDs, mailbox contents, consent URLs or screenshots identifying users.

| Area | Required live evidence |
|---|---|
| Infrastructure | Expected resources/tags/outputs, opt-in absence, no unplanned network/storage, stable reprovision/no credential reset |
| Direct REST | Synthetic messages and recurring/exception calendar fixtures; list metadata, full text detail, empty/notfound |
| Native MCP | Authenticated initialize, initialized notification, tools/list exactly four schemas, all four tools/call; streaming integrity |
| Authentication | Deny absent/expired/wrong tenant/issuer/audience/client, app-only and insufficient-scope tokens on both surfaces |
| OBO/isolation | Graph receives delegated user token; real consent/CA behavior; two users with separate credentials/response state cannot cross cursors, IDs or forged headers |
| Limits/paging | Sizes 1/10/25 and invalid sizes, service next links, offsets, recurrence, exact 31-day and UTF-8 byte boundaries, explicit oversize rejection through MCP |
| Faults | Consent denied/revoked, expiry/reauth, throttling/Retry-After, timeouts, malformed/backend errors; no automatic unbounded retries |
| Foundry | Actual named MCP invocations correlated privately with APIM/Graph fixture results, not plausible prose; consent accept/reject, approval deny/continue, second user |
| Confidentiality | Zero body/header logging, no shared tokens/cache, synthetic content only, review conversation retention and trace/edit permissions |

Create synthetic fixtures through approved mailbox tools, **not by adding write
scopes**. Empty fixtures cannot establish detail behavior. If native backing
policy/header forwarding, CA, OAuth or the selected client contract fails, stop
at that exact gate. Do not silently substitute shared/app-only credentials,
a custom broker/server or native response buffering.

## Publish to Teams and Microsoft 365 Copilot

Publishing exposes the **same** `graph-mail-calendar` agent, connection and MCP
tools in Teams and Microsoft 365 Copilot. It changes no APIM, Key Vault or
identity-helper setting, and is not part of `azd provision`. Publish only after
the playground and direct tests pass, under its own approval: it lists the agent
in the tenant's agent store and sends conversation content to Microsoft 365.

### Prerequisites

| Item | Requirement |
|---|---|
| Agent identity | The agent has its own identity (`instance_identity` on `GET {project endpoint}/agents/<name>?api-version=v1`). Agents created by `configure-foundry-agent.ps1` through the v1 agents API have one; an older-format agent must be migrated first |
| Resource provider | `Microsoft.BotService` registered in the subscription; the template's preflight does not check it |
| Publisher | **Foundry User** on the project (agent write), plus `Microsoft.BotService/botServices/write` and `channels/write` on the resource group: **Azure Bot Service Contributor Role**, Contributor or Owner. Foundry roles do not grant the Bot Service permissions |
| Users | Members of the project's tenant (guests are refused), with **Foundry Agent Consumer** on the project for OAuth passthrough, a Teams license and an Exchange Online mailbox |
| Network | Users' networks allow HTTPS to `*.azureml.ms` for the sign-in redirect |

Grant Foundry Agent Consumer to a group rather than to single users. It is the
least-privileged role for OAuth passthrough; do not grant Foundry User or
Contributor to agent users.

### Publish

In the Foundry portal, on the project:

1. Open the agent, **Details** > **Active version**: pin the tested version, or
   keep **Always use latest** so a new version reaches Teams without republishing.
2. **Publish** > **Teams and Microsoft Copilot**. Foundry creates an Azure Bot
   Service resource (F0, global) in the project's resource group, or shows the
   existing one.
3. Enter the display name, a three-part publish version (`1.0.0`), short and full
   descriptions and the developer name. These fields are shown to users: no
   identifiers, URLs to internal systems or secrets.
4. **Next: Publish options** > **Direct publish**, choose the scope, **Publish**.
   **Download & customize** instead returns the validated Teams app package to
   upload by hand; change only user-facing metadata and icons in it.

| Scope (portal / REST `publishScope`) | Authorization scheme | Who can call the agent | Approval |
|---|---|---|---|
| **Just you** / `Shared` | `BotServiceRbac` | The publisher, and users the link is shared with who hold the project role | None |
| **People in your organization** / `Tenant` | `BotServiceTenant` | Every member of the tenant | A Microsoft 365 admin approves it in the admin center (**Agents** > **Requests**) |

Start with **Just you**. `BotServiceTenant` lets any tenant member reach the
agent, but the MCP tools still require each user's own OAuth consent and Foundry
Agent Consumer. The REST equivalent (Bot Service Bicep, agent endpoint update and
`POST {project endpoint}/agents/<name>/microsoft365/publish?api-version=v1`) is in
the Microsoft Learn REST article; the project here keeps public network access,
so `enable_m365_public_endpoint` is not needed.

### In Teams

The agent appears under **Your agents** (`Shared`) or, after approval, **Built by
your org** (`Tenant`); the store cache can take about an hour. The first tool use
shows a sign-in card: the same OAuth consent as in the playground, through the
same connection and registered callback. Each MCP call then shows an approval
card, because `require_approval=always` stays on. A dismissed approval or a tool
error can lock the conversation; send `/foundry_new_preview` in Teams to start a
new one.

Published agents do not stream responses or show citations. Updating the store
metadata needs a higher publish version (**Publish** > **Update agent Teams and
Microsoft Copilot display properties**); changing the agent's behavior needs only
a new agent version.

### What publishing adds

| Added | Where | Removed by `azd down` |
|---|---|---|
| Azure Bot Service resource | The azd resource group, created by the portal, not by the Bicep; `azd provision` leaves it alone | Yes, with the resource group |
| `activity` protocol and Bot Service authorization scheme | The agent endpoint | No; deleted with the Foundry project |
| Teams app and agent store entry | The Microsoft 365 tenant | No |
| Conversation content | Microsoft 365 and Teams, under their terms and retention, as well as Foundry | No |

Review data handling before publishing an agent that reads real mailboxes: the
synthetic-only acceptance terms above no longer bound what users send or see.

## Recovery and teardown

Retain previous REST revisions/policies, native tool definitions and agent
versions for non-destructive rollback. Disable the project connection to stop
agent access; revoke per-user grants when appropriate. Rotate a credential
explicitly, store a new vault version, refresh/verify the APIM versionless named
value and OBO, then separately approve removal of the prior credential.
Connection disable, user revocation and credential removal need operational
authority; the helpers do not silently perform them.

For a published agent, disabling the connection stops its tools in Teams too.
Deleting the Bot Service resource stops message delivery from Teams and Microsoft
365 Copilot; a Microsoft 365 admin removes an organization-scope agent from the
store in the admin center.

Teardown requires separate approval and an inventory of **both** owned Azure
resources and tenant apps, grants and Foundry conversations, plus the Teams app
and Microsoft 365 conversations of a published agent. Deleting the RG
does not remove tenant identities or necessarily retained conversations.
Key Vault soft delete/purge protection can retain secrets/reserve names.
Profile/flag disablement in an incremental deployment is not deletion and may
leave billable resources. Never broadly delete a tenant, subscription or shared RG.

## Authoritative references

- [APIM native MCP overview](https://learn.microsoft.com/azure/api-management/mcp-server-overview),
  [REST export](https://learn.microsoft.com/azure/api-management/export-rest-mcp-server),
  [management API](https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api),
  [security](https://learn.microsoft.com/azure/api-management/secure-mcp-servers).
- [APIM authentication](https://learn.microsoft.com/azure/api-management/authentication-authorization-overview),
  [Key Vault named values](https://learn.microsoft.com/azure/api-management/api-management-howto-properties),
  [Entra OBO](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-on-behalf-of-flow).
- [Foundry MCP authentication/roles](https://learn.microsoft.com/azure/foundry/agents/how-to/mcp-authentication),
  [MCP tools and SDK](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/model-context-protocol).
- [Publish to Teams and Microsoft 365 Copilot (portal)](https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot),
  [REST API](https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network),
  [troubleshooting](https://learn.microsoft.com/azure/foundry/agents/how-to/troubleshoot-publish-copilot).
- [Graph messages](https://learn.microsoft.com/graph/api/user-list-messages?view=graph-rest-1.0),
  [calendar view](https://learn.microsoft.com/graph/api/calendar-list-calendarview?view=graph-rest-1.0).
- [Azure Retail Pricing API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices).
