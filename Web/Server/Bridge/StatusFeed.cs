using System.Collections.Concurrent;
using System.Threading.Channels;

namespace CinegyBridge.Web.Bridge;

/// <summary>
/// Reads the bridge's status once a second, whoever is watching, and fans it
/// out to every open event stream. One reader for all browsers: ten open tabs
/// cost the bridge what one does.
/// </summary>
public sealed class StatusFeed(IBridgeChannel bridge, ILogger<StatusFeed> logger) : BackgroundService
{
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(1);
    private readonly ConcurrentDictionary<Guid, Channel<string>> _subscribers = new();
    private volatile string _latest = Envelope(null);

    /// <summary>The last message sent: <c>{"online":bool,"status":{...}|null}</c>.</summary>
    public string Latest => _latest;

    public (Guid Id, ChannelReader<string> Reader) Subscribe()
    {
        // Bounded and dropping the oldest: a stalled browser gets the newest
        // state when it wakes, never a backlog, and never holds memory.
        var channel = Channel.CreateBounded<string>(new BoundedChannelOptions(4) { FullMode = BoundedChannelFullMode.DropOldest });
        var id = Guid.NewGuid();
        _subscribers[id] = channel;
        channel.Writer.TryWrite(_latest);
        return (id, channel.Reader);
    }

    public void Unsubscribe(Guid id)
    {
        if (_subscribers.TryRemove(id, out var channel)) channel.Writer.TryComplete();
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var wasOnline = true;
        using var timer = new PeriodicTimer(Interval);
        do
        {
            var reply = await bridge.SendAsync("status", null, stoppingToken);
            if (reply.Ok != wasOnline) logger.LogInformation("Bridge is {State}", reply.Ok ? "reachable" : "unreachable");
            wasOnline = reply.Ok;
            Publish(Envelope(reply.Ok ? reply.Data.GetRawText() : null));
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    private void Publish(string message)
    {
        _latest = message;
        foreach (var channel in _subscribers.Values) channel.Writer.TryWrite(message);
    }

    private static string Envelope(string? status) =>
        status is null ? """{"online":false,"status":null}""" : $$"""{"online":true,"status":{{status}}}""";
}
