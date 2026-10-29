using GraphMcp.TestClient;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Xunit;

namespace GraphMcp.TestClient.Tests;

public sealed class HttpTests
{
    [Theory]
    [InlineData(65536)]
    [InlineData(131072)]
    public async Task Serialized_json_byte_boundary_is_inclusive_and_never_truncated(int limit)
    {
        string json = "{\"text\":\"" + new string('a', limit - 13) + "é\"}";
        Assert.Equal(limit, Encoding.UTF8.GetByteCount(json));
        using HttpResponseMessage response = TestData.Response(json);
        JsonElement payload = await BoundedHttp.ReadJsonAsync(response, limit, TestData.Contract, CancellationToken.None);
        Assert.Equal((limit - 13) + 1, payload.GetProperty("text").GetString()!.Length);
        using HttpResponseMessage tooLarge = TestData.Response(json + " ");
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            BoundedHttp.ReadJsonAsync(tooLarge, limit, TestData.Contract, CancellationToken.None));
        Assert.Equal(FailureCode.ResponseTooLarge, error.Code);
    }

    [Fact]
    public async Task Unknown_content_length_is_bounded_while_reading()
    {
        using ByteStream stream = new(new byte[ 101 ], failAfterData: false);
        using StreamContent content = new(stream);
        Assert.Null(content.Headers.ContentLength);
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            BoundedHttp.ReadAsync(content, 100, CancellationToken.None));
        Assert.Equal(FailureCode.ResponseTooLarge, error.Code);
    }

    [Theory]
    [InlineData(301, "RedirectRejected")]
    [InlineData(401, "Unauthorized")]
    [InlineData(403, "Forbidden")]
    [InlineData(404, "NotFound")]
    [InlineData(429, "Throttled")]
    [InlineData(502, "Backend")]
    [InlineData(504, "Timeout")]
    public async Task Failures_remain_distinguishable_without_retries_or_backend_text(int status, string expected)
    {
        using FakeHandler handler = new((_, _) =>
        {
            HttpResponseMessage response = TestData.Response("SECRET synthetic token and mailbox data", (HttpStatusCode)status, "application/problem+json");
            response.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.FromSeconds(120));
            response.Headers.Location = new Uri("https://fabrikam.example/");
            return Task.FromResult(response);
        });
        using HttpClient http = new(handler);
        RestGatewayClient rest = new(http, TestData.Config(), TestData.Contract, new(TestData.Contract), _ => Task.FromResult("synthetic-token"));
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            rest.CallAsync("list_messages", TestData.Json("{}"), CancellationToken.None));
        Assert.Equal(expected, error.Code.ToString());
        Assert.Equal(status, error.Status);
        Assert.Equal(30, error.RetryAfter);
        Assert.DoesNotContain("SECRET", error.ToString(), StringComparison.Ordinal);
        Assert.Equal(1, handler.Count);
    }

    [Theory]
    [InlineData("\n")]
    [InlineData("\r\n")]
    [InlineData("\r")]
    public async Task Sse_handles_comments_notifications_and_multiline_data_and_stops_at_result(string newline)
    {
        string sse = string.Join(newline,
            ": heartbeat", "", "event: message", "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{}}", "",
            "id: synthetic-event", "event: message", "data: {\"jsonrpc\":\"2.0\",", "data: \"id\":7,\"result\":{\"ok\":true}}", "", "");
        using ByteStream stream = new(Encoding.UTF8.GetBytes(sse), failAfterData: true);
        using HttpResponseMessage response = new(HttpStatusCode.OK) { Content = new StreamContent(stream) };
        response.Content.Headers.ContentType = new MediaTypeHeaderValue("text/event-stream");
        JsonElement result = await BoundedHttp.ReadRpcAsync(response, 7, TestData.Contract, CancellationToken.None);
        Assert.True(result.GetProperty("ok").GetBoolean());
        Assert.InRange(stream.BytesRead, Encoding.UTF8.GetByteCount(sse) - 1, Encoding.UTF8.GetByteCount(sse));
    }

    [Theory]
    [InlineData("{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{}}", "InvalidProtocol")]
    [InlineData("{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"message\":\"synthetic secret\"}}", "ToolFailure")]
    [InlineData("{\"jsonrpc\":\"2.0\",\"id\":7}", "InvalidProtocol")]
    [InlineData("{\"jsonrpc\":\"1.0\",\"id\":7,\"result\":{}}", "InvalidProtocol")]
    public async Task Rpc_ids_and_error_envelopes_are_checked(string body, string expected)
    {
        using HttpResponseMessage response = TestData.Response(body);
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            BoundedHttp.ReadRpcAsync(response, 7, TestData.Contract, CancellationToken.None));
        Assert.Equal(expected, error.Code.ToString());
    }

    [Fact]
    public async Task Server_requests_and_endless_sse_are_not_executed()
    {
        using HttpResponseMessage response = TestData.Response("data: {\"jsonrpc\":\"2.0\",\"method\":\"sampling/createMessage\",\"params\":{}}\n\n",
            type: "text/event-stream");
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            BoundedHttp.ReadRpcAsync(response, 1, TestData.Contract, CancellationToken.None));
        Assert.Equal(FailureCode.Unsupported, error.Code);
        using CancellationTokenSource cancellation = new();
        cancellation.Cancel();
        using HttpResponseMessage cancelled = TestData.Response("data: {}\n\n", type: "text/event-stream");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            BoundedHttp.ReadRpcAsync(cancelled, 1, TestData.Contract, cancellation.Token));
    }

    [Fact]
    public async Task Sse_envelope_budget_counts_bytes_including_comments()
    {
        using HttpResponseMessage response = TestData.Response(":" + new string('a', Contract.EnvelopeMaxBytes), type: "text/event-stream");
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            BoundedHttp.ReadRpcAsync(response, 1, TestData.Contract, CancellationToken.None));
        Assert.Equal(FailureCode.ResponseTooLarge, error.Code);
    }

    [Fact]
    public async Task Sse_accepts_optional_utf8_bom()
    {
        using HttpResponseMessage response = TestData.Response("\ufeffdata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n", type: "text/event-stream");
        JsonElement value = await BoundedHttp.ReadRpcAsync(response, 1, TestData.Contract, CancellationToken.None);
        Assert.Equal(JsonValueKind.Object, value.ValueKind);
    }

    [Fact]
    public async Task Gateway_oversize_problem_is_distinguishable_from_other_502_errors()
    {
        using HttpResponseMessage response = TestData.Response(
            "{\"type\":\"about:blank\",\"title\":\"Synthetic content is not logged\",\"status\":502,\"code\":\"response_too_large\"}",
            HttpStatusCode.BadGateway, "application/problem+json");
        VerificationException error = await Assert.ThrowsAsync<VerificationException>(() =>
            BoundedHttp.ReadJsonAsync(response, 65536, TestData.Contract, CancellationToken.None));
        Assert.Equal(FailureCode.ResponseTooLarge, error.Code);
        Assert.Equal(502, error.Status);
    }

    private sealed class ByteStream(byte[] data, bool failAfterData) : Stream
    {
        private int _position;
        internal int BytesRead => _position;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => _position; set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (_position == data.Length && failAfterData) { throw new InvalidOperationException("The client read past the complete SSE result."); }
            int count = Math.Min(buffer.Length, data.Length - _position);
            data.AsMemory(_position, count).CopyTo(buffer);
            _position += count;
            return ValueTask.FromResult(count);
        }
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
