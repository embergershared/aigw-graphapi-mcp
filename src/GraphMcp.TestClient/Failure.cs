using System.Text.Json;

namespace GraphMcp.TestClient;

internal enum FailureCode
{
    InvalidConfiguration = 2,
    Unauthorized = 3,
    Forbidden = 4,
    NotFound = 5,
    Throttled = 6,
    Timeout = 7,
    Network = 8,
    RedirectRejected = 9,
    ResponseTooLarge = 10,
    InvalidProtocol = 11,
    ToolFailure = 12,
    FixturesMissing = 13,
    ConsentDenied = 14,
    ApprovalDenied = 15,
    NoToolEvidence = 16,
    RoundLimit = 17,
    Cancelled = 18,
    Unsupported = 19,
    Backend = 20
}

internal sealed class VerificationException(FailureCode code, int? status = null, int? retryAfter = null)
    : Exception(code.ToString())
{
    internal FailureCode Code { get; } = code;
    internal int? Status { get; } = status;
    internal int? RetryAfter { get; } = retryAfter;
}

internal static class Diagnostics
{
    // Only fixed event names, enums and counts reach diagnostics, never SDK exception messages or response text.
    internal static void Write(string eventName, string outcome, int? count = null, int? status = null, int? retryAfter = null)
    {
        Console.WriteLine(JsonSerializer.Serialize(new { level = "INFO", eventName, outcome, count, status, retryAfter }));
    }

    internal static void Failure(VerificationException error)
    {
        Console.Error.WriteLine(JsonSerializer.Serialize(new
        {
            level = "ERROR",
            eventName = "verification_failed",
            code = error.Code.ToString(),
            status = error.Status,
            retryAfterSeconds = error.RetryAfter
        }));
    }
}
