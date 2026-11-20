using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public sealed record TemplateFieldDto(string Name, string Label, bool Required, int? MaxLength);

public sealed record TemplateDto(string Key, string Name, int Layer, string? Category, bool Disabled, IReadOnlyList<TemplateFieldDto> Fields);

public sealed record ShowTemplateRequest(string Key, Dictionary<string, string>? Variables, int AutoHideSeconds);

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
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);

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
            autoHideSeconds = request.AutoHideSeconds
        }, http.RequestAborted);

        return AirResult(reply);
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
        "bad_duration" => ApiErrors.Of(400, reply.Error),
        "refused" => ApiErrors.Of(400, reply.Error, reply.Data.ValueKind == JsonValueKind.String ? reply.Data.GetString() : null),
        _ => ApiErrors.BridgeUnavailable()
    };
}
