using System.Net.Http.Json;
using CinegyBridge.Web.Accounts;
using CinegyBridge.Web.Bridge;
using CinegyBridge.Web.Endpoints;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;

namespace CinegyBridge.Web.Tests;

/// <summary>The real server, on a throwaway bridge folder, with the fake bridge.</summary>
public sealed class WebApp : WebApplicationFactory<Program>
{
    public const long Owner = 11;
    public const long Admin = 22;
    public const long Operator = 33;

    public FakeBridge Bridge { get; } = new();
    public string Root { get; } = Directory.CreateTempSubdirectory("cgb-web-test-").FullName;

    public WebApp()
    {
        File.WriteAllText(Path.Combine(Root, "TelegramBridge.ps1"), "# test stand-in");
        Bridge.Users[Owner] = ("Owner", "owner");
        Bridge.Users[Admin] = ("Admin", "admin");
        Bridge.Users[Operator] = ("Operator", "operator");
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseSetting("BridgeRoot", Root);
        builder.ConfigureTestServices(services => services.AddSingleton<IBridgeChannel>(Bridge));
    }

    public AccountStore Accounts => Services.GetRequiredService<AccountStore>();

    public async Task AddPasswordAccountAsync(string username, long userId, string password = "correct horse battery")
    {
        await Accounts.AddAsync(new WebAccount
        {
            Username = username,
            UserId = userId,
            DisplayName = username,
            Password = PasswordHasher.Hash(password),
        });
    }

    /// <summary>A browser: keeps cookies, sends the anti-forgery header.</summary>
    public async Task<Browser> BrowserAsync()
    {
        var client = CreateClient(new WebApplicationFactoryClientOptions { HandleCookies = true, BaseAddress = new Uri("http://localhost") });
        var browser = new Browser(client);
        await browser.RefreshSessionAsync();
        return browser;
    }

    public async Task<Browser> SignedInAsync(string username, long userId)
    {
        await AddPasswordAccountAsync(username, userId);
        var browser = await BrowserAsync();
        var response = await browser.PostAsync("/api/auth/password", new PasswordSignInRequest(username, "correct horse battery"));
        response.EnsureSuccessStatusCode();
        await browser.RefreshSessionAsync();
        return browser;
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        try { Directory.Delete(Root, recursive: true); } catch (IOException) { /* key files can lag */ }
    }
}

public sealed class Browser(HttpClient client)
{
    public HttpClient Client => client;
    public SessionResponse? Session { get; private set; }

    public async Task RefreshSessionAsync()
    {
        Session = await client.GetFromJsonAsync<SessionResponse>("/api/session");
        client.DefaultRequestHeaders.Remove("X-XSRF-TOKEN");
        client.DefaultRequestHeaders.Add("X-XSRF-TOKEN", Session!.CsrfToken);
    }

    public Task<HttpResponseMessage> PostAsync<T>(string path, T body) => client.PostAsJsonAsync(path, body);
    public Task<HttpResponseMessage> PutAsync<T>(string path, T body) => client.PutAsJsonAsync(path, body);
}
