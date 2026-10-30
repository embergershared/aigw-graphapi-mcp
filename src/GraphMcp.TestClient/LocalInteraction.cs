using System.Diagnostics;

namespace GraphMcp.TestClient;

internal interface ILocalInteraction
{
    Task<bool> ConsentAsync(Uri exactReturnedLink, CancellationToken cancellationToken);
    Task<bool> ApproveAsync(string tool, CancellationToken cancellationToken);
}

internal sealed class LocalInteraction : ILocalInteraction
{
    public async Task<bool> ConsentAsync(Uri exactReturnedLink, CancellationToken cancellationToken)
    {
        Console.Write("OAuth consent is distinct from tool approval. Type open to open the reviewed Foundry consent route, or deny: ");
        string? action = await Console.In.ReadLineAsync(cancellationToken).ConfigureAwait(false);
        if (action != "open") { return false; }
        using Process? browser = Process.Start(new ProcessStartInfo(exactReturnedLink.AbsoluteUri) { UseShellExecute = true });
        Console.Write("Complete consent in the browser, then type done; anything else denies continuation: ");
        return await Console.In.ReadLineAsync(cancellationToken).ConfigureAwait(false) == "done";
    }

    public async Task<bool> ApproveAsync(string tool, CancellationToken cancellationToken)
    {
        // The name is allowlisted; arguments are already constrained to the configured synthetic fixtures/window.
        Console.Write($"Tool {tool} uses only the configured synthetic fixture/window (IDs and content withheld). Type approve or deny: ");
        return await Console.In.ReadLineAsync(cancellationToken).ConfigureAwait(false) == "approve";
    }
}
