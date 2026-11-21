using System.Text.Json;
using CinegyBridge.Web.Auth;
using CinegyBridge.Web.Bridge;

namespace CinegyBridge.Web.Endpoints;

internal sealed record TemplateRegistryTransferPolicy(string Directory, int MaximumBytes)
{
    public static async Task<(TemplateRegistryTransferPolicy? Policy, string Error)> Prepare(
        HttpContext http, IBridgeChannel bridge, string operation)
    {
        var reply = await bridge.SendAsync(operation, new { actor = http.User.UserId(), action = "prepare" }, http.RequestAborted);
        if (!reply.Ok) return (null, reply.Error);
        try
        {
            var policy = reply.Data.Deserialize<TemplateRegistryTransferPolicy>(JsonDefaults.Options);
            return policy is { MaximumBytes: > 0 and <= 10 * 1024 * 1024, Directory.Length: >= 3 } &&
                char.IsAsciiLetter(policy.Directory[0]) && policy.Directory[1] == ':' && Path.IsPathFullyQualified(policy.Directory)
                ? (policy, "") : (null, "template_registry_transfer_unavailable");
        }
        catch (JsonException) { return (null, "template_registry_transfer_unavailable"); }
    }

    public FileStream Open(string kind, string id, FileAccess access)
    {
        var directory = new DirectoryInfo(Directory);
        if (!directory.Exists || (directory.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Registry transfer directory is unavailable.");
        var share = (access == FileAccess.ReadWrite ? FileShare.ReadWrite : FileShare.Read) | FileShare.Delete;
        return new FileStream(Path.Combine(directory.FullName, $"{kind}-{id}.json"), FileMode.CreateNew, access,
            share, 32_768, FileOptions.Asynchronous | FileOptions.DeleteOnClose);
    }
}
