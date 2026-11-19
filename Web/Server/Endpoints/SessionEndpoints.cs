using CinegyBridge.Web.Auth;

namespace CinegyBridge.Web.Endpoints;

/// <summary>Signed-in browsers. Everyone sees and ends their own; an
/// administrator sees and ends everyone's.</summary>
public static class SessionEndpoints
{
    public static void MapSessionEndpoints(this IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api/sessions").WithTags("Sessions").RequireAuthorization();
        api.MapGet("", List).Produces<IReadOnlyList<SessionInfoResponse>>();
        api.MapDelete("/{id}", End).Produces(StatusCodes.Status204NoContent).Produces<ErrorResponse>(StatusCodes.Status404NotFound);
    }

    private static async Task<IResult> List(HttpContext http, SessionStore sessions, BridgeIdentity identity)
    {
        var all = await sessions.ListAsync();
        var me = http.User.UserId();
        var visible = http.User.IsAdmin() ? all : [.. all.Where(s => s.UserId == me)];
        var roster = await identity.RosterAsync(http.RequestAborted) ?? [];
        var names = roster.ToDictionary(u => u.Id, u => u.Name);
        var current = http.User.SessionIdOf();
        return TypedResults.Ok<IReadOnlyList<SessionInfoResponse>>([.. visible.Select(s => new SessionInfoResponse(
            s.Id, s.UserId, names.GetValueOrDefault(s.UserId, s.Username), s.Method, s.Address, s.Agent,
            s.CreatedAt, s.LastSeenAt, s.Id == current))]);
    }

    private static async Task<IResult> End(string id, HttpContext http, SessionStore sessions)
    {
        var session = (await sessions.ListAsync()).FirstOrDefault(s => s.Id == id);
        if (session is null || (!http.User.IsAdmin() && session.UserId != http.User.UserId())) return ApiErrors.Of(404, "not_found");
        await sessions.RemoveAsync(id);
        return TypedResults.NoContent();
    }
}
