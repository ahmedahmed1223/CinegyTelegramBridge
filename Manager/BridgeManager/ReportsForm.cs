using System.Globalization;
using System.Text.Json.Nodes;

namespace BridgeManager;

/// <summary>
/// Two reports from what this machine already records - nothing the bot must
/// compute twice and nothing that can drift from it.
///
/// Tab one ranks templates by the bridge's own usage.json (count, last use).
/// Tab two counts this supervisor's own history out of manager.log: starts,
/// manual stops, watchdog restarts, crash-loop give-ups - plus the errors the
/// live window saw in the last hour, handed in by the main form.
///
/// Read-only throughout, like the on-air window: reports explain, they do
/// not act. The two "tabs" are toggle chips switching panels, not a
/// TabControl: the system tab renderer paints a light strip that survives
/// the dark palette.
/// </summary>
public sealed class ReportsForm : Form
{
    internal sealed record TemplateUsage(string Key, int Count, DateTime? LastUsedUtc);
    internal sealed record StabilitySummary(int Starts, int ManualStops, int WatchdogRestarts, int GiveUps);

    private readonly string _bridgeRoot;
    private readonly int _errorsLastHour;
    private readonly BarChart _chart = new();
    private readonly Label _usageFootnote;
    private readonly Panel _usagePage = new() { Dock = DockStyle.Fill, BackColor = Theme.Background, Padding = new Padding(14, 6, 14, 10) };
    private readonly Panel _healthPage = new() { Dock = DockStyle.Fill, BackColor = Theme.Background, Padding = new Padding(18, 6, 18, 10), AutoScroll = true, Visible = false };
    private readonly CheckBox _usageChip;
    private readonly CheckBox _healthChip;
    private readonly Label _startsValue;
    private readonly Label _stopsValue;
    private readonly Label _watchdogValue;
    private readonly Label _giveupsValue;
    private readonly Label _errorsValue;
    private readonly Panel _watchdogAccent;
    private readonly Panel _giveupsAccent;
    private readonly Panel _errorsAccent;
    private readonly ToolTip _tips = new() { AutoPopDelay = 12000, InitialDelay = 500, ReshowDelay = 200 };

    public ReportsForm(string bridgeRoot, int errorsLastHour)
    {
        _bridgeRoot = bridgeRoot;
        _errorsLastHour = errorsLastHour;

        Text = "تقارير التشغيل";
        Width = 720;
        Height = 560;
        MinimumSize = new Size(560, 420);
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.Sizable;
        MaximizeBox = true;
        MinimizeBox = false;
        BackColor = Theme.Background;
        ForeColor = Theme.Text;
        Font = Theme.Ui;
        RightToLeft = RightToLeft.Yes;
        RightToLeftLayout = true;

        var header = new Panel { Dock = DockStyle.Top, Height = 62, BackColor = Theme.Surface, Padding = new Padding(18, 10, 18, 10) };
        var headerHint = new Label { Dock = DockStyle.Top, Height = 18, Text = "من ملفات هذا الجهاز نفسها — عرض فقط.", Font = Theme.UiSmall, ForeColor = Theme.TextMuted };
        var headerTitle = new Label { Dock = DockStyle.Top, Height = 22, Text = "📊 تقارير التشغيل", Font = Theme.SectionHeading, ForeColor = Theme.Text };
        header.Controls.Add(headerHint);
        header.Controls.Add(headerTitle);

        var switchRow = new FlowLayoutPanel
        {
            Dock = DockStyle.Top, AutoSize = true, FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false, Padding = new Padding(14, 10, 14, 2), BackColor = Theme.Background
        };
        _usageChip = Theme.ToggleChip("استخدام القوالب");
        _healthChip = Theme.ToggleChip("استقرار التشغيل");
        _usageChip.Checked = true;
        _usageChip.CheckedChanged += (_, _) => { if (_usageChip.Checked) { _healthChip.Checked = false; ShowPage(_usagePage); } else if (!_healthChip.Checked) _usageChip.Checked = true; };
        _healthChip.CheckedChanged += (_, _) => { if (_healthChip.Checked) { _usageChip.Checked = false; ShowPage(_healthPage); } else if (!_usageChip.Checked) _healthChip.Checked = true; };
        switchRow.Controls.AddRange(new Control[] { _usageChip, _healthChip });

        var usageHint = new Label { Dock = DockStyle.Top, Height = 20, Text = "مرتبة بالأكثر نشرًا، من عدّاد الجسر.", Font = Theme.UiSmall, ForeColor = Theme.TextMuted };
        _usageFootnote = new Label { Dock = DockStyle.Bottom, Height = 20, Text = "", Font = Theme.UiSmall, ForeColor = Theme.TextMuted, TextAlign = ContentAlignment.MiddleRight };
        _chart.Dock = DockStyle.Fill;
        _chart.EmptyText = "لا استخدام مسجل بعد.";
        _usagePage.Controls.Add(_chart);
        _usagePage.Controls.Add(usageHint);
        _usagePage.Controls.Add(_usageFootnote);

        var healthHint = new Label { Dock = DockStyle.Top, Height = 20, Text = "إقلاعات اليوم من سجل المدير، والأخطاء من الساعة الأخيرة.", Font = Theme.UiSmall, ForeColor = Theme.TextMuted };
        var statsFlow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = true, Padding = new Padding(0, 8, 0, 4) };
        (_startsValue, _) = StatTile(statsFlow, "إقلاعات الجسر اليوم", Theme.Accent);
        (_stopsValue, _) = StatTile(statsFlow, "إيقافات يدوية اليوم", Theme.Accent);
        (_watchdogValue, _watchdogAccent) = StatTile(statsFlow, "إعادة تشغيل لكشف التعليق", Theme.Border);
        (_giveupsValue, _giveupsAccent) = StatTile(statsFlow, "توقف متكرر أوقف التلقائي", Theme.Border);
        (_errorsValue, _errorsAccent) = StatTile(statsFlow, "أخطاء الساعة الأخيرة", Theme.Border);
        _healthPage.Controls.Add(statsFlow);
        // Added bottom-up: DockStyle.Top stacks in reverse addition order.
        _healthPage.Controls.Add(healthHint);

        var buttons = new Panel { Dock = DockStyle.Bottom, Height = 60, BackColor = Theme.Surface, Padding = new Padding(18, 12, 18, 12) };
        var buttonFlow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, WrapContents = false };
        var refreshButton = Theme.QuietButton("🔄 تحديث");
        refreshButton.Width = 120;
        refreshButton.Click += (_, _) => Reload();
        var closeButton = Theme.QuietButton("إغلاق");
        closeButton.Width = 100;
        closeButton.DialogResult = DialogResult.Cancel;
        buttonFlow.Controls.AddRange(new Control[] { refreshButton, closeButton });
        buttons.Controls.Add(buttonFlow);

        Controls.Add(_usagePage);
        Controls.Add(_healthPage);
        Controls.Add(switchRow);
        Controls.Add(buttons);
        Controls.Add(header);

        CancelButton = closeButton;
        Load += (_, _) => Reload();
        Disposed += (_, _) => _tips.Dispose();
    }

    private void ShowPage(Panel page)
    {
        _usagePage.Visible = page == _usagePage;
        _healthPage.Visible = page == _healthPage;
    }

    /// <summary>
    /// One stability metric as a card: a big number over a caption, with a
    /// thin top bar carrying the colour. The bar starts at <paramref
    /// name="accentColor"/> and Reload() repaints it once real counts are
    /// known, so a stack of five equal-weight numbers reads instead as one
    /// calm signal and two or three that want a glance.
    /// </summary>
    private static (Label Value, Panel Accent) StatTile(Control parent, string caption, Color accentColor)
    {
        var tile = new Panel { Width = 168, Height = 92, BackColor = Theme.Surface, Margin = new Padding(0, 0, 10, 10) };
        var name = new Label { Dock = DockStyle.Fill, Text = caption, Font = Theme.UiSmall, ForeColor = Theme.TextMuted, TextAlign = ContentAlignment.TopCenter, Padding = new Padding(8, 0, 8, 10) };
        var value = new Label { Dock = DockStyle.Top, Height = 46, Text = "—", Font = Theme.Title, ForeColor = Theme.Text, TextAlign = ContentAlignment.MiddleCenter };
        var accent = new Panel { Dock = DockStyle.Top, Height = 3, BackColor = accentColor };
        tile.Controls.Add(name);
        tile.Controls.Add(value);
        tile.Controls.Add(accent);
        parent.Controls.Add(tile);
        return (value, accent);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.ApplyTitleBar(Handle);
    }

    private void Reload()
    {
        try
        {
            var names = OnAirForm.ReadTemplateNames(ReadSharedFile(Path.Combine(_bridgeRoot, "templates.json")));
            var usage = ParseUsageFile(ReadSharedFile(Path.Combine(_bridgeRoot, "logs", "usage.json")));
            var bars = BuildUsageBars(usage, key => names.TryGetValue(key, out var friendly) ? friendly : key);
            _chart.SetData(bars);
            // The chart caps at eight bars; the ninth template down must be
            // named, not silently missing.
            var hidden = Math.Max(0, usage.Count - bars.Count);
            _usageFootnote.Text = hidden == 0 ? "" : $"يعرض أول 8 من {usage.Count}.";

            var logLines = ReadSharedFile(Path.Combine(_bridgeRoot, "logs", "manager.log"))?
                .Split('\n') ?? Array.Empty<string>();
            var summary = SummarizeManagerLog(logLines, DateTime.Now.Date);
            _startsValue.Text = summary.Starts.ToString(CultureInfo.CurrentCulture);
            _stopsValue.Text = summary.ManualStops.ToString(CultureInfo.CurrentCulture);
            _watchdogValue.Text = summary.WatchdogRestarts.ToString(CultureInfo.CurrentCulture);
            _giveupsValue.Text = summary.GiveUps.ToString(CultureInfo.CurrentCulture);
            _errorsValue.Text = _errorsLastHour.ToString(CultureInfo.CurrentCulture);
            _errorsValue.ForeColor = _errorsLastHour == 0 ? Theme.Running : Theme.Stopped;
            // Calm when zero, coloured only when the number says look here.
            _watchdogAccent.BackColor = summary.WatchdogRestarts == 0 ? Theme.Running : Theme.Pending;
            _giveupsAccent.BackColor = summary.GiveUps == 0 ? Theme.Running : Theme.Stopped;
            _errorsAccent.BackColor = _errorsLastHour == 0 ? Theme.Running : Theme.Stopped;
        }
        catch { /* a half-written file keeps the previous report, never a crash */ }
    }

    private static string? ReadSharedFile(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd();
        }
        catch { return null; }
    }

    /// <summary>Templates ranked by the bridge's own counter, most-published first.</summary>
    internal static List<TemplateUsage> ParseUsageFile(string? json)
    {
        var items = new List<TemplateUsage>();
        try
        {
            var root = JsonNode.Parse(string.IsNullOrWhiteSpace(json) ? "{}" : json) as JsonObject;
            if (root is null) return items;
            foreach (var pair in root)
            {
                OnAirForm.TryReadInt32(pair.Value?["Count"], out var count);
                DateTime? last = null;
                var stamp = (string?)pair.Value?["LastUsedUtc"];
                if (!string.IsNullOrWhiteSpace(stamp) &&
                    DateTime.TryParse(stamp, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var parsed))
                    last = parsed.Kind == DateTimeKind.Unspecified
                        ? DateTime.SpecifyKind(parsed, DateTimeKind.Utc)
                        : parsed.ToUniversalTime();
                items.Add(new TemplateUsage(pair.Key, Math.Max(0, count), last));
            }
        }
        catch { /* torn file - an empty report beats a half one */ }
        items.Sort((a, b) => b.Count.CompareTo(a.Count));
        return items;
    }

    /// <summary>Usage rows ready for paint: fractions against the leader, at most eight bars.</summary>
    internal static List<BarChart.Bar> BuildUsageBars(List<TemplateUsage> items, Func<string, string> nameFor)
    {
        var bars = new List<BarChart.Bar>();
        if (items.Count == 0) return bars;
        var top = Math.Max(1, items[0].Count);
        foreach (var item in items.Take(8))
        {
            var ago = item.LastUsedUtc is null
                ? "بلا تاريخ"
                : "آخرها قبل " + MainForm.FormatSpan(DateTime.UtcNow - item.LastUsedUtc.Value);
            bars.Add(new BarChart.Bar(
                nameFor(item.Key),
                $"{item.Count} مرة · {ago}",
                (double)item.Count / top));
        }
        return bars;
    }

    /// <summary>
    /// The supervisor's own day, counted out of its own log lines. Markers are
    /// this program's exact sentences - a line is counted only for today, so
    /// yesterday's storm never inflates today's calm.
    /// </summary>
    internal static StabilitySummary SummarizeManagerLog(string[] lines, DateTime today)
    {
        var prefix = today.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var starts = 0; var stops = 0; var watchdog = 0; var giveups = 0;
        foreach (var line in lines)
        {
            if (line is null || !line.StartsWith(prefix, StringComparison.Ordinal)) continue;
            if (line.Contains("تم بدء تشغيل الجسر بنجاح", StringComparison.Ordinal)) starts++;
            else if (line.Contains("إيقاف يدوي.", StringComparison.Ordinal)) stops++;
            else if (line.Contains("كشف تعليق", StringComparison.Ordinal)) watchdog++;
            else if (line.Contains("توقف متكرر", StringComparison.Ordinal)) giveups++;
        }
        return new StabilitySummary(starts, stops, watchdog, giveups);
    }
}
