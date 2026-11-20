using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class ContentEndpoints
{
    public static void MapContentEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/content/{view}", List)
            .WithTags("Content")
            .RequireAuthorization()
            .Produces<ContentPage>()
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        app.MapPost("/api/content/urgent", WriteUrgent)
            .WithTags("Content")
            .RequireAuthorization()
            .Produces(StatusCodes.Status204NoContent)
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status409Conflict)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        var playback = app.MapGroup("/api/content/urgent/playback").WithTags("Content").RequireAuthorization();
        playback.MapGet("", (IBridgeChannel bridge, HttpContext http) => UrgentPlayback(new("status"), bridge, http))
            .Produces<UrgentPlaybackResponse>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        playback.MapPost("", UrgentPlayback)
            .Produces<UrgentPlaybackResponse>()
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status409Conflict)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        var manual = app.MapGroup("/api/content/urgent/manual").WithTags("Content").RequireAuthorization();
        manual.MapGet("", (IBridgeChannel bridge, HttpContext http) => UrgentManual(new("status"), bridge, http))
            .Produces<UrgentManualResponse>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        manual.MapPost("", UrgentManual)
            .Produces<UrgentManualResponse>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(404).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        var timing = app.MapGroup("/api/content/urgent/timing").WithTags("Content").RequireAuthorization();
        timing.MapGet("", (IBridgeChannel bridge, HttpContext http) => UrgentTiming(new("status"), bridge, http))
            .Produces<UrgentTimingState>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(404).Produces<ErrorResponse>(503);
        timing.MapPost("", UrgentTiming)
            .Produces<UrgentTimingState>().Produces<ErrorResponse>(400).Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(404).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        var ticker = app.MapGroup("/api/content/ticker/draft").WithTags("Content").RequireAuthorization();
        ticker.MapGet("", (int? pausedPage, IBridgeChannel bridge, HttpContext http) =>
                TickerEditor(new("status", PausedPage: pausedPage), bridge, http))
            .Produces<TickerEditorState>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        ticker.MapPost("", TickerEditor)
            .Produces<TickerEditorState>()
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status409Conflict)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        TickerTxtEndpoints.Map(ticker);
        var tickerSets = app.MapGroup("/api/content/ticker/sets").WithTags("Content").RequireAuthorization();
        tickerSets.MapGet("", (IBridgeChannel bridge, HttpContext http) => TickerSets(new("status"), bridge, http))
            .Produces<TickerSetsState>()
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(503);
        tickerSets.MapPost("", TickerSets)
            .Produces<TickerSetsState>()
            .Produces<ErrorResponse>(400)
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409)
            .Produces<ErrorResponse>(503);
        var tickerBackups = app.MapGroup("/api/content/ticker/backups").WithTags("Content").RequireAuthorization();
        tickerBackups.MapGet("", (int? page, IBridgeChannel bridge, HttpContext http) => TickerBackups(new("list", Page: page), bridge, http))
            .Produces<TickerBackupResponse>()
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(503);
        tickerBackups.MapPost("", TickerBackups)
            .Produces<TickerBackupResponse>()
            .Produces(204)
            .Produces<ErrorResponse>(400)
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409)
            .Produces<ErrorResponse>(503);
        app.MapPost("/api/content/ticker/sheet", TickerSheet)
            .WithTags("Content")
            .RequireAuthorization()
            .Produces<TickerSheetPreview>()
            .Produces(204)
            .Produces<ErrorResponse>(400)
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409)
            .Produces<ErrorResponse>(503);
        var bulletin = app.MapGroup("/api/content/bulletins").WithTags("Content").RequireAuthorization();
        bulletin.MapGet("/editor", (string id, int? page, IBridgeChannel bridge, HttpContext http) =>
                EditBulletin(new("read", Id: id, Page: page), bridge, http))
            .Produces<BulletinEditor>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        bulletin.MapPost("/editor", EditBulletin)
            .Produces<BulletinEditor>()
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status409Conflict)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        bulletin.MapGet("/designs", GetBulletinDesigns)
            .Produces<BulletinDesignOptions>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        bulletin.MapPost("/paste", PasteBulletin)
            .Produces<BulletinPasteResult>()
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status409Conflict)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
    }

    private static async Task<IResult> List(string view, int? page, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("content.list", new { actor = http.User.UserId(), view, page = page ?? 0 }, http.RequestAborted);
        if (reply.Ok)
        {
            http.Response.Headers.CacheControl = "no-store";
            return TypedResults.Ok(reply.Data.Deserialize<ContentPage>(JsonDefaults.Options));
        }

        return reply.Error switch
        {
            "bad_view" => ApiErrors.Of(400, reply.Error),
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "content_disabled" => ApiErrors.Of(404, reply.Error),
            "content_unreadable" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static async Task<IResult> WriteUrgent(UrgentWriteRequest request, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("urgent.write", new
        {
            actor = http.User.UserId(), request.Action, request.Revision, request.Id, request.Row, request.Timing
        }, http.RequestAborted);
        if (reply.Ok) return TypedResults.NoContent();
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "not_found" or "content_disabled" => ApiErrors.Of(404, reply.Error),
            "urgent_stale" => ApiErrors.Of(409, reply.Error),
            "urgent_invalid" => ApiErrors.Of(400, reply.Error),
            "refused" => ApiErrors.Of(400, reply.Error, reply.Data.ValueKind == JsonValueKind.String ? reply.Data.GetString() : null),
            "urgent_save_failed" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static async Task<IResult> EditBulletin(BulletinEditRequest request, IBridgeChannel bridge, HttpContext http)
    {
        if (request.Action is "designs") return ApiErrors.Of(400, "bulletin_invalid");
        var reply = await bridge.SendAsync("bulletin.edit", new
        {
            actor = http.User.UserId(), request.Action, request.Id, request.Revision, request.Page,
            request.RowId, request.Name, request.Design, request.Values, request.Timing
        }, http.RequestAborted);
        if (!reply.Ok) return BulletinError(reply);
        http.Response.Headers.CacheControl = "no-store";
        return TypedResults.Ok(reply.Data.Deserialize<BulletinEditor>(JsonDefaults.Options));
    }

    private static async Task<IResult> GetBulletinDesigns(IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("bulletin.edit", new { actor = http.User.UserId(), action = "designs" }, http.RequestAborted);
        if (!reply.Ok) return BulletinError(reply);
        http.Response.Headers.CacheControl = "no-store";
        return TypedResults.Ok(reply.Data.Deserialize<BulletinDesignOptions>(JsonDefaults.Options));
    }

    private static async Task<IResult> PasteBulletin(BulletinPasteRequest request, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("bulletin.paste", new
        {
            actor = http.User.UserId(), request.Action, request.Id, request.Revision, request.Format, request.Text, request.Review
        }, http.RequestAborted);
        if (!reply.Ok) return BulletinError(reply);
        http.Response.Headers.CacheControl = "no-store";
        return TypedResults.Ok(reply.Data.Deserialize<BulletinPasteResult>(JsonDefaults.Options));
    }

    private static IResult BulletinError(BridgeReply reply) => reply.Error switch
    {
        "forbidden" => ApiErrors.Of(403, reply.Error),
        "not_found" or "content_disabled" => ApiErrors.Of(404, reply.Error),
        "bulletin_invalid" or "bulletin_paste_invalid" => ApiErrors.Of(400, reply.Error),
        "bulletin_refused" => ApiErrors.Of(400, reply.Error, reply.Data.ValueKind == JsonValueKind.String ? reply.Data.GetString() : null),
        "bulletin_stale" => ApiErrors.Of(409, reply.Error),
        "bulletin_save_failed" or "bridge_outcome_unknown" => ApiErrors.Of(503, reply.Error),
        _ => ApiErrors.BridgeUnavailable()
    };

    private static async Task<IResult> TickerSheet(TickerSheetRequest request, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (request.Action is not ("preview" or "apply") || request.Target is not ("draft" or "air"))
            return ApiErrors.Of(400, "ticker_sheet_invalid");
        var reply = await bridge.SendAsync("ticker.sheet", new { actor = http.User.UserId(), request.Action, request.Target, request.Review }, http.RequestAborted);
        if (reply.Ok)
            return request.Action == "apply" ? Results.NoContent() : TypedResults.Ok(reply.Data.Deserialize<TickerSheetPreview>(JsonDefaults.Options));
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "content_disabled" or "ticker_sheet_unconfigured" => ApiErrors.Of(404, reply.Error),
            "ticker_sheet_invalid" => ApiErrors.Of(400, reply.Error),
            "ticker_locked" or "ticker_sheet_stale" or "ticker_sheet_busy" => ApiErrors.Of(409, reply.Error),
            "content_unreadable" or "ticker_sheet_unavailable" or "ticker_sheet_save_failed" or "ticker_sheet_schedule_cancelled" or "bridge_outcome_unknown" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static async Task<IResult> TickerBackups(TickerBackupRequest request, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (request.Action is not ("list" or "preview" or "restore")) return ApiErrors.Of(400, "ticker_backup_invalid");
        var reply = await bridge.SendAsync("ticker.backups", new
        {
            actor = http.User.UserId(), request.Action, request.Id, request.Review, request.Page
        }, http.RequestAborted);
        if (reply.Ok)
            return request.Action == "restore" ? Results.NoContent() : TypedResults.Ok(reply.Data.Deserialize<TickerBackupResponse>(JsonDefaults.Options));
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "content_disabled" => ApiErrors.Of(404, reply.Error),
            "ticker_backup_invalid" => ApiErrors.Of(400, reply.Error),
            "ticker_backup_stale" => ApiErrors.Of(409, reply.Error),
            "ticker_backup_unreadable" or "ticker_backup_save_failed" or "ticker_backup_schedule_cancelled" or "bridge_outcome_unknown" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static async Task<IResult> TickerSets(TickerSetRequest request, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("ticker.sets", new
        {
            actor = http.User.UserId(), request.Action, request.Index, request.Revision, request.DraftRevision, request.Name
        }, http.RequestAborted);
        http.Response.Headers.CacheControl = "no-store";
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<TickerSetsState>(JsonDefaults.Options));
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "content_disabled" => ApiErrors.Of(404, reply.Error),
            "ticker_set_invalid" or "ticker_set_full" => ApiErrors.Of(400, reply.Error),
            "ticker_stale" or "ticker_locked" or "ticker_set_stale" or "ticker_set_exists" => ApiErrors.Of(409, reply.Error),
            "ticker_set_save_failed" or "bridge_outcome_unknown" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static async Task<IResult> TickerEditor(TickerDraftRequest request, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("ticker.edit", new
        {
            actor = http.User.UserId(), request.Action, request.Revision, request.Index, request.Text, request.Review,
            request.PublishAtMs, request.PausedPage
        }, http.RequestAborted);
        if (reply.Ok)
        {
            http.Response.Headers.CacheControl = "no-store";
            return TypedResults.Ok(reply.Data.Deserialize<TickerEditorState>(JsonDefaults.Options));
        }
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "content_disabled" => ApiErrors.Of(404, reply.Error),
            "ticker_stale" or "ticker_locked" or "ticker_conflict" or "ticker_lock_pending" => ApiErrors.Of(409, reply.Error),
            "ticker_invalid" or "ticker_full" or "ticker_schedule_invalid" or "ticker_paste_invalid" or "ticker_paste_separator" => ApiErrors.Of(400, reply.Error),
            "content_unreadable" or "ticker_start_failed" or "ticker_publish_failed" or "ticker_lock_save_failed" or "bridge_outcome_unknown" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static async Task<IResult> UrgentManual(UrgentManualRequest request, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("urgent.manual", new
        {
            actor = http.User.UserId(), request.Action, request.ItemId, request.AutoHideSeconds, request.Review
        }, http.RequestAborted);
        if (reply.Ok) return Results.Ok(reply.Data.Deserialize<UrgentManualResponse>(JsonDefaults.Options));
        return reply.Error switch
        {
            "urgent_invalid" => ApiErrors.Of(400, reply.Error),
            "refused" => ApiErrors.Of(400, reply.Error, reply.Data.ValueKind == JsonValueKind.String ? reply.Data.GetString() : null),
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "content_disabled" => ApiErrors.Of(404, reply.Error),
            "urgent_stale" or "urgent_manual_hide_unconfirmed" => ApiErrors.Of(409, reply.Error),
            "bridge_outcome_unknown" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable(),
        };
    }

    private static async Task<IResult> UrgentTiming(UrgentTimingRequest request, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("urgent.timing", new
        {
            actor = http.User.UserId(), request.Action, request.Revision, request.Field, request.Number, request.Option
        }, http.RequestAborted);
        if (reply.Ok) return Results.Ok(reply.Data.Deserialize<UrgentTimingState>(JsonDefaults.Options));
        return reply.Error switch
        {
            "urgent_timing_invalid" => ApiErrors.Of(400, reply.Error),
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "content_disabled" => ApiErrors.Of(404, reply.Error),
            "urgent_stale" or "urgent_timing_active" => ApiErrors.Of(409, reply.Error),
            "urgent_timing_save_failed" or "bridge_outcome_unknown" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }

    private static async Task<IResult> UrgentPlayback(UrgentPlaybackRequest request, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("urgent.playback", new
        {
            actor = http.User.UserId(), request.Action, request.SelectedIds, request.Review, request.RunId, request.Step
        }, http.RequestAborted);
        if (reply.Ok)
        {
            http.Response.Headers.CacheControl = "no-store";
            return TypedResults.Ok(reply.Data.Deserialize<UrgentPlaybackResponse>(JsonDefaults.Options));
        }
        return reply.Error switch
        {
            "forbidden" => ApiErrors.Of(403, reply.Error),
            "content_disabled" => ApiErrors.Of(404, reply.Error),
            "urgent_stale" or "urgent_air_busy" or "urgent_stop_unconfirmed" => ApiErrors.Of(409, reply.Error),
            "urgent_invalid" => ApiErrors.Of(400, reply.Error),
            "refused" => ApiErrors.Of(400, reply.Error, reply.Data.ValueKind == JsonValueKind.String ? reply.Data.GetString() : null),
            "bridge_outcome_unknown" => ApiErrors.Of(503, reply.Error),
            _ => ApiErrors.BridgeUnavailable()
        };
    }
}
