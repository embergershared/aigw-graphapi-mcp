using GraphMcp.TestClient;
using System.Net;
using System.Text.Json;
using Xunit;

namespace GraphMcp.TestClient.Tests;

public sealed class GatewayTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Rest_verifies_all_four_tools_with_only_explicit_validated_continuation(bool followContinuation)
    {
        Configuration config = TestData.Config();
        int nextPages = 0;
        using FakeHandler handler = new((request, _) =>
        {
            Assert.Equal(HttpMethod.Get, request.Method);
            Assert.Equal("contoso.azure-api.net", request.RequestUri!.Host);
            Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
            Assert.Equal("synthetic-token", request.Headers.Authorization.Parameter);
            string path = request.RequestUri.AbsolutePath;
            bool list = path is "/graph/messages" or "/graph/calendar-view";
            bool calendar = path == "/graph/calendar-view";
            string id = path.StartsWith("/graph/messages", StringComparison.Ordinal) ? config.MessageId : config.EventId;
            if (!list) { return Task.FromResult(TestData.Response(TestData.Detail(id).GetRawText())); }
            if (request.RequestUri.Query.Contains("continuation=", StringComparison.Ordinal))
            {
                nextPages++;
                Assert.StartsWith("?continuation=", request.RequestUri.Query, StringComparison.Ordinal);
                Assert.DoesNotContain("&", request.RequestUri.Query, StringComparison.Ordinal);
                return Task.FromResult(TestData.Response(TestData.Page(id).GetRawText()));
            }
            Assert.Contains("page_size=10", request.RequestUri.Query, StringComparison.Ordinal);
            if (calendar)
            {
                Assert.Contains("start=", request.RequestUri.Query, StringComparison.Ordinal);
                Assert.Contains("end=", request.RequestUri.Query, StringComparison.Ordinal);
            }
            return Task.FromResult(TestData.Response(TestData.Page(id, TestData.Cursor(calendar ? "list_calendar_view" : "list_messages")).GetRawText()));
        });
        using HttpClient http = new(handler);
        Continuations cursors = new(TestData.Contract);
        RestGatewayClient rest = new(http, config, TestData.Contract, cursors, _ => Task.FromResult("synthetic-token"));
        await Verification.VerifyFixturesAsync(rest, config, TestData.Contract, cursors, followContinuation, CancellationToken.None);
        Assert.Equal(followContinuation ? 6 : 4, handler.Count);
        Assert.Equal(followContinuation ? 2 : 0, nextPages);
    }

    [Fact]
    public async Task Rest_does_not_invent_success_when_synthetic_lists_are_empty()
    {
        using FakeHandler handler = new((_, _) => Task.FromResult(TestData.Response("{\"items\":[],\"continuation\":null}")));
        using HttpClient http = new(handler);
        Continuations cursors = new(TestData.Contract);
        RestGatewayClient rest = new(http, TestData.Config(), TestData.Contract, cursors, _ => Task.FromResult("synthetic"));
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            Verification.VerifyFixturesAsync(rest, TestData.Config(), TestData.Contract, cursors, false, CancellationToken.None));
        Assert.Equal(FailureCode.FixturesMissing, error.Code);
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task Native_streamable_http_initializes_lists_exact_schemas_and_reads_every_fixture()
    {
        Configuration config = TestData.Config();
        List<string> methods = [];
        using FakeHandler handler = new(async (request, ct) =>
        {
            Assert.Equal(HttpMethod.Post, request.Method);
            Assert.Equal(config.McpEndpoint, request.RequestUri);
            Assert.Equal("synthetic-token", request.Headers.Authorization!.Parameter);
            Assert.Contains(request.Headers.Accept, v => v.MediaType == "application/json");
            Assert.Contains(request.Headers.Accept, v => v.MediaType == "text/event-stream");
            JsonElement envelope = TestData.Json(await request.Content!.ReadAsStringAsync(ct));
            Assert.Equal("2.0", envelope.GetProperty("jsonrpc").GetString());
            string method = envelope.GetProperty("method").GetString()!;
            methods.Add(method);
            if (method == "notifications/initialized")
            {
                Assert.False(envelope.TryGetProperty("id", out _));
                Assert.Equal("synthetic-session", Assert.Single(request.Headers.GetValues("Mcp-Session-Id")));
                return new(HttpStatusCode.Accepted);
            }
            int id = envelope.GetProperty("id").GetInt32();
            if (method == "initialize")
            {
                Assert.False(request.Headers.Contains("Mcp-Session-Id"));
                Assert.False(request.Headers.Contains("MCP-Protocol-Version"));
                Assert.Equal("2025-03-26", envelope.GetProperty("params").GetProperty("protocolVersion").GetString());
                HttpResponseMessage response = TestData.Response(JsonSerializer.Serialize(new
                {
                    jsonrpc = "2.0",
                    id,
                    result = new { protocolVersion = "2025-03-26", capabilities = new { tools = new { } }, serverInfo = new { name = "synthetic", version = "1" } }
                }));
                response.Headers.Add("Mcp-Session-Id", "synthetic-session");
                return response;
            }
            Assert.Equal("2025-03-26", Assert.Single(request.Headers.GetValues("MCP-Protocol-Version")));
            Assert.Equal("synthetic-session", Assert.Single(request.Headers.GetValues("Mcp-Session-Id")));
            if (method == "tools/list")
            {
                return TestData.Response(JsonSerializer.Serialize(new { jsonrpc = "2.0", id, result = TestData.Schemas() }));
            }
            Assert.Equal("tools/call", method);
            JsonElement parameters = envelope.GetProperty("params");
            string tool = parameters.GetProperty("name").GetString()!;
            string fixture = tool is "list_messages" or "get_message" ? config.MessageId : config.EventId;
            JsonElement payload = tool.StartsWith("list_", StringComparison.Ordinal) ? TestData.Page(fixture) : TestData.Detail(fixture);
            string resultJson = JsonSerializer.Serialize(new { jsonrpc = "2.0", id, result = new { content = new[] { new { type = "text", text = payload.GetRawText() } }, isError = false } });
            return TestData.Response("event: message\ndata: " + resultJson + "\n\n", type: "text/event-stream");
        });
        using HttpClient http = new(handler);
        Continuations cursors = new(TestData.Contract);
        NativeMcpClient client = new(http, config, TestData.Contract, cursors, _ => Task.FromResult("synthetic-token"));
        await client.InitializeAsync(CancellationToken.None);
        await client.ListToolsAsync(CancellationToken.None);
        await Verification.VerifyFixturesAsync(client, config, TestData.Contract, cursors, false, CancellationToken.None);
        Assert.Equal([ "initialize", "notifications/initialized", "tools/list", "tools/call", "tools/call", "tools/call", "tools/call" ], methods);
    }

    [Fact]
    public async Task Native_session_state_is_not_shared_between_users()
    {
        int minted = 0;
        using FakeHandler handler = new(async (request, ct) =>
        {
            JsonElement envelope = TestData.Json(await request.Content!.ReadAsStringAsync(ct));
            string method = envelope.GetProperty("method").GetString()!;
            if (method == "notifications/initialized") { return new(HttpStatusCode.Accepted); }
            Assert.False(request.Headers.Contains("Mcp-Session-Id"));
            int id = envelope.GetProperty("id").GetInt32();
            HttpResponseMessage response = TestData.Response(JsonSerializer.Serialize(new
            {
                jsonrpc = "2.0",
                id,
                result = new { protocolVersion = "2025-03-26", capabilities = new { tools = new { } } }
            }));
            response.Headers.Add("Mcp-Session-Id", "user-" + minted++);
            return response;
        });
        using HttpClient http = new(handler);
        NativeMcpClient first = new(http, TestData.Config(), TestData.Contract, new(TestData.Contract), _ => Task.FromResult("synthetic-one"));
        NativeMcpClient second = new(http, TestData.Config(), TestData.Contract, new(TestData.Contract), _ => Task.FromResult("synthetic-two"));
        await first.InitializeAsync(CancellationToken.None);
        await second.InitializeAsync(CancellationToken.None);
        Assert.Equal(4, handler.Count);
    }

    [Theory]
    [InlineData("write_message")]
    [InlineData("shared_messages")]
    public void Native_tool_schema_allowlist_rejects_replaced_tools(string name)
    {
        string json = TestData.Schemas().GetRawText().Replace("\"get_event\"", "\"" + name + "\"", StringComparison.Ordinal);
        Assert.Throws<VerificationException>(() => NativeMcpClient.ValidateToolSchemas(TestData.Json(json), TestData.Contract));
    }

    [Theory]
    [InlineData("\"maximum\":25", "\"maximum\":100")]
    [InlineData("\"default\":10", "\"default\":25")]
    [InlineData("\"maxLength\":2048", "\"maxLength\":9999")]
    [InlineData("\"format\":\"date-time\"", "\"format\":\"date\"")]
    public void Native_schema_checks_more_than_tool_names(string before, string after)
    {
        string json = TestData.Schemas().GetRawText().Replace(before, after, StringComparison.Ordinal);
        Assert.Throws<VerificationException>(() => NativeMcpClient.ValidateToolSchemas(TestData.Json(json), TestData.Contract));
    }

    [Theory]
    [InlineData("{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"synthetic error\"}]}")]
    [InlineData("{\"content\":[{\"type\":\"image\",\"data\":\"synthetic\"}]}")]
    [InlineData("{\"content\":[]}")]
    public void Native_tool_errors_and_nonjson_content_cannot_appear_successful(string json)
    {
        Assert.Throws<VerificationException>(() => NativeMcpClient.ExtractPayload(TestData.Json(json), 65536));
    }

    [Fact]
    public void List_bodies_and_html_details_are_rejected()
    {
        JsonElement list = TestData.Json("{\"items\":[{\"id\":\"synthetic\",\"body\":{\"content\":\"no\"}}],\"continuation\":null}");
        Assert.Throws<VerificationException>(() => Verification.ValidatePayload("list_messages", list, TestData.Contract, new(TestData.Contract)));
        JsonElement html = TestData.Json("{\"id\":\"synthetic\",\"body\":{\"contentType\":\"html\",\"content\":\"<p>no</p>\"}}");
        Assert.Throws<VerificationException>(() => Verification.ValidatePayload("get_message", html, TestData.Contract, new(TestData.Contract)));
    }
}
