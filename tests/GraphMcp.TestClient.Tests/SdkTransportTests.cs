using Azure.Core;
using GraphMcp.TestClient;
using OpenAI.Responses;
using System.Net;
using System.Text;
using System.Text.Json;
using Xunit;

namespace GraphMcp.TestClient.Tests;

public sealed class SdkTransportTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Current_sdk_sends_pinned_agent_and_only_the_selected_continuation_contract(bool copilot)
    {
        Configuration config = TestData.Config("foundry");
        JsonElement body = default;
        using FakeHandler handler = new(async (request, ct) =>
        {
            Assert.Equal(HttpMethod.Post, request.Method);
            Assert.Equal("contoso.services.ai.azure.com", request.RequestUri!.Host);
            Assert.StartsWith("/api/projects/synthetic/", request.RequestUri.AbsolutePath, StringComparison.Ordinal);
            Assert.EndsWith("/responses", request.RequestUri.AbsolutePath, StringComparison.Ordinal);
            Assert.Equal("synthetic-access-token", request.Headers.Authorization!.Parameter);
            body = TestData.Json(await request.Content!.ReadAsStringAsync(ct));
            return TestData.Response("{\"id\":\"synthetic-response\",\"object\":\"response\",\"created_at\":0,\"status\":\"completed\",\"model\":\"synthetic-model\",\"output\":[]}");
        });
        using FoundryService service = new(config, TestData.Contract, new SyntheticCredential(), handler);
        CreateResponseOptions options = new()
        {
            PreviousResponseId = copilot ? null : "synthetic-previous",
            ConversationOptions = copilot ? new ResponseConversationOptions("synthetic-conversation") : null,
            MaxOutputTokenCount = 2048,
            MaxToolCallCount = 4,
            InputItems = { ResponseItem.CreateUserMessageItem("Synthetic verification only.") }
        };
        ResponseResult response = await service.RespondAsync(options, copilot ? "synthetic-conversation" : null, CancellationToken.None);
        Assert.Equal("synthetic-response", response.Id);
        Assert.True(body.TryGetProperty("agent_reference", out JsonElement agent), body.GetRawText());
        Assert.Equal("synthetic-agent", agent.GetProperty("name").GetString());
        Assert.Equal("1", agent.GetProperty("version").GetString());
        if (copilot)
        {
            Assert.False(body.TryGetProperty("previous_response_id", out _));
            Assert.Contains("synthetic-conversation", body.GetRawText(), StringComparison.Ordinal);
        }
        else
        {
            Assert.Equal("synthetic-previous", body.GetProperty("previous_response_id").GetString());
            Assert.False(body.TryGetProperty("conversation", out _));
        }
        Assert.Equal(1, handler.Count);
    }

    [Theory]
    [InlineData(429, "Throttled")]
    [InlineData(302, "RedirectRejected")]
    public async Task Current_sdk_does_not_retry_redirects_or_throttling(int status, string expected)
    {
        Configuration config = TestData.Config("foundry");
        using FakeHandler handler = new((_, _) =>
        {
            HttpResponseMessage response = TestData.Response("{}", (HttpStatusCode)status);
            response.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromSeconds(120));
            return Task.FromResult(response);
        });
        using FoundryService service = new(config, TestData.Contract, new SyntheticCredential(), handler);
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            service.RespondAsync(new CreateResponseOptions(), null, CancellationToken.None));
        Assert.Equal(expected, error.Code.ToString());
        Assert.Equal(30, error.RetryAfter);
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task Current_sdk_fetches_the_exact_agent_version_and_validates_its_definition()
    {
        Configuration config = TestData.Config("foundry");
        AgentPlan plan = AgentPlan.Build(config);
        JsonElement definition = TestData.Json(System.ClientModel.Primitives.ModelReaderWriter.Write(plan.Options.Definition).ToString());
        using FakeHandler handler = new((request, _) =>
        {
            Assert.Equal(HttpMethod.Get, request.Method);
            Assert.EndsWith("/agents/synthetic-agent/versions/1", request.RequestUri!.AbsolutePath, StringComparison.Ordinal);
            string json = JsonSerializer.Serialize(new
            {
                id = "synthetic-agent-id",
                name = "synthetic-agent",
                version = "1",
                created_at = 0,
                definition,
                metadata = new Dictionary<string, string>()
            });
            return Task.FromResult(TestData.Response(json));
        });
        using FoundryService service = new(config, TestData.Contract, new SyntheticCredential(), handler);
        await service.ValidateAgentAsync(CancellationToken.None);
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task Current_sdk_creates_a_fresh_conversation_without_reusing_global_state()
    {
        Configuration config = TestData.Config("foundry");
        using FakeHandler handler = new((request, _) =>
        {
            Assert.Equal(HttpMethod.Post, request.Method);
            Assert.EndsWith("/conversations", request.RequestUri!.AbsolutePath, StringComparison.Ordinal);
            return Task.FromResult(TestData.Response("{\"id\":\"fresh-synthetic-conversation\",\"object\":\"conversation\",\"created_at\":0,\"metadata\":{}}"));
        });
        using FoundryService service = new(config, TestData.Contract, new SyntheticCredential(), handler);
        Assert.Equal("fresh-synthetic-conversation", await service.CreateConversationAsync(CancellationToken.None));
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task Sdk_guard_rejects_unexpected_hosts_and_paths_before_transport()
    {
        using FakeHandler handler = new((_, _) => throw new InvalidOperationException("The transport must not be reached."));
        using HttpClient client = new(new BoundedSdkHandler(TestData.Config("foundry").ProjectEndpoint!, TestData.Contract, handler));
        foreach (string uri in new[] { "https://fabrikam.example/api/projects/synthetic/openai/responses", "https://contoso.services.ai.azure.com/api/projects/other/openai/responses" })
        {
            VerificationException error = await Assert.ThrowsAsync<VerificationException>(() => client.GetAsync(new Uri(uri)));
            Assert.Equal(FailureCode.RedirectRejected, error.Code);
        }
        Assert.Equal(0, handler.Count);
    }

    [Fact]
    public async Task Sdk_envelope_is_bounded_before_sdk_deserialization()
    {
        Configuration config = TestData.Config("foundry");
        using FakeHandler handler = new((_, _) => Task.FromResult(TestData.Response(new string('a', Contract.EnvelopeMaxBytes + 1))));
        using FoundryService service = new(config, TestData.Contract, new SyntheticCredential(), handler);
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            service.RespondAsync(new CreateResponseOptions(), null, CancellationToken.None));
        Assert.Equal(FailureCode.ResponseTooLarge, error.Code);
        Assert.Equal(1, handler.Count);
    }

    private sealed class SyntheticCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            new("synthetic-access-token", DateTimeOffset.UtcNow.AddHours(1));

        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }
}
