using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Xunit;

namespace CinegyBridge.Web.Tests;

public sealed class OperationReferenceApiTests : IDisposable
{
    private const string Path = "/api/history/operation-reference";
    private readonly WebApp _app = new();

    public void Dispose() => _app.Dispose();

    [Fact]
    public async Task Lookup_requires_admin_and_distinguishes_bounded_safe_results()
    {
        var anonymous = await _app.BrowserAsync();
        using var unauthenticated = await anonymous.Client.GetAsync($"{Path}?reference=5023333B");
        Assert.Equal(HttpStatusCode.Unauthorized, unauthenticated.StatusCode);
        var operatorBrowser = await _app.SignedInAsync("operator", WebApp.Operator);
        using var denied = await operatorBrowser.Client.GetAsync($"{Path}?reference=5023333B");
        Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
        Assert.DoesNotContain(_app.Bridge.Calls, entry => entry.Op == "shift.operation-reference");
        var admin = await _app.SignedInAsync("admin", WebApp.Admin);
        using var invalid = await admin.Client.GetAsync($"{Path}?reference=5023");
        Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
        using var found = await admin.Client.GetAsync($"{Path}?reference=5023333B&actor=11&path=untrusted");
        found.EnsureSuccessStatusCode();
        Assert.True(found.Headers.CacheControl!.NoStore);
        var payload = await found.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("found", payload.GetProperty("status").GetString());
        var item = payload.GetProperty("items")[0];
        Assert.Equal("SHOW", item.GetProperty("action").GetString());
        Assert.Equal(6, item.EnumerateObject().Count());
        var call = _app.Bridge.Calls.Last(entry => entry.Op == "shift.operation-reference");
        var wire = JsonSerializer.Deserialize<JsonElement>(call.Args);
        Assert.Equal(WebApp.Admin, wire.GetProperty("actor").GetInt64());
        Assert.False(wire.TryGetProperty("path", out _));
        foreach (var (reference, status) in new[] { ("abcdef01", "collision"), ("f00dcafe", "missing") })
        {
            using var response = await admin.Client.GetAsync($"{Path}?reference={reference}");
            var summary = await response.Content.ReadFromJsonAsync<JsonElement>();
            Assert.Equal(status, summary.GetProperty("status").GetString());
            Assert.Equal(0, summary.GetProperty("items").GetArrayLength());
        }
    }
}
