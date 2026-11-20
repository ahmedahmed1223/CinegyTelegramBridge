using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Win32.SafeHandles;

namespace CinegyBridge.Web.Endpoints;

internal static class BulletinPhotoEndpoints
{
    private sealed record UploadPolicy(string Directory, int MaximumBytes);
    private sealed record PreviewFile(string Root, string Path);

    public static void Map(RouteGroupBuilder bulletin)
    {
        bulletin.MapPost("/photo", Upload)
            .Accepts<Stream>("application/octet-stream")
            .Produces<BulletinEditor>()
            .Produces<ErrorResponse>(400)
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409)
            .Produces<ErrorResponse>(413)
            .Produces<ErrorResponse>(503);
        bulletin.MapGet("/preview-image", Preview)
            .Produces(200, contentType: "image/png", additionalContentTypes: ["image/jpeg", "image/bmp", "image/gif", "image/webp"])
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(404)
            .Produces<ErrorResponse>(409)
            .Produces<ErrorResponse>(503);
    }

    private static async Task<IResult> Preview(string id, string rowId, string field, int revision, string stamp, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync("bulletin.preview-image", new { actor = http.User.UserId(), id, rowId, field, revision, stamp }, http.RequestAborted);
        if (!reply.Ok) return Error(reply.Error);
        var file = reply.Data.Deserialize<PreviewFile>(JsonDefaults.Options);
        if (file is null || string.IsNullOrEmpty(file.Root) || string.IsNullOrEmpty(file.Path) ||
            !Path.IsPathFullyQualified(file.Root) || !Path.IsPathFullyQualified(file.Path))
            return Error("not_found");

        FileStream? stream = null;
        try
        {
            var relative = Path.GetRelativePath(file.Root, file.Path);
            var segments = relative.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (Path.IsPathRooted(relative) || segments.Any(segment => segment is "" or "." or ".." || segment.Contains(':')))
                return Error("not_found");
            var candidate = Path.GetFullPath(Path.Combine(file.Root, relative));
            if (HasReparsePoint(candidate)) return Error("not_found");
            if ((File.GetAttributes(candidate) & FileAttributes.Directory) != 0) return Error("not_found");
            stream = File.Open(candidate, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            // Check the opened handle as well: a component could have been
            // redirected between inspecting the path and opening it.
            if (!MatchesOpenedPath(stream.SafeFileHandle, candidate)) return Error("not_found");
            if (stream.Length is < 12 or > 32 * 1024 * 1024) return Error("not_found");
            var type = ReadImageType(stream, Path.GetExtension(candidate));
            if (type is null) return Error("not_found");
            stream.Position = 0;
            var result = Results.File(stream, type);
            stream = null;
            return result;
        }
        catch (IOException) { return Error("not_found"); }
        catch (UnauthorizedAccessException) { return Error("not_found"); }
        finally { stream?.Dispose(); }
    }

    private static bool HasReparsePoint(string path)
    {
        var root = Path.GetPathRoot(path)!;
        var candidate = root;
        if ((File.GetAttributes(candidate) & FileAttributes.ReparsePoint) != 0) return true;
        foreach (var segment in Path.GetRelativePath(root, path).Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))
        {
            candidate = Path.Combine(candidate, segment);
            if ((File.GetAttributes(candidate) & FileAttributes.ReparsePoint) != 0) return true;
        }
        return false;
    }

    private static bool MatchesOpenedPath(SafeFileHandle handle, string expected)
    {
        var buffer = new StringBuilder(512);
        var length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
        if (length is 0 or > 32767) return false;
        if (length >= buffer.Capacity)
        {
            buffer.EnsureCapacity((int)length + 1);
            length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
        }
        if (length == 0 || length >= buffer.Capacity) return false;
        return string.Equals(WithoutExtendedPrefix(buffer.ToString()), WithoutExtendedPrefix(expected), StringComparison.OrdinalIgnoreCase);
    }

    private static string WithoutExtendedPrefix(string path) =>
        path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase) ? @"\\" + path[8..]
        : path.StartsWith(@"\\?\", StringComparison.Ordinal) ? path[4..] : path;

    [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);

    private static string? ReadImageType(Stream stream, string extension)
    {
        Span<byte> header = stackalloc byte[12];
        stream.ReadExactly(header);
        return extension.ToLowerInvariant() switch
        {
            ".png" when header.StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }) => "image/png",
            ".jpg" or ".jpeg" when header[0] == 255 && header[1] == 216 && header[2] == 255 => "image/jpeg",
            ".bmp" when header.StartsWith("BM"u8) => "image/bmp",
            ".gif" when header.StartsWith("GIF87a"u8) || header.StartsWith("GIF89a"u8) => "image/gif",
            ".webp" when header.StartsWith("RIFF"u8) && header[8..].SequenceEqual("WEBP"u8) => "image/webp",
            _ => null,
        };
    }

    private static async Task<IResult> Upload(string id, string rowId, int revision, string? field, IBridgeChannel bridge, HttpContext http)
    {
        http.Response.Headers.CacheControl = "no-store";
        if (revision < 1 || id.Length is < 1 or > 64 || rowId.Length is < 1 or > 64 || field is { Length: > 256 })
            return Error("bulletin_photo_invalid");
        var actor = http.User.UserId();
        var cancellation = http.RequestAborted;
        var prepare = await bridge.SendAsync("bulletin.photo", new { actor, action = "prepare", id, rowId, revision, field }, cancellation);
        if (!prepare.Ok) return Error(prepare.Error);
        var policy = prepare.Data.Deserialize<UploadPolicy>(JsonDefaults.Options);
        if (policy is null || string.IsNullOrEmpty(policy.Directory) ||
            !Path.IsPathFullyQualified(policy.Directory) || policy.MaximumBytes <= 0)
            return ApiErrors.BridgeUnavailable();
        if (http.Request.ContentLength > policy.MaximumBytes) return Error("bulletin_photo_size");
        if (http.Features.Get<IHttpMaxRequestBodySizeFeature>() is { IsReadOnly: false } limit)
            limit.MaxRequestBodySize = policy.MaximumBytes;

        try
        {
            var directory = Directory.CreateDirectory(policy.Directory);
            if ((directory.Attributes & FileAttributes.ReparsePoint) != 0) return Error("bulletin_save_failed");
            var upload = Guid.NewGuid().ToString("N");
            var path = Path.Combine(directory.FullName, $"web-{upload}.image");
            await using var staged = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read | FileShare.Delete,
                32_768, FileOptions.Asynchronous | FileOptions.DeleteOnClose);
            var buffer = new byte[32_768];
            long bytes = 0;
            while (true)
            {
                var read = await http.Request.Body.ReadAsync(buffer, cancellation);
                if (read == 0) break;
                bytes += read;
                if (bytes > policy.MaximumBytes) return Error("bulletin_photo_size");
                await staged.WriteAsync(buffer.AsMemory(0, read), cancellation);
            }
            if (bytes == 0) return Error("bulletin_photo_invalid");
            await staged.FlushAsync(cancellation);
            var reply = await bridge.SendAsync("bulletin.photo", new { actor, action = "apply", id, rowId, revision, field, upload }, cancellation);
            return reply.Ok ? Results.Ok(reply.Data.Deserialize<BulletinEditor>(JsonDefaults.Options)) : Error(reply.Error);
        }
        catch (BadHttpRequestException exception) when (exception.StatusCode == StatusCodes.Status413PayloadTooLarge)
        {
            return Error("bulletin_photo_size");
        }
        catch (IOException) { return Error("bulletin_save_failed"); }
        catch (UnauthorizedAccessException) { return Error("bulletin_save_failed"); }
    }

    private static IResult Error(string code) => code switch
    {
        "bulletin_photo_invalid" => ApiErrors.Of(400, code),
        "forbidden" => ApiErrors.Of(403, code),
        "not_found" or "content_disabled" or "bulletin_photo_unavailable" => ApiErrors.Of(404, code),
        "bulletin_stale" or "bulletin_photo_busy" => ApiErrors.Of(409, code),
        "bulletin_photo_size" => ApiErrors.Of(413, code),
        "bulletin_save_failed" or "bulletin_photo_timeout" or "bridge_outcome_unknown" => ApiErrors.Of(503, code),
        _ => ApiErrors.BridgeUnavailable(),
    };
}
