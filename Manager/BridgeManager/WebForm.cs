using System.Diagnostics;

namespace BridgeManager;

/// <summary>
/// The web interface, controlled from one place: whether the bridge opens its
/// web channel, the local web server, and the Cloudflare tunnel that makes it
/// reachable from outside. Closing this window stops nothing; the processes
/// belong to the manager and stop with it.
/// </summary>
public sealed class WebForm : Form
{
    private readonly WebHost _host;
    private readonly string _configPath;
    private readonly Func<bool, Task<bool>> _applyBridgeSetting;
    private readonly Action<bool> _saveAutoStart;

    private readonly Label _bridgeState = State();
    private readonly Button _bridgeToggle = Theme.QuietButton("");
    private readonly Label _serverState = State();
    private readonly Button _serverToggle = Theme.QuietButton("");
    private readonly LinkLabel _localLink = new() { AutoSize = true, Font = Theme.Ui, Margin = new Padding(0, 6, 0, 0) };
    private readonly Label _tunnelState = State();
    private readonly Button _tunnelToggle = Theme.QuietButton("");
    private readonly TextBox _publicUrl = Theme.Input(360);
    private readonly Button _copyUrl = Theme.QuietButton("📋  نسخ الرابط");
    private readonly Label _problem;
    private readonly CheckBox _autoStart;

    internal WebForm(WebHost host, string configPath, bool autoStart, Func<bool, Task<bool>> applyBridgeSetting, Action<bool> saveAutoStart)
    {
        _host = host;
        _configPath = configPath;
        _applyBridgeSetting = applyBridgeSetting;
        _saveAutoStart = saveAutoStart;

        Text = "واجهة الويب";
        Width = 720;
        Height = 560;
        MinimumSize = new Size(620, 480);
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = false;
        BackColor = Theme.Background;
        ForeColor = Theme.Text;
        Font = Theme.Ui;
        RightToLeft = RightToLeft.Yes;
        RightToLeftLayout = true;

        // Not a themed hint: Theme.Apply would paint it muted, and this one is a warning.
        _problem = new Label { AutoSize = true, Font = Theme.UiSmall, ForeColor = Theme.Stopped, MaximumSize = new Size(640, 0), Margin = new Padding(0, 10, 0, 0) };
        _publicUrl.ReadOnly = true;
        _publicUrl.RightToLeft = RightToLeft.No;
        _localLink.RightToLeft = RightToLeft.No;
        _autoStart = Theme.ToggleChip("تشغيل الخادم والنفق مع فتح المدير");
        _autoStart.Checked = autoStart;

        var layout = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
            Padding = new Padding(22, 12, 22, 12),
        };
        layout.Controls.Add(Theme.Heading("١ — قناة الجسر"));
        layout.Controls.Add(Theme.Hint("الجسر يفتح قناة محلية لا يصل إليها إلا هذا الجهاز، والخادم يكلّم الجسر عبرها وحدها. تغييرها يعيد تشغيل الجسر."));
        layout.Controls.Add(Row(_bridgeState, _bridgeToggle));

        layout.Controls.Add(Theme.Heading("٢ — خادم الويب"));
        layout.Controls.Add(Theme.Hint("يعمل على هذا الجهاز فقط (localhost). لا يكلّم Cinegy ولا Telegram."));
        layout.Controls.Add(Row(_serverState, _serverToggle));
        layout.Controls.Add(_localLink);

        layout.Controls.Add(Theme.Heading("٣ — الوصول من الخارج (Cloudflare Tunnel)"));
        layout.Controls.Add(Theme.Hint("رابط مؤقت مجاني يتغيّر مع كل تشغيل. لا يُفتح أي منفذ في الراوتر، ومنفذ Cinegy لا يمرّ منه أبدًا."));
        layout.Controls.Add(Row(_tunnelState, _tunnelToggle));
        layout.Controls.Add(Row(_publicUrl, _copyUrl));

        layout.Controls.Add(Theme.Heading("خيارات"));
        layout.Controls.Add(_autoStart);
        var logsButton = Theme.QuietButton("📂  سجلات الويب");
        layout.Controls.Add(logsButton);
        layout.Controls.Add(_problem);
        Controls.Add(layout);

        _bridgeToggle.Click += async (_, _) => await ToggleBridgeSetting();
        _serverToggle.Click += (_, _) => { if (_host.ServerRunning) _host.StopServer(); else _host.StartServer(); };
        _tunnelToggle.Click += (_, _) => { if (_host.TunnelRunning) _host.StopTunnel(); else _host.StartTunnel(); };
        _copyUrl.Click += (_, _) => { if (_host.TunnelUrl.Length > 0) Clipboard.SetText(_host.TunnelUrl); };
        _localLink.LinkClicked += (_, _) => Open(_host.LocalUrl);
        _autoStart.CheckedChanged += (_, _) => _saveAutoStart(_autoStart.Checked);
        logsButton.Click += (_, _) => OpenLogs();

        _host.Changed += OnHostChanged;
        FormClosed += (_, _) => _host.Changed -= OnHostChanged;
        Theme.Apply(this);
        Refresh();
    }

    private void OnHostChanged()
    {
        if (IsDisposed) return;
        try { BeginInvoke(Refresh); }
        catch (InvalidOperationException) { /* closing */ }
    }

    public override void Refresh()
    {
        var bridgeOn = WebHost.ReadBridgeSetting(_configPath);
        SetState(_bridgeState, bridgeOn, "مفتوحة", "مغلقة");
        _bridgeToggle.Text = bridgeOn ? "إغلاق القناة" : "فتح القناة";

        SetState(_serverState, _host.ServerRunning, "يعمل", "متوقف");
        _serverToggle.Text = _host.ServerRunning ? "■  إيقاف الخادم" : "▶  تشغيل الخادم";
        _localLink.Text = _host.ServerRunning ? _host.LocalUrl : "";

        var tunnelLabel = _host.TunnelRunning && _host.TunnelUrl.Length == 0 ? "يتصل…" : null;
        SetState(_tunnelState, _host.TunnelRunning, tunnelLabel ?? "متصل", "متوقف");
        _tunnelToggle.Text = _host.TunnelRunning ? "■  إيقاف النفق" : "▶  تشغيل النفق";
        _tunnelToggle.Enabled = _host.ServerRunning;
        _publicUrl.Text = _host.TunnelUrl;
        _copyUrl.Enabled = _host.TunnelUrl.Length > 0;

        _problem.Text = _host.LastProblem.Length > 0 ? _host.LastProblem
            : !bridgeOn && _host.ServerRunning ? "الخادم يعمل لكن قناة الجسر مغلقة: الصفحة ستقول إن الجسر لا يجيب."
            : "";
        base.Refresh();
    }

    private async Task ToggleBridgeSetting()
    {
        var enable = !WebHost.ReadBridgeSetting(_configPath);
        _bridgeToggle.Enabled = false;
        try { await _applyBridgeSetting(enable); }
        finally
        {
            _bridgeToggle.Enabled = true;
            Refresh();
        }
    }

    private void OpenLogs()
    {
        var folder = Path.Combine(Path.GetDirectoryName(_configPath)!, "logs", "web");
        Directory.CreateDirectory(folder);
        using var explorer = Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });
    }

    private static void Open(string url)
    {
        using var browser = Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    }

    private static void SetState(Label label, bool on, string onText, string offText)
    {
        label.Text = "●  " + (on ? onText : offText);
        label.ForeColor = on ? Theme.Running : Theme.TextMuted;
    }

    private static Label State() => new() { AutoSize = true, Font = Theme.UiBold, Margin = new Padding(0, 8, 16, 0), MinimumSize = new Size(110, 0) };

    private static FlowLayoutPanel Row(params Control[] controls)
    {
        var row = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, Margin = new Padding(0, 0, 0, 4) };
        row.Controls.AddRange(controls);
        return row;
    }
}
