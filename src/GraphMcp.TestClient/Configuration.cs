using System.Text.RegularExpressions;

namespace GraphMcp.TestClient;

internal sealed record Command(string Mode, bool Live, bool OpenBrowser, bool Synthetic, bool FollowContinuation)
{
    internal static Command Parse(string[] args)
    {
        string mode = args.Length == 0 ? "offline" : args[ 0 ] is "--help" or "-h" ? "help" : args[ 0 ];
        if (mode is not ("offline" or "direct" or "foundry" or "definition" or "help"))
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        string[] flags = args.Skip(1).ToArray();
        string[] allowed = mode == "direct"
            ? [ "--live", "--open-browser", "--synthetic", "--follow-continuation" ]
            : mode == "foundry" ? [ "--live", "--open-browser", "--synthetic" ] : [];
        if (flags.Any(f => !allowed.Contains(f, StringComparer.Ordinal)) || flags.Distinct(StringComparer.Ordinal).Count() != flags.Length)
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        bool live = flags.Contains("--live", StringComparer.Ordinal);
        bool browser = flags.Contains("--open-browser", StringComparer.Ordinal);
        bool synthetic = flags.Contains("--synthetic", StringComparer.Ordinal);
        if (mode is "direct" or "foundry" && (!live || !browser || !synthetic))
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        return new(mode, live, browser, synthetic, flags.Contains("--follow-continuation", StringComparer.Ordinal));
    }
}

internal enum Harness { Responses, Copilot }

internal sealed partial record Configuration(
    Uri GatewayOrigin, Uri RestEndpoint, Uri McpEndpoint, string TenantId, string ClientId, string GatewayScope,
    Uri RedirectUri, string MessageId, string EventId, string Start, string End, int PageSize,
    Uri? ProjectEndpoint, string Model, string AgentName, string AgentVersion, string ConnectionName, Uri? ConsentOrigin,
    Harness Harness, string ConsentPath)
{
    internal static Configuration Load(Command command, Contract contract, Func<string, string?>? read = null)
    {
        read ??= Environment.GetEnvironmentVariable;
        string Get(string name, string? fallback = null)
        {
            string value = read("GRAPH_MCP_" + name) ?? fallback
                ?? throw new VerificationException(FailureCode.InvalidConfiguration);
            if (string.IsNullOrWhiteSpace(value) || value != value.Trim() || value.Any(char.IsControl))
            {
                throw new VerificationException(FailureCode.InvalidConfiguration);
            }
            return value;
        }
        Uri origin = HttpsUri(Get("GATEWAY_ORIGIN"), originOnly: true);
        Uri rest = Endpoint(origin, Get("REST_PATH", "/graph"));
        string? mcpUrl = read("GRAPH_MCP_MCP_URL");
        string? mcpPath = read("GRAPH_MCP_MCP_PATH");
        if ((mcpUrl is null) == (mcpPath is null))
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        Uri mcp;
        if (mcpUrl is not null)
        {
            mcp = HttpsUri(Get("MCP_URL"));
            if (mcp.Host != origin.Host || mcp.Port != origin.Port)
            {
                throw new VerificationException(FailureCode.InvalidConfiguration);
            }
            ValidateMcpPath(mcp.AbsolutePath);
        }
        else
        {
            string path = Get("MCP_PATH");
            ValidateMcpPath(path);
            mcp = new Uri(origin, path);
        }
        bool foundry = command.Mode is "foundry" or "definition";
        bool live = command.Mode is "direct" or "foundry";
        string tenant = live ? Get("TENANT_ID") : "";
        string client = live ? Get("CLIENT_ID") : "";
        string scope = live ? Get("GATEWAY_SCOPE") : "";
        if (live && (!Guid.TryParseExact(tenant, "D", out _) || !Guid.TryParseExact(client, "D", out _)
            || !Regex.IsMatch(scope, @"^api://[a-fA-F0-9-]{36}/access_as_user$", RegexOptions.CultureInvariant)
            || !Guid.TryParseExact(scope[ 6..^15 ], "D", out _)))
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        string redirectValue = Get("REDIRECT_URI", "http://localhost:8400/");
        if (!Uri.TryCreate(redirectValue, UriKind.Absolute, out Uri? redirect)
            || redirectValue.Contains('%', StringComparison.Ordinal) || redirectValue.Contains('\\', StringComparison.Ordinal)
            || redirect.Scheme != "http" || redirect.Host != "localhost" || redirect.Port is < 1024 or > 65535
            || redirect.AbsolutePath != "/" || redirect.Query.Length != 0 || redirect.Fragment.Length != 0 || redirect.UserInfo.Length != 0)
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        string message = live ? Get("SYNTHETIC_MESSAGE_ID") : "";
        string eventId = live ? Get("SYNTHETIC_EVENT_ID") : "";
        string start = live ? Get("CALENDAR_START") : "";
        string end = live ? Get("CALENDAR_END") : "";
        int pageSize = contract.DefaultPageSize;
        if (!int.TryParse(Get("PAGE_SIZE", pageSize.ToString(System.Globalization.CultureInfo.InvariantCulture)), out pageSize)
            || pageSize < 1 || pageSize > contract.MaximumPageSize)
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        if (live)
        {
            contract.ValidateId(message);
            contract.ValidateId(eventId);
            contract.ValidateWindow(start, end);
        }
        Uri? project = foundry ? HttpsUri(Get("PROJECT_ENDPOINT")) : null;
        if (project is not null && (!project.Host.EndsWith(".services.ai.azure.com", StringComparison.Ordinal)
            || !Regex.IsMatch(project.AbsolutePath, @"^/api/projects/[A-Za-z0-9_-]+/?$", RegexOptions.CultureInvariant)))
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        string model = foundry ? Get("MODEL_DEPLOYMENT") : "";
        string agent = foundry ? Get("AGENT_NAME") : "";
        string version = command.Mode == "foundry" ? Get("AGENT_VERSION") : "";
        string connection = foundry ? Get("CONNECTION_NAME") : "";
        if (foundry && new[] { model, agent, connection }.Any(s => !NamePattern().IsMatch(s))
            || version.Length > 0 && !NamePattern().IsMatch(version))
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        Uri? consent = command.Mode == "foundry" ? HttpsUri(Get("CONSENT_ORIGIN"), originOnly: true) : null;
        // The returned consent URL is opened intact, but only on the separately reviewed Foundry origin.
        if (consent is not null && !consent.Host.EndsWith(".services.ai.azure.com", StringComparison.Ordinal))
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        string consentPath = command.Mode == "foundry" ? Get("CONSENT_PATH") : "";
        if (consentPath.Length > 0 && !Regex.IsMatch(consentPath, @"^(/[A-Za-z0-9_-]+)+$", RegexOptions.CultureInvariant))
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        Harness harness = Get("HARNESS", "responses") switch
        {
            "responses" => Harness.Responses,
            "copilot" => Harness.Copilot,
            _ => throw new VerificationException(FailureCode.InvalidConfiguration)
        };
        return new(origin, rest, mcp, tenant, client, scope, redirect, message, eventId, start, end, pageSize,
            project, model, agent, version, connection, consent, harness, consentPath);
    }

    internal static Uri HttpsUri(string value, bool originOnly = false)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out Uri? uri) || uri.Scheme != "https" || uri.Port != 443
            || Uri.CheckHostName(uri.Host) != UriHostNameType.Dns || uri.Host == "localhost"
            || uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0
            || value.Contains('%', StringComparison.Ordinal) || value.Contains('\\', StringComparison.Ordinal)
            || value.Contains("/../", StringComparison.Ordinal) || value.EndsWith("/..", StringComparison.Ordinal)
            || value.Contains("/./", StringComparison.Ordinal) || value.EndsWith("/.", StringComparison.Ordinal)
            || originOnly && uri.AbsolutePath != "/")
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        return uri;
    }

    private static Uri Endpoint(Uri origin, string path)
    {
        if (!Regex.IsMatch(path, @"^(/[A-Za-z0-9_-]+)+$", RegexOptions.CultureInvariant))
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        return new Uri(origin, path);
    }

    private static void ValidateMcpPath(string path)
    {
        if (!Regex.IsMatch(path, @"^(/[A-Za-z0-9._~-]+)+/?$", RegexOptions.CultureInvariant)
            || path.Split('/').Any(segment => segment is "." or ".."))
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
    }

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", RegexOptions.CultureInvariant)]
    private static partial Regex NamePattern();
}
