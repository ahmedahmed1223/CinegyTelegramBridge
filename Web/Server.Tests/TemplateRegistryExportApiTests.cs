using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Xunit;

namespace CinegyBridge.Web.Tests;

public sealed class TemplateRegistryExportApiTests : IDisposable
{
    private readonly WebApp _app = new();

    public void Dispose() => _app.Dispose();

    [Fact]
    public async Task Registry_review_requires_admin_and_only_the_reviewed_bytes_become_an_attachment()
    {
        var directory = Directory.CreateDirectory(Path.Combine(_app.Root, "registry-transfer")).FullName;
        _app.Bridge.RegistryTransferDirectory = directory;
        const string path = "/api/air/template-registry/export";
        var anonymous = await _app.BrowserAsync();
        using var denied = await anonymous.PostAsync(path + "/review", new { });
        Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
        var operatorBrowser = await _app.SignedInAsync("operator", WebApp.Operator);
        using var operatorDenied = await operatorBrowser.PostAsync(path + "/review", new { });
        Assert.Equal(HttpStatusCode.Forbidden, operatorDenied.StatusCode);
        var admin = await _app.SignedInAsync("admin", WebApp.Admin);
        using var reviewResponse = await admin.PostAsync(path + "/review", new { actor = 11, path = "C:/elsewhere.json" });
        reviewResponse.EnsureSuccessStatusCode();
        Assert.True(reviewResponse.Headers.CacheControl!.NoStore);
        var review = await reviewResponse.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(1, review.GetProperty("templates").GetInt32());
        Assert.False(review.TryGetProperty("base64", out _));
        var token = review.GetProperty("review").GetString();
        using var download = await admin.PostAsync(path + "/download", new { review = token, actor = 11, path = "C:/elsewhere.json" });
        download.EnsureSuccessStatusCode();
        Assert.True(download.Headers.CacheControl!.NoStore);
        Assert.Equal("attachment", download.Content.Headers.ContentDisposition!.DispositionType);
        Assert.Equal("templates.json", download.Content.Headers.ContentDisposition.FileNameStar);
        Assert.Equal(new byte[] { 123, 32, 13, 10, 125 }, await download.Content.ReadAsByteArrayAsync());
        var last = _app.Bridge.Calls.Last(call => call.Op == "air.template-registry-export");
        var args = JsonSerializer.Deserialize<JsonElement>(last.Args);
        Assert.Equal(WebApp.Admin, args.GetProperty("actor").GetInt64());
        Assert.False(args.TryGetProperty("path", out _));
        Assert.Equal(32, args.GetProperty("transferId").GetString()!.Length);
        Assert.Empty(Directory.EnumerateFiles(directory));
    }
}
