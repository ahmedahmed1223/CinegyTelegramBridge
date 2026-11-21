using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Xunit;

namespace CinegyBridge.Web.Tests;

public sealed class RestartReadinessApiTests : IDisposable
{
    private const string Route = "/api/admin/restart/readiness";
    private readonly WebApp _app = new();
    public void Dispose() => _app.Dispose();

    [Fact]
    public async Task Restart_readiness_requires_admin_and_has_no_mutation_route()
    {
        var anonymous = await _app.BrowserAsync();
        using var unauthenticated = await anonymous.Client.GetAsync(Route);
        Assert.Equal(HttpStatusCode.Unauthorized, unauthenticated.StatusCode);
        var operatorBrowser = await _app.SignedInAsync("desk", WebApp.Operator);
        using var forbidden = await operatorBrowser.Client.GetAsync(Route);
        Assert.Equal(HttpStatusCode.Forbidden, forbidden.StatusCode);
        Assert.DoesNotContain(_app.Bridge.Calls, call => call.Op.StartsWith("admin.restart", StringComparison.Ordinal));

        var admin = await _app.SignedInAsync("studio", WebApp.Admin);
        using var response = await admin.Client.GetAsync($"{Route}?actor=17&path=fixture");
        response.EnsureSuccessStatusCode();
        Assert.True(response.Headers.CacheControl!.NoStore);
        var report = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("supervisor-reported", report.GetProperty("state").GetString());
        Assert.Equal(2, report.GetProperty("activeScenes").GetInt32());
        Assert.False(report.GetProperty("managedRestartAvailable").GetBoolean());
        Assert.False(report.GetProperty("relayBlocksRestart").GetBoolean());
        Assert.Equal(5, report.EnumerateObject().Count());
        using var unsupported = await admin.PostAsync(Route, new { restart = true });
        Assert.Equal(HttpStatusCode.MethodNotAllowed, unsupported.StatusCode);
        var call = Assert.Single(_app.Bridge.Calls, call => call.Op.StartsWith("admin.restart", StringComparison.Ordinal));
        Assert.Equal("admin.restart.readiness", call.Op);
        Assert.Equal("""{"actor":22}""", call.Args);
    }
}
