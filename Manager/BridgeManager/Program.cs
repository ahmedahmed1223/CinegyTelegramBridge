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

        // Two managers racing to supervise the same bridge process (both
        // reacting to its Exited event, both able to -StopExisting the other's
        // launch) is exactly the kind of instability this app exists to
        // prevent. A second launch just points at the one already running.
        using var singleInstance = new Mutex(initiallyOwned: true, "CinegyTelegramBridgeManager-SingleInstance", out var createdNew);
        if (!createdNew)
        {
            MessageBox.Show(
                "مدير الجسر يعمل بالفعل - تحقّق من أيقونات شريط النظام بجانب الساعة.",
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
        Application.Run(new MainForm());
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
/// `BridgeManager.exe --selftest`: one runnable check for the id-list
/// parse/format round-trip (branchy, non-trivial text logic) without needing
/// a UI or a test framework.
/// </summary>
internal static class SelfTest
{
    public static bool Run()
    {
        var failures = new List<string>();

        void Check(string label, bool ok)
        {
            if (!ok) failures.Add(label);
        }

        Check("parses comma-separated ids", SettingsForm.ParseIds("111, 222,333").Select(n => (long)n!).SequenceEqual(new long[] { 111, 222, 333 }));
        Check("parses mixed separators", SettingsForm.ParseIds("111 222;333").Select(n => (long)n!).SequenceEqual(new long[] { 111, 222, 333 }));
        Check("ignores non-numeric junk", SettingsForm.ParseIds("111, abc, 222").Select(n => (long)n!).SequenceEqual(new long[] { 111, 222 }));
        Check("empty text parses to empty array", SettingsForm.ParseIds("").Count == 0);
        Check("round-trips through FormatIds", SettingsForm.FormatIds(SettingsForm.ParseIds("111, 222, 333")) == "111, 222, 333");
        Check("FormatIds of null is empty", SettingsForm.FormatIds(null) == "");

        foreach (var f in failures) Console.WriteLine($"FAIL: {f}");
        if (failures.Count == 0) Console.WriteLine("selftest: all checks passed");
        return failures.Count == 0;
    }
}
