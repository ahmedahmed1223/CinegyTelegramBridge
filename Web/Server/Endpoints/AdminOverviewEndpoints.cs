using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class AdminOverviewEndpoints
{
    public static void MapAdminOverviewEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/admin/overview", Read)
            .WithTags("Administration").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<AdminOverview>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);

        var restart = app.MapGroup("/api/admin/restart").WithTags("Administration")
            .RequireAuthorization(AccountEndpoints.AdminPolicy);
        restart.MapPost("/review", ReviewRestart)
            .Produces<ManagedRestartResult>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        restart.MapPost("/confirm", ConfirmRestart)
            .Produces<ManagedRestartResult>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        restart.MapPost("/cancel", CancelRestart)
            .Produces<ManagedRestartResult>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        restart.MapPost("/accept", AcceptRestart)
            .Produces<ManagedRestartResult>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        restart.MapGet("/{id}/status", StatusRestart)
            .Produces<ManagedRestartResult>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);

        app.MapGet("/api/admin/restart/readiness", ReadRestartReadiness)
            .WithTags("Administration").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<RestartReadiness>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);

        app.MapGet("/api/admin/readiness", ReadReadiness)
            .WithTags("Administration").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<ShiftReadinessReport>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);

        app.MapGet("/api/admin/self-test/readiness", ReadSelfTestReadiness)
            .WithTags("Administration").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<SelfTestReadinessReport>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status429TooManyRequests)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);

        app.MapGet("/api/admin/usage-summary", ReadUsageSummary)
            .WithTags("Administration").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<AdminUsageSummaryReport>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);

        app.MapGet("/api/admin/notifications/coverage", ReadNotificationCoverage)
            .WithTags("Administration").RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<AdminNotificationCoverage>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
    }

    private static Task<IResult> ReadSelfTestReadiness(HttpContext http, IBridgeChannel bridge) =>
        ReadReport<SelfTestReadinessReport>(http, bridge, "admin.self-test.readiness");

    private static Task<IResult> ReadUsageSummary(HttpContext http, IBridgeChannel bridge) =>
        ReadReport<AdminUsageSummaryReport>(http, bridge, "admin.usage-summary");

    private static Task<IResult> ReadNotificationCoverage(HttpContext http, IBridgeChannel bridge) =>
        ReadReport<AdminNotificationCoverage>(http, bridge, "admin.notifications.coverage");

    private static Task<IResult> ReviewRestart(HttpContext http, IBridgeChannel bridge) =>
        SendManagedRestart(http, bridge, "admin.restart.review", null, null);

    private static Task<IResult> ConfirmRestart(ManagedRestartReviewCommand command, HttpContext http, IBridgeChannel bridge) =>
        SendManagedRestart(http, bridge, "admin.restart.confirm", command.Id, null);

    private static Task<IResult> CancelRestart(ManagedRestartReviewCommand command, HttpContext http, IBridgeChannel bridge) =>
        SendManagedRestart(http, bridge, "admin.restart.cancel", command.Id, null);

    private static Task<IResult> AcceptRestart(ManagedRestartReceiptCommand command, HttpContext http, IBridgeChannel bridge) =>
        SendManagedRestart(http, bridge, "admin.restart.accept", command.Id, command.Receipt);

    private static Task<IResult> StatusRestart(string id, HttpContext http, IBridgeChannel bridge) =>
        SendManagedRestart(http, bridge, "admin.restart.status", id, null);

    private static async Task<IResult> SendManagedRestart(HttpContext http, IBridgeChannel bridge, string operation,
        string? id, string? receipt)
    {
        http.Response.Headers.CacheControl = "no-store";
        var sid = http.User.SessionIdOf();
        if (sid.Length == 0) return ApiErrors.Of(403, "forbidden");
        if ((operation != "admin.restart.review" && (id is not { Length: 32 } || !id.All(Uri.IsHexDigit))) ||
            (operation == "admin.restart.accept" && (receipt is not { Length: 32 } || !receipt.All(Uri.IsHexDigit))))
            return ApiErrors.Of(400, "restart_invalid");

        var session = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sid)));
        var reply = await bridge.SendAsync(operation, new { actor = http.User.UserId(), session, id, receipt }, http.RequestAborted);
        if (!reply.Ok)
            return reply.Error switch
            {
                "forbidden" or "restart_forbidden" => ApiErrors.Of(403, "forbidden"),
                "restart_invalid" => ApiErrors.Of(400, reply.Error),
                "restart_busy" or "restart_stale" or "restart_relay_active" => ApiErrors.Of(409, reply.Error),
                "restart_unavailable" => ApiErrors.Of(503, reply.Error),
                _ => ApiErrors.BridgeUnavailable()
            };
        try
        {
            var result = reply.Data.Deserialize<ManagedRestartResult>(JsonDefaults.Options);
            return result is not null ? TypedResults.Ok(result) : ApiErrors.BridgeUnavailable();
        }
        catch (JsonException) { return ApiErrors.BridgeUnavailable(); }
    }

    private static Task<IResult> ReadRestartReadiness(HttpContext http, IBridgeChannel bridge) =>
        ReadReport<RestartReadiness>(http, bridge, "admin.restart.readiness");

    private static Task<IResult> ReadReadiness(HttpContext http, IBridgeChannel bridge) =>
        ReadReport<ShiftReadinessReport>(http, bridge, "admin.readiness");

    private static Task<IResult> Read(HttpContext http, IBridgeChannel bridge) =>
        ReadReport<AdminOverview>(http, bridge, "admin.overview");

    private static async Task<IResult> ReadReport<T>(HttpContext http, IBridgeChannel bridge, string operation) where T : class
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync(operation, new { actor = http.User.UserId() }, http.RequestAborted);
        if (!reply.Ok)
            return reply.Error switch
            {
                "forbidden" => ApiErrors.Of(StatusCodes.Status403Forbidden, reply.Error),
                "layer_comparison_busy" => ApiErrors.Of(StatusCodes.Status429TooManyRequests, reply.Error),
                _ => ApiErrors.BridgeUnavailable(),
            };

        try
        {
            var report = reply.Data.Deserialize<T>(JsonDefaults.Options);
            return report is null ? ApiErrors.BridgeUnavailable() : TypedResults.Ok(report);
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }
}
