<!--
Context: a customer running the APIM Graph MCP pattern in Azure Government (GCC High) cannot create the
Foundry custom OAuth (identity passthrough) connection (HTTP 500 on the connection write, support ticket open).
This plan is the workaround ("Option A") proposed on 2026-11-05: a Teams bot owns the user sign-in and executes
the Foundry agent function calls against APIM with the user token. Status: written from Microsoft Learn,
not yet tested in Azure Government. Use it to reproduce and test the whole path if the customer goes this way.
-->

# Option A setup: Teams bot with per-user tokens calling a Foundry agent through APIM (Azure Government, GCC High)

A Teams bot you own signs the user in with Teams SSO, calls a Foundry prompt agent through the Responses API, and executes the agent's function calls itself against your APIM gateway with the signed-in user's token. APIM validates the token and does the on-behalf-of exchange to Microsoft Graph exactly as it does today.

Flow of one turn:

1. The user writes to the bot in Teams (GCC High). Teams SSO gives the bot a token for the bot's own app; the Azure Bot token service exchanges it for a delegated token for your gateway app (`api://<gateway-app-id>/access_as_user`).
2. The bot calls the Foundry agent (Responses API) with its own managed identity. The agent has function tools named like your MCP tools.
3. The response contains `function_call` items. The bot runs each one against APIM with the user's gateway token, submits the results as `function_call_output` items, and posts the agent's final answer in Teams.

What this gives you: the token that reaches APIM is the same one the Foundry passthrough connection would have produced, so the APIM policies, the OBO exchange, the Key Vault secret and the Graph consent on the gateway app do not change. The user's token only ever lives in the bot process and in APIM.

Nothing in this guide was run end to end in Azure Government by us. Every step is taken from the Microsoft Learn articles listed at the end, with the GCC High values substituted. Validate each step in your environment.

---

## 1. Prerequisites

- Microsoft 365 GCC High tenant with Teams, and an Azure Government subscription in the same tenant.
- Your existing APIM gateway: the gateway app registration (exposes `access_as_user`, holds the delegated Graph permissions and the OBO secret) and the APIM MCP or REST endpoint (`https://<apim>.azure-api.us/...`), both already validated with the static-token test.
- Foundry project in `usgovvirginia` or `usgovarizona` with a deployed model. Project endpoint format: `https://<resource>.services.ai.azure.us/api/projects/<project>`.
- Permission to create app registrations and grant admin consent in the Gov tenant, to create an Azure Bot resource, and to assign roles on the Foundry project.
- A Teams administrator who can publish a custom app to the org catalog. GCC High does not allow users to upload custom apps; the admin publishes the package from the Teams admin center.
- Tooling: Azure CLI signed in to Azure Government, and the Teams SDK (C#, TypeScript or Python) or the Bot Framework SDK v4.14+. The Teams SDK is used below because its sovereign-cloud configuration is documented (`Cloud = USGov`).

PowerShell (workstation):

```powershell
az cloud set --name AzureUSGovernment
az login
az account set --subscription "<subscription-id>"
```

---

## 2. Register the bot's Entra app (Gov tenant)

Create one single-tenant app registration, called the bot auth app below. It is both the Azure Bot's Microsoft App ID and the app Teams uses for SSO.

1. Entra admin center for Azure Government: **App registrations > New registration**, single tenant. Note the application (client) ID and the tenant ID.
2. **Certificates & secrets**: add a client secret for development. For production prefer a certificate or a federated credential on the bot's managed identity.
3. **Authentication > Add a platform > Web**, redirect URI `https://tokengcch.botframework.azure.us/.auth/web/redirect` (GCC High value; for DoD use the value from the Bot Service government article).
4. **Expose an API**:
   - Application ID URI: `api://botid-<bot-app-id>`.
   - Add scope `access_as_user`, enabled, admins and users can consent.
   - Authorized client applications: add `1fec8e78-bce4-4aaf-ab1b-5451cc387264` (Teams desktop and mobile) and `5e3ce6c0-2b1f-4285-8d4b-75ee78787346` (Teams web), both for the `access_as_user` scope. This is what makes SSO silent.
5. **API permissions > Add a permission > My APIs** > your gateway app > delegated `access_as_user`. **Grant admin consent** for the tenant.

Then on the gateway app:

6. **Expose an API > Authorized client applications**: add the bot auth app ID for `access_as_user`. This keeps the token exchange silent even where user consent is restricted.
7. APIM: if the inbound policy allow-lists the calling application (`azp` or `appid` claim), add the bot auth app ID. Audience, scope and user-only checks stay as they are. The OBO to Graph and its secret stay as they are.

The Teams SSO article shows steps 1 to 4 as `az rest` calls against the Graph applications endpoint; in GCC High use `https://graph.microsoft.us` as the Graph base URL.

---

## 3. Create the Azure Bot resource and its OAuth connection (Azure Government)

1. Azure portal for Government (`portal.azure.us`): create **Azure Bot**, type of app **Single tenant**, creation type **Use existing app registration**, app ID and tenant ID from section 2.
2. **Configuration**: messaging endpoint `https://<bot-host>.azurewebsites.us/api/messages` (the App Service you create in section 4).
3. **Channels**: add **Microsoft Teams**. Teams is the only channel available in GCC High.
4. **Configuration > Add OAuth Connection Settings**, or with the CLI:

PowerShell (workstation, Azure Government):

```powershell
az bot authsetting create `
  --resource-group "<rg>" --name "<bot-resource-name>" `
  --setting-name "gateway" `
  --client-id "<bot-app-id>" --client-secret "<bot-app-secret>" `
  --service "Aadv2" `
  --provider-scope-string "api://<gateway-app-id>/access_as_user" `
  --parameters tenantId=<tenant-id> tokenExchangeUrl=api://botid-<bot-app-id>
```

Pass the secret from a variable or a Key Vault reference, not typed on the command line in a shared shell. Portal equivalent: Service provider **Azure Active Directory v2**, Token Exchange URL `api://botid-<bot-app-id>`, Scopes `api://<gateway-app-id>/access_as_user`.

The token the bot receives from this connection has `aud` = your gateway app, `scp` = `access_as_user`, the user's `oid`, and `azp` = the bot auth app. It is exactly what the Foundry passthrough connection would have produced.

---

## 4. Host the bot

App Service (or Container Apps) in Azure Government with a system-assigned managed identity. The managed identity is what calls Foundry; it never touches user data.

Configuration the bot needs (as app settings, never in source):

| Setting | Value |
|---|---|
| Bot app ID, tenant ID, client secret or certificate | From section 2 |
| Cloud | `USGov` (Teams SDK) or the GCC High settings block below (Bot Framework SDK) |
| OAuth connection name | `gateway` (the name given in section 3) |
| Foundry project endpoint | `https://<resource>.services.ai.azure.us/api/projects/<project>` |
| Foundry token scope | `https://ai.azure.us/.default` |
| Agent name | From section 5 |
| APIM base URL | `https://<apim>.azure-api.us/<api-path>` |

Teams SDK: set `CLOUD=USGov` (environment) or `"Teams": { "Cloud": "USGov" }` (appsettings.json). The SDK then uses `login.microsoftonline.us`, the Gov bot token scope, the GCC High token service and the Gov OpenID metadata for JWT validation.

Bot Framework SDK v4 instead: add to appsettings.json

```json
"ChannelService": "https://botframework.azure.us",
"OAuthUrl": "https://tokengcch.botframework.azure.us/",
"ToChannelFromBotLoginUrl": "https://login.microsoftonline.us/MicrosoftServices.onmicrosoft.us",
"ToChannelFromBotOAuthScope": "https://api.botframework.us",
"ToBotFromChannelTokenIssuer": "https://api.botframework.us",
"ToBotFromChannelOpenIdMetadataUrl": "https://login.botframework.azure.us/v1/.well-known/openidconfiguration",
"ToBotFromEmulatorOpenIdMetadataUrl": "https://login.microsoftonline.us/cab8a31a-1906-4287-a0d8-4eef66b95f6e/v2.0/.well-known/openid-configuration",
"ValidateAuthority": true
```

---

## 5. Create the Foundry agent with function tools

The portal cannot add function tools; use the REST API or an SDK. Mirror your MCP tools one for one (same names and arguments) so the agent instructions you already have keep working.

PowerShell (workstation, Azure Government):

```powershell
$endpoint = "https://<resource>.services.ai.azure.us/api/projects/<project>"
$token = az account get-access-token --scope "https://ai.azure.us/.default" --query accessToken -o tsv
$body = @'
{
  "name": "graph-mail-calendar-bot",
  "description": "Mail, calendar and chat assistant; tools are executed by the Teams bot with the user's token.",
  "definition": {
    "kind": "prompt",
    "model": "<model-deployment-name>",
    "instructions": "You help the signed-in user with their mail, calendar and Teams chats. Use the tools; never guess data. Return concise answers.",
    "tools": [
      {
        "type": "function",
        "name": "list_messages",
        "description": "List the user's most recent mail messages.",
        "parameters": {
          "type": "object",
          "properties": {
            "page_size": { "type": "integer", "description": "Number of messages, 1 to 25" },
            "continuation": { "type": "string", "description": "Continuation token from a previous call" }
          }
        }
      },
      {
        "type": "function",
        "name": "get_message",
        "description": "Get one mail message by id.",
        "parameters": {
          "type": "object",
          "properties": { "message_id": { "type": "string" } },
          "required": ["message_id"]
        }
      },
      {
        "type": "function",
        "name": "list_calendar_view",
        "description": "List calendar events between two ISO 8601 date-times.",
        "parameters": {
          "type": "object",
          "properties": {
            "start": { "type": "string" },
            "end": { "type": "string" },
            "page_size": { "type": "integer" }
          },
          "required": ["start", "end"]
        }
      },
      {
        "type": "function",
        "name": "list_chats",
        "description": "List the user's recent Teams chats.",
        "parameters": { "type": "object", "properties": { "page_size": { "type": "integer" } } }
      }
    ]
  }
}
'@
$body | az rest --method POST --uri "$endpoint/agents?api-version=v1" --headers "Content-Type=application/json" "Authorization=Bearer $token" --body "@-"
```

Add `get_event`, `list_chat_messages` and any other tool the same way. Keep `strict` unset.

---

## 6. Let the bot call the agent

Assign **Foundry Agent Consumer** (role ID `eed3b665-ab3a-47b6-8f48-c9382fb1dad6`) to the bot's managed identity at project scope, or at agent scope to limit it to this one agent. The Azure portal only offers this role at account scope, so use the CLI.

PowerShell (workstation, Azure Government):

```powershell
$projectScope = "/subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry-account>/projects/<project>"
$botPrincipalId = az webapp identity show --name "<bot-host>" --resource-group "<rg>" --query principalId -o tsv
az role assignment create --assignee-object-id $botPrincipalId --assignee-principal-type ServicePrincipal --role "eed3b665-ab3a-47b6-8f48-c9382fb1dad6" --scope $projectScope
```

Append `/agents/<agent-name>` to the scope for agent-level assignment.

---

## 7. Bot logic

Pseudo-code of one Teams turn. Use the Teams SDK user-authentication APIs for the sign-in and token calls (names differ per language); the Foundry calls are plain REST.

```text
on message(turn):
    if not signed in:  start SSO for connection "gateway"; return             # silent for pre-authorized Teams clients
    gatewayToken = getToken(connection "gateway")                             # call late, the SDK refreshes near expiry

    foundryToken = managedIdentity.getToken("https://ai.azure.us/.default")   # DefaultAzureCredential with AuthorityHost = AzureGovernment
    conv = conversationFor(turn.user.aadObjectId)                             # one Foundry conversation per Teams user, never shared
          or POST {endpoint}/openai/v1/conversations

    input = [ { type: "message", role: "user", content: turn.text } ]
    loop (max 10 rounds, stop before the 10-minute run limit):
        resp = POST {endpoint}/openai/v1/responses
               { agent: { type: "agent_reference", name: "<agent-name>" }, conversation: conv, input: input }
        calls = resp.output where type == "function_call"
        if none: break
        input = []
        for call in calls:
            result = callApim(call.name, parse(call.arguments), gatewayToken)  # section 8
            input += { type: "function_call_output", call_id: call.call_id, output: json(result) }

    send(turn, resp.output_text)
```

Rules that matter:

- Never log `gatewayToken` or `foundryToken`; never put them in tool output or agent instructions.
- Tool outputs are untrusted input to the model: keep the bounding APIM already does and return only the fields the answer needs.
- Keep Foundry conversations per user. Do not reuse a conversation across users.
- Submit all `function_call_output` items of one response in a single Responses call.

---

## 8. Executing a tool against APIM

Option REST (simplest): call the facade operations behind the MCP server.

```text
GET https://<apim>.azure-api.us/<rest-path>/messages?page_size=10
Authorization: Bearer <gateway token>
```

Map each function name to its facade path (`/messages`, `/messages/{id}`, `/calendar-view?start=&end=`, `/events/{id}`, `/chats`, ...). Return the JSON body as the function output.

Option MCP: call the MCP server the agent used before, with an MCP client library (`ModelContextProtocol` for .NET, `mcp` with `streamablehttp_client` for Python). Flow: `initialize`, `notifications/initialized`, then `tools/call` with `name` and `arguments` from the function call, sending `Authorization: Bearer <gateway token>` on every request and echoing the `Mcp-Session-Id` header the server returns. Use this when you want the bot and the Foundry-native path to share one tool contract exactly.

Either way APIM sees a delegated token for the gateway audience with `access_as_user`, validates it, and performs the OBO to `graph.microsoft.us` as it does today.

---

## 9. Teams app package and publication

Manifest essentials:

```json
"bots": [ { "botId": "<bot-app-id>", "scopes": ["personal"], "supportsFiles": false, "isNotificationOnly": false } ],
"webApplicationInfo": { "id": "<bot-app-id>", "resource": "api://botid-<bot-app-id>" },
"validDomains": [ "*.botframework.azure.us" ]
```

Publish: a Teams admin uploads the package in the GCC High Teams admin center (**Teams apps > Manage apps > Upload new app**) and makes it available with app permission and setup policies. User upload (sideloading) is not available in GCC High.

---

## 10. What stays the same

APIM policies, JWT validation, OBO, Key Vault secret, Graph consent on the gateway app. When the Foundry custom OAuth connection write is fixed in Gov, you can switch the agent back to the hosted MCP tool without touching the backend; the bot then becomes optional.

---

## 11. Verification

1. Teams: open the bot, send "what are my last 3 emails". First turn should sign in silently (pre-authorized Teams clients) or show one consent card. Second user: repeat; each user must get their own mailbox.
2. Foundry tracing: the response shows a `function_call` item, then the final text after `function_call_output`.
3. APIM analytics shows the calls with the bot auth app as caller; Graph calls still come from APIM with the OBO token.
4. Negative tests: a user without a mailbox gets a clean error, not another user's data; an expired user token triggers a new sign-in rather than a failure loop; no bearer token appears in logs or in tool output.
5. Load: Responses runs expire after 10 minutes; make sure tool execution plus model time stays well under that.

---

## 12. References

- Bot Service in Azure Government and GCC High settings: https://learn.microsoft.com/azure/bot-service/how-to-deploy-gov-cloud-high
- Teams SDK sovereign cloud configuration: https://learn.microsoft.com/microsoftteams/platform/teams-sdk/essentials/app-configuration/sovereign-cloud
- Teams SSO setup (app registration, OAuth connection, manifest): https://learn.microsoft.com/microsoftteams/platform/teams-sdk/teams/user-authentication/sso-setup
- Teams app capabilities per government cloud (no custom app upload in GCC High): https://learn.microsoft.com/microsoftteams/platform/concepts/cloud-overview
- Foundry Agent Service in Azure Government (endpoint, token scope, SDK version): https://learn.microsoft.com/azure/foundry/agents/concepts/azure-government
- Function calling with Foundry agents (REST payloads): https://learn.microsoft.com/azure/foundry/agents/how-to/tools/function-calling
- Foundry RBAC, Foundry Agent Consumer at project or agent scope: https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry
