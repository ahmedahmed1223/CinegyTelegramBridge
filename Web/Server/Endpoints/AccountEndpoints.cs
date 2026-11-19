using System.Security.Claims;
using CinegyBridge.Web.Accounts;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

/// <summary>
/// Password accounts, managed by administrators. The rule that protects the
/// bot protects these too: only the owner may touch an account that carries
/// administrator rights - otherwise resetting the owner's password would be
/// a way for an administrator to become the owner.
/// </summary>
public static class AccountEndpoints
{
    public const string AdminPolicy = "admin";

    public static void MapAccountEndpoints(this IEndpointRouteBuilder app)
    {
        var admin = app.MapGroup("/api/accounts").WithTags("Accounts").RequireAuthorization(AdminPolicy);
        admin.MapGet("", List).Produces<AccountsResponse>().Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        admin.MapPost("", Create).Produces<WebAccountResponse>(StatusCodes.Status201Created)
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest).Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status409Conflict).Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        admin.MapDelete("/{username}", Delete).Produces(StatusCodes.Status204NoContent)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden).Produces<ErrorResponse>(StatusCodes.Status404NotFound);
        admin.MapPut("/{username}/password", ResetPassword).Produces(StatusCodes.Status204NoContent)
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest).Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound);

        app.MapPut("/api/me/password", ChangeOwnPassword).WithTags("Accounts").RequireAuthorization()
            .Produces(StatusCodes.Status204NoContent).Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound);
    }

    private static async Task<IResult> List(AccountStore accounts, BridgeIdentity identity, HttpContext http)
    {
        var roster = await identity.RosterAsync(http.RequestAborted);
        if (roster is null) return ApiErrors.BridgeUnavailable();
        var list = await accounts.ListAsync();
        var byUser = list.ToDictionary(a => a.UserId);
        return TypedResults.Ok(new AccountsResponse(
            [.. list.Select(a => ToResponse(a, roster))],
            [.. roster.Select(u => new BridgeUserResponse(u.Id, u.Name, u.Role, u.WebOnly, byUser.GetValueOrDefault(u.Id)?.Username))]));
    }

    private static async Task<IResult> Create(
        CreateAccountRequest request, HttpContext http, AccountStore accounts, BridgeIdentity identity, IBridgeChannel bridge, TimeProvider clock)
    {
        if (!AccountStore.IsValidUsername(request.Username)) return ApiErrors.Of(400, "bad_username");
        if (PasswordHasher.Validate(request.Password) is { } passwordError) return ApiErrors.Of(400, passwordError);
        var username = AccountStore.Normalize(request.Username);
        if (await accounts.FindAsync(username) is not null) return ApiErrors.Of(409, "username_taken");

        var roster = await identity.RosterAsync(http.RequestAborted);
        if (roster is null) return ApiErrors.BridgeUnavailable();
        var actor = http.User.UserId();
        var actorIsOwner = http.User.IsInRole("owner");

        long userId;
        string displayName;
        if (request.Kind == "telegram")
        {
            var target = roster.FirstOrDefault(u => u.Id == request.UserId && !u.WebOnly);
            if (target is null) return ApiErrors.Of(400, "unknown_user");
            if (target.IsAdmin && !actorIsOwner) return ApiErrors.Of(403, "owner_only");
            userId = target.Id;
            displayName = target.Name;
        }
        else if (request.Kind == "webOnly")
        {
            displayName = (request.DisplayName ?? "").Trim();
            if (displayName.Length is 0 or > 48) return ApiErrors.Of(400, "bad_display_name");
            if (request.Role is not ("operator" or "admin")) return ApiErrors.Of(400, "bad_role");
            userId = await accounts.ReserveWebOnlyIdAsync();
            var grant = await bridge.SendAsync("account.grant", new { actor, userId, role = request.Role, name = displayName }, http.RequestAborted);
            if (grant.IsUnavailable) return ApiErrors.BridgeUnavailable();
            if (!grant.Ok) return ApiErrors.Of(grant.Error is "forbidden" or "owner_only" ? 403 : 400, grant.Error);
            identity.Forget(userId);
        }
        else
        {
            return ApiErrors.Of(400, "bad_kind");
        }

        var account = new WebAccount
        {
            Username = username,
            UserId = userId,
            DisplayName = displayName,
            WebOnly = request.Kind == "webOnly",
            Password = PasswordHasher.Hash(request.Password),
            CreatedAt = clock.GetUtcNow(),
            CreatedBy = actor,
        };
        if (!await accounts.AddAsync(account)) return ApiErrors.Of(409, "account_exists");
        var role = request.Kind == "webOnly" ? request.Role! : roster.First(u => u.Id == userId).Role;
        return TypedResults.Created($"/api/accounts/{username}", ToResponse(account, [new BridgeUser(userId, displayName, role, account.WebOnly)]));
    }

    private static async Task<IResult> Delete(
        string username, HttpContext http, AccountStore accounts, BridgeIdentity identity, IBridgeChannel bridge, SessionStore sessions)
    {
        var account = await accounts.FindAsync(username);
        if (account is null) return ApiErrors.Of(404, "not_found");
        if (await RefuseIfProtected(account, http, identity) is { } refusal) return refusal;
        if (account.WebOnly)
        {
            var revoke = await bridge.SendAsync("account.revoke", new { actor = http.User.UserId(), userId = account.UserId }, http.RequestAborted);
            if (revoke.IsUnavailable) return ApiErrors.BridgeUnavailable();
            if (!revoke.Ok) return ApiErrors.Of(403, revoke.Error);
            identity.Forget(account.UserId);
            await sessions.RemoveForUserAsync(account.UserId);
        }
        else
        {
            await sessions.RemoveForUsernameAsync(account.Username);
        }
        await accounts.RemoveAsync(account.Username);
        return TypedResults.NoContent();
    }

    private static async Task<IResult> ResetPassword(
        string username, SetPasswordRequest request, HttpContext http, AccountStore accounts, BridgeIdentity identity, SessionStore sessions)
    {
        if (PasswordHasher.Validate(request.Password) is { } passwordError) return ApiErrors.Of(400, passwordError);
        var account = await accounts.FindAsync(username);
        if (account is null) return ApiErrors.Of(404, "not_found");
        if (await RefuseIfProtected(account, http, identity) is { } refusal) return refusal;
        await accounts.SetPasswordAsync(account.Username, PasswordHasher.Hash(request.Password));
        // Whoever was signed in with the old password is signed out.
        await sessions.RemoveForUsernameAsync(account.Username);
        return TypedResults.NoContent();
    }

    private static async Task<IResult> ChangeOwnPassword(ChangePasswordRequest request, HttpContext http, AccountStore accounts)
    {
        if (PasswordHasher.Validate(request.NewPassword) is { } passwordError) return ApiErrors.Of(400, passwordError);
        var account = (await accounts.ListAsync()).FirstOrDefault(a => a.UserId == http.User.UserId());
        if (account is null) return ApiErrors.Of(404, "no_password_account");
        if (!PasswordHasher.Verify(request.CurrentPassword ?? "", account.Password)) return ApiErrors.Of(400, "wrong_password");
        await accounts.SetPasswordAsync(account.Username, PasswordHasher.Hash(request.NewPassword));
        return TypedResults.NoContent();
    }

    private static async Task<IResult?> RefuseIfProtected(WebAccount account, HttpContext http, BridgeIdentity identity)
    {
        if (http.User.IsInRole("owner")) return null;
        var target = await identity.GetAsync(account.UserId, http.RequestAborted);
        if (target.State == IdentityState.Unavailable) return ApiErrors.BridgeUnavailable();
        return target.User?.IsAdmin == true ? ApiErrors.Of(403, "owner_only") : null;
    }

    private static WebAccountResponse ToResponse(WebAccount account, IReadOnlyList<BridgeUser> roster) => new(
        account.Username, account.UserId, account.DisplayName, account.WebOnly,
        roster.FirstOrDefault(u => u.Id == account.UserId)?.Role ?? "none",
        account.CreatedAt, account.LastLoginAt, account.LockedUntil);
}
