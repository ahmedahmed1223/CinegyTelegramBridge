using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Xunit;

namespace CinegyBridge.Web.Tests;

public sealed class BulletinSceneImageApiTests : IDisposable
{
    private readonly WebApp _app = new();

    public void Dispose() => _app.Dispose();

    [Fact]
    public async Task Scene_image_picker_uses_the_signed_in_actor_and_exchanges_opaque_choices()
    {
        const string path = "/api/content/bulletins/scene-images";
        const string query = "?id=morning&rowId=opening&revision=3&actor=999";
        var anonymous = await _app.BrowserAsync();
        using var denied = await anonymous.Client.GetAsync(path + query);
        Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
        var browser = await _app.SignedInAsync("operator", WebApp.Operator);
        using var listed = await browser.Client.GetAsync(path + query);
        listed.EnsureSuccessStatusCode();
        Assert.True(listed.Headers.CacheControl!.NoStore);
        var choices = await listed.Content.ReadFromJsonAsync<JsonElement>();
        var token = choices.GetProperty("selection").GetString();
        var picture = choices.GetProperty("items")[0];
        Assert.Equal("logo.png", picture.GetProperty("label").GetString());
        Assert.False(picture.TryGetProperty("path", out _));
        var listCall = Assert.Single(_app.Bridge.Calls, call => call.Op == "bulletin.scene-images");
        Assert.Equal(WebApp.Operator, JsonSerializer.Deserialize<JsonElement>(listCall.Args).GetProperty("actor").GetInt64());

        using var stale = await browser.PostAsync(path, new { id = "morning", rowId = "opening", revision = 3, selection = "wrong", slot = 0 });
        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        using var applied = await browser.PostAsync(path, new
        {
            id = "morning", rowId = "opening", revision = 3, selection = token, slot = 0, actor = 999, path = "../other.png"
        });
        applied.EnsureSuccessStatusCode();
        Assert.True(applied.Headers.CacheControl!.NoStore);
        var saved = await applied.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(4, saved.GetProperty("revision").GetInt32());
        var call = _app.Bridge.Calls.Last(call => call.Op == "bulletin.scene-images");
        var wire = JsonSerializer.Deserialize<JsonElement>(call.Args);
        Assert.Equal(WebApp.Operator, wire.GetProperty("actor").GetInt64());
        Assert.Equal("opening", wire.GetProperty("rowId").GetString());
        Assert.False(wire.TryGetProperty("path", out _));
    }
}
