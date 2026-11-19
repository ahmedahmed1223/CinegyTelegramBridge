using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace BridgeManager;

/// <summary>
/// The web interface's two processes, owned by the control program so one
/// place starts, stops and watches everything: CinegyBridge.Web (the server,
/// loopback only) and cloudflared (the tunnel that makes it reachable from
/// outside). Both outlive the web window; they stop with the manager.
///
/// Neither touches the air. The server talks only to the bridge's local pipe,
/// and the bridge stays the single writer to Cinegy.
/// </summary>
internal sealed partial class WebHost : IDisposable
{
    public const int DefaultPort = 8790;
    public const string SettingName = "WebAccessEnabled";

    private readonly string _bridgeRoot;
    private readonly object _gate = new();
    private Process? _server;
    private Process? _tunnel;

    public WebHost(string bridgeRoot) => _bridgeRoot = bridgeRoot;

    /// <summary>Raised on any change worth redrawing; may come from a background thread.</summary>
    public event Action? Changed;

    public int Port { get; set; } = DefaultPort;
    public string TunnelUrl { get; private set; } = "";
    public string LastProblem { get; private set; } = "";
    public bool ServerRunning => _server is { HasExited: false };
    public bool TunnelRunning => _tunnel is { HasExited: false };
    public string LocalUrl => $"http://localhost:{Port}/";

    private string LogDirectory => Path.Combine(_bridgeRoot, "logs", "web");

    // ---------------------------------------------------------------- server

    public bool StartServer()
    {
        lock (_gate)
        {
            if (ServerRunning) return true;
            var exe = ResolveServerPath(_bridgeRoot, AppContext.BaseDirectory);
            if (exe is null)
            {
                Problem("لم يُعثر على CinegyBridge.Web.exe. ابنِه بـ scripts\\Build-BridgeWeb.ps1 (يضعه في dist\\web).");
                return false;
            }
            var psi = Quiet(exe);
            psi.WorkingDirectory = Path.GetDirectoryName(exe)!;
            psi.ArgumentList.Add("--BridgeRoot");
            psi.ArgumentList.Add(_bridgeRoot);
            psi.ArgumentList.Add("--Port");
            psi.ArgumentList.Add(Port.ToString(System.Globalization.CultureInfo.InvariantCulture));
            _server = Launch(psi, "web.log", line => { });
            if (_server is null) return false;
            LastProblem = "";
            Changed?.Invoke();
            return true;
        }
    }

    public void StopServer()
    {
        // The tunnel without its server only returns errors to whoever opens the link.
        StopTunnel();
        lock (_gate) { Stop(ref _server); }
        Changed?.Invoke();
    }

    // ---------------------------------------------------------------- tunnel

    public bool StartTunnel()
    {
        lock (_gate)
        {
            if (TunnelRunning) return true;
            if (!ServerRunning)
            {
                Problem("شغّل خادم الويب أولًا: النفق يوصل إليه.");
                return false;
            }
            var exe = ResolveCloudflared(_bridgeRoot);
            if (exe is null)
            {
                Problem("cloudflared غير مثبّت. ثبّته بالأمر: winget install --id Cloudflare.cloudflared ثم أعد المحاولة.");
                return false;
            }
            TunnelUrl = "";
            var psi = Quiet(exe);
            psi.ArgumentList.Add("tunnel");
            psi.ArgumentList.Add("--no-autoupdate");
            psi.ArgumentList.Add("--url");
            psi.ArgumentList.Add($"http://localhost:{Port}");
            _tunnel = Launch(psi, "tunnel.log", line =>
            {
                // cloudflared announces the quick tunnel's address once, in its log.
                if (TunnelUrl.Length == 0 && ParseTunnelUrl(line) is { } url)
                {
                    TunnelUrl = url;
                    Changed?.Invoke();
                }
            });
            if (_tunnel is null) return false;
            LastProblem = "";
            Changed?.Invoke();
            return true;
        }
    }

    public void StopTunnel()
    {
        lock (_gate)
        {
            Stop(ref _tunnel);
            TunnelUrl = "";
        }
        Changed?.Invoke();
    }

    public void Dispose()
    {
        StopTunnel();
        lock (_gate) { Stop(ref _server); }
    }

    // ------------------------------------------------- the bridge's setting

    /// <summary>Whether the bridge opens its web channel - read from config.json.</summary>
    public static bool ReadBridgeSetting(string configPath)
    {
        try
        {
            var root = JsonNode.Parse(File.ReadAllText(configPath));
            return root?["Settings"]?[SettingName]?.GetValue<bool>() == true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or InvalidOperationException)
        {
            return false;
        }
    }

    /// <summary>The JSON with the setting changed and nothing else touched.</summary>
    internal static string WithBridgeSetting(string json, bool enabled)
    {
        var root = JsonNode.Parse(json) as JsonObject ?? throw new InvalidDataException("config.json is not a JSON object.");
        if (root["Settings"] is not JsonObject settings)
        {
            settings = new JsonObject();
            root["Settings"] = settings;
        }
        settings[SettingName] = enabled;
        return root.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true });
    }

    // ----------------------------------------------------------------- pure

    [GeneratedRegex(@"https://[a-z0-9-]+\.trycloudflare\.com", RegexOptions.IgnoreCase)]
    private static partial Regex QuickTunnelUrl();

    internal static string? ParseTunnelUrl(string line)
    {
        var match = QuickTunnelUrl().Match(line);
        // cloudflared also prints its own api.trycloudflare.com endpoint.
        return match.Success && !match.Value.StartsWith("https://api.", StringComparison.OrdinalIgnoreCase) ? match.Value : null;
    }

    internal static string? ResolveServerPath(string bridgeRoot, string managerDirectory)
    {
        foreach (var candidate in new[]
        {
            Path.Combine(bridgeRoot, "dist", "web", "CinegyBridge.Web.exe"),
            Path.Combine(managerDirectory, "web", "CinegyBridge.Web.exe"),
        })
        {
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    internal static string? ResolveCloudflared(string bridgeRoot)
    {
        var local = Path.Combine(bridgeRoot, "tools", "cloudflared.exe");
        if (File.Exists(local)) return local;
        foreach (var folder in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(folder.Trim(), "cloudflared.exe");
            if (File.Exists(candidate)) return candidate;
        }
        // winget installs here without always reaching an already-open PATH.
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var installed = Path.Combine(programFiles, "cloudflared", "cloudflared.exe");
        return File.Exists(installed) ? installed : null;
    }

    // -------------------------------------------------------------- helpers

    private static ProcessStartInfo Quiet(string exe) => new(exe)
    {
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        StandardOutputEncoding = Encoding.UTF8,
        StandardErrorEncoding = Encoding.UTF8,
    };

    private Process? Launch(ProcessStartInfo psi, string logName, Action<string> onLine)
    {
        Directory.CreateDirectory(LogDirectory);
        var log = new StreamWriter(Path.Combine(LogDirectory, logName), append: true, new UTF8Encoding(false)) { AutoFlush = true };
        log.WriteLine($"--- {DateTime.Now:yyyy-MM-dd HH:mm:ss} start: {Path.GetFileName(psi.FileName)} ---");
        var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        // Output can still drain after Exited fires; a closed log ignores it.
        var closed = false;
        void Record(string? line)
        {
            if (line is null) return;
            lock (log)
            {
                if (closed) return;
                log.WriteLine(line);
            }
            onLine(line);
        }
        process.OutputDataReceived += (_, e) => Record(e.Data);
        process.ErrorDataReceived += (_, e) => Record(e.Data);
        process.Exited += (_, _) =>
        {
            lock (log)
            {
                log.WriteLine($"--- {DateTime.Now:yyyy-MM-dd HH:mm:ss} exit ---");
                closed = true;
                log.Dispose();
            }
            Changed?.Invoke();
        };
        try
        {
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            return process;
        }
        catch (System.ComponentModel.Win32Exception exception)
        {
            log.Dispose();
            process.Dispose();
            Problem($"تعذّر تشغيل {Path.GetFileName(psi.FileName)}: {exception.Message}");
            return null;
        }
    }

    private static void Stop(ref Process? process)
    {
        if (process is null) return;
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5000);
            }
        }
        catch (InvalidOperationException) { /* already gone */ }
        finally
        {
            process.Dispose();
            process = null;
        }
    }

    private void Problem(string message)
    {
        LastProblem = message;
        Changed?.Invoke();
    }
}
