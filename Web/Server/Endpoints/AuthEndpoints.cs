using System.Security.Claims;
using CinegyBridge.Web.Accounts;
using CinegyBridge.Web.Auth;
using Microsoft.AspNetCore.Antiforgery;

namespace CinegyBridge.Web.Endpoints;

public static class ApiErrors
{
    public static IResult Of(int status, string error, string? message = null) =>
        TypedResults.Json(new ErrorResponse(error, message), statusCode: status);

    public static IResult BridgeUnavailable() => Of(StatusCodes.Status503ServiceUnavailable, "bridge_unavailable");
}

public static class AuthEndpoints
{
    public const string AuthRateLimit = "auth";
    public const string PollRateLimit = "auth-poll";

    public static void MapAuthEndpoints(this IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api").WithTags("Auth");

        api.MapGet("/session", GetSession).AllowAnonymous();
        api.MapPost("/auth/password", PasswordSignIn).AllowAnonymous().RequireRateLimiting(AuthRateLimit)
            .Produces(StatusCodes.Status204NoContent)
            .Produces<ErrorResponse>(StatusCodes.Status401Unauthorized)
            .Produces<ErrorResponse>(StatusCodes.Status423Locked)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        api.MapPost("/auth/telegram", BeginTelegram).AllowAnonymous().RequireRateLimiting(AuthRateLimit)
            .Produces<TelegramSignInResponse>()
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        api.MapPost("/auth/telegram/{flowId}", PollTelegram).AllowAnonymous().RequireRateLimiting(PollRateLimit);
        api.MapPost("/auth/logout", SignOut).RequireAuthorization();
    }

    /// <summary>Also hands out the anti-forgery token every POST needs. It is
    /// bound to the signed-in user, so the client fetches this again after
    /// signing in or out.</summary>
    private static SessionResponse GetSession(HttpContext http, IAntiforgery antiforgery)
    {
        var tokens = antiforgery.GetAndStoreTokens(http);
        return new SessionResponse(ToCurrentUser(http.User), tokens.RequestToken ?? "");
    }

    private static async Task<IResult> PasswordSignIn(
        PasswordSignInRequest request, HttpContext http, AccountStore accounts, WebSignIn signIn, ILoggerFactory loggers)
    {
        var logger = loggers.CreateLogger("CinegyBridge.Web.Auth");
        // One answer for "no such user" and "wrong password", on purpose.
        var invalid = ApiErrors.Of(StatusCodes.Status401Unauthorized, "invalid_credentials");
        if (string.IsNullOrEmpty(request.Username) || string.IsNullOrEmpty(request.Password) ||
            request.Password.Length > PasswordHasher.MaximumLength || request.Username.Length > 64)
        {
            return invalid;
        }
        var username = AccountStore.Normalize(request.Username);
        var result = await accounts.SignInAsync(username, request.Password);
        if (result.Outcome == SignInOutcome.Locked)
        {
            logger.LogWarning("Locked web account {Username} refused from {Address}", username, ClientInfo.Address(http));
            return ApiErrors.Of(StatusCodes.Status423Locked, "locked", result.LockedUntil?.ToString("o"));
        }
        if (result.Outcome != SignInOutcome.Success || result.Account is null)
        {
            logger.LogWarning("Failed web sign-in for {Username} from {Address}", username, ClientInfo.Address(http));
            return invalid;
        }
        var refusal = await signIn.SignInAsync(http, result.Account.UserId, "password", result.Account.Username);
        if (refusal == "bridge_unavailable") return ApiErrors.BridgeUnavailable();
        if (refusal is not null) return ApiErrors.Of(StatusCodes.Status401Unauthorized, "not_authorized");
        logger.LogInformation("Web sign-in by password: {Username} from {Address}", username, ClientInfo.Address(http));
        return TypedResults.NoContent();
    }

    private static async Task<IResult> BeginTelegram(HttpContext http, TelegramSignIn telegram)
    {
        var (start, error) = await telegram.BeginAsync(ClientInfo.Address(http), ClientInfo.Agent(http), http.RequestAborted);
        if (start is null)
        {
            return error == "bridge_unavailable" ? ApiErrors.BridgeUnavailable() : ApiErrors.Of(StatusCodes.Status400BadRequest, error);
        }
        return TypedResults.Ok(new TelegramSignInResponse(start.FlowId, start.Code, start.BotUsername, start.ExpiresAt));
    }

    private static async Task<TelegramPollResponse> PollTelegram(
        string flowId, HttpContext http, TelegramSignIn telegram, WebSignIn signIn, ILoggerFactory loggers)
    {
        var poll = await telegram.PollAsync(flowId, http.RequestAborted);
        if (poll.State != TelegramSignInState.Approved) return new TelegramPollResponse(poll.State.ToString().ToLowerInvariant());

        var refusal = await signIn.SignInAsync(http, poll.UserId, "telegram", "");
        if (refusal is not null) return new TelegramPollResponse(refusal == "bridge_unavailable" ? "unavailable" : "denied");
        loggers.CreateLogger("CinegyBridge.Web.Auth")
            .LogInformation("Web sign-in through Telegram: user {UserId} from {Address}", poll.UserId, ClientInfo.Address(http));
        return new TelegramPollResponse("approved");
    }

    private static async Task<IResult> SignOut(HttpContext http, WebSignIn signIn)
    {
        await signIn.SignOutAsync(http);
        return TypedResults.NoContent();
    }

    internal static CurrentUser? ToCurrentUser(ClaimsPrincipal user)
    {
        if (user.Identity?.IsAuthenticated != true) return null;
        return new CurrentUser(
            user.UserId(),
            user.Identity.Name ?? "",
            user.FindFirstValue(ClaimTypes.Role) ?? "operator",
            user.FindFirstValue(WebClaims.Method) ?? "",
            user.FindFirstValue(WebClaims.WebOnly) == "true");
    }
}
