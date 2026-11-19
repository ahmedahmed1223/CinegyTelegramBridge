using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CinegyBridge.Web.Bridge;

/// <summary>The answer to one request on the bridge's local pipe.</summary>
public sealed record BridgeReply(bool Ok, JsonElement Data, string Error)
{
    public static BridgeReply Unavailable { get; } = new(false, default, "bridge_unavailable");

    public bool IsUnavailable => Error == "bridge_unavailable";
}

/// <summary>
/// The only way this server learns or changes anything. The bridge stays the
/// single writer to Cinegy and the single judge of permission; this server
/// only carries requests to it. An interface because the tests replace it.
/// </summary>
public interface IBridgeChannel
{
    Task<BridgeReply> SendAsync(string op, object? args = null, CancellationToken cancellationToken = default);
}

public sealed class PipeBridgeChannel(WebOptions options, ILogger<PipeBridgeChannel> logger) : IBridgeChannel
{
    private static readonly UTF8Encoding Utf8 = new(false);

    // The listener waits up to 15 s for the bridge thread; a little more here
    // so its own "bridge_busy" answer arrives rather than our timeout.
    private static readonly TimeSpan ReplyTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(5);

    public async Task<BridgeReply> SendAsync(string op, object? args = null, CancellationToken cancellationToken = default)
    {
        var request = new JsonObject { ["op"] = op };
        if (args is not null) request["args"] = JsonSerializer.SerializeToNode(args, JsonDefaults.Options);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(ReplyTimeout);
        try
        {
            await using var pipe = new NamedPipeClientStream(".", options.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
            using (var connect = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token))
            {
                connect.CancelAfter(ConnectTimeout);
                await pipe.ConnectAsync(connect.Token);
            }
            await using var writer = new StreamWriter(pipe, Utf8, 4096, leaveOpen: true);
            using var reader = new StreamReader(pipe, Utf8, false, 4096, leaveOpen: true);
            await writer.WriteLineAsync(request.ToJsonString().AsMemory(), timeout.Token);
            await writer.FlushAsync(timeout.Token);
            var line = await reader.ReadLineAsync(timeout.Token);
            return Parse(line);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            logger.LogWarning("Bridge did not answer {Op} in time", op);
            return BridgeReply.Unavailable;
        }
        catch (IOException exception)
        {
            logger.LogDebug(exception, "Bridge pipe unavailable for {Op}", op);
            return BridgeReply.Unavailable;
        }
        catch (UnauthorizedAccessException exception)
        {
            // The pipe exists but belongs to another account: the bridge and
            // this server must run as the same Windows user.
            logger.LogError(exception, "Bridge pipe refused this account");
            return BridgeReply.Unavailable;
        }
    }

    internal static BridgeReply Parse(string? line)
    {
        if (string.IsNullOrWhiteSpace(line)) return BridgeReply.Unavailable;
        using var document = JsonDocument.Parse(line);
        var root = document.RootElement;
        var ok = root.TryGetProperty("ok", out var okElement) && okElement.ValueKind == JsonValueKind.True;
        var data = root.TryGetProperty("data", out var dataElement) ? dataElement.Clone() : default;
        var error = root.TryGetProperty("error", out var errorElement) ? errorElement.GetString() ?? "" : "";
        return new BridgeReply(ok, data, error);
    }
}
