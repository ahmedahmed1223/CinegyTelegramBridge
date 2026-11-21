using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;
using Microsoft.AspNetCore.Mvc;

namespace CinegyBridge.Web.Endpoints;

public sealed class ShiftHistoryQuery
{
    [FromQuery(Name = "scope")]
    public string? Scope { get; init; }
    [FromQuery(Name = "hours")]
    public int? Hours { get; init; }
    [FromQuery(Name = "day")]
    public string? Day { get; init; }
    [FromQuery(Name = "target")]
    public string? Target { get; init; }
    [FromQuery(Name = "operatorId")]
    public string? OperatorId { get; init; }
    [FromQuery(Name = "kind")]
    public string? Kind { get; init; }
    [FromQuery(Name = "result")]
    public string? Result { get; init; }
    [FromQuery(Name = "page")]
    public int? Page { get; init; }
}

public static class ShiftHistoryEndpoints
{
    public static void MapShiftHistoryEndpoints(this IEndpointRouteBuilder app)
    {
        var history = app.MapGroup("/api/history").WithTags("Shift history").RequireAuthorization();
        history.MapGet("/operation-reference", LookupOperationReference).RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<OperationReferenceLookup>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        history.MapGet("/operations", Operations).Produces<ShiftHistoryPage>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        history.MapGet("/audit", Audit).RequireAuthorization(AccountEndpoints.AdminPolicy).Produces<ShiftHistoryPage>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        history.MapGet("/operations/export", ExportOperations).RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<ShiftHistoryExport>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        history.MapGet("/audit/export", ExportAudit).RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<ShiftHistoryExport>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> LookupOperationReference(string? reference, HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("shift.operation-reference", new { actor = http.User.UserId(), reference }, http.RequestAborted);
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<OperationReferenceLookup>(JsonDefaults.Options));
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "operation_reference_invalid" => ApiErrors.Of(400, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static Task<IResult> Operations([AsParameters] ShiftHistoryQuery filters, HttpContext http, IBridgeChannel bridge) =>
        Send<ShiftHistoryPage>(filters, http, bridge, "operations", "list");

    private static Task<IResult> Audit([AsParameters] ShiftHistoryQuery filters, HttpContext http, IBridgeChannel bridge) =>
        Send<ShiftHistoryPage>(filters, http, bridge, "audit", "list");

    private static Task<IResult> ExportOperations([AsParameters] ShiftHistoryQuery filters, HttpContext http, IBridgeChannel bridge) =>
        Send<ShiftHistoryExport>(filters, http, bridge, "operations", "export");

    private static Task<IResult> ExportAudit([AsParameters] ShiftHistoryQuery filters, HttpContext http, IBridgeChannel bridge) =>
        Send<ShiftHistoryExport>(filters, http, bridge, "audit", "export");

    private static async Task<IResult> Send<T>(ShiftHistoryQuery filters, HttpContext http, IBridgeChannel bridge,
        string view, string action)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("shift.history", new
        {
            actor = http.User.UserId(), action, view, filters.Scope, filters.Hours, filters.Day, filters.Target,
            filters.OperatorId, filters.Kind, filters.Result, filters.Page
        }, http.RequestAborted);
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<T>(JsonDefaults.Options));
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(StatusCodes.Status403Forbidden, reply.Error),
            "history_invalid" => ApiErrors.Of(StatusCodes.Status400BadRequest, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }
}
