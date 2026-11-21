using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Xunit;

namespace CinegyBridge.Web.Tests;

public sealed class TemplateRegistryImportApiTests : IDisposable
{
    private const string Path = "/api/air/template-registry/import";
    private static readonly byte[] Fixture = Encoding.UTF8.GetBytes("{\"Fixture\":{\"path\":\"D:/approved/fixture.cintitle\",\"layer\":2,\"presets\":[{\"name\":\"large\",\"values\":[\"" + new string('a', 100_000) + "\"]}]}}");
    private readonly WebApp _app = new();

    public void Dispose() => _app.Dispose();

    private static async Task<HttpResponseMessage> Upload(Browser browser, string action, byte[] bytes, string? review = null)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"{Path}/{action}?actor=11&path=arbitrary");
        request.Content = new ByteArrayContent(bytes);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        if (review is not null) request.Headers.Add("X-Template-Registry-Review", review);
        return await browser.Client.SendAsync(request);
    }

    [Fact]
    public async Task Import_requires_admin_and_routes_bounded_bytes_and_review_only()
    {
        var directory = Directory.CreateDirectory(System.IO.Path.Combine(_app.Root, "registry-transfer")).FullName;
        _app.Bridge.RegistryTransferDirectory = directory;
        var operatorBrowser = await _app.SignedInAsync("operator", WebApp.Operator);
        using var operatorDenied = await Upload(operatorBrowser, "review", Fixture);
        Assert.Equal(HttpStatusCode.Forbidden, operatorDenied.StatusCode);
        var admin = await _app.SignedInAsync("admin", WebApp.Admin);
        using var oversized = await Upload(admin, "review", new byte[10 * 1024 * 1024 + 1]);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, oversized.StatusCode);
        Assert.DoesNotContain(_app.Bridge.Calls, call => call.Op == "air.template-registry-import" && call.Args.Contains("transferId"));
        Assert.Empty(Directory.EnumerateFiles(directory));
        using var review = await Upload(admin, "review", Fixture);
        review.EnsureSuccessStatusCode();
        Assert.True(review.Headers.CacheControl!.NoStore);
        var summary = await review.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(1, summary.GetProperty("added").GetInt32());
        using var confirmed = await Upload(admin, "confirm", Fixture, summary.GetProperty("review").GetString());
        Assert.Equal(HttpStatusCode.NoContent, confirmed.StatusCode);
        var last = _app.Bridge.Calls.Last(call => call.Op == "air.template-registry-import");
        var args = JsonSerializer.Deserialize<JsonElement>(last.Args);
        Assert.Equal(WebApp.Admin, args.GetProperty("actor").GetInt64());
        Assert.Equal(Fixture, _app.Bridge.RegistryUploadBytes);
        Assert.False(args.TryGetProperty("base64", out _));
        Assert.Equal(32, args.GetProperty("transferId").GetString()!.Length);
        Assert.True(last.Args.Length < 1024);
        Assert.False(args.TryGetProperty("path", out _));
        Assert.Empty(Directory.EnumerateFiles(directory));
        using var exportReview = await admin.PostAsync("/api/air/template-registry/export/review", new { });
        var exported = await exportReview.Content.ReadFromJsonAsync<JsonElement>();
        using var download = await admin.PostAsync("/api/air/template-registry/export/download", new { review = exported.GetProperty("review").GetString() });
        Assert.Equal(Fixture, await download.Content.ReadAsByteArrayAsync());
        Assert.Empty(Directory.EnumerateFiles(directory));
    }
}
