using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace GraphMcp.TestClient;

internal static class BoundedHttp
{
    internal static HttpClient CreateClient()
    {
        return new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false })
        {
            Timeout = Timeout.InfiniteTimeSpan,
            MaxResponseContentBufferSize = Contract.EnvelopeMaxBytes
        };
    }

    internal static async Task<byte[]> ReadAsync(HttpContent content, int maximum, CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength > maximum)
        {
            throw new VerificationException(FailureCode.ResponseTooLarge);
        }
        await using Stream stream = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using MemoryStream result = new();
        byte[] buffer = new byte[ 8192 ];
        while (true)
        {
            int count = await stream.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, maximum + 1 - (int)result.Length)), cancellationToken).ConfigureAwait(false);
            if (count == 0) { return result.ToArray(); }
            if (result.Length + count > maximum)
            {
                throw new VerificationException(FailureCode.ResponseTooLarge);
            }
            result.Write(buffer, 0, count);
        }
    }

    internal static void EnsureSuccess(HttpResponseMessage response, Contract contract)
    {
        int status = (int)response.StatusCode;
        FailureCode? code = status switch
        {
            >= 200 and <= 299 => null,
            >= 300 and <= 399 => FailureCode.RedirectRejected,
            401 => FailureCode.Unauthorized,
            403 => FailureCode.Forbidden,
            404 => FailureCode.NotFound,
            429 => FailureCode.Throttled,
            408 or 504 => FailureCode.Timeout,
            _ => FailureCode.Backend
        };
        if (code is null) { return; }
        double? delay = response.Headers.RetryAfter?.Delta?.TotalSeconds
            ?? (response.Headers.RetryAfter?.Date - DateTimeOffset.UtcNow)?.TotalSeconds;
        int? retryAfter = delay is double seconds
            ? Math.Clamp((int)Math.Clamp(seconds, int.MinValue, int.MaxValue), 1, contract.MaximumRetryAfterSeconds) : null;
        throw new VerificationException(code.Value, status, retryAfter);
    }

    internal static async Task EnsureSuccessAsync(HttpResponseMessage response, Contract contract, CancellationToken cancellationToken)
    {
        try { EnsureSuccess(response, contract); }
        catch (VerificationException failure) when (failure.Code == FailureCode.Backend
            && response.Content.Headers.ContentType?.MediaType is "application/problem+json" or "application/json")
        {
            byte[] bytes = await ReadAsync(response.Content, Contract.ErrorMaxBytes, cancellationToken).ConfigureAwait(false);
            FailureCode code = failure.Code;
            try
            {
                JsonElement problem = JsonPayload.Parse(new UTF8Encoding(false, true).GetString(bytes));
                if (problem.TryGetProperty("code", out JsonElement value) && value.ValueKind == JsonValueKind.String)
                {
                    code = value.GetString() switch
                    {
                        "response_too_large" => FailureCode.ResponseTooLarge,
                        "invalid_backend_response" or "invalid_backend_continuation" or "unsupported_body_format" => FailureCode.InvalidProtocol,
                        "invalid_page_size" or "calendar_offsets_required" or "invalid_calendar_window" or "invalid_item_id"
                            or "invalid_continuation" or "continuation_must_be_sent_alone" or "unknown_or_duplicate_argument" => FailureCode.InvalidConfiguration,
                        _ => code
                    };
                }
            }
            catch (Exception error) when (error is JsonException or InvalidOperationException or DecoderFallbackException)
            {
                // Preserve the HTTP failure; never expose or interpret an arbitrary upstream error message.
            }
            throw new VerificationException(code, failure.Status, failure.RetryAfter);
        }
    }

    internal static async Task<JsonElement> ReadJsonAsync(HttpResponseMessage response, int maximum, Contract contract, CancellationToken cancellationToken)
    {
        await EnsureSuccessAsync(response, contract, cancellationToken).ConfigureAwait(false);
        if (response.Content.Headers.ContentType?.MediaType != "application/json")
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        byte[] bytes = await ReadAsync(response.Content, maximum, cancellationToken).ConfigureAwait(false);
        return JsonPayload.Parse(new UTF8Encoding(false, true).GetString(bytes));
    }

    internal static async Task<JsonElement> ReadRpcAsync(HttpResponseMessage response, int requestId, Contract contract, CancellationToken cancellationToken)
    {
        await EnsureSuccessAsync(response, contract, cancellationToken).ConfigureAwait(false);
        if (response.Content.Headers.ContentType?.MediaType == "application/json")
        {
            JsonElement json = await ReadJsonAsync(response, Contract.EnvelopeMaxBytes, contract, cancellationToken).ConfigureAwait(false);
            return RpcResult(json, requestId);
        }
        if (response.Content.Headers.ContentType?.MediaType != "text/event-stream")
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        await using Stream stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        // Return at the complete result event, without waiting for the SSE connection to close.
        using MemoryStream line = new();
        StringBuilder data = new();
        byte[] one = new byte[ 1 ];
        int total = 0;
        bool skipLineFeed = false;
        bool firstLine = true;
        while (true)
        {
            int read = await stream.ReadAsync(one, cancellationToken).ConfigureAwait(false);
            if (read == 0) { throw new VerificationException(FailureCode.InvalidProtocol); }
            if (++total > Contract.EnvelopeMaxBytes) { throw new VerificationException(FailureCode.ResponseTooLarge); }
            if (skipLineFeed && one[ 0 ] == (byte)'\n') { skipLineFeed = false; continue; }
            skipLineFeed = one[ 0 ] == (byte)'\r';
            if (one[ 0 ] != (byte)'\n' && one[ 0 ] != (byte)'\r') { line.WriteByte(one[ 0 ]); continue; }
            string text = new UTF8Encoding(false, true).GetString(line.ToArray());
            line.SetLength(0);
            if (firstLine)
            {
                if (text.StartsWith('\ufeff')) { text = text[ 1.. ]; }
                firstLine = false;
            }
            if (text.Length == 0 && data.Length != 0)
            {
                JsonElement item = JsonPayload.Parse(data.ToString().TrimEnd('\n'));
                data.Clear();
                if (item.TryGetProperty("id", out _)) { return RpcResult(item, requestId); }
                ValidateRpcNotification(item);
            }
            else if (text.StartsWith("data:", StringComparison.Ordinal))
            {
                string value = text[ 5.. ];
                data.Append(value.StartsWith(' ') ? value[ 1.. ] : value).Append('\n');
            }
            else if (text.Length != 0 && !text.StartsWith(':') && !text.StartsWith("event:", StringComparison.Ordinal)
                && !text.StartsWith("id:", StringComparison.Ordinal) && !text.StartsWith("retry:", StringComparison.Ordinal))
            {
                throw new VerificationException(FailureCode.InvalidProtocol);
            }
        }
    }

    private static JsonElement RpcResult(JsonElement envelope, int requestId)
    {
        if (envelope.ValueKind != JsonValueKind.Object || Contract.RequiredString(envelope, "jsonrpc") != "2.0"
            || !envelope.TryGetProperty("id", out JsonElement id) || id.ValueKind != JsonValueKind.Number
            || !id.TryGetInt32(out int actual) || actual != requestId)
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        if (envelope.TryGetProperty("error", out _))
        {
            throw new VerificationException(FailureCode.ToolFailure);
        }
        if (!envelope.TryGetProperty("result", out JsonElement result) || result.ValueKind != JsonValueKind.Object)
        {
            throw new VerificationException(FailureCode.InvalidProtocol);
        }
        return result.Clone();
    }

    private static void ValidateRpcNotification(JsonElement item)
    {
        if (item.ValueKind != JsonValueKind.Object || Contract.RequiredString(item, "jsonrpc") != "2.0"
            || !item.TryGetProperty("method", out JsonElement method) || method.ValueKind != JsonValueKind.String
            || method.GetString() != "notifications/message")
        {
            // Never implement server-initiated tools, URL fetching, sampling, or elicitation.
            throw new VerificationException(FailureCode.Unsupported);
        }
    }
}

internal sealed class BoundedSdkHandler(Uri projectEndpoint, Contract contract, HttpMessageHandler? transport = null) : DelegatingHandler(
    transport ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false })
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Uri target = request.RequestUri ?? throw new VerificationException(FailureCode.InvalidProtocol);
        string prefix = projectEndpoint.AbsolutePath.TrimEnd('/') + "/";
        if (target.Scheme != "https" || target.Authority != projectEndpoint.Authority || target.UserInfo.Length != 0
            || target.Fragment.Length != 0 || !target.AbsolutePath.StartsWith(prefix, StringComparison.Ordinal))
        {
            throw new VerificationException(FailureCode.RedirectRejected);
        }
        HttpResponseMessage response = await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
        try
        {
            await BoundedHttp.EnsureSuccessAsync(response, contract, cancellationToken).ConfigureAwait(false);
            byte[] bytes = await BoundedHttp.ReadAsync(response.Content, Contract.EnvelopeMaxBytes, cancellationToken).ConfigureAwait(false);
            MediaTypeHeaderValue? type = response.Content.Headers.ContentType;
            response.Content.Dispose();
            response.Content = new ByteArrayContent(bytes);
            response.Content.Headers.ContentType = type;
            return response;
        }
        catch
        {
            response.Dispose();
            throw;
        }
    }
}
