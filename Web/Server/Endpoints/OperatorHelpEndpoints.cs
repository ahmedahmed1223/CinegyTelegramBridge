using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class OperatorHelpEndpoints
{
    public static void MapOperatorHelpEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/help/operator", GetOperatorHelp).WithTags("Operator help").RequireAuthorization()
            .Produces<OperatorHelp>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> GetOperatorHelp(HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("help.operator", new { actor = http.User.UserId() }, http.RequestAborted);
        if (reply.Ok && reply.Data.Deserialize<OperatorHelp>(JsonDefaults.Options) is { } help)
            return TypedResults.Ok(help);
        return reply.Error == "forbidden" ? ApiErrors.Of(StatusCodes.Status403Forbidden, reply.Error) : ApiErrors.BridgeUnavailable();
    }
}
