using System.Net;
using System.Net.Http.Json;
using CinegyBridge.Web.Endpoints;
using Microsoft.Extensions.DependencyInjection;

namespace CinegyBridge.Web.Tests;

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
}
