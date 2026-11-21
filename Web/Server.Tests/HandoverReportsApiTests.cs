using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Xunit;

namespace CinegyBridge.Web.Tests;

public sealed class HandoverReportsApiTests : IDisposable
{
    private readonly WebApp _app = new();

    public void Dispose() => _app.Dispose();

    [Theory]
    [InlineData("weekly", "tickerPublishes")]
    [InlineData("handover", "showCount")]
    public async Task Station_report_uses_the_signed_in_actor_and_typed_noncached_data(string route, string fixtureField)
    {
        var path = $"/api/reports/{route}?actor=11";
        var anonymous = await _app.BrowserAsync();
        using var denied = await anonymous.Client.GetAsync(path);
        Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
        var browser = await _app.SignedInAsync("operator", WebApp.Operator);
        using var response = await browser.Client.GetAsync(path);
        response.EnsureSuccessStatusCode();
        Assert.True(response.Headers.CacheControl!.NoStore);
        var report = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(2, report.GetProperty(fixtureField).GetInt32());
        var call = Assert.Single(_app.Bridge.Calls, entry => entry.Op == $"reports.{route}");
        var wire = JsonSerializer.Deserialize<JsonElement>(call.Args);
        Assert.Equal(WebApp.Operator, wire.GetProperty("actor").GetInt64());
        Assert.Single(wire.EnumerateObject());
    }
}
