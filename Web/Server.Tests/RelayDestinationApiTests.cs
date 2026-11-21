using System.Net;
using System.Net.Http.Json;
using CinegyBridge.Web.Endpoints;
using Xunit;

namespace CinegyBridge.Web.Tests;

public sealed class RelayDestinationApiTests : IDisposable
{
    private const string Root = "/api/live/relay/destination";
    private readonly WebApp _app = new();
    public void Dispose() => _app.Dispose();

    [Fact]
    public async Task Relay_destination_uses_admin_csrf_and_authored_review_without_returning_credentials()
    {
        var url = "rtmps://user:fixture-secret@receiver.example.invalid/live/key?secret=fixture-query";
        var revision = new string('A', 64);
        var payload = new { actor = 999, revision, destination = url };
        var viewer = await _app.SignedInAsync("desk", WebApp.Operator);
        using var denial = await viewer.PostAsync($"{Root}/review", payload);
        Assert.Equal(HttpStatusCode.Forbidden, denial.StatusCode);
        var admin = await _app.SignedInAsync("studio", WebApp.Admin);
        admin.Client.DefaultRequestHeaders.Remove("X-XSRF-TOKEN");
        using var noCsrf = await admin.PostAsync($"{Root}/review", payload);
        Assert.Equal(HttpStatusCode.BadRequest, noCsrf.StatusCode);
        await admin.RefreshSessionAsync();
        using var tooLong = await admin.PostAsync($"{Root}/review", new { revision, destination = new string('Z', 4097) });
        Assert.Equal(HttpStatusCode.BadRequest, tooLong.StatusCode);
        Assert.DoesNotContain(_app.Bridge.Calls, command => command.Op.StartsWith("relay.destination", StringComparison.Ordinal));

        using var reviewed = await admin.PostAsync($"{Root}/review", payload);
        reviewed.EnsureSuccessStatusCode();
        Assert.True(reviewed.Headers.CacheControl!.NoStore);
        var reviewedBody = await reviewed.Content.ReadAsStringAsync();
        Assert.DoesNotContain("fixture-secret", reviewedBody);
        Assert.DoesNotContain("fixture-query", reviewedBody);
        var review = (await reviewed.Content.ReadFromJsonAsync<RelayDestinationReview>())!.Review;
        using var applied = await admin.PostAsync($"{Root}/confirm", new { revision, destination = url, review });
        applied.EnsureSuccessStatusCode();
        Assert.Equal("destination-saved", (await applied.Content.ReadFromJsonAsync<RelayState>())!.Outcome);
        Assert.DoesNotContain("fixture-secret", await applied.Content.ReadAsStringAsync());
        Assert.Contains(_app.Bridge.Calls, command => command.Op == "relay.destination.review" && command.Args.Contains("\"actor\":22"));
        Assert.DoesNotContain(_app.Bridge.Calls, command => command.Op == "relay.control");
    }
}
