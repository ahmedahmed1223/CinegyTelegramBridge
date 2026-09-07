using System.Security.AccessControl;
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
        Check("an untouched manager field preserves a newer disk value",
            !SettingsForm.ShouldWriteLoadedValue("127.0.0.1", "127.0.0.1"));
        Check("an edited manager field replaces its loaded value",
            SettingsForm.ShouldWriteLoadedValue("127.0.0.1", "10.0.0.5"));

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

        // --- the heartbeat file, which adoption reads -----------------------
        // Set-Content writes CRLF on Windows, so every one of these arrives
        // with a carriage return the parser has to shed. A pid left as "25884\r"
        // is the difference between adopting a running bridge and telling the
        // operator it is stopped while it is on air.
        var (crlfStamp, crlfPid) = MainForm.ParseLiveness("2026-09-06T14:54:41.9006845Z\r\n25884\r\n");
        Check("reads the stamp past a carriage return", crlfStamp is not null);
        Check("reads the pid past a carriage return", crlfPid == 25884);
        Check("keeps the stamp in UTC", crlfStamp is not null && crlfStamp.Value.Kind == DateTimeKind.Utc);

        var (oldStamp, oldPid) = MainForm.ParseLiveness("2026-09-06T14:54:41.9006845Z\r\n");
        Check("still reads a single-line file from an older bridge", oldStamp is not null);
        Check("reports no pid when the older bridge wrote none", oldPid is null);

        Check("an empty file yields nothing", MainForm.ParseLiveness("").Pid is null);
        Check("null content yields nothing", MainForm.ParseLiveness(null).Stamp is null);
        Check("junk on the stamp line is not a stamp", MainForm.ParseLiveness("not-a-date\r\n25884").Stamp is null);
        Check("junk on the pid line is not a pid", MainForm.ParseLiveness("2026-09-06T14:54:41Z\r\nabc").Pid is null);
        Check("a zero pid is refused", MainForm.ParseLiveness("2026-09-06T14:54:41Z\r\n0").Pid is null);
        Check("a negative pid is refused", MainForm.ParseLiveness("2026-09-06T14:54:41Z\r\n-7").Pid is null);
        Check("a pid still parses when the stamp does not",
            MainForm.ParseLiveness("garbage\r\n25884").Pid == 25884);

        // --- following an adopted bridge's log ------------------------------
        var whole = MainForm.SplitCompleteLines("first\nsecond\n", out var noRemainder);
        Check("returns every complete line", whole.SequenceEqual(new[] { "first", "second" }));
        Check("leaves nothing over when the chunk ends on a newline", noRemainder == "");

        // A write caught mid-line: rendering the half now would render it again
        // in full on the next tick.
        var partial = MainForm.SplitCompleteLines("first\nhalf-writ", out var leftover);
        Check("holds back a half-written line", partial.SequenceEqual(new[] { "first" }));
        Check("keeps the half for the next read", leftover == "half-writ");

        Check("a chunk with no newline yields no lines",
            MainForm.SplitCompleteLines("no newline yet", out _).Length == 0);
        Check("an empty chunk yields no lines", MainForm.SplitCompleteLines("", out _).Length == 0);
        Check("strips the carriage return the bridge writes",
            MainForm.SplitCompleteLines("line\r\n", out _).SequenceEqual(new[] { "line" }));
        Check("drops blank lines rather than printing gaps",
            MainForm.SplitCompleteLines("a\n\n\nb\n", out _).SequenceEqual(new[] { "a", "b" }));

        // bridge.log rotates at LogMaxSizeMB; reading on from the old offset
        // would skip the whole beginning of the new file.
        Check("spots a rotated log", MainForm.WasLogRotated(5000, 120));
        Check("a growing log is not a rotated one", !MainForm.WasLogRotated(5000, 9000));
        Check("an unchanged log is not a rotated one", !MainForm.WasLogRotated(5000, 5000));

        // --- what the bridge is connected to --------------------------------
        // "Running" only says the process is alive; a bridge refused by
        // Telegram or unable to reach the Air engine is alive and useless.
        var tg = MainForm.ParseHealthLine("2026-09-06 17:54:23 [INFO] Telegram connection changed from unknown to connected");
        Check("reads a Telegram transition", tg is not null && tg.Value.Kind == "telegram" && tg.Value.State == "connected");
        var cg = MainForm.ParseHealthLine("2026-09-06 17:54:26 [INFO] Cinegy health changed from unknown to healthy");
        Check("reads a Cinegy transition", cg is not null && cg.Value.Kind == "cinegy" && cg.Value.State == "healthy");
        var lost = MainForm.ParseHealthLine("2026-09-06 04:11:00 [WARN] Telegram connection changed from connected to disconnected");
        Check("reads the transition's destination, not its origin", lost is not null && lost.Value.State == "disconnected");
        Check("an ordinary line is not a health line",
            MainForm.ParseHealthLine("2026-09-06 17:54:07 [INFO] Bridge v7.68.0 starting.") is null);
        Check("an empty line is not a health line", MainForm.ParseHealthLine("") is null);

        Check("connected reads as healthy", MainForm.IsHealthyState("connected"));
        Check("healthy reads as healthy", MainForm.IsHealthyState("healthy"));
        Check("unknown is neither healthy nor faulted",
            !MainForm.IsHealthyState("unknown") && !MainForm.IsFaultedState("unknown"));
        Check("disconnected reads as faulted", MainForm.IsFaultedState("disconnected"));
        Check("unhealthy reads as faulted", MainForm.IsFaultedState("unhealthy"));
        Check("names the state in Arabic", MainForm.HealthText("telegram", "connected") == "تيليجرام: متصل");
        Check("keeps Cinegy's own name", MainForm.HealthText("cinegy", "healthy") == "Cinegy: سليم");
        Check("shows a dash rather than the word unknown", MainForm.HealthText("cinegy", "unknown") == "Cinegy: —");

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

        // The manager carries the major version only and the bridge ships
        // several times a day, so the status bar names both rather than
        // printing one number that gets read as the other.
        Check("reads the bridge version off its startup line",
            MainForm.ParseBridgeVersion("2026-09-07 09:00:01 [INFO] Bridge v7.76.0 starting. Air 127.0.0.1:5521, templates: 4")
                == "7.76.0");
        Check("ignores an ordinary log line", MainForm.ParseBridgeVersion("2026-09-07 09:00:02 [INFO] Telegram connected") is null);
        Check("ignores a line that only mentions a version",
            MainForm.ParseBridgeVersion("2026-09-07 09:00:02 [INFO] manager v7 attached to Bridge v7.76.0") is null);
        Check("survives an empty line", MainForm.ParseBridgeVersion("") is null);

        // An empty log pane reads as "the bridge stopped logging" - this
        // window's whole job is to say otherwise, so no path may leave it
        // blank without a sentence naming why and the way out.
        Check("nothing is said while there are lines on screen",
            MainForm.EmptyStateMessage(totalLines: 100, shownLines: 12, filter: "", errorsOnly: false) is null);
        Check("an empty pane before any output says output is still to come",
            MainForm.EmptyStateMessage(0, 0, "", false)?.Contains("فور تشغيله") == true);
        Check("a filter that matches nothing names the filter and Esc",
            MainForm.EmptyStateMessage(1842, 0, "ffmpeg", false) is string m
                && m.Contains("ffmpeg") && m.Contains("1842") && m.Contains("Esc"));
        Check("a clean log under errors-only says so is the point, not a fault",
            MainForm.EmptyStateMessage(1842, 0, "", true)?.Contains("وهذا هو المطلوب") == true);
        Check("both filters together name both ways out",
            MainForm.EmptyStateMessage(1842, 0, "ffmpeg", true) is string both
                && both.Contains("ffmpeg") && both.Contains("Esc") && both.Contains("الأخطاء والتحذيرات"));
        Check("a filter of only spaces counts as no filter",
            MainForm.EmptyStateMessage(1842, 0, "   ", true)?.Contains("وهذا هو المطلوب") == true);
        Check("highlights the operation id without changing the surrounding text",
            MainForm.GetLogHighlights("2026-09-05 [INFO] AIR_OP id=air-a8f9daa3 action=SHOW layer=4 result=success")
                .Any(h => h.Kind == LogHighlightKind.OperationId && h.Text == "air-a8f9daa3"));
        Check("highlights the error-bearing result",
            MainForm.GetLogHighlights("2026-09-05 [ERROR] AIR_OP result=failed error=timeout")
                .Any(h => h.Kind == LogHighlightKind.Failure));
        Check("keeps queued warnings when a long burst must be reduced",
            MainForm.GetPendingDrainPlan(pendingCount: 9000, warningCount: 3, errorCount: 2).KeepWarningAndError);
        Check("caps one UI drain so a log burst cannot monopolise the message loop",
            MainForm.GetPendingDrainPlan(pendingCount: 9000, warningCount: 0, errorCount: 0).ProcessNow < 9000);
        Check("shortens a pathological log line before it reaches the UI buffer",
            MainForm.LimitDisplayedLogLine(new string('x', 9000)).Contains("bridge.log", StringComparison.Ordinal));
        Check("does not classify a token-shaped setting as a colourable log field",
            MainForm.GetLogHighlights("BotToken=123456:AAExampleSecretValue").Count == 0);

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

        // A failed replacement must not leave a second readable copy of credentials.
        var fixture = Path.Combine(Path.GetTempPath(), "BridgeManager-selftest-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(fixture);
        try
        {
            var target = Path.Combine(fixture, "blocked.json");
            Directory.CreateDirectory(target);
            var form = (SettingsForm)System.Runtime.CompilerServices.RuntimeHelpers.GetUninitializedObject(typeof(SettingsForm));
            typeof(SettingsForm).GetField("_configPath", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.SetValue(form, target);
            try
            {
                typeof(SettingsForm).GetMethod("WriteConfigAtomically", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.Invoke(form, new object[] { "{\"fixture\":true}" });
            }
            catch (System.Reflection.TargetInvocationException) { }
            Check("failed config replacement removes the credential staging file", Directory.GetFiles(fixture, "*.tmp").Length == 0);
        }
        finally { Directory.Delete(fixture, recursive: true); }
        Check("earlier information remains before a later warning", !MainForm.PriorityComesFirst(2, 1));
        Check("earlier warning remains before later information", MainForm.PriorityComesFirst(1, 2));
        Check("priority queue drains when information is empty", MainForm.PriorityComesFirst(1, null));
        var stopRefused = false;
        try { SettingsForm.VerifyStoppedForSave(true, () => false); }
        catch (IOException) { stopRefused = true; }
        Check("save and restart refuses an unverified stop", stopRefused);
        var stopCalls = 0;
        SettingsForm.VerifyStoppedForSave(false, () => { stopCalls++; return true; });
        Check("ordinary save does not stop the bridge", stopCalls == 0);
        SettingsForm.VerifyStoppedForSave(true, () => { stopCalls++; return true; });
        Check("save and restart verifies stop before proceeding", stopCalls == 1);
        var testMutexName = "BridgeManager-selftest-" + Guid.NewGuid().ToString("N");
        using var observingWriter = new Mutex(false, testMutexName);
        try { SettingsForm.WithConfigLock(testMutexName, () => throw new IOException("fixture")); }
        catch (IOException) { }
        var lockRecovered = Task.Run(() =>
        {
            using var contender = new Mutex(false, testMutexName);
            var owned = contender.WaitOne(TimeSpan.FromSeconds(2));
            if (owned) contender.ReleaseMutex();
            return owned;
        }).GetAwaiter().GetResult();
        Check("another writer can acquire the lock after a failed save", lockRecovered);
        Directory.CreateDirectory(fixture);
        try
        {
            var path = Path.Combine(fixture, "settings.json");
            File.WriteAllText(path, "original");
            var emptyWhenProtected = false;
            try
            {
                SettingsForm.WriteConfigFile(path, "fixture credentials", staged =>
                {
                    emptyWhenProtected = new FileInfo(staged).Length == 0;
                    throw new UnauthorizedAccessException("fixture");
                });
            }
            catch (UnauthorizedAccessException) { }
            Check("credentials are not written before protection succeeds", emptyWhenProtected);
            Check("ACL failure preserves the existing configuration", File.ReadAllText(path) == "original");
            Check("ACL failure removes the empty staging file", Directory.GetFiles(fixture, "*.tmp").Length == 0);
            SettingsForm.WriteConfigFile(path, "replacement");
            Check("successful save replaces the file and preserves its backup", File.ReadAllText(path) == "replacement" && File.ReadAllText(path + ".bak") == "original");
            Check("configuration and backup have protected ACLs", new FileInfo(path).GetAccessControl().AreAccessRulesProtected && new FileInfo(path + ".bak").GetAccessControl().AreAccessRulesProtected);
        }
        finally { Directory.Delete(fixture, recursive: true); }
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
