using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.Mvc;

namespace CinegyBridge.Web.Endpoints;

public static class TemplateRegistryImportEndpoints
{
    private const string Operation = "air.template-registry-import";

    public static void MapTemplateRegistryImportEndpoints(this IEndpointRouteBuilder app)
    {
        var import = app.MapGroup("/api/air/template-registry/import").WithTags("Air")
            .RequireAuthorization(AccountEndpoints.AdminPolicy);
        import.MapPost("/review", Review).Accepts<Stream>("application/octet-stream").Produces<TemplateRegistryImportReview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409)
            .Produces<ErrorResponse>(413).Produces<ErrorResponse>(503);
        import.MapPost("/confirm", Confirm).Accepts<Stream>("application/octet-stream").Produces(204)
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409)
            .Produces<ErrorResponse>(413).Produces<ErrorResponse>(503);
    }

    private static Task<IResult> Review(HttpContext http, IBridgeChannel bridge) => Import(http, bridge, "review", null);

    private static Task<IResult> Confirm([FromHeader(Name = "X-Template-Registry-Review")] string? review,
        HttpContext http, IBridgeChannel bridge) => Import(http, bridge, "confirm", review);

    private static async Task<IResult> Import(HttpContext http, IBridgeChannel bridge, string action, string? review)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (action == "confirm" && review is not { Length: 32 }) return Error("template_registry_import_invalid");
        var (policy, error) = await TemplateRegistryTransferPolicy.Prepare(http, bridge, Operation);
        if (policy is null) return Error(error);
        if (http.Request.ContentLength > policy.MaximumBytes) return Error("template_registry_import_size");
        if (http.Features.Get<IHttpMaxRequestBodySizeFeature>() is { IsReadOnly: false } limit)
            limit.MaxRequestBodySize = policy.MaximumBytes;

        try
        {
            var transferId = Guid.NewGuid().ToString("N");
            await using var upload = policy.Open("upload", transferId, FileAccess.Write);
            var buffer = new byte[16384];
            int count;
            while ((count = await http.Request.Body.ReadAsync(buffer, http.RequestAborted)) > 0)
            {
                if (upload.Length + count > policy.MaximumBytes) return Error("template_registry_import_size");
                await upload.WriteAsync(buffer.AsMemory(0, count), http.RequestAborted);
            }
            if (upload.Length == 0) return Error("template_registry_import_invalid");
            await upload.FlushAsync(http.RequestAborted);
            var reply = await bridge.SendAsync(Operation, new
            {
                actor = http.User.UserId(),
                action,
                review,
                transferId,
            }, http.RequestAborted);
            if (!reply.Ok) return Error(reply.Error);
            if (action == "confirm") return Results.NoContent();
            var summary = reply.Data.Deserialize<TemplateRegistryImportReview>(JsonDefaults.Options);
            return summary is null ? ApiErrors.BridgeUnavailable() : TypedResults.Ok(summary);
        }
        catch (BadHttpRequestException ex) when (ex.StatusCode == StatusCodes.Status413PayloadTooLarge)
        {
            return Error("template_registry_import_size");
        }
        catch (IOException) { return Error("template_registry_import_unavailable"); }
        catch (UnauthorizedAccessException) { return Error("template_registry_import_unavailable"); }
        catch (JsonException) { return ApiErrors.BridgeUnavailable(); }
    }

    private static IResult Error(string code) => code switch
    {
        "forbidden" => ApiErrors.Of(403, code),
        "template_registry_import_invalid" or "template_backup_invalid" or "template_registry_import_path" or
            "template_registry_import_path_count" => ApiErrors.Of(400, code),
        "template_registry_import_stale" or "template_backup_identical" or "scene_definition_live" or
            "scene_definition_scheduled" or "scene_definition_linked" or "scene_definition_alias" => ApiErrors.Of(409, code),
        "template_registry_import_size" => ApiErrors.Of(413, code),
        "template_registry_import_unavailable" or "template_registry_transfer_unavailable" => ApiErrors.Of(503, "template_registry_import_unavailable"),
        _ => ApiErrors.BridgeUnavailable()
    };
}
