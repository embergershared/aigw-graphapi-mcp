using System.Globalization;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace GraphMcp.TestClient;

internal sealed record ToolContract(string Name, string Path, string Fields, string OrderBy);

internal sealed partial class Contract
{
    internal const int EnvelopeMaxBytes = 1_048_576;
    internal const int ErrorMaxBytes = 4096;
    internal const int RequestTimeoutSeconds = 30;
    internal const int AuthenticationTimeoutSeconds = 180;
    internal const int MaximumRounds = 12;
    internal const int MaxOutputTokens = 2048;
    internal const string ServerLabel = "own_graph";
    internal const string ProtocolVersion = "2025-03-26";
    internal static readonly string[] ToolNames = [ "list_messages", "get_message", "list_calendar_view", "get_event" ];

    internal int DefaultPageSize { get; private init; }
    internal int MaximumPageSize { get; private init; }
    internal int MaximumCalendarDays { get; private init; }
    internal int DetailMaxBytes { get; private init; }
    internal int ListMaxBytes { get; private init; }
    internal int MaximumCursorLength { get; private init; }
    internal int MaximumIdLength { get; private init; }
    internal int MaximumRetryAfterSeconds { get; private init; }
    internal required IReadOnlyDictionary<string, ToolContract> Tools { get; init; }

    internal static Contract Load()
    {
        using Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("GraphMcp.Contract.json")
            ?? throw new VerificationException(FailureCode.InvalidConfiguration);
        using JsonDocument document = JsonDocument.Parse(stream);
        JsonElement root = document.RootElement;
        Dictionary<string, ToolContract> tools = root.GetProperty("tools").EnumerateArray().ToDictionary(
            t => t.GetProperty("name").GetString()!,
            t => new ToolContract(t.GetProperty("name").GetString()!, t.GetProperty("path").GetString()!,
                t.GetProperty("fields").GetString()!, t.GetProperty("orderBy").GetString()!), StringComparer.Ordinal);
        if (!tools.Keys.Order(StringComparer.Ordinal).SequenceEqual(ToolNames.Order(StringComparer.Ordinal)))
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        return new()
        {
            DefaultPageSize = root.GetProperty("defaultPageSize").GetInt32(),
            MaximumPageSize = root.GetProperty("maximumPageSize").GetInt32(),
            MaximumCalendarDays = root.GetProperty("maximumCalendarDays").GetInt32(),
            DetailMaxBytes = root.GetProperty("detailMaxBytes").GetInt32(),
            ListMaxBytes = root.GetProperty("listMaxBytes").GetInt32(),
            MaximumCursorLength = root.GetProperty("maximumCursorLength").GetInt32(),
            MaximumIdLength = root.GetProperty("maximumIdLength").GetInt32(),
            MaximumRetryAfterSeconds = root.GetProperty("maximumRetryAfterSeconds").GetInt32(),
            Tools = tools
        };
    }

    internal void ValidateId(string value)
    {
        if (value.Length is 0 || value.Length > MaximumIdLength || !IdPattern().IsMatch(value))
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
    }

    internal void ValidateWindow(string start, string end)
    {
        if (start.Length > 40 || end.Length > 40
            || !OffsetPattern().IsMatch(start) || !OffsetPattern().IsMatch(end)
            || !DateTimeOffset.TryParse(start, CultureInfo.InvariantCulture, DateTimeStyles.None, out DateTimeOffset from)
            || !DateTimeOffset.TryParse(end, CultureInfo.InvariantCulture, DateTimeStyles.None, out DateTimeOffset to)
            || to <= from || (to - from).TotalDays > MaximumCalendarDays)
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
    }

    internal void ValidateArguments(string tool, JsonElement arguments, Continuations? continuations = null)
    {
        if (!Tools.ContainsKey(tool) || arguments.ValueKind != JsonValueKind.Object)
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        JsonProperty[] properties = arguments.EnumerateObject().ToArray();
        if (properties.Select(p => p.Name).Distinct(StringComparer.Ordinal).Count() != properties.Length)
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        bool list = tool.StartsWith("list_", StringComparison.Ordinal);
        bool calendar = tool == "list_calendar_view";
        string idName = tool == "get_message" ? "message_id" : "event_id";
        string[] allowed = list ? (calendar ? [ "start", "end", "page_size", "continuation" ] : [ "page_size", "continuation" ]) : [ idName ];
        if (properties.Any(p => !allowed.Contains(p.Name, StringComparer.Ordinal)))
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        if (!list)
        {
            ValidateId(RequiredString(arguments, idName));
            return;
        }
        if (arguments.TryGetProperty("continuation", out JsonElement cursor))
        {
            if (properties.Length != 1 || cursor.ValueKind != JsonValueKind.String || continuations is null)
            {
                throw new VerificationException(FailureCode.InvalidProtocol);
            }
            continuations.ValidateForRequest(tool, cursor.GetString()!);
            return;
        }
        if (arguments.TryGetProperty("page_size", out JsonElement size)
            && (size.ValueKind != JsonValueKind.Number || !size.TryGetInt32(out int count) || count < 1 || count > MaximumPageSize))
        {
            throw new VerificationException(FailureCode.InvalidConfiguration);
        }
        if (calendar)
        {
            ValidateWindow(RequiredString(arguments, "start"), RequiredString(arguments, "end"));
        }
    }

    internal static string RequiredString(JsonElement value, string name)
    {
        if (!value.TryGetProperty(name, out JsonElement property) || property.ValueKind != JsonValueKind.String
            || string.IsNullOrEmpty(property.GetString()))
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        return property.GetString()!;
    }

    internal static void CheckSize(string json, int maximum)
    {
        if (Encoding.UTF8.GetByteCount(json) > maximum)
        {
            throw new VerificationException(FailureCode.ResponseTooLarge);
        }
    }

    [GeneratedRegex(@"^[A-Za-z0-9_+=/-]+$", RegexOptions.CultureInvariant)]
    private static partial Regex IdPattern();

    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})$", RegexOptions.CultureInvariant)]
    private static partial Regex OffsetPattern();
}
