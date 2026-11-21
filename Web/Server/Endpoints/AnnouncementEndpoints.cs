using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class AnnouncementEndpoints
{
    public static void MapAnnouncementEndpoints(this IEndpointRouteBuilder app)
    {
        var announcements = app.MapGroup("/api/admin/announcements")
            .WithTags("Administration").RequireAuthorization(AccountEndpoints.AdminPolicy);
        announcements.MapGet("", List).Produces<AnnouncementAdminPage>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(503);
        announcements.MapPost("/review", Review).Produces<AnnouncementPreview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        announcements.MapPost("/confirm", Confirm).Produces<AnnouncementAdminItem>()
            .Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        announcements.MapPost("/{id}/cancel/review", ReviewCancel).Produces<AnnouncementCancelPreview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        announcements.MapPost("/{id}/cancel/confirm", ConfirmCancel).Produces<AnnouncementCancelResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
    }

    private static Task<IResult> List(int? page, int? pageSize, HttpContext http, IBridgeChannel bridge) =>
        Send<AnnouncementAdminPage>(http, bridge, "admin.announcements.list", new { actor = http.User.UserId(), page, pageSize });

    private static Task<IResult> Review(AnnouncementReviewCommand request, HttpContext http, IBridgeChannel bridge) =>
        Send<AnnouncementPreview>(http, bridge, "admin.announcements.queue.review", new {
            actor = http.User.UserId(), request.Text, request.Scope, request.ExpiryHours, request.RepeatHours, request.RequireAck, request.Pinned
        });

    private static Task<IResult> Confirm(AnnouncementConfirmCommand request, HttpContext http, IBridgeChannel bridge) =>
        Send<AnnouncementAdminItem>(http, bridge, "admin.announcements.queue.confirm", new { actor = http.User.UserId(), request.Review });

    private static Task<IResult> ReviewCancel(string id, HttpContext http, IBridgeChannel bridge) =>
        Send<AnnouncementCancelPreview>(http, bridge, "admin.announcements.cancel.review", new { actor = http.User.UserId(), id });

    private static Task<IResult> ConfirmCancel(string id, AnnouncementConfirmCommand request, HttpContext http, IBridgeChannel bridge) =>
        Send<AnnouncementCancelResult>(http, bridge, "admin.announcements.cancel.confirm", new { actor = http.User.UserId(), id, request.Review });

    private static async Task<IResult> Send<T>(HttpContext http, IBridgeChannel bridge, string operation, object request)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync(operation, request, http.RequestAborted);
        if (!reply.Ok)
        {
            var status = reply.Error switch
            {
                "forbidden" => 403,
                "bad_request" or "announcement_invalid" => 400,
                "announcement_disabled" or "announcement_no_recipients" or "announcement_stale" => 409,
                "announcement_save_failed" or "bridge_busy" => 503,
                _ => 0
            };
            return status == 0 ? ApiErrors.BridgeUnavailable() : ApiErrors.Of(status, reply.Error);
        }

        try
        {
            var result = reply.Data.Deserialize<T>(JsonDefaults.Options);
            return result is null ? ApiErrors.BridgeUnavailable() : TypedResults.Ok(result);
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }
}
