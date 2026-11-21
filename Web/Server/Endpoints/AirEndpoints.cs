using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public sealed record TemplateFieldDto(string Name, string Label, bool Required, int? MaxLength, bool Sensitive = false);

public sealed record TemplateDto(string Key, string Name, int Layer, string? Category, bool Disabled, IReadOnlyList<TemplateFieldDto> Fields);

public sealed record ShowTemplateRequest(string Key, Dictionary<string, string>? Variables, int AutoHideSeconds,
    int? PresetIndex = null, string? PresetRevision = null);

public static class AirEndpoints
{
    public static void MapAirEndpoints(this IEndpointRouteBuilder app)
    {
        var api = app.MapGroup("/api/air").WithTags("Air").RequireAuthorization();

        api.MapGet("/templates", GetTemplates)
            .Produces<IReadOnlyList<TemplateDto>>()
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);

        api.MapPost("/show", Show)
            .Produces(StatusCodes.Status204NoContent)
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status404NotFound)
            .Produces<ErrorResponse>(StatusCodes.Status409Conflict)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);

        api.MapGet("/templates/{key}/presets", GetPresets)
            .Produces<TemplatePresetPage>()
            .Produces<ErrorResponse>(403).Produces<ErrorResponse>(404).Produces<ErrorResponse>(503);
        api.MapPost("/templates/{key}/presets", ChangePreset)
            .Produces<TemplatePresetPage>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        api.MapPost("/rehearsal", Rehearse)
            .Produces<TemplateRehearsalResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);
        api.MapPost("/template-catalogue", TemplateCatalogue)
            .RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<TemplateCatalogueResult>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409).Produces<ErrorResponse>(503);

        api.MapPost("/hide/{layer:int}", Hide)
            .Produces(StatusCodes.Status204NoContent)
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);

        api.MapPost("/exit/{layer:int}", Exit)
            .Produces(StatusCodes.Status204NoContent)
            .Produces<ErrorResponse>(StatusCodes.Status400BadRequest)
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
    }

    private static async Task<IResult> GetTemplates(IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("air.templates", null, http.RequestAborted);
        if (!reply.Ok) return ApiErrors.BridgeUnavailable();

        var templates = JsonSerializer.Deserialize<List<TemplateDto>>(reply.Data.GetRawText(), JsonDefaults.Options);
        return TypedResults.Ok(templates ?? []);
    }

    private static async Task<IResult> Show(ShowTemplateRequest request, IBridgeChannel bridge, HttpContext http)
    {
        if (string.IsNullOrWhiteSpace(request.Key)) return ApiErrors.Of(400, "bad_key");
        var actor = http.User.UserId();

        var reply = await bridge.SendAsync("air.show", new
        {
            actor,
            key = request.Key.Trim(),
            variables = request.Variables ?? new Dictionary<string, string>(),
            autoHideSeconds = request.AutoHideSeconds,
            request.PresetIndex,
            request.PresetRevision
        }, http.RequestAborted);

        return AirResult(reply);
    }

    private static async Task<IResult> GetPresets(string key, int? page, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("air.presets", new { actor = http.User.UserId(), key, page }, http.RequestAborted);
        return PresetResult(reply, http);
    }

    private static async Task<IResult> ChangePreset(string key, TemplatePresetRequest request, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("air.preset-change", new
        {
            actor = http.User.UserId(), key, request.Action, request.Revision, request.Index, request.Name, request.Values, request.Page
        }, http.RequestAborted);
        return PresetResult(reply, http);
    }

    private static async Task<IResult> Rehearse(TemplateRehearsalRequest request, IBridgeChannel bridge, HttpContext http)
    {
        var reply = await bridge.SendAsync("air.rehearsal", new
        {
            actor = http.User.UserId(), request.Key, request.Action, request.Review
        }, http.RequestAborted);
        if (!reply.Ok) return AirResult(reply);
        http.Response.Headers.CacheControl = "no-store";
        return TypedResults.Ok(reply.Data.Deserialize<TemplateRehearsalResult>(JsonDefaults.Options));
    }

    private static async Task<IResult> TemplateCatalogue(TemplateCatalogueRequest request, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("air.templateCatalogue", new
        {
            actor = http.User.UserId(), request.Action, request.Folder, request.Page, request.Search,
            request.Definition, request.Review
        }, http.RequestAborted);
        if (reply.IsUnavailable) return ApiErrors.BridgeUnavailable();
        if (!reply.Ok) return reply.Error switch
        {
            "scene_definition_invalid" => ApiErrors.Of(400, reply.Error),
            "scene_not_found" => ApiErrors.Of(404, reply.Error),
            "scene_registry_stale" or "scene_key_taken" => ApiErrors.Of(409, reply.Error),
            "scene_folder_missing" or "scene_registry_failed" => ApiErrors.Of(503, reply.Error),
            _ => AirResult(reply)
        };
        return TypedResults.Ok(reply.Data.Deserialize<TemplateCatalogueResult>(JsonDefaults.Options));
    }

    private static IResult PresetResult(BridgeReply reply, HttpContext http)
    {
        if (!reply.Ok) return AirResult(reply);
        http.Response.Headers.CacheControl = "no-store";
        return TypedResults.Ok(reply.Data.Deserialize<TemplatePresetPage>(JsonDefaults.Options));
    }

    private static async Task<IResult> Hide(int layer, IBridgeChannel bridge, HttpContext http)
    {
        var actor = http.User.UserId();
        var reply = await bridge.SendAsync("air.hide", new { actor, layer }, http.RequestAborted);

        return AirResult(reply);
    }

    private static async Task<IResult> Exit(int layer, IBridgeChannel bridge, HttpContext http)
    {
        var actor = http.User.UserId();
        var reply = await bridge.SendAsync("air.exit", new { actor, layer }, http.RequestAborted);

        return AirResult(reply);
    }

    private static IResult AirResult(BridgeReply reply) => reply.Ok ? TypedResults.NoContent() : reply.Error switch
    {
        "forbidden" => ApiErrors.Of(403, reply.Error),
        "not_found" => ApiErrors.Of(404, reply.Error),
        "preset_stale" or "preset_duplicate" => ApiErrors.Of(409, reply.Error),
        "preset_invalid" or "preset_invalid_name" or "preset_too_long" => ApiErrors.Of(400, reply.Error),
        "preset_save_failed" => ApiErrors.Of(503, reply.Error),
        "rehearsal_invalid" => ApiErrors.Of(400, reply.Error),
        "rehearsal_unavailable" => ApiErrors.Of(404, reply.Error),
        "rehearsal_busy" or "rehearsal_stale" or "rehearsal_multi" => ApiErrors.Of(409, reply.Error),
        "rehearsal_failed" or "rehearsal_unverified" => ApiErrors.Of(503, reply.Error),
        "bad_duration" => ApiErrors.Of(400, reply.Error),
        "refused" => ApiErrors.Of(400, reply.Error, reply.Data.ValueKind == JsonValueKind.String ? reply.Data.GetString() : null),
        _ => ApiErrors.BridgeUnavailable()
    };
}
