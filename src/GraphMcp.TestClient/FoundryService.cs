using Azure.AI.Extensions.OpenAI;
using Azure.AI.Projects;
using Azure.AI.Projects.Agents;
using Azure.Core;
using OpenAI.Responses;
using System.ClientModel.Primitives;

namespace GraphMcp.TestClient;

internal interface IFoundryService
{
    Task<string> CreateConversationAsync(CancellationToken cancellationToken);
    Task<ResponseResult> RespondAsync(CreateResponseOptions options, string? conversationId, CancellationToken cancellationToken);
}

internal sealed class FoundryService : IFoundryService, IDisposable
{
    private readonly Configuration _config;
    private readonly AIProjectClient _project;
    private readonly ProjectOpenAIClient _openAI;
    private readonly HttpClient _http;

    internal FoundryService(Configuration config, Contract contract, TokenCredential credential, HttpMessageHandler? transportHandler = null)
    {
        _config = config;
        Uri endpoint = config.ProjectEndpoint ?? throw new VerificationException(FailureCode.InvalidConfiguration);
        _http = new HttpClient(new BoundedSdkHandler(endpoint, contract, transportHandler)) { Timeout = Timeout.InfiniteTimeSpan };
        HttpClientPipelineTransport transport = new(_http);
        _project = new AIProjectClient(endpoint, credential, new AIProjectClientOptions
        {
            Transport = transport,
            RetryPolicy = new ClientRetryPolicy(0),
            NetworkTimeout = TimeSpan.FromSeconds(Contract.RequestTimeoutSeconds),
            ClientLoggingOptions = new() { EnableLogging = false, EnableMessageContentLogging = false },
            EnableDistributedTracing = false
        });
        _openAI = new ProjectOpenAIClient(endpoint, credential, new ProjectOpenAIClientOptions
        {
            Transport = transport,
            RetryPolicy = new ClientRetryPolicy(0),
            NetworkTimeout = TimeSpan.FromSeconds(Contract.RequestTimeoutSeconds),
            ClientLoggingOptions = new() { EnableLogging = false, EnableMessageContentLogging = false },
            EnableDistributedTracing = false
        });
    }

    internal async Task ValidateAgentAsync(CancellationToken cancellationToken)
    {
        ProjectsAgentVersion agent = await _project.AgentAdministrationClient.GetAgentVersionAsync(
            _config.AgentName, _config.AgentVersion, cancellationToken).ConfigureAwait(false);
        AgentPlan.ValidateExisting(agent.Definition, _config);
    }

    public async Task<string> CreateConversationAsync(CancellationToken cancellationToken)
    {
        ProjectConversation conversation = await _openAI.GetProjectConversationsClient()
            .CreateProjectConversationAsync(new ProjectConversationCreationOptions(), cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrEmpty(conversation.Id)) { throw new VerificationException(FailureCode.InvalidProtocol); }
        return conversation.Id;
    }

    public async Task<ResponseResult> RespondAsync(CreateResponseOptions options, string? conversationId, CancellationToken cancellationToken)
    {
        AgentReference reference = new(_config.AgentName, _config.AgentVersion);
        ProjectResponsesClient client = _openAI.GetProjectResponsesClientForAgent(reference, conversationId);
        return await client.CreateResponseAsync(options, cancellationToken).ConfigureAwait(false);
    }

    public void Dispose() => _http.Dispose();
}
