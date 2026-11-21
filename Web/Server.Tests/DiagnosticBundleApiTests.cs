using System.IO.Compression;
using System.Net;
using System.Text.Json;
using Xunit;

namespace CinegyBridge.Web.Tests;

public sealed class DiagnosticBundleApiTests : IDisposable
{
    private const string Route = "/api/admin/diagnostics/runtime-bundle";
    private readonly WebApp _app = new();
    public void Dispose() => _app.Dispose();

    [Fact]
    public async Task Diagnostic_zip_requires_admin_and_uses_only_typed_safe_entries()
    {
        var anonymous = await _app.BrowserAsync();
        using var signInFirst = await anonymous.Client.GetAsync(Route);
        Assert.Equal(HttpStatusCode.Unauthorized, signInFirst.StatusCode);
        var regular = await _app.SignedInAsync("desk", WebApp.Operator);
        using var denial = await regular.Client.GetAsync(Route);
        Assert.Equal(HttpStatusCode.Forbidden, denial.StatusCode);
        Assert.DoesNotContain(_app.Bridge.Calls, command => command.Op == "admin.diagnostics.bundle");
        var admin = await _app.SignedInAsync("studio", WebApp.Admin);
        using var response = await admin.Client.GetAsync($"{Route}?actor=9283471&path=untrusted");
        response.EnsureSuccessStatusCode();
        Assert.True(response.Headers.CacheControl!.NoStore);
        Assert.Equal("application/zip", response.Content.Headers.ContentType!.MediaType);
        Assert.Equal("cinegy-bridge-diagnostics.zip", response.Content.Headers.ContentDisposition!.FileName!.Trim('"'));
        using var zip = new ZipArchive(await response.Content.ReadAsStreamAsync());
        Assert.Equal(new[] { "summary.json", "recent-runtime.json" }, zip.Entries.Select(entry => entry.FullName).ToArray());
        using var summaryStream = zip.Entries[0].Open();
        using var timelineStream = zip.Entries[1].Open();
        using var summary = await JsonDocument.ParseAsync(summaryStream);
        using var timeline = await JsonDocument.ParseAsync(timelineStream);
        Assert.True(summary.RootElement.GetProperty("lowDisk").GetBoolean());
        Assert.Equal(10, summary.RootElement.GetProperty("airOperations").GetProperty("success").GetInt32());
        var first = timeline.RootElement.GetProperty("items")[0];
        Assert.Equal("relay", first.GetProperty("category").GetString());
        Assert.False(first.TryGetProperty("raw", out _));
        Assert.DoesNotContain("9283471", summary.RootElement.GetRawText());
        Assert.DoesNotContain("secret", summary.RootElement.GetRawText());
        Assert.DoesNotContain("secret", timeline.RootElement.GetRawText());
        Assert.Contains(_app.Bridge.Calls, command => command.Op == "admin.diagnostics.bundle" && command.Args == """{"actor":22}""");
    }
}
