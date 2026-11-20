using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;
using Microsoft.AspNetCore.Http.Features;

namespace CinegyBridge.Web.Endpoints;

internal static class TickerTxtEndpoints
{
    private sealed record UploadPolicy(string Directory, int MaximumBytes);

    public static void Map(RouteGroupBuilder ticker)
    {
        ticker.MapPost("/txt", Import)
            .Accepts<Stream>("application/octet-stream")
            .Produces<TickerTxtPreview>()
            .Produces(204)
            .Produces<ErrorResponse>(400)
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409)
            .Produces<ErrorResponse>(413)
            .Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> Import(string action, string revision, string? review, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (action is not ("preview" or "apply") || revision.Length != 64
            || action == "apply" && review?.Length != 64)
            return ApiErrors.Of(400, "ticker_txt_invalid");

        var actor = http.User.UserId();
        var cancelled = http.RequestAborted;
        var prepare = await bridge.SendAsync("ticker.txt", new { actor, action = "prepare", revision }, cancelled);
        if (!prepare.Ok) return Error(prepare.Error);
        var policy = prepare.Data.Deserialize<UploadPolicy>(JsonDefaults.Options);
        if (policy is null || string.IsNullOrEmpty(policy.Directory) || !Path.IsPathFullyQualified(policy.Directory) || policy.MaximumBytes <= 0)
            return ApiErrors.BridgeUnavailable();
        if (http.Request.ContentLength > policy.MaximumBytes) return Error("ticker_txt_size");
        if (http.Features.Get<IHttpMaxRequestBodySizeFeature>() is { IsReadOnly: false } sizeLimit)
            sizeLimit.MaxRequestBodySize = policy.MaximumBytes;

        try
        {
            var directory = Directory.CreateDirectory(policy.Directory);
            if ((directory.Attributes & FileAttributes.ReparsePoint) != 0) return Error("ticker_txt_save_failed");
            var upload = Guid.NewGuid().ToString("N");
            var path = Path.Combine(directory.FullName, $"web-{upload}.txt");
            // Keep the file until the bridge answers. DeleteOnClose also cleans it up on a server restart.
            await using var staged = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read | FileShare.Delete, 32_768,
                FileOptions.Asynchronous | FileOptions.DeleteOnClose);
            var buffer = new byte[32_768];
            long bytes = 0;
            while (true)
            {
                var read = await http.Request.Body.ReadAsync(buffer, cancelled);
                if (read == 0) break;
                bytes += read;
                if (bytes > policy.MaximumBytes) return Error("ticker_txt_size");
                await staged.WriteAsync(buffer.AsMemory(0, read), cancelled);
            }
            if (bytes == 0) return Error("ticker_txt_empty");
            await staged.FlushAsync(cancelled);
            var reply = await bridge.SendAsync("ticker.txt", new { actor, action, revision, review, upload }, cancelled);
            if (!reply.Ok) return Error(reply.Error);
            return action == "apply" ? Results.NoContent() : Results.Ok(reply.Data.Deserialize<TickerTxtPreview>(JsonDefaults.Options));
        }
        catch (BadHttpRequestException exception) when (exception.StatusCode == StatusCodes.Status413PayloadTooLarge)
        {
            return Error("ticker_txt_size");
        }
        catch (IOException) { return Error("ticker_txt_save_failed"); }
        catch (UnauthorizedAccessException) { return Error("ticker_txt_save_failed"); }
    }

    private static IResult Error(string code) => code switch
    {
        "ticker_txt_invalid" or "ticker_txt_empty" => ApiErrors.Of(400, code),
        "forbidden" => ApiErrors.Of(403, code),
        "content_disabled" => ApiErrors.Of(404, code),
        "ticker_locked" or "ticker_stale" or "ticker_txt_busy" => ApiErrors.Of(409, code),
        "ticker_txt_size" => ApiErrors.Of(413, code),
        "ticker_txt_save_failed" or "ticker_txt_timeout" or "bridge_outcome_unknown" => ApiErrors.Of(503, code),
        _ => ApiErrors.BridgeUnavailable(),
    };
}
