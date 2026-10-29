using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace GraphMcp.TestClient;

internal interface IToolReader
{
    Task<JsonElement> CallAsync(string tool, JsonElement arguments, CancellationToken cancellationToken);
}

internal sealed class RestGatewayClient(
    HttpClient httpClient, Configuration configuration, Contract contract, Continuations continuations,
    Func<CancellationToken, Task<string>> getToken) : IToolReader
{
    public async Task<JsonElement> CallAsync(string tool, JsonElement arguments, CancellationToken cancellationToken)
    {
        contract.ValidateArguments(tool, arguments, continuations);
        string path = tool switch
        {
            "list_messages" => "/messages",
            "get_message" => "/messages/" + Uri.EscapeDataString(Contract.RequiredString(arguments, "message_id")),
            "list_calendar_view" => "/calendar-view",
            "get_event" => "/events/" + Uri.EscapeDataString(Contract.RequiredString(arguments, "event_id")),
            _ => throw new VerificationException(FailureCode.InvalidProtocol)
        };
        bool list = tool.StartsWith("list_", StringComparison.Ordinal);
        string query = list ? string.Join("&", arguments.EnumerateObject().Select(p =>
            Uri.EscapeDataString(p.Name) + "=" + Uri.EscapeDataString(p.Value.ToString()))) : "";
        Uri target = new(configuration.RestEndpoint.AbsoluteUri + path + (query.Length > 0 ? "?" + query : ""));
        using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(Contract.RequestTimeoutSeconds));
        using HttpRequestMessage request = new(HttpMethod.Get, target);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await getToken(timeout.Token).ConfigureAwait(false));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        try
        {
            using HttpResponseMessage response = await httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            return await BoundedHttp.ReadJsonAsync(response, list ? contract.ListMaxBytes : contract.DetailMaxBytes, contract, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new VerificationException(FailureCode.Timeout);
        }
    }
}

internal sealed partial class NativeMcpClient(
    HttpClient httpClient, Configuration configuration, Contract contract, Continuations continuations,
    Func<CancellationToken, Task<string>> getToken) : IToolReader
{
    private string? _sessionId;
    private int _nextId;
    private bool _initialized;
    private bool _schemasValidated;

    internal async Task InitializeAsync(CancellationToken cancellationToken)
    {
        if (_initialized || _nextId != 0) { throw new VerificationException(FailureCode.InvalidProtocol); }
        JsonElement result = await SendAsync("initialize", new
        {
            protocolVersion = Contract.ProtocolVersion,
            capabilities = new { },
            clientInfo = new { name = "graph-mcp-verifier", version = "1.0" }
        }, notification: false, cancellationToken).ConfigureAwait(false);
        if (Contract.RequiredString(result, "protocolVersion") != Contract.ProtocolVersion
            || !result.TryGetProperty("capabilities", out JsonElement capabilities) || capabilities.ValueKind != JsonValueKind.Object
            || !capabilities.TryGetProperty("tools", out JsonElement tools) || tools.ValueKind != JsonValueKind.Object)
        {
            throw new VerificationException(FailureCode.Unsupported);
        }
        await SendAsync("notifications/initialized", new { }, notification: true, cancellationToken).ConfigureAwait(false);
        _initialized = true;
    }

    internal async Task ListToolsAsync(CancellationToken cancellationToken)
    {
        EnsureInitialized();
        JsonElement result = await SendAsync("tools/list", new { }, notification: false, cancellationToken).ConfigureAwait(false);
        ValidateToolSchemas(result, contract);
        _schemasValidated = true;
    }

    public async Task<JsonElement> CallAsync(string tool, JsonElement arguments, CancellationToken cancellationToken)
    {
        EnsureInitialized();
        if (!_schemasValidated) { throw new VerificationException(FailureCode.InvalidProtocol); }
        contract.ValidateArguments(tool, arguments, continuations);
        JsonElement result = await SendAsync("tools/call", new { name = tool, arguments }, notification: false, cancellationToken).ConfigureAwait(false);
        return ExtractPayload(result, tool.StartsWith("list_", StringComparison.Ordinal) ? contract.ListMaxBytes : contract.DetailMaxBytes);
    }

    private void EnsureInitialized()
    {
        if (!_initialized) { throw new VerificationException(FailureCode.InvalidProtocol); }
    }

    private async Task<JsonElement> SendAsync(string method, object parameters, bool notification, CancellationToken cancellationToken)
    {
        int id = notification ? 0 : ++_nextId;
        using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(Contract.RequestTimeoutSeconds));
        using HttpRequestMessage request = new(HttpMethod.Post, configuration.McpEndpoint);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await getToken(timeout.Token).ConfigureAwait(false));
        if (method != "initialize") { request.Headers.Add("MCP-Protocol-Version", Contract.ProtocolVersion); }
        if (_sessionId is not null) { request.Headers.Add("Mcp-Session-Id", _sessionId); }
        request.Content = notification
            ? JsonContent.Create(new { jsonrpc = "2.0", method, @params = parameters })
            : JsonContent.Create(new { jsonrpc = "2.0", id, method, @params = parameters });
        try
        {
            using HttpResponseMessage response = await httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            await BoundedHttp.EnsureSuccessAsync(response, contract, timeout.Token).ConfigureAwait(false);
            if (response.Headers.TryGetValues("Mcp-Session-Id", out IEnumerable<string>? values))
            {
                string[] sessions = values.ToArray();
                if (sessions.Length != 1 || !SessionPattern().IsMatch(sessions[ 0 ])
                    || _sessionId is not null && _sessionId != sessions[ 0 ] || method != "initialize" && _sessionId is null)
                {
                    throw new VerificationException(FailureCode.InvalidProtocol);
                }
                _sessionId = sessions[ 0 ];
            }
            if (notification)
            {
                if (response.StatusCode is not (HttpStatusCode.Accepted or HttpStatusCode.NoContent))
                {
                    throw new VerificationException(FailureCode.InvalidProtocol);
                }
                return default;
            }
            if (response.StatusCode != HttpStatusCode.OK) { throw new VerificationException(FailureCode.InvalidProtocol); }
            return await BoundedHttp.ReadRpcAsync(response, id, contract, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new VerificationException(FailureCode.Timeout);
        }
    }

    internal static JsonElement ExtractPayload(JsonElement result, int maximum)
    {
        if (result.ValueKind != JsonValueKind.Object) { throw new VerificationException(FailureCode.InvalidProtocol); }
        if (result.TryGetProperty("isError", out JsonElement error) && error.ValueKind != JsonValueKind.False)
        {
            throw new VerificationException(FailureCode.ToolFailure);
        }
        if (result.TryGetProperty("structuredContent", out JsonElement structured))
        {
            Contract.CheckSize(structured.GetRawText(), maximum);
            if (structured.ValueKind != JsonValueKind.Object) { throw new VerificationException(FailureCode.InvalidProtocol); }
            return structured.Clone();
        }
        if (!result.TryGetProperty("content", out JsonElement content) || content.ValueKind != JsonValueKind.Array
            || content.GetArrayLength() != 1 || Contract.RequiredString(content[ 0 ], "type") != "text")
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        string text = Contract.RequiredString(content[ 0 ], "text");
        Contract.CheckSize(text, maximum);
        return JsonPayload.Parse(text);
    }

    internal static void ValidateToolSchemas(JsonElement result, Contract contract)
    {
        if (!result.TryGetProperty("tools", out JsonElement tools) || tools.ValueKind != JsonValueKind.Array
            || tools.GetArrayLength() != Contract.ToolNames.Length || result.TryGetProperty("nextCursor", out JsonElement next) && next.ValueKind != JsonValueKind.Null)
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        HashSet<string> names = new(StringComparer.Ordinal);
        foreach (JsonElement tool in tools.EnumerateArray())
        {
            string name = Contract.RequiredString(tool, "name");
            if (!contract.Tools.ContainsKey(name) || !names.Add(name))
            {
                throw new VerificationException(FailureCode.InvalidProtocol);
            }
            if (!tool.TryGetProperty("inputSchema", out JsonElement schema) || Contract.RequiredString(schema, "type") != "object"
                || !schema.TryGetProperty("properties", out JsonElement properties) || properties.ValueKind != JsonValueKind.Object)
            {
                throw new VerificationException(FailureCode.InvalidProtocol);
            }
            bool list = name.StartsWith("list_", StringComparison.Ordinal);
            string[] expected = name switch
            {
                "list_messages" => [ "page_size", "continuation" ],
                "list_calendar_view" => [ "start", "end", "page_size", "continuation" ],
                "get_message" => [ "message_id" ],
                _ => [ "event_id" ]
            };
            if (!properties.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal).SequenceEqual(expected.Order(StringComparer.Ordinal)))
            {
                throw new VerificationException(FailureCode.InvalidProtocol);
            }
            foreach (JsonProperty property in properties.EnumerateObject())
            {
                JsonElement value = property.Value;
                bool pageSize = property.Name == "page_size";
                if (Contract.RequiredString(value, "type") != (pageSize ? "integer" : "string"))
                {
                    throw new VerificationException(FailureCode.InvalidProtocol);
                }
                if (pageSize)
                {
                    if (value.GetProperty("minimum").GetInt32() != 1 || value.GetProperty("maximum").GetInt32() != contract.MaximumPageSize
                        || value.GetProperty("default").GetInt32() != contract.DefaultPageSize)
                    {
                        throw new VerificationException(FailureCode.InvalidProtocol);
                    }
                }
                else
                {
                    int max = property.Name == "continuation" ? contract.MaximumCursorLength : list ? 40 : contract.MaximumIdLength;
                    if (value.GetProperty("maxLength").GetInt32() != max
                        || property.Name is "start" or "end" && Contract.RequiredString(value, "format") != "date-time"
                        || !list && value.GetProperty("minLength").GetInt32() != 1)
                    {
                        throw new VerificationException(FailureCode.InvalidProtocol);
                    }
                }
            }
            string[] required = schema.TryGetProperty("required", out JsonElement requiredElement)
                ? requiredElement.EnumerateArray().Select(e => e.GetString()!).ToArray() : [];
            if (!required.Order(StringComparer.Ordinal).SequenceEqual((list ? Array.Empty<string>() : expected).Order(StringComparer.Ordinal)))
            {
                throw new VerificationException(FailureCode.InvalidProtocol);
            }
        }
    }

    [GeneratedRegex(@"^[\x21-\x7e]{1,256}$", RegexOptions.CultureInvariant)]
    private static partial Regex SessionPattern();
}
