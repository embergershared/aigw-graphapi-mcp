extern alias AzureIdentity;
using AzureIdentity::Azure.Identity;
using GraphMcp.TestClient;
using System.ClientModel;
using System.Text.Json;

using CancellationTokenSource cancellation = new();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cancellation.Cancel(); };
try
{
    Command command = Command.Parse(args);
    Contract contract = Contract.Load();
    if (command.Mode is "offline" or "help")
    {
        Diagnostics.Write("offline_contract", "validated_no_network", count: contract.Tools.Count);
        Console.WriteLine("Modes: offline (default), definition (local-only SDK JSON preview), direct, foundry.");
        Console.WriteLine("Live modes require --live --open-browser --synthetic. Direct additionally accepts --follow-continuation (one returned page per list).");
        Console.WriteLine($"UTF-8 serialized JSON limits: detail={contract.DetailMaxBytes}, list={contract.ListMaxBytes}, MCP/SDK envelope={Contract.EnvelopeMaxBytes}. No truncation or automatic retries.");
        Console.WriteLine("Configuration comes only from named GRAPH_MCP_ environment variables; never from .env files.");
        Console.WriteLine("All configured modes require GATEWAY_ORIGIN and exactly one of MCP_URL or MCP_PATH, copied from the actual deployed MCP endpoint. No MCP endpoint is guessed.");
        Console.WriteLine("Live required suffixes: GATEWAY_ORIGIN, TENANT_ID, CLIENT_ID, GATEWAY_SCOPE, SYNTHETIC_MESSAGE_ID, SYNTHETIC_EVENT_ID, CALENDAR_START, CALENDAR_END.");
        Console.WriteLine("Foundry additionally requires: PROJECT_ENDPOINT, MODEL_DEPLOYMENT, AGENT_NAME, AGENT_VERSION, CONNECTION_NAME, CONSENT_ORIGIN, CONSENT_PATH.");
        Console.WriteLine("Definition dry-run requires only: GATEWAY_ORIGIN, PROJECT_ENDPOINT, MODEL_DEPLOYMENT, AGENT_NAME, CONNECTION_NAME.");
        Console.WriteLine("Optional suffixes/defaults: REST_PATH=/graph, PAGE_SIZE=10, REDIRECT_URI=http://localhost:8400/, HARNESS=responses (or copilot).");
        Console.WriteLine("Definition writes actual SDK agent-version creation options to this build's ignored artifacts folder. Keep the resource-identifying preview local; do not commit it or upload it to public logs.");
        Console.WriteLine("Copilot selects conversation-only continuation; it never sends previous_response_id or configures a hosted harness. No apply mode exists.");
        return 0;
    }
    Configuration config = Configuration.Load(command, contract);
    if (command.Mode == "definition")
    {
        AgentPlan plan = AgentPlan.Build(config);
        string preview = await plan.WriteLocalPreviewAsync(config, Path.Combine(AppContext.BaseDirectory, "artifacts"), cancellation.Token);
        Diagnostics.Write("agent_definition", "local_sdk_preview_written_operator_apply_required", count: Contract.ToolNames.Length);
        Console.WriteLine($"Local-only SDK creation-options preview: {Path.GetRelativePath(Environment.CurrentDirectory, preview)}");
        Console.WriteLine("Keep this nonsecret but resource-identifying file local. Do not commit it, publish it, or copy it to public logs.");
        Console.WriteLine("No mutation performed. Operator must create/review the encrypted customOAuth project connection in the portal, verify gateway audience, tenant endpoints and exact returned callback, then separately apply and pin the agent version.");
        return 0;
    }
    using UserSession session = new(config);
    await session.AuthenticateAsync(command.Mode == "foundry", cancellation.Token);
    if (command.Mode == "direct")
    {
        using HttpClient http = BoundedHttp.CreateClient();
        Continuations restContinuations = new(contract);
        RestGatewayClient rest = new(http, config, contract, restContinuations, session.GetGatewayTokenAsync);
        await Verification.VerifyFixturesAsync(rest, config, contract, restContinuations, command.FollowContinuation, cancellation.Token);
        Diagnostics.Write("rest_verification", "synthetic_fixtures_verified", count: Contract.ToolNames.Length);
        Continuations mcpContinuations = new(contract);
        NativeMcpClient mcp = new(http, config, contract, mcpContinuations, session.GetGatewayTokenAsync);
        await mcp.InitializeAsync(cancellation.Token);
        await mcp.ListToolsAsync(cancellation.Token);
        await Verification.VerifyFixturesAsync(mcp, config, contract, mcpContinuations, command.FollowContinuation, cancellation.Token);
        Diagnostics.Write("native_mcp_verification", "synthetic_fixtures_verified", count: Contract.ToolNames.Length);
    }
    else
    {
        using FoundryService service = new(config, contract, session.Credential);
        await service.ValidateAgentAsync(cancellation.Token);
        FoundryVerifier verifier = new(config, contract, service, new LocalInteraction());
        await verifier.RunAsync(cancellation.Token);
        Diagnostics.Write("foundry_verification", "approved_tool_evidence_verified", count: verifier.ResponseCount);
    }
    return 0;
}
catch (VerificationException error) { Diagnostics.Failure(error); return (int)error.Code; }
catch (AuthenticationFailedException) { return Fail(FailureCode.Unauthorized); }
catch (ClientResultException error)
{
    FailureCode code = error.Status switch
    {
        401 => FailureCode.Unauthorized,
        403 => FailureCode.Forbidden,
        404 => FailureCode.NotFound,
        429 => FailureCode.Throttled,
        408 or 504 => FailureCode.Timeout,
        _ => FailureCode.Backend
    };
    Diagnostics.Failure(new VerificationException(code, error.Status));
    return (int)code;
}
catch (OperationCanceledException) { return Fail(cancellation.IsCancellationRequested ? FailureCode.Cancelled : FailureCode.Timeout); }
catch (HttpRequestException) { return Fail(FailureCode.Network); }
catch (System.ComponentModel.Win32Exception) { return Fail(FailureCode.Unsupported); }
catch (IOException) { return Fail(FailureCode.Network); }
catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or ArgumentException or System.Text.DecoderFallbackException)
{
    return Fail(FailureCode.InvalidProtocol);
}
catch (Exception) { return Fail(FailureCode.Unsupported); }

static int Fail(FailureCode code)
{
    Diagnostics.Failure(new VerificationException(code));
    return (int)code;
}
