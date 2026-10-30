using GraphMcp.TestClient;
using System.Text;
using System.Text.Json;
using Xunit;

namespace GraphMcp.TestClient.Tests;

public sealed class ContinuationTests
{
    [Theory]
    [InlineData("list_messages")]
    [InlineData("list_calendar_view")]
    public void Returned_cursor_is_valid_only_for_its_protocol_user_session_and_operation(string tool)
    {
        string cursor = TestData.Cursor(tool);
        Continuations first = new(TestData.Contract);
        first.Register(tool, cursor);
        first.ValidateForRequest(tool, cursor);
        Continuations anotherUserOrProtocol = new(TestData.Contract);
        Assert.Throws<VerificationException>(() => anotherUserOrProtocol.ValidateForRequest(tool, cursor));
        string other = tool == "list_messages" ? "list_calendar_view" : "list_messages";
        Assert.Throws<VerificationException>(() => first.ValidateForRequest(other, cursor));
    }

    [Fact]
    public void Cursor_must_be_sent_alone_and_not_as_a_url()
    {
        Continuations cursors = new(TestData.Contract);
        string cursor = TestData.Cursor();
        cursors.Register("list_messages", cursor);
        TestData.Contract.ValidateArguments("list_messages", TestData.Args(new { continuation = cursor }), cursors);
        Assert.Throws<VerificationException>(() => TestData.Contract.ValidateArguments("list_messages", TestData.Args(new { continuation = cursor, page_size = 10 }), cursors));
        Assert.Throws<VerificationException>(() => cursors.Register("list_messages", "https://graph.microsoft.com/v1.0/me/messages"));
        Assert.Throws<VerificationException>(() => cursors.Register("list_messages", new string('a', 16385)));
    }

    [Theory]
    [InlineData("http://graph.microsoft.com/v1.0/me/messages")]
    [InlineData("https://fabrikam.example/v1.0/me/messages")]
    [InlineData("https://graph.microsoft.com/v1.0/users/synthetic/messages")]
    [InlineData("https://graph.microsoft.com:444/v1.0/me/messages")]
    [InlineData("https://user@graph.microsoft.com/v1.0/me/messages")]
    [InlineData("https://graph.microsoft.com/v1.0/me/messages#fragment")]
    [InlineData("https://graph.microsoft.com/v1.0/me/messages?$top=26")]
    [InlineData("https://graph.microsoft.com/v1.0/me/messages?$top=10&$select=body&$orderby=receivedDateTime%20desc&$skip=10")]
    public void Cursor_validates_graph_host_own_user_path_and_fixed_query(string link)
    {
        Continuations cursors = new(TestData.Contract);
        Assert.Throws<VerificationException>(() => cursors.Register("list_messages", TestData.Cursor(link: link)));
    }

    [Theory]
    [InlineData("&$skiptoken=other")]
    [InlineData("&$top=25")]
    [InlineData("&$expand=attachments")]
    public void Cursor_rejects_duplicate_and_unapproved_queries(string suffix)
    {
        string encoded = TestData.Cursor();
        string json = Encoding.UTF8.GetString(Convert.FromBase64String(encoded.Replace('-', '+').Replace('_', '/').PadRight(encoded.Length + ((4 - (encoded.Length % 4)) % 4), '=')));
        JsonElement original = TestData.Json(json);
        string cursor = TestData.Cursor(link: original.GetProperty("nextLink").GetString() + suffix);
        Assert.Throws<VerificationException>(() => new Continuations(TestData.Contract).Register("list_messages", cursor));
    }
}
