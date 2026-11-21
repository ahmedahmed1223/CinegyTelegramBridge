using System.IO.Compression;
using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class RuntimeFileDiagnosticsEndpoints
{
    public static void MapRuntimeFileDiagnosticsEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/admin/diagnostics/runtime-bundle", Download)
            .WithTags("Administration")
            .RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces(200, typeof(byte[]), "application/zip")
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
        app.MapGet("/api/admin/diagnostics/runtime-files", Read)
            .WithTags("Administration")
            .RequireAuthorization(AccountEndpoints.AdminPolicy)
            .Produces<RuntimeFileDiagnostics>()
            .Produces<ErrorResponse>(StatusCodes.Status403Forbidden)
            .Produces<ErrorResponse>(StatusCodes.Status503ServiceUnavailable);
    }

    private static async Task<IResult> Download(HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("admin.diagnostics.bundle", new { actor = http.User.UserId() }, http.RequestAborted);
        if (!reply.Ok)
            return reply.Error == "forbidden" ? ApiErrors.Of(StatusCodes.Status403Forbidden, reply.Error) : ApiErrors.BridgeUnavailable();

        RuntimeDiagnosticBundle? bundle;
        try { bundle = reply.Data.Deserialize<RuntimeDiagnosticBundle>(JsonDefaults.Options); }
        catch (JsonException) { return ApiErrors.BridgeUnavailable(); }
        if (bundle?.Timeline?.Items is not { Length: <= 200 } || bundle.RuntimeFiles?.Items is not { Length: <= 8 })
            return ApiErrors.BridgeUnavailable();

        using var output = new MemoryStream();
        using (var archive = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true))
        {
            using (var summary = archive.CreateEntry("summary.json").Open())
                JsonSerializer.Serialize(summary, new
                {
                    bundle.SchemaVersion, bundle.GeneratedAtMs, bundle.BridgeVersion, bundle.PowershellVersion,
                    bundle.UptimeSeconds, bundle.WorkingSetMB, bundle.PrivateMemoryMB, bundle.DiskFreeGB, bundle.LowDisk,
                    bundle.AirOperations, bundle.RuntimeFiles
                }, JsonDefaults.Options);
            using var timeline = archive.CreateEntry("recent-runtime.json").Open();
            JsonSerializer.Serialize(timeline, bundle.Timeline, JsonDefaults.Options);
        }

        return Results.File(output.ToArray(), "application/zip", "cinegy-bridge-diagnostics.zip");
    }

    private static async Task<IResult> Read(HttpContext http, IBridgeChannel bridge)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("admin.diagnostics.runtime-files", new { actor = http.User.UserId() }, http.RequestAborted);
        if (!reply.Ok)
            return reply.Error == "forbidden" ? ApiErrors.Of(StatusCodes.Status403Forbidden, reply.Error) : ApiErrors.BridgeUnavailable();

        try
        {
            var result = reply.Data.Deserialize<RuntimeFileDiagnostics>(JsonDefaults.Options);
            return result is null ? ApiErrors.BridgeUnavailable() : TypedResults.Ok(result);
        }
        catch (JsonException)
        {
            return ApiErrors.BridgeUnavailable();
        }
    }
}
