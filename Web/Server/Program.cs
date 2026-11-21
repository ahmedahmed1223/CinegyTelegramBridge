using System.Threading.RateLimiting;
using CinegyBridge.Web;
using CinegyBridge.Web.Accounts;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;
using CinegyBridge.Web.Endpoints;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.HttpOverrides;

var builder = WebApplication.CreateBuilder(args);
var options = WebOptions.FromConfiguration(builder.Configuration, builder.Environment);

// Loopback only, always. The outside world reaches this through cloudflared
// running on the same machine; nothing else should be able to.
builder.WebHost.ConfigureKestrel(kestrel => kestrel.ListenLocalhost(options.Port));
builder.Configuration["AllowedHosts"] = string.Join(';', options.AllowedHosts());

builder.Services.AddSingleton(options);
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<IBridgeChannel, PipeBridgeChannel>();
builder.Services.AddSingleton<BridgeIdentity>();
builder.Services.AddSingleton<AccountStore>();
builder.Services.AddSingleton<SessionStore>();
builder.Services.AddSingleton<TelegramSignIn>();
builder.Services.AddSingleton<WebSignIn>();
builder.Services.AddSingleton<SessionCookieEvents>();
builder.Services.AddSingleton<StatusFeed>();
builder.Services.AddHostedService(services => services.GetRequiredService<StatusFeed>());

// Cookie and anti-forgery keys survive a restart, encrypted to this Windows
// account like the bridge's own secrets.
builder.Services.AddDataProtection()
    .SetApplicationName("CinegyBridge.Web")
    .PersistKeysToFileSystem(new DirectoryInfo(Path.Combine(options.StateDirectory, "keys")))
    .ProtectKeysWithDpapi();

builder.Services.Configure<ForwardedHeadersOptions>(forwarded =>
{
    // cloudflared is the only proxy, and it runs on loopback - which is the
    // default trusted proxy list. Its X-Forwarded-Proto makes the cookie
    // Secure on the tunnel; its X-Forwarded-For names the real browser.
    forwarded.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    forwarded.ForwardLimit = 1;
});

builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(cookie =>
    {
        cookie.Cookie.Name = "cgb.session";
        cookie.Cookie.HttpOnly = true;
        cookie.Cookie.SameSite = SameSiteMode.Strict;
        cookie.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
        cookie.ExpireTimeSpan = SessionStore.IdleLimit;
        cookie.SlidingExpiration = true;
        cookie.EventsType = typeof(SessionCookieEvents);
    });
builder.Services.AddAuthorizationBuilder()
    .AddPolicy(AccountEndpoints.AdminPolicy, policy => policy.RequireRole("admin", "owner"));
builder.Services.AddAntiforgery(antiforgery =>
{
    antiforgery.HeaderName = "X-XSRF-TOKEN";
    antiforgery.Cookie.Name = "cgb.xsrf";
    antiforgery.Cookie.SameSite = SameSiteMode.Strict;
    antiforgery.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
});

builder.Services.AddRateLimiter(limiter =>
{
    limiter.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    limiter.AddPolicy(AuthEndpoints.AuthRateLimit, http => RateLimitPartition.GetFixedWindowLimiter(
        ClientInfo.Address(http), _ => new FixedWindowRateLimiterOptions { PermitLimit = 10, Window = TimeSpan.FromMinutes(1) }));
    // The Telegram sign-in page asks every two seconds for five minutes.
    limiter.AddPolicy(AuthEndpoints.PollRateLimit, http => RateLimitPartition.GetFixedWindowLimiter(
        ClientInfo.Address(http), _ => new FixedWindowRateLimiterOptions { PermitLimit = 60, Window = TimeSpan.FromMinutes(1) }));
});

builder.Services.AddOpenApi();

var app = builder.Build();

app.UseForwardedHeaders();
app.Use(async (http, next) =>
{
    var headers = http.Response.Headers;
    headers["X-Content-Type-Options"] = "nosniff";
    headers["X-Frame-Options"] = "DENY";
    headers["Referrer-Policy"] = "no-referrer";
    // Mantine sets inline style attributes, hence 'unsafe-inline' for styles
    // only. No inline or remote script, ever.
    var mediaOrigin = options.PlaybackOrigin.Length > 0 ? $" {options.PlaybackOrigin}" : "";
    headers["Content-Security-Policy"] =
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; " +
        $"font-src 'self'; connect-src 'self'{mediaOrigin}; media-src 'self' blob:{mediaOrigin}; " +
        "frame-ancestors 'none'; base-uri 'none'; form-action 'self'";
    await next();
});
app.UseDefaultFiles();
app.UseStaticFiles();
app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();

// Every state-changing API call carries the token GET /api/session issued.
app.Use(async (http, next) =>
{
    var method = http.Request.Method;
    var changesState = HttpMethods.IsPost(method) || HttpMethods.IsPut(method) || HttpMethods.IsDelete(method) || HttpMethods.IsPatch(method);
    if (changesState && http.Request.Path.StartsWithSegments("/api"))
    {
        var antiforgery = http.RequestServices.GetRequiredService<IAntiforgery>();
        if (!await antiforgery.IsRequestValidAsync(http))
        {
            await ApiErrors.Of(StatusCodes.Status400BadRequest, "csrf").ExecuteAsync(http);
            return;
        }
    }
    await next();
});

app.MapOpenApi("/api/openapi.json");
app.MapAuthEndpoints();
app.MapStatusEndpoints();
app.MapAccountEndpoints();
app.MapSessionEndpoints();
app.MapAirEndpoints();
app.MapNewsroomWorkflowEndpoints();
app.MapAdminOverviewEndpoints();
app.MapAdminSettingsEndpoints();
app.MapAirRollbackEndpoints();
app.MapAirTextEndpoints();
app.MapShiftHistoryEndpoints();
app.MapShiftNoticeEndpoints();
app.MapTelegramRosterEndpoints();
app.MapTelegramUnblockEndpoints();
app.MapAccessHistoryEndpoints();
app.MapTelegramSuspensionEndpoints();
app.MapTelegramAliasEndpoints();
app.MapTelegramOperatorActivityEndpoints();
app.MapTelegramDeliveryQuarantineEndpoints();
app.MapAnnouncementEndpoints();
app.MapRuntimeFileDiagnosticsEndpoints();
app.MapScheduleExecutionEndpoints();
app.MapTemplateSceneReplacementEndpoints();
app.MapWorkSummaryEndpoints();
app.MapBulletinReportEndpoints();
app.MapTickerReportEndpoints();
app.MapTemplateReportEndpoints();
app.MapHandoverReportEndpoints();
app.MapBulletinManagementEndpoints();
app.MapBulletinAfterUrgentEndpoints();
app.MapAirEmergencyEndpoints();
app.MapAirTimerEndpoints();
app.MapAirLayerRemovalEndpoints();
app.MapTemplateBackupEndpoints();
app.MapTemplateIssueEndpoints();
app.MapContentEndpoints();
// Client-side routes: any non-API path is the app.
app.MapFallbackToFile("index.html");

app.Logger.LogInformation("Cinegy bridge web on http://localhost:{Port} for {Root}", options.Port, options.BridgeRoot);
app.Run();

public partial class Program;
