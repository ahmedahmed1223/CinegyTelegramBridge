using System.Globalization;
using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;

namespace CinegyBridge.Web.Auth;

public static class WebClaims
{
    public const string SessionId = "sid";
    public const string Method = "method";
    public const string WebOnly = "web_only";

    public static long UserId(this ClaimsPrincipal principal) =>
        long.Parse(principal.FindFirstValue(ClaimTypes.NameIdentifier) ?? "0", CultureInfo.InvariantCulture);

    public static string SessionIdOf(this ClaimsPrincipal principal) => principal.FindFirstValue(SessionId) ?? "";

    public static bool IsAdmin(this ClaimsPrincipal principal) =>
        principal.IsInRole("admin") || principal.IsInRole("owner");
}

/// <summary>Turns a proven identity into a session and its cookie. Both
/// sign-in methods end here, so both get the same checks.</summary>
public sealed class WebSignIn(SessionStore sessions, BridgeIdentity identity)
{
    /// <summary>Null on success, else the reason the bridge refused.</summary>
    public async Task<string?> SignInAsync(HttpContext http, long userId, string method, string username)
    {
        identity.Forget(userId);
        var who = await identity.GetAsync(userId, http.RequestAborted);
        if (who.State == IdentityState.Unavailable) return "bridge_unavailable";
        if (who.State != IdentityState.Known || who.User is null) return "not_authorized";

        var session = await sessions.CreateAsync(userId, method, username, ClientInfo.Address(http), ClientInfo.Agent(http));
        await http.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, Principal(who.User, session.Id, method));
        return null;
    }

    public async Task SignOutAsync(HttpContext http)
    {
        var sid = http.User.SessionIdOf();
        if (sid.Length > 0) await sessions.RemoveAsync(sid);
        await http.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
    }

    public static ClaimsPrincipal Principal(BridgeUser user, string sessionId, string method)
    {
        var claims = new List<Claim>
        {
            new(ClaimTypes.NameIdentifier, user.Id.ToString(CultureInfo.InvariantCulture)),
            new(ClaimTypes.Name, user.Name),
            new(ClaimTypes.Role, user.Role),
            new(WebClaims.SessionId, sessionId),
            new(WebClaims.Method, method),
            new(WebClaims.WebOnly, user.WebOnly ? "true" : "false"),
        };
        return new ClaimsPrincipal(new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme));
    }
}

/// <summary>
/// Every request re-checks the session record and the bridge's view of the
/// person. Losing access in the bot ends the browser session too; a changed
/// role or name is picked up without signing out.
/// </summary>
public sealed class SessionCookieEvents(SessionStore sessions, BridgeIdentity identity) : CookieAuthenticationEvents
{
    public override async Task ValidatePrincipal(CookieValidatePrincipalContext context)
    {
        var principal = context.Principal;
        var session = principal is null ? null : await sessions.TouchAsync(principal.SessionIdOf());
        if (principal is null || session is null)
        {
            context.RejectPrincipal();
            return;
        }
        var who = await identity.GetAsync(session.UserId, context.HttpContext.RequestAborted);
        if (who.State == IdentityState.NotAuthorized)
        {
            await sessions.RemoveAsync(session.Id);
            context.RejectPrincipal();
            return;
        }
        // Unavailable: keep the last known identity. The bridge re-checks
        // every action itself, so nothing is granted by keeping it.
        if (who.User is { } user &&
            (!principal.IsInRole(user.Role) || principal.Identity?.Name != user.Name))
        {
            context.ReplacePrincipal(WebSignIn.Principal(user, session.Id, session.Method));
            context.ShouldRenew = true;
        }
    }

    public override Task RedirectToLogin(RedirectContext<CookieAuthenticationOptions> context)
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        return Task.CompletedTask;
    }

    public override Task RedirectToAccessDenied(RedirectContext<CookieAuthenticationOptions> context)
    {
        context.Response.StatusCode = StatusCodes.Status403Forbidden;
        return Task.CompletedTask;
    }
}

public static class ClientInfo
{
    /// <summary>After the forwarded-headers middleware: the browser's address
    /// as Cloudflare saw it, or the local one.</summary>
    public static string Address(HttpContext http) => http.Connection.RemoteIpAddress?.ToString() ?? "";

    public static string Agent(HttpContext http)
    {
        var agent = http.Request.Headers.UserAgent.ToString();
        return agent.Length <= 160 ? agent : agent[..160];
    }
}
