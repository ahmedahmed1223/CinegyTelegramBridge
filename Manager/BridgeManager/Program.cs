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

    /// <summary>What identifies one recurring fault, for the purpose of not
    /// reporting it twice a second.</summary>
    /// <remarks>
    /// Type and message, not the stack: the same fault thrown from the same
    /// timer carries the same pair every time, while a stack string would make
    /// two identical faults look different whenever the frames differ.
    /// </remarks>
    internal static string CrashSignature(Exception? ex) =>
        ex is null ? "(null)" : $"{ex.GetType().FullName}: {ex.Message}";

    /// <summary>
    /// Whether this fault has earned a dialog, or has already had one.
    /// </summary>
    /// <remarks>
    /// The manager's clock timer ticks once a second. A fault inside it is
    /// caught, reported, and thrown again on the next tick - so an unguarded
    /// reporter puts one modal dialog on screen per second, faster than an
    /// operator can dismiss them, and the window they were using to supervise
    /// a live bridge becomes unusable. The bridge itself is fine throughout,
    /// which is the cruel part.
    ///
    /// So the first of a fault is shown, and repeats of the same fault go to
    /// the log and nowhere else until the window has passed. The log keeps
    /// every occurrence either way - the count is what says a fault is a storm
    /// rather than a one-off.
    /// </remarks>
    internal static bool ShouldShowCrashDialog(
        string signature,
        DateTime now,
        IDictionary<string, DateTime> lastShown,
        TimeSpan window)
    {
        if (lastShown.TryGetValue(signature, out var previous) && now - previous < window)
        {
            return false;
        }
        lastShown[signature] = now;
        return true;
    }

    private static readonly Dictionary<string, DateTime> CrashDialogsShown = new();
    private static readonly TimeSpan CrashDialogWindow = TimeSpan.FromMinutes(10);

    private static void ReportCrash(Exception? ex)
    {
        // Logged first and always: the file is the record, and a fault whose
        // dialog is suppressed must still be countable afterwards.
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "BridgeManager-crash.log");
            File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {ex}{Environment.NewLine}{Environment.NewLine}");
        }
        catch { /* best effort - do not let logging the crash cause another one */ }

        if (!ShouldShowCrashDialog(CrashSignature(ex), DateTime.UtcNow, CrashDialogsShown, CrashDialogWindow))
        {
            return;
        }

        MessageBox.Show(
            $"حدث خطأ غير متوقع في واجهة المدير:\n{ex?.Message}\n\nالتفاصيل في BridgeManager-crash.log بجانب البرنامج.\nإن تكرر الخطأ فلن يُعاد فتح هذه النافذة، ويبقى التسجيل في الملف.\nالجسر نفسه (إن كان يعمل) لم يتأثر ويستمر بالعمل.",
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

        // --- starting the bridge by itself is opt-in ------------------------
        // A bridge that comes up on its own is a decision about the air. It is
        // made once, deliberately, and must never be inherited from a default -
        // which is also why the toggles beside it were moved into the settings
        // file in the first place, after auto-restart kept turning itself back on.
        Check("the bridge does not start itself unless asked", new ManagerSettings().StartBridgeOnOpen == false);
        Check("the choice survives a round trip through the settings file",
            System.Text.Json.JsonSerializer.Deserialize<ManagerSettings>(
                System.Text.Json.JsonSerializer.Serialize(new ManagerSettings { StartBridgeOnOpen = true }))!.StartBridgeOnOpen);

        // --- the bridge-managed list guard ---------------------------------
        Check("managed edit while running needs a restart",
            SettingsForm.NeedsRestartToPersist(true, new[] { "AdminUserIds" }));
        Check("managed edit while stopped is safe",
            !SettingsForm.NeedsRestartToPersist(false, new[] { "AdminUserIds" }));
        Check("OwnerUserIds is not bridge-managed",
            !SettingsForm.NeedsRestartToPersist(true, new[] { "OwnerUserIds" }));
        Check("no edit needs nothing", !SettingsForm.NeedsRestartToPersist(true, Array.Empty<string>()));
        Check("editing managers preserves the implicit owner and existing order",
            SettingsForm.OrderRoleIds(new long[] { 900, 100 }, new long[] { 100, 500, 900 }).SequenceEqual(new long[] { 900, 100, 500 }));
        Check("removed accounts do not return when preserving order",
            SettingsForm.OrderRoleIds(new long[] { 900, 100 }, new long[] { 100, 500 }).SequenceEqual(new long[] { 100, 500 }));
        Check("declining restart cannot save transient permissions",
            SettingsForm.ResolveRestartChoice(DialogResult.No) is null);
        Check("accepting restart permits a persistent permission save",
            SettingsForm.ResolveRestartChoice(DialogResult.Yes) == true);
        Check("an explicit owner wins over the first administrator",
            SettingsForm.EffectiveOwners(new long[] { 500 }, new long[] { 900, 100 }, new long[] { 200 }).SequenceEqual(new long[] { 500 }));
        Check("the first positive admin chat is owner only when no user admin exists",
            SettingsForm.EffectiveOwners(Array.Empty<long>(), Array.Empty<long>(), new long[] { -100, 900, 200 }).SequenceEqual(new long[] { 900 }));
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

        // --- the on-air window ------------------------------------------------
        var onAirJson = "{\"Scenes\":[{\"Layer\":9,\"Key\":\"logo\",\"At\":\"09/11/2026 15:50:04\",\"UserId\":122238225,\"Source\":\"bridge\"},{\"Layer\":8,\"Key\":\"News-Ticker\",\"At\":\"09/11/2026 15:50:11\",\"UserId\":0,\"Source\":\"cinegy\"}]}";
        var onAirRows = OnAirForm.ParseOnAirRows(onAirJson);
        Check("reads every tracked scene", onAirRows.Count == 2);
        Check("keeps the layer with its key",
            onAirRows.Exists(r => r.Layer == 9 && r.Key == "logo"));
        Check("reads the stamp as month-first",
            onAirRows[0].AtLocal is DateTime at && at.Month == 9 && at.Day == 11 && at.Hour == 15);
        foreach (var invalidState in new string?[] { null, "{\"Scenes\":[{", "{}", "{\"Scenes\":[{\"Key\":\"logo\"}]}" })
        {
            var unavailable = false;
            try { OnAirForm.ParseOnAirRows(invalidState); }
            catch (InvalidDataException) { unavailable = true; }
            Check("unavailable or malformed state cannot claim a clear output", unavailable);
        }
        Check("a valid empty state can report no tracked scenes", OnAirForm.ParseOnAirRows("{\"Scenes\":[]}").Count == 0);
        var heartbeatNow = new DateTime(2026, 9, 24, 12, 0, 0, DateTimeKind.Utc);
        Check("an old heartbeat cannot certify the on-air record", !OnAirForm.IsHeartbeatFresh(heartbeatNow.AddMinutes(-6), heartbeatNow));
        Check("a missing heartbeat cannot certify the on-air record", !OnAirForm.IsHeartbeatFresh(null, heartbeatNow));
        Check("a current heartbeat permits a current-record caption", OnAirForm.IsHeartbeatFresh(heartbeatNow.AddSeconds(-30), heartbeatNow));
        Check("failed reads visibly identify retained data", OnAirForm.ReadStatusText(false, heartbeatNow, null, heartbeatNow).Contains("آخر سجل"));
        Check("reads numbers written as JSON numbers",
            OnAirForm.ParseOnAirRows("{\"Scenes\":[{\"Layer\":9,\"Key\":\"logo\",\"UserId\":122238225}]}")[0].UserId == 122238225);
        Check("reads numbers written as JSON strings",
            OnAirForm.ParseOnAirRows("{\"Scenes\":[{\"Layer\":\"9\",\"Key\":\"logo\",\"UserId\":\"122238225\"}]}")[0].Layer == 9);
        Check("reads the AirCopy when present",
            OnAirForm.ParseOnAirRows("{\"Scenes\":[{\"Layer\":9,\"Key\":\"logo\",\"AirCopy\":\"عاجل الآن\"}]}")[0].AirCopy == "عاجل الآن");
        Check("treats a missing AirCopy as blank",
            OnAirForm.ParseOnAirRows("{\"Scenes\":[{\"Layer\":9,\"Key\":\"logo\"}]}")[0].AirCopy == "");
        Check("a blank stamp is no stamp", OnAirForm.ParseOnAirStamp("  ") is null);

        var templateNames = OnAirForm.ReadTemplateNames("{\"Urgent\":{\"description\":\"عاجل متحرك\"},\"logo\":{}}");
        Check("a description stands in for its key", templateNames["Urgent"] == "عاجل متحرك");
        Check("a key without a description stands in for itself", templateNames["logo"] == "logo");

        var layerNames = OnAirForm.ReadLayerNames("7=عاجل;8=شريط الأخبار;abc;9=");
        Check("reads layer nicknames", layerNames.Count == 2 && layerNames[7] == "عاجل");
        Check("an empty setting names nothing", OnAirForm.ReadLayerNames("").Count == 0);

        var aliases = new Dictionary<string, string> { ["122238225"] = "أحمد" };
        Check("an alias stands in for its id", OnAirForm.ResolveActor(122238225, aliases) == "أحمد");
        Check("an unknown publisher stays numeric", OnAirForm.ResolveActor(999, aliases) == "999");
        Check("reads the alias file",
            OnAirForm.ReadAliases("{\"7275359265\":\"ابو حسام\"}")["7275359265"] == "ابو حسام");
        Check("a torn alias file means raw ids", OnAirForm.ReadAliases("{oops").Count == 0);

        // One noun, four numbers: the rule behind every corrected screen line.
        Check("one takes the singular", MainForm.ArabicCountWord(1, "خطأ", "خطآن", "أخطاء", "خطأً") == "خطأ");
        Check("two takes the dual", MainForm.ArabicCountWord(2, "خطأ", "خطآن", "أخطاء", "خطأً") == "خطآن");
        Check("three-to-ten takes the plural", MainForm.ArabicCountWord(5, "دقيقة", "دقيقتان", "دقائق", "دقيقة") == "دقائق");
        Check("eleven and up takes the singular again", MainForm.ArabicCountWord(11, "ساعة", "ساعتان", "ساعات", "ساعة") == "ساعة");
        Check("zero takes the singular", MainForm.ArabicCountWord(0, "رسالة", "رسالتان", "رسائل", "رسالة") == "رسالة");

        // --- the reports window -----------------------------------------------
        var usage = ReportsForm.ParseUsageFile("{\"urgent\":{\"Count\":10,\"LastUsedUtc\":\"2026-09-12T08:37:11.185Z\"},\"logo\":{\"Count\":5}}");
        Check("ranks templates most-published first",
            usage.Count == 2 && usage[0].Key == "urgent" && usage[0].Count == 10);
        Check("a torn usage file is an empty report, not an error",
            ReportsForm.ParseUsageFile("{oops").Count == 0);

        var bars = ReportsForm.BuildUsageBars(usage, key => key);
        Check("the leader fills its bar", bars.Count == 2 && bars[0].Fraction == 1.0);
        Check("the rest scale against the leader", bars[1].Fraction == 0.5);
        Check("no usage is no bars", ReportsForm.BuildUsageBars(new List<ReportsForm.TemplateUsage>(), key => key).Count == 0);

        using (var auditChart = new BarChart())
        {
            auditChart.SetData(new[] { new BarChart.Bar("Urgent", "10 times", 1), new BarChart.Bar("Logo", "5 times", .5) });
            Check("assistive readers receive report labels and values", auditChart.AccessibleDescription!.Contains("Urgent") && auditChart.AccessibleDescription.Contains("5 times"));
            auditChart.SetData(Enumerable.Range(0, 8).Select(i => new BarChart.Bar("Row " + i, "1", 1)).ToArray());
            Check("eight report bars reserve enough scrollable height", auditChart.Height >= 448);
        }
        static double Luminance(Color c)
        {
            static double Linear(byte x) { var v = x / 255.0; return v <= .04045 ? v / 12.92 : Math.Pow((v + .055) / 1.055, 2.4); }
            return .2126 * Linear(c.R) + .7152 * Linear(c.G) + .0722 * Linear(c.B);
        }
        foreach (var dark in new[] { false, true })
        {
            Theme.SetMode(dark);
            foreach (var fill in new Func<Color>[] { () => Theme.Running, () => Theme.Stopped, () => Theme.Pending, () => Theme.Accent })
            {
                using var auditButton = Theme.PrimaryButton("Test", fill);
                foreach (var background in new[] { auditButton.BackColor, auditButton.FlatAppearance.MouseOverBackColor, auditButton.FlatAppearance.MouseDownBackColor })
                {
                    var a = Luminance(auditButton.ForeColor); var b = Luminance(background);
                    Check("primary labels remain readable in each palette and pointer state", (Math.Max(a, b) + .05) / (Math.Min(a, b) + .05) >= 4.5);
                }
            }
        }
        Theme.SetMode(false);
        var reportErrorCount = 1;
        var reportFixture = Path.Combine(Path.GetTempPath(), "BridgeManager-report-" + Guid.NewGuid().ToString("N"));
        using (var liveReport = new ReportsForm(reportFixture, () => reportErrorCount))
        {
            var reloadReport = typeof(ReportsForm).GetMethod("Reload", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!;
            var reportValue = (Label)typeof(ReportsForm).GetField("_errorsValue", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(liveReport)!;
            reloadReport.Invoke(liveReport, null);
            Check("report refresh reads the current error count", reportValue.Text == "1");
            reportErrorCount = 4;
            reloadReport.Invoke(liveReport, null);
            Check("report refresh includes new errors without reopening", reportValue.Text == "4");
            reportErrorCount = 0;
            reloadReport.Invoke(liveReport, null);
            Check("report refresh clears errors after they age out", reportValue.Text == "0");
        }

        var today = new DateTime(2026, 9, 12);
        var logLines = new[]
        {
            "2026-09-12 08:00:01 [Manager] تم بدء تشغيل الجسر بنجاح.",
            "2026-09-12 09:00:01 [Manager] توقف الجسر - رمز الخروج 1.",
            "2026-09-12 09:00:02 [Manager] إيقاف يدوي.",
            "2026-09-12 10:00:01 [Manager] كشف تعليق: لا نبضة منذ 6 دقيقة - إعادة تشغيل تلقائية.",
            "2026-09-12 10:00:02 [Manager] توقف متكرر (5 مرات) - تم إيقاف إعادة التشغيل التلقائي.",
            "2026-09-11 08:00:01 [Manager] تم بدء تشغيل الجسر بنجاح."
        };
        var stability = ReportsForm.SummarizeManagerLog(logLines, today);
        Check("counts only today's starts", stability.Starts == 1);
        Check("counts manual stops", stability.ManualStops == 1);
        Check("counts watchdog restarts", stability.WatchdogRestarts == 1);
        Check("counts crash-loop give-ups", stability.GiveUps == 1);

        var health = ReportsForm.ParseHealthSnapshot(
            "{\"GeneratedUtc\":\"2026-09-13T17:00:00Z\",\"Rows\":[{\"Name\":\"Telegram\",\"Icon\":\"🟢\",\"Detail\":\"متصل\"},{\"Name\":\"Cinegy\",\"Icon\":\"🔴\",\"Detail\":\"غير سليم\"}]}");
        Check("reads every live health row", health.Rows.Count == 2 && health.Rows[1].Name == "Cinegy" && health.Rows[1].Icon == "🔴");
        Check("reads the snapshot timestamp", health.GeneratedUtc == new DateTime(2026, 9, 13, 17, 0, 0, DateTimeKind.Utc));
        Check("a missing snapshot file is an empty report, not an error", ReportsForm.ParseHealthSnapshot(null).Rows.Count == 0);
        Check("a torn snapshot file is an empty report, not an error", ReportsForm.ParseHealthSnapshot("{oops").Rows.Count == 0);

        // A fault inside the one-second clock timer is caught, reported, and
        // thrown again on the next tick. Unguarded, that is one modal dialog
        // per second - faster than an operator can dismiss them - while the
        // bridge it was supervising runs on perfectly well.
        var shown = new Dictionary<string, DateTime>();
        var t0 = new DateTime(2026, 9, 7, 14, 0, 0, DateTimeKind.Utc);
        var window = TimeSpan.FromMinutes(10);
        Check("the first of a fault is shown",
            Program.ShouldShowCrashDialog("A: boom", t0, shown, window));
        Check("the same fault a second later is not",
            !Program.ShouldShowCrashDialog("A: boom", t0.AddSeconds(1), shown, window));
        Check("nor sixty ticks later",
            !Program.ShouldShowCrashDialog("A: boom", t0.AddSeconds(60), shown, window));
        Check("a different fault is still shown",
            Program.ShouldShowCrashDialog("B: other", t0.AddSeconds(2), shown, window));
        Check("the same fault is shown again once the window has passed",
            Program.ShouldShowCrashDialog("A: boom", t0.AddMinutes(11), shown, window));
        Check("two faults of one type but different messages are two faults",
            Program.CrashSignature(new InvalidOperationException("x")) != Program.CrashSignature(new InvalidOperationException("y")));
        Check("a null exception has a signature rather than throwing",
            Program.CrashSignature(null) == "(null)");

        // A stop nobody asked for, with nobody coming to restart it and the
        // window hidden, is the one stop that must knock.
        Check("a silent stop with no auto-restart knocks",
            MainForm.ShouldNotifyUnexpectedExit(false, false, false, false));
        Check("a manual stop does not",
            !MainForm.ShouldNotifyUnexpectedExit(true, false, false, false));
        Check("a restart in flight does not",
            !MainForm.ShouldNotifyUnexpectedExit(false, true, false, false));
        Check("an auto-restarted stop does not",
            !MainForm.ShouldNotifyUnexpectedExit(false, false, true, false));
        Check("closing down does not",
            !MainForm.ShouldNotifyUnexpectedExit(false, false, false, true));

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
        Check("caps one UI drain so a log burst cannot monopolise the message loop",
            MainForm.GetPendingDrainPlan(pendingCount: 9000).ProcessNow < 9000);
        // The alarms this program raises about itself are Manager lines, and
        // the errors-only filter hid every one of them: a failed launch, the
        // give-up after five crashes, the hang restart. A launch that fails
        // before pwsh writes anything produces no [ERROR] line either, so the
        // pane said "لا أخطاء ولا تحذيرات - وهذا هو المطلوب" while the bridge
        // was dead and auto-restart was off. These fail before the fix.
        Check("shows the give-up notice under errors-only",
            MainForm.ShouldShow("--- توقف 5 مرات متتالية خلال ثوانٍ - تم إيقاف إعادة التشغيل التلقائي. ---", "", true));
        Check("shows a failed launch under errors-only",
            MainForm.ShouldShow("--- فشل بدء التشغيل: pwsh غير موجود ---", "", true));
        Check("shows the hang restart under errors-only",
            MainForm.ShouldShow("--- الجسر يعمل لكنه توقف عن النبض منذ 7 دقيقة - يُعاد تشغيله. ---", "", true));
        Check("still hides ordinary bridge chatter under errors-only",
            MainForm.ShouldShow("2026-09-21 10:00:00 [INFO] Bridge starting", "", true) == false);
        Check("keeps errors and warnings visible under errors-only",
            MainForm.ShouldShow("2026-09-21 10:00:00 [ERROR] boom", "", true)
            && MainForm.ShouldShow("2026-09-21 10:00:00 [WARN] careful", "", true));
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

        // The status bar used to open the heartbeat file on every tick - ten
        // reads a second during a burst, against a writer that holds it once
        // per poll loop. Now it re-reads at most every fifteen seconds; the
        // thirty-second watchdog keeps its own direct read.
        var readAt = new DateTime(2026, 9, 12, 12, 0, 0, DateTimeKind.Utc);
        Check("a heartbeat never read is read at once",
            MainForm.ShouldRefreshLivenessCache(DateTime.MinValue, readAt));
        Check("a five-second-old reading is reused",
            !MainForm.ShouldRefreshLivenessCache(readAt, readAt.AddSeconds(5)));
        Check("a fifteen-second-old reading is refreshed",
            MainForm.ShouldRefreshLivenessCache(readAt, readAt.AddSeconds(15)));
        Check("an hour-old reading is refreshed",
            MainForm.ShouldRefreshLivenessCache(readAt, readAt.AddHours(1)));

        // A persisted zoom from a hand-edited settings file must still land
        // somewhere sane, and tenth-steps must not drift off the notches.
        Check("zoom below half clamps to half", MainForm.ClampZoom(0.1f) == 0.5f);
        Check("zoom above triple clamps to triple", MainForm.ClampZoom(10f) == 3f);
        Check("a whole zoom passes through", MainForm.ClampZoom(1f) == 1f);
        Check("a step rounds to one decimal", MainForm.ClampZoom(1.26f) == 1.3f);

        // The header reads the version on disk beside the version on air.
        Check("reads the on-disk bridge version",
            MainForm.ParseBridgeScriptVersion("$script:BridgeVersion = '8.25.0'") == "8.25.0");
        Check("a script without the version line has none",
            MainForm.ParseBridgeScriptVersion("Write-Host 'hi'") is null);
        Check("an empty file has none", MainForm.ParseBridgeScriptVersion("") is null);

        // The status bar keeps the folder name; the tooltip keeps the path.
        Check("shortens a deep bridge path to its folder",
            MainForm.ShortBridgeRoot(@"D:\cingy cg\CinegyTelegramBridge") == "CinegyTelegramBridge");

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
        // The activity line: the manager reads the bridge's own AIR_OP record,
        // whose shape is fixed by Write-AirOperationResult.
        Check("reads an air operation into one readable line",
            MainForm.ParseAirActivity("2026-09-08 14:22:31 [INFO] AIR_OP id=air-1 action=SHOW result=success durationMs=9 user=7 chat=7 layer=7 target=\"Urgent\"")
                == "✅ عرض «Urgent» — 14:22");
        Check("marks a refused operation as refused",
            (MainForm.ParseAirActivity("2026-09-08 14:22:31 [WARN] AIR_OP id=air-2 action=HIDE result=blocked durationMs=9 user=7 chat=7 layer=4 target=\"\"") ?? "").StartsWith("⛔ إخفاء"));
        Check("an ordinary line is not an air operation", MainForm.ParseAirActivity("2026-09-08 14:22:31 [INFO] Bridge v8.5.0 starting.") is null);
        Check("earlier information remains before a later warning", !MainForm.PriorityComesFirst(2, 1));
        Check("earlier warning remains before later information", MainForm.PriorityComesFirst(1, 2));
        Check("priority queue drains when information is empty", MainForm.PriorityComesFirst(1, null));
        var stopRefused = false;
        try { SettingsForm.VerifyStoppedForSaveAsync(true, () => Task.FromResult(false)).GetAwaiter().GetResult(); }
        catch (IOException) { stopRefused = true; }
        Check("save and restart refuses an unverified stop", stopRefused);
        var stopCalls = 0;
        SettingsForm.VerifyStoppedForSaveAsync(false, () => { stopCalls++; return Task.FromResult(true); }).GetAwaiter().GetResult();
        Check("ordinary save does not stop the bridge", stopCalls == 0);
        SettingsForm.VerifyStoppedForSaveAsync(true, () => { stopCalls++; return Task.FromResult(true); }).GetAwaiter().GetResult();
        Check("save and restart verifies stop before proceeding", stopCalls == 1);
        var stopCompletion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pendingSave = SettingsForm.VerifyStoppedForSaveAsync(true, () => stopCompletion.Task);
        Check("waiting for a stop yields to the UI instead of finishing the save", !pendingSave.IsCompleted);
        stopCompletion.SetResult(false);
        var delayedStopRefused = false;
        try { pendingSave.GetAwaiter().GetResult(); } catch (IOException) { delayedStopRefused = true; }
        Check("an asynchronous stop failure still prevents writing", delayedStopRefused);
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
