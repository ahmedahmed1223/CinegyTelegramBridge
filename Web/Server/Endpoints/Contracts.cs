namespace CinegyBridge.Web.Endpoints;

// The public shape of the API. Web/openapi.json is generated from these at
// build time, and the client's types are generated from that file - so a
// change here that the client has not caught up with fails the gate.

public sealed record ErrorResponse(string Error, string? Message = null);

public sealed record ContentItem(string Title, string State, int? Rows, string? Id, bool? Enabled, Dictionary<string, string>? Values);
public sealed record ContentPage(IReadOnlyList<ContentItem> Items, int Page, int PageCount, int Total, int? Revision, IReadOnlyList<TemplateFieldDto>? Fields);
public sealed record UrgentRowInput(Dictionary<string, string> Values, bool Enabled);
public sealed record UrgentWriteRequest(string Action, int Revision, string? Id = null, UrgentRowInput? Row = null);

public sealed record CurrentUser(long Id, string Name, string Role, string Method, bool WebOnly);

public sealed record SessionResponse(CurrentUser? User, string CsrfToken);

public sealed record PasswordSignInRequest(string Username, string Password);

public sealed record TelegramSignInResponse(string FlowId, string Code, string BotUsername, DateTimeOffset ExpiresAt);

/// <summary>State is pending, approved, denied, expired or unavailable.</summary>
public sealed record TelegramPollResponse(string State);

public sealed record BridgeUserResponse(long Id, string Name, string Role, bool WebOnly, string? Username);

public sealed record WebAccountResponse(
    string Username, long UserId, string DisplayName, bool WebOnly, string Role,
    DateTimeOffset CreatedAt, DateTimeOffset? LastLoginAt, DateTimeOffset? LockedUntil);

public sealed record AccountsResponse(IReadOnlyList<WebAccountResponse> Accounts, IReadOnlyList<BridgeUserResponse> BridgeUsers);

/// <summary>Kind is "telegram" (a password for an existing bot user, by
/// <see cref="UserId"/>) or "webOnly" (a new person with a <see cref="Role"/>).</summary>
public sealed record CreateAccountRequest(string Kind, string Username, string Password, string? DisplayName, long? UserId, string? Role);

public sealed record SetPasswordRequest(string Password);

public sealed record ChangePasswordRequest(string CurrentPassword, string NewPassword);

public sealed record SessionInfoResponse(
    string Id, long UserId, string Name, string Method, string Address, string Agent,
    DateTimeOffset CreatedAt, DateTimeOffset LastSeenAt, bool Current);
