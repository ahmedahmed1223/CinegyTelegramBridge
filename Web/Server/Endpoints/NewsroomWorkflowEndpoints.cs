using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class NewsroomWorkflowEndpoints
{
    public static void MapNewsroomWorkflowEndpoints(this IEndpointRouteBuilder app)
    {
        var access = app.MapGroup("/api/telegram-access").WithTags("Telegram access")
            .RequireAuthorization(AccountEndpoints.AdminPolicy);
        access.MapGet("/requests", Requests).Produces<TelegramAccessPage>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        access.MapPost("/requests/{chatId:long}/review", ReviewDecision).Produces<TelegramAccessReview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        access.MapPost("/requests/{chatId:long}/decision", Decide).Produces<TelegramAccessDecision>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        access.MapPut("/users/{userId:long}/role", Role).Produces<TelegramAccessRole>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);

        var schedule = app.MapGroup("/api/schedule/templates").WithTags("Template schedule").RequireAuthorization();
        schedule.MapGet("", SchedulePage).Produces<TemplateSchedulePage>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        schedule.MapPost("/review", ReviewSchedule).Produces<TemplateScheduleReview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        schedule.MapPost("/confirm", SaveSchedule).Produces<TemplateSchedulePage>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);

        var hold = schedule.MapGroup("/hold").RequireAuthorization(AccountEndpoints.AdminPolicy);
        hold.MapPost("/review", ReviewScheduleHold).Produces<ScheduleHoldReview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        hold.MapPost("/confirm", ConfirmScheduleHold).Produces<ScheduleHoldResult>()
            .Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);

        app.MapGet("/api/schedule/materials", ScheduleMaterials).WithTags("Template schedule").RequireAuthorization()
            .Produces<ScheduleMaterialPage>().Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);

        app.MapPost("/api/air/rerun", Rerun).WithTags("Air").RequireAuthorization().Produces<AirRerunResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> Requests(int? page, int? pageSize, IBridgeChannel bridge, HttpContext http) =>
        await Send<TelegramAccessPage>(bridge, http, "telegram.access.requests", new { actor = http.User.UserId(), page, pageSize });

    private static async Task<IResult> ReviewDecision(long chatId, TelegramAccessReviewCommand request, IBridgeChannel bridge, HttpContext http) =>
        await Send<TelegramAccessReview>(bridge, http, "telegram.access.review", new { actor = http.User.UserId(), chatId, request.Decision });

    private static async Task<IResult> Decide(long chatId, TelegramAccessDecisionCommand request, IBridgeChannel bridge, HttpContext http) =>
        await Send<TelegramAccessDecision>(bridge, http, "telegram.access.decide",
            new { actor = http.User.UserId(), chatId, request.Decision, request.Review });

    private static async Task<IResult> Role(long userId, TelegramAccessRoleCommand request, IBridgeChannel bridge,
        BridgeIdentity identity, HttpContext http)
    {
        var reply = await bridge.SendAsync("telegram.access.role",
            new { actor = http.User.UserId(), userId, request.Role, request.ExpectedRole }, http.RequestAborted);
        if (reply.Ok) identity.Forget(userId);
        return Result<TelegramAccessRole>(http, reply);
    }

    private static async Task<IResult> SchedulePage(int? page, IBridgeChannel bridge, HttpContext http) =>
        await Send<TemplateSchedulePage>(bridge, http, "schedule.templates", new { actor = http.User.UserId(), action = "list", page = page ?? 0 });

    private static async Task<IResult> ScheduleMaterials(int? page, IBridgeChannel bridge, HttpContext http) =>
        await Send<ScheduleMaterialPage>(bridge, http, "schedule.templates", new { actor = http.User.UserId(), action = "materials", page = page ?? 0 });

    private static async Task<IResult> ReviewSchedule(TemplateScheduleReviewCommand request, IBridgeChannel bridge, HttpContext http) =>
        await Send<TemplateScheduleReview>(bridge, http, "schedule.templates",
            new
            {
                actor = http.User.UserId(), action = "review", request.Key, request.Time, request.Recurrence,
                request.RecurrenceUntil, request.Variables, request.Operation, request.ScheduleId, request.Revision,
                request.AnchorMaterialId, request.AnchorOffsetSeconds
            });

    private static Task<IResult> ReviewScheduleHold(ScheduleHoldReviewCommand request, IBridgeChannel bridge, HttpContext http) =>
        Send<ScheduleHoldReview>(bridge, http, "schedule.hold.review", new { actor = http.User.UserId(), request.Paused });

    private static Task<IResult> ConfirmScheduleHold(TemplateScheduleConfirmCommand request, IBridgeChannel bridge, HttpContext http) =>
        Send<ScheduleHoldResult>(bridge, http, "schedule.hold.confirm", new { actor = http.User.UserId(), request.Review });

    private static async Task<IResult> SaveSchedule(TemplateScheduleConfirmCommand request, IBridgeChannel bridge, HttpContext http) =>
        await Send<TemplateSchedulePage>(bridge, http, "schedule.templates",
            new { actor = http.User.UserId(), action = "confirm", request.Review });

    private static async Task<IResult> Rerun(AirRerunCommand request, IBridgeChannel bridge, HttpContext http) =>
        await Send<AirRerunResult>(bridge, http, "air.rerun",
            new { actor = http.User.UserId(), request.Kind, request.Action, request.Variables, request.Review });

    private static async Task<IResult> Send<T>(IBridgeChannel bridge, HttpContext http, string operation, object arguments) =>
        Result<T>(http, await bridge.SendAsync(operation, arguments, http.RequestAborted));

    private static IResult Result<T>(HttpContext http, BridgeReply reply)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (reply.Ok) return TypedResults.Ok(reply.Data.Deserialize<T>(JsonDefaults.Options));
        var status = reply.Error switch
        {
            "forbidden" or "owner_only" => 403,
            "rerun_missing" => 404,
            "bad_request" or "schedule_hold_invalid" or "schedule_invalid" or "schedule_invalid_time" or "schedule_invalid_end" or
                "schedule_invalid_fields" or "schedule_material_invalid" or "rerun_invalid" or "rerun_required" or "rerun_too_long" => 400,
            "access_request_stale" or "access_role_stale" or "access_role_refused" or "schedule_stale" or "schedule_hold_stale" or
                "schedule_template_unavailable" or "schedule_maintenance" or "schedule_clock" or
                "schedule_material_disabled" or "schedule_material_stale" or "rerun_stale" or
                "rerun_refused" or "rerun_busy" or "rerun_unverified" or "rerun_ambiguous" => 409,
            _ => 503
        };
        return ApiErrors.Of(status, reply.Error);
    }
}
