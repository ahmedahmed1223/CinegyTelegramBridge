using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

internal static class ProgrammeBoardEndpoints
{
    public static void Map(IEndpointRouteBuilder app)
    {
        var boards = app.MapGroup("/api/content/boards").WithTags("Content").RequireAuthorization();
        boards.MapGet("", List)
            .Produces<ProgrammeBoardList>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404).Produces<ErrorResponse>(503);
        boards.MapGet("/templates", Templates)
            .Produces<ProgrammeBoardTemplates>()
            .Produces<ErrorResponse>(403).Produces<ErrorResponse>(404).Produces<ErrorResponse>(503);
        boards.MapGet("/editor", (string id, int? page, string? search, string? order, IBridgeChannel bridge, HttpContext http) =>
                SendEditor(new("read", id, Page: page), bridge, http, search, order))
            .Produces<ProgrammeBoardEditor>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404).Produces<ErrorResponse>(503);
        boards.MapPost("/editor", Edit)
            .Produces<ProgrammeBoardEditor>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        boards.MapPost("/paste", Paste)
            .Produces<ProgrammeBoardPasteResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        boards.MapPost("/air", Air)
            .Produces<ProgrammeBoardAirResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        boards.MapDelete("/{id}", Delete)
            .Produces(StatusCodes.Status204NoContent)
            .Produces<ErrorResponse>(403).Produces<ErrorResponse>(404).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> List(int? page, string? search, string? order, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("board.list", new { actor = http.User.UserId(), page, search, order }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        http.Response.Headers.CacheControl = "no-store";
        return TypedResults.Ok(reply.Data.Deserialize<ProgrammeBoardList>(JsonDefaults.Options));
    }

    private static Task<IResult> Edit(ProgrammeBoardEditRequest request, IBridgeChannel bridge, HttpContext http) =>
        SendEditor(request, bridge, http, null, null);

    private static async Task<IResult> SendEditor(ProgrammeBoardEditRequest request, IBridgeChannel bridge, HttpContext http,
        string? search, string? order)
    {
        if (string.Equals(request.Action, "options", StringComparison.OrdinalIgnoreCase)) return Error("board_invalid");
        var reply = await bridge.SendAsync("board.edit", new
        {
            actor = http.User.UserId(), request.Action, request.Id, request.Revision, request.Page, request.RowId, request.Values,
            request.Name, request.Template, request.Role, search, order
        }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        http.Response.Headers.CacheControl = "no-store";
        return TypedResults.Ok(reply.Data.Deserialize<ProgrammeBoardEditor>(JsonDefaults.Options));
    }

    private static async Task<IResult> Templates(IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("board.edit", new { actor = http.User.UserId(), action = "options" }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        http.Response.Headers.CacheControl = "no-store";
        return TypedResults.Ok(reply.Data.Deserialize<ProgrammeBoardTemplates>(JsonDefaults.Options));
    }

    private static async Task<IResult> Paste(ProgrammeBoardPasteRequest request, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("board.paste", new
        {
            actor = http.User.UserId(), request.Action, request.Id, request.Revision, request.Format, request.Text, request.Review
        }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        http.Response.Headers.CacheControl = "no-store";
        return TypedResults.Ok(reply.Data.Deserialize<ProgrammeBoardPasteResult>(JsonDefaults.Options));
    }

    private static async Task<IResult> Delete(string id, int revision, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("board.delete", new { actor = http.User.UserId(), id, revision }, http.RequestAborted);
        return reply.Ok ? TypedResults.NoContent() : Error(reply.Error);
    }

    private static async Task<IResult> Air(ProgrammeBoardAirRequest request, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("board.air", new
        {
            actor = http.User.UserId(), request.Action, request.Id, request.Revision, request.RowId, request.Review, request.Values
        }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        http.Response.Headers.CacheControl = "no-store";
        return TypedResults.Ok(reply.Data.Deserialize<ProgrammeBoardAirResult>(JsonDefaults.Options));
    }

    private static IResult Error(string code) => code switch
    {
        "forbidden" => ApiErrors.Of(403, code),
        "not_found" or "content_disabled" or "board_missing_item" => ApiErrors.Of(404, code),
        "board_invalid" or "board_unknown_field" or "board_no_fields" or "board_too_long" or "board_empty" or "board_full"
            or "board_invalid_text" or "board_invalid_template" or "board_invalid_name" or "board_name_too_long" or "board_invalid_role"
            or "board_paste_invalid"
            => ApiErrors.Of(400, code),
        "board_stale" or "board_at_edge" or "board_capacity" or "board_air_refused" or "board_air_multiple" or "board_air_conflict" => ApiErrors.Of(409, code),
        "board_save_failed" or "board_delete_failed" or "board_air_unverified" => ApiErrors.Of(503, code),
        _ => ApiErrors.BridgeUnavailable(),
    };
}
