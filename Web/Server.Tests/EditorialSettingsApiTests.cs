using System.Net;
using System.Text.Json;
using Xunit;

namespace CinegyBridge.Web.Tests;

public sealed class EditorialSettingsApiTests : IDisposable
{
    private const string ReviewRoute = "/api/admin/settings/import/review";
    private readonly WebApp _app = new();
    public void Dispose() => _app.Dispose();

    [Fact]
    public async Task Editorial_snapshot_round_trips_typed_values_and_rejects_extra_or_malformed_keys()
    {
        var operatorBrowser = await _app.SignedInAsync("desk", WebApp.Operator);
        using var denied = await operatorBrowser.Client.GetAsync("/api/admin/settings/export");
        Assert.Equal(HttpStatusCode.Forbidden, denied.StatusCode);
        var admin = await _app.SignedInAsync("studio", WebApp.Admin);
        using var response = await admin.Client.GetAsync("/api/admin/settings/export");
        response.EnsureSuccessStatusCode();
        Assert.True(response.Headers.CacheControl!.NoStore);
        using var export = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var settings = export.RootElement.GetProperty("Settings");
        Assert.Equal(0, settings.GetProperty("TemplateReminderFollowUpMinutes").GetInt32());
        Assert.False(settings.GetProperty("MojazNotifyOnFinish").GetBoolean());
        Assert.Equal(8, settings.GetProperty("UrgentBoardIntervalSeconds").GetInt32());
        Assert.False(settings.TryGetProperty("BotToken", out _));
        Assert.False(settings.TryGetProperty("NewsDraftTimeoutMinutes", out _));

        using var review = await admin.PostAsync(ReviewRoute, export.RootElement);
        review.EnsureSuccessStatusCode();
        var imported = Assert.Single(_app.Bridge.Calls, call => call.Op == "admin.settings.import.review");
        using var args = JsonDocument.Parse(imported.Args);
        Assert.Equal(22, args.RootElement.GetProperty("actor").GetInt32());
        Assert.Equal(3, args.RootElement.GetProperty("settings").EnumerateObject().Count());

        foreach (var payload in new[]
        {
            """{"Kind":"CinegyTelegramBridge.Settings","Settings":{"TemplateReminderFollowUpMinutes":"0"}}""",
            """{"Kind":"CinegyTelegramBridge.Settings","Settings":{"TemplateReminderFollowUpMinutes":0,"TemplateReminderFollowUpMinutes":2}}""",
            """{"Kind":"CinegyTelegramBridge.Settings","Settings":{"TemplateReminderFollowUpMinutes":0,"BotToken":true}}""",
            """{"Kind":"CinegyTelegramBridge.Settings","Settings":{"mojazNotifyOnFinish":false}}"""
        })
        {
            using var invalid = JsonDocument.Parse(payload);
            using var rejected = await admin.PostAsync(ReviewRoute, invalid.RootElement);
            Assert.Equal(HttpStatusCode.BadRequest, rejected.StatusCode);
        }
        Assert.Single(_app.Bridge.Calls, call => call.Op == "admin.settings.import.review");
    }
}
