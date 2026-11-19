using System.Text.Json;

namespace CinegyBridge.Web;

/// <summary>
/// Where the bridge lives and how this server is reached. Read once at
/// startup from the command line or environment (the control program passes
/// <c>--BridgeRoot</c> and <c>--Port</c>).
/// </summary>
public sealed class WebOptions
{
    public required string BridgeRoot { get; init; }
    public int Port { get; init; } = 8790;
    public string PipeName { get; init; } = "CinegyTelegramBridge.Web";

    /// <summary>The named tunnel's hostname, once there is one. Quick tunnels
    /// are allowed by their domain without configuration.</summary>
    public string PublicHostname { get; init; } = "";

    public string StateDirectory => Path.Combine(BridgeRoot, "logs", "web");

    public static WebOptions FromConfiguration(IConfiguration configuration, IHostEnvironment environment)
    {
        var root = configuration["BridgeRoot"];
        if (string.IsNullOrWhiteSpace(root))
        {
            // Development: Web/Server sits two folders below the bridge.
            root = Path.GetFullPath(Path.Combine(environment.ContentRootPath, "..", ".."));
        }
        if (!File.Exists(Path.Combine(root, "TelegramBridge.ps1")))
        {
            throw new InvalidOperationException($"BridgeRoot '{root}' does not contain TelegramBridge.ps1.");
        }
        return new WebOptions
        {
            BridgeRoot = Path.GetFullPath(root),
            Port = configuration.GetValue("Port", 8790),
            PipeName = configuration["PipeName"] is { Length: > 0 } pipe ? pipe : "CinegyTelegramBridge.Web",
            PublicHostname = configuration["PublicHostname"] ?? "",
        };
    }

    public IReadOnlyList<string> AllowedHosts()
    {
        var hosts = new List<string> { "localhost", "127.0.0.1", "[::1]", "*.trycloudflare.com" };
        if (!string.IsNullOrWhiteSpace(PublicHostname)) hosts.Add(PublicHostname.Trim());
        return hosts;
    }
}

public static class JsonDefaults
{
    public static JsonSerializerOptions Options { get; } = new(JsonSerializerDefaults.Web);
}
