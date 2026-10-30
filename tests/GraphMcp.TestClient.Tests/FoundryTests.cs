using Azure.AI.Projects.Agents;
using GraphMcp.TestClient;
using OpenAI.Responses;
using System.ClientModel.Primitives;
using System.Text.Json;
using Xunit;

namespace GraphMcp.TestClient.Tests;

public sealed class FoundryTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Consent_and_approval_use_distinct_inputs_and_correct_identity_contracts(bool copilot)
    {
        Configuration config = TestData.Config("foundry") with { Harness = copilot ? Harness.Copilot : Harness.Responses };
        ResponseItem consent = Consent("https://contoso.services.ai.azure.com/oauth/consent?state=synthetic");
        FakeFoundry service = new([
            Response("r1", consent),
            Response("r2", Approvals(config)),
            Response("r3", Calls(config))
        ]);
        FakeInteraction interaction = new();
        FoundryVerifier verifier = new(config, TestData.Contract, service, interaction);
        await verifier.RunAsync(CancellationToken.None);
        Assert.Equal(1, interaction.ConsentCount);
        Assert.Equal(4, interaction.ApprovalCount);
        Assert.Equal("https://contoso.services.ai.azure.com/oauth/consent?state=synthetic", interaction.LastConsent!.AbsoluteUri);
        Assert.IsAssignableFrom<MessageResponseItem>(Assert.Single(service.Requests[ 1 ].Options.InputItems));
        Assert.All(service.Requests[ 2 ].Options.InputItems, item => Assert.IsType<McpToolCallApprovalResponseItem>(item));
        if (copilot)
        {
            Assert.Equal(1, service.ConversationsCreated);
            Assert.Equal("synthetic-conversation", verifier.ConversationId);
            Assert.All(service.Requests, request =>
            {
                Assert.Null(request.Options.PreviousResponseId);
                Assert.Equal("synthetic-conversation", request.ConversationId);
                Assert.Equal("synthetic-conversation", request.Options.ConversationOptions.ConversationId);
            });
        }
        else
        {
            Assert.Equal(0, service.ConversationsCreated);
            Assert.Null(verifier.ConversationId);
            Assert.Null(service.Requests[ 0 ].Options.PreviousResponseId);
            Assert.Equal("r1", service.Requests[ 1 ].Options.PreviousResponseId);
            Assert.Equal("r2", service.Requests[ 2 ].Options.PreviousResponseId);
            Assert.All(service.Requests, request => Assert.Null(request.Options.ConversationOptions));
        }
        Assert.Equal("r3", verifier.PreviousResponseId);
        Assert.Equal(3, verifier.ResponseCount);
        await Assert.ThrowsAsync<VerificationException>(() => verifier.RunAsync(CancellationToken.None));
    }

    [Fact]
    public async Task Local_denial_is_sent_once_and_never_automatically_reapproved()
    {
        Configuration config = TestData.Config("foundry");
        FakeFoundry service = new([ Response("r1", Approvals(config)), Response("r2") ]);
        FakeInteraction interaction = new() { Approve = false };
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            new FoundryVerifier(config, TestData.Contract, service, interaction).RunAsync(CancellationToken.None));
        Assert.Equal(FailureCode.ApprovalDenied, error.Code);
        Assert.Equal(2, service.Requests.Count);
        foreach (ResponseItem item in service.Requests[ 1 ].Options.InputItems)
        {
            JsonElement json = TestData.Json(ModelReaderWriter.Write(item).ToString());
            Assert.False(json.GetProperty("approve").GetBoolean());
        }
    }

    [Theory]
    [InlineData("other_server", "list_messages", "{\"page_size\":10}")]
    [InlineData("own_graph", "delete_message", "{\"message_id\":\"synthetic-message\"}")]
    [InlineData("own_graph", "get_message", "{\"message_id\":\"another-users-data\"}")]
    [InlineData("own_graph", "list_messages", "{\"page_size\":26}")]
    [InlineData("own_graph", "list_messages", "{\"url\":\"https://fabrikam.example\"}")]
    public async Task Unknown_servers_tools_and_nonfixture_arguments_are_denied_without_prompt(string server, string tool, string args)
    {
        McpToolCallApprovalRequestItem approval = new("approval-one", server, tool, BinaryData.FromString(args));
        FakeFoundry service = new([ Response("r1", approval), Response("r2") ]);
        FakeInteraction interaction = new();
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            new FoundryVerifier(TestData.Config("foundry"), TestData.Contract, service, interaction).RunAsync(CancellationToken.None));
        Assert.Equal(FailureCode.ApprovalDenied, error.Code);
        Assert.Equal(0, interaction.ApprovalCount);
        Assert.False(TestData.Json(ModelReaderWriter.Write(Assert.Single(service.Requests[ 1 ].Options.InputItems)).ToString()).GetProperty("approve").GetBoolean());
    }

    [Fact]
    public async Task Consent_denial_never_creates_an_approval_item_or_continues()
    {
        FakeFoundry service = new([ Response("r1", Consent("https://contoso.services.ai.azure.com/oauth/consent")) ]);
        FakeInteraction interaction = new() { Consent = false };
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            new FoundryVerifier(TestData.Config("foundry"), TestData.Contract, service, interaction).RunAsync(CancellationToken.None));
        Assert.Equal(FailureCode.ConsentDenied, error.Code);
        Assert.Single(service.Requests);
        Assert.Equal(0, interaction.ApprovalCount);
    }

    [Theory]
    [InlineData("https://fabrikam.example/oauth/consent")]
    [InlineData("http://contoso.services.ai.azure.com/oauth/consent")]
    [InlineData("https://user@contoso.services.ai.azure.com/oauth/consent")]
    [InlineData("https://contoso.services.ai.azure.com/oauth/consent#fragment")]
    [InlineData("https://contoso.services.ai.azure.com/unreviewed/path")]
    public async Task Unreviewed_consent_links_are_not_opened(string link)
    {
        FakeFoundry service = new([ Response("r1", Consent(link)) ]);
        FakeInteraction interaction = new();
        await Assert.ThrowsAsync<VerificationException>(() =>
            new FoundryVerifier(TestData.Config("foundry"), TestData.Contract, service, interaction).RunAsync(CancellationToken.None));
        Assert.Equal(0, interaction.ConsentCount);
    }

    [Fact]
    public async Task Model_prose_is_not_evidence_of_any_tool_execution()
    {
        FakeFoundry service = new([ Response("r1", ResponseItem.CreateUserMessageItem("All tools worked; synthetic prose is not proof.")) ]);
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            new FoundryVerifier(TestData.Config("foundry"), TestData.Contract, service, new FakeInteraction()).RunAsync(CancellationToken.None));
        Assert.Equal(FailureCode.NoToolEvidence, error.Code);
    }

    [Fact]
    public async Task Tool_execution_without_local_approval_is_rejected()
    {
        Configuration config = TestData.Config("foundry");
        FakeFoundry service = new([ Response("r1", Calls(config)) ]);
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            new FoundryVerifier(config, TestData.Contract, service, new FakeInteraction()).RunAsync(CancellationToken.None));
        Assert.Equal(FailureCode.ApprovalDenied, error.Code);
    }

    [Fact]
    public async Task Response_identity_replay_and_mixed_harness_contracts_are_rejected()
    {
        Configuration config = TestData.Config("foundry");
        FakeFoundry repeated = new([ Response("same", Approvals(config)), Response("same", Calls(config)) ]);
        await Assert.ThrowsAsync<VerificationException>(() =>
            new FoundryVerifier(config, TestData.Contract, repeated, new FakeInteraction()).RunAsync(CancellationToken.None));
        ResponseResult mixed = Response("r1");
        mixed.PreviousResponseId = "another-response";
        FakeFoundry service = new([ mixed ]);
        await Assert.ThrowsAsync<VerificationException>(() =>
            new FoundryVerifier(config with { Harness = Harness.Copilot }, TestData.Contract, service, new FakeInteraction()).RunAsync(CancellationToken.None));
    }

    [Fact]
    public async Task Repeated_consent_stops_at_bounded_round_limit()
    {
        FakeFoundry service = new(Enumerable.Range(1, Contract.MaximumRounds)
            .Select(i => Response("r" + i, Consent("https://contoso.services.ai.azure.com/oauth/consent"))));
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            new FoundryVerifier(TestData.Config("foundry"), TestData.Contract, service, new FakeInteraction()).RunAsync(CancellationToken.None));
        Assert.Equal(FailureCode.RoundLimit, error.Code);
        Assert.Equal(Contract.MaximumRounds, service.Requests.Count);
    }

    [Fact]
    public async Task Empty_fixture_results_and_tool_failures_cannot_be_successful()
    {
        Configuration config = TestData.Config("foundry");
        McpToolCallItem[] calls = Calls(config);
        calls[ 0 ].ToolOutput = "{\"items\":[],\"continuation\":null}";
        FakeFoundry service = new([ Response("r1", Approvals(config)), Response("r2", calls) ]);
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            new FoundryVerifier(config, TestData.Contract, service, new FakeInteraction()).RunAsync(CancellationToken.None));
        Assert.Equal(FailureCode.FixturesMissing, error.Code);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Sdk_native_tool_list_is_schema_checked_when_returned(bool invalidSchema)
    {
        Configuration config = TestData.Config("foundry");
        JsonElement[] tools = TestData.Schemas().GetProperty("tools").EnumerateArray().Select(tool =>
            TestData.Args(new { name = tool.GetProperty("name").GetString(), input_schema = tool.GetProperty("inputSchema") })).ToArray();
        string json = JsonSerializer.Serialize(new { type = "mcp_list_tools", server_label = "own_graph", tools });
        if (invalidSchema) { json = json.Replace("\"maximum\":25", "\"maximum\":999", StringComparison.Ordinal); }
        ResponseItem list = ModelReaderWriter.Read<ResponseItem>(BinaryData.FromString(json))!;
        FakeFoundry service = new([ Response("r1", new[] { list }.Concat(Approvals(config)).ToArray()), Response("r2", Calls(config)) ]);
        FoundryVerifier verifier = new(config, TestData.Contract, service, new FakeInteraction());
        if (invalidSchema)
        {
            VerificationException error = await Assert.ThrowsAsync<VerificationException>(() => verifier.RunAsync(CancellationToken.None));
            Assert.Equal(FailureCode.InvalidProtocol, error.Code);
        }
        else
        {
            await verifier.RunAsync(CancellationToken.None);
            Assert.Equal(2, verifier.ResponseCount);
        }
    }

    [Fact]
    public async Task Approval_replay_and_output_argument_changes_are_rejected()
    {
        Configuration config = TestData.Config("foundry");
        McpToolCallApprovalRequestItem approval = Approvals(config)[ 0 ];
        FakeFoundry replay = new([ Response("r1", approval), Response("r2", approval) ]);
        VerificationException repeated = await Assert.ThrowsAsync<VerificationException>(() =>
            new FoundryVerifier(config, TestData.Contract, replay, new FakeInteraction()).RunAsync(CancellationToken.None));
        Assert.Equal(FailureCode.InvalidProtocol, repeated.Code);
        McpToolCallItem[] calls = Calls(config);
        calls[ 0 ].ToolArguments = BinaryData.FromString("{\"page_size\":25}");
        FakeFoundry changed = new([ Response("r1", Approvals(config)), Response("r2", calls) ]);
        await Assert.ThrowsAsync<VerificationException>(() =>
            new FoundryVerifier(config, TestData.Contract, changed, new FakeInteraction()).RunAsync(CancellationToken.None));
    }

    [Fact]
    public async Task Foundry_continuation_is_returned_bound_to_session_and_separately_approved()
    {
        Configuration config = TestData.Config("foundry");
        string cursor = TestData.Cursor();
        McpToolCallApprovalRequestItem firstApproval = Approvals(config)[ 0 ];
        McpToolCallItem firstCall = Calls(config)[ 0 ];
        firstCall.ToolOutput = TestData.Page("synthetic-other-message", cursor).GetRawText();
        BinaryData continuationArgs = BinaryData.FromString(TestData.Args(new { continuation = cursor }).GetRawText());
        McpToolCallApprovalRequestItem nextApproval = new("next-page-approval", Contract.ServerLabel, "list_messages", continuationArgs);
        McpToolCallItem nextCall = new(Contract.ServerLabel, "list_messages", continuationArgs) { ToolOutput = TestData.Page(config.MessageId).GetRawText() };
        FakeFoundry service = new([
            Response("r1", firstApproval),
            Response("r2", firstCall, nextApproval),
            Response("r3", new ResponseItem[] { nextCall }.Concat(Approvals(config).Skip(1)).ToArray()),
            Response("r4", Calls(config).Skip(1).ToArray())
        ]);
        FakeInteraction interaction = new();
        FoundryVerifier verifier = new(config, TestData.Contract, service, interaction);
        await verifier.RunAsync(CancellationToken.None);
        Assert.Equal(5, interaction.ApprovalCount);
        Assert.Equal(4, verifier.ResponseCount);
    }

    [Fact]
    public async Task Cancellation_does_not_retry_or_reuse_a_foundry_session()
    {
        Configuration config = TestData.Config("foundry");
        FakeFoundry service = new([]);
        FoundryVerifier verifier = new(config, TestData.Contract, service, new FakeInteraction());
        using CancellationTokenSource cancellation = new();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => verifier.RunAsync(cancellation.Token));
        Assert.Empty(service.Requests);
        await Assert.ThrowsAsync<VerificationException>(() => verifier.RunAsync(CancellationToken.None));
    }

    [Fact]
    public void Agent_definition_has_exact_native_four_tool_connection_and_always_approval_contract()
    {
        Configuration config = TestData.Config("definition");
        AgentPlan plan = AgentPlan.Build(config);
        AgentPlan.ValidateExisting(plan.Options.Definition, config);
        DeclarativeAgentDefinition definition = Assert.IsType<DeclarativeAgentDefinition>(plan.Options.Definition);
        McpTool tool = Assert.IsType<McpTool>(Assert.Single(definition.Tools));
        Assert.Equal(config.McpEndpoint, tool.ServerUri);
        Assert.Equal(Contract.ServerLabel, tool.ServerLabel);
        Assert.Equal(Contract.ToolNames, tool.AllowedTools.ToolNames);
        Assert.Equal(GlobalMcpToolCallApprovalPolicy.AlwaysRequireApproval, tool.ToolCallApprovalPolicy.GlobalPolicy);
        Assert.Equal(config.ConnectionName, tool.ProjectConnectionId);
        Assert.Null(tool.AuthorizationToken);
        Assert.True(tool.Headers is null || tool.Headers.Count == 0);
        Assert.Equal(plan.Fingerprint, plan.Options.Metadata[ "graph-mcp-fingerprint" ]);
        Assert.Equal(plan.Fingerprint, AgentPlan.Build(config).Fingerprint);
        JsonElement json = TestData.Json(ModelReaderWriter.Write(definition).ToString());
        JsonElement serializedTool = json.GetProperty("tools")[ 0 ];
        Assert.Equal("always", serializedTool.GetProperty("require_approval").GetString());
        Assert.Equal(config.ConnectionName, serializedTool.GetProperty("project_connection_id").GetString());
        tool.AllowedTools.ToolNames.Add("write_message");
        Assert.Throws<VerificationException>(() => AgentPlan.ValidateExisting(definition, config));
    }

    [Fact]
    public async Task Local_preview_contains_actual_usable_sdk_options_and_no_credentials()
    {
        Configuration config = TestData.Config("definition");
        AgentPlan plan = AgentPlan.Build(config);
        string directory = Path.Combine(AppContext.BaseDirectory, "artifacts", "synthetic-preview-" + Guid.NewGuid().ToString("N"));
        try
        {
            string first = await plan.WriteLocalPreviewAsync(config, directory, CancellationToken.None);
            string second = await plan.WriteLocalPreviewAsync(config, directory, CancellationToken.None);
            Assert.NotEqual(first, second);
            Assert.EndsWith(".preview.json", first, StringComparison.Ordinal);
            Assert.Equal(2, Directory.GetFiles(directory).Length);
            string json = await File.ReadAllTextAsync(first);
            ProjectsAgentVersionCreationOptions parsed = ModelReaderWriter.Read<ProjectsAgentVersionCreationOptions>(BinaryData.FromString(json))!;
            AgentPlan.ValidateExisting(parsed.Definition, config);
            DeclarativeAgentDefinition definition = Assert.IsType<DeclarativeAgentDefinition>(parsed.Definition);
            McpTool tool = Assert.IsType<McpTool>(Assert.Single(definition.Tools));
            Assert.Equal(config.McpEndpoint, tool.ServerUri);
            Assert.Equal(config.Model, definition.Model);
            Assert.Equal(config.ConnectionName, tool.ProjectConnectionId);
            Assert.Equal(Contract.ToolNames, tool.AllowedTools.ToolNames);
            Assert.Equal(GlobalMcpToolCallApprovalPolicy.AlwaysRequireApproval, tool.ToolCallApprovalPolicy.GlobalPolicy);
            Assert.Equal(plan.Fingerprint, parsed.Metadata[ "graph-mcp-fingerprint" ]);
            Assert.Equal("v1", parsed.Metadata[ "graph-mcp-contract" ]);
            JsonElement serializedTool = TestData.Json(json).GetProperty("definition").GetProperty("tools")[ 0 ];
            Assert.False(serializedTool.TryGetProperty("authorization", out _));
            Assert.False(serializedTool.TryGetProperty("headers", out _));
            Assert.DoesNotContain("consent_link", json, StringComparison.Ordinal);
            Assert.DoesNotContain("client_secret", json, StringComparison.Ordinal);
        }
        finally
        {
            if (Directory.Exists(directory)) { Directory.Delete(directory, recursive: true); }
        }
    }

    [Fact]
    public async Task Local_preview_rejects_embedded_credentials_before_creating_a_file()
    {
        Configuration config = TestData.Config("definition");
        AgentPlan plan = AgentPlan.Build(config);
        DeclarativeAgentDefinition definition = Assert.IsType<DeclarativeAgentDefinition>(plan.Options.Definition);
        Assert.IsType<McpTool>(Assert.Single(definition.Tools)).AuthorizationToken = "synthetic-forbidden-token";
        string directory = Path.Combine(AppContext.BaseDirectory, "artifacts", "synthetic-invalid-preview-" + Guid.NewGuid().ToString("N"));
        await Assert.ThrowsAsync<VerificationException>(() => plan.WriteLocalPreviewAsync(config, directory, CancellationToken.None));
        Assert.False(Directory.Exists(directory));
    }

    [Theory]
    [InlineData("approval")]
    [InlineData("header")]
    [InlineData("authorization")]
    [InlineData("server")]
    [InlineData("endpoint")]
    [InlineData("connection")]
    public void Agent_validation_rejects_bypassed_approval_or_embedded_credentials(string change)
    {
        Configuration config = TestData.Config("definition");
        DeclarativeAgentDefinition definition = Assert.IsType<DeclarativeAgentDefinition>(AgentPlan.Build(config).Options.Definition);
        McpTool tool = Assert.IsType<McpTool>(Assert.Single(definition.Tools));
        switch (change)
        {
            case "approval": tool.ToolCallApprovalPolicy = new(GlobalMcpToolCallApprovalPolicy.NeverRequireApproval); break;
            case "header": tool.Headers = new Dictionary<string, string> { [ "Authorization" ] = "synthetic" }; break;
            case "authorization": tool.AuthorizationToken = "synthetic"; break;
            case "server": tool.ServerLabel = "unreviewed"; break;
            case "endpoint": tool.ServerUri = new Uri("https://fabrikam.example/mcp"); break;
            case "connection": tool.ProjectConnectionId = "other-connection"; break;
        }
        Assert.Throws<VerificationException>(() => AgentPlan.ValidateExisting(definition, config));
    }

    private static McpToolCallApprovalRequestItem[] Approvals(Configuration config)
    {
        return Arguments(config).Select((entry, i) => new McpToolCallApprovalRequestItem(
            "approval-" + i, Contract.ServerLabel, entry.Tool, BinaryData.FromString(entry.Arguments.GetRawText()))).ToArray();
    }

    private static McpToolCallItem[] Calls(Configuration config)
    {
        return Arguments(config).Select(entry => new McpToolCallItem(Contract.ServerLabel, entry.Tool, BinaryData.FromString(entry.Arguments.GetRawText()))
        {
            ToolOutput = (entry.Tool.StartsWith("list_", StringComparison.Ordinal)
                ? TestData.Page(entry.Tool == "list_messages" ? config.MessageId : config.EventId)
                : TestData.Detail(entry.Tool == "get_message" ? config.MessageId : config.EventId)).GetRawText()
        }).ToArray();
    }

    private static (string Tool, JsonElement Arguments)[] Arguments(Configuration config) =>
    [
        ("list_messages", TestData.Args(new { page_size = config.PageSize })),
        ("get_message", TestData.Args(new { message_id = config.MessageId })),
        ("list_calendar_view", TestData.Args(new { page_size = config.PageSize, start = config.Start, end = config.End })),
        ("get_event", TestData.Args(new { event_id = config.EventId }))
    ];

    private static ResponseItem Consent(string link) => ModelReaderWriter.Read<ResponseItem>(BinaryData.FromString(
        JsonSerializer.Serialize(new { type = "oauth_consent_request", consent_link = link, server_label = "own_graph" })))!;

    private static ResponseResult Response(string id, params ResponseItem[] items)
    {
        ResponseResult response = new() { Id = id, Status = ResponseStatus.Completed };
        foreach (ResponseItem item in items) { response.OutputItems.Add(item); }
        return response;
    }

    private sealed class FakeFoundry(IEnumerable<ResponseResult> responses) : IFoundryService
    {
        private readonly Queue<ResponseResult> _responses = new(responses);
        internal List<(CreateResponseOptions Options, string? ConversationId)> Requests { get; } = [];
        internal int ConversationsCreated { get; private set; }
        public Task<string> CreateConversationAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ConversationsCreated++;
            return Task.FromResult("synthetic-conversation");
        }
        public Task<ResponseResult> RespondAsync(CreateResponseOptions options, string? conversationId, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Requests.Add((options, conversationId));
            return Task.FromResult(_responses.Dequeue());
        }
    }

    private sealed class FakeInteraction : ILocalInteraction
    {
        internal bool Consent { get; init; } = true;
        internal bool Approve { get; init; } = true;
        internal int ConsentCount { get; private set; }
        internal int ApprovalCount { get; private set; }
        internal Uri? LastConsent { get; private set; }
        public Task<bool> ConsentAsync(Uri exactReturnedLink, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ConsentCount++;
            LastConsent = exactReturnedLink;
            return Task.FromResult(Consent);
        }
        public Task<bool> ApproveAsync(string tool, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ApprovalCount++;
            return Task.FromResult(Approve);
        }
    }
}
