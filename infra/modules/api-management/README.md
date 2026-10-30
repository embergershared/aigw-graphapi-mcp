# API Management Graph gateway

Public APIM **Developer**, system identity and metrics-only monitoring. Default
off in every profile. This module supports only the approved `core` public PoC;
it does not add a private endpoint or a hosted MCP application.

`configureGraph=false` creates infrastructure without an open Graph API.
After separately approved Entra bootstrap and Key Vault secret population,
`configureGraph=true` creates the curated REST facade, shared authentication/OBO
fragments, and four native MCP tools. MCP management is pinned to
`2025-09-01-preview`; each child tool binds a full ARM REST-operation ID.

Inputs include publisher settings, gateway client ID, approved client IDs and
the **name**, never the value, of an existing vault secret. Secret-scoped
Key Vault Secrets User RBAC authorizes the APIM system identity. Keep the
vault's trusted-services integration and deny-by-default firewall.

`contract.json` owns limits and fixed Graph field selections. `openapi.json`
owns the public four-operation schema. Policy tests check that they agree.
Both APIs require a v2 delegated gateway token, including `access_as_user`,
tenant, audience and an approved caller; Graph uses an OBO token instead.
There is no cache or arbitrary proxy. See [the runbook](../../../docs/graph-mcp.md)
for identity setup, phased deployment, error/size contracts and live gates.

Outputs are IDs, names, principal ID and REST URL only. Read the actual deployed
MCP server URL through the management API/portal; the module deliberately does
not guess a transport URL. No payload diagnostic logger is provisioned.

The all-APIs diagnostic references an explicitly declared `azureMonitor` logger.
A `/loggers/azuremonitor` reference alone did not create that logger in live
validation. The [logger REST contract](https://learn.microsoft.com/en-us/rest/api/apimanagement/logger/create-or-update?view=rest-apimanagement-2024-05-01)
marks credentials optional; omit the property entirely, not an empty object
that invokes connection-method validation. No monitoring credential or role
is declared. The current [Azure Verified Module implementation](https://github.com/Azure/bicep-registry-modules/blob/main/avm/res/api-management/service/logger/main.bicep)
uses the same `2024-05-01` API and explicitly omits credentials for `azureMonitor`.
Successful live logger/diagnostic provisioning is a required gate,
not established by schema validation alone.
Sampling remains zero, with no body bytes, headers, client IP or error-sampling
exception. Only platform metrics are routed to Log Analytics.

The legacy portal, SSL 3.0, TLS 1.0/1.1 in both directions and Triple DES are
explicitly disabled so repeat provisioning preserves the deployed restrictions.
