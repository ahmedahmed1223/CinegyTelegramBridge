using System.Diagnostics;
using System.Text.Json;
using Microsoft.Win32;

namespace BridgeManager;

/// <summary>Local, portable persistence for the one thing this app needs to remember: where TelegramBridge.ps1 lives.</summary>
internal sealed class ManagerSettings
{
    public string? BridgeScriptPath { get; set; }

    private static string SettingsFilePath => Path.Combine(AppContext.BaseDirectory, "BridgeManager.settings.json");

    public static ManagerSettings Load()
    {
        try
        {
            if (File.Exists(SettingsFilePath))
            {
                var json = File.ReadAllText(SettingsFilePath);
                return JsonSerializer.Deserialize<ManagerSettings>(json) ?? new ManagerSettings();
            }
        }
        catch { /* corrupt or unreadable - start fresh rather than block the app */ }
        return new ManagerSettings();
    }

    public void Save()
    {
        try
        {
            var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(SettingsFilePath, json);
        }
        catch { /* e.g. exe sitting in a write-protected folder - worst case, ask again next launch */ }
    }
}

public sealed class MainForm : Form
{
    private readonly RichTextBox _output;
    private readonly Label _statusLabel;
    private readonly Button _startButton;
    private readonly Button _stopButton;
    private readonly Button _restartButton;
    private readonly CheckBox _autoRestartCheck;
    private readonly CheckBox _autoClearCheck;
    private readonly CheckBox _startWithWindowsCheck;
    private readonly CheckBox _wordWrapCheck;
    private readonly NotifyIcon _trayIcon;
    private readonly System.Windows.Forms.Timer _restartTimer;
    private readonly System.Windows.Forms.Timer _autoClearTimer;

    private ManagerSettings _settings;
    private Process? _bridgeProcess;
    private bool _stoppingIntentionally;
    private bool _exiting;
    private int _outputLineCount;
    private const int MaxOutputLines = 3000;

    // Crash-loop breaker: a bad config (bad token, unreachable engine) makes the
    // bridge exit within seconds of every launch. Without a cap, auto-restart
    // would hammer Telegram's API and the Air Pro engine forever instead of
    // surfacing the problem.
    private DateTime _lastStartAt;
    private int _consecutiveQuickFailures;
    private const int MaxQuickFailures = 5;
    private static readonly TimeSpan QuickFailThreshold = TimeSpan.FromSeconds(10);

    public MainForm()
    {
        // Stamped from TelegramBridge.ps1's $script:BridgeVersion at publish
        // time by scripts/Build-BridgeManager.ps1 (-p:Version=...); a plain
        // `dotnet build` without that script falls back to .NET's default "1.0.0.0".
        Text = $"مدير جسر تيليجرام - Cinegy Air Pro (v{Application.ProductVersion})";
        Width = 900;
        Height = 600;
        StartPosition = FormStartPosition.CenterScreen;
        // Pull the icon baked into this exe (ApplicationIcon in the csproj) rather
        // than shipping/loading a separate .ico file at runtime.
        var appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application;
        Icon = appIcon;

        _settings = ManagerSettings.Load();

        _statusLabel = new Label { Text = "متوقف", AutoSize = false, Dock = DockStyle.Top, Height = 32, TextAlign = ContentAlignment.MiddleLeft, Font = new Font(Font.FontFamily, 11, FontStyle.Bold), ForeColor = Color.DarkRed, Padding = new Padding(8, 0, 0, 0) };

        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Padding = new Padding(4) };
        _startButton = new Button { Text = "▶ تشغيل", Width = 100 };
        _stopButton = new Button { Text = "⏹ إيقاف", Width = 100, Enabled = false };
        _restartButton = new Button { Text = "♻ إعادة تشغيل", Width = 120, Enabled = false };
        var settingsButton = new Button { Text = "⚙ الإعدادات", Width = 110 };
        var logsButton = new Button { Text = "📁 مجلد السجلات", Width = 130 };
        var clearButton = new Button { Text = "🧹 مسح الشاشة", Width = 110 };
        _autoRestartCheck = new CheckBox { Text = "إعادة التشغيل تلقائيًا عند التوقف", AutoSize = true, Checked = true, Padding = new Padding(12, 6, 0, 0) };
        _autoClearCheck = new CheckBox { Text = "مسح تلقائي للشاشة كل 24 ساعة", AutoSize = true, Checked = false, Padding = new Padding(12, 6, 0, 0) };
        _startWithWindowsCheck = new CheckBox { Text = "🔁 تشغيل تلقائي مع بدء ويندوز", AutoSize = true, Checked = IsStartWithWindowsEnabled(), Padding = new Padding(12, 6, 0, 0) };
        _wordWrapCheck = new CheckBox { Text = "التفاف الأسطر الطويلة", AutoSize = true, Checked = true, Padding = new Padding(12, 6, 0, 0) };

        _startButton.Click += (_, _) => StartBridge(manual: true);
        _stopButton.Click += (_, _) => { if (ConfirmStop()) StopBridge(manual: true); };
        _restartButton.Click += (_, _) => RestartBridge();
        settingsButton.Click += (_, _) => OpenSettings();
        logsButton.Click += (_, _) => OpenLogsFolder();

        toolbar.Controls.AddRange(new Control[] { _startButton, _stopButton, _restartButton, settingsButton, logsButton, clearButton, _autoRestartCheck, _autoClearCheck, _startWithWindowsCheck, _wordWrapCheck });
        _startWithWindowsCheck.CheckedChanged += (_, _) =>
        {
            SetStartWithWindows(_startWithWindowsCheck.Checked);
            LogEvent($"تشغيل تلقائي مع بدء ويندوز: {(_startWithWindowsCheck.Checked ? "مفعّل" : "معطّل")}.");
        };

        _output = new RichTextBox
        {
            Dock = DockStyle.Fill,
            ReadOnly = true,
            BackColor = Color.Black,
            ForeColor = Color.Gainsboro,
            // Segoe UI (not a monospace font) shapes Arabic correctly - the bridge
            // logs a lot of Arabic text, and Courier New/Consolas render it as
            // disconnected letters with no joining forms.
            Font = new Font("Segoe UI", 10f),
            // Long lines (stack traces, JSON dumps in error output) would
            // otherwise only be reachable by scrolling sideways.
            WordWrap = true,
            ScrollBars = RichTextBoxScrollBars.Vertical
        };
        clearButton.Click += (_, _) => { _output.Clear(); _outputLineCount = 0; };
        _wordWrapCheck.CheckedChanged += (_, _) =>
        {
            _output.WordWrap = _wordWrapCheck.Checked;
            _output.ScrollBars = _wordWrapCheck.Checked ? RichTextBoxScrollBars.Vertical : RichTextBoxScrollBars.Both;
        };

        Controls.Add(_output);
        Controls.Add(toolbar);
        Controls.Add(_statusLabel);

        _restartTimer = new System.Windows.Forms.Timer { Interval = 3000 };
        _restartTimer.Tick += (_, _) => { _restartTimer.Stop(); StartBridge(); };

        _autoClearTimer = new System.Windows.Forms.Timer { Interval = (int)TimeSpan.FromHours(24).TotalMilliseconds };
        _autoClearTimer.Tick += (_, _) => { _output.Clear(); _outputLineCount = 0; AppendLine("--- مسح تلقائي للشاشة (كل 24 ساعة) ---"); };
        _autoClearCheck.CheckedChanged += (_, _) =>
        {
            if (_autoClearCheck.Checked) _autoClearTimer.Start();
            else _autoClearTimer.Stop();
        };

        _trayIcon = new NotifyIcon
        {
            Icon = appIcon,
            Text = "مدير جسر تيليجرام - متوقف",
            Visible = true
        };
        var trayMenu = new ContextMenuStrip();
        trayMenu.Items.Add("عرض النافذة", null, (_, _) => ShowFromTray());
        trayMenu.Items.Add("تشغيل", null, (_, _) => StartBridge(manual: true));
        trayMenu.Items.Add("إيقاف", null, (_, _) => { if (ConfirmStop()) StopBridge(manual: true); });
        trayMenu.Items.Add("إعادة تشغيل", null, (_, _) => RestartBridge());
        trayMenu.Items.Add(new ToolStripSeparator());
        trayMenu.Items.Add("❌ إغلاق البرنامج", null, (_, _) => ExitFromTray());
        _trayIcon.ContextMenuStrip = trayMenu;
        _trayIcon.DoubleClick += (_, _) => ShowFromTray();

        Load += (_, _) => { if (EnsureBridgeScriptResolved()) LogEvent($"تم فتح برنامج المدير (الإصدار v{Application.ProductVersion})."); };
        FormClosing += MainForm_FormClosing;
    }

    // ---- locating the bridge --------------------------------------------

    private bool EnsureBridgeScriptResolved()
    {
        if (!string.IsNullOrWhiteSpace(_settings.BridgeScriptPath) && File.Exists(_settings.BridgeScriptPath))
            return true;

        // Dropped next to TelegramBridge.ps1 (e.g. copied into the repo root)?
        // Pick it up without asking.
        var besideExe = Path.Combine(AppContext.BaseDirectory, "TelegramBridge.ps1");
        if (File.Exists(besideExe))
        {
            _settings.BridgeScriptPath = besideExe;
            _settings.Save();
            return true;
        }

        using var dialog = new OpenFileDialog
        {
            Title = "اختر ملف TelegramBridge.ps1",
            Filter = "PowerShell script (TelegramBridge.ps1)|TelegramBridge.ps1|كل الملفات|*.*",
            CheckFileExists = true
        };
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            _settings.BridgeScriptPath = dialog.FileName;
            _settings.Save();
            return true;
        }
        return false;
    }

    private string BridgeRoot => Path.GetDirectoryName(_settings.BridgeScriptPath!) ?? "";
    private string ConfigPath => Path.Combine(BridgeRoot, "config.json");

    // ---- process supervision ---------------------------------------------

    private void StartBridge(bool manual = false)
    {
        // Disable immediately, before anything else: a burst of clicks queued
        // faster than the UI thread can react would otherwise each run this
        // method in turn (once per queued click), each one restarting what
        // the previous click just started. A disabled button drops any
        // already-queued click messages instead of turning them into more
        // Restart calls. SetStatus() below restores the right enabled state
        // on every exit path once the outcome (running or not) is known.
        SetButtonsBusy();

        if (_bridgeProcess is { HasExited: false }) { SetStatus(running: true); return; }
        if (!EnsureBridgeScriptResolved()) { SetStatus(running: false); return; }
        // A deliberate click always gets a fresh chance, even after the
        // crash-loop breaker gave up on automatic restarts.
        if (manual) _consecutiveQuickFailures = 0;

        var pwsh = ResolvePwsh();
        if (pwsh is null)
        {
            MessageBox.Show(this,
                "لم يتم العثور على pwsh.exe (PowerShell 7).\nثبّته من https://aka.ms/powershell-release ثم أعد المحاولة.",
                "PowerShell 7 غير موجود", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            SetStatus(running: false);
            return;
        }

        var scriptPath = _settings.BridgeScriptPath!;
        var psi = new ProcessStartInfo
        {
            FileName = pwsh,
            WorkingDirectory = BridgeRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            // pwsh writes Arabic (Write-Host, log lines) as UTF-8; decode it as
            // such explicitly rather than falling back to the console codepage.
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8,
        };
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-File");
        psi.ArgumentList.Add(scriptPath);
        psi.ArgumentList.Add("-ConfigPath");
        psi.ArgumentList.Add(ConfigPath);
        // -StopExisting: this process has no attached console, so a Read-Host
        // prompt from "another instance is already running" would hang forever.
        psi.ArgumentList.Add("-StopExisting");

        _stoppingIntentionally = false;
        AppendLine($"--- بدء التشغيل: {scriptPath} ---");
        LogEvent($"بدء تشغيل الجسر: {scriptPath}");

        var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) AppendLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) AppendLine(e.Data); };
        process.Exited += (_, _) =>
        {
            // The process's exit notification can arrive on a background thread
            // after the form itself has already been torn down (app closing
            // while the bridge is still shutting down) - BeginInvoke on a
            // destroyed/disposed handle throws, which would surface as an
            // unhandled exception right as the operator is closing the app.
            if (IsDisposed) return;
            // ObjectDisposedException derives from InvalidOperationException - one catch covers both.
            try { BeginInvoke(() => OnBridgeExited(process)); }
            catch (InvalidOperationException) { }
        };

        try
        {
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
        }
        catch (Exception ex)
        {
            // A failure to even launch (missing pwsh at the exact moment,
            // permission hiccup) is just as much a "quick failure" as an
            // instant exit would be - it must go through the same
            // retry/crash-loop-breaker path instead of silently giving up
            // and leaving the operator to notice and click Start by hand.
            AppendLine($"--- فشل بدء التشغيل: {ex.Message} ---");
            LogEvent($"فشل بدء التشغيل: {ex.Message}");
            SetStatus(running: false);
            // A failed launch never "started" at all - treat it as an
            // instant (0-second) run so it counts as a quick failure below.
            _lastStartAt = DateTime.UtcNow;
            ScheduleRetryOrGiveUp();
            return;
        }

        _bridgeProcess = process;
        _lastStartAt = DateTime.UtcNow;
        SetStatus(running: true);
        LogEvent("تم بدء تشغيل الجسر بنجاح.");
    }

    private void OnBridgeExited(Process exitedProcess)
    {
        // A rapid restart can leave an old process's Exited event arriving
        // after a newer one has already taken its place - acting on it here
        // would null out tracking of the process that is actually running now.
        if (!ReferenceEquals(exitedProcess, _bridgeProcess)) return;

        var exitCode = -1;
        try { exitCode = exitedProcess.ExitCode; } catch { /* process handle already gone */ }
        AppendLine($"--- توقف الجسر (رمز الخروج {exitCode}) ---");
        LogEvent($"توقف الجسر - رمز الخروج {exitCode}.");
        _bridgeProcess = null;
        SetStatus(running: false);

        if (_exiting) return;
        if (_stoppingIntentionally)
        {
            _consecutiveQuickFailures = 0;
            LogEvent("إيقاف يدوي.");
            return;
        }

        ScheduleRetryOrGiveUp();
    }

    private void ScheduleRetryOrGiveUp()
    {
        _consecutiveQuickFailures = DateTime.UtcNow - _lastStartAt < QuickFailThreshold
            ? _consecutiveQuickFailures + 1
            : 0;

        if (!_autoRestartCheck.Checked) return;

        if (_consecutiveQuickFailures >= MaxQuickFailures)
        {
            AppendLine($"--- توقف {_consecutiveQuickFailures} مرات متتالية خلال ثوانٍ من كل تشغيل - تم إيقاف إعادة التشغيل التلقائي. راجع الإعدادات ثم اضغط ▶ تشغيل يدويًا. ---");
            LogEvent($"توقف متكرر ({_consecutiveQuickFailures} مرات) - تم إيقاف إعادة التشغيل التلقائي.");
            _statusLabel.Text = "فشل متكرر - إعادة التشغيل التلقائي متوقفة";
            _statusLabel.ForeColor = Color.Red;
            _trayIcon.ShowBalloonTip(10000, "مدير جسر تيليجرام",
                "الجسر يتوقف بشكل متكرر بعد كل تشغيل. تم إيقاف إعادة التشغيل التلقائي - راجع الإعدادات ثم شغّله يدويًا.",
                ToolTipIcon.Error);
            return;
        }

        AppendLine("--- إعادة التشغيل خلال 3 ثوانٍ... ---");
        LogEvent($"سيُعاد التشغيل خلال 3 ثوانٍ (محاولة رقم {_consecutiveQuickFailures}).");
        _statusLabel.Text = "إعادة التشغيل خلال 3 ثوانٍ...";
        _statusLabel.ForeColor = Color.DarkOrange;
        _restartTimer.Start();
    }

    private bool ConfirmStop() =>
        MessageBox.Show(this, "سيتوقف الجسر عن التحكم بالرسومات على الهواء. متابعة؟",
            "تأكيد الإيقاف", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes;

    private void StopBridge(bool manual)
    {
        SetButtonsBusy(); // see the comment in StartBridge - same rapid-click concern
        if (_bridgeProcess is not { HasExited: false } process) { SetStatus(running: false); return; }
        if (manual) LogEvent("طلب المستخدم إيقاف الجسر يدويًا.");
        _stoppingIntentionally = manual;
        try { process.Kill(entireProcessTree: true); } catch { /* already exiting */ }
    }

    private void RestartBridge()
    {
        LogEvent("طلب المستخدم إعادة تشغيل الجسر.");
        _consecutiveQuickFailures = 0; // a deliberate restart always gets a fresh chance
        if (_bridgeProcess is { HasExited: false } process)
        {
            _stoppingIntentionally = true;
            try { process.Kill(entireProcessTree: true); } catch { /* already exiting */ }
            // Not waiting for exit here: killing the tree can take a moment (ffmpeg
            // children), and blocking the UI thread on it would freeze the window.
            // The new instance's own -StopExisting handles any straggler.
        }
        StartBridge();
    }

    private static string? ResolvePwsh()
    {
        // Plain PATH search - no throwaway process spawn, so this stays cheap
        // even when called on every iteration of a crash-restart loop.
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            try
            {
                var candidate = Path.Combine(dir, "pwsh.exe");
                if (File.Exists(candidate)) return candidate;
            }
            catch { /* malformed PATH entry */ }
        }

        var fallback = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        return File.Exists(fallback) ? fallback : null;
    }

    // ---- start with Windows -------------------------------------------------
    // Per-user Run key: survives a reboot without needing admin rights or a
    // separate service/task installer, closing the gap where a power cut or
    // Windows update silently drops bridge supervision until someone notices.

    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValueName = "CinegyTelegramBridgeManager";

    private static bool IsStartWithWindowsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
            return key?.GetValue(RunValueName) is string existing
                && string.Equals(existing.Trim('"'), Application.ExecutablePath, StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    private static void SetStartWithWindows(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true)
                ?? Registry.CurrentUser.CreateSubKey(RunKeyPath);
            if (enabled) key.SetValue(RunValueName, $"\"{Application.ExecutablePath}\"");
            else key.DeleteValue(RunValueName, throwOnMissingValue: false);
        }
        catch { /* registry access denied in some locked-down environments - not fatal */ }
    }

    // ---- UI helpers --------------------------------------------------------

    private void SetStatus(bool running)
    {
        _statusLabel.Text = running ? "يعمل" : "متوقف";
        _statusLabel.ForeColor = running ? Color.DarkGreen : Color.DarkRed;
        _startButton.Enabled = !running;
        _stopButton.Enabled = running;
        _restartButton.Enabled = running;
        _trayIcon.Text = running ? "مدير جسر تيليجرام - يعمل" : "مدير جسر تيليجرام - متوقف";
    }

    /// <summary>
    /// Disables Start/Stop/Restart the instant one of them is clicked, before
    /// doing anything else. A click already queued by the time the control
    /// goes disabled is simply dropped by Windows rather than firing another
    /// Click - this is what actually stops a mashed button from running the
    /// operation once per queued click. SetStatus() restores the correct
    /// enabled state once the real outcome (running or not) is known.
    /// </summary>
    private void SetButtonsBusy()
    {
        _startButton.Enabled = false;
        _stopButton.Enabled = false;
        _restartButton.Enabled = false;
    }

    private void AppendLine(string line)
    {
        // Output/error data can still arrive from the child process's reader
        // threads for a moment after the form is disposed (app closing while
        // the bridge is mid-shutdown) - BeginInvoke on a dead handle throws on
        // a background thread, which is unrecoverable and kills the process.
        if (IsDisposed) return;
        if (InvokeRequired)
        {
            try { BeginInvoke(() => AppendLine(line)); }
            catch (InvalidOperationException) { }
            return;
        }

        _output.AppendText(line + Environment.NewLine);
        _outputLineCount++;
        if (_outputLineCount > MaxOutputLines)
        {
            var text = _output.Text;
            var cut = text.IndexOf('\n', text.Length / 4);
            if (cut > 0) _output.Text = text[(cut + 1)..];
            _outputLineCount = MaxOutputLines * 3 / 4;
        }
        _output.SelectionStart = _output.TextLength;
        _output.ScrollToCaret();
    }

    /// <summary>
    /// A persistent record of what the manager itself did - separate from the
    /// bridge's own logs/bridge.log - so "why did it restart at 3am" is
    /// answerable after the on-screen scrollback (capped, in-memory) is gone.
    /// </summary>
    private void LogEvent(string message)
    {
        if (string.IsNullOrWhiteSpace(_settings.BridgeScriptPath)) return;
        try
        {
            var logsDir = Path.Combine(BridgeRoot, "logs");
            Directory.CreateDirectory(logsDir);
            var path = Path.Combine(logsDir, "manager.log");
            if (File.Exists(path) && new FileInfo(path).Length > 5_000_000)
            {
                File.Copy(path, Path.Combine(logsDir, "manager.log.old"), overwrite: true);
                File.Delete(path);
            }
            File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} [Manager] {message}{Environment.NewLine}");
        }
        catch { /* logging must never be the reason the app breaks */ }
    }

    private void OpenSettings()
    {
        if (!EnsureBridgeScriptResolved()) return;
        using var form = new SettingsForm(ConfigPath, BridgeRoot);
        if (form.ShowDialog(this) == DialogResult.OK)
        {
            LogEvent("تم حفظ الإعدادات من واجهة المدير.");
            if (form.RestartRequested && _bridgeProcess is { HasExited: false }) RestartBridge();
        }
    }

    private void OpenLogsFolder()
    {
        if (!EnsureBridgeScriptResolved()) return;
        var logsDir = Path.Combine(BridgeRoot, "logs");
        Directory.CreateDirectory(logsDir);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{logsDir}\"") { UseShellExecute = true });
    }

    private void ShowFromTray()
    {
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
    }

    private void ExitFromTray()
    {
        if (_bridgeProcess is { HasExited: false })
        {
            var confirm = MessageBox.Show(this,
                "سيتم إيقاف الجسر أيضًا عند الخروج. متابعة؟",
                "تأكيد الخروج", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (confirm != DialogResult.Yes) return;
        }
        _exiting = true;
        _trayIcon.Visible = false;
        StopBridge(manual: true);
        Application.Exit();
    }

    private void MainForm_FormClosing(object? sender, FormClosingEventArgs e)
    {
        if (_exiting) return;
        // Closing the window just hides it to the tray - the bridge keeps running/supervised.
        e.Cancel = true;
        Hide();
    }
}
