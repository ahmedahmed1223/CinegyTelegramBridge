using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Text.Json;
using Microsoft.Win32;

namespace BridgeManager;

/// <summary>Local, portable persistence for what this app must remember between runs.</summary>
internal sealed class ManagerSettings
{
    public string? BridgeScriptPath { get; set; }

    // These toggles used to be born from hardcoded defaults on every launch, so
    // a deliberate decision silently undid itself: an operator who turned
    // auto-restart off to work on the Air engine found it back on after simply
    // closing the window, and the bridge restarting under their hands.
    public bool AutoRestart { get; set; } = true;
    public bool AutoClearDaily { get; set; }
    public bool WordWrap { get; set; } = true;

    // The hang watchdog is deliberately a file-only knob: the on/off switch
    // belongs on the toolbar, but the threshold is a number nobody should be
    // nudging from the UI during a broadcast.
    public bool HangWatchdog { get; set; } = true;
    public int HangWatchdogMinutes { get; set; } = 5;

    // Light unless asked otherwise: this window sits among Explorer, Notepad
    // and the Cinegy client during the day, and a lone black one among them
    // reads as a different application every time it is opened.
    public bool DarkMode { get; set; }

    // Whether the operator has already been told that closing the window
    // hides it to the tray. The explanation is worth showing to someone who
    // has never seen it - a window that refuses to close reads as a bug - and
    // is noise to everyone who has, which is everyone after the first time.
    // Persisted rather than per-session, or reopening the manager would make
    // it new again every day.
    public bool TrayHintShown { get; set; }

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

/// <summary>How a log line should read at a glance. Pure classification, so `--selftest` can check it.</summary>
internal enum LogLineKind { Manager, Error, Warning, Debug, Normal }

/// <summary>Semantic pieces of a bridge log line that deserve a separate colour.</summary>
internal enum LogHighlightKind { Timestamp, Level, OperationId, Layer, Success, Failure }
internal readonly record struct LogHighlight(int Start, int Length, LogHighlightKind Kind, string Text);
internal readonly record struct PendingDrainPlan(int ProcessNow, bool KeepWarningAndError);

public sealed class MainForm : Form
{
    private readonly RichTextBox _output;
    private readonly Panel _accentBar;
    private readonly Panel _header;
    private readonly Panel _filterBar;
    private readonly Panel _statusBar;
    private readonly FlowLayoutPanel _actionBar;
    private readonly FlowLayoutPanel _optionsBar;
    private readonly Label _stateLabel;
    private readonly Label _stateDetail;
    private readonly Label _telegramPill;
    private readonly Label _cinegyPill;
    private readonly Button _startButton;
    private readonly Button _stopButton;
    private readonly Button _restartButton;
    private readonly CheckBox _autoRestartCheck;
    private readonly CheckBox _autoClearCheck;
    private readonly CheckBox _startWithWindowsCheck;
    private readonly CheckBox _wordWrapCheck;
    private readonly CheckBox _watchdogCheck;
    private readonly CheckBox _errorsOnlyCheck;
    private readonly CheckBox _darkModeCheck;
    private readonly TextBox _filterBox;
    private readonly Label _lineCountLabel;
    private readonly Label _livenessLabel;
    private readonly Label _pathLabel;
    private readonly Label _activityLabel;
    private ContextMenuStrip? _optionsMenu;
    // The last thing that reached air, and when the last hour's errors landed.
    private string _lastAirSummary = string.Empty;
    private readonly Queue<DateTime> _recentErrors = new();
    private readonly ToolTip _tips = new() { AutoPopDelay = 12000, InitialDelay = 500, ReshowDelay = 200 };
    private readonly NotifyIcon _trayIcon;
    private readonly Icon _appIcon;
    private readonly System.Windows.Forms.Timer _restartTimer;
    private readonly System.Windows.Forms.Timer _autoClearTimer;
    private readonly System.Windows.Forms.Timer _drainTimer;
    private readonly System.Windows.Forms.Timer _watchdogTimer;
    private readonly System.Windows.Forms.Timer _clockTimer;
    private readonly System.Windows.Forms.Timer _startupTimer;
    private readonly System.Windows.Forms.Timer _filterTimer;

    private readonly ManagerSettings _settings;
    private Process? _bridgeProcess;
    private bool _stoppingIntentionally;
    private bool _restartAfterExit;
    private bool _exiting;

    // Start-with-Windows launches the manager with --autostart: it comes up
    // straight into the tray and starts the bridge itself. Without that the
    // registry entry only ever restored the supervisor, not what it supervises
    // - the machine came back from a power cut with the window sitting on the
    // playout screen and the bridge still stopped.
    private readonly bool _autoStartBridge;
    private readonly bool _startHidden;
    private bool _firstShowSuppressed;

    // The on-screen scrollback is kept as text, not just as pixels, so the
    // filter box can re-render a subset without losing what came before - and
    // so the line count is counted rather than estimated.
    private readonly List<string> _lines = new();
    private readonly ConcurrentQueue<(long Sequence, string Text)> _pendingPriority = new();
    private readonly ConcurrentQueue<(long Sequence, string Text)> _pendingInformational = new();
    private readonly object _pendingGate = new();
    private long _pendingSequence;
    private const int MaxOutputLines = 3000;
    private const int MaxPendingInformationalLines = 8000;
    private const int MaxPendingPriorityLines = 2000;
    private const int MaxLinesPerUiDrain = 300;
    private const int MaxDisplayedLineLength = 8192;
    private int _pendingInformationalCount;
    private int _pendingPriorityCount;
    private int _droppedInformationalLines;
    private int _droppedPriorityLines;

    // Crash-loop breaker: a bad config (bad token, unreachable engine) makes the
    // bridge exit within seconds of every launch. Without a cap, auto-restart
    // would hammer Telegram's API and the Air Pro engine forever instead of
    // surfacing the problem.
    private DateTime _lastStartAt;
    private int _consecutiveQuickFailures;
    private const int MaxQuickFailures = 5;
    private static readonly TimeSpan QuickFailThreshold = TimeSpan.FromSeconds(10);

    // Hang detection. A bridge that is stuck - a long poll that never returns,
    // a deadlock - keeps its process alive, so Process.Exited never fires and
    // the supervisor called it healthy forever. Silence on stdout cannot stand
    // in for a heartbeat: measured against this installation's own bridge.log,
    // a perfectly healthy bridge goes 10 to 18 hours without printing a single
    // line overnight, so any silence threshold short enough to catch a hang
    // would have restarted a working bridge every night. The bridge therefore
    // stamps logs/bridge.liveness once per poll loop, and this watches that.
    private DateTime? _lastLivenessSeen;
    // The running bridge's own version, from its startup line; null until one
    // is seen. See ParseBridgeVersion.
    private string? _bridgeVersion;
    // Whether the log pane currently holds an empty-state note rather than log
    // lines; see EmptyStateMessage.
    private bool _showingEmptyState;
    private bool _watchdogInactiveLogged;
    private static readonly TimeSpan LivenessGrace = TimeSpan.FromMinutes(3);

    private bool _running;

    private const int WM_SETREDRAW = 0x000B;

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    public MainForm(bool autoStart = false)
    {
        _autoStartBridge = autoStart;
        _startHidden = autoStart;

        // Stamped from TelegramBridge.ps1's $script:BridgeVersion at publish
        // time by scripts/Build-BridgeManager.ps1 (-p:Version=...); a plain
        // `dotnet build` without that script falls back to .NET's default "1.0.0.0".
        Text = $"مدير جسر تيليجرام - Cinegy Air Pro (v{Application.ProductVersion})";
        Width = 1000;
        Height = 660;
        MinimumSize = new Size(760, 480);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Theme.Background;
        ForeColor = Theme.Text;
        Font = Theme.Ui;
        // The whole UI is Arabic, so the chrome, the button flow and every
        // MessageBox this form owns should read right-to-left. The log pane
        // below opts back out on purpose.
        RightToLeft = RightToLeft.Yes;
        RightToLeftLayout = true;
        // Pull the icon baked into this exe (ApplicationIcon in the csproj) rather
        // than shipping/loading a separate .ico file at runtime.
        _appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application;
        Icon = _appIcon;

        _settings = ManagerSettings.Load();
        // Before a single control is built: every factory below reads the
        // palette at construction time.
        Theme.SetMode(_settings.DarkMode);

        // ---- header: the one thing readable from across the room ----------
        // A 16pt state word against a colour-coded bar, with the quieter
        // detail (uptime, version) under it. The old window said "متوقف" in an
        // 11pt label wedged between the title bar and a row of eleven buttons.
        _header = new Panel { Dock = DockStyle.Top, Height = 74, BackColor = Theme.Surface };
        // Right, not left: this window is right-to-left, so the leading edge -
        // where the eye starts and where the state text is aligned - is the right
        // one. On the left the bar trailed the text it belongs to.
        _accentBar = new Panel { Dock = DockStyle.Right, Width = 6, BackColor = Theme.Stopped };
        var headerText = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 12, 16, 12) };
        // AutoEllipsis, because this line grew: uptime, pid, and now both
        // versions. A fixed-height docked Label cuts a too-long string off
        // mid-character with nothing to say it did, and the piece that goes
        // first is the end of the line - where the versions are.
        _stateDetail = new Label { Dock = DockStyle.Top, Height = 20, Text = "", Font = Theme.UiSmall, ForeColor = Theme.TextMuted, TextAlign = ContentAlignment.MiddleLeft, AutoEllipsis = true };
        _stateLabel = new Label { Dock = DockStyle.Top, Height = 30, Text = "متوقف", Font = Theme.Title, ForeColor = Theme.Stopped, TextAlign = ContentAlignment.MiddleLeft };
        headerText.Controls.Add(_stateDetail);
        headerText.Controls.Add(_stateLabel);

        // The empty half of the header, which is where the eye goes after the
        // state word. Left, because the state text and the accent bar already
        // own the right edge in this right-to-left window.
        var healthPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Left,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoSize = true,
            Padding = new Padding(16, 14, 8, 10),
            BackColor = Color.Transparent
        };
        _telegramPill = new Label { AutoSize = true, Font = Theme.Ui, ForeColor = Theme.TextMuted, Margin = new Padding(0, 0, 0, 2) };
        _cinegyPill = new Label { AutoSize = true, Font = Theme.Ui, ForeColor = Theme.TextMuted, Margin = new Padding(0) };
        _tips.SetToolTip(_telegramPill, "حالة اتصال الجسر بتيليجرام، كما يعلنها في سجله.");
        _tips.SetToolTip(_cinegyPill, "حالة محرّك Cinegy Air كما يراها الجسر.");
        healthPanel.Controls.AddRange(new Control[] { _telegramPill, _cinegyPill });

        _header.Controls.Add(headerText);
        _header.Controls.Add(healthPanel);
        _header.Controls.Add(_accentBar);

        // ---- action bar: three things that change the air, then the rest ---
        _actionBar = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = true, Padding = new Padding(14, 12, 14, 6), BackColor = Theme.Background };
        _startButton = Theme.PrimaryButton("▶  تشغيل", () => Theme.Running);
        _startButton.AccessibleName = "تشغيل الجسر";
        _startButton.Width = 118;
        _stopButton = Theme.PrimaryButton("■  إيقاف", () => Theme.Stopped);
        _stopButton.AccessibleName = "إيقاف الجسر";
        _stopButton.Width = 118;
        _stopButton.Enabled = false;
        _restartButton = Theme.PrimaryButton("↻  إعادة تشغيل", () => Theme.Pending);
        _restartButton.AccessibleName = "إعادة تشغيل الجسر (F5)";
        _restartButton.Width = 140;
        _restartButton.Enabled = false;

        var settingsButton = Theme.QuietButton("⚙  الإعدادات");
        settingsButton.Width = 120;
        var logsButton = Theme.QuietButton("📂  مجلد السجلات");
        logsButton.Width = 140;
        var clearButton = Theme.QuietButton("🧹  مسح الشاشة");
        clearButton.Width = 130;
        var optionsButton = Theme.QuietButton("☰  خيارات");
        optionsButton.Width = 118;
        optionsButton.AccessibleName = "خيارات التشغيل والعرض";
        optionsButton.Click += (_, _) => _optionsMenu?.Show(optionsButton, new Point(0, optionsButton.Height));

        _tips.SetToolTip(_startButton, "يشغّل TelegramBridge.ps1 ويتابعه.");
        _tips.SetToolTip(_stopButton, "يوقف الجسر - يتوقف التحكم بالرسومات على الهواء.");
        // The shortcut is named where the hand already is. Recognition over
        // recall: F5 and Ctrl+L existed for a release and nothing on screen
        // said so, which is the same as not having them.
        _tips.SetToolTip(_restartButton, "إيقاف ثم تشغيل، لتطبيق تغييرات الإعدادات.  (F5)");
        _tips.SetToolTip(settingsButton, "الحقول التي لا تُحرَّر من داخل البوت: الرمز، عنوان المحرّك، قوائم الصلاحيات.");
        _tips.SetToolTip(logsButton, "يفتح مجلد logs في المستكشف.");
        _tips.SetToolTip(clearButton, "يمسح المعروض هنا فقط - لا يمسّ logs\\bridge.log.  (Ctrl+L)");
        _tips.SetToolTip(optionsButton, "إعادة التشغيل التلقائية وكشف التعليق وبدء ويندوز، ومظهر هذه النافذة.");

        _startButton.Click += (_, _) => StartBridge(manual: true);
        _stopButton.Click += (_, _) => { if (ConfirmStop()) StopBridge(manual: true); };
        _restartButton.Click += (_, _) => { if (ConfirmRestart()) RestartBridge(); };
        settingsButton.Click += (_, _) => OpenSettings();
        logsButton.Click += (_, _) => OpenLogsFolder();
        clearButton.Click += (_, _) => ClearOutput();

        // Keep each group intact when the manager reaches its minimum width.
        // A lone "clear" control beside a live stop button is too easy to misread
        // during an on-air incident.
        var operationalActions = new FlowLayoutPanel { AutoSize = true, WrapContents = false, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 0, 20, 6) };
        operationalActions.Controls.AddRange(new Control[] { _startButton, _stopButton, _restartButton });
        var utilityActions = new FlowLayoutPanel { AutoSize = true, WrapContents = false, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 0, 0, 6) };
        utilityActions.Controls.AddRange(new Control[] { settingsButton, optionsButton, logsButton, clearButton });
        _actionBar.Controls.AddRange(new Control[] { operationalActions, utilityActions });

        // ---- options: switches, which are not actions ----------------------
        _optionsBar = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = true, Padding = new Padding(16, 2, 14, 8), BackColor = Theme.Background };
        _autoRestartCheck = Theme.ToggleChip("↻  إعادة تشغيل تلقائية", "يعيد تشغيل الجسر بعد 3 ثوانٍ من أي توقف، ويكفّ بعد 5 انهيارات سريعة متتالية بدل أن يظل يحاول.", _tips);
        _autoRestartCheck.Checked = _settings.AutoRestart;
        _watchdogCheck = Theme.ToggleChip("🩺  كشف التعليق", $"يعيد التشغيل إذا انقطعت نبضة الجسر أكثر من {_settings.HangWatchdogMinutes} دقيقة، حتى لو بقيت العملية حيّة.", _tips);
        _watchdogCheck.Checked = _settings.HangWatchdog;
        _startWithWindowsCheck = Theme.ToggleChip("🪟  مع بدء ويندوز", "يعود المدير إلى شريط النظام بعد إعادة تشغيل الجهاز، ويشغّل الجسر بنفسه.", _tips);
        _startWithWindowsCheck.Checked = IsStartWithWindowsEnabled();
        _autoClearCheck = Theme.ToggleChip("🧹  مسح كل 24 ساعة", "يمسح المعروض هنا كل يوم - لا يمسّ logs\bridge.log.", _tips);
        _autoClearCheck.Checked = _settings.AutoClearDaily;
        _wordWrapCheck = Theme.ToggleChip("↩  التفاف الأسطر", "يلفّ السطر الطويل بدل التمرير الأفقي.", _tips);
        _wordWrapCheck.Checked = _settings.WordWrap;
        _darkModeCheck = Theme.ToggleChip("🌙  الوضع الليلي",
            "مظهر داكن - أنسب لغرفة معتمة بجانب شاشة البث. الافتراضي فاتح.", _tips);
        _darkModeCheck.Checked = _settings.DarkMode;
        // The switches move behind one button, and the row they occupied goes
        // back to the log.
        //
        // This window exists to be watched: fourteen controls stood between
        // its top edge and the first line of the thing it is for, and on a
        // gallery laptop the log had less than half the height. These six are
        // set once and left alone for months - two of them are about line
        // wrapping and dark mode - so they cost a click each and give a row
        // back to what is actually read.
        //
        // Hosted, not rebuilt: the same CheckBox objects sit inside the menu,
        // so every .Checked read and every handler elsewhere still works, and
        // what they persist is untouched.
        _optionsMenu = MakeOptionsMenu();
        _optionsBar.Visible = false;

        // ---- what is happening, above the stream that says it slowly -------
        _activityLabel = new Label
        {
            Dock = DockStyle.Top,
            Height = 26,
            Font = Theme.UiSmall,
            ForeColor = Theme.TextMuted,
            BackColor = Theme.Background,
            Padding = new Padding(16, 5, 16, 0),
            TextAlign = ContentAlignment.MiddleRight,
            AutoEllipsis = true,
            Text = "▶ آخر عملية: لا عملية بعد     ⚠ بلا أخطاء"
        };

        // ---- filter row, sitting directly on top of what it filters --------
        _filterBar = new Panel { Dock = DockStyle.Top, Height = 52, BackColor = Theme.Surface, Padding = new Padding(14, 9, 14, 9) };
        var filterFlow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, AutoSize = false };
        _filterBox = Theme.Input(300);
        // Saying that a time works here, because it always did and nothing
        // said so: every line opens with its stamp, so "07:2" is a filter on
        // a twenty-minute window as much as a word is a filter on a word.
        _filterBox.PlaceholderText = "تصفية بالنص أو بالوقت (مثل 07:2)…  (Ctrl+F)";
        _filterBox.AccessibleName = "تصفية السجل";
        _filterBox.AccessibleDescription = "يبحث في النص المعروض من سجل الجسر.";
        _errorsOnlyCheck = Theme.ToggleChip("الأخطاء والتحذيرات فقط", "يخفي كل ما عدا أسطر [ERROR] و[WARN].", _tips);
        _errorsOnlyCheck.Margin = new Padding(12, 0, 0, 0);
        _filterBox.Margin = new Padding(0, 5, 0, 0);
        filterFlow.Controls.AddRange(new Control[] { _filterBox, _errorsOnlyCheck });
        _filterBar.Controls.Add(filterFlow);

        _output = new RichTextBox
        {
            Dock = DockStyle.Fill,
            ReadOnly = true,
            BackColor = Theme.LogBackground,
            ForeColor = Theme.LogNormal,
            BorderStyle = BorderStyle.None,
            // Segoe UI (not a monospace font) shapes Arabic correctly - the bridge
            // logs a lot of Arabic text, and Courier New/Consolas render it as
            // disconnected letters with no joining forms.
            Font = Theme.Mono,
            // Long lines (stack traces, JSON dumps in error output) would
            // otherwise only be reachable by scrolling sideways.
            WordWrap = _settings.WordWrap,
            ScrollBars = _settings.WordWrap ? RichTextBoxScrollBars.Vertical : RichTextBoxScrollBars.Both,
            // Deliberately NOT right-to-left, even though the form is: every
            // bridge log line opens with "2026-09-04 14:06:02 [INFO]" and only
            // then turns Arabic. Mirroring the pane pushes that timestamp to
            // the right edge and makes the log much harder to scan; leaving the
            // control LTR lets each line's own bidi run place the Arabic
            // correctly inside it.
            RightToLeft = RightToLeft.No
        };

        // ---- status bar: the facts nobody should have to hunt for ----------
        // A plain panel rather than a StatusStrip: the strip renderers fight a
        // dark palette and win.
        _statusBar = new Panel { Dock = DockStyle.Bottom, Height = 28, BackColor = Theme.Surface, Padding = new Padding(14, 5, 14, 5) };
        var statusFlow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, AutoSize = false, WrapContents = false };
        _lineCountLabel = new Label { AutoSize = true, ForeColor = Theme.TextMuted, Font = Theme.UiSmall, Margin = new Padding(0, 2, 24, 0) };
        _livenessLabel = new Label { AutoSize = true, ForeColor = Theme.TextMuted, Font = Theme.UiSmall, Margin = new Padding(0, 2, 24, 0) };
        _pathLabel = new Label { AutoSize = true, ForeColor = Theme.TextMuted, Font = Theme.UiSmall, Margin = new Padding(0, 2, 0, 0) };
        statusFlow.Controls.AddRange(new Control[] { _lineCountLabel, _livenessLabel, _pathLabel });
        _statusBar.Controls.Add(statusFlow);

        _wordWrapCheck.CheckedChanged += (_, _) =>
        {
            _output.WordWrap = _wordWrapCheck.Checked;
            _output.ScrollBars = _wordWrapCheck.Checked ? RichTextBoxScrollBars.Vertical : RichTextBoxScrollBars.Both;
            _settings.WordWrap = _wordWrapCheck.Checked;
            _settings.Save();
        };
        _filterTimer = new System.Windows.Forms.Timer { Interval = 250 };
        _filterTimer.Tick += (_, _) => { _filterTimer.Stop(); RenderAll(); };
        _filterBox.TextChanged += (_, _) => { _filterTimer.Stop(); _filterTimer.Start(); };
        _errorsOnlyCheck.CheckedChanged += (_, _) => RenderAll();
        KeyPreview = true;
        KeyDown += (_, e) =>
        {
            if (e.Control && e.KeyCode == Keys.F) { _filterBox.Focus(); _filterBox.SelectAll(); e.Handled = true; }
            if (e.KeyCode == Keys.Escape && _filterBox.Focused && _filterBox.Text.Length > 0) { _filterBox.Clear(); e.Handled = true; }
            // Ctrl+L clears the pane the way it clears a terminal, and F5
            // restarts - both go through the same buttons, so the confirmation
            // an operator gets from the mouse is the one they get here too.
            // Enabled-checked first: a shortcut that fires a disabled button is
            // how a keyboard restarts a bridge that is already stopping.
            if (e.Control && e.KeyCode == Keys.L) { ClearOutput(); e.Handled = true; }
            if (e.KeyCode == Keys.F5 && _restartButton.Enabled) { _restartButton.PerformClick(); e.Handled = true; }
        };

        // Docked Top stacks in reverse order of adding, so this reads
        // bottom-of-the-window first.
        Controls.Add(_output);
        Controls.Add(_filterBar);
        Controls.Add(_activityLabel);
        Controls.Add(_optionsBar);
        Controls.Add(_actionBar);
        Controls.Add(_header);
        Controls.Add(_statusBar);

        _restartTimer = new System.Windows.Forms.Timer { Interval = 3000 };
        _restartTimer.Tick += (_, _) =>
        {
            _restartTimer.Stop();
            if (_autoRestartCheck.Checked) StartBridge();
        };

        _autoClearTimer = new System.Windows.Forms.Timer { Interval = (int)TimeSpan.FromHours(24).TotalMilliseconds };
        _autoClearTimer.Tick += (_, _) => { ClearOutput(); AppendLine("--- مسح تلقائي للشاشة (كل 24 ساعة) ---"); };
        _autoClearCheck.CheckedChanged += (_, _) =>
        {
            if (_autoClearCheck.Checked) _autoClearTimer.Start();
            else _autoClearTimer.Stop();
            _settings.AutoClearDaily = _autoClearCheck.Checked;
            _settings.Save();
        };
        if (_autoClearCheck.Checked) _autoClearTimer.Start();

        _autoRestartCheck.CheckedChanged += (_, _) =>
        {
            if (!ConfirmSafetyOff(_autoRestartCheck,
                    "إن توقّف الجسر فلن يُعاد تشغيله تلقائيًا، وستبقى الرسومات بلا تحكّم حتى ينتبه أحد.\n\nإيقاف إعادة التشغيل التلقائي؟")) return;
            _settings.AutoRestart = _autoRestartCheck.Checked;
            if (!_autoRestartCheck.Checked) _restartTimer.Stop();
            _settings.Save();
            LogEvent($"إعادة التشغيل التلقائي: {(_autoRestartCheck.Checked ? "مفعّلة" : "معطّلة")}.");
        };
        _watchdogCheck.CheckedChanged += (_, _) =>
        {
            if (!ConfirmSafetyOff(_watchdogCheck,
                    "لن يُكتشف الجسر المعلّق بعد الآن: سيبدو «يعمل» وهو لا يستجيب.\n\nإيقاف كشف التعليق؟")) return;
            _settings.HangWatchdog = _watchdogCheck.Checked;
            _settings.Save();
            UpdateStatusBar();
            LogEvent($"كشف التعليق: {(_watchdogCheck.Checked ? "مفعّل" : "معطّل")}.");
        };
        _darkModeCheck.CheckedChanged += (_, _) =>
        {
            _settings.DarkMode = _darkModeCheck.Checked;
            _settings.Save();
            ApplyTheme();
            LogEvent($"المظهر: {(_darkModeCheck.Checked ? "ليلي" : "فاتح")}.");
        };
        _startWithWindowsCheck.CheckedChanged += (_, _) =>
        {
            SetStartWithWindows(_startWithWindowsCheck.Checked);
            LogEvent($"تشغيل تلقائي مع بدء ويندوز: {(_startWithWindowsCheck.Checked ? "مفعّل" : "معطّل")}.");
        };

        // One coalescing pump instead of a BeginInvoke per line: the bridge can
        // emit hundreds of lines in a burst (startup, a template dump, a stack
        // trace), and a marshalled call plus a ScrollToCaret for every one of
        // them flooded the message queue and froze the window while it drained.
        _drainTimer = new System.Windows.Forms.Timer { Interval = 100 };
        _drainTimer.Tick += (_, _) => DrainPending();
        _drainTimer.Start();

        _watchdogTimer = new System.Windows.Forms.Timer { Interval = 30_000 };
        _watchdogTimer.Tick += (_, _) => CheckLiveness();
        _watchdogTimer.Start();

        // Uptime and heartbeat age are only worth showing if they move.
        _clockTimer = new System.Windows.Forms.Timer { Interval = 1000 };
        _clockTimer.Tick += (_, _) => { UpdateStateDetail(); UpdateStatusBar(); PumpBridgeLogTail(); };
        _clockTimer.Start();

        _trayIcon = new NotifyIcon
        {
            Icon = _appIcon,
            Text = "مدير جسر تيليجرام - متوقف",
            Visible = true
        };
        var trayMenu = new ContextMenuStrip { RightToLeft = RightToLeft.Yes };
        // The same glyphs the window uses. This menu is what an operator sees
        // when the window is hidden, which is most of the time, and a menu
        // whose items look nothing like the buttons they mirror is a second
        // thing to learn.
        trayMenu.Items.Add("🪟  عرض النافذة", null, (_, _) => ShowFromTray());
        trayMenu.Items.Add(new ToolStripSeparator());
        trayMenu.Items.Add("▶  تشغيل", null, (_, _) => StartBridge(manual: true));
        trayMenu.Items.Add("■  إيقاف", null, (_, _) => { if (ConfirmStop()) StopBridge(manual: true); });
        trayMenu.Items.Add("↻  إعادة تشغيل", null, (_, _) => { if (ConfirmRestart()) RestartBridge(); });
        trayMenu.Items.Add(new ToolStripSeparator());
        trayMenu.Items.Add("❌ إغلاق البرنامج", null, (_, _) => ExitFromTray());
        _trayIcon.ContextMenuStrip = trayMenu;
        _trayIcon.DoubleClick += (_, _) => ShowFromTray();

        // Not the Load event: with --autostart the window is never shown, so
        // Load would never fire and the bridge would never be started. A
        // one-shot timer runs as soon as the message loop turns over, whether
        // there is a visible window or not.
        _startupTimer = new System.Windows.Forms.Timer { Interval = 1 };
        _startupTimer.Tick += (_, _) => { _startupTimer.Stop(); OnStartup(); };
        _startupTimer.Start();

        FormClosing += MainForm_FormClosing;
        SetStatus(running: false);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.ApplyTitleBar(Handle);
    }

    /// <summary>
    /// Repaints the whole window in the current palette, live. Theme.Apply
    /// walks the tree and runs each control's own restyle delegate; the
    /// surfaces below are this form's own and are set here. RenderAll at the
    /// end is not optional - every line already in the RichTextBox carries a
    /// colour baked in from whichever palette was current when it arrived.
    /// </summary>
    private void ApplyTheme()
    {
        Theme.SetMode(_settings.DarkMode);
        SuspendLayout();
        BackColor = Theme.Background;
        ForeColor = Theme.Text;
        _header.BackColor = Theme.Surface;
        _actionBar.BackColor = Theme.Background;
        _optionsBar.BackColor = Theme.Background;
        _filterBar.BackColor = Theme.Surface;
        _statusBar.BackColor = Theme.Surface;
        _output.BackColor = Theme.LogBackground;
        _output.ForeColor = Theme.LogNormal;
        _lineCountLabel.ForeColor = Theme.TextMuted;
        _livenessLabel.ForeColor = Theme.TextMuted;
        _pathLabel.ForeColor = Theme.TextMuted;
        _stateDetail.ForeColor = Theme.TextMuted;
        Theme.Apply(this);
        ResumeLayout();
        Theme.ApplyTitleBar(Handle);
        SetStatus(_running);
        RenderAll();
    }

    /// <summary>
    /// Swallows only the very first show, so `--autostart` comes up straight
    /// into the tray instead of throwing a window over whatever is on the
    /// playout screen at boot. Every later Show() (tray double-click, menu)
    /// behaves normally.
    /// </summary>
    protected override void SetVisibleCore(bool value)
    {
        if (_startHidden && !_firstShowSuppressed)
        {
            _firstShowSuppressed = true;
            base.SetVisibleCore(false);
            return;
        }
        base.SetVisibleCore(value);
    }

    private void OnStartup()
    {
        UpdateStatusBar();
        // An empty black pane tells a new operator nothing. One muted line
        // costs nothing and answers "what now?".
        if (!_autoStartBridge) AppendLine("--- جاهز. اضغط تشغيل لبدء الجسر. ---");
        if (!EnsureBridgeScriptResolved()) return;
        UpdateStatusBar();
        LogEvent($"تم فتح برنامج المدير (الإصدار v{Application.ProductVersion}){(_autoStartBridge ? " - بدء تلقائي مع ويندوز" : "")}.");
        // Adopt before starting: a bridge left running by a previous manager is
        // already on air, and launching a second one would take the graphics
        // down for the seconds -StopExisting needs to kill the first.
        if (TryAdoptRunningBridge()) return;
        if (_autoStartBridge) StartBridge();
    }

    /// <summary>
    /// Picks up a bridge that is already running without a supervisor.
    ///
    /// Closing the manager leaves the bridge alive on purpose, so reopening it
    /// used to show "stopped" beside a bridge that was plainly on air - and
    /// worse, auto-restart and hang detection both sat idle, because they watch
    /// a process this window never started. The heartbeat file carries the
    /// bridge's process id precisely so that gap can be closed without asking
    /// the operator to restart something that is working.
    ///
    /// The one thing adoption cannot recover is the log pane: stdout belongs to
    /// whoever launched the process, so the window says so rather than looking
    /// broken.
    /// </summary>
    private bool TryAdoptRunningBridge()
    {
        var pid = ReadLivenessPid();
        if (pid is null) return false;

        var stamp = ReadLivenessStamp();
        // A stale heartbeat means the id belongs to a bridge that has already
        // gone; the pid could since have been reused by anything at all.
        if (stamp is null || DateTime.UtcNow - stamp.Value > TimeSpan.FromMinutes(2)) return false;

        Process process;
        try
        {
            process = Process.GetProcessById(pid.Value);
            if (process.HasExited) return false;
            process.EnableRaisingEvents = true;
        }
        catch { return false; }

        process.Exited += (_, _) =>
        {
            if (IsDisposed) return;
            try { BeginInvoke(() => OnBridgeExited(process)); }
            catch (InvalidOperationException) { }
        };

        _bridgeProcess?.Dispose();
        _bridgeProcess = process;
        _stoppingIntentionally = false;
        _consecutiveQuickFailures = 0;
        // Its real start time, so the header does not claim an uptime of zero
        // for a bridge that has been up for days.
        try { _lastStartAt = process.StartTime.ToUniversalTime(); }
        catch { _lastStartAt = DateTime.UtcNow; }
        _lastLivenessSeen = stamp;
        _watchdogInactiveLogged = false;

        AppendLine($"--- تم استلام جسر يعمل بالفعل (المعرّف {pid}). سجله يُتابَع من logs\\bridge.log لأنه بدأ خارج هذا البرنامج. ---");
        StartTailingBridgeLog();
        LogEvent($"استلام جسر يعمل بالفعل (المعرّف {pid}).");
        SetStatus(running: true);
        return true;
    }

    /// <summary>The bridge process id from the heartbeat file, when it carries one.</summary>
    private int? ReadLivenessPid()
    {
        try
        {
            if (string.IsNullOrWhiteSpace(_settings.BridgeScriptPath)) return null;
            var path = LivenessPath;
            if (!File.Exists(path)) return null;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var reader = new StreamReader(stream);
            return ParseLiveness(reader.ReadToEnd()).Pid;
        }
        catch { return null; }
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

        // A file picker owned by a window that is hidden in the tray opens
        // behind everything else and reads as a hang. Come forward first.
        if (!Visible) ShowFromTray();

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

    /// <summary>
    /// Where the bridge stamps its poll loop. Deliberately the default logs
    /// folder rather than anything read out of config.json: an installation
    /// that relocated its logs simply produces no file here, and a missing
    /// stamp switches the watchdog off instead of restarting a healthy bridge.
    /// </summary>
    private string LivenessPath => Path.Combine(BridgeRoot, "logs", "bridge.liveness");

    private string BridgeLogPath => Path.Combine(BridgeRoot, "logs", "bridge.log");

    // ---- what the bridge is connected to -----------------------------------
    // "Running" only ever meant the process is alive. A bridge whose Telegram
    // poll is refused or whose Air engine is unreachable is alive and useless,
    // and saying so took reading log lines. It announces both transitions
    // itself, so the header reads them as they go past and keeps the answer on
    // screen instead of in the scrollback.

    /// <summary>The kind and the new state named by a health transition line, or null for any other line.</summary>
    internal static (string Kind, string State)? ParseHealthLine(string line)
    {
        string kind;
        if (line.Contains("Telegram connection changed from", StringComparison.Ordinal)) kind = "telegram";
        else if (line.Contains("Cinegy health changed from", StringComparison.Ordinal)) kind = "cinegy";
        else return null;

        const string toMarker = " to ";
        var at = line.LastIndexOf(toMarker, StringComparison.Ordinal);
        if (at < 0) return null;

        var state = line[(at + toMarker.Length)..].Trim().TrimEnd('.');
        return state.Length == 0 ? null : (kind, state.ToLowerInvariant());
    }

    internal static string HealthText(string kind, string state)
    {
        var name = kind == "telegram" ? "تيليجرام" : "Cinegy";
        var word = state switch
        {
            "connected" => "متصل",
            "disconnected" => "منقطع",
            "healthy" => "سليم",
            "unhealthy" => "متعثّر",
            "degraded" => "متعثّر",
            "unknown" => "—",
            _ => state
        };
        return $"{name}: {word}";
    }

    internal static bool IsHealthyState(string state) => state is "connected" or "healthy";

    internal static bool IsFaultedState(string state) => state is "disconnected" or "unhealthy" or "degraded";

    /// <summary>
    /// The bridge's version, from the line it prints on every start, or null
    /// when the line is something else.
    /// </summary>
    /// <remarks>
    /// The manager and the bridge are versioned apart on purpose - the exe is
    /// republished only when the manager itself changes, while the bridge
    /// ships several times a day - so the manager may sit at 7 beside a bridge
    /// at 7.76.0 and both be current.
    ///
    /// That makes printing one of the two numbers worse than printing
    /// neither: the status line read "يعمل منذ … المعرّف 28728 · الإصدار v7"
    /// where every other figure on it belongs to the bridge, so the manager's
    /// version was being read as the bridge's. The answer is to show both and
    /// name each, and the bridge announces its own on the line the manager is
    /// already tailing.
    /// </remarks>
    // A quiet caption above a group of switches inside the menu. It explains
    // the grouping without competing with the switches themselves.
    private static ToolStripLabel MakeSwitchGroupLabel(string text) => new(text)
    {
        Font = Theme.UiSmall,
        ForeColor = Theme.TextMuted,
        Enabled = false
    };

    // The switches, grouped by what they govern: the channel when nobody is
    // watching, or this window. Mixing them made a row where a preference
    // about line wrapping sat beside the switch that decides whether a dead
    // bridge comes back.
    private ContextMenuStrip MakeOptionsMenu()
    {
        // RenderMode.System, and the colours set again on every open: the
        // default renderer paints a light chrome that survives the dark
        // palette and leaves white gutters around dark items, and the theme
        // can be switched from inside this very menu.
        var menu = new ContextMenuStrip
        {
            RightToLeft = RightToLeft.Yes,
            ShowImageMargin = false,
            RenderMode = ToolStripRenderMode.System,
            Padding = new Padding(4, 6, 4, 6)
        };
        menu.Items.Add(MakeSwitchGroupLabel("🔴  ما يحدث للقناة"));
        foreach (var box in new[] { _autoRestartCheck, _watchdogCheck, _startWithWindowsCheck })
        {
            menu.Items.Add(new ToolStripControlHost(box) { AutoSize = true, Margin = new Padding(14, 3, 14, 3) });
        }
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(MakeSwitchGroupLabel("🖥  هذه النافذة"));
        foreach (var box in new[] { _autoClearCheck, _wordWrapCheck, _darkModeCheck })
        {
            menu.Items.Add(new ToolStripControlHost(box) { AutoSize = true, Margin = new Padding(14, 3, 14, 3) });
        }
        menu.Opening += (_, _) =>
        {
            menu.BackColor = Theme.Surface;
            menu.ForeColor = Theme.Text;
            foreach (ToolStripItem item in menu.Items)
            {
                item.BackColor = Theme.Surface;
                if (item is ToolStripLabel) item.ForeColor = Theme.TextMuted;
            }
        };
        return menu;
    }

    // What is happening, in one line, without reading the log: the last thing
    // that reached air, and how many errors the last hour holds. The log is a
    // stream that scrolls past; this is the summary an operator glances at.
    private void UpdateActivityStrip()
    {
        PruneRecentErrors();
        var last = string.IsNullOrEmpty(_lastAirSummary) ? "لا عملية بعد" : _lastAirSummary;
        var errors = _recentErrors.Count == 0 ? "بلا أخطاء" : $"{_recentErrors.Count} خطأ في آخر ساعة";
        _activityLabel.Text = $"▶ آخر عملية: {last}     ⚠ {errors}";
        _activityLabel.ForeColor = _recentErrors.Count == 0 ? Theme.TextMuted : Theme.Stopped;
    }

    private void PruneRecentErrors()
    {
        var cutoff = DateTime.Now.AddHours(-1);
        while (_recentErrors.Count > 0 && _recentErrors.Peek() < cutoff) _recentErrors.Dequeue();
    }

    // Read off the same sweep every line already passes through. AIR_OP is the
    // bridge's own record of something reaching the channel, and its shape is
    // fixed by Write-AirOperationResult.
    internal static string? ParseAirActivity(string line)
    {
        if (line is null || !line.Contains("AIR_OP ")) return null;
        var action = Regex.Match(line, @"action=(\w+)");
        var result = Regex.Match(line, @"result=(\w+)");
        if (!action.Success || !result.Success) return null;
        var target = Regex.Match(line, "target=\"([^\"]*)\"");
        var verb = action.Groups[1].Value switch
        {
            "SHOW" => "عرض",
            "HIDE" => "إخفاء",
            "EXIT" => "خروج",
            "UPDATE" => "تحديث",
            _ => action.Groups[1].Value
        };
        var mark = result.Groups[1].Value switch { "success" => "✅", "blocked" => "⛔", _ => "❌" };
        var name = target.Success && target.Groups[1].Value.Length > 0 ? $" «{target.Groups[1].Value}»" : "";
        var stamp = Regex.Match(line, @"^\d{4}-\d{2}-\d{2} (\d{2}:\d{2})");
        var at = stamp.Success ? $" — {stamp.Groups[1].Value}" : "";
        return $"{mark} {verb}{name}{at}";
    }

    internal static string? ParseBridgeVersion(string line)
    {
        if (string.IsNullOrEmpty(line)) return null;
        var match = System.Text.RegularExpressions.Regex.Match(
            line, @"\bBridge v(\d+\.\d+\.\d+) starting\b");
        return match.Success ? match.Groups[1].Value : null;
    }

    private void ApplyHealthLine(string line)
    {
        // Same sweep as the health pills: every line passes through here
        // once, and the version is only ever announced on a start line.
        var version = ParseBridgeVersion(line);
        if (version is not null)
        {
            _bridgeVersion = version;
            UpdateStateDetail();
        }

        var activity = ParseAirActivity(line);
        if (activity is not null)
        {
            _lastAirSummary = activity;
            UpdateActivityStrip();
        }
        if (ClassifyLine(line) == LogLineKind.Error)
        {
            _recentErrors.Enqueue(DateTime.Now);
            UpdateActivityStrip();
        }

        var parsed = ParseHealthLine(line);
        if (parsed is null) return;

        var (kind, state) = parsed.Value;
        var pill = kind == "telegram" ? _telegramPill : _cinegyPill;
        pill.Text = HealthText(kind, state);
        pill.ForeColor = IsHealthyState(state) ? Theme.Running
            : IsFaultedState(state) ? Theme.Stopped
            : Theme.TextMuted;
    }

    private void ResetHealthPills()
    {
        _telegramPill.Text = HealthText("telegram", "unknown");
        _cinegyPill.Text = HealthText("cinegy", "unknown");
        _telegramPill.ForeColor = Theme.TextMuted;
        _cinegyPill.ForeColor = Theme.TextMuted;
    }

    // ---- following an adopted bridge's log ---------------------------------
    // A bridge this window did not start owns its own stdout, so the log pane
    // came up blank and sent the operator to a file in Explorer - the last
    // thing adoption left half-done. The bridge writes every one of those same
    // lines to logs/bridge.log, so the pane follows the file instead.

    private long _tailOffset;
    private bool _tailingAdopted;
    private string _tailRemainder = "";

    /// <summary>
    /// A write can land mid-line, and half a line rendered now would be
    /// rendered again in full on the next tick. Returns the complete lines and
    /// hands back whatever followed the last newline to prepend next time.
    /// </summary>
    internal static string[] SplitCompleteLines(string chunk, out string remainder)
    {
        remainder = "";
        if (string.IsNullOrEmpty(chunk)) return Array.Empty<string>();

        var lastBreak = chunk.LastIndexOf('\n');
        if (lastBreak < 0) { remainder = chunk; return Array.Empty<string>(); }

        remainder = chunk[(lastBreak + 1)..];
        return chunk[..lastBreak]
            .Split('\n')
            .Select(l => l.TrimEnd('\r'))
            .Where(l => l.Length > 0)
            .ToArray();
    }

    /// <summary>
    /// True when the file has been rotated out from under us. bridge.log is
    /// rotated at LogMaxSizeMB, and reading from the old offset into a fresh
    /// file would skip the whole start of the new one.
    /// </summary>
    internal static bool WasLogRotated(long offset, long length) => length < offset;

    private void StartTailingBridgeLog()
    {
        try
        {
            var path = BridgeLogPath;
            if (!File.Exists(path)) return;

            // Seed with recent history rather than an empty pane: a bridge can
            // sit quiet for hours, and "nothing here yet" is indistinguishable
            // from "not working" at a glance.
            foreach (var line in ReadLastLines(path, 100)) AppendLine(line);
            _tailOffset = new FileInfo(path).Length;
            _tailRemainder = "";
            _tailingAdopted = true;
        }
        catch { /* the pane simply stays as it is - never worth a crash */ }
    }

    private static IEnumerable<string> ReadLastLines(string path, int count)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var reader = new StreamReader(stream);
        var tail = new Queue<string>(count);
        while (reader.ReadLine() is { } line)
        {
            if (tail.Count == count) tail.Dequeue();
            tail.Enqueue(line);
        }
        return tail;
    }

    private void PumpBridgeLogTail()
    {
        if (!_tailingAdopted) return;
        try
        {
            var path = BridgeLogPath;
            if (!File.Exists(path)) return;

            var length = new FileInfo(path).Length;
            if (WasLogRotated(_tailOffset, length)) { _tailOffset = 0; _tailRemainder = ""; }
            if (length == _tailOffset) return;

            // FileShare.ReadWrite for the same reason the heartbeat reader uses
            // it: the bridge is writing this file and must not be blocked by
            // something only watching it.
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            stream.Seek(_tailOffset, SeekOrigin.Begin);
            using var reader = new StreamReader(stream);
            var chunk = _tailRemainder + reader.ReadToEnd();
            _tailOffset = length;

            var lines = SplitCompleteLines(chunk, out var remainder);
            foreach (var line in lines) AppendLine(line);
            _tailRemainder = remainder;
        }
        catch { /* a locked or vanished log is not worth interrupting supervision */ }
    }

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
            Ask("لم يتم العثور على pwsh.exe (PowerShell 7).\nثبّته من https://aka.ms/powershell-release ثم أعد المحاولة.",
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
        ResetHealthPills();
        // From here the pane gets this process's own stdout, so following the
        // file as well would print every line twice.
        _tailingAdopted = false;
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
            process.Dispose();
            SetStatus(running: false);
            // A failed launch never "started" at all - treat it as an
            // instant (0-second) run so it counts as a quick failure below.
            _lastStartAt = DateTime.UtcNow;
            ScheduleRetryOrGiveUp();
            return;
        }

        // Every Process is a live OS handle; replacing the field without
        // disposing the old one leaked one per restart, and a crash-looping
        // bridge restarts a lot.
        _bridgeProcess?.Dispose();
        _bridgeProcess = process;
        _lastStartAt = DateTime.UtcNow;
        _lastLivenessSeen = null;
        // A stopped bridge's version is last run's; the next start announces
        // its own, and until it does the manager must not claim the old one.
        _bridgeVersion = null;
        _watchdogInactiveLogged = false;
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
        exitedProcess.Dispose();
        SetStatus(running: false);

        if (_exiting) return;
        if (_restartAfterExit)
        {
            _restartAfterExit = false;
            _stoppingIntentionally = false;
            StartBridge();
            return;
        }
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
            AppendLine($"--- توقف {_consecutiveQuickFailures} مرات متتالية خلال ثوانٍ من كل تشغيل - تم إيقاف إعادة التشغيل التلقائي. راجع الإعدادات ثم اضغط تشغيل يدويًا. ---");
            LogEvent($"توقف متكرر ({_consecutiveQuickFailures} مرات) - تم إيقاف إعادة التشغيل التلقائي.");
            SetHeader("فشل متكرر", Theme.Stopped, "توقف الجسر مرارًا خلال ثوانٍ من كل تشغيل - إعادة التشغيل التلقائي متوقفة.");
            _trayIcon.ShowBalloonTip(10000, "مدير جسر تيليجرام",
                "الجسر يتوقف بشكل متكرر بعد كل تشغيل. تم إيقاف إعادة التشغيل التلقائي - راجع الإعدادات ثم شغّله يدويًا.",
                ToolTipIcon.Error);
            return;
        }

        AppendLine("--- إعادة التشغيل خلال 3 ثوانٍ... ---");
        LogEvent($"سيُعاد التشغيل خلال 3 ثوانٍ (محاولة رقم {_consecutiveQuickFailures}).");
        SetHeader("إعادة التشغيل…", Theme.Pending, "خلال 3 ثوانٍ.");
        _restartTimer.Start();
    }

    // ---- hang detection ----------------------------------------------------

    /// <summary>
    /// Pure decision, so `--selftest` can pin the three cases that must all
    /// answer "not hung": a bridge still booting, a bridge too old to publish
    /// a stamp at all, and a stamp left behind by a previous run. Restarting a
    /// healthy bridge is worse than missing a hang, so every uncertainty here
    /// resolves towards doing nothing.
    /// </summary>
    internal static bool IsHung(DateTime? lastLivenessUtc, DateTime startedUtc, DateTime nowUtc, TimeSpan grace, TimeSpan threshold)
    {
        if (nowUtc - startedUtc < grace) return false;
        if (lastLivenessUtc is null) return false;
        // An older bridge, or a stamp file left over from the previous run: it
        // never advances past this run's start, so it can never be evidence.
        if (lastLivenessUtc.Value < startedUtc) return false;
        return nowUtc - lastLivenessUtc.Value > threshold;
    }

    /// <summary>Reads the stamp the bridge writes once per poll loop. Null when absent or unreadable.</summary>
    private DateTime? ReadLivenessStamp()
    {
        try
        {
            if (string.IsNullOrWhiteSpace(_settings.BridgeScriptPath)) return null;
            var path = LivenessPath;
            if (!File.Exists(path)) return null;
            // FileShare.ReadWrite, because File.ReadAllText opens with
            // FileShare.Read and that denies the writer: the bridge's own log
            // showed "Could not write the liveness stamp ... used by another
            // process" every time a read landed on a write. The bridge retried
            // on its next loop so nothing broke, but a reader has no business
            // blocking the heartbeat it is only observing.
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var reader = new StreamReader(stream);
            var stamp = ParseLiveness(reader.ReadToEnd()).Stamp;
            // Content unreadable but the file is still being touched - the
            // write time alone already says the loop turned over.
            return stamp ?? File.GetLastWriteTimeUtc(path);
        }
        catch { return null; }
    }

    /// <summary>
    /// Splits the heartbeat file into its stamp and the bridge's process id.
    ///
    /// Pure, because adoption decides whether to take over a live bridge on
    /// what this returns, and the file has three shapes to survive: the
    /// single-line form older bridges wrote, the two-line form with the pid,
    /// and either of those carrying the CRLF that Set-Content writes on
    /// Windows - a stray carriage return left on the pid is the whole
    /// difference between adopting a running bridge and reporting it stopped.
    /// </summary>
    internal static (DateTime? Stamp, int? Pid) ParseLiveness(string? content)
    {
        if (string.IsNullOrWhiteSpace(content)) return (null, null);
        var lines = content.Split('\n');

        DateTime? stamp = null;
        if (DateTime.TryParse(lines[0].Trim(), System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.RoundtripKind, out var parsed))
            stamp = parsed.ToUniversalTime();

        int? pid = null;
        if (lines.Length > 1 && int.TryParse(lines[1].Trim(), out var parsedPid) && parsedPid > 0)
            pid = parsedPid;

        return (stamp, pid);
    }

    private void CheckLiveness()
    {
        if (!_watchdogCheck.Checked || _exiting) return;
        if (_bridgeProcess is not { HasExited: false }) return;

        var stamp = ReadLivenessStamp();
        if (stamp is not null) _lastLivenessSeen = stamp;

        var now = DateTime.UtcNow;
        var threshold = TimeSpan.FromMinutes(Math.Max(2, _settings.HangWatchdogMinutes));

        // Say so once, rather than sitting there looking like a working
        // watchdog that never fires: an older bridge publishes no stamp, so
        // there is nothing to watch and nothing will ever restart on its
        // account.
        if (!_watchdogInactiveLogged && now - _lastStartAt > LivenessGrace
            && (_lastLivenessSeen is null || _lastLivenessSeen < _lastStartAt))
        {
            _watchdogInactiveLogged = true;
            AppendLine("--- كشف التعليق غير فعّال: هذه النسخة من الجسر لا تكتب نبضة logs/bridge.liveness. ---");
            LogEvent("كشف التعليق غير فعّال - لا نبضة من الجسر (نسخة أقدم).");
            return;
        }

        if (!IsHung(_lastLivenessSeen, _lastStartAt, now, LivenessGrace, threshold)) return;

        var silentFor = (int)(now - _lastLivenessSeen!.Value).TotalMinutes;
        AppendLine($"--- الجسر يعمل لكنه توقف عن النبض منذ {silentFor} دقيقة - يُعاد تشغيله. ---");
        LogEvent($"كشف تعليق: لا نبضة منذ {silentFor} دقيقة - إعادة تشغيل تلقائية.");
        _trayIcon.ShowBalloonTip(10000, "مدير جسر تيليجرام",
            $"الجسر معلّق (لا استجابة منذ {silentFor} دقيقة). تتم إعادة تشغيله الآن.", ToolTipIcon.Warning);
        _lastLivenessSeen = null;
        RestartBridge();
    }

    // ---- stop / restart ----------------------------------------------------

    private DialogResult Ask(string text, string caption, MessageBoxButtons buttons, MessageBoxIcon icon)
    {
        // Owned by a window that is hidden in the tray, a MessageBox opens
        // behind whatever is on screen and the app looks frozen. Come forward
        // first, so the question appears where the operator is already looking.
        if (!Visible) ShowFromTray();
        return MessageBox.Show(this, text, caption, buttons, icon);
    }

    /// <summary>
    /// Asked at the button, never inside RestartBridge: the hang watchdog and
    /// "save and restart" both call that method too, and a confirmation box
    /// nobody is standing in front of would leave a hung bridge hung.
    /// </summary>
    private bool ConfirmRestart() =>
        Ask("سيتوقف الجسر ثوانٍ حتى يعود، ولن يتحكّم بالرسومات على الهواء خلالها.\n\nمتابعة؟",
            "تأكيد إعادة التشغيل", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes;

    /// <summary>
    /// Confirms only the direction that removes a safety net. Turning one back
    /// on needs no ceremony, and a box that appears both ways teaches people
    /// to dismiss it without reading. Declining puts the switch back without
    /// re-entering this handler.
    /// </summary>
    private bool _revertingToggle;

    private bool ConfirmSafetyOff(CheckBox toggle, string question)
    {
        if (_revertingToggle) return false;
        if (toggle.Checked) return true;

        if (Ask(question, "تأكيد", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes)
            return true;

        _revertingToggle = true;
        toggle.Checked = true;
        _revertingToggle = false;
        return false;
    }

    private bool ConfirmStop() =>
        Ask("سيتوقف الجسر عن التحكم بالرسومات على الهواء.\n\nمتابعة؟",
            "تأكيد الإيقاف", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes;

    private void StopBridge(bool manual)
    {
        _restartAfterExit = false;
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
            _restartAfterExit = true;
            _stoppingIntentionally = true;
            try { process.Kill(entireProcessTree: true); } catch { /* already exiting */ }
            // OnBridgeExited starts the replacement after the old process and
            // its ffmpeg children are actually gone, without freezing the UI.
            return;
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
    // The --autostart argument is what actually closes it: before it, the
    // manager came back from a reboot but the bridge stayed stopped.

    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValueName = "CinegyTelegramBridgeManager";
    internal const string AutoStartArgument = "--autostart";

    /// <summary>
    /// Pulls the exe out of a Run-key command line, which now carries an
    /// argument after it. Comparing the whole stored string against the exe
    /// path would report "not enabled" for an entry this very app just wrote.
    /// </summary>
    internal static string ExtractExePath(string command)
    {
        command = command.Trim();
        if (command.StartsWith('"'))
        {
            var end = command.IndexOf('"', 1);
            if (end > 0) return command[1..end];
        }
        var space = command.IndexOf(' ');
        return space > 0 ? command[..space] : command;
    }

    private static bool IsStartWithWindowsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
            return key?.GetValue(RunValueName) is string existing
                && string.Equals(ExtractExePath(existing), Application.ExecutablePath, StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    private static void SetStartWithWindows(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true)
                ?? Registry.CurrentUser.CreateSubKey(RunKeyPath);
            if (enabled) key.SetValue(RunValueName, $"\"{Application.ExecutablePath}\" {AutoStartArgument}");
            else key.DeleteValue(RunValueName, throwOnMissingValue: false);
        }
        catch { /* registry access denied in some locked-down environments - not fatal */ }
    }

    // ---- header and status -------------------------------------------------

    private void SetHeader(string state, Color colour, string detail)
    {
        _stateLabel.Text = state;
        _stateLabel.ForeColor = colour;
        _accentBar.BackColor = colour;
        _stateDetail.Text = detail;
    }

    private void SetStatus(bool running)
    {
        _running = running;
        SetHeader(running ? "يعمل" : "متوقف",
            running ? Theme.Running : Theme.Stopped,
            running ? "" : "الجسر لا يتحكم بالرسومات على الهواء الآن.");
        UpdateStateDetail();
        // One primary action at a time. Three buttons of equal weight, two of
        // them dead, is a decision to make during an incident; the one that
        // can be pressed is the one that is there.
        _startButton.Enabled = !running;
        _startButton.Visible = !running;
        _stopButton.Enabled = running;
        _stopButton.Visible = running;
        _restartButton.Enabled = running;
        _trayIcon.Text = running ? "مدير جسر تيليجرام - يعمل" : "مدير جسر تيليجرام - متوقف";
        UpdateStatusBar();
    }

    private void UpdateStateDetail()
    {
        if (!_running || _bridgeProcess is not { HasExited: false }) return;
        var up = DateTime.UtcNow - _lastStartAt;
        // The bridge's version when its startup line has gone past, and the
        // manager's own beside it - named, because the two are deliberately
        // different numbers and an unlabelled one is read as the bridge's.
        var versions = _bridgeVersion is null
            ? $"المدير v{Application.ProductVersion}"
            : $"الجسر v{_bridgeVersion}  ·  المدير v{Application.ProductVersion}";
        _stateDetail.Text = $"يعمل منذ {FormatSpan(up)}  ·  المعرّف {_bridgeProcess.Id}  ·  {versions}";
        // The whole line on hover, so a narrow window hides nothing outright.
        _tips.SetToolTip(_stateDetail, _stateDetail.Text);
    }

    private static string FormatSpan(TimeSpan span)
    {
        if (span.TotalMinutes < 1) return $"{Math.Max(0, (int)span.TotalSeconds)} ثانية";
        if (span.TotalHours < 1) return $"{(int)span.TotalMinutes} دقيقة";
        if (span.TotalDays < 1) return $"{(int)span.TotalHours} ساعة و{span.Minutes} دقيقة";
        return $"{(int)span.TotalDays} يوم و{span.Hours} ساعة";
    }

    private void UpdateStatusBar()
    {
        var filtering = _errorsOnlyCheck.Checked || !string.IsNullOrWhiteSpace(_filterBox.Text);
        _lineCountLabel.Text = filtering
            ? $"المعروض: {_lines.Count(l => ShouldShow(l, _filterBox.Text, _errorsOnlyCheck.Checked))} من {_lines.Count}"
            : $"الأسطر: {_lines.Count}";

        if (!_watchdogCheck.Checked) _livenessLabel.Text = "كشف التعليق: معطّل";
        else if (!_running) _livenessLabel.Text = "كشف التعليق: مفعّل";
        else
        {
            var stamp = ReadLivenessStamp();
            if (stamp is not null) _lastLivenessSeen = stamp;
            _livenessLabel.Text = _lastLivenessSeen is null || _lastLivenessSeen < _lastStartAt
                ? "كشف التعليق: بانتظار أول نبضة…"
                : $"آخر نبضة: قبل {FormatSpan(DateTime.UtcNow - _lastLivenessSeen.Value)}";
        }

        _pathLabel.Text = string.IsNullOrWhiteSpace(_settings.BridgeScriptPath)
            ? "مسار الجسر: غير محدد"
            : $"مسار الجسر: {BridgeRoot}";
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

    // ---- the log pane ------------------------------------------------------

    internal static LogLineKind ClassifyLine(string line)
    {
        if (line.StartsWith("---", StringComparison.Ordinal)) return LogLineKind.Manager;
        if (line.Contains("[ERROR]", StringComparison.Ordinal)) return LogLineKind.Error;
        if (line.Contains("[WARN]", StringComparison.Ordinal)) return LogLineKind.Warning;
        if (line.Contains("[DEBUG]", StringComparison.Ordinal)) return LogLineKind.Debug;
        return LogLineKind.Normal;
    }

    private static Color ColorFor(LogLineKind kind) => kind switch
    {
        LogLineKind.Manager => Theme.LogManager,
        LogLineKind.Error => Theme.LogError,
        LogLineKind.Warning => Theme.LogWarning,
        LogLineKind.Debug => Theme.LogDebug,
        _ => Theme.LogNormal
    };

    private static Color ColorFor(LogHighlightKind kind) => kind switch
    {
        LogHighlightKind.Timestamp => Theme.LogTimestamp,
        LogHighlightKind.Level => Theme.LogLevel,
        LogHighlightKind.OperationId => Theme.LogOperation,
        LogHighlightKind.Layer => Theme.LogField,
        LogHighlightKind.Success => Theme.Running,
        LogHighlightKind.Failure => Theme.LogError,
        _ => Theme.LogNormal
    };

    internal static IReadOnlyList<LogHighlight> GetLogHighlights(string line)
    {
        var highlights = new List<LogHighlight>();
        AddMatches(@"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", LogHighlightKind.Timestamp);
        AddMatches(@"\[(?:ERROR|WARN|INFO|DEBUG)\]", LogHighlightKind.Level);
        AddMatches(@"\bair-[a-f0-9]{8,}\b", LogHighlightKind.OperationId);
        AddMatches(@"\b(?:layer|طبقة)\s*[=:]?\s*\d+", LogHighlightKind.Layer);
        AddMatches(@"\b(?:success|succeeded|healthy|running)\b", LogHighlightKind.Success);
        AddMatches(@"\b(?:failed|failure|blocked|error|timeout|unhealthy)\b", LogHighlightKind.Failure);
        return highlights;

        void AddMatches(string pattern, LogHighlightKind kind)
        {
            foreach (Match match in Regex.Matches(line, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                highlights.Add(new LogHighlight(match.Index, match.Length, kind, match.Value));
        }
    }

    internal static PendingDrainPlan GetPendingDrainPlan(int pendingCount, int warningCount, int errorCount) =>
        new(Math.Min(Math.Max(0, pendingCount), MaxLinesPerUiDrain), warningCount > 0 || errorCount > 0);

    internal static string LimitDisplayedLogLine(string line) =>
        line.Length <= MaxDisplayedLineLength
            ? line
            : line[..MaxDisplayedLineLength] + " … [السطر قُصّر في العرض؛ راجع bridge.log للنص الكامل]";

    /// <summary>Pure, so `--selftest` can pin it: an empty filter shows everything.</summary>
    /// <summary>
    /// What to put in the log pane when nothing has been written into it, or
    /// null when there is something to show.
    /// </summary>
    /// <remarks>
    /// An empty pane is not neutral: this window's whole job is to say whether
    /// the bridge is alive, so a blank column reads as "it stopped logging" -
    /// the same confusion a manager showed after adopting a running bridge and
    /// leaving its pane empty. Typing a filter that matches nothing produced
    /// exactly that, with only a small "المعروض: 0 من 1842" at the foot of the
    /// window to say otherwise.
    ///
    /// The three empty panes are three different situations and get three
    /// different sentences: nothing has arrived yet, the filter excluded
    /// everything, or the errors-only chip did. Each names the way out.
    /// </remarks>
    internal static string? EmptyStateMessage(int totalLines, int shownLines, string filter, bool errorsOnly)
    {
        if (shownLines > 0) return null;
        if (totalLines == 0)
            return "لا توجد أسطر بعد. تظهر هنا مخرجات الجسر فور تشغيله.";

        var hasFilter = !string.IsNullOrWhiteSpace(filter);
        if (hasFilter && errorsOnly)
            return $"لا سطر يطابق «{filter.Trim()}» ضمن الأخطاء والتحذيرات، من {totalLines} سطرًا. "
                 + "امسح التصفية (Esc) أو ألغِ «الأخطاء والتحذيرات فقط».";
        if (hasFilter)
            return $"لا سطر يطابق «{filter.Trim()}» من {totalLines} سطرًا. امسح التصفية بمفتاح Esc.";
        if (errorsOnly)
            return $"لا أخطاء ولا تحذيرات ضمن {totalLines} سطرًا — وهذا هو المطلوب. "
                 + "ألغِ «الأخطاء والتحذيرات فقط» لرؤية بقية السجل.";

        // Every line filtered out with nothing filtering: not reachable today,
        // but a blank pane must never be the answer.
        return $"لا شيء معروض من {totalLines} سطرًا.";
    }

    internal static bool ShouldShow(string line, string filter, bool errorsOnly)
    {
        if (errorsOnly)
        {
            var kind = ClassifyLine(line);
            if (kind != LogLineKind.Error && kind != LogLineKind.Warning) return false;
        }
        if (string.IsNullOrWhiteSpace(filter)) return true;
        return line.Contains(filter.Trim(), StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Queues a line from any thread without letting a noisy INFO burst own the UI's memory.</summary>
    private void AppendLine(string line)
    {
        line = LimitDisplayedLogLine(line);
        var kind = ClassifyLine(line);
        var priority = kind is LogLineKind.Error or LogLineKind.Warning or LogLineKind.Manager;
        var queue = priority ? _pendingPriority : _pendingInformational;
        var limit = priority ? MaxPendingPriorityLines : MaxPendingInformationalLines;
        lock (_pendingGate)
        {
            var count = priority ? _pendingPriorityCount : _pendingInformationalCount;
            if (count >= limit)
            {
                // Keep the newest operating evidence. The full bridge log remains
                // on disk; this is only the bounded, live dashboard scrollback.
                queue.TryDequeue(out _);
                if (priority) _droppedPriorityLines++;
                else _droppedInformationalLines++;
            }
            else if (priority) _pendingPriorityCount++;
            else _pendingInformationalCount++;
            queue.Enqueue((++_pendingSequence, line));
        }
    }

    private void DrainPending()
    {
        if (IsDisposed) return;

        var filter = _filterBox.Text;
        var errorsOnly = _errorsOnlyCheck.Checked;
        var appended = false;
        var trimNeeded = false;

        int pendingCount;
        int priorityCount;
        lock (_pendingGate)
        {
            pendingCount = _pendingPriorityCount + _pendingInformationalCount;
            priorityCount = _pendingPriorityCount;
        }
        var plan = GetPendingDrainPlan(pendingCount, warningCount: priorityCount, errorCount: 0);
        var processed = 0;
        while (processed < plan.ProcessNow && TryDequeuePending(out var line))
        {
            processed++;
            _lines.Add(line);
            ApplyHealthLine(line);
            if (_lines.Count > MaxOutputLines) trimNeeded = true;
            if (!ShouldShow(line, filter, errorsOnly)) continue;
            // The pane is holding "لا سطر يطابق…" and a line just arrived that
            // does. Appending under the note would leave the note contradicting
            // the line right below it, so the pane is rebuilt once on the way
            // out of the empty state - a transition, not a per-line cost.
            if (_showingEmptyState) { RenderAll(); return; }
            WriteLine(line);
            appended = true;
        }

        if (trimNeeded)
        {
            _lines.RemoveRange(0, _lines.Count - (MaxOutputLines * 3 / 4));
            RenderAll();
            return;
        }

        int droppedPriority;
        int droppedInformational;
        lock (_pendingGate)
        {
            droppedPriority = _droppedPriorityLines;
            droppedInformational = _droppedInformationalLines;
            _droppedPriorityLines = 0;
            _droppedInformationalLines = 0;
        }
        if (droppedPriority + droppedInformational > 0)
        {
            var summary = $"--- خفّض المدير ضغط السجل: حُذفت {droppedInformational} رسالة معلومات و{droppedPriority} رسالة تحذير/خطأ قديمة من العرض. السجل الكامل محفوظ في bridge.log. ---";
            _lines.Add(summary);
            if (ShouldShow(summary, filter, errorsOnly)) { WriteLine(summary); appended = true; }
        }
        if (appended)
        {
            _output.SelectionStart = _output.TextLength;
            _output.ScrollToCaret();
        }
        UpdateStatusBar();
    }

    internal static bool PriorityComesFirst(long? prioritySequence, long? informationalSequence) =>
        prioritySequence.HasValue && (!informationalSequence.HasValue || prioritySequence.Value < informationalSequence.Value);

    private bool TryDequeuePending(out string line)
    {
        lock (_pendingGate)
        {
            var hasPriority = _pendingPriority.TryPeek(out var priority);
            var hasInfo = _pendingInformational.TryPeek(out var informational);
            // Retention has separate caps; display merges surviving entries in arrival order.
            var takePriority = PriorityComesFirst(hasPriority ? priority.Sequence : null, hasInfo ? informational.Sequence : null);
            var queue = takePriority ? _pendingPriority : _pendingInformational;
            if (queue.TryDequeue(out var entry))
            {
                if (takePriority) _pendingPriorityCount--;
                else _pendingInformationalCount--;
                line = entry.Text;
                return true;
            }
        }
        line = string.Empty;
        return false;
    }

    private void WriteLine(string line)
    {
        var start = _output.TextLength;
        _output.SelectionStart = start;
        _output.SelectionLength = 0;
        _output.SelectionColor = ColorFor(ClassifyLine(line));
        _output.AppendText(line + Environment.NewLine);
        foreach (var highlight in GetLogHighlights(line))
        {
            _output.SelectionStart = start + highlight.Start;
            _output.SelectionLength = highlight.Length;
            _output.SelectionColor = ColorFor(highlight.Kind);
        }
        _output.SelectionStart = _output.TextLength;
        _output.SelectionLength = 0;
    }

    /// <summary>A note from the manager itself, not a line off the bridge.</summary>
    private void WriteMutedLine(string text)
    {
        _output.SelectionStart = _output.TextLength;
        _output.SelectionLength = 0;
        _output.SelectionColor = Theme.TextMuted;
        _output.AppendText(text + Environment.NewLine);
        _output.SelectionStart = _output.TextLength;
        _output.SelectionLength = 0;
    }

    private void RenderAll()
    {
        var filter = _filterBox.Text;
        var errorsOnly = _errorsOnlyCheck.Checked;

        // Repainting per line while rebuilding a couple of thousand of them is
        // the difference between a flicker-free redraw and a window that
        // visibly stutters every time a letter is typed into the filter box.
        SendMessage(_output.Handle, WM_SETREDRAW, IntPtr.Zero, IntPtr.Zero);
        try
        {
            _output.Clear();
            var shown = 0;
            foreach (var line in _lines)
            {
                if (!ShouldShow(line, filter, errorsOnly)) continue;
                WriteLine(line);
                shown++;
            }
            // Said in the pane itself, not only in the small count at the foot
            // of the window: the pane is where the operator is looking.
            var empty = EmptyStateMessage(_lines.Count, shown, filter, errorsOnly);
            _showingEmptyState = empty is not null;
            if (empty is not null) WriteMutedLine(empty);
        }
        finally
        {
            SendMessage(_output.Handle, WM_SETREDRAW, new IntPtr(1), IntPtr.Zero);
            _output.Invalidate();
        }

        _output.SelectionStart = _output.TextLength;
        _output.ScrollToCaret();
        UpdateStatusBar();
    }

    private void ClearOutput()
    {
        _lines.Clear();
        _output.Clear();
        lock (_pendingGate)
        {
            while (_pendingPriority.TryDequeue(out _)) { }
            while (_pendingInformational.TryDequeue(out _)) { }
            _pendingPriorityCount = 0;
            _pendingInformationalCount = 0;
            _droppedPriorityLines = 0;
            _droppedInformationalLines = 0;
        }
        UpdateStatusBar();
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

    private bool StopForSettingsSave()
    {
        _restartTimer.Stop();
        _restartAfterExit = false;
        _stoppingIntentionally = true;
        if (_bridgeProcess is not { } process) return true;
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            if (!process.WaitForExit(10000)) return false;
            // Consume the exit now: its queued UI callback must not stop a replacement.
            OnBridgeExited(process);
            SetHeader("الجسر متوقف", Theme.Stopped, "جارٍ حفظ الإعدادات؛ عند فشل الحفظ يبقى الجسر متوقفًا.");
            return true;
        }
        catch
        {
            SetHeader("تعذّر الإيقاف", Theme.Pending, "لم تُحفظ الإعدادات؛ تحقّق من حالة الجسر.");
            return false;
        }
    }
    private void OpenSettings()
    {
        if (!EnsureBridgeScriptResolved()) return;
        using var form = new SettingsForm(ConfigPath, BridgeRoot, _bridgeProcess is { HasExited: false }, StopForSettingsSave);
        if (form.ShowDialog(this) == DialogResult.OK)
        {
            LogEvent("تم حفظ الإعدادات من واجهة المدير.");
            if (form.RestartRequested) StartBridge(manual: true);
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
            var confirm = Ask("سيتم إيقاف الجسر أيضًا عند الخروج.\n\nمتابعة؟",
                "تأكيد الخروج", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (confirm != DialogResult.Yes) return;
        }
        // Written before anything else shuts down, because the value of this
        // line is mostly in its absence: every deliberate way out of this
        // program now leaves a record, so a manager that is simply gone from
        // the tray with nothing in manager.log was ended from outside - killed
        // by a task manager, an installer, or a build that needed the exe
        // unlocked. Without the line, "it closed by itself" and "something
        // closed it" are the same evidence.
        LogEvent("إغلاق برنامج المدير بطلب من المستخدم - يتم إيقاف الجسر.");
        _exiting = true;
        _trayIcon.Visible = false;
        StopBridge(manual: true);
        Application.Exit();
    }

    private void MainForm_FormClosing(object? sender, FormClosingEventArgs e)
    {
        if (_exiting) return;

        // Windows shutting down, or Task Manager ending the task, is not a
        // request to hide: cancelling it makes Windows put up the "this app is
        // preventing shutdown" wall and then kill the process anyway - with no
        // log line written and the tray icon left as a ghost until something
        // happens to hover over it.
        if (e.CloseReason is CloseReason.WindowsShutDown or CloseReason.TaskManagerClosing or CloseReason.ApplicationExitCall)
        {
            _exiting = true;
            _trayIcon.Visible = false;
            LogEvent($"إغلاق النظام ({e.CloseReason}) - يتم إيقاف الجسر.");
            StopBridge(manual: true);
            return;
        }

        // Closing the window just hides it to the tray - the bridge keeps
        // running and supervised.
        e.Cancel = true;
        Hide();

        // Once, not once per close. The comment here has said "once" since the
        // balloon was added and the code never did it, so every close put a
        // notification on screen; an operator who hides this window a dozen
        // times a shift reads that as the window asking permission to close.
        // The first one is worth showing - a window that refuses to close
        // without explanation reads as a bug - and the rest are noise.
        if (!_settings.TrayHintShown)
        {
            _settings.TrayHintShown = true;
            _settings.Save();
            _trayIcon.ShowBalloonTip(4000, "لا يزال يعمل",
                "المدير يتابع الجسر من شريط النظام. للإغلاق نهائيًا: زر يمين على الأيقونة ← إغلاق البرنامج.",
                ToolTipIcon.Info);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _filterTimer.Stop();
            _filterTimer.Dispose();
            // A NotifyIcon that is never disposed leaves a dead icon sitting in
            // the tray until the mouse happens to pass over it.
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _appIcon.Dispose();
            _tips.Dispose();
            _bridgeProcess?.Dispose();
        }
        base.Dispose(disposing);
    }
}
