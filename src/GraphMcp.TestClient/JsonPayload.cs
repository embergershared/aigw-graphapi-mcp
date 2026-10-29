using System.Text.Json;

namespace GraphMcp.TestClient;

internal static class JsonPayload
{
    internal static JsonElement Parse(string json)
    {
        using JsonDocument document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 32 });
        Validate(document.RootElement);
        return document.RootElement.Clone();
    }

    private static void Validate(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            HashSet<string> names = new(StringComparer.Ordinal);
            foreach (JsonProperty property in element.EnumerateObject())
            {
                if (!names.Add(property.Name))
                {
                    throw new VerificationException(FailureCode.InvalidProtocol);
                }
                Validate(property.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement item in element.EnumerateArray()) { Validate(item); }
        }
    }
}
