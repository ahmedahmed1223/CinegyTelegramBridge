using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using CinegyBridge.Web.Endpoints;
using Xunit;

namespace CinegyBridge.Web.Tests;

public sealed class ManagedRestartApiTests : IDisposable
{
    private const string Root = "/api/admin/restart";
    private readonly WebApp _app = new();
    public void Dispose() => _app.Dispose();

    [Fact]
    public async Task Managed_restart_requires_admin_csrf_and_a_separate_session_bound_receipt()
    {
        var viewer = await _app.SignedInAsync("operator", WebApp.Operator);
        Assert.Equal(HttpStatusCode.Forbidden, (await viewer.PostAsync($"{Root}/review", new { })).StatusCode);
        var admin = await _app.SignedInAsync("studio", WebApp.Admin);
        admin.Client.DefaultRequestHeaders.Remove("X-XSRF-TOKEN");
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PostAsync($"{Root}/review", new { })).StatusCode);
        await admin.RefreshSessionAsync();
        using var reviewed = await admin.PostAsync($"{Root}/review", new { actor = 42, session = "fake-session" });
        reviewed.EnsureSuccessStatusCode();
        Assert.True(reviewed.Headers.CacheControl!.NoStore);
        var review = (await reviewed.Content.ReadFromJsonAsync<ManagedRestartResult>())!;
        Assert.Empty(review.Receipt);
        using var confirmation = await admin.PostAsync($"{Root}/confirm", new { review.Id });
        confirmation.EnsureSuccessStatusCode();
        var confirmed = (await confirmation.Content.ReadFromJsonAsync<ManagedRestartResult>())!;
        Assert.Equal("reviewed", confirmed.State);
        Assert.DoesNotContain(_app.Bridge.Calls, call => call.Op == "admin.restart.accept");
        using var accepted = await admin.PostAsync($"{Root}/accept", new { confirmed.Id, confirmed.Receipt });
        accepted.EnsureSuccessStatusCode();
        Assert.Equal("received", (await accepted.Content.ReadFromJsonAsync<ManagedRestartResult>())!.State);
        using var status = await admin.Client.GetAsync($"{Root}/{review.Id}/status");
        Assert.Equal("running", (await status.Content.ReadFromJsonAsync<ManagedRestartResult>())!.State);
        Assert.Equal(HttpStatusCode.BadRequest, (await admin.PostAsync($"{Root}/accept", new { confirmed.Id, receipt = "invalid" })).StatusCode);

        var requests = _app.Bridge.Calls.Where(call => call.Op.StartsWith("admin.restart.", StringComparison.Ordinal)).ToArray();
        Assert.Equal(4, requests.Length);
        using var first = JsonDocument.Parse(requests[0].Args);
        var hash = first.RootElement.GetProperty("session").GetString();
        Assert.Equal(64, hash?.Length);
        Assert.All(requests, call =>
        {
            using var payload = JsonDocument.Parse(call.Args);
            Assert.Equal(22, payload.RootElement.GetProperty("actor").GetInt32());
            Assert.Equal(hash, payload.RootElement.GetProperty("session").GetString());
        });
    }
}
