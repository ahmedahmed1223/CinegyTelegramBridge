using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class RuntimeFileDiagnosticsEndpoints
{
    public static void MapRuntimeFileDiagnosticsEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/admin/diagnostics/runtime-files", Read)
            .WithTags("Administration")
            .RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<RuntimeFileDiagnostics>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
    }

    private static async Task<IResult> Read(HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("admin.diagnostics.runtime-files", new { actor = http.User.UserId() }, http.RequestAborted);
        if (!reply.Ok)
            return reply.Error == "forbidden" ? ApiErrors.Of(StatusCodes.Status403Forbidden, reply.Error) : ApiErrors.BridgeUnavailable();

        try
        {
            var result = reply.Data.Deserialize<RuntimeFileDiagnostics>(JsonDefaults.Options);
            return result is null ? ApiErrors.BridgeUnavailable() : TypedResults.Ok(result);
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }
}
