using GraphMcp.TestClient;
using System.Text.Json;
using Xunit;

namespace GraphMcp.TestClient.Tests;

public sealed class ConfigurationTests
{
    [Fact]
    public void Default_is_offline_and_contract_has_approved_boundaries()
    {
        Assert.Equal("offline", Command.Parse([]).Mode);
        Assert.Equal(10, TestData.Contract.DefaultPageSize);
        Assert.Equal(25, TestData.Contract.MaximumPageSize);
        Assert.Equal(31, TestData.Contract.MaximumCalendarDays);
        Assert.Equal(65536, TestData.Contract.DetailMaxBytes);
        Assert.Equal(131072, TestData.Contract.ListMaxBytes);
        Assert.Equal(Contract.ToolNames.Order(), TestData.Contract.Tools.Keys.Order());
    }

    [Theory]
    [InlineData("direct")]
    [InlineData("foundry")]
    public void Live_modes_require_every_explicit_gate(string mode)
    {
        Assert.Throws<VerificationException>(() => Command.Parse([ mode ]));
        Assert.Throws<VerificationException>(() => Command.Parse([ mode, "--live", "--synthetic" ]));
        Assert.Throws<VerificationException>(() => Command.Parse([ mode, "--live", "--open-browser" ]));
        Assert.True(Command.Parse([ mode, "--live", "--open-browser", "--synthetic" ]).Live);
    }

    [Theory]
    [InlineData("apply")]
    [InlineData("rest")]
    [InlineData("--live")]
    public void Unknown_or_mutating_modes_are_rejected(string mode)
    {
        Assert.Throws<VerificationException>(() => Command.Parse([ mode ]));
    }

    [Fact]
    public void Offline_and_definition_cannot_accept_live_flags()
    {
        Assert.Throws<VerificationException>(() => Command.Parse([ "offline", "--live" ]));
        Assert.Throws<VerificationException>(() => Command.Parse([ "definition", "--live" ]));
        Assert.Throws<VerificationException>(() => Command.Parse([ "foundry", "--live", "--open-browser", "--synthetic", "--follow-continuation" ]));
    }

    [Theory]
    [InlineData("GATEWAY_ORIGIN", "http://contoso.azure-api.net")]
    [InlineData("GATEWAY_ORIGIN", "https://user@contoso.azure-api.net")]
    [InlineData("GATEWAY_ORIGIN", "https://contoso.azure-api.net:444")]
    [InlineData("GATEWAY_ORIGIN", "https://127.0.0.1")]
    [InlineData("GATEWAY_ORIGIN", "https://contoso.azure-api.net/path")]
    [InlineData("GATEWAY_ORIGIN", "https://contoso.azure-api.net/#fragment")]
    [InlineData("GATEWAY_ORIGIN", "https://contoso.azure-api.net/?token=value")]
    [InlineData("REST_PATH", "//fabrikam.example")]
    [InlineData("REST_PATH", "/graph/../other")]
    [InlineData("MCP_PATH", "/graph%2fmcp")]
    [InlineData("REDIRECT_URI", "https://localhost:8400/")]
    [InlineData("REDIRECT_URI", "http://fabrikam.example:8400/")]
    [InlineData("REDIRECT_URI", "http://localhost:80/")]
    [InlineData("REDIRECT_URI", "not-a-uri")]
    [InlineData("TENANT_ID", "common")]
    [InlineData("CLIENT_ID", "invalid")]
    [InlineData("GATEWAY_SCOPE", "https://graph.microsoft.com/.default")]
    [InlineData("GATEWAY_SCOPE", "api://00000000-0000-0000-0000-000000000000/.default")]
    [InlineData("PAGE_SIZE", "0")]
    [InlineData("PAGE_SIZE", "26")]
    [InlineData("SYNTHETIC_MESSAGE_ID", "https://graph.microsoft.com/me/messages/123")]
    [InlineData("CALENDAR_START", "2026-01-01T00:00:00")]
    public void Invalid_direct_configuration_fails_before_network(string name, string value)
    {
        Dictionary<string, string> env = TestData.Environment();
        env[ "GRAPH_MCP_" + name ] = value;
        Assert.Throws<VerificationException>(() => TestData.Config(environment: env));
    }

    [Fact]
    public void Missing_values_are_not_recovered_from_files_or_other_environment_names()
    {
        Dictionary<string, string> env = TestData.Environment();
        env.Remove("GRAPH_MCP_TENANT_ID");
        env[ "AZURE_TENANT_ID" ] = "00000000-0000-0000-0000-000000000000";
        Assert.Throws<VerificationException>(() => TestData.Config(environment: env));
    }

    [Theory]
    [InlineData("direct")]
    [InlineData("foundry")]
    [InlineData("definition")]
    public void Actual_deployed_mcp_endpoint_is_required_in_every_configured_mode(string mode)
    {
        Dictionary<string, string> env = TestData.Environment();
        env.Remove("GRAPH_MCP_MCP_PATH");
        VerificationException error = Assert.Throws<VerificationException>(() => TestData.Config(mode, env));
        Assert.Equal(FailureCode.InvalidConfiguration, error.Code);
    }

    [Theory]
    [InlineData("direct")]
    [InlineData("foundry")]
    [InlineData("definition")]
    public void Explicit_deployed_mcp_path_is_preserved_and_rest_keeps_its_default(string mode)
    {
        Dictionary<string, string> env = TestData.Environment();
        env[ "GRAPH_MCP_MCP_PATH" ] = "/synthetic-v2.1/exported-mcp/";
        Configuration config = TestData.Config(mode, env);
        Assert.Equal(new Uri("https://contoso.azure-api.net/synthetic-v2.1/exported-mcp/"), config.McpEndpoint);
        Assert.Equal(new Uri("https://contoso.azure-api.net/graph"), config.RestEndpoint);
    }

    [Theory]
    [InlineData("direct")]
    [InlineData("foundry")]
    [InlineData("definition")]
    public void Actual_mcp_url_must_match_the_reviewed_gateway_origin(string mode)
    {
        Dictionary<string, string> env = TestData.Environment();
        env.Remove("GRAPH_MCP_MCP_PATH");
        env[ "GRAPH_MCP_MCP_URL" ] = "https://contoso.azure-api.net/synthetic-v2.1/exported-mcp/";
        Configuration config = TestData.Config(mode, env);
        Assert.Equal(new Uri(env[ "GRAPH_MCP_MCP_URL" ]), config.McpEndpoint);
        env[ "GRAPH_MCP_MCP_URL" ] = "https://fabrikam.azure-api.net/synthetic-v2.1/exported-mcp/";
        VerificationException error = Assert.Throws<VerificationException>(() => TestData.Config(mode, env));
        Assert.Equal(FailureCode.InvalidConfiguration, error.Code);
    }

    [Theory]
    [InlineData("direct")]
    [InlineData("foundry")]
    [InlineData("definition")]
    public void Supplying_both_mcp_url_and_path_is_rejected_rather_than_guessed(string mode)
    {
        Dictionary<string, string> env = TestData.Environment();
        env[ "GRAPH_MCP_MCP_URL" ] = "https://contoso.azure-api.net/synthetic-deployment/exported-mcp";
        VerificationException error = Assert.Throws<VerificationException>(() => TestData.Config(mode, env));
        Assert.Equal(FailureCode.InvalidConfiguration, error.Code);
    }

    [Theory]
    [InlineData("")]
    [InlineData("http://contoso.azure-api.net/synthetic/exported-mcp")]
    [InlineData("https://user@contoso.azure-api.net/synthetic/exported-mcp")]
    [InlineData("https://contoso.azure-api.net:444/synthetic/exported-mcp")]
    [InlineData("https://contoso.azure-api.net.fabrikam.example/synthetic/exported-mcp")]
    [InlineData("https://contoso.azure-api.net/synthetic/exported-mcp?api-key=synthetic")]
    [InlineData("https://contoso.azure-api.net/synthetic/exported-mcp#fragment")]
    [InlineData("https://contoso.azure-api.net/synthetic%2fexported-mcp")]
    [InlineData("https://contoso.azure-api.net/synthetic/../exported-mcp")]
    [InlineData("https://contoso.azure-api.net//synthetic/exported-mcp")]
    [InlineData("https://contoso.azure-api.net/")]
    public void Invalid_mcp_urls_fail_before_authentication_or_sdk_construction(string url)
    {
        Dictionary<string, string> env = TestData.Environment();
        env.Remove("GRAPH_MCP_MCP_PATH");
        env[ "GRAPH_MCP_MCP_URL" ] = url;
        VerificationException error = Assert.Throws<VerificationException>(() => TestData.Config("definition", env));
        Assert.Equal(FailureCode.InvalidConfiguration, error.Code);
    }

    [Theory]
    [InlineData("")]
    [InlineData("/")]
    [InlineData("//fabrikam.example/mcp")]
    [InlineData("/synthetic/../exported-mcp")]
    [InlineData("/synthetic/./exported-mcp")]
    [InlineData("/synthetic/exported-mcp?token=synthetic")]
    [InlineData("/synthetic/exported-mcp#fragment")]
    [InlineData("/synthetic%2fexported-mcp")]
    public void Invalid_mcp_paths_are_not_normalized_into_a_different_endpoint(string path)
    {
        Dictionary<string, string> env = TestData.Environment();
        env[ "GRAPH_MCP_MCP_PATH" ] = path;
        VerificationException error = Assert.Throws<VerificationException>(() => TestData.Config("definition", env));
        Assert.Equal(FailureCode.InvalidConfiguration, error.Code);
    }

    [Theory]
    [InlineData("PROJECT_ENDPOINT", "https://fabrikam.example/api/projects/test")]
    [InlineData("PROJECT_ENDPOINT", "https://contoso.services.ai.azure.com/api/projects/test/other")]
    [InlineData("PROJECT_ENDPOINT", "https://contoso.services.ai.azure.com/api/projects/other/../synthetic")]
    [InlineData("CONSENT_ORIGIN", "https://fabrikam.example")]
    [InlineData("HARNESS", "automatic")]
    [InlineData("CONNECTION_NAME", "token secret")]
    [InlineData("CONSENT_PATH", "//fabrikam.example")]
    [InlineData("CONSENT_PATH", "/redirect?url=other")]
    public void Foundry_configuration_is_pinned_and_nonsecret(string name, string value)
    {
        Dictionary<string, string> env = TestData.Environment();
        env[ "GRAPH_MCP_" + name ] = value;
        Assert.Throws<VerificationException>(() => TestData.Config("foundry", env));
    }

    [Theory]
    [InlineData("2026-01-01T00:00:00Z", "2026-02-01T00:00:00Z")]
    [InlineData("2026-01-01T00:00:00+05:30", "2026-01-01T00:00:01+05:30")]
    [InlineData("2026-01-01T00:00:00-05:00", "2026-02-01T01:00:00-04:00")]
    public void Calendar_accepts_explicit_offsets_and_31_elapsed_days(string start, string end)
    {
        TestData.Contract.ValidateWindow(start, end);
    }

    [Theory]
    [InlineData("2026-01-01T00:00:00", "2026-01-02T00:00:00Z")]
    [InlineData("2026-01-01", "2026-01-02")]
    [InlineData("2026-01-01T00:00:00Z", "2026-02-01T00:00:01Z")]
    [InlineData("2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z")]
    [InlineData("2026-02-30T00:00:00Z", "2026-03-01T00:00:00Z")]
    [InlineData("2026-01-01T00:00:00+15:00", "2026-01-02T00:00:00+15:00")]
    public void Calendar_rejects_ambiguous_invalid_or_excessive_windows(string start, string end)
    {
        Assert.Throws<VerificationException>(() => TestData.Contract.ValidateWindow(start, end));
    }

    [Theory]
    [InlineData("list_messages", "{\"page_size\":0}")]
    [InlineData("list_messages", "{\"page_size\":26}")]
    [InlineData("list_messages", "{\"page_size\":\"25\"}")]
    [InlineData("list_messages", "{\"page_size\":null}")]
    [InlineData("list_messages", "{\"$filter\":\"private\"}")]
    [InlineData("get_message", "{\"message_id\":\"one\",\"extra\":\"two\"}")]
    [InlineData("get_event", "{\"event_id\":\"https://fabrikam.example\"}")]
    [InlineData("write_message", "{}")]
    public void Tool_arguments_reject_unapproved_shapes(string tool, string args)
    {
        Assert.Throws<VerificationException>(() => TestData.Contract.ValidateArguments(tool, TestData.Json(args)));
    }

    [Fact]
    public void Json_rejects_duplicate_fields()
    {
        Assert.Throws<VerificationException>(() => TestData.Json("{\"page_size\":10,\"page_size\":25}"));
        Assert.Throws<VerificationException>(() => TestData.Json("{\"a\":[{\"id\":\"one\",\"id\":\"two\"}]}"));
    }

    [Fact]
    public void Lists_default_to_ten_and_accept_twenty_five_without_clamping()
    {
        Assert.Equal(10, TestData.Config().PageSize);
        Dictionary<string, string> env = TestData.Environment();
        env[ "GRAPH_MCP_PAGE_SIZE" ] = "25";
        Assert.Equal(25, TestData.Config(environment: env).PageSize);
        TestData.Contract.ValidateArguments("list_messages", TestData.Json("{}"));
        TestData.Contract.ValidateArguments("list_messages", TestData.Json("{\"page_size\":25}"));
    }

    [Fact]
    public async Task New_user_session_has_no_automatic_authentication_or_shared_token()
    {
        using UserSession first = new(TestData.Config());
        using UserSession second = new(TestData.Config());
        Assert.NotSame(first.Credential, second.Credential);
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() => first.GetGatewayTokenAsync(CancellationToken.None));
        Assert.Equal(FailureCode.Unauthorized, error.Code);
        await Assert.ThrowsAsync<VerificationException>(() => second.GetGatewayTokenAsync(CancellationToken.None));
    }
}
