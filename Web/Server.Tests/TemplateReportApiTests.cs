using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Xunit;

namespace CinegyBridge.Web.Tests;

public sealed class TemplateReportApiTests : IDisposable
{
    private readonly WebApp _app = new();

    public void Dispose() => _app.Dispose();

    [Fact]
    public async Task Template_report_and_export_use_the_signed_in_actor_and_return_typed_noncached_data()
    {
        const string path = "/api/reports/templates";
        var anonymous = await _app.BrowserAsync();
        using var denied = await anonymous.Client.GetAsync(path);
        Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
        var browser = await _app.SignedInAsync("operator", WebApp.Operator);
        using var table = await browser.Client.GetAsync(path + "?period=today&scope=mine&actor=11");
        table.EnsureSuccessStatusCode();
        Assert.True(table.Headers.CacheControl!.NoStore);
        var report = await table.Content.ReadFromJsonAsync<JsonElement>();
        var item = report.GetProperty("items")[0];
        Assert.Equal("Fixture banner", item.GetProperty("name").GetString());
        Assert.Equal("Replacement", item.GetProperty("endedBy").GetString());
        Assert.False(item.TryGetProperty("values", out _));
        using var crossActor = await browser.Client.GetAsync(path + "/export?scope=all&actor=11");
        Assert.Equal(HttpStatusCode.Forbidden, crossActor.StatusCode);
        using var export = await browser.Client.GetAsync(path + "/export?period=today&scope=mine&actor=11");
        export.EnsureSuccessStatusCode();
        Assert.Equal("application/json", export.Content.Headers.ContentType!.MediaType);
        Assert.True(export.Headers.CacheControl!.NoStore);
        var file = await export.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Contains("Fixture banner", file.GetProperty("html").GetString());
        var call = _app.Bridge.Calls.Last(c => c.Op == "reports.templates");
        var wire = JsonSerializer.Deserialize<JsonElement>(call.Args);
        Assert.Equal(WebApp.Operator, wire.GetProperty("actor").GetInt64());
        Assert.Equal("mine", wire.GetProperty("scope").GetString());
    }
}
