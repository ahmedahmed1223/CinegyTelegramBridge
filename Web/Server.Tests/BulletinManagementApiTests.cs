using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Xunit;

namespace CinegyBridge.Web.Tests;

public sealed class BulletinManagementApiTests : IDisposable
{
    private readonly WebApp _app = new();

    public void Dispose() => _app.Dispose();

    [Theory]
    [InlineData("management", "bulletin.management", "management-ticket")]
    [InlineData("after-urgent", "bulletin.afterUrgent", "queue-ticket")]
    public async Task Bulletin_review_and_confirmation_use_the_signed_in_actor_and_only_the_review_token(
        string route, string operation, string ticket)
    {
        var anonymous = await _app.BrowserAsync();
        var url = $"/api/content/bulletins/{route}";
        using var denied = await anonymous.PostAsync($"{url}/review", new { id = "morning", revision = 3, operation = "delete" });
        Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
        var browser = await _app.SignedInAsync("operator", WebApp.Operator);
        using var review = await browser.PostAsync($"{url}/review",
            new { id = "morning", revision = 3, operation = "delete", actor = 999 });
        review.EnsureSuccessStatusCode();
        Assert.True(review.Headers.CacheControl!.NoStore);
        var summary = await review.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(ticket, summary.GetProperty("review").GetString());
        Assert.Equal(4, summary.GetProperty("rowCount").GetInt32());
        var viewed = Assert.Single(_app.Bridge.Calls, call => call.Op == operation);
        Assert.Equal(WebApp.Operator, JsonSerializer.Deserialize<JsonElement>(viewed.Args).GetProperty("actor").GetInt64());

        using var stale = await browser.PostAsync($"{url}/confirm", new { review = "stale" });
        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        using var accepted = await browser.PostAsync($"{url}/confirm",
            new { review = ticket, id = "unreviewed", operation = "clear", actor = 999 });
        accepted.EnsureSuccessStatusCode();
        Assert.True(accepted.Headers.CacheControl!.NoStore);
        var wire = JsonSerializer.Deserialize<JsonElement>(_app.Bridge.Calls.Last(call => call.Op == operation).Args);
        Assert.Equal(3, wire.EnumerateObject().Count());
        Assert.Equal(WebApp.Operator, wire.GetProperty("actor").GetInt64());
        Assert.Equal("confirm", wire.GetProperty("action").GetString());
        Assert.Equal(ticket, wire.GetProperty("review").GetString());
    }
}
