using System.Text.Json;

namespace CinegyBridge.Web.Bridge;

internal sealed class LivePlaybackSource(IBridgeChannel bridge, WebOptions options)
{
    // The current bridge answers from a published snapshot. A stopped or old
    // bridge must not leave the initial browser document waiting on the pipe.
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromMilliseconds(500);
    private int sharedSettingSeen;

    public async Task<Uri?> ReadAsync(CancellationToken cancellationToken)
    {
        using var probe = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        probe.CancelAfter(ProbeTimeout);
        BridgeReply reply;
        try
        {
            reply = await bridge.SendAsync("live.playback", cancellationToken: probe.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            reply = BridgeReply.Unavailable;
        }
        catch (JsonException) { return null; }

        if (reply.Ok)
        {
            Volatile.Write(ref sharedSettingSeen, 1);
            return reply.Data.ValueKind == JsonValueKind.Object && reply.Data.TryGetProperty("url", out var value) &&
                value.ValueKind == JsonValueKind.String ? WebOptions.ParsePlaybackUri(value.GetString()) : null;
        }

        // An explicit clear must not reveal an obsolete server URL if the
        // bridge subsequently stops. An unknown op identifies a legacy bridge.
        return reply.Error == "unknown_op" || (reply.IsUnavailable && Volatile.Read(ref sharedSettingSeen) == 0)
            ? options.LivePlaybackUri : null;
    }
}
