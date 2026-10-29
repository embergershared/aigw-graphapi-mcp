extern alias AzureIdentity;

using Azure.Core;
using Azure.Core.Pipeline;
using AzureIdentity::Azure.Identity;

namespace GraphMcp.TestClient;

internal sealed class UserSession : IDisposable
{
    private readonly InteractiveBrowserCredential _credential;
    private readonly Configuration _config;
    private readonly HttpClient _http;
    private bool _authenticated;

    internal UserSession(Configuration config)
    {
        _config = config;
        _http = BoundedHttp.CreateClient();
        InteractiveBrowserCredentialOptions options = new()
        {
            TenantId = config.TenantId,
            ClientId = config.ClientId,
            AuthorityHost = AzureAuthorityHosts.AzurePublicCloud,
            RedirectUri = config.RedirectUri,
            DisableAutomaticAuthentication = true,
            TokenCachePersistenceOptions = null,
            Transport = new HttpClientTransport(_http),
            Retry = { MaxRetries = 0, NetworkTimeout = TimeSpan.FromSeconds(Contract.RequestTimeoutSeconds) },
            Diagnostics = { IsLoggingEnabled = false, IsLoggingContentEnabled = false, IsDistributedTracingEnabled = false }
        };
        _credential = new InteractiveBrowserCredential(options);
    }

    internal TokenCredential Credential => _credential;

    internal async Task AuthenticateAsync(bool foundry, CancellationToken cancellationToken)
    {
        if (_authenticated) { throw new VerificationException(FailureCode.InvalidProtocol); }
        string scope = foundry ? "https://ai.azure.com/.default" : _config.GatewayScope;
        using CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(Contract.AuthenticationTimeoutSeconds));
        AuthenticationRecord record = await _credential.AuthenticateAsync(new TokenRequestContext([ scope ]), timeout.Token).ConfigureAwait(false);
        if (!string.Equals(record.TenantId, _config.TenantId, StringComparison.OrdinalIgnoreCase))
        {
            throw new VerificationException(FailureCode.Unauthorized);
        }
        _authenticated = true;
    }

    internal async Task<string> GetGatewayTokenAsync(CancellationToken cancellationToken)
    {
        if (!_authenticated) { throw new VerificationException(FailureCode.Unauthorized); }
        AccessToken token = await _credential.GetTokenAsync(new TokenRequestContext([ _config.GatewayScope ]), cancellationToken).ConfigureAwait(false);
        return token.Token;
    }

    public void Dispose() => _http.Dispose();
}
