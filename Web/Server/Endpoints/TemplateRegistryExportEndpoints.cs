using System.Security.Cryptography;
using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class TemplateRegistryExportEndpoints
{
    private const string Operation = "air.template-registry-export";
    private sealed record TransferReceipt(int Bytes, string Sha256);

    public static void MapTemplateRegistryExportEndpoints(this IEndpointRouteBuilder app)
    {
        var export = app.MapGroup("/api/air/template-registry/export").WithTags("Air")
            .RequireAuthorization(AccountEndpoints.AdminPolicy);
        export.MapPost("/review", Review).Produces<TemplateRegistryExportReview>()
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(413).Produces<ErrorResponse>(503);
        export.MapPost("/download", Download).Produces(200, typeof(byte[]), "application/octet-stream")
            .Produces<ErrorResponse>(400).Produces<ErrorResponse>(403).Produces<ErrorResponse>(409)
            .Produces<ErrorResponse>(413).Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> Review(IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync(Operation, new { actor = http.User.UserId(), action = "review" }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        try
        {
            var review = reply.Data.Deserialize<TemplateRegistryExportReview>(JsonDefaults.Options);
            return review is null ? ApiErrors.BridgeUnavailable() : TypedResults.Ok(review);
        }
        catch (JsonException) { return ApiErrors.BridgeUnavailable(); }
    }

    private static async Task<IResult> Download(TemplateRegistryExportDownload request, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (request.Review is not { Length: 32 }) return ApiErrors.Of(400, "template_registry_export_invalid");
        var (policy, error) = await TemplateRegistryTransferPolicy.Prepare(http, bridge, Operation);
        if (policy is null) return Error(error);
        try
        {
            var transferId = Guid.NewGuid().ToString("N");
            await using var download = policy.Open("download", transferId, FileAccess.ReadWrite);
            var reply = await bridge.SendAsync(Operation,
                new { actor = http.User.UserId(), action = "download", request.Review, transferId }, http.RequestAborted);
            if (!reply.Ok) return Error(reply.Error);
            var receipt = reply.Data.Deserialize<TransferReceipt>(JsonDefaults.Options);
            if (receipt is null || receipt.Bytes <= 0 || receipt.Bytes > policy.MaximumBytes || download.Length != receipt.Bytes)
                return ApiErrors.BridgeUnavailable();
            var bytes = new byte[receipt.Bytes];
            await download.ReadExactlyAsync(bytes, http.RequestAborted);
            return Convert.ToHexString(SHA256.HashData(bytes)) == receipt.Sha256
                ? Results.File(bytes, "application/octet-stream", "templates.json") : ApiErrors.BridgeUnavailable();
        }
        catch (IOException) { return Error("template_registry_export_unavailable"); }
        catch (UnauthorizedAccessException) { return Error("template_registry_export_unavailable"); }
        catch (JsonException) { return ApiErrors.BridgeUnavailable(); }
    }

    private static IResult Error(string code) => code switch
    {
        "forbidden" => ApiErrors.Of(403, code),
        "template_registry_export_invalid" => ApiErrors.Of(400, code),
        "template_registry_export_stale" => ApiErrors.Of(409, code),
        "template_registry_export_size" => ApiErrors.Of(413, code),
        "template_registry_export_unavailable" or "template_registry_transfer_unavailable" => ApiErrors.Of(503, "template_registry_export_unavailable"),
        _ => ApiErrors.BridgeUnavailable()
    };
}
