using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace GraphMcp.TestClient;

internal sealed partial class Continuations(Contract contract)
{
    private readonly HashSet<(string Tool, string Cursor)> _returned = [];

    internal void Register(string tool, string cursor)
    {
        ValidateShape(tool, cursor);
        _returned.Add((tool, cursor));
    }

    internal void ValidateForRequest(string tool, string cursor)
    {
        ValidateShape(tool, cursor);
        if (!_returned.Contains((tool, cursor)))
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
    }

    private void ValidateShape(string tool, string cursor)
    {
        if (!contract.Tools.TryGetValue(tool, out ToolContract? definition) || !tool.StartsWith("list_", StringComparison.Ordinal)
            || cursor.Length is 0 || cursor.Length > contract.MaximumCursorLength || !CursorPattern().IsMatch(cursor))
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        byte[] bytes;
        try { bytes = Convert.FromBase64String(cursor.Replace('-', '+').Replace('_', '/').PadRight(cursor.Length + ((4 - (cursor.Length % 4)) % 4), '=')); }
        catch (FormatException) { throw new VerificationException(FailureCode.InvalidProtocol); }
        JsonElement value = JsonPayload.Parse(new UTF8Encoding(false, true).GetString(bytes));
        if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Count() != 3
            || Contract.RequiredString(value, "operation") != tool || !Guid.TryParseExact(Contract.RequiredString(value, "userId"), "D", out _))
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        string link = Contract.RequiredString(value, "nextLink");
        if (!Uri.TryCreate(link, UriKind.Absolute, out Uri? next) || next.Scheme != "https"
            || next.Host != "graph.microsoft.com" || next.Port != 443 || next.UserInfo.Length != 0
            || next.Fragment.Length != 0 || next.AbsolutePath != definition.Path || next.Query.Length == 0
            || link.Contains('\\', StringComparison.Ordinal))
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        Dictionary<string, string> query = new(StringComparer.Ordinal);
        foreach (string part in next.Query[ 1.. ].Split('&'))
        {
            string[] pair = part.Split('=', 2);
            if (pair.Length != 2 || !query.TryAdd(System.Net.WebUtility.UrlDecode(pair[ 0 ]), System.Net.WebUtility.UrlDecode(pair[ 1 ])))
            {
                throw new VerificationException(FailureCode.InvalidProtocol);
            }
        }
        bool calendar = tool == "list_calendar_view";
        string[] allowed = calendar ? [ "$top", "$select", "$orderby", "$skip", "$skiptoken", "startDateTime", "endDateTime" ]
            : [ "$top", "$select", "$orderby", "$skip", "$skiptoken" ];
        if (query.Keys.Any(k => !allowed.Contains(k, StringComparer.Ordinal))
            || !query.TryGetValue("$top", out string? top) || !int.TryParse(top, NumberStyles.None, CultureInfo.InvariantCulture, out int pageSize)
            || pageSize < 1 || pageSize > contract.MaximumPageSize
            || query.GetValueOrDefault("$select") != definition.Fields || query.GetValueOrDefault("$orderby") != definition.OrderBy
            || query.ContainsKey("$skip") == query.ContainsKey("$skiptoken")
            || query.TryGetValue("$skip", out string? skip) && !long.TryParse(skip, NumberStyles.None, CultureInfo.InvariantCulture, out _)
            || query.TryGetValue("$skiptoken", out string? token) && token.Length == 0)
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        if (calendar)
        {
            contract.ValidateWindow(query.GetValueOrDefault("startDateTime", ""), query.GetValueOrDefault("endDateTime", ""));
        }
    }

    [GeneratedRegex(@"^[A-Za-z0-9_-]+$", RegexOptions.CultureInvariant)]
    private static partial Regex CursorPattern();
}
