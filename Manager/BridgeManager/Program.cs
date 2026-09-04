using System.Text;
using System.Threading;

namespace BridgeManager;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--selftest")
        {
            Environment.Exit(SelfTest.Run() ? 0 : 1);
            return;
        }

        // Written into the Run key by the "start with Windows" checkbox. The
        // registry entry used to restore only the supervisor, so a machine that
        // came back from a power cut showed the manager window over the playout
        // screen with the bridge still stopped - the exact gap the checkbox
        // exists to close.
        var autoStart = args.Any(a => string.Equals(a, MainForm.AutoStartArgument, StringComparison.OrdinalIgnoreCase));

        // Two managers racing to supervise the same bridge process (both
        // reacting to its Exited event, both able to -StopExisting the other's
        // launch) is exactly the kind of instability this app exists to
        // prevent. Global\ rather than a session-local name because the race is
        // just as real between two Windows sessions on one playout box - an RDP
        // login while someone is signed in at the console is the ordinary way
        // it happens.
        Mutex? singleInstance = null;
        var createdNew = false;
        try
        {
            singleInstance = new Mutex(initiallyOwned: true, @"Global\CinegyTelegramBridgeManager-SingleInstance", out createdNew);
        }
        catch (UnauthorizedAccessException)
        {
            // The object exists and belongs to another session, which this
            // account may not open. That is an answer, not a failure: someone
            // else is already supervising.
            createdNew = false;
        }
        catch (Exception)
        {
            // Locked-down policy can refuse global names outright. Fall back to
            // a per-session guard, which is still better than none.
            try { singleInstance = new Mutex(initiallyOwned: true, "CinegyTelegramBridgeManager-SingleInstance", out createdNew); }
            catch { createdNew = true; }
        }

        using (singleInstance)
        {
            if (!createdNew)
            {
                MessageBox.Show(
                    "مدير الجسر يعمل بالفعل - تحقّق من أيقونات شريط النظام بجانب الساعة.\n" +
                    "إن لم تجده هناك فقد يكون يعمل في جلسة ويندوز أخرى على هذا الجهاز.",
                    "يعمل بالفعل", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            // Stability: an unhandled exception in a button click or timer tick
            // would otherwise take the whole supervisor down silently. Log it and
            // keep running instead - the bridge process itself is unaffected
            // either way, but losing the supervisor loses auto-restart/monitoring.
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += (_, e) => ReportCrash(e.Exception);
            AppDomain.CurrentDomain.UnhandledException += (_, e) => ReportCrash(e.ExceptionObject as Exception);

            Application.SetHighDpiMode(HighDpiMode.SystemAware);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm(autoStart));
        }
    }

    private static void ReportCrash(Exception? ex)
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "BridgeManager-crash.log");
            File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {ex}{Environment.NewLine}{Environment.NewLine}");
        }
        catch { /* best effort - do not let logging the crash cause another one */ }

        MessageBox.Show(
            $"حدث خطأ غير متوقع في واجهة المدير:\n{ex?.Message}\n\nالتفاصيل في BridgeManager-crash.log بجانب البرنامج.\nالجسر نفسه (إن كان يعمل) لم يتأثر ويستمر بالعمل.",
            "خطأ غير متوقع", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}

/// <summary>
/// `BridgeManager.exe --selftest`: the branchy, non-trivial text and time logic
/// in this app, checked without a UI or a test framework. Run by
/// scripts/Build-BridgeManager.ps1 after every publish - it used to exist and
/// never run, which is the same as not existing.
///
/// The report goes to a file as well as to stdout because this is a WinExe:
/// there is no console attached, so a failure printed to Console alone would be
/// invisible to whoever has to fix it.
/// </summary>
internal static class SelfTest
{
    public static bool Run()
    {
        var failures = new List<string>();
        var checks = 0;

        void Check(string label, bool ok)
        {
            checks++;
            if (!ok) failures.Add(label);
        }

        // --- DPAPI reference detection -------------------------------------
        Check("spots a dpapi reference", SettingsForm.LooksLikeDpapiReference("dpapi:BotToken"));
        Check("a real token is not a reference", SettingsForm.LooksLikeDpapiReference("123456:AAErandomlookingtokentext") == false);
        Check("null is not a reference", !SettingsForm.LooksLikeDpapiReference(null));

        // --- the bridge-managed list guard ---------------------------------
        Check("managed edit while running needs a restart",
            SettingsForm.NeedsRestartToPersist(true, new[] { "AdminUserIds" }));
        Check("managed edit while stopped is safe",
            !SettingsForm.NeedsRestartToPersist(false, new[] { "AdminUserIds" }));
        Check("OwnerUserIds is not bridge-managed",
            !SettingsForm.NeedsRestartToPersist(true, new[] { "OwnerUserIds" }));
        Check("no edit needs nothing", !SettingsForm.NeedsRestartToPersist(true, Array.Empty<string>()));

        // --- accounts and permissions --------------------------------------
        // All five arrays share one id space: Telegram gives a private chat
        // the same id as the person in it, so one operator legitimately holds
        // several of these at once.
        var noIds = Array.Empty<long>();
        Check("accepts a personal id", SettingsForm.ValidateNewId("122238225", noIds, out var pid) is null && pid == 122238225);
        Check("accepts a group id", SettingsForm.ValidateNewId("-1001234567890", noIds, out _) is null);
        Check("refuses text", SettingsForm.ValidateNewId("abc", noIds, out _) is not null);
        Check("refuses empty", SettingsForm.ValidateNewId("", noIds, out _) is not null);
        Check("refuses zero", SettingsForm.ValidateNewId("0", noIds, out _) is not null);
        Check("trims surrounding spaces",
            SettingsForm.ValidateNewId("  42  ", noIds, out var trimmed) is null && trimmed == 42);
        Check("refuses an id already listed",
            SettingsForm.ValidateNewId("42", new long[] { 42 }, out _) is not null);

        Check("a group cannot be a user-role member",
            !SettingsForm.RoleAppliesTo(-1001234567890, "AdminUserIds"));
        Check("a group can be an admin chat",
            SettingsForm.RoleAppliesTo(-1001234567890, "AdminChatIds"));
        Check("a person can hold every role",
            SettingsForm.Roles.All(r => SettingsForm.RoleAppliesTo(122238225, r.Key)));

        Check("a new group starts as an allowed chat",
            SettingsForm.DefaultRoleFor(-100) == "AllowedChatIds");
        Check("a new person starts as an allowed user",
            SettingsForm.DefaultRoleFor(100) == "AllowedUserIds");

        Check("summarises permissions in canonical order",
            SettingsForm.PermissionSummary(new[] { "AdminUserIds", "AllowedChatIds" })
                == "محادثة مسموحة، مستخدم إداري");
        Check("says so when an account holds nothing",
            SettingsForm.PermissionSummary(Array.Empty<string>()) == "— بلا صلاحيات —");
        Check("labels a negative id a group", SettingsForm.KindLabel(-100) == "مجموعة");
        Check("labels a positive id an account", SettingsForm.KindLabel(100) == "حساب");
        Check("every role has an Arabic label",
            SettingsForm.Roles.All(r => SettingsForm.RoleLabel(r.Key) != r.Key));
        Check("owner is not bridge-managed", !SettingsForm.BridgeManagedKeys.Contains("OwnerUserIds"));
        Check("reads ids and skips junk",
            SettingsForm.ReadIds(System.Text.Json.Nodes.JsonNode.Parse("[1, \"x\", -2]")).SequenceEqual(new long[] { 1, -2 }));
        Check("reads a missing array as empty", SettingsForm.ReadIds(null).Count == 0);

        // --- Run-key command line ------------------------------------------
        Check("extracts a quoted exe with an argument",
            MainForm.ExtractExePath("\"C:\\Bridge\\BridgeManager.exe\" --autostart") == "C:\\Bridge\\BridgeManager.exe");
        Check("extracts a bare exe with no argument",
            MainForm.ExtractExePath("C:\\Bridge\\BridgeManager.exe") == "C:\\Bridge\\BridgeManager.exe");
        Check("extracts a quoted exe with no argument",
            MainForm.ExtractExePath("\"C:\\Program Files\\BridgeManager.exe\"") == "C:\\Program Files\\BridgeManager.exe");

        // --- log line classification / filtering ---------------------------
        Check("an ERROR line is an error", MainForm.ClassifyLine("2026-09-04 14:06:02 [ERROR] Polling error") == LogLineKind.Error);
        Check("a WARN line is a warning", MainForm.ClassifyLine("2026-09-04 14:06:02 [WARN] Long-poll timed out") == LogLineKind.Warning);
        Check("a manager line is its own kind", MainForm.ClassifyLine("--- بدء التشغيل ---") == LogLineKind.Manager);
        Check("an INFO line is normal", MainForm.ClassifyLine("2026-09-04 14:06:02 [INFO] Bridge starting") == LogLineKind.Normal);
        Check("an empty filter shows everything", MainForm.ShouldShow("anything at all", "", false));
        Check("filter matches case-insensitively", MainForm.ShouldShow("2026 [INFO] Bridge starting", "bridge", false));
        Check("filter excludes a non-match", !MainForm.ShouldShow("2026 [INFO] Bridge starting", "ffmpeg", false));
        Check("errors-only hides INFO", !MainForm.ShouldShow("2026 [INFO] fine", "", true));
        Check("errors-only keeps WARN", MainForm.ShouldShow("2026 [WARN] careful", "", true));

        // --- hang detection -------------------------------------------------
        // Measured against this installation's own bridge.log, a healthy bridge
        // is silent for 10-18 hours overnight. These cases are the whole reason
        // the watchdog reads a stamp instead of watching for silence.
        var started = new DateTime(2026, 9, 4, 12, 0, 0, DateTimeKind.Utc);
        var grace = TimeSpan.FromMinutes(3);
        var threshold = TimeSpan.FromMinutes(5);
        Check("a stamp going stale is a hang",
            MainForm.IsHung(started.AddMinutes(4), started, started.AddMinutes(20), grace, threshold));
        Check("a fresh stamp is not a hang",
            !MainForm.IsHung(started.AddMinutes(19), started, started.AddMinutes(20), grace, threshold));
        Check("a booting bridge is never a hang",
            !MainForm.IsHung(null, started, started.AddMinutes(1), grace, threshold));
        Check("a bridge that publishes no stamp is never a hang",
            !MainForm.IsHung(null, started, started.AddHours(9), grace, threshold));
        Check("a stamp from the previous run is never evidence",
            !MainForm.IsHung(started.AddMinutes(-30), started, started.AddHours(9), grace, threshold));

        var report = new StringBuilder();
        report.AppendLine($"{DateTime.Now:yyyy-MM-dd HH:mm:ss} BridgeManager selftest");
        foreach (var f in failures) report.AppendLine($"FAIL: {f}");
        report.AppendLine(failures.Count == 0
            ? $"selftest: all {checks} checks passed"
            : $"selftest: {failures.Count} of {checks} checks FAILED");

        Console.Write(report.ToString());
        try { File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "BridgeManager-selftest.log"), report.ToString()); }
        catch { /* the exit code still carries the verdict */ }

        return failures.Count == 0;
    }
}
