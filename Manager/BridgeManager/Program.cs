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

        Application.SetHighDpiMode(HighDpiMode.SystemAware);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MainForm());
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
