using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using CinegyBridge.Web.Endpoints;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;

namespace CinegyBridge.Web.Tests;

public sealed class TickerTxtTests : IDisposable
{
    private readonly WebApp _app = new();

    public void Dispose() => _app.Dispose();

    [Fact]
    public async Task Streamed_file_is_bounded_and_removed_after_the_bridge_reads_its_exact_bytes()
    {
        var directory = Path.Combine(_app.Root, "uploads");
        _app.Bridge.TickerTxtDirectory = directory;
        var browser = await _app.SignedInAsync("ticker-editor", WebApp.Operator);
        var path = $"/api/content/ticker/draft/txt?action=preview&revision={new string('A', 64)}";
        using var tooLarge = new ByteArrayContent(new byte[70_001]);
        tooLarge.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        using var refused = await browser.Client.PostAsync(path, tooLarge);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, refused.StatusCode);
        Assert.False(Directory.Exists(directory));

        var bytes = Enumerable.Range(0, 68_000).Select(i => (byte)i).ToArray();
        using var payload = new ByteArrayContent(bytes);
        payload.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        using var response = await browser.Client.PostAsync(path, payload);
        var preview = await response.Content.ReadFromJsonAsync<TickerTxtPreview>();
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.NotNull(preview);
        Assert.Equal("خبر جديد", Assert.Single(preview.Items));
        Assert.Equal(bytes, _app.Bridge.TickerTxtBytes);
        Assert.Empty(Directory.EnumerateFiles(directory));
    }
}

public sealed class SignInTests : IDisposable
{
    private readonly WebApp _app = new();

    public void Dispose() => _app.Dispose();

    [Fact]
    public async Task Status_is_closed_to_anyone_not_signed_in()
    {
        var browser = await _app.BrowserAsync();
        var response = await browser.Client.GetAsync("/api/status");
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task Only_a_signed_in_viewer_receives_the_configured_playback_url()
    {
        using var configured = _app.WithWebHostBuilder(host => host.UseSetting("LivePlaybackUrl", "https://media.example.test/output/main.m3u8"));
        using var client = configured.CreateClient(new() { BaseAddress = new Uri("http://localhost") });
        using var denied = await client.GetAsync("/api/live");
        Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
        Assert.Contains("https://media.example.test", denied.Headers.GetValues("Content-Security-Policy").Single());

        await _app.AddPasswordAccountAsync("desk", WebApp.Operator);
        var browser = new Browser(client);
        await browser.RefreshSessionAsync();
        using var login = await browser.PostAsync("/api/auth/password", new PasswordSignInRequest("desk", "correct horse battery"));
        login.EnsureSuccessStatusCode();
        var playback = await client.GetFromJsonAsync<LivePlayback>("/api/live");
        Assert.Equal("https://media.example.test/output/main.m3u8", playback!.Url);
    }

    [Fact]
    public async Task Only_administrators_can_review_and_control_the_relay_with_csrf()
    {
        var viewer = await _app.SignedInAsync("desk", WebApp.Operator);
        Assert.Equal(HttpStatusCode.Forbidden, (await viewer.Client.GetAsync("/api/live/relay")).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await viewer.PostAsync("/api/live/relay", new RelayRequest("start", "review"))).StatusCode);
        Assert.DoesNotContain(_app.Bridge.Calls, call => call.Op == "relay.control");

        var administrator = await _app.SignedInAsync("studio", WebApp.Admin);
        var state = await administrator.Client.GetFromJsonAsync<RelayState>("/api/live/relay");
        Assert.Equal("review", state!.Revision);
        administrator.Client.DefaultRequestHeaders.Remove("X-XSRF-TOKEN");
        var payload = new { action = "start", revision = state.Revision, actor = 999 };
        Assert.Equal(HttpStatusCode.BadRequest, (await administrator.PostAsync("/api/live/relay", payload)).StatusCode);
        await administrator.RefreshSessionAsync();
        var response = await administrator.PostAsync("/api/live/relay", payload);
        Assert.Equal("starting", (await response.Content.ReadFromJsonAsync<RelayState>())!.State);
        Assert.Contains(_app.Bridge.Calls, call => call.Op == "relay.control" && call.Args.Contains("\"actor\":22") && call.Args.Contains("\"action\":\"start\""));
    }

    [Fact]
    public async Task Capture_bytes_are_private_seekable_and_never_expose_a_local_path()
    {
        var viewer = await _app.SignedInAsync("desk", WebApp.Operator);
        var administrator = await _app.SignedInAsync("studio", WebApp.Admin);
        var anonymous = await _app.BrowserAsync();
        var path = Path.Combine(Path.GetTempPath(), $"snapshot-web-{_app.Bridge.CaptureId}.mp4");
        var route = $"/api/live/captures/{_app.Bridge.CaptureId}/file";
        await File.WriteAllBytesAsync(path, [1, 2, 3, 4]);
        try
        {
            _app.Bridge.CapturePath = path;
            using var denied = await anonymous.Client.GetAsync(route);
            Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
            using var foreign = await administrator.Client.GetAsync(route);
            Assert.Equal(HttpStatusCode.NotFound, foreign.StatusCode);
            viewer.Client.DefaultRequestHeaders.Remove("X-XSRF-TOKEN");
            using var missingToken = await viewer.PostAsync("/api/live/captures", new CaptureCreateRequest("clip"));
            Assert.Equal(HttpStatusCode.BadRequest, missingToken.StatusCode);
            await viewer.RefreshSessionAsync();
            using var created = await viewer.PostAsync("/api/live/captures", new { kind = "clip", actor = WebApp.Admin });
            created.EnsureSuccessStatusCode();
            var capture = await created.Content.ReadFromJsonAsync<OutputCapture>();
            Assert.Equal(_app.Bridge.CaptureId, capture!.Id);
            Assert.DoesNotContain("path", await created.Content.ReadAsStringAsync());
            using var range = new HttpRequestMessage(HttpMethod.Get, route);
            range.Headers.Range = new(1, 2);
            using var clip = await viewer.Client.SendAsync(range);
            Assert.Equal(HttpStatusCode.PartialContent, clip.StatusCode);
            Assert.Equal("video/mp4", clip.Content.Headers.ContentType!.MediaType);
            Assert.True(clip.Headers.CacheControl!.NoStore);
            Assert.Equal(new byte[] { 2, 3 }, await clip.Content.ReadAsByteArrayAsync());
            _app.Bridge.CapturePath = path + ".other";
            using var wrongFile = await viewer.Client.GetAsync(route);
            Assert.Equal(HttpStatusCode.NotFound, wrongFile.StatusCode);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public async Task Bulletin_image_requires_sign_in_and_a_matching_raster_file_within_the_scene()
    {
        var desk = await _app.SignedInAsync("desk", WebApp.Operator);
        var anonymous = await _app.BrowserAsync();
        var directory = Directory.CreateTempSubdirectory("cgb-bulletin-");
        var scene = directory.CreateSubdirectory("scene");
        var path = Path.Combine(scene.FullName, "photo.png");
        var outside = Path.Combine(directory.FullName, "outside.png");
        var image = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aB8kAAAAASUVORK5CYII=");
        var route = "/api/content/bulletins/preview-image?id=b_1&rowId=r_1&field=mojaz_img&revision=1&stamp=review";
        try
        {
            await File.WriteAllBytesAsync(path, image);
            await File.WriteAllBytesAsync(outside, image);
            _app.Bridge.BulletinPreviewImage = (scene.FullName, path);
            using var denied = await anonymous.Client.GetAsync(route);
            Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);
            using var allowed = await desk.Client.GetAsync(route);
            Assert.Equal(HttpStatusCode.OK, allowed.StatusCode);
            Assert.Equal("image/png", allowed.Content.Headers.ContentType!.MediaType);
            Assert.True(allowed.Headers.CacheControl!.NoStore);
            Assert.Equal(image, await allowed.Content.ReadAsByteArrayAsync());

            _app.Bridge.BulletinPreviewImage = (scene.FullName, outside);
            using var escaped = await desk.Client.GetAsync(route);
            Assert.Equal(HttpStatusCode.NotFound, escaped.StatusCode);
            _app.Bridge.BulletinPreviewImage = (scene.FullName, path);
            await File.WriteAllTextAsync(path, "<html>not a PNG</html>");
            using var wrongFormat = await desk.Client.GetAsync(route);
            Assert.Equal(HttpStatusCode.NotFound, wrongFormat.StatusCode);
        }
        finally
        {
            _app.Bridge.BulletinPreviewImage = null;
            File.Delete(path);
            File.Delete(outside);
            scene.Delete();
            directory.Delete();
        }
    }

    [Theory]
    [InlineData("http://media.example.test/output/main.m3u8")]
    [InlineData("https://name:secret@media.example.test/output.m3u8")]
    [InlineData("https://media.example.test/output.m3u8?key=secret")]
    [InlineData("file:///C:/Station/source.m3u8")]
    public void Playback_configuration_refuses_insecure_or_credentialed_sources(string url)
    {
        Assert.Null(WebOptions.ParsePlaybackUri(url));
    }

    [Fact]
    public async Task Bulletin_playback_requires_the_session_and_uses_its_operator_for_review()
    {
        const string route = "/api/content/bulletins/playback";
        var anonymous = await _app.BrowserAsync();
        using var denied = await anonymous.Client.GetAsync(route + "?id=b_1");
        Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);

        var desk = await _app.SignedInAsync("desk", WebApp.Operator);
        using var reviewed = await desk.PostAsync(route, new { action = "review", id = "b_1", revision = 3, stamp = "preview", actor = WebApp.Admin });
        reviewed.EnsureSuccessStatusCode();
        Assert.True(reviewed.Headers.CacheControl!.NoStore);
        var data = (await reviewed.Content.ReadFromJsonAsync<BulletinPlayback>())!;
        Assert.Equal("ticket", data.Review);
        Assert.Equal(4, data.Layer);
        var call = _app.Bridge.Calls.Last(entry => entry.Op == "bulletin.playback");
        using var arguments = System.Text.Json.JsonDocument.Parse(call.Args);
        Assert.Equal(WebApp.Operator, arguments.RootElement.GetProperty("actor").GetInt64());

        using var stale = await desk.PostAsync(route, new BulletinPlaybackRequest("start", "b_1", Review: "expired"));
        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        Assert.Equal("bulletin_playback_stale", (await stale.Content.ReadFromJsonAsync<ErrorResponse>())!.Error);
    }

    [Fact]
    public async Task A_post_without_the_anti_forgery_token_is_refused()
    {
        await _app.AddPasswordAccountAsync("desk", WebApp.Operator);
        var client = _app.CreateClient();
        var response = await client.PostAsJsonAsync("/api/auth/password", new PasswordSignInRequest("desk", "correct horse battery"));
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal("csrf", (await response.Content.ReadFromJsonAsync<ErrorResponse>())!.Error);
    }

    [Fact]
    public async Task Password_sign_in_opens_the_status_and_names_the_user()
    {
        var browser = await _app.SignedInAsync("desk", WebApp.Operator);
        Assert.Equal("Operator", browser.Session!.User!.Name);
        Assert.Equal("operator", browser.Session.User.Role);

        var status = await browser.Client.GetFromJsonAsync<StatusEnvelope>("/api/status");
        Assert.NotNull(status);
    }

    [Fact]
    public async Task Wrong_password_and_unknown_user_get_the_same_answer()
    {
        await _app.AddPasswordAccountAsync("desk", WebApp.Operator);
        var browser = await _app.BrowserAsync();
        var wrong = await browser.PostAsync("/api/auth/password", new PasswordSignInRequest("desk", "not the password"));
        var unknown = await browser.PostAsync("/api/auth/password", new PasswordSignInRequest("nobody", "not the password"));
        Assert.Equal(HttpStatusCode.Unauthorized, wrong.StatusCode);
        Assert.Equal(await wrong.Content.ReadAsStringAsync(), await unknown.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Five_wrong_passwords_lock_the_account_even_against_the_right_one()
    {
        await _app.AddPasswordAccountAsync("desk", WebApp.Operator);
        var accounts = _app.Accounts;
        for (var i = 0; i < 5; i++) await accounts.SignInAsync("desk", "wrong password!!");
        var browser = await _app.BrowserAsync();
        var response = await browser.PostAsync("/api/auth/password", new PasswordSignInRequest("desk", "correct horse battery"));
        Assert.Equal(HttpStatusCode.Locked, response.StatusCode);
    }

    [Fact]
    public async Task Losing_access_in_the_bot_ends_the_browser_session()
    {
        var browser = await _app.SignedInAsync("desk", WebApp.Operator);
        _app.Bridge.Users.TryRemove(WebApp.Operator, out _);
        // Past the identity cache.
        _app.Services.GetRequiredService<CinegyBridge.Web.Auth.BridgeIdentity>().Forget(WebApp.Operator);
        var response = await browser.Client.GetAsync("/api/status");
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task A_request_for_another_host_name_is_refused()
    {
        var client = _app.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/session");
        request.Headers.Host = "evil.example";
        var response = await client.SendAsync(request);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Telegram_approval_signs_the_waiting_browser_in_once()
    {
        var browser = await _app.BrowserAsync();
        var start = await (await browser.PostAsync("/api/auth/telegram", new { })).Content.ReadFromJsonAsync<TelegramSignInResponse>();
        Assert.Equal(_app.Bridge.LastLoginCode, start!.Code);

        var pending = await (await browser.PostAsync($"/api/auth/telegram/{start.FlowId}", new { })).Content.ReadFromJsonAsync<TelegramPollResponse>();
        Assert.Equal("pending", pending!.State);

        _app.Bridge.Approve(start.Code, WebApp.Admin);
        var approved = await (await browser.PostAsync($"/api/auth/telegram/{start.FlowId}", new { })).Content.ReadFromJsonAsync<TelegramPollResponse>();
        Assert.Equal("approved", approved!.State);
        await browser.RefreshSessionAsync();
        Assert.Equal(WebApp.Admin, browser.Session!.User!.Id);

        // The flow id is spent.
        var again = await (await browser.PostAsync($"/api/auth/telegram/{start.FlowId}", new { })).Content.ReadFromJsonAsync<TelegramPollResponse>();
        Assert.Equal("expired", again!.State);
    }

    [Fact]
    public async Task A_guessed_flow_id_opens_nothing()
    {
        var browser = await _app.BrowserAsync();
        var poll = await (await browser.PostAsync("/api/auth/telegram/0123456789abcdef", new { })).Content.ReadFromJsonAsync<TelegramPollResponse>();
        Assert.Equal("expired", poll!.State);
    }
}

public sealed class AccountTests : IDisposable
{
    private readonly WebApp _app = new();

    public void Dispose() => _app.Dispose();

    [Fact]
    public async Task An_operator_cannot_see_accounts()
    {
        var browser = await _app.SignedInAsync("desk", WebApp.Operator);
        Assert.Equal(HttpStatusCode.Forbidden, (await browser.Client.GetAsync("/api/accounts")).StatusCode);
    }

    [Fact]
    public async Task An_administrator_adds_a_browser_only_operator_through_the_bridge()
    {
        var browser = await _app.SignedInAsync("chief", WebApp.Admin);
        var response = await browser.PostAsync("/api/accounts",
            new CreateAccountRequest("webOnly", "night.desk", "a long enough password", "Night desk", null, "operator"));
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        Assert.Contains(_app.Bridge.Calls, call => call.Op == "account.grant" && call.Args.Contains($"\"actor\":{WebApp.Admin}"));

        var created = await response.Content.ReadFromJsonAsync<WebAccountResponse>();
        Assert.True(created!.UserId >= 9_000_000_000_000_000L);

        var newcomer = await _app.BrowserAsync();
        var signIn = await newcomer.PostAsync("/api/auth/password", new PasswordSignInRequest("night.desk", "a long enough password"));
        Assert.Equal(HttpStatusCode.NoContent, signIn.StatusCode);
    }

    [Fact]
    public async Task An_administrator_cannot_take_over_the_owner_by_resetting_a_password()
    {
        await _app.AddPasswordAccountAsync("boss", WebApp.Owner);
        var browser = await _app.SignedInAsync("chief", WebApp.Admin);
        var response = await browser.PutAsync("/api/accounts/boss/password", new SetPasswordRequest("attacker chosen password"));
        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    [Fact]
    public async Task The_owner_alone_creates_a_browser_only_administrator()
    {
        var admin = await _app.SignedInAsync("chief", WebApp.Admin);
        var refused = await admin.PostAsync("/api/accounts",
            new CreateAccountRequest("webOnly", "deputy", "a long enough password", "Deputy", null, "admin"));
        Assert.Equal(HttpStatusCode.Forbidden, refused.StatusCode);

        var owner = await _app.SignedInAsync("boss", WebApp.Owner);
        var allowed = await owner.PostAsync("/api/accounts",
            new CreateAccountRequest("webOnly", "deputy", "a long enough password", "Deputy", null, "admin"));
        Assert.Equal(HttpStatusCode.Created, allowed.StatusCode);
    }

    [Fact]
    public async Task A_short_password_is_refused()
    {
        var browser = await _app.SignedInAsync("chief", WebApp.Admin);
        var response = await browser.PostAsync("/api/accounts",
            new CreateAccountRequest("telegram", "op.desk", "short", null, WebApp.Operator, null));
        Assert.Equal("password_too_short", (await response.Content.ReadFromJsonAsync<ErrorResponse>())!.Error);
    }

    [Fact]
    public async Task Resetting_a_password_signs_out_whoever_used_the_old_one()
    {
        var desk = await _app.SignedInAsync("desk", WebApp.Operator);
        var admin = await _app.SignedInAsync("chief", WebApp.Admin);
        var reset = await admin.PutAsync("/api/accounts/desk/password", new SetPasswordRequest("a brand new password"));
        Assert.Equal(HttpStatusCode.NoContent, reset.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await desk.Client.GetAsync("/api/status")).StatusCode);
    }

    [Fact]
    public async Task Air_operations_require_authentication_and_route_to_bridge()
    {
        var anon = await _app.BrowserAsync();
        var unauth = await anon.Client.GetAsync("/api/air/templates");
        Assert.Equal(HttpStatusCode.Unauthorized, unauth.StatusCode);

        var op = await _app.SignedInAsync("desk", WebApp.Operator);
        
        // 1. Templates
        var tpls = await op.Client.GetFromJsonAsync<List<TemplateDto>>("/api/air/templates");
        Assert.NotNull(tpls);
        Assert.Single(tpls);
        Assert.Equal("test_l3d", tpls[0].Key);

        // 2. Show
        var showRes = await op.PostAsync("/api/air/show", new ShowTemplateRequest("test_l3d", new Dictionary<string, string> { ["title"] = "Breaking" }, 10));
        Assert.Equal(HttpStatusCode.NoContent, showRes.StatusCode);
        Assert.Contains(_app.Bridge.Calls, c => c.Op == "air.show" && c.Args.Contains("test_l3d"));

        // 3. Hide
        var hideRes = await op.PostAsync("/api/air/hide/5", new { });
        Assert.Equal(HttpStatusCode.NoContent, hideRes.StatusCode);
        Assert.Contains(_app.Bridge.Calls, c => c.Op == "air.hide" && c.Args.Contains("\"layer\":5"));

        // 4. Exit
        var exitRes = await op.PostAsync("/api/air/exit/5", new { });
        Assert.Equal(HttpStatusCode.NoContent, exitRes.StatusCode);
        Assert.Contains(_app.Bridge.Calls, c => c.Op == "air.exit" && c.Args.Contains("\"layer\":5"));
    }

    [Fact]
    public async Task Newsroom_passes_the_signed_in_identity_and_requested_page_to_the_bridge()
    {
        var anonymous = await _app.BrowserAsync();
        Assert.Equal(HttpStatusCode.Unauthorized, (await anonymous.Client.GetAsync("/api/content/ticker?page=1")).StatusCode);

        var browser = await _app.SignedInAsync("desk", WebApp.Operator);
        var response = await browser.Client.GetAsync("/api/content/ticker?page=1");
        response.EnsureSuccessStatusCode();
        Assert.True(response.Headers.CacheControl?.NoStore);
        var page = await response.Content.ReadFromJsonAsync<ContentPage>();
        Assert.NotNull(page);
        Assert.Equal(1, page.Page);
        Assert.Equal("خبر منشور", Assert.Single(page.Items).Title);
        Assert.Contains(_app.Bridge.Calls, call => call.Op == "content.list" &&
            call.Args == """{"actor":33,"view":"ticker","page":1}""");
    }

    [Fact]
    public async Task Urgent_table_requires_csrf_and_reports_an_outdated_revision()
    {
        var browser = await _app.SignedInAsync("desk", WebApp.Operator);
        var row = new UrgentRowInput(new() { ["strap"] = "خبر جديد", ["location"] = "الميدان" }, true);
        var request = new UrgentWriteRequest("add", 3, Row: row);
        browser.Client.DefaultRequestHeaders.Remove("X-XSRF-TOKEN");
        Assert.Equal(HttpStatusCode.BadRequest, (await browser.PostAsync("/api/content/urgent", request)).StatusCode);
        Assert.DoesNotContain(_app.Bridge.Calls, call => call.Op == "urgent.write");
        await browser.RefreshSessionAsync();
        Assert.Equal(HttpStatusCode.NoContent, (await browser.PostAsync("/api/content/urgent", request)).StatusCode);
        var stale = await browser.PostAsync("/api/content/urgent", request with { Revision = 2 });
        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
        Assert.Equal("urgent_stale", (await stale.Content.ReadFromJsonAsync<ErrorResponse>())?.Error);
    }
}
