using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

public static class AdminSettingsEndpoints
{
    public static void MapAdminSettingsEndpoints(this IEndpointRouteBuilder app)
    {
        var settings = app.MapGroup("/api/admin/settings").WithTags("Administration")
            .RequireAuthorization(AccountEndpoints.AdminPolicy);
        settings.MapGet("/export", Export)
            .Produces<WebEditableSettingsExport>()
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(503);
        settings.MapPost("/import/review", ReviewImport)
            .Accepts<WebEditableSettingsExport>("application/json")
            .Produces<WebSettingsImportPreview>()
            .Produces<ErrorResponse>(400)
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(413)
            .Produces<ErrorResponse>(503);
        settings.MapPost("/import/confirm", ConfirmImport)
            .Produces<WebSettingsImportResult>()
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409)
            .Produces<ErrorResponse>(503);
        settings.MapPost("/{id}/review", Review)
            .Produces<AdminSettingPreview>()
            .Produces<ErrorResponse>(400)
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(503);
        settings.MapPost("/{id}/confirm", Confirm)
            .Produces<AdminSettingResult>()
            .Produces<ErrorResponse>(400)
            .Produces<ErrorResponse>(403)
            .Produces<ErrorResponse>(409)
            .Produces<ErrorResponse>(503);
    }

    private static Task<IResult> Export(HttpContext http, IBridgeChannel bridge) =>
        Send<WebEditableSettingsExport>(http, bridge, "admin.settings.export", new { actor = http.User.UserId() });

    private static async Task<IResult> ReviewImport(HttpContext http, IBridgeChannel bridge)
    {
        const int maxBytes = 16 * 1024;
        http.Response.Headers.CacheControl = "no-store";
        if (http.Request.ContentLength > maxBytes) return ApiErrors.Of(413, "settings_import_size");

        var buffer = new byte[maxBytes + 1];
        var read = 0;
        while (read < buffer.Length)
        {
            var count = await http.Request.Body.ReadAsync(buffer.AsMemory(read), http.RequestAborted);
            if (count == 0) break;
            read += count;
        }
        if (read > maxBytes) return ApiErrors.Of(413, "settings_import_size");

        var hasBom = read >= 3 && buffer[0] == 0xef && buffer[1] == 0xbb && buffer[2] == 0xbf;
        var start = hasBom ? 3 : 0;
        try
        {
            using var document = JsonDocument.Parse(buffer.AsMemory(start, read - start), new JsonDocumentOptions { MaxDepth = 8 });
            if (!TryReadEditableSettings(document.RootElement, out var settings))
                return ApiErrors.Of(400, "settings_import_invalid");
            return await Send<WebSettingsImportPreview>(http, bridge, "admin.settings.import.review",
                new { actor = http.User.UserId(), settings });
        }
        catch (JsonException)
        {
            return ApiErrors.Of(400, "settings_import_invalid");
        }
    }

    private static bool TryReadEditableSettings(JsonElement root, out Dictionary<string, object> settings)
    {
        settings = new(StringComparer.Ordinal);
        if (root.ValueKind != JsonValueKind.Object) return false;
        var fields = new HashSet<string>(StringComparer.Ordinal);
        foreach (var field in root.EnumerateObject())
        {
            if (!fields.Add(field.Name)) return false;
            switch (field.Name)
            {
                case "Kind" when field.Value.ValueKind == JsonValueKind.String &&
                    field.Value.GetString() == "CinegyTelegramBridge.Settings":
                    break;
                case "BridgeVersion" when field.Value.ValueKind == JsonValueKind.String &&
                    Version.TryParse(field.Value.GetString(), out _):
                    break;
                case "ExportedAt" when field.Value.ValueKind == JsonValueKind.String && field.Value.TryGetDateTimeOffset(out _):
                    break;
                case "Settings" when field.Value.ValueKind == JsonValueKind.Object:
                    foreach (var setting in field.Value.EnumerateObject())
                    {
                        object? value = setting.Name switch
                        {
                            nameof(WebEditableSettingsValues.NotifyAdminsOnAccessRequest) or nameof(WebEditableSettingsValues.AskRequesterName)
                                or nameof(WebEditableSettingsValues.OneHandMode) or nameof(WebEditableSettingsValues.EnablePersistentMenuButton)
                                when setting.Value.ValueKind is JsonValueKind.True or JsonValueKind.False => setting.Value.GetBoolean(),
                            nameof(WebEditableSettingsValues.MaxPendingApprovals) or nameof(WebEditableSettingsValues.PendingStateTimeoutMinutes)
                                when setting.Value.ValueKind == JsonValueKind.Number && setting.Value.TryGetInt32(out var number) => number,
                            _ => null
                        };
                        if (value is null || !settings.TryAdd(setting.Name, value)) return false;
                    }
                    break;
                default:
                    return false;
            }
        }
        return fields.Contains("Kind") && settings.Count > 0;
    }

    private static Task<IResult> ConfirmImport(AdminSettingConfirmCommand request, HttpContext http, IBridgeChannel bridge) =>
        Send<WebSettingsImportResult>(http, bridge, "admin.settings.import.confirm",
            new { actor = http.User.UserId(), request.Review });

    private static Task<IResult> Review(string id, AdminSettingReviewCommand request, HttpContext http, IBridgeChannel bridge) =>
        Send<AdminSettingPreview>(http, bridge, "admin.settings.review",
            new { actor = http.User.UserId(), id, request.Enabled, request.Value });

    private static Task<IResult> Confirm(string id, AdminSettingConfirmCommand request, HttpContext http, IBridgeChannel bridge) =>
        Send<AdminSettingResult>(http, bridge, "admin.settings.confirm",
            new { actor = http.User.UserId(), id, request.Review });

    private static async Task<IResult> Send<T>(HttpContext http, IBridgeChannel bridge, string operation, object request)
    {
        http.Response.Headers.CacheControl = "no-store";
        var reply = await bridge.SendAsync(operation, request, http.RequestAborted);
        if (!reply.Ok)
        {
            var status = reply.Error switch
            {
                "forbidden" => 403,
                "setting_not_editable" or "setting_invalid" or "settings_import_invalid" => 400,
                "setting_stale" => 409,
                "setting_save_failed" or "setting_export_unavailable" or "bridge_busy" => 503,
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
