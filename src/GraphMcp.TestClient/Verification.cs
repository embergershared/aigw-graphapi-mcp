using System.Text.Json;

namespace GraphMcp.TestClient;

internal static class Verification
{
    internal static JsonElement Arguments(object value) => JsonSerializer.SerializeToElement(value);

    internal static async Task VerifyFixturesAsync(IToolReader reader, Configuration config, Contract contract,
        Continuations continuations, bool followContinuation, CancellationToken cancellationToken)
    {
        await VerifyPairAsync("list_messages", "get_message", config.MessageId,
            Arguments(new { page_size = config.PageSize }), Arguments(new { message_id = config.MessageId })).ConfigureAwait(false);
        await VerifyPairAsync("list_calendar_view", "get_event", config.EventId,
            Arguments(new { page_size = config.PageSize, start = config.Start, end = config.End }),
            Arguments(new { event_id = config.EventId })).ConfigureAwait(false);

        async Task VerifyPairAsync(string listTool, string detailTool, string fixtureId, JsonElement listArgs, JsonElement detailArgs)
        {
            JsonElement page = await reader.CallAsync(listTool, listArgs, cancellationToken).ConfigureAwait(false);
            ValidatePayload(listTool, page, contract, continuations);
            bool present = ContainsFixture(page, fixtureId);
            if (followContinuation)
            {
                if (page.GetProperty("continuation").ValueKind != JsonValueKind.String)
                {
                    throw new VerificationException(FailureCode.FixturesMissing);
                }
                JsonElement nextArgs = Arguments(new { continuation = page.GetProperty("continuation").GetString() });
                JsonElement next = await reader.CallAsync(listTool, nextArgs, cancellationToken).ConfigureAwait(false);
                ValidatePayload(listTool, next, contract, continuations);
                present |= ContainsFixture(next, fixtureId);
            }
            if (!present) { throw new VerificationException(FailureCode.FixturesMissing); }
            JsonElement detail = await reader.CallAsync(detailTool, detailArgs, cancellationToken).ConfigureAwait(false);
            ValidatePayload(detailTool, detail, contract, continuations);
            if (Contract.RequiredString(detail, "id") != fixtureId)
            {
                throw new VerificationException(FailureCode.FixturesMissing);
            }
        }
    }

    internal static void ValidatePayload(string tool, JsonElement payload, Contract contract, Continuations continuations)
    {
        bool list = tool.StartsWith("list_", StringComparison.Ordinal);
        Contract.CheckSize(payload.GetRawText(), list ? contract.ListMaxBytes : contract.DetailMaxBytes);
        if (payload.ValueKind != JsonValueKind.Object) { throw new VerificationException(FailureCode.InvalidProtocol); }
        HashSet<string> fields = new(contract.Tools[ tool ].Fields.Split(','), StringComparer.Ordinal);
        if (list)
        {
            if (payload.EnumerateObject().Count() != 2 || !payload.TryGetProperty("items", out JsonElement items)
                || items.ValueKind != JsonValueKind.Array || items.GetArrayLength() > contract.MaximumPageSize
                || !payload.TryGetProperty("continuation", out JsonElement cursor)
                || cursor.ValueKind is not (JsonValueKind.Null or JsonValueKind.String))
            {
                throw new VerificationException(FailureCode.InvalidProtocol);
            }
            foreach (JsonElement item in items.EnumerateArray()) { ValidateItem(item, fields, contract); }
            if (cursor.ValueKind == JsonValueKind.String) { continuations.Register(tool, cursor.GetString()!); }
        }
        else
        {
            ValidateItem(payload, fields, contract);
            if (!payload.TryGetProperty("body", out JsonElement body) || body.ValueKind != JsonValueKind.Object
                || Contract.RequiredString(body, "contentType") != "text"
                || !body.TryGetProperty("content", out JsonElement text) || text.ValueKind != JsonValueKind.String)
            {
                throw new VerificationException(FailureCode.InvalidProtocol);
            }
        }
    }

    private static void ValidateItem(JsonElement item, HashSet<string> fields, Contract contract)
    {
        if (item.ValueKind != JsonValueKind.Object || item.EnumerateObject().Any(p => !fields.Contains(p.Name)))
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        contract.ValidateId(Contract.RequiredString(item, "id"));
    }

    private static bool ContainsFixture(JsonElement page, string fixtureId)
    {
        return page.GetProperty("items").EnumerateArray().Any(item => Contract.RequiredString(item, "id") == fixtureId);
    }
}
